import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Single-channel live RTSP tile for iOS/iPadOS.
///
/// Ports the macOS `LiveCameraTile` to touch idioms:
/// - Tap (not double-click) expands to the rich single-camera view.
/// - Long-press surfaces the same context menu that right-click does on macOS.
/// - Battery / sleeping cameras require an explicit "Connect" tap; we do
///   not auto-stream them, to preserve battery (iPhones AND camera battery).
/// - Auto-rotation correction for portrait-encoded streams is computed
///   per-player from the decoded frame's natural size, exactly as on
///   macOS — dual-lens cameras need this because main/sub can be
///   encoded at different native orientations.
struct LiveTileView: View {
    let session: CameraSession
    let channel: ChannelStatus
    let stream: StreamKind
    var autoStart: Bool = true
    var onTap: (() -> Void)? = nil
    /// Pause this tile (stop its RTSP session). Used by the parent to
    /// avoid running two concurrent sessions to the same channel when a
    /// fullscreen detail is open — Reolink hubs cap concurrent sessions
    /// and silently drop one after a few seconds.
    var paused: Bool = false
    /// Invoked whenever the tile's internal `LiveVideoPlayer` is
    /// created (or nilled). Used by `SingleChannelView` to wire the
    /// player into a Picture-in-Picture controller. Defaults to nil for
    /// the grid-tile case where PiP is not surfaced.
    var onPlayerChanged: ((LiveVideoPlayer?) -> Void)? = nil
    /// When true, render a cached still preview instead of starting an
    /// RTSP stream. Default is false. Grid surfaces pass `true` to
    /// honor the 0.4.0 static-preview default; single-channel and
    /// fullscreen views keep `false`.
    var preferPreview: Bool = false
    /// Center-crop the preview-mode snapshot to fill the cell instead
    /// of letterboxing. Fixed N×N grids set this for dual-lens
    /// channels so a 32:9 stitched snapshot doesn't render as a thin
    /// strip in a 16:9 cell. Adaptive grid gives dual-lens cells their
    /// own 32:9 aspect, so it leaves this false.
    var centerCropPreview: Bool = false
    /// 0.5.1 — When true, always render the camera-name glass badge
    /// regardless of the user's "Show camera name on live feed"
    /// setting. Set by multi-channel grid call sites so users can
    /// tell tiles apart at a glance; single-camera detail views pass
    /// false because the camera name is already in the toolbar / nav
    /// title and the badge would just collide with the camera's
    /// own OSD timestamp.
    var forcesNameBadge: Bool = false

    @Environment(CameraStore.self) private var store
    @State private var player: LiveVideoPlayer?
    @State private var didStart = false
    @State private var isVisible = false
    /// Brief HUD shown after a snapshot completes. nil = no HUD.
    @State private var snapshotHUD: SnapshotHUDState?
    /// 0.5.1 — drives the visual feedback while a one-tap battery-camera
    /// wake is in flight. The Baichuan wake call lands a few seconds
    /// before `player.state` flips off `.connecting`, and without an
    /// explicit indicator users double-tap thinking nothing happened.
    @State private var isWaking = false

