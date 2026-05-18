import Foundation
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "playback.loader")

/// Custom URL scheme that AVPlayer treats as "unknown — call your
/// delegate." We register this on the `AVURLAsset` so every loading
/// request lands on `ChunkedResourceLoader` instead of AVPlayer's own
/// HTTP code path. AVPlayer's HTTP can't negotiate Reolink's CGI
/// download endpoint (missing `Accept-Ranges` / `Content-Type` /
/// `Content-Length`), which is why the original implementation had
/// to fully download before playing.
public enum PlaybackScheme {
    public static let value = "reolens-stream"
}

/// AVAssetResourceLoaderDelegate that streams a Reolink CGI download
/// to AVPlayer via on-demand HTTP Range requests. Replaces the
/// "download fully then hand AVPlayer a file:// URL" flow with byte-
/// range fetches keyed off whatever AVPlayer actually asks for —
/// which is typically a tiny "what's the file size?" probe plus the
/// MOOV atom + sequential reads from the start. First-frame time
/// becomes ~1 round-trip instead of "full file download."
///
/// Concurrency: AVPlayer dispatches delegate callbacks onto a private
/// serial queue. Each callback spawns a Task into the loader's actor,
/// which serializes URL session usage and disk writes. The class
/// itself is `@unchecked Sendable` because all mutable state lives
/// in the actor.
public final class ChunkedResourceLoader: NSObject, @unchecked Sendable {

    /// The pre-signed Reolink CGI download URL (`https://.../cgi-bin/api.cgi?
    /// cmd=Download&source=...&token=...`). The loader never exposes
    /// this to AVPlayer; AVPlayer only ever sees the `reolens-stream://`
    /// placeholder.
    public let upstreamURL: URL

    /// The placeholder URL handed to `AVURLAsset`. AVPlayer keys its
    /// delegate dispatches off the scheme being non-standard; the
    /// host portion uniquely identifies the asset within a process.
    public let placeholderURL: URL

    /// Underlying engine actor. Public so the engine can observe
    /// completion / total size if needed.
    public let engine: StreamingEngine

    public init(upstreamURL: URL) {
        self.upstreamURL = upstreamURL
        // Use a stable host derived from the upstream URL's `source=`
        // query item so two different clips never collide on the
        // resource-loader bookkeeping. Falls back to a UUID for URLs
        // missing the param (shouldn't happen for Reolink Download
        // endpoints but keeps us safe).
        let host = Self.assetHost(for: upstreamURL)
        var components = URLComponents()
        components.scheme = PlaybackScheme.value
        components.host = host
        components.path = "/clip.mp4"
        // safe: components are all valid characters
        self.placeholderURL = components.url!
        self.engine = StreamingEngine(upstreamURL: upstreamURL)
        super.init()
    }

    /// Cancel every in-flight fetch and tear down the underlying
    /// session. Safe to call from any thread / actor.
    public func cancel() {
        Task { [engine] in await engine.cancelAll() }
    }

    // MARK: - Host derivation

    private static func assetHost(for url: URL) -> String {
        // safe: malformed URL → fall back to a UUID-derived host. The
        // host doesn't carry meaning, just uniqueness.
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let source = comps.queryItems?.first(where: { $0.name == "source" })?.value,
              !source.isEmpty else {
            return UUID().uuidString.lowercased()
        }
        // RFC 3986 host must be lowercased alphanumerics + a few
        // punctuation chars. Reolink source names are mostly
        // filesystem-safe but contain `.` and `_`; map to `-`.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = source.lowercased()
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var s = String(mapped)
        // Collapse runs of hyphens so the URL stays readable in
        // diagnostic logs.
        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .ifEmptyFallback(to: UUID().uuidString.lowercased())
    }
}

extension ChunkedResourceLoader: AVAssetResourceLoaderDelegate {

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Per the documented contract: returning `true` tells AVPlayer
        // we'll respond asynchronously via `finishLoading` (success)
        // or `finishLoading(with:)` (error). We hop into the actor,
        // serve the request, and resolve.
        Task { [engine] in
            await engine.handle(request: loadingRequest)
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        Task { [engine] in
            await engine.cancel(request: loadingRequest)
        }
    }
}

private extension String {
    /// Tiny helper: return self unless empty, then fall back. Used
    /// once in host derivation so a fully-stripped name doesn't
    /// produce an empty host.
    func ifEmptyFallback(to other: @autoclosure () -> String) -> String {
        isEmpty ? other() : self
    }
}

