import Foundation
import Observation
import ReolinkAPI

/// Surfaced when a Keychain password write silently fails — usually
/// either a stale iCloud-synced item resisting deletion (now handled
/// internally via SecItemUpdate fallback) or a keychain-access-group
/// entitlement mismatch from a signing-identity change. Views
/// observe `CameraStore.passwordSaveError` and present an alert,
/// then clear the field by setting it back to nil.
public struct PasswordSaveError: Sendable, Equatable, Identifiable {
    public let deviceID: UUID
    public let message: String

    public var id: UUID { deviceID }

    public init(deviceID: UUID, message: String) {
        self.deviceID = deviceID
        self.message = message
    }
}

/// Snapshot of a notification-tap routing destination that points at
/// a specific recording. Held briefly on `CameraStore` between the
/// shell's selection-change handler and the RecordingsView's appear,
/// then cleared.
public struct PendingRecordingScroll: Sendable, Equatable {
    public let deviceID: UUID
    public let channel: Int
    public let at: Date

    public init(deviceID: UUID, channel: Int, at: Date) {
        self.deviceID = deviceID
        self.channel = channel
        self.at = at
    }
}

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
    /// Base64-encoded SHA-256 of the leaf certificate's DER, recorded
    /// on the first successful HTTPS handshake. Subsequent connections
    /// verify against this and refuse on mismatch. nil means "not yet
    /// recorded" (TOFU first-use). Added in 0.4.1. Forward-compatible
    /// per AGENTS.md §7 — older apps decode-and-ignore this field;
    /// newer apps tolerate it being absent.
    public var tlsFingerprint: String? = nil
    /// Channels where the user has hidden Reolens' in-tile app badges
    /// (camera name, motion / AI icons) so the camera's own OSD
    /// overlay isn't fought over. Per-channel because some channels
    /// on a Hub may have OSD off (top-left clear) while others have
    /// it on. Added in 0.4.1; forward-compatible decode-and-ignore.
    public var hiddenAppBadgeChannels: Set<Int> = []

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
        channelOrder: [Int] = [],
        tlsFingerprint: String? = nil,
        hiddenAppBadgeChannels: Set<Int> = []
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
        self.tlsFingerprint = tlsFingerprint
        self.hiddenAppBadgeChannels = hiddenAppBadgeChannels
    }

    /// Codable conformance: serialize the dict with String keys so JSON is round-trip clean.
    package enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, useHTTPS, preferredCodec,
             channelRotations,         // legacy: per-channel rotation, no stream split
             channelStreamRotations,   // new: per-(channel, stream) rotation
             dualLensOverrides,
             gridPreset,
             channelOrder,
             tlsFingerprint,           // 0.4.1: TOFU TLS pinning
             hiddenAppBadgeChannels    // 0.4.1: per-channel "hide app badges"
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
        // 0.4.1 fields: optional + default-empty, so older
        // cameras.json files (or future schema revisions that drop
        // them) deserialize cleanly per AGENTS.md §7.
        self.tlsFingerprint = try? c.decodeIfPresent(String.self, forKey: .tlsFingerprint)
        let hiddenBadgesList = (try? c.decode([Int].self, forKey: .hiddenAppBadgeChannels)) ?? []
        self.hiddenAppBadgeChannels = Set(hiddenBadgesList)
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
        try c.encodeIfPresent(tlsFingerprint, forKey: .tlsFingerprint)
        // Encode hidden-badge channels even when empty, so a user's
        // explicit "all visible" stays distinguishable from "never
        // configured" in downstream tooling.
        try c.encode(Array(hiddenAppBadgeChannels).sorted(), forKey: .hiddenAppBadgeChannels)
    }
}

