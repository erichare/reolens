import Foundation
import Observation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.app", category: "recordings")

/// Downloads a Reolink recording to a local `.mp4`. Uses **parallel HTTP
/// Range requests** to multiply throughput on hubs that rate-limit each TCP
/// connection (~200 KB/s on Home Hub Pro), then falls back to a single
/// `URLSessionDownloadTask` if the endpoint doesn't honor `Range`.
///
/// Strategy:
///   1. Issue a probe `Range: bytes=0-1023` request. If the server replies
///      `206 Partial Content` with a parseable `Content-Range`, we have a
///      working ranged endpoint and a known total size.
///   2. Pre-allocate a single output file. Slice the byte range into
///      `chunkSize`-byte segments and run a bounded number in parallel,
///      each writing to its byte offset in the output file.
///   3. If the probe returns 200 or the headers don't make sense, fall back
///      to a plain single-stream `URLSessionDownloadTask`.
///
/// Trade-off: parallel ranged is materially faster but each chunk completes
/// atomically, so progress updates step (not per-byte). We chose a 1 MB
/// chunk for a balance — even a 60 MB file produces ~60 progress updates,
/// which feels smooth in the UI.
@MainActor
@Observable
public final class RecordingDownloader {
    // Properties are `public` (not `package`) because Xcode 16's @Observable
    // macro expansion conflicts with `package` on tracked properties — it
    // emits `@ObservationIgnored private package var _state` for the
    // backing storage and the compiler flags `private` + `package` as
    // incompatible access modifiers. `public` doesn't trigger the same
    // expansion path. (Xcode 17's macro is more permissive but CI still
    // builds on Xcode 16.) The class itself is `public` so the property
    // access modifier isn't more open than the type.
    public var state: State = .idle
    public var bytesReceived: Int64 = 0
    public var totalBytes: Int64 = 0
    public var localURL: URL?

    public enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    /// Bytes per ranged chunk. 1 MB is a good balance — small enough that
    /// progress updates frequently, large enough that per-chunk overhead is
    /// negligible.
    private static let chunkSize: Int64 = 1024 * 1024
    /// Concurrent in-flight chunks. The hub typically allows several
    /// simultaneous CGI sessions; 4 is conservative and avoids overwhelming
    /// the host on slower hardware.
    private static let concurrency = 4
    /// Anything smaller than this falls back to single-stream; the parallel
    /// path has too much setup overhead to pay back for tiny files.
    private static let minSizeForParallel: Int64 = 512 * 1024

    private let session: URLSession
    private var workTask: Task<Void, Never>?
    private var legacyTask: URLSessionDownloadTask?
    private var legacyObservations: [NSKeyValueObservation] = []

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        // Plenty of headroom over `concurrency` so the URLSession layer
        // doesn't queue our tasks behind itself.
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Cache

    /// Cache directory under `~/Library/Caches/Reolens/recordings/`.
    /// iOS may purge it under disk pressure; macOS persists it until
    /// the user clears system caches. The downloader writes every
    /// completed recording here so re-tapping a clip the user has
    /// already watched is a zero-byte cache hit, not a fresh
    /// download. Reolink recordings are immutable for a given
    /// (camera, timestamp) — safe to cache without invalidation.
    nonisolated static func cacheDirectory() -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Reolens", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Compute the cache filename for a given Reolink download URL.
    /// Uses the `?source=` query parameter — that's the canonical
    /// recording filename the CGI Download endpoint expects, and it
    /// uniquely identifies the clip across cameras and time. Returns
    /// nil if the URL doesn't have a `source` param (which means it
    /// isn't a Reolink Download URL we should be caching anyway).
    nonisolated static func cacheFilename(for downloadURL: URL) -> String? {
        guard let components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let source = items.first(where: { $0.name == "source" })?.value,
              !source.isEmpty
        else { return nil }
        // Source names are filesystem-friendly on Reolink hubs
        // (Mp4Record_2026-05-12_06h44m13s_xxx.mp4 style), but defend
        // against the rare colon / slash anyway.
        var safe = source
        for bad in ["/", ":", "\\"] {
            safe = safe.replacingOccurrences(of: bad, with: "_")
        }
        // Ensure .mp4 extension so the OS recognizes the type when
        // AVPlayer loads from disk.
        if !safe.lowercased().hasSuffix(".mp4") {
            safe += ".mp4"
        }
        return safe
    }

