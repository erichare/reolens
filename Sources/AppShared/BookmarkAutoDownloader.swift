import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "bookmark-autodownload")

/// 0.5.1 — Schedules background downloads of bookmarked recordings so
/// the clip is available offline when the user wants to revisit it.
///
/// Architecture:
/// - Backed by a single `URLSessionConfiguration.background(...)`
///   session so the OS keeps the download going even when the app is
///   suspended or relaunched.
/// - `enqueue(bookmark:sourceURL:)` is idempotent — calling it twice
///   for the same bookmark doesn't queue a second download.
/// - Wi-Fi only by default to avoid surprising cellular usage; a
///   `Settings → Background downloads on cellular` toggle ships
///   later (0.5.2).
/// - Persists `taskDescription = bookmark.id.uuidString` so a relaunch
///   re-binds in-flight tasks to their bookmark records.
/// - Completed files land in
///   `~/Library/Application Support/Reolens/bookmarks/<bookmarkID>.mp4`
///   so they survive cache eviction.
///
/// The URLSession's delegate is a separate non-actor class so it can
/// conform to `URLSessionDownloadDelegate` (a non-Sendable protocol).
public final class BookmarkAutoDownloader: NSObject, @unchecked Sendable {
    public static let shared = BookmarkAutoDownloader()

    /// 0.5.1 — Post this when the cellular preference flips so the
    /// downloader can invalidate its session and pick up the new
    /// config. Posted by `BackgroundDownloadsSection`.
    public static let preferencesDidChange = Notification.Name("com.reolens.bookmarkDL.preferencesDidChange")

    private static let backgroundIdentifier = "com.reolens.bookmarkDL"
    /// Guarded by `queue`. The session pointer itself is also guarded
    /// because `applyPreferenceChange()` swaps it under the delegate's
    /// feet — without the guard, an in-flight `enqueue` could grab
    /// the old session reference and resume on it.
    private var session: URLSession
    private let queue = DispatchQueue(label: "com.reolens.bookmark-dl.state")
    private var tasksInFlight: Set<String> = []

    public override init() {
        self.session = Self.makeSession()
        super.init()
        // Rebuild the in-flight task ID set from any tasks the system
        // is still tracking from a previous app launch.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let ids = tasks.compactMap { $0.taskDescription }
            self.queue.async { self.tasksInFlight.formUnion(ids) }
        }
        // 0.5.1 — Listen for cellular toggle changes; invalidate
        // session so the next enqueue uses the new config. Pending
        // tasks finish on the prior config — acceptable trade-off
        // for an instant Settings toggle.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesDidChange),
            name: Self.preferencesDidChange,
            object: nil
        )
    }

    /// Read the current preferences and build a fresh background
    /// session. Factored out so `applyPreferenceChange()` can rebuild
    /// with the new config without duplicating the wiring.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        config.allowsCellularAccess = BackgroundDownloadPreferences.allowCellular
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: config,
            delegate: BookmarkAutoDownloadDelegate.shared,
            delegateQueue: delegateQueue
        )
    }

    @objc private func handlePreferencesDidChange() {
        queue.async { [weak self] in
            guard let self else { return }
            // Finish, then replace. `finishTasksAndInvalidate` lets
            // pending tasks complete on the old session — they'd
            // have completed under the old policy anyway, and
            // cancelling them mid-flight would lose progress.
            self.session.finishTasksAndInvalidate()
            self.session = Self.makeSession()
            log.info("BookmarkAutoDownloader session reconfigured (cellular=\(BackgroundDownloadPreferences.allowCellular))")
        }
    }

    /// Storage root for downloaded bookmark clips. Outside `Caches`
    /// so the OS can't reclaim a clip the user explicitly bookmarked.
    nonisolated public static var storageRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appending(path: "Reolens/bookmarks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Final destination path for a bookmark's clip. Deterministic so
    /// callers can probe for presence without round-tripping.
    nonisolated public static func localFileURL(for bookmark: RecordingBookmark) -> URL {
        Self.storageRoot.appending(path: "\(bookmark.id.uuidString).mp4")
    }

    /// True when this bookmark has a fully-downloaded local clip.
    nonisolated public static func hasLocalClip(for bookmark: RecordingBookmark) -> Bool {
        FileManager.default.fileExists(atPath: Self.localFileURL(for: bookmark).path)
    }

    /// Queue a background download for the given bookmark. Idempotent.
    /// If the file is already on disk OR a task with this bookmark ID
    /// is in flight, no new task is created.
    public func enqueue(bookmark: RecordingBookmark, sourceURL: URL) async {
        let dest = Self.localFileURL(for: bookmark)
        if FileManager.default.fileExists(atPath: dest.path) {
            log.info("Bookmark \(bookmark.id, privacy: .public) already downloaded; skip.")
            return
        }
        let bookmarkKey = bookmark.id.uuidString
        let shouldEnqueue: Bool = await withCheckedContinuation { cont in
            queue.async {
                if self.tasksInFlight.contains(bookmarkKey) {
                    cont.resume(returning: false)
                } else {
                    self.tasksInFlight.insert(bookmarkKey)
                    cont.resume(returning: true)
                }
            }
        }
        guard shouldEnqueue else {
            log.info("Bookmark \(bookmark.id, privacy: .public) download already in flight; skip.")
            return
        }
        let task = session.downloadTask(with: sourceURL)
        task.taskDescription = bookmarkKey
        task.resume()
        log.info("Bookmark \(bookmark.id, privacy: .public) download enqueued (task=\(task.taskIdentifier))")
    }

    /// Cancel an in-flight download. Returns true if a task was
    /// cancelled, false if nothing was queued.
    @discardableResult
    public func cancel(bookmarkID: UUID) async -> Bool {
        let key = bookmarkID.uuidString
        let tasks = await session.allTasks
        guard let task = tasks.first(where: { $0.taskDescription == key }) else { return false }
        task.cancel()
        queue.async { self.tasksInFlight.remove(key) }
        return true
    }

    /// Internal: move a completed download into the bookmark's
    /// permanent location. Called by the delegate.
    fileprivate func finalize(taskKey: String, tempLocation: URL) {
        guard let id = UUID(uuidString: taskKey) else { return }
        // Reconstruct the destination without needing the full
        // bookmark object — `localFileURL(for:)` only reads the ID.
        let dest = Self.storageRoot.appending(path: "\(id.uuidString).mp4")
        do {
            // Replace any partial file from a previous failed run.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempLocation, to: dest)
            log.info("Bookmark \(id, privacy: .public) download saved to disk")
        } catch {
            log.error("Bookmark \(id, privacy: .public) finalize failed: \(String(describing: error), privacy: .public)")
        }
        queue.async { self.tasksInFlight.remove(taskKey) }
    }

    fileprivate func forget(taskKey: String) {
        queue.async { self.tasksInFlight.remove(taskKey) }
    }
}

/// 0.5.1 — URLSession background delegate. A separate class so the
/// inherited NSObject + non-Sendable URLSessionDelegate methods don't
/// pollute the public Swift-Concurrency surface of
/// `BookmarkAutoDownloader`.
public final class BookmarkAutoDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = BookmarkAutoDownloadDelegate()

    private override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }
        // The temp file at `location` is deleted as soon as this
        // method returns, so we must move it synchronously here.
        BookmarkAutoDownloader.shared.finalize(taskKey: key, tempLocation: location)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            log.warning("Background download finished with error: \(String(describing: error), privacy: .public)")
        }
        if let key = task.taskDescription {
            BookmarkAutoDownloader.shared.forget(taskKey: key)
        }
    }
}
