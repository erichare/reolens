import SwiftUI
import ReolinkAPI

/// Multi-select chip row for filtering AI events in the recordings view.
/// Added in 0.4.0. Shared across macOS, iPadOS, and iPhone.
///
/// State is a `Binding<Set<DetectionType>>` owned by the parent so the
/// filter survives view-rebuilds (sheet/tab dismissal) and lets multiple
/// surfaces (recordings list, timeline scrubber, notification settings
/// later in 0.4.0) read the same selection.
///
/// An empty set means "show everything" — chips render greyed, the row
/// acts like a soft prompt rather than a hard "nothing matches" filter.
public struct AIEventFilterBar: View {
    @Binding public var selected: Set<DetectionType>
    /// Categories rendered as chips, in display order. Excludes `.motion`
    /// by default because plain motion is its own row in the recordings
    /// list; callers that want to filter on motion too can pass it in.
    public let categories: [DetectionType]

    public init(
        selected: Binding<Set<DetectionType>>,
        categories: [DetectionType] = DetectionType.allCases.filter { $0 != .motion }
    ) {
        self._selected = selected
        self.categories = categories
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.self) { tag in
                    chip(for: tag)
                }
                if !selected.isEmpty {
                    Button {
                        selected.removeAll()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func chip(for tag: DetectionType) -> some View {
        let isOn = selected.contains(tag)
        Button {
            if isOn { selected.remove(tag) } else { selected.insert(tag) }
        } label: {
            Label(tag.label, systemImage: tag.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.tertiary),
                    in: .capsule
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.label) filter")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
