import Foundation
import ReolinkBcUdp

/// Counterpart to `DataReassembler` for the send path: splits a
/// long Baichuan-message byte stream into a list of
/// `BcUdpDataPacket`s, each sized to fit within the negotiated
/// MTU. Pure value type — no actors, no networking.
///
/// ## MTU
///
/// The 2026-05-16 wire capture's M2C_Q_R reply carried
/// `<mtu>1350</mtu>` — the discovery server's hint at the
/// largest BcUdp Data payload that's reliably deliverable across
/// the chosen path. The default here matches that. Callers that
/// want to be conservative (e.g. when the path looks
/// CGNAT-flavoured) can pass a smaller value; callers that have
/// a higher-MTU path can pass larger.
///
/// ## Sequence numbering
///
/// `DataFragmenter` is stateful in exactly one variable —
/// `nextSequence` — so a single instance can fragment many
/// successive Baichuan messages and the sequence space stays
/// monotonic. Each call to `fragment(_:)` returns the packets
/// and advances `nextSequence` past them.
public struct DataFragmenter: Sendable, Equatable {

    public let connectionID: UInt32
    /// Max bytes of payload (excluding the BcUdp header) that
    /// can ride in a single Data packet. Default matches the
    /// `<mtu>` value from the captured M2C_Q_R reply.
    public let maxPayloadBytesPerPacket: Int
    /// Sequence number to stamp into the next fragment. Wraps
    /// at `UInt32.max` like a TCP seq.
    public private(set) var nextSequence: UInt32

    public init(
        connectionID: UInt32,
        maxPayloadBytesPerPacket: Int = 1350,
        startingSequence: UInt32 = 0
    ) {
        precondition(
            maxPayloadBytesPerPacket > 0,
            "MTU must be positive — chunk size = \(maxPayloadBytesPerPacket)"
        )
        self.connectionID = connectionID
        self.maxPayloadBytesPerPacket = maxPayloadBytesPerPacket
        self.nextSequence = startingSequence
    }

    /// Split `payload` into one or more `BcUdpDataPacket`s
    /// using the configured MTU. Empty inputs return an empty
    /// list (no zero-byte packets emitted — the wire shouldn't
    /// carry them). Updates `nextSequence` to point past the
    /// last fragment.
    public mutating func fragment(_ payload: Data) -> [BcUdpDataPacket] {
        guard !payload.isEmpty else { return [] }
        var fragments: [BcUdpDataPacket] = []
        var offset = payload.startIndex
        let end = payload.endIndex
        while offset < end {
            let chunkEnd = min(offset + maxPayloadBytesPerPacket, end)
            let chunk = payload.subdata(in: offset..<chunkEnd)
            fragments.append(
                BcUdpDataPacket(
                    connectionID: connectionID,
                    sequence: nextSequence,
                    payload: chunk
                )
            )
            nextSequence &+= 1
            offset = chunkEnd
        }
        return fragments
    }
}
