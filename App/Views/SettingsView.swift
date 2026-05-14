import SwiftUI
import UserNotifications
import AppShared

struct SettingsView: View {
    @Environment(CameraStore.self) private var store
    @State private var notifier = EventNotifier.shared
    @State private var showingNotificationLog: Bool = false
    @AppStorage(GridPreviewSetting.liveGridDefaultsKey) private var liveGridEnabled: Bool = false
    @AppStorage(MenuBarController.menuBarModeKey) private var menuBarMode: Bool = false
    @AppStorage(MenuBarController.launchAtLoginKey) private var launchAtLogin: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            developerTab
                .tabItem { Label("Developer", systemImage: "hammer") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }

    private var generalTab: some View {
        @Bindable var store = store
        return Form {
            LabeledContent("Cameras configured") {
                Text("\(store.cameras.count)")
            }
            Section("Display") {
                Toggle("Show camera name on live feed", isOn: $store.showCameraNameOnFeed)
                Text("New in 0.5.1. Reolink cameras burn their own date / time / name overlay into the top of the frame, so by default Reolens hides its own camera-name badge to avoid covering it. Turn this on if your cameras have OSD off and you want the label back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Grid previews") {
                Toggle("Live previews in grid", isOn: $liveGridEnabled)
                Text("New in 0.4.0. By default, the multi-camera grid shows the last snapshot from each camera and only streams live when you open a single camera. Turn this on to bring back continuous live grids (uses more CPU and bandwidth).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            BackgroundDownloadsSection()
            Section("Run in the menu bar") {
                Toggle("Run in the menu bar when closed", isOn: $menuBarMode)
                    .onChange(of: menuBarMode) { _, newValue in
                        if newValue {
                            MenuBarController.shared.install(store: store)
                        } else {
                            MenuBarController.shared.uninstall()
                            // Launch-at-login without menu-bar mode is
                            // surprising — disable it together.
                            if launchAtLogin {
                                launchAtLogin = false
                                if #available(macOS 13.0, *) {
                                    MenuBarController.shared.setLaunchAtLogin(false)
                                }
                            }
                        }
                    }
                Text("New in 0.4.0. Closing the window keeps Reolens running in the menu bar so motion notifications keep firing. Quit from the menu bar item to fully stop the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if #available(macOS 13.0, *) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .disabled(!menuBarMode)
                        .onChange(of: launchAtLogin) { _, newValue in
                            MenuBarController.shared.setLaunchAtLogin(newValue)
                        }
                    Text("Reolens starts in the menu bar at login so events from the moment you sit down at the Mac aren't missed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            ICloudKeychainSyncSection()
            MotionRelayPublisherSection()
            RelayDiagnosticsSection()
        }
        .formStyle(.grouped)
    }

    private var notificationsTab: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $notifier.enabled)
                Text("Post a macOS notification (with a still from the camera) whenever your hub reports motion or AI events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Event types") {
                Toggle("AI events (person, vehicle, pet, …)", isOn: $notifier.notifyAI)
                Toggle("Motion only (no AI classification)", isOn: $notifier.notifyMotion)
                Text("Motion-only events can flood when sustained — leave off unless you want every triggered second.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!notifier.enabled)
            NotificationCategoriesSection(notifier: notifier)
            PerCameraNotificationsSection()
            OvernightDigestSection()
            Section("System permission") {
                permissionRow
            }
            Section("Notification log") {
                Button {
                    showingNotificationLog = true
                } label: {
                    Label("View notification history…", systemImage: "list.bullet.rectangle.portrait")
                }
                Text("Browse the last 1,000 notifications delivered or silenced on this Mac. New in 0.6.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await notifier.refreshPermissionStatus() }
        .sheet(isPresented: $showingNotificationLog) {
            NavigationStack {
                NotificationLogView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingNotificationLog = false }
                        }
                    }
            }
            .frame(minWidth: 520, minHeight: 600)
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch notifier.permissionStatus {
        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Granted").foregroundStyle(.secondary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                    Text("Denied — re-enable in System Settings.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Notification Settings") {
                    notifier.openSystemSettings()
                }
                .controlSize(.small)
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 6) {
                Text("Permission not requested yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request permission") {
                    Task { await notifier.requestPermission() }
                }
                .controlSize(.small)
            }
        @unknown default:
            Text(String(describing: notifier.permissionStatus))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var developerTab: some View {
        @Bindable var store = store
        return Form {
            Section {
                Toggle("Developer mode", isOn: $store.developerMode)
                Text("Surfaces diagnostic UI for debugging: Raw JSON popovers in the recordings view and other low-level inspection tools. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 8) {
            Text("Reolens")
                .font(.title2.weight(.semibold))
            Text("A modern, native macOS client for Reolink cameras and NVRs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// 0.5.0 Theme A5 — overnight digest controls. Edits the
/// `OvernightDigestSettings` UserDefaults pair; on change, kicks
/// `DigestScheduler.reconcileSchedule()` so the local notification
/// trigger matches the new settings.
private struct OvernightDigestSection: View {
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
            .disabled(!enabled)
            .onChange(of: hour) { _, value in
                OvernightDigestSettings.setHourOfDay(value)
                Task { await DigestScheduler.shared.reconcileSchedule() }
            }
            Text("Bundles last night's motion events into a single notification at the configured time. Default 07:00 local.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Preview last digest…") { showingPreview = true }
                .sheet(isPresented: $showingPreview) {
                    DigestDetailView()
                }
            Button("Build a digest now") {
                Task { await DigestScheduler.shared.runDigest() }
            }
            .help("Useful for verifying the pipeline without waiting for the scheduled time.")
        }
    }
}
