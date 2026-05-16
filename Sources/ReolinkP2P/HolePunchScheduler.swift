import Foundation
import ReolinkBcUdp

/// Tries the candidates returned by discovery in priority order
/// and returns the first one that responds — direct first, relay
/// as fallback. The state machine is small: probe registration,
/// wait up to `directDeadline`, on timeout probe relay, wait up
/// to `relayDeadline`, then give up.
///
/// ## Why this is a function, not an actor
///
/// No state survives between calls — the inputs (candidates +
/// deadlines + runner) fully determine the outcome. Folding it
/// into a free function keeps the interface narrow and the
/// tests pure.
///
/// ## Probe sequencing
///
/// Per decision #2 in `docs/0.7.0-plan.md`, the direct deadline
/// defaults to 6 s. Relay deadline is shorter (4 s) on the
/// theory that if relay won't answer quickly the network path
/// is hopelessly broken regardless. Both are configurable for
/// tests and for users with unusually slow paths.
///
/// ## Result
///
/// Returns the winning endpoint plus a `path` discriminator so
/// callers can surface "direct" vs "relayed" to the UI (Phase
/// 5a's connection-mode pip).
public enum HolePunchScheduler {

    /// Drive the punch state machine to completion. Throws
    /// `HolePunchError` if neither path responds.
    public static func punch(
        _ candidates: DiscoveryXML.LookupResponse,
        directDeadline: Duration = .seconds(6),
        relayDeadline: Duration = .seconds(4),
        runner: any HolePunchProbeRunner
    ) async throws -> HolePunchResult {
        var attempts: [HolePunchError.Attempt] = []

        if let direct = candidates.registration {
            let outcome = await tryProbe(direct, deadline: directDeadline, runner: runner)
            attempts.append(.init(endpoint: direct, path: .direct, outcome: outcome))
            if case .success = outcome {
                return HolePunchResult(endpoint: direct, path: .direct)
            }
        }

        if let relay = candidates.relay {
            let outcome = await tryProbe(relay, deadline: relayDeadline, runner: runner)
            attempts.append(.init(endpoint: relay, path: .relayed, outcome: outcome))
            if case .success = outcome {
                return HolePunchResult(endpoint: relay, path: .relayed)
            }
        }

        // Either no candidates were supplied at all, or every
        // attempted candidate failed.
        if attempts.isEmpty {
            throw HolePunchError.noCandidates
        }
        throw HolePunchError.allFailed(attempts: attempts)
    }

    private static func tryProbe(
        _ endpoint: DiscoveryXML.Endpoint,
        deadline: Duration,
        runner: any HolePunchProbeRunner
    ) async -> ProbeOutcome {
        do {
            return try await runner.probe(endpoint, deadline: deadline)
        } catch {
            return .failed(detail: "\(error)")
        }
    }
}

/// Result of a single probe attempt.
public enum ProbeOutcome: Sendable, Equatable {
    /// Probe round-tripped — the endpoint is alive.
    case success
    /// Deadline elapsed without a reply.
    case timeout
    /// Local-side failure (couldn't open socket, send failed,
    /// invalid reply). `detail` is diagnostic.
    case failed(detail: String)
}

/// Result of a successful hole-punch — the chosen endpoint and
/// whether we reached it directly or via Reolink's relay.
public struct HolePunchResult: Sendable, Equatable {
    public enum Path: Sendable, Equatable {
        case direct
        case relayed
    }
    public let endpoint: DiscoveryXML.Endpoint
    public let path: Path

    public init(endpoint: DiscoveryXML.Endpoint, path: Path) {
        self.endpoint = endpoint
        self.path = path
    }
}

/// Why a punch attempt didn't yield a winner.
public enum HolePunchError: Error, Sendable, Equatable {
    /// `LookupResponse` had no registration and no relay —
    /// the discovery server claims no usable path exists.
    case noCandidates
    /// Every supplied candidate was probed and none responded.
    /// The list of attempts is included so Diagnostics Center
    /// can surface "tried direct (timeout), tried relay
    /// (timeout)" without needing a debug build.
    case allFailed(attempts: [Attempt])

    public struct Attempt: Sendable, Equatable {
        public let endpoint: DiscoveryXML.Endpoint
        public let path: HolePunchResult.Path
        public let outcome: ProbeOutcome

        public init(
            endpoint: DiscoveryXML.Endpoint,
            path: HolePunchResult.Path,
            outcome: ProbeOutcome
        ) {
            self.endpoint = endpoint
            self.path = path
            self.outcome = outcome
        }
    }
}

/// Seam between the state machine and the network. Production
/// implementations open a UDP socket, send a Disc probe, and
/// wait for any reply on the same 5-tuple within `deadline`.
/// Tests inject a scripted stub.
public protocol HolePunchProbeRunner: Sendable {
    func probe(
        _ endpoint: DiscoveryXML.Endpoint,
        deadline: Duration
    ) async throws -> ProbeOutcome
}
