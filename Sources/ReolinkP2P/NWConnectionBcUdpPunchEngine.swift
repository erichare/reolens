import Foundation
import Network
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "punch-engine")

/// Concrete `HolePunchProbeRunner` plus a connection cache.
/// `probe(_:deadline:)` opens a fresh UDP `NWConnection` to the
/// candidate, sends a Disc probe, and waits up to `deadline` for
/// any reply on the same 5-tuple. On success, the connection is
/// retained inside the engine; on failure it's cancelled.
///
/// The matching `dataConnection(for:)` accessor extracts the
/// retained connection once `HolePunchScheduler` declares a
/// winner — that's the connection-handoff the data plane needs
/// to preserve the hole-punched NAT mapping.
///
/// ## Why this engine combines probe + cache
///
/// `HolePunchScheduler` is intentionally narrow — it knows
/// nothing about UDP sockets, just probe outcomes. But the
/// production runner needs a UDP socket per candidate AND has
/// to keep the winning socket alive past the probe phase.
/// Stashing the sockets inside the engine is the simplest way
/// to honour both constraints without leaking
/// `NWConnection` into the scheduler's interface.
///
/// ## Status
///
/// **Phase 3d.2-D — pending real-device validation.** The
/// probe wire format is the BcUdp Disc kind from the codec
/// (validated against the May 2026 capture), but a *direct*
/// hole-punch probe might require a specific XML payload that
/// we haven't reverse-engineered yet. For now we send an empty
/// Disc; the next on-device capture will tell us whether that
/// elicits a reply or whether the camera ignores it.
public actor NWConnectionBcUdpPunchEngine: HolePunchProbeRunner {

    private static let callbackQueue = DispatchQueue.global(qos: .userInitiated)

    /// Endpoints we've successfully probed but not yet handed
    /// off via `dataConnection(for:)`. Keyed by
    /// `"host:port"` because `DiscoveryXML.Endpoint` is not
    /// `Hashable` enough to use directly as a dict key safely
    /// across address types.
    private var cached: [String: NWConnection] = [:]

    /// Probe payload bytes — the encrypted XML we send in the
    /// Disc probe. For now this is empty; Phase 3d.2-D follow-
    /// up will populate with whatever the real Reolink app
    /// sends, once a capture confirms the format.
    private let probePayload: Data

    /// Sender ID stamped into outbound Disc probes. Random per
    /// engine instance; matches what `P2PDiscovery` does.
    private let senderID: UInt32

    public init(probePayload: Data = Data(), senderID: UInt32 = .random(in: 1...UInt32.max)) {
        self.probePayload = probePayload
        self.senderID = senderID
    }

    // MARK: - HolePunchProbeRunner

    public nonisolated func probe(
        _ endpoint: DiscoveryXML.Endpoint,
        deadline: Duration
    ) async throws -> ProbeOutcome {
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? .init(integerLiteral: 9999),
            using: .udp
        )

        do {
            try await awaitReady(connection)
        } catch {
            connection.cancel()
            return .failed(detail: "ready: \(error)")
        }

        let probeBytes = BcUdpDiscPacket(
            protocolFlag: 1,
            senderID: senderID,
            requestToken: 0,
            payload: probePayload
        ).encode()
        do {
            try await sendBytes(probeBytes, on: connection)
        } catch {
            connection.cancel()
            return .failed(detail: "send: \(error)")
        }

        let outcome = await awaitAnyReply(on: connection, deadline: deadline)
        switch outcome {
        case .success:
            // Keep the socket alive — the data plane consumes
            // it via `dataConnection(for:)`. Subsequent
            // `receive()` calls inside
            // `NWConnectionBcUdpDataConnection` will pick up
            // any datagrams that arrive on the same 5-tuple.
            await retain(connection, for: endpoint)
            return .success
        case .timeout, .failed:
            connection.cancel()
            return outcome
        }
    }

    // MARK: - Connection handoff

    /// Extract the cached connection for an endpoint we
    /// previously probed successfully. Returns nil if the
    /// engine never saw this endpoint or already vended it.
    public func dataConnection(for endpoint: DiscoveryXML.Endpoint) -> (any BcUdpDataConnection)? {
        let nwConn = cached.removeValue(forKey: key(endpoint))
        return nwConn.map { NWConnectionBcUdpDataConnection(connection: $0) }
    }

    private func retain(_ connection: NWConnection, for endpoint: DiscoveryXML.Endpoint) {
        cached[key(endpoint)] = connection
    }

    private nonisolated func key(_ endpoint: DiscoveryXML.Endpoint) -> String {
        "\(endpoint.host):\(endpoint.port)"
    }

    // MARK: - NWConnection lifecycle helpers

    private nonisolated func awaitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.success(())
                case .failed(let err): box.failure(err)
                case .cancelled: box.failure(CocoaError(.userCancelled))
                case .waiting(let err): box.failure(err)
                default: break
                }
            }
            conn.start(queue: Self.callbackQueue)
        }
        conn.stateUpdateHandler = { _ in }
    }

    private nonisolated func sendBytes(_ bytes: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.send(content: bytes, completion: .contentProcessed { error in
                if let error { box.failure(error) }
                else { box.success(()) }
            })
        }
    }

    private nonisolated func awaitAnyReply(
        on conn: NWConnection,
        deadline: Duration
    ) async -> ProbeOutcome {
        let result = await withTaskGroup(of: ProbeOutcome?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<ProbeOutcome?, Never>) in
                    let box = ContinuationBox(cont)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error {
                            box.success(.failed(detail: "recv: \(error)"))
                        } else if data?.isEmpty == false {
                            box.success(.success)
                        } else if isComplete {
                            box.success(.failed(detail: "peer closed"))
                        } else {
                            box.success(.failed(detail: "empty datagram"))
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        return result ?? .timeout
    }
}

// MARK: - Sendable continuation box

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
    }
}