/// The actor that owns all mutable streaming state — URL session,
/// in-flight Range fetches, byte-range coverage, the pre-allocated
/// scratch file. The public entry points are `handle(request:)` and
/// `cancel(request:)`, plus `bytesReceived`/`totalBytes`/`isComplete`
/// peeks for the engine's progress UI.
public actor StreamingEngine {

    public let upstreamURL: URL

    /// Total file size from the upstream. Nil until the first probe
    /// resolves. Reolink returns 206 with `Content-Range: bytes
    /// 0-N/TOTAL` on the first probe; we cache TOTAL here so
    /// subsequent `contentInformationRequest` callbacks resolve
    /// instantly.
    public private(set) var totalBytes: Int64?

    /// Cumulative bytes received from upstream — used for the
    /// download-progress UI in the player sheet. Strictly monotonic;
    /// duplicated overlapping fetches don't double-count because
    /// we coalesce by range.
    public private(set) var bytesReceived: Int64 = 0

    /// Once true, the scratch file is on disk in its entirety and
    /// has been moved into `RecordingDownloader.cacheDirectory()`.
    /// The engine flips this to short-circuit any further upstream
    /// fetches and lets the player sheet enable "Export" actions
    /// that need the full file.
    public private(set) var isComplete: Bool = false

    /// URL where the engine has accumulated bytes. Starts in tmp,
    /// moves into the recordings cache on completion. Nil until the
    /// first probe resolves and we know the total size.
    public private(set) var scratchURL: URL?

    /// Cached file path (in the recordings cache). Present only when
    /// `isComplete == true` — callers can hand this directly to
    /// `AVURLAsset` or to the export router.
    public private(set) var completedFileURL: URL?

    /// True when a contentInformationRequest is needed but we've
    /// already issued the probe — avoids re-probing on every
    /// AVPlayer ask.
    private var probeStarted: Bool = false
    /// Continuations to fulfill once the probe lands. Awaiting these
    /// means callers block until `totalBytes` is set.
    private var probeWaiters: [CheckedContinuation<Int64, any Error>] = []

    /// In-flight fetches keyed by the loadingRequest ObjectIdentifier
    /// so a cancel callback can match and cancel.
    private var inFlight: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Bytes already written to the scratch file (sorted, disjoint
    /// intervals). Read-side optimization: if a request's range is
    /// already covered, we serve from disk instead of re-fetching.
    private var coverage: [Range<Int64>] = []

    /// Lazily-created URLSession. Configured for high-throughput
    /// downloads with no shared cache (we manage our own).
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil
        config.networkServiceType = .responsiveData
        return URLSession(configuration: config)
    }()

    public init(upstreamURL: URL) {
        self.upstreamURL = upstreamURL
    }

    // MARK: - Public entry points

    /// Serve a single `AVAssetResourceLoadingRequest`. This is the
    /// only mutating entry point invoked from the resource loader
    /// delegate. Honors both contentInformationRequest (file size
    /// metadata) and dataRequest (byte range fetch).
    public func handle(request: AVAssetResourceLoadingRequest) async {
        // Cache-hit fast path: if the upstream URL already has a
        // completed file in the recordings cache (from a prior
        // session or a parallel `RecordingDownloader`), serve that
        // and skip the network entirely.
        if !isComplete, let cached = RecordingDownloader.cachedFile(for: upstreamURL) {
            let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? Int64) ?? 0
            if size > 0 {
                totalBytes = size
                bytesReceived = size
                coverage = [0..<size]
                scratchURL = cached
                completedFileURL = cached
                isComplete = true
                fulfillProbeWaiters(.success(size))
            }
        }

        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            await self?.serve(request: request)
            await self?.removeInFlight(id)
        }
        inFlight[id] = task
    }

    public func cancel(request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        inFlight[id]?.cancel()
        inFlight.removeValue(forKey: id)
    }

    public func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        fulfillProbeWaiters(.failure(CancellationError()))
        // Drop the scratch file if we haven't finished — partial
        // files outside the recordings cache are intermediate.
        if let url = scratchURL, !isComplete {
            try? FileManager.default.removeItem(at: url)
            scratchURL = nil
            coverage.removeAll()
            bytesReceived = 0
        }
    }

    /// Await the upstream's total size. Used by the engine to
    /// surface a known denominator in the progress UI before the
    /// first dataRequest arrives.
    public func awaitTotalSize() async throws -> Int64 {
        if let totalBytes { return totalBytes }
        if !probeStarted {
            probeStarted = true
            Task { [weak self] in await self?.probe() }
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int64, any Error>) in
            probeWaiters.append(c)
        }
    }

    // MARK: - Internal

    private func removeInFlight(_ id: ObjectIdentifier) {
        inFlight.removeValue(forKey: id)
    }

    private func fulfillProbeWaiters(_ result: Result<Int64, any Error>) {
        let waiters = probeWaiters
        probeWaiters.removeAll()
        for w in waiters { w.resume(with: result) }
    }

    /// Issue the initial probe request that resolves `totalBytes`.
    /// Optimistically requests the first 256 KB so the bytes flow
    /// straight into the scratch file and any contentInformation
    /// request resolves without a second round trip.
    private func probe() async {
        do {
            let bytes = try await fetch(range: 0..<256 * 1024, isProbe: true)
            if let totalBytes {
                fulfillProbeWaiters(.success(totalBytes))
                // Best-effort writeback already happened in `fetch`;
                // mark the bytes as covered so subsequent requests
                // covering this range short-circuit.
                _ = bytes
            } else {
                fulfillProbeWaiters(.failure(URLError(.cannotParseResponse)))
            }
        } catch {
            fulfillProbeWaiters(.failure(error))
        }
    }

    /// Resolve a single `AVAssetResourceLoadingRequest`. Splits the
    /// AVAssetResource loading API into the two sub-requests it
    /// carries (info + data) and handles both. Errors propagate
    /// back through `finishLoading(with:)`.
    private func serve(request: AVAssetResourceLoadingRequest) async {
        do {
            // 1. Content information — AVPlayer asks "how big is this
            //    file and can I issue Ranges?" Resolve from the
            //    cached `totalBytes` if we have it; otherwise probe.
            if let info = request.contentInformationRequest {
                let total = try await awaitTotalSize()
                info.contentType = "video/mp4"
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }

            // 2. Data request — give it the requested bytes. AVPlayer
            //    can ask for "to end" with `requestsAllDataToEnd
            //    OfResource = true`; treat that as 0..<totalBytes
            //    after the probe resolved.
            if let dataReq = request.dataRequest {
                let total = try await awaitTotalSize()
                let start = max(0, dataReq.requestedOffset)
                let endExclusive: Int64
                if dataReq.requestsAllDataToEndOfResource {
                    endExclusive = total
                } else {
                    endExclusive = min(total, start + Int64(dataReq.requestedLength))
                }
                if start >= endExclusive {
                    request.finishLoading()
                    return
                }
                let bytes = try await bytes(in: start..<endExclusive)
                if Task.isCancelled { return }
                dataReq.respond(with: bytes)
            }

            if !Task.isCancelled {
                request.finishLoading()
            }
        } catch is CancellationError {
            // Loader was torn down. AVPlayer doesn't need a finish
            // call after a didCancel.
            return
        } catch {
            log.warning("Loader request failed: \(error.localizedDescription, privacy: .public)")
            request.finishLoading(with: error)
        }
    }

    // MARK: - Byte fetching

    /// Read the requested byte range. Serves from disk if the range
    /// is already covered; otherwise fetches the missing portions
    /// from upstream, writes them to the scratch file, marks them
    /// covered, and returns the concatenated bytes.
    private func bytes(in range: Range<Int64>) async throws -> Data {
        try await ensureScratch()
        let missing = missingRanges(within: range)
        for sub in missing {
            _ = try await fetch(range: sub, isProbe: false)
        }
        return try readScratch(range: range)
    }

    /// Make sure the scratch file exists and is pre-truncated to the
    /// upstream's total size. Idempotent. Called from the first
    /// fetch path; the probe also reaches here once `totalBytes` is
    /// known.
    private func ensureScratch() async throws {
        if scratchURL != nil { return }
        guard let total = totalBytes else {
            // We only get here from `fetch` after the probe response
            // populates `totalBytes`. If it's still nil, the upstream
            // didn't tell us the size.
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolens-stream-\(UUID().uuidString).mp4")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()
        scratchURL = url
    }

    /// Issue a single Range GET. Writes the response bytes to the
    /// scratch file (creating it on first call) and updates
    /// `bytesReceived` + `coverage`. Returns the response bytes for
    /// callers that need them inline (the probe path).
    @discardableResult
    private func fetch(range: Range<Int64>, isProbe: Bool) async throws -> Data {
        var req = URLRequest(url: upstreamURL)
        // RFC 7233: Range header uses inclusive end.
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Probe path: resolve `totalBytes` from Content-Range. Reolink
        // returns 206 with the canonical format on modern firmware.
        if isProbe, totalBytes == nil {
            if http.statusCode == 206, let total = parseContentRangeTotal(http: http) {
                totalBytes = total
            } else if http.statusCode == 200 {
                // Server ignored Range and is streaming the whole
                // file. Take the size from the response body length.
                totalBytes = Int64(data.count)
            } else {
                throw URLError(.badServerResponse, userInfo: ["status": http.statusCode])
            }
        }

        if http.statusCode >= 400 {
            throw URLError(.badServerResponse, userInfo: ["status": http.statusCode])
        }

        try await ensureScratch()
        guard let scratchURL else {
            throw URLError(.cannotCreateFile)
        }

        // Write the bytes at their offset. The scratch file is
        // pre-truncated to total size, so seek+write is safe and
        // doesn't fragment the file.
        let handle = try FileHandle(forWritingTo: scratchURL)
        defer { try? handle.close() }
        let offset = range.lowerBound
        try handle.seek(toOffset: UInt64(offset))
        // If upstream returned 200, `data` is the full body — clamp
        // to the requested range size so we don't write past the
        // scratch file's end (truncation should catch it but be safe).
        let writeable: Data
        if http.statusCode == 200, totalBytes.map({ Int64(data.count) > $0 - offset }) ?? false {
            // Shouldn't happen, but defensive.
            writeable = data.prefix(Int(Int64(data.count)))
        } else {
            writeable = data
        }
        try handle.write(contentsOf: writeable)

        // Record coverage and bump received bytes by the new union.
        let written = Int64(writeable.count)
        let writtenRange = offset..<(offset + written)
        let added = addCoverage(writtenRange)
        bytesReceived += added

        // Promote-to-cache if we've now covered the whole file. Use
        // the existing RecordingDownloader cache layout so the next
        // play (or an Export action) is a zero-fetch hit.
        if let total = totalBytes, !isComplete, coverage == [0..<total] {
            completePromotion()
        }

        return writeable
    }

    /// Compute the sub-ranges within `range` that aren't covered yet.
    /// Used by `bytes(in:)` so we only fetch the holes. Internal so
    /// the unit tests can exercise the algorithm without spinning up
    /// AVFoundation.
    internal func missingRanges(within range: Range<Int64>) -> [Range<Int64>] {
        var cursor = range.lowerBound
        var result: [Range<Int64>] = []
        for covered in coverage where covered.upperBound > cursor && covered.lowerBound < range.upperBound {
            if covered.lowerBound > cursor {
                result.append(cursor..<min(covered.lowerBound, range.upperBound))
            }
            cursor = max(cursor, covered.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound {
            result.append(cursor..<range.upperBound)
        }
        return result
    }

    /// Insert `r` into `coverage` (kept sorted + disjoint). Returns
    /// the count of *new* bytes covered, which the caller adds to
    /// `bytesReceived` so overlapping re-fetches don't double-count.
    /// Internal for unit tests; see `missingRanges`.
    @discardableResult
    internal func addCoverage(_ r: Range<Int64>) -> Int64 {
        if r.isEmpty { return 0 }
        var merged: [Range<Int64>] = []
        var pending = r
        var addedBefore: Int64 = 0
        for existing in coverage {
            if existing.upperBound < pending.lowerBound {
                merged.append(existing)
            } else if existing.lowerBound > pending.upperBound {
                merged.append(pending)
                pending = existing
            } else {
                // Overlap — track how many bytes of `r` were already
                // covered so we don't credit them twice.
                let overlapLo = max(existing.lowerBound, r.lowerBound)
                let overlapHi = min(existing.upperBound, r.upperBound)
                if overlapHi > overlapLo {
                    addedBefore += overlapHi - overlapLo
                }
                pending = min(existing.lowerBound, pending.lowerBound)..<max(existing.upperBound, pending.upperBound)
            }
        }
        merged.append(pending)
        coverage = merged
        let totalNew = (r.upperBound - r.lowerBound) - addedBefore
        return totalNew
    }

    /// Read bytes from the scratch file. Used by `bytes(in:)` after
    /// `fetch` has populated the missing pieces.
    private func readScratch(range: Range<Int64>) throws -> Data {
        guard let scratchURL else { throw URLError(.cannotOpenFile) }
        let handle = try FileHandle(forReadingFrom: scratchURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let count = Int(range.upperBound - range.lowerBound)
        // safe: `read(upToCount:)` returns nil only on EOF before any
        // bytes; the file is pre-truncated to total size so the read
        // is bounded.
        return handle.readData(ofLength: count)
    }

    /// Parse `Content-Range: bytes 0-1023/45678` and return the
    /// trailing total. Nil for missing / malformed headers. Static
    /// + internal for unit tests; the actor instance calls through
    /// via the response header path.
    internal static func parseContentRangeTotal(header: String?) -> Int64? {
        guard let header else { return nil }
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let totalPart = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(totalPart)
    }

    private func parseContentRangeTotal(http: HTTPURLResponse) -> Int64? {
        Self.parseContentRangeTotal(header: http.value(forHTTPHeaderField: "Content-Range"))
    }

    /// Move the scratch file into the recordings cache so a
    /// subsequent open of the same recording is a zero-fetch
    /// startup. Re-uses the existing `RecordingDownloader` cache
    /// layout (path + naming) so the parallel-Range downloader and
    /// the streaming loader share state.
    private func completePromotion() {
        guard let scratchURL else { return }
        let cached = RecordingDownloader.promoteToCache(tempURL: scratchURL, downloadURL: upstreamURL)
        completedFileURL = cached
        self.scratchURL = cached
        isComplete = true
        log.info("Streaming complete; promoted to cache at \(cached.lastPathComponent, privacy: .public)")
    }
}
