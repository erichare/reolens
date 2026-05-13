import AppIntents
import Foundation
import AppShared

/// Widget configuration intent — pick which camera the widget shows.
///
/// The intent stores only the camera UUID. The widget timeline-
/// provider resolves that UUID against the App-Group snapshots file
/// at render time, so no credentials or network traffic ever cross
/// the intent boundary. AGENTS.md §11, §16.
public struct SelectCameraIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Camera"
    public static let description = IntentDescription("Pick which camera this widget should display.")

    @Parameter(title: "Camera")
    public var camera: CameraQueryEntity?

    public init() {}

    public init(camera: CameraQueryEntity?) {
        self.camera = camera
    }
}

/// A camera reference as seen by widgets / Shortcuts. Sourced from
/// the shared App-Group snapshots file — no Keychain reads, no
/// camera network traffic during enumeration.
public struct CameraQueryEntity: AppEntity {

    public let id: UUID
    public let displayName: String

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    public static let defaultQuery = CameraQuery()

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct CameraQuery: EntityQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [CameraQueryEntity] {
        let snapshots = SharedContainer.readLatestSnapshots()
        return snapshots
            .filter { identifiers.contains($0.cameraID) }
            .map { CameraQueryEntity(id: $0.cameraID, displayName: $0.cameraName) }
    }

    public func suggestedEntities() async throws -> [CameraQueryEntity] {
        SharedContainer.readLatestSnapshots()
            .sorted { $0.cameraName < $1.cameraName }
            .map { CameraQueryEntity(id: $0.cameraID, displayName: $0.cameraName) }
    }
}
