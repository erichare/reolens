import Foundation
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "discovery")

public enum P2PDiscoveryError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// Every server in the pool either timed out, was
    /// unreachable, or returned an empty / malformed response.
    /// The actor records which servers it tried and what each
    /// one returned so Diagnostics can surface "your camera is
    /// online but Reolink's servers aren't responding" without
    /// requiring a debug build.
    case exhausted(uid: String, attempts: [Attempt])

    /// The supplied server pool was empty. Programmer error —
    /// only emitted from tests / dev builds.
    case emptyServerPool

    public struct Attempt: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let outcome: Outcome

        public enum Outcome: Sendable, Equatable {
            case timedOut
            case unreachable(detail: String)
            case malformedReply
            case unexpectedKind(BcUdpPacketKind)
            case emptyResponse
        }
    }

    public var description: String {
        switch self {
        case .exhausted(let uid, let attempts):
            "P2P discovery exhausted server pool for uid \(uid) after \(attempts.count) attempt(s)"
        case .emptyServerPool:
            "P2P discovery server pool is empty"
        }
    }

    public var errorDescription: String? { description }
}

/// Looks a camera up in Reolink's P2P discovery cluster by UID.
///
/// ## Flow
///
/// 1. Build a `DiscoveryXML.LookupRequest` keyed on the supplied
///    UID + a fresh per-call client token.
/// 2. Wrap it in a `BcUdpDiscPacket` and walk the configured
///    server pool, calling
///    `BcUdpTransport.sendAndAwaitReply` on each in order.
/// 3. On the first reply that decodes to a non-empty
///    `LookupResponse`, return its parsed candidates.
/// 4. If every server in the pool fails (timeout / unreachable /
///    malformed / empty), throw `P2PDiscoveryError.exhausted`
///    with the per-server outcome list so the caller can
///    surface a useful diagnostic.
///
/// ## What this actor does NOT do
///
/// - Open any sockets. The transport does that.
/// - Cache results. Discovery answers are short-lived; caching
///   them risks holding a stale WAN address through a NAT
///   rebinding. The caller (Phase 3's NAT-traversal layer) owns
///   any caching it needs.
/// - Validate that the discovered candidates actually work. That
///   is the next layer up — the hole-punch state machine
///   probes each candidate before committing to one.
public actor P2PDiscovery {

    private let transport: any BcUdpTransport
    private let pool: DiscoveryServerPool
    private let clientIDProvider: @Sendable () -> String

    /// - Parameters:
    ///   - transport: The BcUdp transport to use. Injected so
    ///     tests can stub the network surface.
    ///   - pool: Server pool to walk. Defaults to the production
    ///     `p2p*.reolink.com` cluster.
    ///   - clientIDProvider: Source of per-lookup client tokens.
    ///     Defaults to a short random hex string; tests inject a
    ///     deterministic generator.
    public init(
        transport: any BcUdpTransport,
        pool: DiscoveryServerPool = .default,
        clientIDProvider: @escaping @Sendable () -> String = Self.defaultClientID
    ) {
        self.transport = transport
        self.pool = pool
        self.clientIDProvider = clientIDProvider
    }

    /// Look the camera identified by `uid` up in the discovery
    /// pool. Returns the first non-empty server reply, parsed
    /// into a `LookupResponse`. Throws `.exhausted` when every
    /// server in the pool fails.
    public func lookup(
        uid: String,
        timeoutPerServer: Duration = .milliseconds(1500)
    ) async throws -> DiscoveryXML.LookupResponse {
        guard !pool.entries.isEmpty else { throw P2PDiscoveryError.emptyServerPool }

        let request = DiscoveryXML.LookupRequest(uid: uid, clientID: clientIDProvider())
        let packet = BcUdpPacket.disc(
            BcUdpDiscPacket(
                connectionID: 0,
                responseCode: 0,
                payload: request.encode()
            )
        )

        var attempts: [P2PDiscoveryError.Attempt] = []
        attempts.reserveCapacity(pool.entries.count)

        for entry in pool.entries {
            // UID is private (per-camera identifier); host is
            // public infrastructure. Match the privacy markers
            // used elsewhere in the project.
            log.info("Trying discovery server \(entry.host, privacy: .public):\(entry.port, privacy: .public) for uid=\(uid, privacy: .private)")
            do {
                let reply = try await transport.sendAndAwaitReply(
                    packet,
                    to: entry.host,
                    port: entry.port,
                    timeout: timeoutPerServer
                )
                guard case .disc(let discReply) = reply else {
                    attempts.append(.init(host: entry.host, port: entry.port, outcome: .unexpectedKind(reply.kind)))
                    continue
                }
                guard let parsed = DiscoveryXML.LookupResponse.decode(from: discReply.payload) else {
                    attempts.append(.init(host: entry.host, port: entry.port, outcome: .malformedReply))
                    continue
                }
                guard !parsed.isEmpty else {
                    // Some servers in the pool answer with a
                    // well-formed but candidate-free response
                    // when they don't have a current
                    // registration for the UID. That's not an
                    // error — just means try the next server.
                    log.info("Server \(entry.host, privacy: .public) returned empty candidate list; trying next")
                    attempts.append(.init(host: entry.host, port: entry.port, outcome: .emptyResponse))
                    continue
                }
                log.info("Discovery succeeded via \(entry.host, privacy: .public) after \(attempts.count + 1, privacy: .public) attempt(s)")
                return parsed
            } catch BcUdpTransportError.timedOut(_, _) {
                attempts.append(.init(host: entry.host, port: entry.port, outcome: .timedOut))
                continue
            } catch BcUdpTransportError.unreachable(_, _, let detail) {
                attempts.append(.init(host: entry.host, port: entry.port, outcome: .unreachable(detail: detail)))
                continue
            } catch BcUdpTransportError.malformedReply(_, _) {
                attempts.append(.init(host: entry.host, port: entry.port, outcome: .malformedReply))
                continue
            } catch BcUdpTransportError.unexpectedKind(_, _, let got) {
                attempts.append(.init(host: entry.host, port: entry.port, outcome: .unexpectedKind(got)))
                continue
            }
        }

        // Pre-compute the Sendable string-form for the log line
        // so the error isn't captured into a Task body — same
        // pattern CameraListPersistence uses for AppErrorRecorder.
        let attemptCount = attempts.count
        log.error("Discovery exhausted server pool for uid=\(uid, privacy: .private) after \(attemptCount, privacy: .public) attempt(s)")
        throw P2PDiscoveryError.exhausted(uid: uid, attempts: attempts)
    }

    /// Default client-ID generator: 8 hex chars derived from a
    /// random `UInt32`. The token is opaque to Reolink's servers
    /// (they just echo it back); collisions across concurrent
    /// in-flight lookups are harmless because the transport
    /// pairs reply-to-request by 5-tuple, not by client ID.
    public static let defaultClientID: @Sendable () -> String = {
        String(UInt32.random(in: 0...UInt32.max), radix: 16)
    }
}
