import SwiftUI

/// Shared password-entry sheet used on macOS, iOS, and iPadOS to re-enter
/// a device password locally. Used in two cases:
///
/// 1. A device was added on another Apple device and synced over via
///    iCloud Drive; the camera metadata is here but the password isn't,
///    because passwords stay device-local in Keychain by design.
/// 2. The user has rotated the camera/router password and needs to
///    update this device's stored copy.
///
/// The sheet is intentionally narrow in scope — only the password is
/// editable. Host, port, and username appear as read-only context so the
/// user can confirm they're entering the right credential for the right
/// device. To change those, remove and re-add the camera.
///
/// On submit, calls `CameraStore.setPassword(_:for:)`, which writes the
/// password to Keychain and tears down any in-memory session so the next
/// access reconnects with the new credentials. Nothing is written to
/// `cameras.json`, so no iCloud round-trip happens.
public struct EnterPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    let entry: CameraEntry

    @State private var password: String = ""
    @FocusState private var passwordFieldFocused: Bool

    public init(entry: CameraEntry) {
        self.entry = entry
    }

    private var isValid: Bool {
        !password.isEmpty
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Name", value: entry.displayName)
                    LabeledContent("Host", value: "\(entry.host):\(entry.port)")
                    LabeledContent("Username", value: entry.username)
                }
                Section("Password") {
                    SecureField("Password", text: $password)
                        .focused($passwordFieldFocused)
                        .onSubmit(submit)
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                }
                Section {
                    Text("This password is stored only on this device's Keychain. Reolens never syncs passwords between devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Enter Password")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: submit).disabled(!isValid)
                }
            }
            .onAppear { passwordFieldFocused = true }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private func submit() {
        guard isValid else { return }
        store.setPassword(password, for: entry.id)
        dismiss()
    }
}
