import SwiftUI
import ReolinkAPI
import ReolinkStreaming

struct CameraDetailView: View {
    let session: CameraSession
    let focusedChannel: Int?

    @State private var didStart = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .task(id: session.entry.id) {
            guard !didStart else { return }
            didStart = true
            await session.connect()
        }
        .navigationTitle(titleLine)
        .navigationSubtitle(session.deviceInfo?.model ?? session.entry.host)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let focusedChannel,
           let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
            SingleChannelView(session: session, channel: channel)
        } else if session.channels.count > 1 {
            MultiChannelGridView(session: session)
        } else if let channel = session.channels.first {
            SingleChannelView(session: session, channel: channel)
        } else {
            ContentUnavailableView("Connecting…", systemImage: "bolt.horizontal")
        }
    }

    private var titleLine: String {
        if let focusedChannel,
           let channel = session.channels.first(where: { $0.channel == focusedChannel }) {
            return "\(session.entry.displayName) — \(channel.name ?? "Channel \(focusedChannel + 1)")"
        }
        return session.entry.displayName
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let info = session.deviceInfo {
                Label(info.model ?? "Unknown", systemImage: "video.fill")
                if let fw = info.firmVer {
                    Text(fw).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(session.entry.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .error(msg) = session.status {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Compact connection-status pill for the toolbar. The toolbar renders
    /// `Label` with both icon and text full-size, which looks heavy next to
    /// the title; switching to a tinted capsule with a small dot keeps the
    /// information density without the visual weight.
    @ViewBuilder
    private var statusBadge: some View {
        switch session.status {
        case .connected:
            statusPill(text: "Connected", color: .green)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            statusPill(text: "Disconnected", color: .red)
                .help(msg)
        case .disconnected:
            Button {
                Task { await session.connect() }
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .controlSize(.small)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: .capsule)
    }
}

struct SingleChannelView: View {
    let session: CameraSession
    let channel: ChannelStatus

    var body: some View {
        VStack(spacing: 0) {
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PTZControlBar(session: session, channel: channel.channel)
                .padding(8)
        }
    }
}

struct MultiChannelGridView: View {
    let session: CameraSession
    @State private var richViewerChannel: ChannelStatus?

    private var visibleChannels: [ChannelStatus] {
        // Filter out channels with no paired camera. Reolink Home Hub reports
        // 24 slots even when fewer are populated — empty slots have no name and
        // no typeInfo. Keep sleeping/named ones; drop totally-empty rows.
        session.channels.filter { ch in
            (ch.name?.isEmpty == false) || (ch.typeInfo?.isEmpty == false)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 8)]

    var body: some View {
        // When the rich viewer is open, pause ALL grid tiles. Reolink Home Hub
        // has a small per-device concurrent-session cap; running 20+ sub-stream
        // sessions while a main-stream session is also open exhausts it and
        // the hub starts dropping streams after a few seconds.
        let richViewerOpen = richViewerChannel != nil
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(visibleChannels) { channel in
                    let tile = LiveCameraTile(
                        session: session,
                        channel: channel,
                        stream: .sub,
                        onTap: { richViewerChannel = channel },
                        paused: richViewerOpen
                    )
                    // Dual-lens cameras render natively at ~8:3 (Duo /
                    // TrackMix / Argus 4 Pro). Give them more vertical room
                    // so the stitched view isn't cropped.
                    if session.isDualLens(channel: channel.channel) {
                        tile.frame(minHeight: 110, idealHeight: 140, maxHeight: 220)
                    } else {
                        tile.frame(minHeight: 160, idealHeight: 210, maxHeight: 320)
                    }
                }
            }
            .padding(8)
        }
        .sheet(item: $richViewerChannel) { channel in
            RichViewerSheet(session: session, channel: channel)
        }
    }
}
