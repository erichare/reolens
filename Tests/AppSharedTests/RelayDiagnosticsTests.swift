import Testing
import Foundation
@testable import AppShared

/// Tests for `RelayDiagnostics`. Each test builds its own actor with a
/// custom storage key so the production singleton's state never leaks
/// between tests, and so we don't need to touch the App Group suite
/// (which would be empty under `swift test` anyway).
@Suite("RelayDiagnostics — state capture + persistence")
struct RelayDiagnosticsTests {

    /// Construct a freshly-keyed diagnostics actor. Each test gets its
    /// own UUID-suffixed storage key so there's no shared mutable
    /// state between cases.
    private static func makeFresh() async -> RelayDiagnostics {
        let key = "com.reolens.relayDiagnostics.test.\(UUID().uuidString)"
        let diag = RelayDiagnostics(suiteName: nil, storageKey: key)
        // Defensive: a brand-new actor with a unique key has no prior
        // state, but reset() also clears any leftover UserDefaults
        // entry from a previous crashed test run.
        await diag.reset()
        return diag
    }

    @Test("Snapshot of an unused actor is empty")
    func snapshotIsInitiallyEmpty() async {
        let diag = await Self.makeFresh()
        let state = await diag.snapshot()
        #expect(state.lastAPNSRegistrationAt == nil)
        #expect(state.lastAPNSTokenByteCount == nil)
        #expect(state.lastSubscriptionInstallAt == nil)
        #expect(state.lastPublisherSaveAt == nil)
        #expect(state.lastSilentPushAt == nil)
        #expect(state.silentPushReceiptsLast24h.isEmpty)
        #expect(state.publisherSaveCountLast24h == 0)
    }

    @Test("Successful APNS registration clears prior failure")
    func successClearsFailure() async {
        let diag = await Self.makeFresh()
        await diag.recordAPNSFailed(message: "network down")
        var state = await diag.snapshot()
        #expect(state.lastAPNSFailureMessage == "network down")
        await diag.recordAPNSRegistered(tokenByteCount: 32)
        state = await diag.snapshot()
        #expect(state.lastAPNSRegistrationAt != nil)
        #expect(state.lastAPNSTokenByteCount == 32)
        #expect(state.lastAPNSFailureAt == nil)
        #expect(state.lastAPNSFailureMessage == nil)
    }

    @Test("Subscription install outcomes round-trip")
    func subscriptionOutcomes() async {
        let diag = await Self.makeFresh()
        await diag.recordSubscriptionInstall(outcome: .installed)
        var state = await diag.snapshot()
        #expect(state.lastSubscriptionInstallSucceeded == true)
        #expect(state.lastSubscriptionInstallOutcome == "installed")

        await diag.recordSubscriptionInstall(outcome: .alreadyRegistered)
        state = await diag.snapshot()
        #expect(state.lastSubscriptionInstallSucceeded == true)

        await diag.recordSubscriptionInstall(
            outcome: .failed,
            errorMessage: "quota exceeded"
        )
        state = await diag.snapshot()
        #expect(state.lastSubscriptionInstallSucceeded == false)
        #expect(state.lastSubscriptionInstallOutcome == "quota exceeded")
    }

    @Test("Publisher saves count successes only")
    func publisherCountsSuccesses() async {
        let diag = await Self.makeFresh()
        await diag.recordPublisherSave(outcome: .saved)
        await diag.recordPublisherSave(outcome: .deduped)
        await diag.recordPublisherSave(outcome: .burstSummary)
        // Three successful outcomes
        var state = await diag.snapshot()
        #expect(state.publisherSaveCountLast24h == 3)
        #expect(state.lastPublisherSaveSucceeded == true)

        // Failures and rate-limited suppressions don't bump the count
        await diag.recordPublisherSave(outcome: .rateLimitedSuppressed)
        await diag.recordPublisherSave(outcome: .failed, errorMessage: "x")
        state = await diag.snapshot()
        #expect(state.publisherSaveCountLast24h == 3)
        #expect(state.lastPublisherSaveSucceeded == false)
        #expect(state.lastPublisherSaveOutcome == "x")
    }

