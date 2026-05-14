import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "camera-list-persist")

/// 0.6.0 Slice 15c — list-persistence carve-out from CameraStore.
///
/// Owns the JSON encode/decode boundary around the iCloud-backed
/// camera list. CameraStore previously held this inline as
/// `load()` / `save()` / `reloadFromStorageIfChanged()` private
/// methods entangled with the rest of its state. Extracting them
/// gives:
///
/// - Unit-testable encode/decode + diff-on-reload without spinning
///   the whole CameraStore + iCloud-KVS / NSMetadataQuery harness.
/// - A clear seam for future migrations: e.g. adopting versioned-
///   Codable for `[CameraEntry]` only touches this file.
/// - A backend abstraction (`Backend` protocol) so tests can stub
///   the read/write side without poking the real
///   `ICloudCameraStorage`.
///
/// `@MainActor`-isolated because the production backend
/// (`ICloudCameraStorage`) is — and because callers (`CameraStore`'s
/// `load` / `save` / `reloadFromStorageIfChanged`) run on the main
/// actor. Tests can construct an instance from any context and
/// dispatch through `MainActor.run`.
@MainActor
public struct CameraListPersistence {

    /// Storage surface. Production conformance is
    /// `ICloudCameraStorageBackend` which forwards to the existing
    /// `ICloudCameraStorage.shared` singleton; tests substitute an
    /// in-memory implementation.
    public protocol Backend {
        @MainActor func read() -> Data?
        @MainActor func write(_ data: Data)
    }

    /// Shared production instance — uses the iCloud backend.
    public static let shared = CameraListPersistence(backend: ICloudCameraStorageBackend.shared)

    private let backend: any Backend

    public init(backend: any Backend) {
        self.backend = backend
    }

    /// Load the camera list from the backend. Returns nil when the
    /// backend has nothing yet (first launch on a fresh device) or
    /// when the on-disk bytes don't decode (treated as nil rather
    /// than throwing — callers fall back to the current in-memory
    /// list).
    public func load() -> [CameraEntry]? {
        guard let data = backend.read() else { return nil }
        return try? JSONDecoder().decode([CameraEntry].self, from: data)
    }

    /// Encode the supplied entries and write them through the
    /// backend. Failures are logged and dropped — the previous
    /// implementation also swallowed encode errors silently because
    /// `CameraEntry` is `Codable` with synthesized init and a stable
    /// shape, so a runtime failure here would only indicate a
    /// programming error rather than a recoverable runtime
    /// condition.
    public func save(_ entries: [CameraEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            log.error("Failed to encode camera list; skipping write")
            return
        }
        backend.write(data)
    }

    /// True when the bytes on the backend differ from the supplied
    /// `current` list. Used by the iCloud metadata-query handler to
    /// decide whether to publish a fresh `[CameraEntry]` (which
    /// triggers SwiftUI re-render) or leave the in-memory model
    /// alone (avoiding a needless tracker invalidation).
    public func hasChanged(comparedTo current: [CameraEntry]) -> Bool {
        guard let loaded = load() else { return false }
        return loaded != current
    }
}

// MARK: - Production backend

/// Forwards reads / writes to the existing `ICloudCameraStorage`
/// singleton so the migration is byte-for-byte equivalent to the
/// pre-Slice-15c behaviour.
@MainActor
public struct ICloudCameraStorageBackend: CameraListPersistence.Backend {
    public static let shared = ICloudCameraStorageBackend()
    public func read() -> Data? { ICloudCameraStorage.shared.read() }
    public func write(_ data: Data) { ICloudCameraStorage.shared.write(data) }
}
