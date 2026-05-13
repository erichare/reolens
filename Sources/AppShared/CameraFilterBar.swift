import SwiftUI

/// 0.5.1 — Multi-select chip row for filtering recordings by camera in
/// the All Recordings view. Mirrors `AIEventFilterBar` so the two pill
/// rows visually rhyme.
///
/// State is a `Binding<Set<CameraChannelKey>>` owned by the parent so
/// it survives sheet/tab dismissals and so the sidebar's camera
/// selection can drive it (selecting one camera in the sidebar narrows
/// the filter automatically).
///
/// An empty set means "show everything" — the bar renders an "All
/// Cameras" affordance and chips read as a soft prompt rather than a
/// hard "nothing matches" filter.
public struct CameraFilterBar: View {
    /// Stable identity for a (deviceID, channel) pair. Hub-scoped All
    /// Recordings only ever needs `channel` to disambiguate (deviceID
    /// is constant for the visible list), but keeping the device ID
    /// here lets the same component work cross-hub later without API
    /// churn.
    public struct CameraChannelKey: Hashable, Sendable {
        public let deviceID: UUID
        public let channel: Int
        public let label: String

        public init(deviceID: UUID, channel: Int, label: String) {
            self.deviceID = deviceID
            self.channel = channel
            self.label = label
        }
    }

    @Binding public var selected: Set<CameraChannelKey>
    public let cameras: [CameraChannelKey]

    public init(
        selected: Binding<Set<CameraChannelKey>>,
        cameras: [CameraChannelKey]
    ) {
        self._selected = selected
        self.cameras = cameras
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chipsRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var chipsRow: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { rawChipsRow }
        } else {
            rawChipsRow
        }
    }

    @ViewBuilder
    private var rawChipsRow: some View {
        HStack(spacing: 8) {
            allCamerasChip
            ForEach(cameras, id: \.self) { camera in
                chip(for: camera)
            }
        }
    }

    private var allCamerasChip: some View {
        let isOn = selected.isEmpty
        return Button {
            selected.removeAll()
        } label: {
            Label("All Cameras", systemImage: "rectangle.stack.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : .primary)
                .reolensGlassChip(selected: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All cameras")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func chip(for camera: CameraChannelKey) -> some View {
        let isOn = selected.contains(camera)
        return Button {
            if isOn { selected.remove(camera) } else { selected.insert(camera) }
        } label: {
            Label(camera.label, systemImage: "video.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : .primary)
                .reolensGlassChip(selected: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(camera.label) filter")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
