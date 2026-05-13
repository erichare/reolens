import WidgetKit
import SwiftUI
import AppIntents
import AppShared

/// 0.5.0 Theme A1 — Control Center widget (iOS 26+). One-tap opens
/// the configured camera's live view in the main app via the
/// canonical `OpenCameraIntent` declared in
/// `Sources/AppShared/AppIntents/CameraIntents.swift`.
///
/// The intent only carries the camera entity (which itself only
/// exposes the UUID + display name); no credentials cross the
/// intent boundary. AGENTS.md §11, §16.
@available(iOS 26.0, *)
public struct OpenCameraControlWidget: ControlWidget {

    public static let kind = "io.reolens.controlWidget.openCamera"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: OpenCameraControlProvider()
        ) { value in
            ControlWidgetButton(action: intent(for: value)) {
                Label(value.cameraName, systemImage: "video.fill")
            }
        }
        .displayName("Open Reolens Camera")
        .description("Jump straight into a Reolink camera's live view.")
    }

    /// Build the `OpenCameraIntent` payload for this widget value.
    /// When `cameraID` is nil (no snapshots in the App-Group container
    /// yet — fresh install, never opened a camera), we synthesize a
    /// placeholder entity. The intent's `perform()` falls through to
    /// the main app, which surfaces the normal Add-Camera flow if the
    /// referenced ID doesn't exist locally.
    private func intent(for value: OpenCameraControlValue) -> OpenCameraIntent {
        let entity = CameraEntity(
            id: value.cameraID ?? UUID(),
            displayName: value.cameraName
        )
        return OpenCameraIntent(camera: entity)
    }
}

/// Value carried from the provider to the widget body. Plain struct
/// — iOS 26's `ControlValueProvider` accepts any `Sendable` type as
/// the associated `Value`; there is no `ControlValue` protocol.
@available(iOS 26.0, *)
public struct OpenCameraControlValue: Sendable {
    public let cameraID: UUID?
    public let cameraName: String

    public init(cameraID: UUID?, cameraName: String) {
        self.cameraID = cameraID
        self.cameraName = cameraName
    }
}

@available(iOS 26.0, *)
public struct OpenCameraControlProvider: AppIntentControlValueProvider {
    public init() {}

    public func previewValue(configuration: SelectCameraIntent) -> OpenCameraControlValue {
        OpenCameraControlValue(cameraID: nil, cameraName: "Reolens")
    }

    public func currentValue(configuration: SelectCameraIntent) async throws -> OpenCameraControlValue {
        let snapshots = SharedContainer.readLatestSnapshots()
        let snap = snapshots.first(where: { $0.cameraID == configuration.camera?.id })
            ?? snapshots.first
        return OpenCameraControlValue(
            cameraID: snap?.cameraID,
            cameraName: snap?.cameraName ?? "Reolens"
        )
    }
}
