import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "icloud")

/// File-level iCloud Drive helper for `cameras.json`.
///
/// Resolves the app's ubiquity container, performs coordinated reads/writes
/// via `NSFileCoordinator`, and observes remote changes via `NSMetadataQuery`
/// so the in-memory model refreshes when another device (Mac/iPad/iPhone)
/// edits the file.
///
/// Falls back to a per-device local URL under Application Support when
/// iCloud is unavailable (user signed out, entitlement missing in a
/// sideloaded build, etc.). Callers do not special-case which storage is
/// active — the same `read()` / `write(_:)` API works for both.
@MainActor
package final class ICloudCameraStorage {
    package static let shared = ICloudCameraStorage()

    /// Visible to callers so the legacy `CameraStore.storageURL` can be
    /// kept around for logging / diagnostics. Path inside the ubiquity
    /// container is `Documents/cameras.json`; everything under
    /// `Documents/` is visible in the user's iCloud Drive Files app.
    package private(set) var currentURL: URL
    package var isUsingICloud: Bool { currentURL.path.contains("Mobile Documents") }

    private static let fileName = "cameras.json"
    private var metadataQuery: NSMetadataQuery?
    private var remoteChangeHandler: (@MainActor () -> Void)?
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let fm = FileManager.default
        if let cloudRoot = fm.url(forUbiquityContainerIdentifier: nil) {
            let docs = cloudRoot.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            self.currentURL = docs.appendingPathComponent(Self.fileName)
            log.info("Using iCloud storage at \(self.currentURL.path, privacy: .public)")
        } else {
            self.currentURL = Self.localFallbackURL()
            log.info("iCloud unavailable; using local storage at \(self.currentURL.path, privacy: .public)")
        }
    }

    /// One-shot coordinated read. Returns nil if the file does not yet
    /// exist (first-ever launch) or if the read errored. The coordinator
    /// blocks while another device is mid-write, so we get a consistent
    /// snapshot rather than a partial file.
    ///
    /// 0.6.2 — read failures on a file that exists (the second-device
    /// "iCloud download corrupt" case) now surface in Diagnostics
    /// Center via `AppErrorRecorder`. The first-launch nil case
    /// stays silent — that's the empty-by-design state, not an error.
    package func read() -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var data: Data?
        var readError: (any Error)?
        coordinator.coordinate(readingItemAt: currentURL, options: [], error: &coordError) { url in
            do {
                data = try Data(contentsOf: url)
            } catch CocoaError.fileReadNoSuchFile {
                // First-launch path; not an error worth recording.
            } catch {
                readError = error
            }
        }
        if let coordError {
            log.error("Read coord error: \(coordError.localizedDescription, privacy: .public)")
            // Pre-compute the Sendable path so the Task body doesn't
            // need to reach back into MainActor for it.
            let path = currentURL.lastPathComponent
            Task {
                await AppErrorRecorder.shared.record(
                    .persistence(.read(path: path)),
                    context: "iCloudStorage.coordinator"
                )
            }
        }
        if let readError {
            log.error("Read failed: \(readError.localizedDescription, privacy: .public)")
            let path = currentURL.lastPathComponent
            Task {
                await AppErrorRecorder.shared.record(
                    .persistence(.read(path: path)),
                    context: "iCloudStorage.read"
                )
            }
        }
        return data
    }

    /// One-shot coordinated atomic-replace write. Other devices observing
    /// the file will see a single complete update, never a torn write.
    package func write(_ data: Data) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: currentURL, options: .forReplacing, error: &coordError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("Write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let coordError {
            log.error("Write coord error: \(coordError.localizedDescription, privacy: .public)")
        }
    }

    /// Subscribe to remote-change notifications. Handler fires on the
    /// main actor when another device pushes a change (download finished,
    /// metadata changed). Also fires once on initial gather so the
    /// caller can reconcile any updates that landed while the app was
    /// off. Only meaningful when `isUsingICloud == true`.
    package func observeRemoteChanges(_ handler: @escaping @MainActor () -> Void) {
        remoteChangeHandler = handler
        guard isUsingICloud, metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)
        let center = NotificationCenter.default
        let gatherObs = center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.shared.remoteChangeHandler?()
            }
        }
        let updateObs = center.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.shared.remoteChangeHandler?()
            }
        }
        observers = [gatherObs, updateObs]
        query.start()
        metadataQuery = query
    }

    /// One-shot migration from the legacy Application Support
    /// `cameras.json` into the iCloud Documents container. Safe to call
    /// on every launch: no-ops when iCloud is not in use, when the
    /// iCloud copy already exists, or when there is no legacy file to
    /// migrate. Preserves the local copy as a backup — we do not delete
    /// it, in case the user disables iCloud later.
    package func migrateLegacyLocalIfNeeded() {
        guard isUsingICloud else { return }
        // safe: reachability probe — already-migrated is the common case.
        if (try? currentURL.checkResourceIsReachable()) == true { return }
        let legacy = Self.localFallbackURL()
        // safe: missing legacy is the common case (fresh install).
        guard let data = try? Data(contentsOf: legacy) else { return }
        write(data)
        log.info("Migrated legacy cameras.json into iCloud Documents")
    }

    private static func localFallbackURL() -> URL {
        let fm = FileManager.default
        // safe: fallback URL builder; Application Support is always
        // available on supported platforms — the `??` below covers the
        // unreachable sandboxed-test case.
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport?.appendingPathComponent("Reolens", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reolens", isDirectory: true)
        // safe: idempotent makeDir; existing-dir is the common case.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
}
