import Foundation
import Observation
import ReolinkAPI

/// Persisted camera definition (no password — that's in Keychain).
public struct CameraEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var useHTTPS: Bool
    public var preferredCodec: VideoCodec
    /// Per-(channel, stream) rotation in degrees (90 / 180 / 270). Defaults
    /// to 0 when unset. Stored per stream because dual-lens Reolink cameras
    /// can encode the main and sub stream in different native orientations
    /// (e.g. sub rotated 90° CCW, main rotated 90° CW) — a single shared
    /// rotation would only correct one of them. Key format: `"{channel}:{stream}"`,
    /// e.g. `"0:main"`, `"0:sub"`.
    public var channelStreamRotations: [String: Int] = [:]
    /// Channels that the user has manually marked dual-lens. Used when the
    /// hub's `GetChannelstatus` doesn't report a `typeInfo` we recognize
    /// (Home Hub Pro returns nil for many paired cameras, including Argus
    /// 4 Pro on current firmware).
    public var dualLensOverrides: Set<Int> = []

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 80,
        username: String,
        useHTTPS: Bool = false,
        preferredCodec: VideoCodec = .h264,
        channelStreamRotations: [String: Int] = [:],
        dualLensOverrides: Set<Int> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.useHTTPS = useHTTPS
        self.preferredCodec = preferredCodec
        self.channelStreamRotations = channelStreamRotations
        self.dualLensOverrides = dualLensOverrides
    }

    /// Codable conformance: serialize the dict with String keys so JSON is round-trip clean.
    enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, useHTTPS, preferredCodec,
             channelRotations,         // legacy: per-channel rotation, no stream split
             channelStreamRotations,   // new: per-(channel, stream) rotation
             dualLensOverrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.useHTTPS = try c.decode(Bool.self, forKey: .useHTTPS)
        self.preferredCodec = try c.decode(VideoCodec.self, forKey: .preferredCodec)
        // New per-stream rotation map. Falls back to migrating the legacy
        // `channelRotations` (one rotation per channel, shared by all
        // streams) into both `:main` and `:sub` entries — preserves the
        // user's previous configuration on first launch of this build.
        if let newDict = try? c.decode([String: Int].self, forKey: .channelStreamRotations), !newDict.isEmpty {
            self.channelStreamRotations = newDict
        } else if let legacy = try? c.decode([String: Int].self, forKey: .channelRotations) {
            var migrated: [String: Int] = [:]
            for (k, v) in legacy {
                guard Int(k) != nil else { continue }
                migrated["\(k):main"] = v
                migrated["\(k):sub"] = v
            }
            self.channelStreamRotations = migrated
        } else {
            self.channelStreamRotations = [:]
        }
        // Backward-compat: the field is optional so existing cameras.json
        // files without it continue to deserialize cleanly.
        let overrideList = (try? c.decode([Int].self, forKey: .dualLensOverrides)) ?? []
        self.dualLensOverrides = Set(overrideList)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(useHTTPS, forKey: .useHTTPS)
        try c.encode(preferredCodec, forKey: .preferredCodec)
        try c.encode(channelStreamRotations, forKey: .channelStreamRotations)
        try c.encode(Array(dualLensOverrides).sorted(), forKey: .dualLensOverrides)
    }
}

@MainActor
@Observable
public final class CameraStore {
    public var cameras: [CameraEntry] = []
    public var selection: SidebarSelection?
    public var sessions: [CameraEntry.ID: CameraSession] = [:]
    public var expandedDevices: Set<UUID> = []
    /// Developer mode. Surfaces diagnostic UI (Raw JSON popovers, verbose
    /// log buttons, etc.) that would otherwise clutter the default view.
    /// Toggle from Settings → Developer. Backed by `UserDefaults` so it
    /// survives relaunch.
    public var developerMode: Bool {
        didSet { UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey) }
    }
    private static let developerModeKey = "com.reolens.developerMode"

    private let storageURL: URL

    public init() {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = appSupport?.appendingPathComponent("Reolens", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reolens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("cameras.json")
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        load()
    }

    public func add(_ entry: CameraEntry, password: String) {
        cameras.append(entry)
        Keychain.set(password: password, for: entry.id)
        selection = .device(entry.id)
        save()
    }

    public func remove(_ id: CameraEntry.ID) {
        cameras.removeAll { $0.id == id }
        if let session = sessions.removeValue(forKey: id) {
            Task { await session.disconnect() }
        }
        Keychain.deletePassword(for: id)
        if selection?.deviceID == id {
            selection = cameras.first.map { .device($0.id) }
        }
        save()
    }

    /// Look up the user's persisted rotation for a specific (channel, stream).
    /// Reolink dual-lens cameras can encode main and sub at different
    /// native orientations, so we have to store these independently.
    public func rotation(for deviceID: UUID, channel: Int, stream: StreamKind) -> Int {
        let key = Self.rotationKey(channel: channel, stream: stream)
        return cameras.first(where: { $0.id == deviceID })?.channelStreamRotations[key] ?? 0
    }

    public func setRotation(_ degrees: Int, for deviceID: UUID, channel: Int, stream: StreamKind) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        let key = Self.rotationKey(channel: channel, stream: stream)
        let normalized = ((degrees % 360) + 360) % 360
        if normalized == 0 {
            cameras[i].channelStreamRotations.removeValue(forKey: key)
        } else {
            cameras[i].channelStreamRotations[key] = normalized
        }
        save()
    }

    public func rotateClockwise(deviceID: UUID, channel: Int, stream: StreamKind) {
        let current = rotation(for: deviceID, channel: channel, stream: stream)
        setRotation(current + 90, for: deviceID, channel: channel, stream: stream)
    }

    private static func rotationKey(channel: Int, stream: StreamKind) -> String {
        "\(channel):\(stream.rawValue)"
    }

    /// User-set dual-lens override for a given channel. Empty when the user
    /// hasn't explicitly flipped the toggle in channel settings.
    public func isDualLensOverride(deviceID: UUID, channel: Int) -> Bool {
        cameras.first(where: { $0.id == deviceID })?.dualLensOverrides.contains(channel) ?? false
    }

    public func setDualLensOverride(_ enabled: Bool, deviceID: UUID, channel: Int) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        if enabled {
            cameras[i].dualLensOverrides.insert(channel)
        } else {
            cameras[i].dualLensOverrides.remove(channel)
        }
        save()
    }

    public func session(for id: CameraEntry.ID) -> CameraSession? {
        if let s = sessions[id] { return s }
        guard let entry = cameras.first(where: { $0.id == id }),
              let password = Keychain.password(for: id) else { return nil }
        let creds = CameraCredentials(
            host: entry.host,
            port: entry.port,
            username: entry.username,
            password: password,
            useHTTPS: entry.useHTTPS
        )
        let session = CameraSession(entry: entry, credentials: creds)
        // Inject the store's persistent dual-lens override map so the
        // session can answer `isDualLens(channel:)` correctly when the
        // hub doesn't tell us via `typeInfo`.
        session.dualLensOverride = { [weak self] channel in
            self?.isDualLensOverride(deviceID: id, channel: channel) ?? false
        }
        sessions[id] = session
        return session
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let entries = try? JSONDecoder().decode([CameraEntry].self, from: data) else { return }
        cameras = entries
        selection = entries.first.map { .device($0.id) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
