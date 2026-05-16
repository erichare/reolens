import Foundation
import ReolinkBcUdp

/// Reassembles `BcUdpDataPacket` fragments back into complete
/// Baichuan-framed byte sequences. Pure value type — no actors,
/// no networking, no async — so every interesting behaviour
/// (sequence ordering, boundary detection, multi-message
/// streams) is unit-testable in isolation.
///
/// ## Why this is a separate type
///
/// The Baichuan TCP path moves bytes as a continuous stream;
/// `BcMessage.decode(from:cipher:)` already knows how to parse
/// out individual messages from a long buffer. The remote
/// (BcUdp) path delivers those same bytes split into UDP-sized
/// fragments, and UDP can lose / reorder / duplicate fragments.
/// `DataReassembler` bridges the gap — it consumes Data
/// packets, reorders them by sequence number, and emits the
/// reassembled bytes in order so `BcMessage.decode` can run
/// unchanged downstream.
///
/// ## Scope
///
/// Tracks one connectionID. The wire capture shows the same
/// hole-punched UDP socket can carry multiple BcUdp
/// connections (different `connectionID` values) — callers
/// that need to demultiplex should run one `DataReassembler`
/// per connectionID and route inbound packets by
/// `BcUdpDataPacket.connectionID`.
///
/// ## Semantics
///
/// - Out-of-order fragments are buffered until contiguous.
/// - Duplicate fragments (same `sequence`) are silently
///   dropped (treat as benign retransmits from the peer).
/// - The expected-next sequence number is initialized at
///   `0` because Reolink's wire shows fresh hole-punch
///   sessions starting their seq counter at 0; if a future
///   capture shows otherwise, the caller can supply an
///   alternative starting value.
public struct DataReassembler: Sendable, Equatable {

    /// The connection identifier this reassembler accepts.
    /// Packets with different `connectionID` are rejected by
    /// `ingest(_:)` returning `.wrongConnection`.
    public let connectionID: UInt32

    /// The next sequence number we expect. Starts at 0;
    /// advances by 1 each time a fragment is consumed in
    /// order.
    public private(set) var nextExpectedSequence: UInt32

    /// Buffer of fragments that arrived out of order, keyed
    /// by their sequence number. Drained as soon as
    /// contiguous progress becomes possible.
    private var pending: [UInt32: Data]

    /// Bytes assembled in-order but not yet pulled out by
    /// `pullAssembled()`. Grows as fragments arrive; the
    /// caller drains it after each `ingest`.
    private var assembled: Data

    public init(connectionID: UInt32, startingSequence: UInt32 = 0) {
        self.connectionID = connectionID
        self.nextExpectedSequence = startingSequence
        self.pending = [:]
        self.assembled = Data()
    }

    /// Result of an `ingest` call. The caller drives an
    /// outer state machine off this: emit Acks for `.appended`
    /// + `.bufferedOutOfOrder`, ignore (or log) the others.
    public enum Outcome: Sendable, Equatable {
        /// Packet contributed contiguous bytes; the
        /// `assembled` buffer grew.
        case appended(sequence: UInt32)
        /// Packet was a future fragment; held until the gap
        /// fills in.
        case bufferedOutOfOrder(sequence: UInt32)
        /// Packet was a duplicate or an already-consumed
        /// sequence — silently dropped.
        case duplicate(sequence: UInt32)
        /// Packet belongs to a different connection. The
        /// caller routes it elsewhere.
        case wrongConnection
    }

    /// Consume one Data packet. Updates `assembled` and
    /// `nextExpectedSequence`; returns what happened so the
    /// caller can drive ack / retransmit logic.
    @discardableResult
    public mutating func ingest(_ packet: BcUdpDataPacket) -> Outcome {
        guard packet.connectionID == connectionID else {
            return .wrongConnection
        }
        let seq = packet.sequence
        if seq < nextExpectedSequence {
            // Peer retransmitted a fragment we already
            // assembled. Silent drop — our prior ack must
            // have been lost in transit.
            return .duplicate(sequence: seq)
        }
        if seq == nextExpectedSequence {
            // Contiguous fragment — append directly, then
            // drain any pending fragments that became
            // contiguous as a result.
            assembled.append(packet.payload)
            nextExpectedSequence &+= 1
            while let bufferedPayload = pending.removeValue(forKey: nextExpectedSequence) {
                assembled.append(bufferedPayload)
                nextExpectedSequence &+= 1
            }
            return .appended(sequence: seq)
        }
        // Future fragment — hold for later.
        if pending[seq] != nil {
            return .duplicate(sequence: seq)
        }
        pending[seq] = packet.payload
        return .bufferedOutOfOrder(sequence: seq)
    }

    /// Pull whatever bytes have been assembled in-order so
    /// far. Hands ownership to the caller and resets the
    /// internal buffer; the next `pullAssembled()` returns
    /// only bytes appended since.
    public mutating func pullAssembled() -> Data {
        let out = assembled
        assembled = Data()
        return out
    }

    /// True when the reassembler is sitting on no buffered
    /// fragments and no unread assembled bytes. Useful for
    /// asserting "all caught up" in tests.
    public var isIdle: Bool {
        pending.isEmpty && assembled.isEmpty
    }

    /// How many out-of-order fragments are currently
    /// buffered. The hole-punch state machine uses this to
    /// decide whether to send a selective-ack hint.
    public var pendingFragmentCount: Int {
        pending.count
    }
}
