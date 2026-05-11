import SwiftUI
import ReolinkAPI

/// Per-channel settings — currently OSD (on-screen display) toggles for the
/// camera-name and time overlays the camera bakes into the video stream.
struct ChannelSettingsView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @State private var osd: OsdSettings?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("On-Screen Display") {
                if let _ = osd {
                    osdToggles
                } else if isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Loading…") }
                } else if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("No OSD configuration available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Channel") {
                LabeledContent("Name", value: channel.name ?? "—")
                LabeledContent("Type", value: channel.typeInfo ?? "—")
                LabeledContent("Status", value: channel.isOnline ? (channel.isAsleep ? "Sleeping" : "Online") : "Offline")
            }
            if let info = session.deviceInfo {
                Section("Device") {
                    LabeledContent("Model", value: info.model ?? "—")
                    LabeledContent("Firmware", value: info.firmVer ?? "—")
                    LabeledContent("Hardware", value: info.hardVer ?? "—")
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadOsd() }
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
        guard osd == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let env = try await session.client.send(
                Commands.getOsd(channel: channel.channel),
                as: OsdEnvelope.self
            )
            osd = env.Osd
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func persist(_ settings: OsdSettings) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.client.sendIgnoringValue(Commands.setOsd(settings))
        } catch {
            errorMessage = "\(error)"
        }
    }
}
