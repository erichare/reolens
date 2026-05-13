import Foundation
import CryptoKit
import CloudKit
import OSLog

private let log = Logger(subsystem: "com.reolens.Reolens", category: "MotionRelay+H")

// MARK: - Deterministic record IDs

/// Build a content-addressed `CKRecord.ID` for a motion event so that
/// retries on crash recovery (and bursts of "the same" event from
/// multiple paths) collapse to a single record on the server. The
/// timestamp is bucketed to 5-second granularity so two genuinely-
/// different events on the same camera that happen to fire in the
/// same second still produce different record IDs.
public enum MotionEventRecordID {
    /// 5-second time-bucket size. Tunable; small enough that a busy
    /// scene still records distinct events, large enough that retries
    /// after a transient network blip collapse cleanly.
    public static let bucketSeconds: TimeInterval = 5

    public static func recordName(
        cameraID: UUID,
        channel: Int,
        detection: String,
        timestamp: Date
    ) -> String {
        let bucket = Int(timestamp.timeIntervalSince1970 / bucketSeconds)
        let canonical = "\(cameraID.uuidString)|\(channel)|\(detection)|\(bucket)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // CloudKit record names accept any UTF-8 string but length-cap
        // at 255. A hex SHA-256 is 64 chars; well within bounds and
        // collision-resistant for our cardinality.
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Token bucket rate limiter

/// Sliding-window rate limit so a high-motion scene (pet, traffic,
/// rain) doesn't burn through Apple's free-tier CloudKit silent-push
/// budget. Configured per camera at 30 events / 10 minutes by default.
/// Excess events coalesce client-side into a single "burst" record
/// every refill window.
public actor MotionEventRateLimiter {

    public struct Bucket: Sendable {
        public var tokens: Double
        public var lastRefill: Date
    }

    private let capacity: Double
    private let refillPerSecond: Double
    private var buckets: [UUID: Bucket] = [:]
    private var burstAccumulator: [UUID: Int] = [:]
    private var burstWindowStart: [UUID: Date] = [:]

    public init(capacity: Int = 30, windowSeconds: TimeInterval = 600) {
        self.capacity = Double(capacity)
        self.refillPerSecond = Double(capacity) / windowSeconds
    }

    public enum Decision: Sendable, Equatable {
        case allow
        case suppress
        /// Periodic burst summary. Includes the number of events
        /// suppressed since the last summary so the receiver can show
        /// "+N events during burst" instead of dropping them on the
        /// floor.
        case burstSummary(suppressedSinceLast: Int)
    }

    public func decide(for cameraID: UUID, now: Date = Date()) -> Decision {
        var bucket = buckets[cameraID] ?? Bucket(tokens: capacity, lastRefill: now)
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        if elapsed > 0 {
            bucket.tokens = min(capacity, bucket.tokens + elapsed * refillPerSecond)
            bucket.lastRefill = now
        }

        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            buckets[cameraID] = bucket
            return .allow
        }

        // Out of tokens — accumulate suppressed-count for the burst
        // summary. Emit a summary record at most once per minute so
        // we don't trade one storm for another.
        let summaryWindow: TimeInterval = 60
        burstAccumulator[cameraID, default: 0] += 1
        let windowStart = burstWindowStart[cameraID] ?? now
        if now.timeIntervalSince(windowStart) >= summaryWindow {
            let suppressed = burstAccumulator[cameraID] ?? 0
            burstAccumulator[cameraID] = 0
            burstWindowStart[cameraID] = now
            buckets[cameraID] = bucket
            return .burstSummary(suppressedSinceLast: suppressed)
        }
        buckets[cameraID] = bucket
        if burstWindowStart[cameraID] == nil {
            burstWindowStart[cameraID] = now
        }
        return .suppress
    }
}

// MARK: - Multi-account guard

/// Persisted across launches in `UserDefaults`, the iCloud
/// ubiquity-identity-token's hash is the cheapest stable "which iCloud
/// account am I logged into" signal. If the user signs out and into a
/// different account between launches, the token changes; we refuse
/// to publish until the user explicitly re-enables relay (so a stale
/// publisher doesn't push events into the wrong family member's iCloud).
///
/// AGENTS.md §5 (privacy: device-local, no Reolens server) is the
/// invariant — multi-account leak would violate that even though the
/// data never leaves Apple's infrastructure.
public enum CloudKitAccountIdentityGuard {

    public static let storedTokenHashKey = "com.reolens.cloudKitRelay.identityHashV1"
    public static let trustChangedFlagKey = "com.reolens.cloudKitRelay.identityTrustChanged"

    /// Compute the hash of the current iCloud account's
    /// ubiquity-identity-token. Returns `nil` if the user isn't signed
    /// into iCloud or the token isn't available.
    public static func currentIdentityHash() -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        // The token is an opaque `NSCoding` object — archive it to a
        // canonical Data form, hash that.
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public enum Decision: Sendable, Equatable {
        /// First publish from this account — store the hash and proceed.
        case enrollAndAllow(hash: String)
        /// Hash matches the stored hash; same account; proceed.
        case allow
        /// Hash differs from stored hash; account changed since last
        /// publish. Block, flip the trust-changed flag, surface a
        /// modal in the UI layer.
        case accountChanged
        /// Couldn't read the token — user signed out of iCloud, or
        /// running without iCloud entitlements. Caller should treat
        /// as "no relay available."
        case unavailable
    }

    public static func decide(
        defaults: UserDefaults = .standard,
        liveHash: String? = currentIdentityHash()
    ) -> Decision {
        guard let liveHash else { return .unavailable }
        let stored = defaults.string(forKey: storedTokenHashKey)
        if let stored {
            if stored == liveHash {
                return .allow
            } else {
                defaults.set(true, forKey: trustChangedFlagKey)
                log.error("iCloud account changed since last relay; halting publish")
                return .accountChanged
            }
        }
        return .enrollAndAllow(hash: liveHash)
    }

    /// Commit an `.enrollAndAllow` decision once a publish has
    /// succeeded. We don't enroll proactively so a `decide()` call
    /// from a passive check (e.g. Settings UI rendering) doesn't
    /// silently bind the device to whatever iCloud account was
    /// active at that moment.
    public static func enroll(hash: String, defaults: UserDefaults = .standard) {
        defaults.set(hash, forKey: storedTokenHashKey)
        defaults.set(false, forKey: trustChangedFlagKey)
    }

    /// User-driven reset — used by Settings → "Re-enable on this
    /// account" after the trust-changed modal fires.
    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storedTokenHashKey)
        defaults.set(false, forKey: trustChangedFlagKey)
    }

    public static func trustChangedFlag(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: trustChangedFlagKey)
    }
}
