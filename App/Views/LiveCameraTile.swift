import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Live RTSP-backed tile.
///
/// - Sleeping (battery) cameras are NOT auto-started: they show a "Wake & connect"
///   button. Waking would route a Baichuan push to the hub — for now, tapping just
///   tries the RTSP connection in case the camera is actually awake.
/// - Tap-to-expand opens a full-window rich viewer with PTZ + metadata.
struct LiveCameraTile: View {
    let session: CameraSession
    let channel: ChannelStatus
    let stream: StreamKind
    var autoStart: Bool = true
    var onTap: (() -> Void)? = nil
    /// Optional explicit rotation override. If nil, the tile reads from CameraStore.
    var rotationDegrees: Int? = nil
    /// When true, stops any running player and prevents auto-start. Used to
    /// avoid running two RTSP sessions to the same channel when the rich
    /// viewer is open — Reolink's hub silently drops one after a few seconds.
    var paused: Bool = false
    /// Optional callback invoked from the context menu's "Update Password…"
    /// item. When nil, the item is hidden. Wired up by parent views that
    /// own the password-entry sheet state.
    var onEnterPassword: (() -> Void)? = nil
    /// When true, render a cached still preview instead of starting an
    /// RTSP stream. Default is false — matches the existing live-tile
    /// behavior. Grid surfaces pass `true` to honor the 0.4.0 static-
    /// preview default; single-channel and fullscreen views keep `false`
    /// because the user explicitly asked to see live video there.
    var preferPreview: Bool = false
    /// When true, the preview-mode cached snapshot center-crops to fill
    /// the cell instead of letterboxing. Fixed N×N grids set this for
    /// dual-lens channels so a 32:9 stitched snapshot doesn't render
    /// as a thin horizontal strip with huge black bars in a 16:9 cell.
    /// Adaptive grids give dual-lens cells their own 32:9 aspect ratio
    /// so this can stay false there.
    var centerCropPreview: Bool = false
    /// 0.5.1 — When true, always render the camera-name glass badge
    /// regardless of the user's "Show camera name on live feed"
    /// setting. Set by multi-channel grid call sites so users can
    /// tell tiles apart at a glance; single-camera detail views pass
    /// false because the camera name is already in the toolbar / tab
    /// header, and the badge would just collide with the camera's
    /// own OSD timestamp.
    var forcesNameBadge: Bool = false

    @Environment(CameraStore.self) private var store
    @State private var player: LiveVideoPlayer?
    @State private var didStart = false
    @State private var isVisible = false
    /// 0.5.1 — drives the visual feedback while a battery-camera wake is
    /// in flight from a one-tap sleeping-tile tap. Distinct from
    /// `didStart` (which races the RTSP probe) because the Baichuan wake
    /// call lands several seconds before `player.state` flips off
    /// `.connecting`, and the user otherwise sees a frozen sleeping
    /// overlay during that window and double-taps thinking nothing
    /// happened.
    @State private var isWaking = false

