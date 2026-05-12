import SwiftUI
import ReolinkAPI
import AppShared

/// Placeholder tile that displays:
/// - Periodic JPEG snapshots (cheap, works without any RTSP integration)
/// - Channel name + motion/AI indicators
/// - Connection state overlay
///
/// To be replaced by an RTSP-backed `LivePreviewView` once `ReolinkStreaming` is wired up.
struct VideoTilePlaceholder: View {
    let session: CameraSession
    let channel: ChannelStatus

    @State private var snapshot: Image?
    @State private var snapshotTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let snapshot {
                GeometryReader { geo in
                    snapshot
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else if channel.isAsleep {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill").font(.title2)
                    Text("Sleeping").font(.caption)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.status == .connected {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                    Text(channel.name ?? "Channel \(channel.channel + 1)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if session.motionState[channel.channel] == true {
                        Label("Motion", systemImage: "figure.walk.motion")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.yellow)
                    }
                    if session.aiTriggered[channel.channel] == true {
                        Label("AI", systemImage: "sparkles")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
            }
            .padding(8)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .task(id: session.status) {
            guard session.status == .connected else {
                snapshotTask?.cancel()
                snapshotTask = nil
                return
            }
            startSnapshotLoop()
        }
        .onDisappear {
            snapshotTask?.cancel()
            snapshotTask = nil
        }
    }

    private func startSnapshotLoop() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            while !Task.isCancelled {
                if let url = await session.snapshotURL(channel: channel.channel) {
                    await loadSnapshot(url: url)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func loadSnapshot(url: URL) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let nsImage = NSImage(data: data) {
                await MainActor.run {
                    snapshot = Image(nsImage: nsImage)
                }
            }
        } catch {
            // ignore — placeholder
        }
    }
}
