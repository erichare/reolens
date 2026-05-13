import SwiftUI
import ReolinkAPI
import AppShared

/// iOS add-camera sheet. As of 0.4.1, supports both manual entry AND
/// local-network discovery via `CameraDiscovery`. Discovery runs
/// Bonjour/mDNS browse + an HTTP /24 sweep concurrently and prefills
/// the form with the device's host + display name; the user enters
/// the username + password to finish.
///
/// AGENTS.md §3 — the Local Network permission prompt fires the first
/// time the user opens the discovery sheet, which is contextually
/// justified ("I asked to scan, so iOS is asking permission").
struct AddCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    @State private var displayName: String = ""
    @State private var host: String = ""
    @State private var port: String = "80"
    @State private var username: String = "admin"
    @State private var password: String = ""
    @State private var useHTTPS: Bool = false
    @State private var preferredCodec: VideoCodec = .h264
    @State private var showingDiscovery: Bool = false

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && Int(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingDiscovery = true
                    } label: {
                        Label("Scan local network for cameras", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Reolens looks for cameras on your Wi-Fi network using Bonjour and a one-time HTTP scan. iOS will ask for Local Network permission the first time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Device") {
                    TextField("Display name (optional)", text: $displayName)
                        .textInputAutocapitalization(.words)
                    TextField("Host or IP", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Toggle("Use HTTPS", isOn: $useHTTPS)
                }
                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section("Stream") {
                    Picker("Preferred codec", selection: $preferredCodec) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265 (4K / 8MP)").tag(VideoCodec.h265)
                    }
                }
                Section {
                    Text("Passwords are stored on this device's Keychain only. Your camera list and grid layout sync across devices via iCloud; passwords do not leave the device they were entered on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit).disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingDiscovery) {
                DiscoveryPickerSheet { device in
                    apply(device)
                }
            }
        }
    }

    private func submit() {
        guard let portInt = Int(port) else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let entry = CameraEntry(
            displayName: displayName.isEmpty ? trimmedHost : displayName,
            host: trimmedHost,
            port: portInt,
            username: username.trimmingCharacters(in: .whitespaces),
            useHTTPS: useHTTPS,
            preferredCodec: preferredCodec
        )
        store.add(entry, password: password)
        dismiss()
    }

    private func apply(_ device: DiscoveredDevice) {
        host = device.host
        if displayName.isEmpty || displayName == host {
            displayName = device.displayName
        }
        // Discovery picks up the HTTP port the device responded on —
        // 80 for nearly every Reolink. The user can override on the
        // form before saving.
        port = "\(device.port)"
        // Reolink cameras don't advertise HTTPS-only by default; the
        // discovery sweep is HTTP. Leave `useHTTPS` at whatever the
        // user picked.
    }
}

/// Modal that runs `CameraDiscovery.scan` and renders the results in
/// a tappable list. Picking a row dismisses the sheet and hands the
/// selected `DiscoveredDevice` back to the parent.
private struct DiscoveryPickerSheet: View {
    let onSelect: (DiscoveredDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [DiscoveredDevice] = []
    @State private var isScanning: Bool = false
    @State private var scanProgress: Double = 0
    /// 0.5.0 Theme E: iOS Local Network permission state, surfaced
    /// when the user has explicitly denied so we can show the
    /// "Settings → Privacy" hint instead of an empty list.
    @State private var permissionDenied: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if permissionDenied {
                    ContentUnavailableView {
                        Label("Local Network access denied", systemImage: "lock.shield")
                    } description: {
                        Text("Reolens needs Local Network permission to discover cameras. Open Settings → Privacy & Security → Local Network → Reolens to allow it.")
                    } actions: {
                        Button("Scan again") {
                            Task { await runScan() }
                        }
                    }
                } else if isScanning && devices.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView(value: scanProgress) {
                            Text("Scanning local network…")
                                .font(.callout)
                        }
                        .padding()
                        Text("Cameras typically appear within 3 seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else if devices.isEmpty {
                    ContentUnavailableView {
                        Label("No cameras found", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text("Reolens couldn't find any Reolink devices on this Wi-Fi network. Add by IP address using the form instead.")
                    } actions: {
                        Button("Scan again") {
                            Task { await runScan() }
                        }
                    }
                } else {
                    List(devices) { device in
                        Button {
                            onSelect(device)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.body.weight(.medium))
                                Text("\(device.host) · \(device.kindHint)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Discover cameras")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !isScanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scan again") {
                            Task { await runScan() }
                        }
                    }
                }
            }
        }
        .task {
            await runScan()
        }
    }

    private func runScan() async {
        isScanning = true
        scanProgress = 0
        permissionDenied = false
        defer { isScanning = false }
        let outcome = await CameraDiscovery.shared.scanWithPermissionGate(progress: { p in
            Task { @MainActor in self.scanProgress = p }
        })
        switch outcome {
        case .permissionDenied:
            permissionDenied = true
            devices = []
        case .success(let results):
            devices = results
        }
    }
}
