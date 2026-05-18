import Testing
import Foundation
import CloudKit
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

/// 0.6.8 — `MotionEvent.decode(record:)` surfaces *which* field is
/// missing so the iOS subscriber's diagnostics row can tell the user
/// "schema mismatch on field X" instead of silently dropping the
/// record. These tests pin one failure case per field so a future
/// schema change can't quietly regress the visibility.
@Suite("MotionEvent.decode — per-field failure surfacing")
struct MotionEventDecodeTests {

    private static let validCameraID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let validRecordID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    /// Build a fully-populated `CKRecord` matching the published
    /// schema. Individual tests selectively erase fields to exercise
    /// each failure branch.
    private static func makeValidRecord() -> CKRecord {
        let id = CKRecord.ID(recordName: validRecordID.uuidString)
        let r = CKRecord(recordType: MotionEvent.recordType, recordID: id)
        r[MotionEvent.RecordKey.cameraID] = validCameraID.uuidString as NSString
        r[MotionEvent.RecordKey.channel] = 2 as NSNumber
        r[MotionEvent.RecordKey.detection] = "people" as NSString
        r[MotionEvent.RecordKey.timestamp] = Date(timeIntervalSince1970: 1_700_000_000) as NSDate
        return r
    }

    @Test("Fully-populated record decodes to .success")
    func happyPath() {
        let result = MotionEvent.decode(record: Self.makeValidRecord())
        guard case .success(let event) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        #expect(event.cameraID == Self.validCameraID)
        #expect(event.channel == 2)
        #expect(event.detection == "people")
        #expect(event.id == Self.validRecordID)
    }

    @Test(
        "Missing required field produces .missingField with that field's name",
        arguments: [
            MotionEvent.RecordKey.cameraID,
            MotionEvent.RecordKey.channel,
            MotionEvent.RecordKey.detection,
            MotionEvent.RecordKey.timestamp,
        ]
    )
    func missingField(field: String) {
        let record = Self.makeValidRecord()
        record[field] = nil
        let result = MotionEvent.decode(record: record)
        guard case .failure(let failure) = result else {
            Issue.record("Expected .failure for missing \(field), got \(result)")
            return
        }
        #expect(failure == .missingField(field))
        #expect(failure.label == field)
    }

    @Test("Wrong recordType produces .wrongRecordType carrying the actual type")
    func wrongRecordType() {
        let id = CKRecord.ID(recordName: Self.validRecordID.uuidString)
        let r = CKRecord(recordType: "SomeOtherType", recordID: id)
        let result = MotionEvent.decode(record: r)
        guard case .failure(.wrongRecordType(let actual)) = result else {
            Issue.record("Expected .wrongRecordType, got \(result)")
            return
        }
        #expect(actual == "SomeOtherType")
    }

    @Test("Non-UUID recordName (SHA-256 hex hash) decodes to a stable derived UUID")
    func contentAddressedRecordNameDecodes() {
        // 64-char hex string — what the deduped publisher path actually
        // writes. Pre-fix the decoder rejected these as malformed.
        let hashName = MotionEventRecordID.recordName(
            cameraID: Self.validCameraID,
            channel: 0,
            detection: "people",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let id = CKRecord.ID(recordName: hashName)
        let r = CKRecord(recordType: MotionEvent.recordType, recordID: id)
        r[MotionEvent.RecordKey.cameraID] = Self.validCameraID.uuidString as NSString
        r[MotionEvent.RecordKey.channel] = 0 as NSNumber
        r[MotionEvent.RecordKey.detection] = "people" as NSString
        r[MotionEvent.RecordKey.timestamp] = Date() as NSDate
        guard case .success(let event) = MotionEvent.decode(record: r) else {
            Issue.record("Expected .success for content-addressed recordName")
            return
        }
        // Stable: a second decode of the same record produces the
        // same id — this is the invariant NotificationHistory dedup
        // relies on.
        guard case .success(let again) = MotionEvent.decode(record: r) else {
            Issue.record("Second decode should also succeed")
            return
        }
        #expect(event.id == again.id)
    }

    @Test("Distinct record names map to distinct UUIDs")
    func distinctRecordNamesDistinctUUIDs() {
        let a = MotionEventRecordID.stableUUID(fromRecordName: "abc123")
        let b = MotionEventRecordID.stableUUID(fromRecordName: "abc124")
        #expect(a != b)
    }

    @Test("UUID-string recordName round-trips unchanged through stableUUID")
    func uuidRecordNamePassthrough() {
        let original = Self.validRecordID
        let derived = MotionEventRecordID.stableUUID(fromRecordName: original.uuidString)
        #expect(derived == original)
    }

    @Test("Non-UUID cameraID string is reported as missing cameraID field")
    func malformedCameraIDIsReportedAsMissing() {
        let record = Self.makeValidRecord()
        record[MotionEvent.RecordKey.cameraID] = "not-a-uuid" as NSString
        let result = MotionEvent.decode(record: record)
        #expect(result == .failure(.missingField(MotionEvent.RecordKey.cameraID)))
    }

    @Test("init?(record:) is a thin pass-through over decode")
    func initIsPassthrough() {
        #expect(MotionEvent(record: Self.makeValidRecord()) != nil)
        let broken = Self.makeValidRecord()
        broken[MotionEvent.RecordKey.channel] = nil
        #expect(MotionEvent(record: broken) == nil)
    }

    @Test("cameraName field round-trips through toRecord + decode")
    func cameraNameRoundTrip() {
        let event = MotionEvent(
            id: Self.validRecordID,
            cameraID: Self.validCameraID,
            channel: 13,
            detection: "people",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            snapshotFileURL: nil,
            cameraName: "Front Door"
        )
        let record = event.toRecord()
        guard case .success(let decoded) = MotionEvent.decode(record: record) else {
            Issue.record("Expected .success")
            return
        }
        #expect(decoded.cameraName == "Front Door")
    }

    @Test("Record without cameraName field still decodes (legacy compat)")
    func legacyRecordWithoutCameraNameStillDecodes() {
        let record = Self.makeValidRecord()
        #expect(record[MotionEvent.RecordKey.cameraName] == nil)
        guard case .success(let decoded) = MotionEvent.decode(record: record) else {
            Issue.record("Expected .success for legacy record")
            return
        }
        #expect(decoded.cameraName == nil)
    }

    @Test("Empty cameraName is normalized to nil")
    func emptyCameraNameNormalizedToNil() {
        let record = Self.makeValidRecord()
        record[MotionEvent.RecordKey.cameraName] = "" as NSString
        guard case .success(let decoded) = MotionEvent.decode(record: record) else {
            Issue.record("Expected .success")
            return
        }
        #expect(decoded.cameraName == nil)
    }
}
