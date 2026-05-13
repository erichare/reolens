import Testing
import Foundation
@testable import AppShared

/// 0.5.0 Theme B3 — the CloudKit motion-event relay grew three
/// safety behaviors on top of the 0.4.1 baseline. These tests lock
/// each one in.
@Suite("MotionEventRecordID — deterministic, time-bucketed")
struct MotionEventRecordIDTests {

    private let cameraA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let cameraB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test("Two events with identical inputs produce the same hash")
    func deterministicHash() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t)
        let b = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t)
        #expect(a == b)
    }

    @Test("Events within the same 5-second bucket collapse to the same hash")
    func sameBucketCollapses() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_003)  // +3s, same bucket
        let h1 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t1)
        let h2 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t2)
        #expect(h1 == h2)
    }

    @Test("Events in adjacent buckets produce different hashes")
    func differentBucketSplits() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_005)  // +5s, new bucket
        let h1 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t1)
        let h2 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t2)
        #expect(h1 != h2)
    }

    @Test("Different cameras at same time still distinct")
    func differentCameraDistinct() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let h1 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t)
        let h2 = MotionEventRecordID.recordName(cameraID: cameraB, channel: 0, detection: "people", timestamp: t)
        #expect(h1 != h2)
    }

    @Test("Different detection tags split")
    func differentDetectionSplits() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let h1 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "people", timestamp: t)
        let h2 = MotionEventRecordID.recordName(cameraID: cameraA, channel: 0, detection: "vehicle", timestamp: t)
        #expect(h1 != h2)
    }
}

@Suite("MotionEventRateLimiter — token bucket + burst")
struct MotionEventRateLimiterTests {

    private let camera = UUID()

    @Test("Allows up to capacity events in a single burst")
    func allowsCapacity() async {
        let limiter = MotionEventRateLimiter(capacity: 3, windowSeconds: 600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 {
            #expect(await limiter.decide(for: camera, now: now) == .allow)
        }
    }

    @Test("Suppresses excess events until the burst-summary window opens")
    func suppressesExcess() async {
        let limiter = MotionEventRateLimiter(capacity: 2, windowSeconds: 600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Burn the capacity.
        _ = await limiter.decide(for: camera, now: now)
        _ = await limiter.decide(for: camera, now: now)
        // Next two are suppressed (within the 60s burst window).
        #expect(await limiter.decide(for: camera, now: now.addingTimeInterval(1)) == .suppress)
        #expect(await limiter.decide(for: camera, now: now.addingTimeInterval(2)) == .suppress)
    }

    @Test("Emits a burst-summary record once per minute, counting suppressed events")
    func emitsBurstSummary() async {
        let limiter = MotionEventRateLimiter(capacity: 1, windowSeconds: 600)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await limiter.decide(for: camera, now: t0)            // allow
        _ = await limiter.decide(for: camera, now: t0.addingTimeInterval(5))   // suppress (#1)
        _ = await limiter.decide(for: camera, now: t0.addingTimeInterval(10))  // suppress (#2)
        // Burst window starts at the first suppression (t0+5). It
        // emits when (now - windowStart) ≥ 60s, so we cross at
        // t0 + 5 + 60 = t0+65. The fourth call (suppress #3) is
        // what trips the emission. The summary includes all three
        // suppressed events.
        let decision = await limiter.decide(for: camera, now: t0.addingTimeInterval(70))
        switch decision {
        case .burstSummary(let suppressed):
            #expect(suppressed == 3)
        default:
            Issue.record("Expected burstSummary, got \(decision)")
        }
    }
}

@Suite("CloudKitAccountIdentityGuard — multi-account guard")
struct CloudKitAccountIdentityGuardTests {

    private func uniqueDefaults() -> UserDefaults {
        let suite = "test.cloudkitidentity.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("First publish enrolls and allows")
    func firstPublishEnrolls() {
        let defaults = uniqueDefaults()
        let decision = CloudKitAccountIdentityGuard.decide(defaults: defaults, liveHash: "hashA")
        switch decision {
        case .enrollAndAllow(let hash):
            #expect(hash == "hashA")
        default:
            Issue.record("Expected enrollAndAllow, got \(decision)")
        }
    }

    @Test("Subsequent publish on same account is allowed")
    func sameAccountAllowed() {
        let defaults = uniqueDefaults()
        CloudKitAccountIdentityGuard.enroll(hash: "hashA", defaults: defaults)
        let decision = CloudKitAccountIdentityGuard.decide(defaults: defaults, liveHash: "hashA")
        #expect(decision == .allow)
        #expect(CloudKitAccountIdentityGuard.trustChangedFlag(defaults: defaults) == false)
    }

    @Test("Switched account blocks and raises trust-changed flag")
    func accountSwitchBlocks() {
        let defaults = uniqueDefaults()
        CloudKitAccountIdentityGuard.enroll(hash: "hashA", defaults: defaults)
        let decision = CloudKitAccountIdentityGuard.decide(defaults: defaults, liveHash: "hashB")
        #expect(decision == .accountChanged)
        #expect(CloudKitAccountIdentityGuard.trustChangedFlag(defaults: defaults) == true)
    }

    @Test("Missing iCloud identity is reported as unavailable")
    func missingIdentityUnavailable() {
        let defaults = uniqueDefaults()
        let decision = CloudKitAccountIdentityGuard.decide(defaults: defaults, liveHash: nil)
        #expect(decision == .unavailable)
    }

    @Test("Reset clears persisted hash so next call re-enrolls")
    func resetClears() {
        let defaults = uniqueDefaults()
        CloudKitAccountIdentityGuard.enroll(hash: "hashA", defaults: defaults)
        CloudKitAccountIdentityGuard.reset(defaults: defaults)
        let decision = CloudKitAccountIdentityGuard.decide(defaults: defaults, liveHash: "hashA")
        switch decision {
        case .enrollAndAllow: break
        default:
            Issue.record("Expected enrollAndAllow after reset, got \(decision)")
        }
    }
}
