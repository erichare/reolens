import SwiftUI
import ReolinkAPI
import ReolinkBaichuan
import AppShared

/// Modal sheet wrapper around `ChannelDetailContent`, used when a grid
/// tile is clicked. The same camera UI renders inline (without the sheet
/// chrome) when a channel is selected in the sidebar — see
/// `ChannelDetailContent` for the underlying view.
struct RichViewerSheet: View {
    let session: CameraSession
    let channel: ChannelStatus

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ChannelDetailContent(session: session, channel: channel)
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
}
