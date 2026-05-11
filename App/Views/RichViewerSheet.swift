import SwiftUI
import ReolinkAPI
import ReolinkBaichuan

/// Full-window single-camera viewer with Live / Recordings / Settings tabs.
struct RichViewerSheet: View {
    let session: CameraSession
    let channel: ChannelStatus

    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store
    @State private var tab: Tab = .live

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case live, recordings, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .live: "Live"
            case .recordings: "Recordings"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .live: "dot.radiowaves.left.and.right"
            case .recordings: "rectangle.stack.badge.play"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.label, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .frame(minWidth: 920, minHeight: 600, idealHeight: 760)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: channel.isAsleep ? "moon.zzz.fill" : "video.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name ?? "Channel \(channel.channel + 1)")
                    .font(.headline)
                if let info = session.deviceInfo {
                    Text(metaLine(info: info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            indicators
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func metaLine(info: DeviceInfo) -> String {
        var parts: [String] = []
        if let typeInfo = channel.typeInfo, !typeInfo.isEmpty { parts.append(typeInfo) }
        if let model = info.model { parts.append("via \(model)") }
        if let fw = info.firmVer { parts.append(fw) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var indicators: some View {
        if session.motionState[channel.channel] == true {
            Label("Motion", systemImage: "figure.walk.motion")
                .labelStyle(.titleAndIcon).foregroundStyle(.yellow).font(.caption)
        }
        if session.aiTriggered[channel.channel] == true {
            Label("AI", systemImage: "sparkles")
                .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.caption)
        }
        if !channel.isOnline {
            Label("Offline", systemImage: "wifi.slash")
                .foregroundStyle(.red).font(.caption)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .live:
            liveTab
        case .recordings:
            RecordingsView(session: session, channel: channel)
        case .settings:
            ChannelSettingsView(session: session, channel: channel)
        }
    }

    private var liveTab: some View {
        VStack(spacing: 0) {
            LiveCameraTile(session: session, channel: channel, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            Divider()
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            PTZControlBar(session: session, channel: channel.channel)
            Spacer()
            TalkbackButton(session: session, channelID: UInt8(channel.channel))
            rotationControls
        }
        .padding(12)
    }

    private var rotationControls: some View {
        // The rich viewer renders the MAIN stream, so its rotate control
        // adjusts the main-stream rotation only. The grid preview (sub)
        // has its own persisted rotation independently.
        let current = store.rotation(for: session.entry.id, channel: channel.channel, stream: .main)
        return HStack(spacing: 6) {
            Text("\(current)°").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button {
                store.rotateClockwise(deviceID: session.entry.id, channel: channel.channel, stream: .main)
            } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .help("Rotate the main feed 90° clockwise")
        }
    }
}