    /// Return the cached file URL for `downloadURL` if one exists on
    /// disk, otherwise nil. Used by `start(url:)` to short-circuit
    /// the download flow.
    nonisolated static func cachedFile(for downloadURL: URL) -> URL? {
        guard let dir = cacheDirectory(),
              let name = cacheFilename(for: downloadURL) else { return nil }
        let path = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Move a freshly-downloaded temp file into the cache so subsequent
    /// taps don't re-download. Returns the cache URL on success, or
    /// the original temp URL if the move failed (we still hand the
    /// caller a playable file even if caching failed).
    nonisolated static func promoteToCache(tempURL: URL, downloadURL: URL) -> URL {
        guard let dir = cacheDirectory(),
              let name = cacheFilename(for: downloadURL) else { return tempURL }
        let cachePath = dir.appendingPathComponent(name)
        // Overwrite any stale cache entry (shouldn't happen since we
        // check the cache before downloading, but harmless and keeps
        // the move from failing with "file exists").
        try? FileManager.default.removeItem(at: cachePath)
        do {
            try FileManager.default.moveItem(at: tempURL, to: cachePath)
            return cachePath
        } catch {
            log.warning("Cache promote failed: \(error.localizedDescription, privacy: .public)")
            return tempURL
        }
    }

    /// Whether `url` lives inside our recordings cache directory.
    /// Used by `cleanupTempFile` to avoid deleting cached files —
    /// only partial / cancelled downloads outside the cache should
    /// be cleaned up on dismiss.
    nonisolated static func isInCacheDirectory(_ url: URL) -> Bool {
        guard let cacheDir = cacheDirectory() else { return false }
        return url.path.hasPrefix(cacheDir.path)
    }

    // MARK: - Logging helpers

    /// Return a description of `url` safe to write to the unified log:
    /// drops `user`, `password`, and `token` query parameters which Reolink's
    /// CGI endpoints accept as plaintext credentials when no session cookie
    /// is available. AGENTS.md §3 — never log credentials.
    static func sanitizedDescription(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // No query parameters to worry about — but also no way to be
            // sure, so return only the scheme + host + path.
            return "\(url.scheme ?? "?"):\(url.host ?? "?")\(url.path)"
        }
        let credentialNames: Set<String> = ["user", "password", "token"]
        components.queryItems = components.queryItems?.filter { !credentialNames.contains($0.name) }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? "<unparseable URL>"
    }

    public func start(url: URL) {
        cancel()
        bytesReceived = 0
        totalBytes = 0
        localURL = nil

        // Cache check: if we've already downloaded this recording in a
        // previous session, jump straight to .ready with the cached
        // file. Reolink recordings are immutable (a given timestamped
        // clip never changes), so a content-stable cache hit is always
        // safe to serve without re-downloading.
        if let cached = Self.cachedFile(for: url) {
            log.info("Using cached recording at \(cached.path, privacy: .public)")
            localURL = cached
            // Report the full size up front so the UI doesn't flash a
            // progress bar at zero before switching to .ready.
            if let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? Int64) {
                totalBytes = size
                bytesReceived = size
            }
            state = .ready
            return
        }

