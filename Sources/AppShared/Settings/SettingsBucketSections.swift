import SwiftUI

/// 0.6.1 Settings IA — the seven top-level buckets. Both the iOS Form
/// and the macOS TabView compose from these so the platform shells
/// don't drift again.
///
/// Buckets are intentionally small. Each one composes existing section
/// views (`BackgroundDownloadsSection`, `ICloudKeychainSyncSection`,
/// `NotificationCategoriesSection`, etc.) rather than re-implementing
/// their bodies. Avoid moving section bodies into this file — keep the
/// composition shallow.

// MARK: - 1. Cameras

public struct SettingsCamerasBucket: View {
    @Environment(CameraStore.self) private var store

    public init() {}

    public var body: some View {
        Section("Cameras") {
            LabeledContent("Configured", value: "\(store.cameras.count)")
            if store.cameras.isEmpty {
                Text("Add a camera in the Devices tab. The list syncs to your other Apple devices via iCloud.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 2. Notifications & Events

/// Combines the previously-scattered notification controls into one
/// bucket. Order is intentional: master toggle first, then event-type
/// filters, then per-camera + per-tag, then system surfaces (permission
/// row, log, diagnostics), and finally the relay rows whose platform
/// availability differs.
public struct SettingsNotificationsBucket: View {
    @State private var notifier = EventNotifier.shared
    @Binding private var showingLog: Bool

    public init(showingLog: Binding<Bool>) {
        self._showingLog = showingLog
    }

    public var body: some View {
        Group {
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notifier.enabled)
                Text("Post a notification with a snapshot whenever the hub reports motion or AI events on one of your cameras.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Event types") {
                Toggle("AI events (person, vehicle, pet, …)", isOn: $notifier.notifyAI)
                Toggle("Motion only (no AI classification)", isOn: $notifier.notifyMotion)
                Text("Motion-only events can flood when sustained — leave off unless you want every triggered second.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!notifier.enabled)

            NotificationCategoriesSection(notifier: notifier)
            PerCameraNotificationsSection()
            OvernightDigestSettingsSection()

            Section("System permission") {
                NotificationPermissionRow(notifier: notifier)
            }

            #if os(iOS)
            MotionRelaySubscriberSection()
            #elseif os(macOS)
            MotionRelayPublisherSection()
            #endif

            Section("Notification log") {
                #if os(iOS)
                NavigationLink {
                    NotificationLogView()
                } label: {
                    Label("View notification history", systemImage: "list.bullet.rectangle.portrait")
                }
                #else
                Button {
                    showingLog = true
                } label: {
                    Label("View notification history…", systemImage: "list.bullet.rectangle.portrait")
                }
                #endif
                Text("Browse the last 1,000 notifications delivered or silenced on this device. New in 0.6.0.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await notifier.refreshPermissionStatus() }
    }
}

// MARK: - 3. Display

public struct SettingsDisplayBucket: View {
    @Environment(CameraStore.self) private var store
    @AppStorage(GridPreviewSetting.liveGridDefaultsKey) private var liveGridEnabled: Bool = false

    public init() {}

    public var body: some View {
        Group {
            Section("Display") {
                Toggle("Show camera name on live feed", isOn: bindable.showCameraNameOnFeed)
                Text("Reolink cameras burn their own date / time / name overlay into the top of the frame, so by default Reolens hides its own camera-name badge. Turn this on if your cameras have OSD off and you want the label back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Grid previews") {
                Toggle("Live previews in grid", isOn: $liveGridEnabled)
                Text("By default, the multi-camera grid shows the last snapshot from each camera and only streams live when you open a single camera — friendlier on battery and bandwidth. Turn this on to bring back continuous live grids.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            DefaultRecordingQualitySection(preferences: store.preferences)
        }
    }

    private var bindable: Bindable<CameraStore> { Bindable(store) }
}

/// 0.7.0 — Default playback quality picker. Lives in its own small
/// view so the `@Bindable` for `AppPreferences` (which is `@Observable`
/// in its own right) can drive the Picker selection through SwiftUI's
/// projected-binding sugar without needing a passthrough on
/// `CameraStore`.
private struct DefaultRecordingQualitySection: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Section("Recordings playback") {
            Picker("Default quality", selection: $preferences.defaultRecordingQuality) {
                ForEach(RecordingQuality.allCases, id: \.self) { quality in
                    Text(quality.longLabel).tag(quality)
                }
            }
            Text("Quality used when you tap a recording. You can still switch in the player. Low (sub stream) starts dramatically faster; High (main stream) is full resolution.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 4. Background & Storage

public struct SettingsBackgroundBucket: View {
    public init() {}

    public var body: some View {
        BackgroundDownloadsSection()
    }
}

// MARK: - 5. Privacy & Sync

public struct SettingsPrivacyBucket: View {
    /// 0.6.0 — HomeKit bridge instance, owned at this level so the
    /// `@Bindable` in `HomeKitSection` works.
    @State private var homeKitBridge: HomeKitBridge

    public init(homeKitBridge: HomeKitBridge? = nil) {
        _homeKitBridge = State(initialValue: homeKitBridge ?? HomeKitBridge())
    }

    public var body: some View {
        Group {
            ICloudKeychainSyncSection()
            #if os(iOS)
            HomeKitSection(bridge: homeKitBridge)
            #endif
        }
    }
}

// MARK: - 6. Advanced

/// Bottom-of-the-list bucket. Demoted because the surfaces here are
/// debug / power-user tools, not everyday settings. New in 0.6.1: the
/// Diagnostics Center link.
public struct SettingsAdvancedBucket: View {
    @Environment(CameraStore.self) private var store

    /// macOS callers can present the Diagnostics Center modally
    /// because the platform doesn't have a navigation stack to push
    /// into from a Settings tab. iOS callers leave this nil and the
    /// view pushes through the existing NavigationStack.
    @Binding private var showingDiagnostics: Bool

    public init(showingDiagnostics: Binding<Bool>) {
        self._showingDiagnostics = showingDiagnostics
    }

    public var body: some View {
        Group {
            Section("Developer") {
                Toggle("Developer mode", isOn: bindable.developerMode)
                Text("Surfaces diagnostic UI for debugging: raw JSON popovers in the recordings view and other low-level inspection tools. Off by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                #if os(iOS)
                NavigationLink {
                    DiagnosticsCenterView()
                } label: {
                    Label("Diagnostics Center", systemImage: "stethoscope")
                }
                #else
                Button {
                    showingDiagnostics = true
                } label: {
                    Label("Diagnostics Center…", systemImage: "stethoscope")
                }
                #endif
                Text("Browse the local error log. Captures network, playback, schedule, and notification failures so support threads can be specific. Nothing is uploaded — the log stays on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            RelayDiagnosticsSection()
        }
    }

    private var bindable: Bindable<CameraStore> { Bindable(store) }
}

// MARK: - 7. About

public struct SettingsAboutBucket: View {
    public init() {}

    public var body: some View {
        Group {
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                Link("Project on GitHub", destination: URL(string: "https://github.com/jestatsio/reolens")!)
                Link("Report an issue", destination: URL(string: "https://github.com/jestatsio/reolens/issues")!)
            }

            Section {
                Text("Reolens is a native client for Reolink cameras and NVRs. Camera list and grid preferences sync via iCloud. Passwords stay on each device's Keychain by default — opt in to iCloud Keychain Sync in Privacy & Sync to share them across your devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Helpers

/// Pulled out of the per-platform SettingsView so both the iOS and the
/// macOS shell can use it. Matches the original switch on
/// `permissionStatus` semantically.
struct NotificationPermissionRow: View {
    let notifier: EventNotifier

    var body: some View {
        switch notifier.permissionStatus {
        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Granted").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                    Text("Denied — re-enable in System Settings.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Notification Settings") {
                    notifier.openSystemSettings()
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 8) {
                Text("Permission not requested yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Request permission") {
                    Task { await notifier.requestPermission() }
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
        @unknown default:
            Text(String(describing: notifier.permissionStatus))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Lift of the previously-private `OvernightDigestSection` from each
/// platform's SettingsView, so the iOS and macOS shells both call the
/// same section. The body is intentionally identical to both legacy
/// implementations.
struct OvernightDigestSettingsSection: View {
    @State private var enabled: Bool = OvernightDigestSettings.enabled
    @State private var hour: Int = OvernightDigestSettings.hourOfDay
    @State private var showingPreview: Bool = false

    var body: some View {
        Section("Overnight digest") {
            Toggle("Daily summary notification", isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    OvernightDigestSettings.setEnabled(value)
                    Task { await DigestScheduler.shared.reconcileSchedule() }
                }
            Picker("Time of day", selection: $hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).tag(h)
                }
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #endif
            .disabled(!enabled)
            .onChange(of: hour) { _, value in
                OvernightDigestSettings.setHourOfDay(value)
                Task { await DigestScheduler.shared.reconcileSchedule() }
            }
            Text("Bundles last night's motion events into a single notification at the configured time. Default 07:00 local.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Preview last digest…") { showingPreview = true }
                .sheet(isPresented: $showingPreview) {
                    DigestDetailView()
                }
            Button("Build a digest now") {
                Task { await DigestScheduler.shared.runDigest() }
            }
            #if os(macOS)
            .help("Useful for verifying the pipeline without waiting for the scheduled time.")
            #endif
        }
    }
}
