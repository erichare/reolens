import SwiftUI
import ReolinkAPI
import ReolinkStreaming

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

    @Environment(CameraStore.self) private var store
    @State private var player: LiveVideoPlayer?
    @State private var didStart = false

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
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                manualStartOverlay
            }

            badgeRow
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .contentShape(.rect)
        .onTapGesture {
            onTap?()
        }
        // Right-click → context menu. The rotate action persists per-stream
        // so the grid preview (sub) and rich-viewer main feed can land at
        // independent orientations — useful for dual-lens cameras where
        // Reolink encodes the two streams at different native rotations.
        .contextMenu {
            Button {
                store.rotateClockwise(deviceID: session.entry.id, channel: channel.channel, stream: stream)
            } label: {
                let current = store.rotation(for: session.entry.id, channel: channel.channel, stream: stream)
                Label("Rotate \(streamLabel) feed (\(current)°)", systemImage: "rotate.right")
            }
        }
        .task(id: channel.channel) {
            guard autoStart, !channel.isAsleep, !session.isBatteryPowered(channel: channel.channel), !didStart, !paused else { return }
            didStart = true
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
        }
    }

    private var sleepingOverlay: some View {
        let isBattery = session.isBatteryPowered(channel: channel.channel)
        return VStack(spacing: 8) {
            Image(systemName: isBattery ? "battery.50" : "moon.zzz.fill").font(.title)
            Text(isBattery ? "Battery camera" : "Sleeping")
                .font(.caption.weight(.medium))
            if isBattery {
                Text("Not auto-streamed to save battery.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            Button("Connect") {
                Task { await startPlayer() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
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

    private func startPlayer() async {
        if player != nil { return }
        didStart = true
        // For battery cameras, poke the hub via Baichuan first to wake the
        // sleeping camera. If we go straight to RTSP, the camera won't
        // respond because it's offline at the radio layer.
        if session.isBatteryPowered(channel: channel.channel) || channel.isAsleep, let baichuan = session.baichuanClient {
            _ = try? await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
        }
        let credentials = await session.client.credentials
        let urls = StreamURLs(credentials: credentials).candidatesForLive(
            channel: channel.channel,
            stream: stream
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
