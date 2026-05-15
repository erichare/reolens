import SwiftUI
import UserNotifications
import AppShared

/// iOS Settings tab. Uses a single grouped `Form` (instead of the
/// macOS app's TabView-based settings window) because iOS settings
/// idiom is one long-scroll page per top-level entry point.
///
/// 0.6.1 reorganized this into the seven shared top-level buckets
/// (`SettingsCamerasBucket`, `SettingsNotificationsBucket`,
/// `SettingsDisplayBucket`, `SettingsBackgroundBucket`,
/// `SettingsPrivacyBucket`, `SettingsAdvancedBucket`,
/// `SettingsAboutBucket`). Each bucket is shared with the macOS
/// `SettingsView` so the platforms can't drift apart again. 0.6.2
/// deletes the legacy flat layout (the emergency-revert flag) now
/// that the new IA has been in the field for a release without
/// regressions.
struct SettingsView: View {
    @State private var showingLog: Bool = false
    @State private var showingDiagnostics: Bool = false

    var body: some View {
        Form {
            SettingsCamerasBucket()
            SettingsNotificationsBucket(showingLog: $showingLog)
            SettingsDisplayBucket()
            SettingsBackgroundBucket()
            SettingsPrivacyBucket()
            SettingsAdvancedBucket(showingDiagnostics: $showingDiagnostics)
            SettingsAboutBucket()
        }
        .navigationTitle("Settings")
    }
}
