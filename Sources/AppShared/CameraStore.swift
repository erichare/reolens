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
    /// Multi-camera grid layout preset (Adaptive / 1-up / 2×2 / 3×3 / ...).
    /// Defaults to `.adaptive`.
    public var gridPreset: GridPreset = .adaptive
    /// User-customized channel order for the grid. Channel IDs not in this
    /// list are appended in the device's natural order. Empty means
    /// "show in natural order" — same effect as nothing-customized.
    public var channelOrder: [Int] = []

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 80,
        username: String,
        useHTTPS: Bool = false,
        preferredCodec: VideoCodec = .h264,
        channelStreamRotations: [String: Int] = [:],
        dualLensOverrides: Set<Int> = [],
        gridPreset: GridPreset = .adaptive,
        channelOrder: [Int] = []
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
        self.gridPreset = gridPreset
        self.channelOrder = channelOrder
    }

    /// Codable conformance: serialize the dict with String keys so JSON is round-trip clean.
    package enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, useHTTPS, preferredCodec,
             channelRotations,         // legacy: per-channel rotation, no stream split
             channelStreamRotations,   // new: per-(channel, stream) rotation
             dualLensOverrides,
             gridPreset,
             channelOrder
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
        // Grid layout state — also optional for older files.
        self.gridPreset = (try? c.decode(GridPreset.self, forKey: .gridPreset)) ?? .adaptive
        self.channelOrder = (try? c.decode([Int].self, forKey: .channelOrder)) ?? []
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
        try c.encode(gridPreset, forKey: .gridPreset)
        try c.encode(channelOrder, forKey: .channelOrder)
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

    public init() {
        let storage = ICloudCameraStorage.shared
        storage.migrateLegacyLocalIfNeeded()
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        load()
        // Watch for remote pushes from a sibling device. When another
        // Mac/iPad/iPhone signs in to the same iCloud account writes
        // `cameras.json`, this fires and we rebuild the in-memory model.
        storage.observeRemoteChanges { [weak self] in
            self?.reloadFromStorageIfChanged()
        }
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

    // MARK: - Grid layout

    public func gridPreset(for deviceID: UUID) -> GridPreset {
        cameras.first(where: { $0.id == deviceID })?.gridPreset ?? .adaptive
    }

    public func setGridPreset(_ preset: GridPreset, for deviceID: UUID) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        cameras[i].gridPreset = preset
        save()
    }

    /// Order the given channels according to the user's customized order.
    /// Channels missing from the stored order list are appended in their
    /// natural (camera-supplied) sequence.
    public func orderedChannels(for deviceID: UUID, channels: [ChannelStatus]) -> [ChannelStatus] {
        guard let stored = cameras.first(where: { $0.id == deviceID })?.channelOrder, !stored.isEmpty else {
            return channels
        }
        var remaining = channels
        var ordered: [ChannelStatus] = []
        for chID in stored {
            if let idx = remaining.firstIndex(where: { $0.channel == chID }) {
                ordered.append(remaining.remove(at: idx))
            }
        }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    /// Move the channel ID `source` so it lands immediately before `target`
    /// in the persisted order. Channels not yet recorded in the order list
    /// are appended in their current natural sequence first, so the user's
    /// gesture moves the right tile from the right starting place.
    public func reorder(deviceID: UUID, source: Int, before target: Int, allChannels: [ChannelStatus]) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        var order = cameras[i].channelOrder
        // Seed from the natural order if we don't have one yet.
        if order.isEmpty {
            order = allChannels.map(\.channel)
        } else {
            for ch in allChannels where !order.contains(ch.channel) {
                order.append(ch.channel)
            }
        }
        order.removeAll { $0 == source }
        if let targetIdx = order.firstIndex(of: target) {
            order.insert(source, at: targetIdx)
        } else {
            order.append(source)
        }
        cameras[i].channelOrder = order
        save()
    }

    /// Promote a channel to the **primary** slot of the channel order.
    /// In the Spotlight grid this means the big top-left tile. Equivalent
    /// to dragging the chosen tile to index 0 in the persisted order;
    /// surfaced as a dedicated helper so the right-click "Make primary"
    /// action and the control-bar primary picker can share one entry
    /// point. The previous primary slides one slot to the right (becomes
    /// the first sub-spotlight in the new spotlight layout).
    public func setPrimary(deviceID: UUID, channel: Int, allChannels: [ChannelStatus]) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        var order = cameras[i].channelOrder
        if order.isEmpty {
            order = allChannels.map(\.channel)
        } else {
            for ch in allChannels where !order.contains(ch.channel) {
                order.append(ch.channel)
            }
        }
        order.removeAll { $0 == channel }
        order.insert(channel, at: 0)
        cameras[i].channelOrder = order
        save()
    }

    /// The currently-primary channel ID for a device, or nil when no
    /// order has been set yet (caller can default to the first natural
    /// channel in that case).
    public func primaryChannel(for deviceID: UUID) -> Int? {
        cameras.first(where: { $0.id == deviceID })?.channelOrder.first
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
        guard let data = ICloudCameraStorage.shared.read(),
              let entries = try? JSONDecoder().decode([CameraEntry].self, from: data) else { return }
        cameras = entries
        if selection == nil {
            selection = entries.first.map { .device($0.id) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        ICloudCameraStorage.shared.write(data)
    }

    /// Pull the latest JSON from storage and rebuild the in-memory model
    /// only if the on-disk contents differ from what we have. Called by
    /// the iCloud metadata-query handler when another device pushes a
    /// change. Preserves the user's current `selection` so a remote
    /// update doesn't yank the focus away mid-interaction.
    private func reloadFromStorageIfChanged() {
        guard let data = ICloudCameraStorage.shared.read(),
              let entries = try? JSONDecoder().decode([CameraEntry].self, from: data) else { return }
        if entries != cameras {
            cameras = entries
        }
    }
}
