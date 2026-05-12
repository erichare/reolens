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

    @Environment(CameraStore.self) private var store
    @State private var player: LiveVideoPlayer?
    @State private var didStart = false
    /// Brief HUD shown after a snapshot completes. nil = no HUD.
    @State private var snapshotHUD: SnapshotHUDState?

    var body: some View {
        let userRotation = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
        let autoCorrection = portraitCorrection(for: player?.naturalSize)
        let rotation = ((userRotation + autoCorrection) % 360 + 360) % 360
        let isBatteryIdle = (channel.isAsleep || session.isBatteryPowered(channel: channel.channel)) && player == nil

        ZStack(alignment: .topLeading) {
            Color.black
            if isBatteryIdle {
                sleepingOverlay
            } else if let player {
                LiveVideoView(player: player, rotationDegrees: rotation)
                if case .failed(let msg) = player.state {
                    overlay(message: msg, systemImage: "exclamationmark.triangle.fill", tint: .red)
                } else if player.state == .connecting {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if autoStart {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                manualStartOverlay
            }
            badgeRow
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .contentShape(.rect)
        .onTapGesture { onTap?() }
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
        }
        .overlay(alignment: .bottom) {
            if let snapshotHUD {
                Text(snapshotHUD.text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(snapshotHUD.tint.opacity(0.9), in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: snapshotHUD)
        .task(id: channel.channel) {
            guard autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart, !paused else { return }
            didStart = true
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
            } else if autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart {
                Task {
                    didStart = true
                    await startPlayer()
                }
            }
        }
        .onDisappear {
            player?.stop()
            player = nil
            didStart = false
            onPlayerChanged?(nil)
        }
        .onChange(of: player == nil) { _, _ in
            onPlayerChanged?(player)
        }
    }

    private var sleepingOverlay: some View {
        let isBattery = session.isBatteryPowered(channel: channel.channel)
        return VStack(spacing: 10) {
            Image(systemName: isBattery ? "battery.50" : "moon.zzz.fill").font(.title2)
            Text(isBattery ? "Battery camera" : "Sleeping")
                .font(.caption.weight(.medium))
            if isBattery {
                Text("Not auto-streamed to save battery.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            Button("Connect") { Task { await startPlayer() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
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
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
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

    private func startPlayer() async {
        if player != nil { return }
        didStart = true
        if session.isBatteryPowered(channel: channel.channel) || channel.isAsleep,
           let baichuan = session.baichuanClient {
            _ = try? await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
        }
        let credentials = await session.client.credentials
        let urls = StreamURLs(credentials: credentials).candidatesForLive(
            channel: channel.channel,
            stream: stream
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
