import Testing
import Foundation
@testable import AppShared

/// 0.5.0 Theme E — connection robustness types pinned by tests.
@Suite("ConnectionStage labels")
struct ConnectionStageTests {

    @Test("Working stages report isWorking=true")
    func workingStagesAreWorking() {
        let working: [ConnectionStage] = [
            .probingReachability,
            .awaitingLocalNetworkPermission,
            .loggingIn(attempt: 1),
            .fetchingDeviceMetadata,
            .establishingPushChannel,
            .retrying(after: 2, reason: "x")
        ]
        for stage in working {
            #expect(stage.isWorking, "Expected \(stage) to be working")
        }
    }

    @Test("Settled stages report isWorking=false")
    func settledStagesAreSettled() {
        #expect(ConnectionStage.idle.isWorking == false)
        #expect(ConnectionStage.connected.isWorking == false)
        #expect(ConnectionStage.failed(reason: "no").isWorking == false)
    }

    @Test("loggingIn attempt 1 reads 'Logging in…'; attempt 2 reads 'Logging in (retry 1)…'")
    func loggingInLabels() {
        #expect(ConnectionStage.loggingIn(attempt: 1).shortLabel == "Logging in…")
        #expect(ConnectionStage.loggingIn(attempt: 2).shortLabel == "Logging in (retry 1)…")
        #expect(ConnectionStage.loggingIn(attempt: 4).shortLabel == "Logging in (retry 3)…")
    }

    @Test("retrying countdown rounds up the displayed seconds")
    func retryingCountdown() {
        #expect(ConnectionStage.retrying(after: 0.1, reason: "x").shortLabel == "Retrying in 1 s")
        #expect(ConnectionStage.retrying(after: 2.4, reason: "x").shortLabel == "Retrying in 3 s")
        #expect(ConnectionStage.retrying(after: 5.0, reason: "x").shortLabel == "Retrying in 5 s")
    }
}

@Suite("ConnectRetryPolicy backoff")
struct ConnectRetryPolicyTests {

    @Test("Backoff doubles per attempt up to maxBackoffSeconds")
    func doublesUpToCeiling() {
        let policy = ConnectRetryPolicy(maxAttempts: 6, baseSeconds: 1, maxBackoffSeconds: 8, jitterFraction: 0)
        // Pin random source to return the midpoint (0.5 → zero delta).
        let zero = { 0.5 }
        #expect(policy.backoffSeconds(attempt: 1, randomSource: zero) == 1)
        #expect(policy.backoffSeconds(attempt: 2, randomSource: zero) == 2)
        #expect(policy.backoffSeconds(attempt: 3, randomSource: zero) == 4)
        #expect(policy.backoffSeconds(attempt: 4, randomSource: zero) == 8)
        // Capped.
        #expect(policy.backoffSeconds(attempt: 5, randomSource: zero) == 8)
        #expect(policy.backoffSeconds(attempt: 6, randomSource: zero) == 8)
    }

    @Test("Jitter pulls the result inside [base*(1-j), base*(1+j)]")
    func jitterInBounds() {
        let policy = ConnectRetryPolicy(maxAttempts: 4, baseSeconds: 4, maxBackoffSeconds: 100, jitterFraction: 0.25)
        for _ in 0..<200 {
            let value = policy.backoffSeconds(attempt: 1)
            #expect(value >= 3.0)   // 4 * (1 - 0.25)
            #expect(value <= 5.0)   // 4 * (1 + 0.25)
        }
    }

    @Test("Zero jitter is deterministic")
    func zeroJitterDeterministic() {
        let policy = ConnectRetryPolicy(maxAttempts: 4, baseSeconds: 2, maxBackoffSeconds: 16, jitterFraction: 0)
        let a = policy.backoffSeconds(attempt: 3)
        let b = policy.backoffSeconds(attempt: 3)
        #expect(a == b)
        #expect(a == 8)  // 2 * 2^(3-1) = 8
    }

    @Test("Default policy has a 30s overall deadline")
    func defaultDeadline() {
        #expect(ConnectRetryPolicy.default.overallDeadlineSeconds == 30)
    }
}

@Suite("CameraDiscovery throttling cap")
struct CameraDiscoveryThrottleTests {

    @Test("The /24 concurrency cap is small enough for iOS")
    func capIsConservative() {
        // iOS's NetworkSession can blow up with 254 simultaneous
        // probes. Confirm the cap stays well below.
        #expect(CameraDiscovery.concurrentProbeLimit <= 64)
        #expect(CameraDiscovery.concurrentProbeLimit >= 8)
    }
}