    @Test("Silent-push receipts trim entries older than 24 h")
    func silentPushReceiptsTrim() async {
        let diag = await Self.makeFresh()
        let now = Date()
        // Three stale receipts beyond the 24 h window
        await diag.recordSilentPushReceived(at: now.addingTimeInterval(-26 * 60 * 60))
        await diag.recordSilentPushReceived(at: now.addingTimeInterval(-25 * 60 * 60))
        await diag.recordSilentPushReceived(at: now.addingTimeInterval(-24.5 * 60 * 60))
        // Two fresh receipts inside the window. The latest write trims
        // older entries; we record them at progressively newer times
        // so the cutoff applies to the *current* receipt's timestamp.
        await diag.recordSilentPushReceived(at: now.addingTimeInterval(-60))
        await diag.recordSilentPushReceived(at: now)
        let state = await diag.snapshot()
        #expect(state.silentPushReceiptsLast24h.count == 2)
        #expect(state.lastSilentPushAt == now)
    }

    @Test(
        "humanize splits camelCase outcome rawValues",
        arguments: [
            ("noEntitlement", "No entitlement"),
            ("rateLimitedSuppressed", "Rate limited suppressed"),
            ("alreadyRegistered", "Already registered"),
            ("saved", "Saved"),
            ("Trying to initialize a container without an application id", "Trying to initialize a container without an application id"),
        ]
    )
    func humanizeCamelCase(input: String, expected: String) {
        #expect(DiagnosticsFormatter.humanize(input) == expected)
    }

    @Test("recordDecodeFailure captures field + timestamp")
    func decodeFailureCaptured() async {
        let diag = await Self.makeFresh()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await diag.recordDecodeFailure(field: "channel", at: now)
        let state = await diag.snapshot()
        #expect(state.lastDecodeFailureField == "channel")
        #expect(state.lastDecodeFailureAt == now)
    }

    @Test("recordDecodeSuccess auto-clears a prior decode failure")
    func decodeSuccessClearsFailure() async {
        let diag = await Self.makeFresh()
        await diag.recordDecodeFailure(field: "channel")
        await diag.recordDecodeSuccess()
        let state = await diag.snapshot()
        #expect(state.lastDecodeFailureAt == nil)
        #expect(state.lastDecodeFailureField == nil)
    }

    @Test("recordDecodeSuccess on a clean state is a no-op")
    func decodeSuccessNoopOnCleanState() async {
        let diag = await Self.makeFresh()
        await diag.recordDecodeSuccess()
        let state = await diag.snapshot()
        #expect(state.lastDecodeFailureAt == nil)
        #expect(state.lastDecodeFailureField == nil)
    }

    @Test("Reset clears all persisted state")
    func resetClears() async {
        let diag = await Self.makeFresh()
        await diag.recordAPNSRegistered(tokenByteCount: 32)
        await diag.recordPublisherSave(outcome: .saved)
        await diag.recordSilentPushReceived()
        await diag.recordDecodeFailure(field: "channel")
        await diag.reset()
        let state = await diag.snapshot()
        #expect(state == RelayDiagnosticsState())
    }

    @Test("State persists across actor instances with the same storage key")
    func statePersistsAcrossInstances() async {
        let key = "com.reolens.relayDiagnostics.test.persist.\(UUID().uuidString)"
        // Defensive: make sure no leftover state from a prior run.
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let first = RelayDiagnostics(suiteName: nil, storageKey: key)
        await first.recordAPNSRegistered(tokenByteCount: 32)
        await first.recordPublisherSave(outcome: .saved)

        // A new actor with the same key should observe the persisted
        // state — proving writes hit disk (UserDefaults) atomically.
        let second = RelayDiagnostics(suiteName: nil, storageKey: key)
        let state = await second.snapshot()
        #expect(state.lastAPNSTokenByteCount == 32)
        #expect(state.publisherSaveCountLast24h == 1)
        #expect(state.lastPublisherSaveSucceeded == true)
    }
}