@MainActor
@Observable
public final class CameraStore {
    public var cameras: [CameraEntry] = []
    public var selection: SidebarSelection?
    public var sessions: [CameraEntry.ID: CameraSession] = [:]
    /// 0.5.1 — hub expand/collapse state lives in `HubExpansionStore`
    /// so it persists locally AND syncs across devices via
    /// `NSUbiquitousKeyValueStore`. The default is "everything
    /// expanded" (empty `collapsedHubs` set) so newly-paired hubs
    /// surface their channels without an extra click.
    public let hubExpansion = HubExpansionStore.shared
    /// Per-device preferred order for the top-level camera list.
    /// **Not synced via iCloud** — different platforms (sidebar / tab /
    /// single column) have different optimal orderings, and avoiding a
    /// `cameras.json` schema bump keeps older Reolens versions on the
    /// user's other Apple devices compatible. See AGENTS.md "backward-
    /// compatible sync schema". Empty array means "use natural insertion
    /// order"; reconciled with the current `cameras` list at read time
    /// so newly-synced devices appear at the end automatically.
    public var cameraOrder: [UUID] = [] {
        didSet { persistCameraOrder() }
    }
    /// Developer mode. Surfaces diagnostic UI (Raw JSON popovers, verbose
    /// log buttons, etc.) that would otherwise clutter the default view.
    /// Toggle from Settings → Developer. Backed by `UserDefaults` so it
    /// survives relaunch.
    public var developerMode: Bool {
        didSet { UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey) }
    }

    /// Non-isolated peek at the developer-mode flag for code that
    /// runs outside the MainActor (logging hooks in `CameraSession`
    /// task continuations, background relay observers, etc.). Reads
    /// directly from `UserDefaults` so it doesn't need to hop the
    /// actor just to decide whether to emit a `.debug` log line.
    public static var developerModeIsOn: Bool {
        UserDefaults.standard.bool(forKey: developerModeKey)
    }
    static let developerModeKey = "com.reolens.developerMode"
    private static let cameraOrderKey = "com.reolens.cameraOrder"

    /// 0.5.1 — global "Show camera name on feed" preference. Default OFF
    /// because Reolink cameras typically burn their own OSD (date / time
    /// / name) into the top-left of the frame, so our app badge collides
    /// with it and the user has to chase the timestamp around. Users who
    /// want our label back can flip this on in Settings → Display.
    /// Per-channel `hiddenAppBadgeChannels` still acts as an override:
    /// when the global is ON, individual channels can still be hidden.
    public var showCameraNameOnFeed: Bool {
        didSet { UserDefaults.standard.set(showCameraNameOnFeed, forKey: Self.showCameraNameKey) }
    }
    static let showCameraNameKey = "com.reolens.showCameraNameOnFeed"

    public init() {
        let storage = ICloudCameraStorage.shared
        storage.migrateLegacyLocalIfNeeded()
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        // 0.5.1 — default OFF (hidden) on first launch. `bool(forKey:)`
        // returns false when the key is missing, which is exactly what
        // we want as the new default.
        self.showCameraNameOnFeed = UserDefaults.standard.bool(forKey: Self.showCameraNameKey)
        // Restore the device-local sidebar order (UUID strings). Filter to
        // valid UUIDs defensively in case anything was corrupted.
        if let raw = UserDefaults.standard.array(forKey: Self.cameraOrderKey) as? [String] {
            self.cameraOrder = raw.compactMap(UUID.init(uuidString:))
        }
        load()
        // Watch for remote pushes from a sibling device. When another
        // Mac/iPad/iPhone signs in to the same iCloud account writes
        // `cameras.json`, this fires and we rebuild the in-memory model.
        storage.observeRemoteChanges { [weak self] in
            self?.reloadFromStorageIfChanged()
        }
    }

    /// The user's camera list ordered for display in any tile/row UI.
    /// New cameras (not yet in `cameraOrder`) appear at the end so they
    /// don't get hidden after a fresh iCloud sync.
    public func orderedCameras() -> [CameraEntry] {
        let natural = cameras.map(\.id)
        let reconciled = ReorderList.reconciled(order: cameraOrder, natural: natural)
        let byID = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
        return reconciled.compactMap { byID[$0] }
    }

    /// Filter the ordered camera list by a free-text search query. Empty
    /// query returns the full ordered list (same as `orderedCameras()`).
    /// Matches on display name OR host (case-insensitive, diacritic-
    /// insensitive). Useful when a user has many devices and wants to
    /// jump to one without scrolling.
    public func orderedCameras(matching query: String) -> [CameraEntry] {
        let ordered = orderedCameras()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { entry in
            entry.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || entry.host.range(of: trimmed, options: [.caseInsensitive]) != nil
        }
    }

    /// Move the device identified by `sourceID` to the slot immediately
    /// before `targetID`. Used by the sidebar/device-list drag-and-drop.
    /// No-op if either ID is unknown or source == target.
    @discardableResult
    public func reorderCamera(source sourceID: UUID, before targetID: UUID) -> Bool {
        // Seed `cameraOrder` from natural order on first reorder so the
        // user's gesture moves the correct tile from the correct starting
        // position rather than from "empty + appended-at-end".
        var working = ReorderList.reconciled(order: cameraOrder, natural: cameras.map(\.id))
        let moved = ReorderList.move(sourceID: sourceID, before: targetID, in: &working)
        if moved {
            cameraOrder = working
        }
        return moved
    }

    private func persistCameraOrder() {
        let strings = cameraOrder.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: Self.cameraOrderKey)
    }

    /// One-shot navigation request. Set by `applyPendingIntentFocus()`
    /// when an App Intent or notification tap fires; observed by
    /// platform-specific shells (`iPadSplitShell`, `iPhoneTabShell`) to
    /// update their own `selectedSection` / tab state without creating
    /// a feedback loop with the user's `selection` choices in the
    /// sidebar.
    ///
    /// Consumers should reset this to nil after handling so a single
    /// intent fires exactly one navigation.
    public var pendingIntentNavigation: AppIntentFocus.Target?

    /// "Open the recordings tab and scroll-to-and-play this clip"
    /// hint, set by `applyPendingIntentFocus` whenever a recording-
    /// aged notification tap routes in. RecordingsView consumes
    /// (and clears) it on appear. Added in 0.4.1 to deliver
    /// notification-tap → exact-clip routing.
    public var pendingRecordingScroll: PendingRecordingScroll?

    /// Apply any pending focus request written by `OpenCameraIntent`
    /// (Shortcuts / Siri) or by a notification tap. Called by each
    /// app's scene on launch and on foreground. Idempotent — consumes
    /// the pending key so it doesn't re-apply across background/
    /// foreground cycles.
    public func applyPendingIntentFocus() {
        guard let target = AppIntentFocus.consumePending() else { return }
        switch target {
        case .liveCamera(let id):
            guard cameras.contains(where: { $0.id == id }) else { return }
            selection = .device(id)
        case .recording(let id, let channelID, let at):
            guard cameras.contains(where: { $0.id == id }) else { return }
            // Surface the user straight into the channel's Recordings
            // tab + auto-play the closest clip. `pendingRecordingScroll`
            // is consumed by `RecordingsView` on appear; `selection`
            // points to the specific channel so the shell's
            // sidebar/tab routing lands the user on the right view.
            selection = .channel(deviceID: id, channel: channelID)
            pendingRecordingScroll = PendingRecordingScroll(
                deviceID: id,
                channel: channelID,
                at: at
            )
        case .digest(let day):
            // 0.5.0 Theme A5 — open the digest detail sheet. The
            // active scene observes `pendingDigestDay` and presents
            // `DigestDetailView` as a sheet.
            pendingDigestDay = day
        }
        pendingIntentNavigation = target
    }

    /// 0.5.0 Theme A5 — set by `applyPendingIntentFocus` when the
    /// user taps the overnight digest notification. The hosting
    /// scene's `.sheet(item:)` reads (and clears) this to present
    /// `DigestDetailView`.
    public var pendingDigestDay: Date?

    /// Read-and-clear accessor for `pendingRecordingScroll`. Used by
    /// `RecordingsView` on appear so the scroll target only triggers
    /// once per notification tap.
    public func consumePendingRecordingScroll(deviceID: UUID, channel: Int) -> Date? {
        guard let pending = pendingRecordingScroll,
              pending.deviceID == deviceID,
              pending.channel == channel else { return nil }
        pendingRecordingScroll = nil
        return pending.at
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
        Task { await CameraPreviewService.shared.purge(cameraID: id) }
        if selection?.deviceID == id {
            selection = cameras.first.map { .device($0.id) }
        }
        // 0.5.1 — prune the cross-device collapse state for the
        // removed hub so the iCloud KV index stays bounded.
        hubExpansion.forget(deviceID: id)
        // 0.5.1 — prune the per-camera notification mute set so a
        // re-added camera with the same UUID doesn't inherit a
        // stranger's mute state.
        CameraNotificationPreferences.shared.forget(deviceID: id)
        save()
    }

    /// Store a new password for an existing device in this device's Keychain
    /// and rebuild the in-memory session against the new credentials.
    ///
    /// Used by the "Enter Password" flow when a device has synced in from
    /// another platform without credentials, or when the user has rotated
    /// the camera's password on the router/camera side. Does **not** touch
    /// `cameras.json` (the synced metadata), so no iCloud round-trip
    /// happens — passwords stay device-local by design.
    ///
    /// Eagerly creates the new session and stores it in `sessions[id]`
    /// before returning. This is what makes the calling view re-render:
    /// `Keychain.set` is not @Observable, so a fresh-synced device that
    /// had no prior session would NOT trigger a re-render and the user
    /// would stay on the "No password" placeholder until a manual
    /// navigate-away-and-back. Writing to the observable `sessions`
    /// dictionary closes that gap.
    @discardableResult
    public func setPassword(_ password: String, for id: CameraEntry.ID) -> Bool {
        guard cameras.contains(where: { $0.id == id }) else { return false }
        let saved = Keychain.set(password: password, for: id)
        if !saved {
            // Surface the failure so the UI can show an error instead
            // of silently going back to "No password on this Mac".
            // `passwordSaveError` is observable; views present it via
            // an alert.
            let message: String
            #if os(macOS)
            message = """
                The system Keychain rejected the password write.

                If you're running a locally-built Reolens (./Scripts/build-app.sh) and you previously enabled iCloud Keychain Sync, that's the cause — ad-hoc-signed dev builds don't have the iCloud-Keychain entitlement. Turn off iCloud Keychain Sync in Settings → Privacy, or use the Developer-ID-signed release DMG.

                Otherwise, run \u{0060}log show --predicate 'subsystem == "com.reolens.Reolens" AND category == "Keychain"' --info --last 5m\u{0060} in Terminal to see the exact OSStatus.
                """
            #else
            message = "The iOS Keychain rejected the password write. If you've enabled iCloud Keychain Sync, try turning it off in Settings → iCloud Keychain Sync and entering the password again."
            #endif
            passwordSaveError = PasswordSaveError(deviceID: id, message: message)
            return false
        }
        // Tear down the existing session (if any) so a stale one with the
        // old password doesn't keep serving from cache.
        if let existing = sessions.removeValue(forKey: id) {
            Task { await existing.disconnect() }
        }
        // Force-rebuild via session(for:), which reads the new Keychain
        // value and writes the resulting CameraSession into `sessions`.
        // That write is observed by any view rendering this device.
        _ = session(for: id)
        return true
    }

    /// Latest password-save failure, surfaced from `setPassword(_:for:)`
    /// when Keychain reports the write succeeded but the read-back
    /// finds nothing (or both add and update outright fail). Views
    /// observe and present as an alert, then clear. Added in 0.4.1.
    public var passwordSaveError: PasswordSaveError?

    /// Reset the session for a camera without touching its Keychain
    /// entry. Used by the "Reconnect" context-menu action when a
    /// session gets stuck — typically the hub's session token rotated
    /// or the LAN connection blipped, leaving the CGI client in an
    /// indefinitely-connecting state.
    ///
    /// Sequenced so the old session's CGI logout fully completes
    /// before the new session's login fires — Reolink hubs cap
    /// concurrent CGI sessions per credential, so an overlap between
    /// old-still-logging-out and new-trying-to-log-in made the hub
    /// reject the new login with "too many sessions." That was the
    /// "Reconnect doesn't work but delete-and-readd does" path on
    /// iCloud-synced hubs.
    public func reconnect(_ id: CameraEntry.ID) {
        guard cameras.contains(where: { $0.id == id }) else { return }
        if let existing = sessions.removeValue(forKey: id) {
            Task { @MainActor in
                await existing.disconnect()
                _ = self.session(for: id)
            }
        } else {
            _ = session(for: id)
        }
    }

    /// User's opt-in to iCloud Keychain password sync (AGENTS.md §4
    /// opt-in carve-out, added in 0.4.0). Default false. Bridged to
    /// `UserDefaults` so the same flag is visible to `Keychain`
    /// directly when it writes new items, and so the iOS app — which
    /// consumes `AppShared` as an SPM library and can't reach the
    /// `package`-scoped `Keychain` enum — can read/write the
    /// preference through this public surface.
    public var iCloudKeychainSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keychain.syncDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Keychain.syncDefaultsKey) }
    }

    /// Re-save every known camera password on the requested side
    /// (iCloud-synced or device-local). Use after flipping
    /// `iCloudKeychainSyncEnabled` so existing items move to the
    /// chosen side rather than staying on the old one until the user
    /// happens to re-enter the password.
    ///
    /// Returns the count of entries that were migrated and skipped
    /// (skipped means no password was stored on this device for that
    /// camera — common for newly-synced cameras awaiting "Enter
    /// Password"). Never throws; OSStatus errors are logged.
    @discardableResult
    public func migrateKeychainSync(toSync syncOn: Bool) -> (migrated: Int, skipped: Int) {
        let ids = cameras.map(\.id)
        let result = Keychain.migrate(accounts: ids, toSync: syncOn)
        return (result.migrated, result.skipped)
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

    /// Whether the camera-name badge over a live tile should be hidden.
    ///
    /// 0.5.1: the global default flipped to "hidden" because Reolink's
    /// own OSD already shows the camera name + timestamp in the same
    /// corner. The legacy per-channel `hiddenAppBadgeChannels` set still
    /// acts as an override: when the global is ON, channels listed in
    /// the set stay hidden. So the badge is shown only when the user
    /// has explicitly opted in globally AND not opted out on this
    /// channel.
    public func isAppBadgeHidden(deviceID: UUID, channel: Int) -> Bool {
        if !showCameraNameOnFeed { return true }
        return cameras.first(where: { $0.id == deviceID })?.hiddenAppBadgeChannels.contains(channel) ?? false
    }

    public func setAppBadgeHidden(_ hidden: Bool, deviceID: UUID, channel: Int) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        if hidden {
            cameras[i].hiddenAppBadgeChannels.insert(channel)
        } else {
            cameras[i].hiddenAppBadgeChannels.remove(channel)
        }
        save()
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
        let tlsPolicy = makeTLSPolicy(for: id, expecting: entry.tlsFingerprint)
        let session = CameraSession(entry: entry, credentials: creds, tlsPolicy: tlsPolicy)
        // Inject the store's persistent dual-lens override map so the
        // session can answer `isDualLens(channel:)` correctly when the
        // hub doesn't tell us via `typeInfo`.
        session.dualLensOverride = { [weak self] channel in
            self?.isDualLensOverride(deviceID: id, channel: channel) ?? false
        }
        sessions[id] = session
        return session
    }

    /// Per-camera TLS pinning policy. First-use HTTPS handshake
    /// records the leaf cert's fingerprint to the entry; subsequent
    /// mismatches surface via `pendingTrustChange` so a SwiftUI sheet
    /// can present the user's "Trust new cert" / "Cancel" choice.
    /// HTTP-only entries fall through to `alwaysAccept` since the
    /// delegate is never consulted on plain HTTP.
    private func makeTLSPolicy(for id: CameraEntry.ID, expecting fingerprint: String?) -> TLSPinningPolicy {
        // Weak self avoids retain cycles; the policy is held by the
        // CGIClient's URLSession delegate for the session lifetime.
        TLSPinningPolicy(
            expectedFingerprint: fingerprint,
            onObserved: { [weak self] fp in
                Task { @MainActor [weak self] in
                    self?.recordTLSFingerprint(fp, for: id)
                }
            },
            onMismatch: { [weak self] expected, observed in
                Task { @MainActor [weak self] in
                    self?.pendingTrustChange = TrustChangeRequest(
                        deviceID: id,
                        expected: expected,
                        observed: observed
                    )
                }
            }
        )
    }

    /// Persist the just-observed leaf-cert fingerprint to the entry.
    /// Idempotent: writing the same fingerprint is a no-op, so the
    /// callback can fire on every connection without thrashing the
    /// iCloud sync.
    public func recordTLSFingerprint(_ fingerprint: String, for id: CameraEntry.ID) {
        guard let i = cameras.firstIndex(where: { $0.id == id }) else { return }
        guard cameras[i].tlsFingerprint != fingerprint else { return }
        cameras[i].tlsFingerprint = fingerprint
        save()
    }

    /// Clear the stored fingerprint so the next successful connect
    /// re-records (used by the trust-change sheet's "Trust new cert"
    /// confirmation). Also tears down the cached session so the new
    /// pinning policy takes effect on next access.
    public func clearTLSFingerprint(for id: CameraEntry.ID) {
        guard let i = cameras.firstIndex(where: { $0.id == id }) else { return }
        cameras[i].tlsFingerprint = nil
        save()
        if let existing = sessions.removeValue(forKey: id) {
            Task { await existing.disconnect() }
        }
        _ = session(for: id)
    }

    /// Latest TLS trust-change event for the foreground UI to surface
    /// as a sheet. The view that observes this resets it to nil after
    /// the user chooses (accept new cert / cancel).
    public var pendingTrustChange: TrustChangeRequest?

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
