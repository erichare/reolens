import SwiftUI
import ReolinkAPI

/// Per-AI-tag notification toggles, added in 0.4.0. Sits beneath the
/// `notifyAI` master toggle in both macOS and iOS Settings surfaces so
/// users who get flooded by (say) every passing pet trigger can mute
/// that single category without losing person/vehicle alerts.
///
/// Backed by `EventNotifier.notifyPerTag`. The Form section is disabled
/// when the master AI toggle is off, mirroring the row-disabled
/// pattern macOS used in 0.3.0 for the AI/Motion sub-section.
public struct NotificationCategoriesSection: View {
    @Bindable public var notifier: EventNotifier
    public var categories: [DetectionType]

    public init(
        notifier: EventNotifier,
        categories: [DetectionType] = DetectionType.allCases.filter { $0 != .motion }
    ) {
        self.notifier = notifier
        self.categories = categories
    }

    public var body: some View {
        Section("AI event categories") {
            ForEach(categories, id: \.self) { tag in
                Toggle(isOn: binding(for: tag)) {
                    Label(tag.label, systemImage: tag.systemImage)
                }
            }
            Text("Mute individual AI categories without losing the others. Off categories don't fire notifications even when they trigger on the camera.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(!notifier.enabled || !notifier.notifyAI)
    }

    private func binding(for tag: DetectionType) -> Binding<Bool> {
        Binding(
            get: { notifier.notifyPerTag[tag] ?? true },
            set: { newValue in
                var copy = notifier.notifyPerTag
                copy[tag] = newValue
                notifier.notifyPerTag = copy
            }
        )
    }
}
