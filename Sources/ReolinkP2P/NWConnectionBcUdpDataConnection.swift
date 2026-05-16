import Foundation
import Network
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "data-channel")

/// Concrete `BcUdpDataConnection` backed by an already-opened
/// `NWConnection` in UDP mode. Used after the hole-punch has
/// established the working 5-tuple — the caller (typically
/// `NWConnectionBcUdpPunchEngine`) hands over a ready
/// `NWConnection` and this type runs the receive loop, fans out
/// inbound packets to subscribers, and writes outbound packets
/// to the wire.
///
/// ## Why a handoff rather than open-on-connect
///
/// The hole-punched NAT mapping lives in the kernel's UDP
/// socket state — closing the probe socket and opening a fresh
/// one for the data plane would tear that mapping down and
/// defeat the punch. The probe phase therefore owns the
/// `NWConnection`'s lifecycle until it succeeds, then transfers
/// ownership here.
///
/// ## Status
///
/// **Phase 3d.2-D — structural shell, pending real-device
/// validation.** The code compiles and the wire-level
/// invariants line up with the May 2026 capture (LE encoding,
/// 20-byte Disc/Data + 28-byte Ack headers, BcMessage bytes at
/// offset 20 of every Data packet). What hasn't been validated
/// against a camera yet:
///
/// - Whether the probe Disc that opens the channel needs a
///   specific payload (we send empty for now).
/// - Whether the camera tolerates the connectionID we mint
///   client-side, or expects a server-assigned value.
/// - Keepalive cadence (~10 s assumed; not yet implemented).
public actor NWConnectionBcUdpDataConnection: BcUdpDataConnection {

    private let connection: NWConnection
    /// Tracks whether the connection has been fully closed so
    /// `close()` is idempotent and `connect()` becomes a no-op
    /// after teardown.
    private var isClosed = false
    /// Continuations of subscribers consuming the inbound
    /// packet stream. Fan-out: every received packet is
    /// delivered to every subscriber. Most production usage
    /// has exactly one subscriber (`RemoteTransport`'s receive
    /// loop), but the multi-subscriber surface keeps the
    /// design honest.
    private var subscribers: [UUID: AsyncStream<BcUdpPacket>.Continuation] = [:]
    private var receiveLoopStarted = false

    /// Take ownership of an already-`.ready` `NWConnection`.
    /// The caller has already opened the socket — typically as
    /// part of a hole-punch probe — and verified that it's
    /// reachable.
    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func connect() async throws {
        guard !isClosed else {
            throw BcUdpTransportError.unreachable(
                host: "<closed>",
                port: 0,
                detail: "connect() on a closed data connection"
            )
        }
        startReceiveLoop()
    }

    public func send(_ packet: BcUdpPacket) async throws {
        guard !isClosed else {
            throw BcUdpTransportError.unreachable(
                host: "<closed>",
                port: 0,
                detail: "send on a closed data connection"
            )
        }
        let bytes = packet.encode()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    box.failure(BcUdpTransportError.unreachable(
                        host: "<udp>",
                        port: 0,
                        detail: "send: \(error)"
                    ))
                } else {
                    box.success(())
                }
            })
        }
    }

    public func subscribe() async -> AsyncStream<BcUdpPacket> {
        let (stream, continuation) = AsyncStream<BcUdpPacket>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        for (_, cont) in subscribers {
            cont.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        guard !receiveLoopStarted else { return }
        receiveLoopStarted = true
        scheduleReceive()
    }

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceived(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            // BcUdp packets arrive as single datagrams — UDP
            // preserves message boundaries, so one `receive`
            // delivery should be exactly one BcUdp packet.
            // Anything else is malformed; log + drop.
            if let (packet, _) = BcUdpPacket.decode(from: data) {
                for (_, sub) in subscribers {
                    sub.yield(packet)
                }
            } else {
                log.warning("Dropped \(data.count) bytes of un-decodable BcUdp data")
            }
        }
        if let error {
            log.warning("UDP receive error: \(error.localizedDescription, privacy: .public)")
        }
        if isComplete || error != nil || isClosed {
            // Treat as end-of-stream — finish every subscriber
            // and stop the loop. The caller can still call
            // `close()` separately; the second call is a no-op.
            for (_, cont) in subscribers {
                cont.finish()
            }
            return
        }
        scheduleReceive()
    }
}

// MARK: - Sendable continuation box

/// Idempotent `CheckedContinuation` wrapper — first success or
/// failure wins; later resumes are dropped. Same pattern as the
/// helper inside `NWConnectionBcUdpTransport`.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, any Error>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, any Error>) { self.continuation = cont }
    func success(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil
        c?.resume(returning: value)
    }
    func failure(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil
        c?.resume(throwing: error)
    }
}