    var body: some View {
        // Effective rotation has two parts:
        //   1. The user's persisted rotation (manual physical-camera fix).
        //      Shared across all streams from this channel.
        //   2. An auto portrait→landscape correction. Reolink encodes some
        //      cameras' sub stream in portrait but the main stream in
        //      landscape (or vice versa), so applying the same persisted
        //      rotation to both would put one of them sideways. Computing
        //      the correction from THIS player's `naturalSize` gives the
        //      same visual result regardless of which stream the host
        //      chose to display.
        //
        // We read both pieces in the body so SwiftUI's @Observable tracking
        // picks them up — `naturalSize` becomes non-nil after the first
        // decoded frame and we want the view to re-layout at that point.
        let userRotation = rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
        let autoCorrection = portraitCorrection(for: player?.naturalSize)
        let rotation = ((userRotation + autoCorrection) % 360 + 360) % 360

        let isBatteryIdle = (channel.isAsleep || session.isBatteryPowered(channel: channel.channel)) && player == nil
        return ZStack(alignment: .topLeading) {
            Color.black

            if preferPreview {
                CameraPreviewImage(
                    cameraID: session.entry.id,
                    cameraName: session.entry.displayName,
                    channel: channel.channel,
                    snapshotURLProvider: { [session, channelID = channel.channel] in
                        await session.snapshotURL(channel: channelID)
                    },
                    prepareForFetch: { [session, channelID = channel.channel] in
                        // Wake battery / sleeping cameras over Baichuan
                        // before hitting cmd=Snap. Without this, the
                        // JPEG endpoint either times out or returns a
                        // long-stale frame because the camera is offline
                        // at the radio layer. Battery cams go back to
                        // sleep on their own after the briefest of
                        // wakes — same flow startPlayer() uses for
                        // live view.
                        let (asleep, baichuan) = await MainActor.run {
                            (session.isBatteryPoweredOrAsleep(channel: channelID),
                             session.baichuanClient)
                        }
                        guard asleep, let baichuan else { return }
                        _ = try? await baichuan.wakeBatteryCamera(channelID: UInt8(channelID))
                    },
                    centerCrop: centerCropPreview
                )
            } else if isBatteryIdle {
                sleepingOverlay
            } else if let player {
                if case .failed(let msg) = player.state {
                    // Fall back to the cached snapshot instead of
                    // blanking the tile with a red error block.
                    // Reolink hubs cap concurrent RTSP sessions per
                    // device, so when the user toggles live mode on a
                    // many-camera hub some tiles legitimately fail to
                    // start until other sessions free up — those
                    // tiles still have a recent cached preview that's
                    // a better fallback than raw error text.
                    CameraPreviewImage(
                        cameraID: session.entry.id,
                        cameraName: session.entry.displayName,
                        channel: channel.channel,
                        snapshotURLProvider: { [session, channelID = channel.channel] in
                            await session.snapshotURL(channel: channelID)
                        },
                        centerCrop: centerCropPreview
                    )
                    liveUnavailableOverlay(error: msg)
                } else {
                    LiveVideoView(player: player, rotationDegrees: rotation)
                    if player.state == .connecting {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if autoStart {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                manualStartOverlay
            }

            // 0.5.1 — multi-channel-grid call sites force the badge
            // so the user can tell tiles apart. Single-camera detail
            // views pass `forcesNameBadge: false` and respect the
            // global "Show camera name on live feed" setting.
            if forcesNameBadge || !store.isAppBadgeHidden(deviceID: session.entry.id, channel: channel.channel) {
                badgeRow
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .contentShape(.rect)
        .onTapGesture {
            // 0.5.1 tap routing:
            // - **Grid tiles** (`onTap` set by the grid's parent) —
            //   always call through so a tap opens the rich viewer.
            //   The rich viewer's own `startPlayer` handles waking
            //   battery cameras, so the user gets a live feed without
            //   a second tap. The prior version intercepted battery-
            //   idle taps for an in-place wake and never opened the
            //   rich viewer, which read as "the tile won't click."
            // - **Single-camera tile** (`onTap` is nil because it's
            //   the only thing on screen) — still wakes in place,
            //   which is the only sensible action when there's no
            //   parent view to navigate to.
            if let onTap {
                onTap()
            } else if isBatteryIdle, !isWaking {
                Task { await wakeAndStart() }
            }
        }
        // Right-click → context menu. The rotate action persists per-stream
        // so the grid preview (sub) and rich-viewer main feed can land at
        // independent orientations — useful for dual-lens cameras where
        // Reolink encodes the two streams at different native rotations.
        .contextMenu {
            // "Make primary" promotes this tile to the spotlight slot in
            // the multi-channel grid (the big top-left tile in the
            // Spotlight layout). Hidden when the tile is already primary
            // to avoid offering a no-op.
            if store.primaryChannel(for: session.entry.id) != channel.channel {
                Button {
                    store.setPrimary(
                        deviceID: session.entry.id,
                        channel: channel.channel,
                        allChannels: session.liveChannels
                    )
                } label: {
                    Label("Make primary (spotlight)", systemImage: "star.fill")
                }
                Divider()
            }
            Button {
                store.rotateClockwise(deviceID: session.entry.id, channel: channel.channel, stream: stream)
            } label: {
                let current = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
                Label("Rotate \(streamLabel) feed (\(current)°)", systemImage: "rotate.right")
            }
            Divider()
            Button {
                Task { await saveSnapshot() }
            } label: {
                Label("Save Snapshot…", systemImage: "camera.fill")
            }
            .disabled(player == nil)
            Divider()
            Button {
                // Drops the existing session and force-rebuilds it.
                // Use when a hub sticks on "Connecting…" indefinitely
                // — usually a rotated session token or a LAN blip.
                store.reconnect(session.entry.id)
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise.circle")
            }
            if let onEnterPassword {
                Divider()
                Button {
                    onEnterPassword()
                } label: {
                    Label("Update Password…", systemImage: "key.fill")
                }
            }
        }
        .onAppear {
            isVisible = true
        }
        .task(id: channel.channel) {
            guard !preferPreview, autoStart, !didStart, !paused else { return }
            let needsWake = channel.isAsleep || session.isBatteryPowered(channel: channel.channel)
            if needsWake {
                // 0.6.0 — mirror of the iOS auto-wake. Single-camera
                // detail tiles (`onTap == nil`) wake on appear; grid
                // tiles (`onTap != nil`) skip the wake to avoid
                // burning battery cams on Live-grid render. See the
                // iOS LiveTileView comment for the rationale.
                guard onTap == nil else { return }
                await wakeAndStart()
                return
            }
            await startPlayer()
        }
        .onChange(of: rotation) { _, newValue in
            player?.rotationDegrees = newValue
        }
        // Self-learn dual-lens cameras. Reolink's `GetChannelstatus` doesn't
        // include `typeInfo` for some paired models (notably Argus 4 Pro),
        // so we can't reliably classify them from the camera list — but
        // the stream's long-side / short-side ratio is a reliable signal
        // (dual-lens stitched frames are ~32:9 ≈ 3.55, well above 16:9 = 1.78).
        //
        // NOTE: we deliberately do NOT persist a portrait→landscape rotation
        // to the store here. Sub and main streams from the same camera can
        // have different native orientations, and a stored rotation would
        // apply equally to both, breaking one of them. The portrait
        // correction is computed per-player in `portraitCorrection(...)`
        // from THIS view's stream, so each tile picks the right rotation
        // for its own decoded frame size.
        .onChange(of: player?.naturalSize) { _, size in
            guard let size, size.width > 0, size.height > 0 else { return }
            // Opportunistically refresh the preview cache from a
            // freshly-decoded live frame. `naturalSize` becomes
            // non-nil the moment the first sample is enqueued, but
            // `currentSnapshot()` reads from a *parallel* VT decode
            // session whose pixel buffer arrives ~half a second to a
            // few seconds later. Polling on a short delay handles the
            // race without a fragile spin loop. AGENTS.md §7: cache
            // only, never persisted to iCloud.
            capturePreviewWhenReady()
            let longSide = max(size.width, size.height)
            let shortSide = min(size.width, size.height)
            let ratio = longSide / shortSide
            guard ratio >= 2.0 else { return }
            let alreadyMarked = store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel) || channel.isDualLens
            if !alreadyMarked {
                store.setDualLensOverride(true, deviceID: session.entry.id, channel: channel.channel)
            }
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                player?.stop()
                player = nil
                didStart = false
            } else if !preferPreview, autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart {
                // Preview-mode tiles must never auto-resume the player
                // when `paused` flips off — that's the path that made
                // grids briefly stream live after a rich-viewer close
                // even with the static-preview toggle on.
                Task {
                    await startPlayer()
                }
            }
        }
        // Flipping the grid Stills/Live toggle must actually take
        // effect on every tile already on screen — without an explicit
        // observer here, `.task(id: channel.channel)` doesn't re-fire
        // (channel hasn't changed), so the user would see the toggle
        // flip but the tiles would stay frozen on the cached snapshot.
        .onChange(of: preferPreview) { _, nowPreview in
            if nowPreview {
                // Switched to Stills — tear down any running player so
                // we stop holding an RTSP session against the hub's
                // concurrency cap.
                player?.stop()
                player = nil
                didStart = false
            } else if autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart, !paused {
                // Switched to Live — start the player if eligible.
                // Eligibility mirrors the `.task` guards above.
                Task {
                    await startPlayer()
                }
            }
        }
        .onDisappear {
            isVisible = false
            player?.stop()
            player = nil
            didStart = false
        }
    }

    /// Compact "live unavailable" badge shown over the cached preview
    /// when the RTSP player fails to start. Tapping retries — useful
    /// when the hub's concurrent-session cap relaxes (another tile
    /// closes a stream) and a re-attempt would succeed. The detailed
    /// error message is in the context menu so users who care about
    /// diagnostics can still inspect it without it covering the tile.
    private func liveUnavailableOverlay(error message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(liveFailureTitle(error: message))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                if authenticationFailureIsLikely(error: message), let onEnterPassword {
                    Button {
                        onEnterPassword()
                    } label: {
                        Label("Update Password", systemImage: "key.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Update Password")
                }
                Button {
                    Task {
                        player?.stop()
                        player = nil
                        didStart = false
                        await startPlayer()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(message)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // 0.5.0 Liquid Glass — failure-overlay action pill stays
            // legible without an opaque shell.
            .glassEffect(.regular, in: .capsule)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveFailureTitle(error message: String) -> String {
        authenticationFailureIsLikely(error: message) ? "Check password" : "Live unavailable"
    }

    private func authenticationFailureIsLikely(error message: String) -> Bool {
        if case .failed(let reason) = session.connectionStage {
            let lowered = reason.lowercased()
            if lowered.contains("auth") || lowered.contains("password") {
                return true
            }
        }
        let lowered = message.lowercased()
        return lowered.contains("auth")
            || lowered.contains("401")
            || lowered.contains("unauthorized")
            || lowered.contains("password")
    }

    private var sleepingOverlay: some View {
        let isBattery = session.isBatteryPowered(channel: channel.channel)
        // 0.5.1 — hint text reflects what the tap actually does in
        // this context. Grid tiles (with `onTap`) open the rich
        // viewer; single-camera tiles wake in place.
        let hint: String = {
            if onTap != nil {
                return isBattery ? "Tap to open & wake." : "Tap to open."
            }
            return isBattery ? "Tap to wake & connect." : "Tap to connect."
        }()
        return VStack(spacing: 8) {
            if isWaking {
                ProgressView().controlSize(.small)
                Text("Waking…")
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: isBattery ? "battery.50" : "moon.zzz.fill").font(.title)
                Text(isBattery ? "Battery camera" : "Sleeping")
                    .font(.caption.weight(.medium))
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var manualStartOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle").font(.title)
            Button("Connect") {
                Task { await startPlayer() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var badgeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: channel.isAsleep ? "moon.zzz" : "video.fill")
                Text(channel.name ?? "Channel \(channel.channel + 1)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if session.motionState[channel.channel] == true {
                    Image(systemName: "figure.walk.motion").foregroundStyle(.yellow)
                }
                if session.aiTriggered[channel.channel] == true {
                    Image(systemName: "sparkles").foregroundStyle(.green)
                }
            }
            .foregroundStyle(.primary)
            // 0.5.0 Liquid Glass — name + motion/AI indicator pill on
            // the live tile. Adapts to whatever the camera frame
            // currently shows instead of a fixed 45 % black tint.
            .reolensGlassBadge()
        }
        .padding(8)
    }

    private func overlay(message: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title3)
            ScrollView {
                Text(message)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
            }
            .frame(maxHeight: 200)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var effectiveRotation: Int {
        rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
    }

    /// Schedule a delayed capture of `player.currentSnapshot()` into the
    /// preview cache. The first decoded frame's pixel buffer lands a
    /// beat after `naturalSize` flips non-nil — so we poll a few times
    /// before giving up rather than racing the parallel VT decode.
    private func capturePreviewWhenReady() {
        let cameraID = session.entry.id
        let channelID = channel.channel
        // 0.5.0: hand the camera + channel name to the publisher so
        // widgets get a human-readable label alongside the snapshot.
        let cameraName: String = {
            let channelName = (channel.name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            return channelName ?? session.entry.displayName
        }()
        Task { @MainActor in
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                guard let cgImage = player?.currentSnapshot() else { continue }
                Task.detached(priority: .utility) {
                    await CameraPreviewService.shared.storeFromLiveAndPublishToWidget(
                        cgImage: cgImage,
                        cameraID: cameraID,
                        channel: channelID,
                        cameraName: cameraName
                    )
                }
                return
            }
        }
    }

    private func saveSnapshot() async {
        guard let player else { return }
        let image = player.currentSnapshot()
        let name = "\(session.entry.displayName)-ch\(channel.channel + 1)"
        let result = await SnapshotSaver.save(image, cameraName: name)
        if case .saved(let url) = result, let url {
            // Reveal the new file in Finder so the user immediately sees
            // where it landed — far less surprising than a silent save.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// One-tap wake helper for battery / sleeping cameras. Surfaces a
    /// "Waking…" indicator over the sleeping overlay while the Baichuan
    /// wake call completes, debouncing duplicate taps until the player
    /// is running.
    private func wakeAndStart() async {
        guard !isWaking else { return }
        isWaking = true
        await startPlayer()
        isWaking = false
    }

    private func startPlayer() async {
        // Belt-and-suspenders: even if a caller bypasses the `.task`
        // guard (e.g., from `.onChange(of: paused)` or a future manual
        // "Connect" wire-up), preview mode tiles must never spin up an
        // RTSP session. The whole point of preview mode is no live
        // streaming until the user opens a single-channel view.
        if preferPreview || !isVisible { return }
        if player != nil {
            didStart = true
            return
        }
        guard !didStart else { return }
        didStart = true
        // Rate-limit concurrent RTSP starts so a 16-tile grid flipping
        // Stills → Live doesn't open 16 sessions in parallel and trip
        // the hub's concurrency cap. Tiles still go live progressively
        // (~500 ms apart) rather than all-or-nothing.
        guard await LivePlayerStartGate.shared.acquire() else {
            didStart = false
            return
        }
        // Re-check `preferPreview` after the gate wait — the user may
        // have flipped Live → Stills while we were queued.
        if preferPreview || !isVisible {
            didStart = false
            return
        }
        // For battery cameras, poke the hub via Baichuan first to wake the
        // sleeping camera. If we go straight to RTSP, the camera won't
        // respond because it's offline at the radio layer.
        if session.isBatteryPowered(channel: channel.channel) || channel.isAsleep, let baichuan = session.baichuanClient {
            _ = try? await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
        }
        let credentials = await session.client.credentials
        if preferPreview || !isVisible {
            didStart = false
            return
        }
        let urls = StreamURLs(credentials: credentials).candidatesForLive(
            channel: channel.channel,
            stream: stream,
            preferredCodec: session.entry.preferredCodec
        )
        let rotation = rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
        let p = LiveVideoPlayer(
            urls: urls,
            username: credentials.username,
            password: credentials.password,
            rotationDegrees: rotation
        )
        self.player = p
        p.start()
    }

    /// Auto-rotation correction for a portrait-oriented decoded stream.
    /// Returns 90° when the natural frame is taller than wide, 0° otherwise
    /// (and 0° while `naturalSize` is still unknown — i.e. before the first
    /// frame decodes). Combined with the user's persisted rotation in the
    /// body to produce the effective rotation actually applied to the layer.
    private func portraitCorrection(for size: CGSize?) -> Int {
        guard let size, size.width > 0, size.height > 0 else { return 0 }
        return size.height > size.width ? 90 : 0
    }

    /// User-facing label for the current stream. Used in the context-menu
    /// title so the user can tell which feed they're about to rotate.
    private var streamLabel: String {
        switch stream {
        case .main: "main"
        case .sub: "preview"
        case .ext: "ext"
        }
    }
}
