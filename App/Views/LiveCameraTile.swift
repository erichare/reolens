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
        // Read rotation directly here so @Observable's tracking definitely
        // sees the access in this view body — `effectiveRotation` as a
        // computed property doesn't reliably propagate observation through
        // SwiftUI's diffing in all cases.
        let rotation = rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel)

        let isBatteryIdle = (channel.isAsleep || channel.isBatteryPowered) && player == nil
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
        .task(id: channel.channel) {
            guard autoStart, !channel.isAsleep, !channel.isBatteryPowered, !didStart, !paused else { return }
            didStart = true
            await startPlayer()
        }
        .onChange(of: rotation) { _, newValue in
            player?.rotationDegrees = newValue
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                player?.stop()
                player = nil
                didStart = false
            } else if autoStart, !channel.isAsleep, !channel.isBatteryPowered, !didStart {
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
        let isBattery = channel.isBatteryPowered
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
        rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel)
    }

    private func startPlayer() async {
        if player != nil { return }
        didStart = true
        // For battery cameras, poke the hub via Baichuan first to wake the
        // sleeping camera. If we go straight to RTSP, the camera won't
        // respond because it's offline at the radio layer.
        if channel.isBatteryPowered || channel.isAsleep, let baichuan = session.baichuanClient {
            _ = try? await baichuan.wakeBatteryCamera(channelID: UInt8(channel.channel))
        }
        let credentials = await session.client.credentials
        let urls = StreamURLs(credentials: credentials).candidatesForLive(
            channel: channel.channel,
            stream: stream
        )
        let rotation = rotationDegrees ?? store.rotation(for: session.entry.id, channel: channel.channel)
        let p = LiveVideoPlayer(
            urls: urls,
            username: credentials.username,
            password: credentials.password,
            rotationDegrees: rotation
        )
        self.player = p
        p.start()
    }
}
