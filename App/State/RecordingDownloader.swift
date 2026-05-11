import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "recordings")

/// Downloads a Reolink recording to a local `.mp4` file using
/// `URLSessionDownloadTask`. Reports bytes/total via KVO on `task.progress`.
///
/// The previous implementation streamed bytes via `URLSession.bytes(from:)`,
/// which despite the name iterates one byte at a time through Swift's async
/// machinery — it caps throughput at ~100 KB/s and is unusable for binary
/// payloads. `URLSessionDownloadTask` runs at the OS-native socket speed.
@MainActor
@Observable
final class RecordingDownloader {
    var state: State = .idle
    var bytesReceived: Int64 = 0
    var totalBytes: Int64 = 0
    var localURL: URL?

    enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private var task: URLSessionDownloadTask?
    private var receivedObservation: NSKeyValueObservation?
    private var expectedObservation: NSKeyValueObservation?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800   // 30 min for very large files
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil                       // never cache recordings — they can be huge
        self.session = URLSession(configuration: config)
    }

    func start(url: URL) {
        cancel()
        state = .downloading
        bytesReceived = 0
        totalBytes = 0

        log.info("Starting download \(url.absoluteString, privacy: .public)")
        let downloadTask = session.downloadTask(with: url) { [weak self] tmpURL, response, error in
            Task { @MainActor [weak self] in
                self?.handleCompletion(tmpURL: tmpURL, response: response, error: error)
            }
        }

        // Observe the dedicated byte-count properties — these are guaranteed
        // to be byte values, unlike `task.progress.completedUnitCount` which
        // can use abstract 0..100 percentage units depending on the platform.
        receivedObservation = downloadTask.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
            let received = task.countOfBytesReceived
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bytesReceived = received
                // Reolink's `Content-Length` is sometimes a stale estimate
                // from the original Search response, smaller than the actual
                // file. Bump the displayed total so the progress bar never
                // exceeds 100% and the labels stay honest.
                if received > self.totalBytes {
                    self.totalBytes = received
                }
            }
        }
        expectedObservation = downloadTask.observe(\.countOfBytesExpectedToReceive, options: [.initial, .new]) { [weak self] task, _ in
            let expected = task.countOfBytesExpectedToReceive
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = max(0, expected)
                // Only adopt the server's expected total if we haven't already
                // observed more bytes than that.
                if resolved > self.totalBytes && resolved >= self.bytesReceived {
                    self.totalBytes = resolved
                }
            }
        }

        self.task = downloadTask
        downloadTask.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        receivedObservation?.invalidate()
        receivedObservation = nil
        expectedObservation?.invalidate()
        expectedObservation = nil
    }

    func cleanupTempFile() {
        if let localURL {
            try? FileManager.default.removeItem(at: localURL)
            self.localURL = nil
        }
    }

    private func handleCompletion(tmpURL: URL?, response: URLResponse?, error: (any Error)?) {
        receivedObservation?.invalidate()
        receivedObservation = nil
        expectedObservation?.invalidate()
        expectedObservation = nil
        task = nil

        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("\(error)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            state = .failed("HTTP \(http.statusCode) from camera. URL: \(response?.url?.absoluteString ?? "?")")
            return
        }
        guard let tmpURL else {
            state = .failed("Download produced no file.")
            return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            log.info("Download done: \(size) bytes → \(dest.lastPathComponent, privacy: .public)")
            // If `countOfBytesExpectedToReceive` was -1 (server didn't send
            // Content-Length), the on-screen total stays 0 during the
            // download. Backfill it from the final file size so the UI
            // doesn't look stuck right before play.
            if totalBytes <= 0 { totalBytes = size }
            bytesReceived = size
            localURL = dest
            state = .ready
        } catch {
            state = .failed("Couldn't move downloaded file: \(error)")
        }
    }
}
