import SwiftUI
import ReolinkAPI
import AppShared

/// iOS add-camera sheet. v0.2 ships **manual entry only** — local-
/// network discovery on iOS requires the user to grant the Local
/// Network permission AND for the app to register Bonjour services
/// the OS will let it browse, both of which gate the existing
/// `CameraDiscovery` actor. We'll wire that into the iOS app in a
/// point release; for v0.2 the Mac app can populate the camera list
/// and iCloud sync brings it to the iPad/iPhone instantly.
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

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && Int(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
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
}
