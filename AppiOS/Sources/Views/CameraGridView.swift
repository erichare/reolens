import SwiftUI
import ReolinkAPI
import AppShared

/// Multi-channel grid for NVR/Hub cameras on iOS/iPadOS.
///
/// Phase 4 ships the adaptive grid only — fixed N×N presets and
/// Spotlight layout come later. The adaptive grid sizes tiles to fit
/// the available width with a 16:9 (or 32:9 dual-lens) aspect, which
/// is the layout the macOS app defaults to anyway.
///
/// Tapping a tile pushes the per-channel detail. Long-press surfaces
/// the same context menu as macOS (rotate, make-primary).
struct CameraGridView: View {
    let session: CameraSession
    @Environment(CameraStore.self) private var store

    private var visibleChannels: [ChannelStatus] {
        store.orderedChannels(for: session.entry.id, channels: session.liveChannels)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(visibleChannels, id: \.channel) { channel in
                    NavigationLink {
                        SingleChannelView(session: session, channel: channel)
                    } label: {
                        let isDual = channel.isDualLens
                            || store.isDualLensOverride(deviceID: session.entry.id, channel: channel.channel)
                        LiveTileView(
                            session: session,
                            channel: channel,
                            stream: .sub
                        )
                        .aspectRatio(isDual ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Adaptive column layout. Two columns on iPhone, three on regular
    /// iPad, four when there's lots of horizontal room (landscape iPad
    /// Pro, Stage Manager wide). The minimum width is what controls the
    /// reflow point.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 600), spacing: 12)]
    }
}
