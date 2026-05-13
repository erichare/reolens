import SwiftUI

/// 0.5.1 — Settings section for background-download behavior.
/// Single toggle for now (allow cellular); ships as a section so the
/// 0.5.2 follow-ups (per-camera downloads, max-disk-usage, etc.)
/// have a natural home.
public struct BackgroundDownloadsSection: View {
    @AppStorage(BackgroundDownloadPreferences.allowCellularKey)
    private var allowCellular: Bool = false

    public init() {}

    public var body: some View {
        Section {
            Toggle("Allow downloads on cellular", isOn: $allowCellular)
                .onChange(of: allowCellular) { _, _ in
                    // 0.5.1 — `BookmarkAutoDownloader` listens for
                    // this and rebuilds its background session so
                    // the new policy takes effect on the next
                    // enqueue. Pending downloads finish on the
                    // prior session.
                    NotificationCenter.default.post(
                        name: BookmarkAutoDownloader.preferencesDidChange,
                        object: nil
                    )
                }
        } header: {
            Text("Background downloads")
        } footer: {
            Text("When you bookmark a recording, Reolens downloads it in the background so it's available offline. By default downloads only run on Wi-Fi to keep cellular data low. Turn this on to allow them on cellular too. Already-pending downloads finish on the prior setting.")
        }
    }
}
