import Foundation
import Network
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "transport")

/// Concrete `BcUdpTransport` backed by `Network.framework`'s
/// `NWConnection` in UDP mode. Each call opens a fresh
/// connection, sends the supplied packet bytes, awaits a single
/// reply datagram (or the timeout), and tears the connection
/// down — discovery is request/response and doesn't benefit from
/// connection reuse. The stateful BcUdp data-plane channel that
/// Phase 3 will use is a different abstraction entirely; it
/// won't go through this type.
///
/// ## Why a fresh connection per call
///
/// 1. Discovery responses are typically one datagram. There's
///    nothing to keep the socket open for.
/// 2. UDP `NWConnection`s in stale states have surfaced odd
///    behavior on iOS (per Apple's networking forum threads).
///    A new connection per lookup sidesteps the issue at a small
///    cost: ~10 ms of overhead per server tried.
/// 3. Pool-fallback semantics are clearer when each attempt is
///    its own scoped resource — the actor doesn't have to reason
///    about partial state from a previous attempt.
public struct NWConnectionBcUdpTransport: BcUdpTransport {

    /// Queue used to drive `NWConnection` callbacks. A single
    /// shared global queue is fine — `NWConnection` is designed
    /// to be safe under callback-based dispatch and we never
    /// touch shared mutable state from the callbacks (everything
    /// goes through one-shot `CheckedContinuation`s).
    private static let callbackQueue = DispatchQueue.global(qos: .userInitiated)

    public init() {}

    public func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 9999),
            using: .udp
        )
        // `defer` cancels on every exit, including the throw
        // path. `NWConnection.cancel()` is idempotent and safe to
        // call on a still-readying connection.
        defer { conn.cancel() }

        do {
            try await awaitReady(conn, host: host, port: port)
            try await sendBytes(packet.encode(), on: conn, host: host, port: port)
            return try await awaitOneReply(on: conn, host: host, port: port, timeout: timeout)
        } catch let error as BcUdpTransportError {
            throw error
        } catch {
            // Any error from inside `withCheckedThrowingContinuation`
            // that *isn't* a BcUdpTransportError is a programming
            // bug — surface it as `.unreachable` so the discovery
            // actor's fallback still kicks in rather than tearing
            // the whole lookup down.
            throw BcUdpTransportError.unreachable(host: host, port: port, detail: "\(error)")
        }
    }

    // MARK: - Connection lifecycle

    private func awaitReady(_ conn: NWConnection, host: String, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.success(())
                case .failed(let err):
                    box.failure(BcUdpTransportError.unreachable(host: host, port: port, detail: "failed: \(err)"))
                case .cancelled:
                    box.failure(BcUdpTransportError.unreachable(host: host, port: port, detail: "cancelled before ready"))
                case .waiting(let err):
                    // `.waiting` on UDP usually means DNS or
                    // routing isn't resolving. Treat as
                    // unreachable so the actor moves to the next
                    // server rather than blocking the whole
                    // lookup on one slow DNS lookup.
                    box.failure(BcUdpTransportError.unreachable(host: host, port: port, detail: "waiting: \(err)"))
                default: break
                }
            }
            conn.start(queue: Self.callbackQueue)
        }
        // Detach the state handler so a later cancellation event
        // doesn't fire the (already-consumed) continuation.
        conn.stateUpdateHandler = { _ in }
    }

    private func sendBytes(_ bytes: Data, on conn: NWConnection, host: String, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    box.failure(BcUdpTransportError.unreachable(host: host, port: port, detail: "send: \(error)"))
                } else {
                    box.success(())
                }
            })
        }
    }

    // MARK: - Receive

    private func awaitOneReply(
        on conn: NWConnection,
        host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        // Race the receive against the timeout. We can't cancel
        // `NWConnection.receive`'s pending callback directly, so
        // the loser of the race is left dangling — that's fine
        // because the `defer { conn.cancel() }` in the caller
        // tears the whole connection down on return, which
        // synthesizes the receive callback (it fires with `error`
        // / `isComplete` after cancel) and the box absorbs the
        // duplicate resume safely.
        let result = await withTaskGroup(of: Result<BcUdpPacket, BcUdpTransportError>?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Result<BcUdpPacket, BcUdpTransportError>?, Never>) in
                    let box = ContinuationBox(cont)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error {
                            box.success(.failure(.unreachable(host: host, port: port, detail: "recv: \(error)")))
                            return
                        }
                        guard let data, !data.isEmpty else {
                            // Empty datagram or socket reported
                            // complete with no payload — treat as
                            // a malformed reply so the actor
                            // moves on. (UDP shouldn't normally
                            // report `isComplete=true`, but
                            // NWConnection does on cancellation.)
                            if isComplete {
                                box.success(.failure(.unreachable(host: host, port: port, detail: "peer closed")))
                            } else {
                                box.success(.failure(.malformedReply(host: host, port: port)))
                            }
                            return
                        }
                        guard let decoded = BcUdpPacket.decode(from: data) else {
                            box.success(.failure(.malformedReply(host: host, port: port)))
                            return
                        }
                        box.success(.success(decoded.0))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        switch result {
        case .success(let packet): return packet
        case .failure(let err): throw err
        case nil: throw BcUdpTransportError.timedOut(host: host, port: port)
        }
    }
}

// MARK: - Sendable continuation box

/// Idempotent `CheckedContinuation` wrapper — the first
/// success / failure wins; later resumes are dropped on the
/// floor. Mirrors the helper inside
/// `Sources/ReolinkBaichuan/BaichuanClient.swift` so the two
/// modules stay style-consistent without sharing code (the
/// Baichuan helper is private and not vended).
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var successC: CheckedContinuation<T, Never>?
    private var throwingC: CheckedContinuation<T, any Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<T, Never>) { self.successC = cont }
    init(_ cont: CheckedContinuation<T, any Error>) { self.throwingC = cont }

    func success(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        if let c = successC {
            successC = nil
            c.resume(returning: value)
        } else if let c = throwingC {
            throwingC = nil
            c.resume(returning: value)
        }
    }

    func failure(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        if let c = throwingC {
            throwingC = nil
            c.resume(throwing: error)
        }
        // No-op when only a non-throwing continuation is held —
        // callers building one of those never expect a failure
        // path. (The receive task wraps its outcome in `Result`
        // so it can communicate failure on a `Never`-error
        // continuation.)
    }
}