        state = .downloading
        // The download URL embeds Reolink session tokens (and, in the
        // tokenless fallback, the camera username and password as query
        // parameters). Strip those before logging — `os.Logger` keeps the
        // unified log around across reboots, so a `.public` log of the
        // raw URL would leak credentials. See AGENTS.md §3.
        log.info("Starting download \(Self.sanitizedDescription(of: url), privacy: .public)")
        workTask = Task { [weak self] in
            await self?.run(url: url)
        }
    }

    public func cancel() {
        workTask?.cancel()
        workTask = nil
        legacyTask?.cancel()
        legacyTask = nil
        legacyObservations.forEach { $0.invalidate() }
        legacyObservations.removeAll()
    }

    /// Clean up a partial / mid-cancel download. NO-OP for fully
    /// cached files — those persist across sessions so taps that
    /// re-open a previously-watched recording skip the download
    /// entirely (the cache hit in `start(url:)` handles it).
    public func cleanupTempFile() {
        guard let url = localURL else { return }
        // Files inside the cache directory are kept; the system
        // purges them under disk pressure. Files outside are
        // partial-download artifacts that should be deleted.
        if Self.isInCacheDirectory(url) { return }
        try? FileManager.default.removeItem(at: url)
        localURL = nil
    }

    // MARK: - Strategy selection

    private func run(url: URL) async {
        // Race a HEAD probe vs a 5-second deadline. HEAD avoids the trap
        // where the server ignores `Range` and `session.data(for:)` ends up
        // dutifully downloading the whole file before we can check headers.
        let probeResult = await probeWithTimeout(url: url, timeout: 5)
        switch probeResult {
        case .ranged(let total):
            if total >= Self.minSizeForParallel {
                log.info("Range support OK; total=\(total) bytes — using parallel download (\(Self.concurrency) chunks of \(Self.chunkSize / 1024) KB)")
                await downloadParallel(url: url, total: total)
                return
            } else {
                log.info("File too small for parallel split (total=\(total)); falling back to single-stream")
            }
        case .unsupported(let reason):
            log.info("No range support — \(reason, privacy: .public); falling back to single-stream")
        case .timeout:
            log.warning("Probe timed out after 5s; falling back to single-stream")
        }

        await downloadSingleStream(url: url)
    }

    /// Parse `Content-Range: bytes 0-1023/45678` and return the trailing
    /// total. Returns nil if the header is missing or malformed.
    private func parseContentRangeTotal(http: HTTPURLResponse) -> Int64? {
        guard let header = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        // Format: "bytes start-end/total" or "bytes start-end/*".
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let totalPart = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(totalPart)
    }

    private enum ProbeOutcome {
        case ranged(total: Int64)
        case unsupported(reason: String)
        case timeout
    }

    /// Run a HEAD probe (with a Range-GET fallback) under a hard deadline.
    /// The deadline matters because `session.data(for:)` on a non-Range-
    /// aware endpoint will faithfully stream the entire response, defeating
    /// the whole point of a probe.
    private func probeWithTimeout(url: URL, timeout: TimeInterval) async -> ProbeOutcome {
        await withTaskGroup(of: ProbeOutcome.self) { [session] group in
            group.addTask {
                // Try HEAD first — it returns headers only, no body, and is
                // honored by Reolink's CGI on recent firmware.
                var headReq = URLRequest(url: url)
                headReq.httpMethod = "HEAD"
                headReq.cachePolicy = .reloadIgnoringLocalCacheData
                do {
                    let (_, response) = try await session.data(for: headReq)
                    guard let http = response as? HTTPURLResponse else {
                        return .unsupported(reason: "HEAD returned non-HTTP response")
                    }
                    let ar = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "<none>"
                    let cl = http.value(forHTTPHeaderField: "Content-Length") ?? "<none>"
                    log.info("HEAD probe: HTTP \(http.statusCode) Accept-Ranges=\(ar, privacy: .public) Content-Length=\(cl, privacy: .public)")
                    if http.statusCode == 200,
                       ar.lowercased().contains("bytes"),
                       let n = Int64(cl), n > 0 {
                        return .ranged(total: n)
                    }
                    if http.statusCode == 405 || http.statusCode == 501 {
                        // HEAD not supported — try a tiny Range GET instead.
                        return await Self.probeViaRangeGet(url: url, session: session)
                    }
                    return .unsupported(reason: "HEAD HTTP \(http.statusCode) Accept-Ranges=\(ar)")
                } catch {
                    log.info("HEAD probe errored (\(error.localizedDescription, privacy: .public)); trying Range GET")
                    return await Self.probeViaRangeGet(url: url, session: session)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout
            }
            let outcome = await group.next() ?? .timeout
            group.cancelAll()
            return outcome
        }
    }

    /// Range-GET probe: opens the connection, reads at most 1 KB, then
    /// cancels. Used when HEAD is rejected by the server.
    private static func probeViaRangeGet(url: URL, session: URLSession) async -> ProbeOutcome {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (asyncBytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unsupported(reason: "Range GET returned non-HTTP response")
            }
            let cr = http.value(forHTTPHeaderField: "Content-Range") ?? "<none>"
            log.info("Range-GET probe: HTTP \(http.statusCode) Content-Range=\(cr, privacy: .public)")
            // Consume up to 1 KB then drop the connection — we don't want
            // the whole file streaming back if the server ignored Range.
            var read = 0
            for try await _ in asyncBytes {
                read += 1
                if read >= 1024 { break }
            }
            if http.statusCode == 206, let slash = cr.lastIndex(of: "/"),
               let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                return .ranged(total: total)
            }
            return .unsupported(reason: "HTTP \(http.statusCode), Content-Range=\(cr)")
        } catch {
            return .unsupported(reason: "Range GET error: \(error.localizedDescription)")
        }
    }

    // MARK: - Parallel ranged download

    private func downloadParallel(url: URL, total: Int64) async {
        // 1. Pre-allocate output file with the final size so each chunk task
        //    can seek to its offset and write.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-\(UUID().uuidString).mp4")
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            await finishWithFailure("Cannot create output file")
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: dest)
            try handle.truncate(atOffset: UInt64(total))
        } catch {
            try? FileManager.default.removeItem(at: dest)
            await finishWithFailure("Couldn't open output: \(error.localizedDescription)")
            return
        }

        totalBytes = total
        localURL = dest
        let writer = OffsetWriter(handle: handle)
        let progress = ProgressCounter()

        // 2. Slice [0, total) into chunkSize-byte ranges.
        var ranges: [(start: Int64, end: Int64)] = []
        var cursor: Int64 = 0
        while cursor < total {
            let end = min(cursor + Self.chunkSize - 1, total - 1)
            ranges.append((cursor, end))
            cursor = end + 1
        }

        // 4. Run with bounded concurrency. TaskGroup with manual gating gives
        //    us "at most N in flight" without an external semaphore.
        do {
            try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                var inFlight = 0
                var iterator = ranges.makeIterator()

                func launchNext() {
                    guard let range = iterator.next() else { return }
                    inFlight += 1
                    let chunkIdx = inFlight
                    group.addTask { [session] in
                        try Task.checkCancellation()
                        let started = Date()
                        log.debug("chunk[\(chunkIdx)] launching bytes=\(range.start)-\(range.end) (\(range.end - range.start + 1) bytes)")
                        var req = URLRequest(url: url)
                        req.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        let (data, response) = try await session.data(for: req)
                        let elapsed = Date().timeIntervalSince(started)
                        let http = response as? HTTPURLResponse
                        log.info("chunk[\(chunkIdx)] done bytes=\(range.start)-\(range.end) status=\(http?.statusCode ?? -1) received=\(data.count) bytes in \(elapsed, format: .fixed(precision: 2))s (\(Double(data.count) / 1024 / max(elapsed, 0.001), format: .fixed(precision: 0)) KB/s)")
                        if let http, http.statusCode >= 400 {
                            throw URLError(.badServerResponse, userInfo: [
                                "status": http.statusCode,
                                "range": "\(range.start)-\(range.end)"
                            ])
                        }
                        return (range.start, data)
                    }
                }

                for _ in 0..<min(Self.concurrency, ranges.count) {
                    launchNext()
                }

                while let result = try await group.next() {
                    inFlight -= 1
                    let (offset, data) = result
                    try await writer.write(data, at: offset)
                    let received = await progress.add(Int64(data.count))
                    self.bytesReceived = received
                    launchNext()
                    if Task.isCancelled { throw CancellationError() }
                }
                _ = inFlight  // suppress unused-warning under release
            }
        } catch is CancellationError {
            await writer.close()
            try? FileManager.default.removeItem(at: dest)
            localURL = nil
            return
        } catch {
            await writer.close()
            try? FileManager.default.removeItem(at: dest)
            localURL = nil
            await finishWithFailure("Chunk download failed: \(error.localizedDescription)")
            return
        }

        await writer.close()
        let finalSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? total
        // Move the completed file into the cache directory so a future
        // tap on the same recording skips the download entirely. The
        // promote helper returns the new path on success, or the temp
        // path unchanged on failure (still playable, just not cached).
        let final = Self.promoteToCache(tempURL: dest, downloadURL: url)
        log.info("Parallel download complete: \(finalSize) bytes → \(final.lastPathComponent, privacy: .public)")
        localURL = final
        bytesReceived = total
        state = .ready
    }

    // MARK: - Legacy single-stream fallback

    private func downloadSingleStream(url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let task = session.downloadTask(with: url) { [weak self] tmpURL, response, error in
                // CRITICAL: URLSession deletes the temp file immediately after
                // this closure returns. Move it SYNCHRONOUSLY here — do not
                // hop to MainActor first or the file will already be gone.
                let outcome = Self.relocateDownload(tmpURL: tmpURL, response: response, error: error)
                Task { @MainActor [weak self] in
                    self?.finishSingleStream(outcome: outcome, downloadURL: url)
                    cont.resume()
                }
            }
            let recvObs = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
                let n = task.countOfBytesReceived
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.bytesReceived = n
                    if n > self.totalBytes { self.totalBytes = n }
                }
            }
            let expObs = task.observe(\.countOfBytesExpectedToReceive, options: [.initial, .new]) { [weak self] task, _ in
                let n = task.countOfBytesExpectedToReceive
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let resolved = max(0, n)
                    if resolved > self.totalBytes && resolved >= self.bytesReceived {
                        self.totalBytes = resolved
                    }
                }
            }
            self.legacyTask = task
            self.legacyObservations = [recvObs, expObs]
            task.resume()
        }
    }

    private enum SingleStreamOutcome {
        case success(destination: URL, size: Int64)
        case cancelled
        case failure(String)
    }

    /// Runs on the URLSession callback thread (NOT MainActor). Moves the
    /// completion-handler tmp file out of URLSession's auto-delete window
    /// and into a stable path under our temp dir.
    nonisolated private static func relocateDownload(tmpURL: URL?, response: URLResponse?, error: (any Error)?) -> SingleStreamOutcome {
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return .cancelled }
            return .failure("\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // User-visible failure text must never carry the URL —
            // it embeds `user=…&password=…` for the Download CGI.
            // The status code alone is enough to tell the user the
            // hub refused the download. Internal log line below uses
            // `LogRedaction.redact(_:)` for the same reason.
            log.error("Download HTTP \(http.statusCode) from \(LogRedaction.redact(response?.url), privacy: .public)")
            return .failure("HTTP \(http.statusCode) from camera.")
        }
        guard let tmpURL else {
            return .failure("Download produced no file.")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            return .success(destination: dest, size: size)
        } catch {
            return .failure("Couldn't move downloaded file: \(error.localizedDescription)")
        }
    }

    private func finishSingleStream(outcome: SingleStreamOutcome, downloadURL: URL) {
        legacyObservations.forEach { $0.invalidate() }
        legacyObservations.removeAll()
        legacyTask = nil

        switch outcome {
        case .cancelled:
            return
        case .failure(let message):
            log.error("Download failed: \(message, privacy: .public)")
            state = .failed(message)
        case .success(let dest, let size):
            // Move the completed file into the cache so re-taps don't
            // re-download. Falls back to the original temp path on
            // failure — the file is still playable, just not cached.
            let final = Self.promoteToCache(tempURL: dest, downloadURL: downloadURL)
            log.info("Single-stream download done: \(size) bytes → \(final.lastPathComponent, privacy: .public)")
            if totalBytes <= 0 { totalBytes = size }
            bytesReceived = size
            localURL = final
            state = .ready
        }
    }

    private func finishWithFailure(_ message: String) async {
        log.error("\(message, privacy: .public)")
        state = .failed(message)
    }
}

/// Serializes writes to a single file handle across the parallel-download
/// task group. Each chunk task hands off `(data, offset)` and awaits a
/// single seek-and-write under the actor's isolation.
private actor OffsetWriter {
    private var handle: FileHandle?
    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data, at offset: Int64) throws {
        guard let handle else { throw URLError(.cancelled) }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// Lightweight cumulative byte counter shared across parallel chunk tasks.
/// Returns the new running total so the caller can publish it.
private actor ProgressCounter {
    private var total: Int64 = 0
    func add(_ n: Int64) -> Int64 {
        total += n
        return total
    }
}
