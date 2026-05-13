import WidgetKit
import SwiftUI
import ActivityKit
import AppShared

/// Lock Screen + Dynamic Island rendering for the in-flight motion-
/// event Live Activity. The activity is started + updated + ended
/// by `MotionEventActivityController` in the main app
/// ([AppiOS/Sources/LiveActivities/MotionEventActivityController.swift]).
@available(iOS 26.0, *)
public struct MotionEventActivityWidget: Widget {

    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotionEventActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.cameraName)
                            .font(.headline)
                        if !context.state.aiTags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(context.state.aiTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                                }
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let path = context.state.triggerFrameRelativePath,
                       let dir = SharedContainer.activityAssetsDirectory,
                       let data = try? Data(contentsOf: dir.appending(path: path)),
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: 120)
                    }
                }
            } compactLeading: {
                Image(systemName: "video.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 50)
            } minimal: {
                Image(systemName: "video.fill")
            }
        }
    }
}

@available(iOS 26.0, *)
struct LockScreenView: View {
    let context: ActivityViewContext<MotionEventActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            if let path = context.state.triggerFrameRelativePath,
               let dir = SharedContainer.activityAssetsDirectory,
               let data = try? Data(contentsOf: dir.appending(path: path)),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ZStack {
                    Color.gray.opacity(0.3)
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.cameraName)
                    .font(.headline)
                if !context.state.aiTags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(context.state.aiTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                }
                if context.state.coalescedCount > 0 {
                    Text("+\(context.state.coalescedCount) more events")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(context.attributes.startedAt, style: .relative)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
