#if !os(macOS)
import SwiftUI

/// Metadata-only recordings list for the last 24 hours. The watch
/// surfaces events the iPhone has already captured into the App
/// Group's `RecentMotionEvents.plist`. Playback happens on the
/// iPhone — tapping a row could later use NSUserActivity to hand off,
/// but v1 keeps the watch screen as a read-only digest.
struct WatchRecordingsView: View {
    @State private var events: [WatchSharedContainer.RecentMotionEvent] = []

    /// 86_400s — the agreed v1 window.
    private static let window: TimeInterval = 24 * 60 * 60

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in the last 24 h", systemImage: "moon.zzz")
                } description: {
                    Text("Motion events will appear here as your cameras detect activity.")
                        .multilineTextAlignment(.center)
                }
            } else {
                List(events) { event in
                    WatchRecordingRow(event: event)
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Last 24 h")
        .task { await pollUntilCancelled() }
    }

    private func pollUntilCancelled() async {
        while !Task.isCancelled {
            let cutoff = Date().addingTimeInterval(-Self.window)
            events = WatchSharedContainer.Reader.readRecentMotionEvents()
                .filter { $0.timestamp >= cutoff }
            // 10s refresh: the underlying plist is updated by the
            // iPhone's notification pipeline, which fires only on
            // motion. Anything faster is wasted work.
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

private struct WatchRecordingRow: View {
    let event: WatchSharedContainer.RecentMotionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.cameraName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(event.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !event.aiTags.isEmpty {
                Text(event.aiTags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
#endif
