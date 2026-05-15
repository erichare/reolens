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

    /// Bytes per ranged chunk. 4 MB is larger than the historic 1 MB because
    /// fewer larger chunks dominate fewer-but-larger round trips and let
    /// TCP windows grow on LAN. Still small enough that 8-way concurrency
    /// scales: 8 × 4 MB = 32 MB peak pipeline. Progress updates still
    /// arrive ~once per 4 MB, which is smooth enough for the UI.
    private static let chunkSize: Int64 = 4 * 1024 * 1024
    /// Concurrent in-flight chunks. Reolink hubs sustain many parallel
    /// CGI sessions on LAN; the per-TCP-connection cap is the real
    /// bottleneck and the parallel path exists specifically to defeat
    /// it. 8 matches what the official app appears to do.
    private static let concurrency = 8
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
        config.httpMaximumConnectionsPerHost = 16
        config.urlCache = nil
        // Higher-priority QoS for the network path so the downloader
        // isn't starved by background work when the user is staring
        // at a progress bar.
        config.networkServiceType = .responsiveData
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
        // No more pre-download probe — historically we did a HEAD probe
        // under a 5-second deadline before any byte arrived, which on a
        // busy hub added ~1-3s of pure latency before we even started.
        // Instead we issue the first chunk as the actual download:
        //   * If the server replies 206 with Content-Range, we have the
        //     total size AND the first chunk's bytes already. We seed
        //     the output file and run the remaining chunks in parallel.
        //   * If the server replies 200 (Range ignored), the body IS
        //     the whole file. We finish via the single-stream path
        //     without re-issuing the request.
        await runOptimistic(url: url)
    }

    /// Issue the first ranged GET as the first chunk of the download.
    /// Skips the historical HEAD probe so time-to-first-byte equals
    /// time-to-first-chunk.
    private func runOptimistic(url: URL) async {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-\(Self.chunkSize - 1)", forHTTPHeaderField: "Range")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                await finishWithFailure("Server returned non-HTTP response")
                return
            }
            if http.statusCode == 206,
               let total = parseContentRangeTotal(http: http),
               total >= Self.minSizeForParallel {
                log.info("Optimistic first chunk got 206 (\(data.count) bytes); total=\(total) — parallel download (\(Self.concurrency) chunks of \(Self.chunkSize / 1024 / 1024) MB)")
                await downloadParallel(url: url, total: total, firstChunk: data)
                return
            }
            if http.statusCode == 206 {
                // 206 but total too small (or unparseable Content-Range):
                // we already have the file — write it out and finish.
                log.info("Optimistic first chunk got 206 but file is small/unparseable; saving directly (\(data.count) bytes)")
                await finishWithSingleData(data, downloadURL: url)
                return
            }
            if http.statusCode == 200 {
                // Server ignored Range and is streaming the whole file.
                // `session.data(for:)` already returned the full body in
                // `data`, so just write it and finish — same outcome as
                // the legacy single-stream path, minus the wasted probe.
                log.info("Server ignored Range header (HTTP 200, \(data.count) bytes) — saving directly")
                await finishWithSingleData(data, downloadURL: url)
                return
            }
            // Any other status — bail with a friendly error.
            await finishWithFailure("HTTP \(http.statusCode) from camera.")
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return }
            // First-chunk transient failure → fall through to the
            // legacy delegate-driven single-stream download which has
            // its own retry/observation behavior. Logs the reason for
            // diagnosis.
            log.warning("Optimistic first chunk failed (\(error.localizedDescription, privacy: .public)); falling back to single-stream")
            await downloadSingleStream(url: url)
        }
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

    /// Persist `data` as the full downloaded file — used when the server
    /// returned 200 (ignored Range) or returned 206 but the file is too
    /// small to be worth splitting. Promotes to cache so a re-tap is a
    /// zero-byte hit.
    private func finishWithSingleData(_ data: Data, downloadURL: URL) async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-\(UUID().uuidString).mp4")
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            await finishWithFailure("Couldn't write file: \(error.localizedDescription)")
            return
        }
        let final = Self.promoteToCache(tempURL: dest, downloadURL: downloadURL)
        let size = Int64(data.count)
        totalBytes = size
        bytesReceived = size
        localURL = final
        state = .ready
    }

    // MARK: - Parallel ranged download

    /// Run the parallel download. The caller has already issued the
    /// first chunk (a `Range: bytes=0-(chunkSize-1)` GET); its bytes
    /// arrive in `firstChunk` and become chunk 0 of the layout, saving
    /// one round trip vs. re-issuing the same range.
    private func downloadParallel(url: URL, total: Int64, firstChunk: Data) async {
        // 1. Pre-allocate output file with the final size so each chunk task
        //    can open its own writable FileHandle, seek to the chunk's
        //    offset, and write without contending with sibling chunks.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-\(UUID().uuidString).mp4")
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            await finishWithFailure("Cannot create output file")
            return
        }
        // Pre-truncate once so the per-task handles see a file of the
        // right size when they seek.
        do {
            let h = try FileHandle(forWritingTo: dest)
            try h.truncate(atOffset: UInt64(total))
            try h.close()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            await finishWithFailure("Couldn't open output: \(error.localizedDescription)")
            return
        }

        totalBytes = total
        localURL = dest

        // 2. Write chunk 0 (already in hand from the optimistic first GET).
        //    Use a one-shot FileHandle write off the main actor — this is
        //    fast (memory-mapped on macOS) but we still keep the work off
        //    MainActor to avoid jitter on slow filesystems.
        let firstSize = Int64(firstChunk.count)
        do {
            try await Self.writeChunkToFile(dest: dest, offset: 0, data: firstChunk)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            await finishWithFailure("Couldn't write first chunk: \(error.localizedDescription)")
            return
        }
        bytesReceived = firstSize

        // 3. Slice [firstSize, total) into chunkSize-byte ranges.
        var ranges: [(start: Int64, end: Int64)] = []
        var cursor: Int64 = firstSize
        while cursor < total {
            let end = min(cursor + Self.chunkSize - 1, total - 1)
            ranges.append((cursor, end))
            cursor = end + 1
        }

        if ranges.isEmpty {
            // The first chunk was the whole file.
            let final = Self.promoteToCache(tempURL: dest, downloadURL: url)
            log.info("Parallel download complete in one chunk: \(total) bytes → \(final.lastPathComponent, privacy: .public)")
            localURL = final
            bytesReceived = total
            state = .ready
            return
        }

        // 4. Run with bounded concurrency. TaskGroup with manual gating
        //    gives us "at most N in flight" without an external semaphore.
        //    Each task writes its bytes through its own FileHandle and
        //    reports the count back; no shared writer actor contention.
        let progress = ProgressCounter()
        await progress.set(firstSize)
        do {
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var inFlight = 0
                var iterator = ranges.makeIterator()
                var chunkIndex = 1

                func launchNext() {
                    guard let range = iterator.next() else { return }
                    inFlight += 1
                    let idx = chunkIndex
                    chunkIndex += 1
                    group.addTask { [session, dest] in
                        try Task.checkCancellation()
                        let started = Date()
                        var req = URLRequest(url: url)
                        req.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        // Stream the response straight to disk via the
                        // chunk's own FileHandle. Avoids holding the
                        // whole chunk (~4 MB) in RAM and reduces the
                        // peak memory footprint to a small per-task
                        // I/O buffer.
                        let (asyncBytes, response) = try await session.bytes(for: req)
                        let http = response as? HTTPURLResponse
                        if let http, http.statusCode >= 400 {
                            throw URLError(.badServerResponse, userInfo: [
                                "status": http.statusCode,
                                "range": "\(range.start)-\(range.end)"
                            ])
                        }
                        let written = try await Self.streamChunkToFile(
                            dest: dest,
                            offset: range.start,
                            bytes: asyncBytes
                        )
                        let elapsed = Date().timeIntervalSince(started)
                        log.info("chunk[\(idx)] done bytes=\(range.start)-\(range.end) status=\(http?.statusCode ?? -1) received=\(written) bytes in \(elapsed, format: .fixed(precision: 2))s (\(Double(written) / 1024 / max(elapsed, 0.001), format: .fixed(precision: 0)) KB/s)")
                        return written
                    }
                }

                for _ in 0..<min(Self.concurrency, ranges.count) {
                    launchNext()
                }

                while let written = try await group.next() {
                    inFlight -= 1
                    let received = await progress.add(written)
                    self.bytesReceived = received
                    launchNext()
                    if Task.isCancelled { throw CancellationError() }
                }
                _ = inFlight  // suppress unused-warning under release
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: dest)
            localURL = nil
            return
        } catch {
            try? FileManager.default.removeItem(at: dest)
            localURL = nil
            await finishWithFailure("Chunk download failed: \(error.localizedDescription)")
            return
        }

        let finalSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? total
        // Move the completed file into the cache directory so a future
        // tap on the same recording skips the download entirely.
        let final = Self.promoteToCache(tempURL: dest, downloadURL: url)
        log.info("Parallel download complete: \(finalSize) bytes → \(final.lastPathComponent, privacy: .public)")
        localURL = final
        bytesReceived = total
        state = .ready
    }

    /// One-shot chunk write: open a FileHandle for writing, seek to
    /// `offset`, write `data`, close. Each call is independent so
    /// concurrent invocations on different offsets don't contend
    /// (Darwin's per-file-descriptor offset is per-handle, and the
    /// file is pre-truncated to final size).
    nonisolated private static func writeChunkToFile(
        dest: URL,
        offset: Int64,
        data: Data
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let h = try FileHandle(forWritingTo: dest)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: data)
        }.value
    }

    /// Streamed chunk write: open a FileHandle, seek to `offset`, and
    /// pipe `bytes` straight to disk in ~64 KB buffer increments so the
    /// whole chunk never lives in RAM at once. Returns the total bytes
    /// written so progress reporting stays accurate.
    nonisolated private static func streamChunkToFile(
        dest: URL,
        offset: Int64,
        bytes: URLSession.AsyncBytes
    ) async throws -> Int64 {
        let h = try FileHandle(forWritingTo: dest)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try h.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try h.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        return written
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

/// Lightweight cumulative byte counter shared across parallel chunk tasks.
/// Returns the new running total so the caller can publish it. The
/// downloader's previous single-FileHandle `OffsetWriter` was removed
/// in favor of per-task FileHandles so chunk writes no longer
/// serialize through a shared actor — `pwrite`-style independent
/// seek-and-write on a pre-allocated file is safe on Darwin.
private actor ProgressCounter {
    private var total: Int64 = 0
    func add(_ n: Int64) -> Int64 {
        total += n
        return total
    }
    func set(_ n: Int64) {
        total = n
    }
}
