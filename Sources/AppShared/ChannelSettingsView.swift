import SwiftUI
import ReolinkAPI
import ReolinkBaichuan
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-channel settings — currently OSD (on-screen display) toggles for the
/// camera-name and time overlays the camera bakes into the video stream,
/// plus the device's AI-detection capability map and battery telemetry.
///
/// Shared across macOS, iPadOS, and iPhone: macOS hosts it as a tab in
/// `ChannelDetailContent`; iOS hosts it as the third tab of
/// `SingleChannelView`. `Form { .formStyle(.grouped) }` renders natively
/// on each platform.
public struct ChannelSettingsView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @Environment(CameraStore.self) private var store
    @State private var osd: OsdSettings?
    @State private var supportedAITypes: [DetectionType] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// 0.5.0 Theme C2 — local working set of motion privacy zones.
    /// Populated lazily on view appear; `apply` pushes them back to
    /// the camera through the existing `SetOsd` privacy-mask param.
    @State private var privacyZones = PrivacyZoneEditorModel()
    @State private var privacyZonesDirty = false
    /// 0.5.1 — backdrop image rendered behind the privacy-zone
    /// editor so the user is drawing on top of the actual camera
    /// frame rather than a black rectangle. Loaded from
    /// `CameraPreviewService`'s snapshot cache; if nothing is cached
    /// we fetch a fresh `cmd=Snap` (waking the camera first when
    /// it's battery-powered, mirroring `CameraPreviewImage.refresh`).
    @State private var privacyBackground: PrivacyZoneBackgroundImage?
    @State private var isLoadingPrivacyBackground = false

    /// Local edit buffer for `CameraEntry.remoteHost`. Synced
    /// from the store on appear and on `cameraDidChange`; pushed
    /// back to the store on submit/commit. Keeping the edit
    /// local avoids re-rendering the whole `Form` on every
    /// keystroke and means the user's in-flight edit isn't lost
    /// when iCloud-sync pushes an unrelated field update.
    @State private var remoteHostDraft: String = ""
    /// True when `remoteHostDraft` has diverged from the
    /// persisted value — controls whether the Save button is
    /// active.
    @State private var remoteHostIsDirty: Bool = false
    @State private var showRemoteHostHelp: Bool = false

    public init(session: CameraSession, channel: ChannelStatus) {
        self.session = session
        self.channel = channel
    }

    public var body: some View {
        Form {
            Section("On-Screen Display") {
                if osd != nil {
                    osdToggles
                } else if isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Loading…") }
                } else if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("No OSD configuration available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !supportedAITypes.isEmpty {
                Section("AI Detection") {
                    Text("This channel can detect:").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(supportedAITypes, id: \.self) { d in
                            Label(d.label, systemImage: d.systemImage)
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                // 0.5.0 Liquid Glass — AI capability
                                // badges read as glass chips matching
                                // the AI-event filter row.
                                .reolensGlassChip()
                        }
                    }
                }
            }
            Section("Channel") {
                LabeledContent("Name", value: channel.name ?? "—")
                LabeledContent("Type", value: channel.typeInfo ?? "—")
                LabeledContent("Status", value: channel.isOnline ? (channel.isAsleep ? "Sleeping" : "Online") : "Offline")
                LabeledContent("Battery powered", value: session.isBatteryPowered(channel: channel.channel) ? "Yes" : "No")
                if store.developerMode {
                    // Hardware property — but we expose a manual override
                    // for Developer mode because some firmwares don't
                    // report `typeInfo` and our auto-detection relies on
                    // the live stream starting. Most users should never
                    // need to touch this.
                    Toggle("Dual lens (override)", isOn: Binding(
                        get: { store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
                               || channel.isDualLens },
                        set: { newValue in
                            store.setDualLensOverride(newValue, deviceID: session.entry.id, channel: channel.channel)
                        }
                    ))
                } else {
                    LabeledContent("Dual lens", value: session.isDualLens(channel: channel.channel) ? "Yes" : "No")
                }
                if let battery = session.batteryByChannel[channel.channel] {
                    LabeledContent("Battery level", value: "\(battery.percent)%")
                    LabeledContent("Charge status", value: batteryChargeLabel(for: battery))
                    if let t = battery.temperatureC {
                        LabeledContent("Battery temperature", value: "\(t) °C")
                    }
                }
            }
            Section("Motion privacy zones") {
                Text("Drag on the preview to mask regions from motion detection. Drag a zone to move it; tap the × to remove. Up to \(PrivacyZoneEditorModel.maxZones) zones per camera.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topTrailing) {
                    PrivacyZoneEditorView(
                        model: Binding(get: { privacyZones }, set: { newValue in
                            privacyZones = newValue
                            privacyZonesDirty = true
                        }),
                        backgroundImage: privacyBackground
                    )
                    .frame(maxWidth: .infinity)
                    if isLoadingPrivacyBackground, privacyBackground == nil {
                        // Brief progress overlay while we fetch a
                        // fresh `cmd=Snap` because the cache is
                        // empty (first-launch / never-viewed
                        // channel). Auto-clears the moment the
                        // image arrives or the load fails.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fetching preview…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: .capsule)
                        .padding(8)
                    }
                }
                HStack {
                    Button("Reset zones") {
                        privacyZones = PrivacyZoneEditorModel()
                        privacyZonesDirty = true
                    }
                    .disabled(privacyZones.zones.isEmpty)
                    Spacer()
                    if privacyZonesDirty {
                        Text("\(privacyZones.zones.count)/\(PrivacyZoneEditorModel.maxZones) zones — unsaved")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(privacyZones.zones.count)/\(PrivacyZoneEditorModel.maxZones) zones")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Save zones") {
                        Task { await persistPrivacyZones() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!privacyZonesDirty)
                }
            }
            Section("Recording schedule") {
                NavigationLink {
                    RecordingScheduleView(session: session, channel: channel)
                        .navigationTitle("Recording schedule")
                } label: {
                    Label("Edit weekly recording schedule", systemImage: "calendar")
                }
                Text("Set the hours when this camera writes recordings to the hub or SD card. Some firmware (battery-powered cameras paired through a Home Hub, older NVRs) reports the schedule as read-only — the editor reflects that.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Motion-detection schedule") {
                NavigationLink {
                    MotionScheduleView(session: session, channel: channel)
                        .navigationTitle("Motion schedule")
                } label: {
                    Label("Edit weekly motion schedule", systemImage: "bell.badge")
                }
                Text("Set the hours when motion and AI events on this camera fire alarms. Per-tag overrides let you quiet a specific tag (e.g. ignore vehicles overnight while still alerting on people).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Overlay") {
                Toggle("Show app badges over video", isOn: Binding(
                    get: { !store.isAppBadgeHidden(deviceID: session.entry.id, channel: channel.channel) },
                    set: { shown in
                        store.setAppBadgeHidden(!shown, deviceID: session.entry.id, channel: channel.channel)
                    }
                ))
                .disabled(!store.showCameraNameOnFeed)
                if store.showCameraNameOnFeed {
                    Text("Reolens can show the camera name and a motion / AI indicator over this tile. Turn off for the cleanest possible image, or if the camera's own date / time / name overlay (configured in the OSD section above) is fighting for the same corner.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("App badges over video are globally hidden (new default in 0.5.1). Enable them under Settings → Display first, then this per-channel toggle takes effect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let info = session.deviceInfo {
                Section("Device") {
                    LabeledContent("Model", value: info.model ?? "—")
                    LabeledContent("Firmware", value: info.firmVer ?? "—")
                    LabeledContent("Hardware", value: info.hardVer ?? "—")
                }
            }
            // 0.7.0 — manual DDNS / WAN-host fallback. Per-
            // camera (not per-channel) but rendered here so
            // there's a single discoverable place to edit a
            // camera's network configuration. The field
            // applies to the camera entry as a whole; the
            // change takes effect on the next reconnect.
            cameraConnectionSection
        }
        .formStyle(.grouped)
        // 0.5.0 fix — key the load on the (camera, channel) pair so
        // switching cameras in the sidebar re-fetches OSD + AI
        // capability instead of leaving the previous camera's values
        // on screen. SwiftUI cancels the prior `.task` when the id
        // changes, then runs this body again with a fresh
        // implicit context.
        .task(id: SettingsLoadID(deviceID: session.entry.id, channel: channel.channel)) {
            // Reset per-channel state so the user sees a fresh
            // "Loading…" rather than the previous camera's values
            // while the new fetch is in flight.
            supportedAITypes = []
            privacyZones = PrivacyZoneEditorModel()
            privacyZonesDirty = false
            privacyBackground = nil
            loadPrivacyZones()                       // local cache
            // Kick the snapshot load in parallel with the OSD / AI
            // fetches; it's an independent network call so there's
            // no reason to serialize. Detached so the OSD fetch
            // below doesn't have to wait on a slow `cmd=Snap`.
            let backgroundLoad = Task { await loadPrivacyBackground() }
            await loadOsd()
            await loadSupportedAITypes()
            await loadPrivacyZonesFromCamera()       // camera truth (if supported)
            _ = await backgroundLoad.value
        }
    }

    /// 0.5.1 — Provide the privacy-zone editor with a real backdrop
    /// to draw on top of. Fast path reads from the
    /// `CameraPreviewService` JPEG cache (populated by the live
    /// player, the periodic prefetcher, or a previous render of
    /// `CameraPreviewImage`). Slow path falls back to a fresh
    /// `cmd=Snap` fetch, waking battery cameras first so the JPEG
    /// endpoint actually has a live camera to respond from.
    private func loadPrivacyBackground() async {
        if let cached = CameraPreviewService.shared.cachedData(
            cameraID: session.entry.id,
            channel: channel.channel
        ), let image = Self.makeBackground(from: cached) {
            privacyBackground = image
            return
        }
        isLoadingPrivacyBackground = true
        defer { isLoadingPrivacyBackground = false }
        // Wake battery / asleep cameras before hitting cmd=Snap.
        // Mirrors the prepare-for-fetch path that
        // `CameraPreviewImage` uses; without it the snap endpoint
        // returns nothing or a long-stale frame.
        if session.isBatteryPoweredOrAsleep(channel: channel.channel),
           let baichuan = session.baichuanClient {
            do {
                _ = try await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
            } catch {
                // 0.6.1 H-1 — categorize through AppError so the
                // BaichuanError(NWError(...)) chain's LAN-IP-bearing
                // string never reaches `AppErrorRecord.detail`.
                AppErrorRecorder.recordAsync(
                    AppError.categorizeBaichuanFailure(error),
                    context: "channelSettings.snapshotRefresh"
                )
            }
        }
        guard let url = await session.snapshotURL(channel: channel.channel) else { return }
        let bytes = await CameraPreviewService.shared.refresh(
            snapshotURL: url,
            cameraID: session.entry.id,
            channel: channel.channel
        )
        guard let bytes, let image = Self.makeBackground(from: bytes) else { return }
        privacyBackground = image
    }

    /// Decode raw JPEG bytes into the cross-platform
    /// `PrivacyZoneBackgroundImage` wrapper. The wrapper is a thin
    /// `NSImage` / `UIImage` shim — there is no SwiftUI `Image`
    /// initializer that accepts raw `Data`, so we go through the
    /// platform image type before re-wrapping.
    nonisolated private static func makeBackground(from data: Data) -> PrivacyZoneBackgroundImage? {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return nil }
        return PrivacyZoneBackgroundImage(uiImage: img)
        #elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return nil }
        return PrivacyZoneBackgroundImage(nsImage: img)
        #else
        return nil
        #endif
    }

    /// Composite identity used by `.task(id:)` so switching cameras
    /// OR channels both retrigger the OSD / AI fetch. The previous
    /// `.task` (no id) only ran once per `ChannelSettingsView`
    /// instance, which SwiftUI reuses across the sidebar's tab
    /// switches.
    private struct SettingsLoadID: Hashable {
        let deviceID: UUID
        let channel: Int
    }

    /// Reolink's `GetEvents` command on Home Hub Pro returns the channel's
    /// current AI alarm state, with `support: 0|1` per category indicating
    /// which detection types this specific camera supports. Surface that as
    /// informational capability tags.
    private func loadSupportedAITypes() async {
        let now = Date()
        let cmd = Commands.getEvents(channel: channel.channel, start: now.addingTimeInterval(-60), end: now)
        do {
            let raw = try await session.withBackgroundPollingPaused {
                try await session.client.sendCapturingRaw(cmd)
            }
            guard let obj = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]],
                  let value = obj.first?["value"] as? [String: Any] else { return }
            var supported: [DetectionType] = []
            if let ai = value["ai"] as? [String: Any] {
                for (key, sub) in ai {
                    if let dict = sub as? [String: Any],
                       (dict["support"] as? Int) == 1,
                       let d = DetectionType.fromReolinkString(key) {
                        supported.append(d)
                    }
                }
            }
            if let md = value["md"] as? [String: Any], (md["support"] as? Int) == 1 {
                supported.append(.motion)
            }
            if let visitor = value["visitor"] as? [String: Any], (visitor["support"] as? Int) == 1 {
                supported.append(.visitor)
            }
            supportedAITypes = supported.sorted { $0.rawValue < $1.rawValue }
        } catch {
            // Probe failure isn't fatal — just leave the section hidden.
        }
    }

    /// "Camera connection" — per-camera settings rendered
    /// alongside per-channel ones. Currently just the WAN
    /// fallback host; other camera-wide network settings can
    /// land here later.
    private var cameraConnectionSection: some View {
        Section {
            TextField("Remote address (optional)", text: $remoteHostDraft, prompt: Text("example.duckdns.org"))
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { saveRemoteHost() }
                .onChange(of: remoteHostDraft) { _, _ in
                    remoteHostIsDirty = (remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                         != (currentEntry?.remoteHost ?? ""))
                }
            HStack {
                Button {
                    showRemoteHostHelp.toggle()
                } label: {
                    Label(showRemoteHostHelp ? "Hide setup notes" : "How does this work?", systemImage: "info.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Save") {
                    saveRemoteHost()
                }
                .disabled(!remoteHostIsDirty)
            }
            if showRemoteHostHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reolens reaches your camera over the LAN by default. When you're away from home, it can dial a public hostname instead — typically a DDNS name (`duckdns.org`, Cloudflare, no-ip.com) that points at your router's WAN IP.")
                    Text("You'll need to forward the camera's ports on your router: 80/443 (HTTP/HTTPS for the API), 554 (RTSP for video), and 9000 (Baichuan, for events and battery info).")
                        .padding(.top, 2)
                    Text("Leave blank for LAN-only.")
                        .padding(.top, 2)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
        } header: {
            Text("Camera connection")
        }
        .onAppear { syncRemoteHostDraftFromStore() }
        // Re-sync when the entry mutates from elsewhere (iCloud
        // pushes, another window editing the same camera). The
        // store's @Observable conformance triggers a body
        // re-render; on each render we reconcile our draft if
        // the user isn't mid-edit.
        .onChange(of: store.cameras) { _, _ in
            if !remoteHostIsDirty { syncRemoteHostDraftFromStore() }
        }
    }

    /// The user's current `CameraEntry` from the store
    /// (resolved by id — the entry on `session` is a snapshot
    /// taken at session creation and may be stale).
    private var currentEntry: CameraEntry? {
        store.cameras.first(where: { $0.id == session.entry.id })
    }

    private func syncRemoteHostDraftFromStore() {
        remoteHostDraft = currentEntry?.remoteHost ?? ""
        remoteHostIsDirty = false
    }

    private func saveRemoteHost() {
        let trimmed = remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setRemoteHost(trimmed.isEmpty ? nil : trimmed, for: session.entry.id)
        // The store will normalise empties to nil. Reflect the
        // canonical value back into the draft so the dirty flag
        // clears even when the user typed whitespace-only.
        remoteHostDraft = currentEntry?.remoteHost ?? ""
        remoteHostIsDirty = false
    }

    @ViewBuilder
    private var osdToggles: some View {
        let binding = Binding<OsdSettings>(
            get: { osd ?? OsdSettings(channel: channel.channel) },
            set: { osd = $0 }
        )
        Toggle("Show camera name", isOn: Binding(
            get: { binding.wrappedValue.osdChannel?.isEnabled ?? false },
            set: { newValue in
                var copy = binding.wrappedValue
                var item = copy.osdChannel ?? OsdSettings.OsdItem(enable: 0)
                item.isEnabled = newValue
                copy.osdChannel = item
                binding.wrappedValue = copy
                Task { await persist(copy) }
            }
        ))
        if let name = osd?.osdChannel?.name {
            TextField("Camera name", text: Binding(
                get: { name },
                set: { newValue in
                    var copy = binding.wrappedValue
                    var item = copy.osdChannel ?? OsdSettings.OsdItem(enable: 1)
                    item.name = newValue
                    copy.osdChannel = item
                    binding.wrappedValue = copy
                }
            ), onCommit: {
                Task { await persist(binding.wrappedValue) }
            })
            .textFieldStyle(.roundedBorder)
        }
        Toggle("Show date / time", isOn: Binding(
            get: { binding.wrappedValue.osdTime?.isEnabled ?? false },
            set: { newValue in
                var copy = binding.wrappedValue
                var item = copy.osdTime ?? OsdSettings.OsdItem(enable: 0)
                item.isEnabled = newValue
                copy.osdTime = item
                binding.wrappedValue = copy
                Task { await persist(copy) }
            }
        ))
        if isSaving {
            HStack { ProgressView().controlSize(.small); Text("Saving…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func loadOsd() async {
        // 0.5.0 fix — was `guard osd == nil else { return }` which
        // short-circuited every reload after the first camera. The
        // sidebar reuses the ChannelSettingsView for every camera by
        // identity (SwiftUI sees the same view type), so switching
        // cameras left the previous camera's OSD on screen
        // indefinitely. The `.task(id:)` below now keyes on
        // `(session.entry.id, channel.channel)` so the load re-fires
        // on every camera switch; here we explicitly clear before
        // re-fetching so the user sees a "Loading…" spinner rather
        // than the stale toggles.
        osd = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let env = try await session.withBackgroundPollingPaused {
                try await session.client.send(
                    Commands.getOsd(channel: channel.channel),
                    as: OsdEnvelope.self
                )
            }
            osd = env.Osd
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func persist(_ settings: OsdSettings) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.withBackgroundPollingPaused {
                try await session.client.sendIgnoringValue(Commands.setOsd(settings))
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func batteryChargeLabel(for info: BaichuanBatteryInfo) -> String {
        if info.isCharging { return "Charging" }
        if info.isPluggedIn { return "Plugged in (\(info.chargeStatus))" }
        return info.chargeStatus.capitalized
    }

    /// 0.5.0 Theme C2 — write the working privacy-zone set back to
    /// the camera via `SetMask`, and also persist locally so the
    /// editor's state survives the next launch (the camera doesn't
    /// store the exact rectangle metadata in an addressable way that
    /// roundtrips perfectly across firmware versions). The local
    /// copy is the source of truth for the editor's display; the
    /// camera roundtrip is what actually masks the video.
    ///
    /// Firmware variability: not every Reolink build implements
    /// `SetMask`. `rspCode = -9` (notSupport) is treated as a soft
    /// failure: the zones still persist locally and `errorMessage`
    /// surfaces a clear notice. Anything else — bad-credentials,
    /// session-expired, transport — surfaces as a hard error and
    /// the dirty flag stays so the user can retry.
    fileprivate func persistPrivacyZones() async {
        isSaving = true
        defer { isSaving = false }
        let key = "com.reolens.privacyZones.\(session.entry.id.uuidString).\(channel.channel)"

        // Local copy first — never silently lose work.
        do {
            let data = try JSONEncoder().encode(privacyZones.zones)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            errorMessage = "Couldn't save privacy zones locally: \(error.localizedDescription)"
            return
        }

        // Build the camera-side mask payload. Zones already live in
        // normalized 0…1 space; Reolink `MaskArea` uses the same
        // origin (top-left) and units.
        let areas = privacyZones.zones.map { zone in
            MaskArea(x: zone.x, y: zone.y, w: zone.width, h: zone.height)
        }
        let mask = MaskSettings(channel: channel.channel, enable: areas.isEmpty ? 0 : 1, area: areas)
        do {
            try await session.withBackgroundPollingPaused {
                try await session.client.sendIgnoringValue(Commands.setMask(mask))
            }
            privacyZonesDirty = false
            errorMessage = nil
        } catch let cgi as CGIError where cgi.rspCode == CGIErrorCode.notSupport.rawValue {
            // Firmware doesn't implement SetMask. Local persistence
            // already happened — surface the limitation but treat
            // the zones as "saved (local only)".
            privacyZonesDirty = false
            errorMessage = "This camera's firmware doesn't accept privacy masks via API. Zones saved on this device but won't mask the video stream."
        } catch {
            errorMessage = "Couldn't apply privacy zones to camera: \(error.localizedDescription)"
        }
    }

    fileprivate func loadPrivacyZones() {
        let key = "com.reolens.privacyZones.\(session.entry.id.uuidString).\(channel.channel)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let zones = try? JSONDecoder().decode([PrivacyZone].self, from: data) else { return }
        privacyZones = PrivacyZoneEditorModel(zones: zones)
        privacyZonesDirty = false
    }

    /// 0.5.0 Theme C2 — pull privacy zones from the camera via
    /// `GetMask`. Falls back to the local UserDefaults copy when
    /// firmware doesn't implement the command, or when transport
    /// fails. Called from the same `.task(id:)` that loads OSD +
    /// AI capabilities so the panel reflects the camera's truth
    /// (when available) rather than the device-local cache.
    fileprivate func loadPrivacyZonesFromCamera() async {
        do {
            let env = try await session.client.send(
                Commands.getMask(channel: channel.channel),
                as: MaskEnvelope.self
            )
            let zones = env.Mask.area.map { area in
                PrivacyZone(x: area.x, y: area.y, width: area.w, height: area.h)
            }
            privacyZones = PrivacyZoneEditorModel(zones: zones)
            privacyZonesDirty = false
        } catch {
            // Firmware doesn't support, or transport failed. The
            // local UserDefaults copy (loaded by `loadPrivacyZones`)
            // is already in place — no UI churn.
        }
    }
}
