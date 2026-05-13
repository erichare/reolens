import SwiftUI
import ReolinkAPI
import AppShared

struct AddCameraSheet: View {
    let onAdd: (CameraEntry, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: AddMode = .autoDetect

    enum AddMode: String, CaseIterable, Identifiable {
        case autoDetect = "Auto-detect"
        case manual = "Manual"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(AddMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            .labelsHidden()
            .padding(.bottom, 12)
            // 0.5.0 Liquid Glass — segmented switcher sits atop a
            // glass toolbar that pairs with the rest of the chrome.
            .reolensGlassToolbar()

            Divider()

            switch mode {
            case .autoDetect:
                AutoDetectPane(onAdd: { entry, password in
                    onAdd(entry, password)
                    dismiss()
                })
            case .manual:
                ManualPane(onAdd: { entry, password in
                    onAdd(entry, password)
                    dismiss()
                })
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

// MARK: - Auto-detect

private struct AutoDetectPane: View {
    let onAdd: (CameraEntry, String) -> Void

    @State private var devices: [DiscoveredDevice] = []
    @State private var isScanning = false
    @State private var progress: Double = 0
    @State private var selectedDevice: DiscoveredDevice?
    @State private var subnetLabel: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            if let selected = selectedDevice {
                Divider()
                CredentialsPane(
                    prefilledHost: selected.host,
                    prefilledName: selected.displayName == selected.host ? "" : selected.displayName,
                    kindHint: selected.kindHint,
                    onAdd: onAdd
                )
            }
        }
        .task {
            await runScan()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Searching the local network").font(.headline)
                Text(subnetLabel.isEmpty ? "Detecting subnet…" : "Scanning \(subnetLabel).1 – \(subnetLabel).254")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isScanning {
                ProgressView(value: progress).frame(width: 100)
            } else {
                Button {
                    Task { await runScan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if devices.isEmpty && !isScanning {
            ContentUnavailableView {
                Label("No Reolink devices found", systemImage: "rectangle.dashed")
            } description: {
                Text("We scanned your subnet and didn't find any Reolink-shaped HTTP endpoints. If your camera is on a different VLAN or only reachable by hostname, add it manually instead.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(devices, selection: $selectedDevice) { device in
                DeviceFoundRow(device: device)
                    .tag(device)
            }
            .listStyle(.plain)
            .frame(minHeight: 160)
        }
    }

    private func runScan() async {
        isScanning = true
        progress = 0
        selectedDevice = nil
        devices = []
        subnetLabel = await CameraDiscovery.primarySubnetPrefix() ?? ""
        let found = await CameraDiscovery.shared.scan(progress: { p in
            Task { @MainActor in self.progress = p }
        })
        await MainActor.run {
            self.devices = found
            self.isScanning = false
        }
    }
}

private struct DeviceFoundRow: View {
    let device: DiscoveredDevice

    /// True when the displayName is just the IP — i.e. Bonjour didn't
    /// find this device and we couldn't get its marketing name. Render
    /// the IP in monospaced digits in that case; for real names, use the
    /// normal body font.
    private var displayLooksLikeIP: Bool {
        device.displayName == device.host
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                if displayLooksLikeIP {
                    Text(device.host)
                        .font(.body.monospacedDigit())
                } else {
                    Text(device.displayName).font(.body)
                }
                HStack(spacing: 6) {
                    // Show the IP as the secondary line when we have a
                    // friendly name on the primary line — keeps it
                    // discoverable but de-emphasized.
                    if !displayLooksLikeIP {
                        Text(device.host)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(device.kindHint).font(.caption).foregroundStyle(.secondary)
                    if !device.confirmedReolink {
                        Text("·").foregroundStyle(.tertiary)
                        Text("HTTP only").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var iconName: String {
        let lower = device.kindHint.lowercased()
        if lower.contains("hub") { return "house.fill" }
        if lower.contains("nvr") { return "rectangle.stack.fill" }
        return "video.fill"
    }
}

private struct CredentialsPane: View {
    let prefilledHost: String
    let prefilledName: String
    let kindHint: String
    let onAdd: (CameraEntry, String) -> Void

    @State private var displayName: String
    @State private var username = "admin"
    @State private var password = ""
    @State private var preferredCodec: VideoCodec = .h264

    init(prefilledHost: String, prefilledName: String, kindHint: String, onAdd: @escaping (CameraEntry, String) -> Void) {
        self.prefilledHost = prefilledHost
        self.prefilledName = prefilledName
        self.kindHint = kindHint
        self.onAdd = onAdd
        _displayName = State(initialValue: prefilledName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in to \(prefilledName.isEmpty ? prefilledHost : prefilledName)")
                        .font(.headline)
                    if !prefilledName.isEmpty {
                        Text(prefilledHost)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Form {
                Section {
                    TextField("Display name (optional)", text: $displayName, prompt: Text(prefilledHost))
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section("Stream") {
                    Picker("Preferred codec", selection: $preferredCodec) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265 (4K / 8MP)").tag(VideoCodec.h265)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Add device") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty)
            }
            .padding(12)
        }
    }

    private func submit() {
        let displayed = displayName.isEmpty ? prefilledHost : displayName
        let entry = CameraEntry(
            displayName: displayed,
            host: prefilledHost,
            port: 80,
            username: username,
            useHTTPS: false,
            preferredCodec: preferredCodec
        )
        onAdd(entry, password)
    }
}

// MARK: - Manual

private struct ManualPane: View {
    let onAdd: (CameraEntry, String) -> Void

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "80"
    @State private var username = "admin"
    @State private var password = ""
    @State private var useHTTPS = false
    @State private var preferredCodec: VideoCodec = .h264

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Display name", text: $displayName)
                        .textContentType(.name)
                    TextField("Host or IP", text: $host)
                    TextField("Port", text: $port)
                }
                Section("Credentials") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section("Connection") {
                    Toggle("Use HTTPS", isOn: $useHTTPS)
                    Picker("Preferred codec", selection: $preferredCodec) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265 (4K / 8MP)").tag(VideoCodec.h265)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Add device") {
                    let portInt = Int(port) ?? 80
                    let displayed = displayName.isEmpty ? host : displayName
                    let entry = CameraEntry(
                        displayName: displayed,
                        host: host,
                        port: portInt,
                        username: username,
                        useHTTPS: useHTTPS,
                        preferredCodec: preferredCodec
                    )
                    onAdd(entry, password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }
            .padding(12)
        }
    }
}
