import SwiftUI
import ReolinkAPI

struct AddCameraSheet: View {
    let onAdd: (CameraEntry, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "80"
    @State private var username = "admin"
    @State private var password = ""
    @State private var useHTTPS = false
    @State private var preferredCodec: VideoCodec = .h264

    var body: some View {
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
                    Text("H.265 (4K/8MP)").tag(VideoCodec.h265)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420)
        .navigationTitle("Add Camera")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
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
                    dismiss()
                }
                .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }
}