    var body: some View {
        let userRotation = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
        let autoCorrection = portraitCorrection(for: player?.naturalSize)
        let rotation = ((userRotation + autoCorrection) % 360 + 360) % 360
        let isBatteryIdle = (channel.isAsleep || session.isBatteryPowered(channel: channel.channel)) && player == nil

        ZStack(alignment: .topLeading) {
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
                        // before hitting cmd=Snap. Battery cams go back
                        // to sleep on their own after the briefest of
                        // wakes — same flow startPlayer() uses for
                        // live view.
                        let (asleep, baichuan) = await MainActor.run {
                            (session.isBatteryPoweredOrAsleep(channel: channelID),
                             session.baichuanClient)
                        }
                        guard asleep, let baichuan else { return }
                        do {
                            _ = try await baichuan.wakeBatteryCamera(channelID: UInt8(channelID))
                        } catch {
                            AppErrorRecorder.recordAsync(
                                .other("batteryWakeFailed: \(error.localizedDescription)"),
                                context: "liveTileView.sleepingOverlayTap"
                            )
                        }
                    },
                    centerCrop: centerCropPreview
                )
            } else if isBatteryIdle {
                sleepingOverlay
            } else if let player {
                if case .failed(let msg) = player.state {
                    // Fall back to the cached snapshot when the
                    // player fails — typically the hub's concurrent
                    // RTSP cap is full while the user flips Live on
                    // a many-camera grid. The cached still is a far
                    // better fallback than a red error block over an
                    // otherwise-fine tile.
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
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                manualStartOverlay
            }
            // 0.5.1 — grid call sites force the badge for tile
            // legibility; single-camera detail views respect the
            // global "Show camera name on live feed" setting.
            if forcesNameBadge || !store.isAppBadgeHidden(deviceID: session.entry.id, channel: channel.channel) {
                badgeRow
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .contentShape(.rect)
        .onTapGesture {
            // 0.5.1 tap routing:
            // - **Grid tiles** (`onTap` set by the grid) — always
            //   call through so a tap opens the single-camera
            //   detail. SingleChannelView's own LiveTileView (with
            //   no `onTap`) takes care of waking the battery camera
            //   once it appears.
            // - **Single-camera tile** (no `onTap`) — wake in place.
            //   The user is already on the camera; there's nowhere
            //   else to navigate.
            if let onTap {
                onTap()
            } else if isBatteryIdle, !isWaking {
                Task { await wakeAndStart() }
            }
        }
        .contextMenu {
            Button {
                store.rotateClockwise(deviceID: session.entry.id, channel: channel.channel, stream: stream)
            } label: {
                let current = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
                Label("Rotate \(streamLabel) feed (\(current)°)", systemImage: "rotate.right")
            }
            if store.primaryChannel(for: session.entry.id) != channel.channel {
                Button {
                    store.setPrimary(
                        deviceID: session.entry.id,
                        channel: channel.channel,
                        allChannels: session.liveChannels
                    )
                } label: {
                    Label("Make primary", systemImage: "star.fill")
                }
            }
            Divider()
            Button {
                Task { await saveSnapshot() }
            } label: {
                Label("Save Snapshot", systemImage: "camera.fill")
            }
            .disabled(player == nil)
            Divider()
            Button {
                // Drops the existing session and force-rebuilds it.
                // Use when a camera sticks on "Connecting…" — usually
                // a rotated session token or a Wi-Fi blip.
                store.reconnect(session.entry.id)
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise.circle")
            }
        }
        .overlay(alignment: .bottom) {
            if let snapshotHUD {
                Text(snapshotHUD.text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    // 0.5.0 Liquid Glass — Save-Snapshot HUD reads
                    // as a tinted glass toast rather than a 90 %
                    // opaque pill.
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(snapshotHUD.tint.opacity(0.55)), in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: snapshotHUD)
        .onAppear {
            isVisible = true
        }
        .task(id: channel.channel) {
            guard !preferPreview, autoStart, !didStart, !paused else { return }
            let needsWake = channel.isAsleep || session.isBatteryPowered(channel: channel.channel)
            if needsWake {
                // 0.6.0 — single-camera tiles (no `onTap`) auto-wake
                // battery / sleeping cameras when the user navigates
                // in. The tap-to-open-detail was already an explicit
                // "I want to see this camera" signal; requiring a
                // second tap on the sleeping-overlay was friction
                // users surfaced. Grid tiles still skip the wake
                // path (`onTap != nil`) because firing a Baichuan
                // wake for every battery cam on grid render would
                // burn battery for tiles the user never looked at.
                guard onTap == nil else { return }
                await wakeAndStart()
                return
            }
            await startPlayer()
        }
        .onChange(of: rotation) { _, newValue in
            player?.rotationDegrees = newValue
        }
        .onChange(of: player?.naturalSize) { _, size in
            // Self-learn dual-lens cameras. Stitched dual-lens frames have a
            // long-side/short-side ratio of ~32:9 ≈ 3.55, well above
            // landscape 16:9 ≈ 1.78. Persist the override so the per-channel
            // grid layout knows to give this tile a wider aspect.
            guard let size, size.width > 0, size.height > 0 else { return }
            // Capture a preview from the freshly-decoded live frame.
            // The parallel VT decode that populates `latestPixelBuffer`
            // lands a beat after `naturalSize` flips non-nil, so we
            // poll on a short delay instead of racing the decode.
            capturePreviewWhenReady()
            let ratio = max(size.width, size.height) / min(size.width, size.height)
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
                // when `paused` flips off — same fix as macOS.
                Task {
                    await startPlayer()
                }
            }
        }
        // Flipping the grid Stills/Live toggle must take effect on
        // every tile already on screen. `.task(id: channel.channel)`
        // alone doesn't re-fire because the channel hasn't changed.
        .onChange(of: preferPreview) { _, nowPreview in
            if nowPreview {
                player?.stop()
                player = nil
                didStart = false
            } else if autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart, !paused {
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
            onPlayerChanged?(nil)
        }
        .onChange(of: player == nil) { _, _ in
            onPlayerChanged?(player)
        }
    }

    /// Compact "live unavailable" badge shown over the cached
    /// preview when the RTSP player fails. Tap to retry — the hub's
    /// concurrent-session cap may have relaxed (another tile closed
    /// a stream). The detailed error is in the help tooltip / context
    /// menu so users who care can still inspect it; covering the
    /// whole tile with a red error block over a perfectly good
    /// cached snapshot was the previous, worse experience.
    private func liveUnavailableOverlay(error message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(liveFailureTitle(error: message))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                Button {
                    Task {
                        player?.stop()
                        player = nil
                        didStart = false
                        await startPlayer()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry live stream")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // 0.5.0 Liquid Glass — failure-overlay action pill.
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
        // this context. Grid tiles (with `onTap`) open the single-
        // camera view; the single-camera tile wakes in place.
        let hint: String = {
            if onTap != nil {
                return isBattery ? "Tap to open & wake." : "Tap to open."
            }
            return isBattery ? "Tap to wake & connect." : "Tap to connect."
        }()
        return VStack(spacing: 10) {
            if isWaking {
                ProgressView().tint(.white)
                Text("Waking…")
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: isBattery ? "battery.50" : "moon.zzz.fill").font(.title2)
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
        VStack(spacing: 10) {
            Image(systemName: "play.circle").font(.title2)
            Button("Connect") { Task { await startPlayer() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: channel.isAsleep ? "moon.zzz" : "video.fill")
            Text(channel.name ?? "Channel \(channel.channel + 1)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if session.motionState[channel.channel] == true {
                Image(systemName: "figure.walk.motion").foregroundStyle(.yellow)
            }
            if session.aiTriggered[channel.channel] == true {
                Image(systemName: "sparkles").foregroundStyle(.green)
            }
        }
        .foregroundStyle(.primary)
        // 0.5.0 Liquid Glass — name + motion/AI indicator pill on the
        // live tile. AGENTS.md §1 (platform parity): same modifier as
        // the macOS twin.
        .reolensGlassBadge()
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

    /// One-tap wake helper for battery / sleeping cameras (0.5.1).
    /// Wraps `startPlayer()` with an `isWaking` flag so the overlay
    /// can show "Waking…" while the Baichuan wake call is in flight
    /// and duplicate taps are debounced.
    private func wakeAndStart() async {
        guard !isWaking else { return }
        isWaking = true
        await startPlayer()
        isWaking = false
    }

    private func startPlayer() async {
        // Belt-and-suspenders preview-mode guard. Same rationale as
        // macOS: no RTSP from grid tiles unless the user has opted in
        // to live grids.
        if preferPreview || !isVisible { return }
        if player != nil {
            didStart = true
            return
        }
        guard !didStart else { return }
        didStart = true
        // Rate-limit concurrent RTSP starts so a 16-tile grid flipping
        // Stills → Live doesn't open 16 sessions in parallel and trip
        // the hub's concurrency cap.
        guard await LivePlayerStartGate.shared.acquire() else {
            didStart = false
            return
        }
        if preferPreview || !isVisible {
            didStart = false
            return
        }
        if session.isBatteryPowered(channel: channel.channel) || channel.isAsleep,
           let baichuan = session.baichuanClient {
            do {
                _ = try await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
            } catch {
                AppErrorRecorder.recordAsync(
                    .other("batteryWakeFailed: \(error.localizedDescription)"),
                    context: "liveTileView.startPlayer"
                )
            }
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
        let rotation = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
        let p = LiveVideoPlayer(
            urls: urls,
            username: credentials.username,
            password: credentials.password,
            rotationDegrees: rotation
        )
        self.player = p
        p.start()
    }

    private func portraitCorrection(for size: CGSize?) -> Int {
        guard let size, size.width > 0, size.height > 0 else { return 0 }
        return size.height > size.width ? 90 : 0
    }

    private var streamLabel: String {
        switch stream {
        case .main: "main"
        case .sub: "preview"
        case .ext: "ext"
        }
    }

    /// Delayed capture of `player.currentSnapshot()` into the preview
    /// cache. The first decoded frame's pixel buffer arrives shortly
    /// after `naturalSize` flips non-nil; polling a few times handles
    /// the race without spin-waiting.
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
        await MainActor.run {
            snapshotHUD = SnapshotHUDState(result: result)
        }
        try? await Task.sleep(for: .seconds(2))
        await MainActor.run {
            snapshotHUD = nil
        }
    }
}

/// Brief HUD shown over a tile after a snapshot completes. Driven by an
/// optional `@State` so SwiftUI's transition wraps the show/hide.
struct SnapshotHUDState: Equatable {
    let text: String
    let tint: Color

    init(result: SnapshotSaver.Result) {
        switch result {
        case .saved:
            self.text = "Saved to Photos"
            self.tint = .green
        case .denied:
            self.text = "Photos access denied"
            self.tint = .orange
        case .noFrame:
            self.text = "Camera still connecting"
            self.tint = .gray
        case .failed(let msg):
            self.text = "Save failed: \(msg)"
            self.tint = .red
        }
    }
}
