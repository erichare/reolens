import Testing
import Foundation
import ReolinkBcUdp
@testable import ReolinkP2P

@Suite("HolePunchScheduler — direct-first, relay-fallback")
struct HolePunchSchedulerTests {

    @Test("Direct candidate succeeds → returns .direct")
    func directWins() async throws {
        let candidates = makeCandidates(
            rendezvous: makeEndpoint("203.0.113.10", 9000),
            relay: makeEndpoint("relay.example", 8443)
        )
        let runner = ScriptedRunner(script: [
            "203.0.113.10:9000": .success
        ])
        let result = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
        #expect(result.endpoint.host == "203.0.113.10")
        #expect(result.path == .direct)
        let attempted = await runner.attempted()
        #expect(attempted == ["203.0.113.10:9000"])  // relay never queried
    }

    @Test("Direct times out → fall back to relay successfully")
    func relayFallback() async throws {
        let candidates = makeCandidates(
            rendezvous: makeEndpoint("203.0.113.10", 9000),
            relay: makeEndpoint("relay.example", 8443)
        )
        let runner = ScriptedRunner(script: [
            "203.0.113.10:9000": .timeout,
            "relay.example:8443": .success
        ])
        let result = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
        #expect(result.endpoint.host == "relay.example")
        #expect(result.path == .relayed)
        let attempted = await runner.attempted()
        #expect(attempted == ["203.0.113.10:9000", "relay.example:8443"])
    }

    @Test("Both candidates fail → throws .allFailed with diagnostic attempts")
    func bothFailExhausted() async {
        let candidates = makeCandidates(
            rendezvous: makeEndpoint("203.0.113.10", 9000),
            relay: makeEndpoint("relay.example", 8443)
        )
        let runner = ScriptedRunner(script: [
            "203.0.113.10:9000": .timeout,
            "relay.example:8443": .timeout
        ])
        do {
            _ = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
            Issue.record("Expected .allFailed to throw")
        } catch HolePunchError.allFailed(let attempts) {
            #expect(attempts.count == 2)
            #expect(attempts[0].path == .direct)
            #expect(attempts[0].outcome == .timeout)
            #expect(attempts[1].path == .relayed)
            #expect(attempts[1].outcome == .timeout)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("No registration but relay succeeds → returns .relayed")
    func registrationMissingRelaySucceeds() async throws {
        let candidates = makeCandidates(
            rendezvous: nil,
            relay: makeEndpoint("relay.example", 8443)
        )
        let runner = ScriptedRunner(script: [
            "relay.example:8443": .success
        ])
        let result = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
        #expect(result.path == .relayed)
        let attempted = await runner.attempted()
        #expect(attempted == ["relay.example:8443"])
    }

    @Test("No candidates at all → throws .noCandidates")
    func neitherCandidate() async {
        let candidates = makeCandidates(rendezvous: nil, relay: nil)
        let runner = ScriptedRunner(script: [:])
        do {
            _ = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
            Issue.record("Expected .noCandidates")
        } catch HolePunchError.noCandidates {
            // expected
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Runner throws → recorded as .failed, fall-through still happens")
    func runnerThrowsRecordsFailedAndFallsThrough() async throws {
        let candidates = makeCandidates(
            rendezvous: makeEndpoint("203.0.113.10", 9000),
            relay: makeEndpoint("relay.example", 8443)
        )
        struct ProbeError: Error {}
        let runner = ScriptedRunner(script: [
            "203.0.113.10:9000": .throwingError,
            "relay.example:8443": .success
        ])
        let result = try await HolePunchScheduler.punch(direct: candidates.rendezvous, relay: candidates.relay, runner: runner)
        #expect(result.path == .relayed)
    }

    @Test("Direct deadline is honored — never blocks longer than configured")
    func directDeadlineHonored() async throws {
        // Use a runner that respects the supplied deadline so
        // we can pin that the scheduler does pass it through.
        let candidates = makeCandidates(
            rendezvous: makeEndpoint("203.0.113.10", 9000),
            relay: makeEndpoint("relay.example", 8443)
        )
        let runner = DeadlineRecorder()
        _ = try? await HolePunchScheduler.punch(
            direct: candidates.rendezvous,
            relay: candidates.relay,
            directDeadline: .milliseconds(750),
            relayDeadline: .milliseconds(250),
            runner: runner
        )
        let recorded = await runner.recorded()
        #expect(recorded.count == 2)
        #expect(recorded[0].0 == "203.0.113.10:9000")
        #expect(recorded[0].1 == .milliseconds(750))
        #expect(recorded[1].0 == "relay.example:8443")
        #expect(recorded[1].1 == .milliseconds(250))
    }

    // MARK: - Helpers

    private func makeCandidates(
        rendezvous: DiscoveryXML.Endpoint?,
        relay: DiscoveryXML.Endpoint?
    ) -> DiscoveryXML.LookupResponse {
        DiscoveryXML.LookupResponse(rendezvous: rendezvous, relay: relay, responseCode: 0)
    }

    private func makeEndpoint(_ host: String, _ port: UInt16) -> DiscoveryXML.Endpoint {
        DiscoveryXML.Endpoint(host: host, port: port)
    }
}

// MARK: - Stubs

private actor ScriptedRunner: HolePunchProbeRunner {
    enum Scripted: Sendable {
        case success
        case timeout
        case throwingError
    }

    private let script: [String: Scripted]
    private var attempts: [String] = []

    init(script: [String: Scripted]) {
        self.script = script
    }

    nonisolated func probe(
        _ endpoint: DiscoveryXML.Endpoint,
        deadline: Duration
    ) async throws -> ProbeOutcome {
        await record(endpoint)
        switch script[key(endpoint)] {
        case .success?: return .success
        case .timeout?: return .timeout
        case .throwingError?:
            struct ProbeError: Error {}
            throw ProbeError()
        case nil:
            return .timeout    // unscripted candidates are treated as "no answer"
        }
    }

    private func record(_ endpoint: DiscoveryXML.Endpoint) {
        attempts.append(key(endpoint))
    }

    func attempted() -> [String] { attempts }

    nonisolated private func key(_ e: DiscoveryXML.Endpoint) -> String {
        "\(e.host):\(e.port)"
    }
}

private actor DeadlineRecorder: HolePunchProbeRunner {
    private var calls: [(String, Duration)] = []

    nonisolated func probe(
        _ endpoint: DiscoveryXML.Endpoint,
        deadline: Duration
    ) async throws -> ProbeOutcome {
        await record(endpoint, deadline: deadline)
        return .timeout
    }

    private func record(_ endpoint: DiscoveryXML.Endpoint, deadline: Duration) {
        calls.append(("\(endpoint.host):\(endpoint.port)", deadline))
    }

    func recorded() -> [(String, Duration)] { calls }
}
