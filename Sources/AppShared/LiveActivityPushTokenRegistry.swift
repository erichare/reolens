import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "live-activity-push")

/// 0.5.1 — Persists the push tokens iOS hands us for in-flight Live
/// Activities so a future server-driven sender (or a peer Apple
/// device acting as a relay) can update them remotely.
///
/// Schema is intentionally minimal: per-activity ID we store the
/// raw APNs token (hex string) + the camera UUID it belongs to +
/// the iOS-issued token freshness timestamp. Tokens rotate when the
/// system tears down and rebuilds the activity, so the registry is
/// authoritative on "what to push to right now."
///
/// Storage: iCloud Drive ubiquity container next to bookmarks. Local
/// fallback under Documents matches the bookmark store pattern.
public actor LiveActivityPushTokenRegistry {
    public static let shared = LiveActivityPushTokenRegistry()

    public struct Token: Codable, Sendable, Hashable {
        public let activityID: String
        public let cameraID: UUID
        public let pushTokenHex: String
        public let issuedAt: Date

        public init(activityID: String, cameraID: UUID, pushTokenHex: String, issuedAt: Date) {
            self.activityID = activityID
            self.cameraID = cameraID
            self.pushTokenHex = pushTokenHex
            self.issuedAt = issuedAt
        }
    }

    private static let fileName = "live-activity-tokens_v1.json"

    private var tokens: [String: Token] = [:]
    private var didLoad = false

    public init() {}

    public func register(_ token: Token) async {
        await ensureLoaded()
        tokens[token.activityID] = token
        persist()
        log.info("Registered Live Activity push token activity=\(token.activityID, privacy: .public) camera=\(token.cameraID, privacy: .public)")
    }

    public func forget(activityID: String) async {
        await ensureLoaded()
        guard tokens.removeValue(forKey: activityID) != nil else { return }
        persist()
    }

    /// Tokens currently registered, keyed by activity ID. Exposed for
    /// the future server-driven sender to drain on demand.
    public func snapshot() async -> [Token] {
        await ensureLoaded()
        return Array(tokens.values)
    }

    // MARK: - Persistence

    private static var rootDirectory: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.reolens.Reolens")?
            .appending(path: "Documents/live-activity-tokens")
    }

    private static var localFallback: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appending(path: "Reolens/live-activity-tokens")
    }

    private static func storageURL() -> URL {
        let base = rootDirectory ?? localFallback
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: fileName)
    }

    private func ensureLoaded() async {
        guard !didLoad else { return }
        didLoad = true
        let url = Self.storageURL()
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: Token].self, from: data) {
            self.tokens = decoded
        }
    }

    private func persist() {
        let url = Self.storageURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tokens) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
