import Foundation
import Network
import OSLog
import Darwin

private let log = Logger(subsystem: "com.reolens.app", category: "discovery")

/// A Reolink-shaped device found during a LAN scan. We try Bonjour/mDNS
/// first (most Reolink devices advertise as `Reolink-<model>-<serial>._http._tcp`
/// — giving us a real product name for free), and fall back to an HTTP
/// /24 sweep that's at least sure to find any HTTP-reachable Reolink even
/// when Bonjour is unavailable.
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let host: String
    public let port: Int
    /// Human-friendly device label — the Bonjour service name when
    /// available (e.g. `"Reolink Home Hub Pro"`, `"Reolink Argus 4 Pro"`),
    /// otherwise the model code parsed from any unauth HTTP response.
    public let displayName: String
    /// Best-effort device-type bucket: `"Hub"`, `"NVR"`, `"Camera"` for
    /// picking the right sidebar icon.
    public let kindHint: String
    /// True when at least one signal (Bonjour service-name match OR HTTP
    /// CGI-shaped JSON envelope) confirms this is a Reolink device.
    public let confirmedReolink: Bool
}

/// Scans the local /24 subnet for Reolink HTTP endpoints by sending a
/// `GET /cgi-bin/api.cgi?cmd=GetDevInfo` request to each candidate IP in
/// parallel. The scanner short-circuits on the first byte of any non-empty
/// response and aggressively times out (1.5 s) so a full sweep finishes in
/// well under 10 seconds on a typical home network.
public actor CameraDiscovery {
    public static let shared = CameraDiscovery()

    private let session: URLSession

    /// Cap on concurrent /24 probes. iOS / iPadOS get cranky with
    /// 254 simultaneous TCP setups (the OS rate-limits the network
    /// stack and Bonjour ends up starved on the same dispatch
    /// queue). 32 is a compromise: scans finish in ~3 s on a typical
    /// home network and Bonjour stays responsive. macOS could carry
    /// more but staying uniform across platforms keeps behavior
    /// predictable. AGENTS.md §1.
    public static let concurrentProbeLimit: Int = 32

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // 0.5.0 Theme E — tighter probe timeouts. Reolink CGI on a
        // reachable LAN responds in < 200 ms; 1 s is generous and
        // gets a full sweep done well inside 3 s wall-clock.
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.5
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Disable cookies — pointless on a discovery scan.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config)
    }

    /// Discover Reolink-looking devices on the Mac's primary IPv4 /24.
    /// Runs Bonjour/mDNS browse and an HTTP /24 sweep concurrently and
    /// merges the results — Bonjour gives us the user-friendly device name
    /// (whatever the owner set during setup — typically "Home Hub Pro",
    /// "Driveway", etc.) while the HTTP sweep catches devices that
    /// don't advertise. Returns the deduped list in increasing-IP order.
    ///
    /// 0.5.0: checks the Local Network permission state up front on
    /// iOS / iPadOS. If the user has explicitly denied, returns
    /// `ScanResult.permissionDenied` so the UI can surface a
    /// "Settings → Privacy → Local Network" hint instead of an
    /// empty list. Pending prompts proceed optimistically — the
    /// first probe triggers the system dialog.
    public enum ScanOutcome: Sendable {
        case success([DiscoveredDevice])
        case permissionDenied
    }

    public func scanWithPermissionGate(progress: (@Sendable (Double) -> Void)? = nil) async -> ScanOutcome {
        // 0.5.0 fix — generous timeout. The original 0.5 s was shorter
        // than the iOS Local Network permission prompt's appearance
        // delay, so the gate returned `.pending` before the user had a
        // chance to see (let alone tap) the system dialog. With the
        // continuation-leak in `ProbeBox` fixed, a longer wait now
        // actually resolves to `.granted` or `.denied` once the user
        // answers. macOS short-circuits inside `check(...)` and is
        // unaffected.
        let permission = await LocalNetworkPermission.check(timeoutSeconds: 8.0)
        if permission == .denied {
            return .permissionDenied
        }
        let results = await scan(progress: progress)
        return .success(results)
    }

    public func scan(progress: (@Sendable (Double) -> Void)? = nil) async -> [DiscoveredDevice] {
        guard let subnet = Self.primarySubnetPrefix() else {
            log.warning("Couldn't determine a usable /24 subnet — discovery skipped")
            return []
        }
        // Subnet prefix identifies the user's LAN. Keep at .private
        // so sysdiagnose / Console.app exports don't expose it
        // (AGENTS.md §11).
        log.info("Discovery scanning subnet \(subnet, privacy: .private).0/24")

        // 0.5.0 fix — run Bonjour FIRST, then the HTTP sweep. The
        // original code raced them concurrently, which broke iOS
        // discovery on the first launch: the URLSession TCP probes
        // would fire 32-at-a-time into local-IP space *before* the
        // user had answered the Local Network prompt. Every probe
        // failed in ~1.5 s and the scan returned an empty list even
        // when the user later tapped "Allow". Running Bonjour to
        // completion first guarantees the prompt has been resolved
        // (or denied) by the time we start hitting IPs, and adds
        // only ~3 s wall-clock to the scan.
        let nameByHost = await Self.bonjourIndex(duration: 3.0)
        var httpResults = await httpSweepScan(subnet: subnet, progress: progress)

        // Enrich each HTTP-probed Reolink with the matching Bonjour name.
        for i in httpResults.indices {
            if let advertisedName = nameByHost[httpResults[i].host] {
                let pretty = BonjourCollector.prettyName(from: advertisedName)
                httpResults[i] = DiscoveredDevice(
                    host: httpResults[i].host,
                    port: httpResults[i].port,
                    displayName: pretty,
                    kindHint: BonjourCollector.kindHint(from: advertisedName),
                    confirmedReolink: httpResults[i].confirmedReolink
                )
                log.info("Bonjour name for \(httpResults[i].host, privacy: .public): '\(advertisedName, privacy: .public)' → '\(pretty, privacy: .public)'")
            }
        }

        return httpResults.sorted { a, b in
            (Self.ipNumeric(a.host) ?? 0) < (Self.ipNumeric(b.host) ?? 0)
        }
    }

    private func httpSweepScan(subnet: String, progress: (@Sendable (Double) -> Void)?) async -> [DiscoveredDevice] {
        let candidates = (1...254).map { "\(subnet).\($0)" }
        let total = candidates.count
        var completed = 0
        var results: [DiscoveredDevice] = []

        // 0.5.0 Theme E — throttled task group. Adding all 254 probes
        // up-front would saturate iOS's network stack and starve
        // Bonjour. Instead we keep `concurrentProbeLimit` in flight
        // at any moment and feed new ones as old ones drain.
        let limit = Self.concurrentProbeLimit
        await withTaskGroup(of: (Int, DiscoveredDevice?).self) { group in
            var nextIndex = 0
            // Prime the pipeline with up to `limit` probes.
            while nextIndex < min(limit, candidates.count) {
                let ip = candidates[nextIndex]
                let captured = nextIndex
                group.addTask { [session] in
                    (captured, await Self.probe(ip: ip, port: 80, session: session))
                }
                nextIndex += 1
            }
            // For each completion, queue the next probe (if any).
            while let (_, found) = await group.next() {
                completed += 1
                progress?(Double(completed) / Double(total))
                if let found {
                    log.info("HTTP probe found \(found.host, privacy: .public) (\(found.kindHint, privacy: .public))")
                    results.append(found)
                }
                if Task.isCancelled { break }
                if nextIndex < candidates.count {
                    let ip = candidates[nextIndex]
                    let captured = nextIndex
                    group.addTask { [session] in
                        (captured, await Self.probe(ip: ip, port: 80, session: session))
                    }
                    nextIndex += 1
                }
            }
        }
        return results
    }

    /// Probe one IP. Two-phase: (1) hit the Reolink CGI endpoint and check
    /// for a Reolink-shaped JSON envelope; (2) on inconclusive response,
    /// fall back to a root GET and check headers/body. Anything that doesn't
    /// look like a Reolink device gets dropped.
    private static func probe(ip: String, port: Int, session: URLSession) async -> DiscoveredDevice? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = port == 80 ? nil : port
        components.path = "/cgi-bin/api.cgi"
        components.queryItems = [URLQueryItem(name: "cmd", value: "GetDevInfo")]
        guard let url = components.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            let body = String(data: data, encoding: .utf8) ?? ""
            // Look for Reolink's CGI envelope shape. Even an auth-failed reply
            // includes `"cmd":"GetDevInfo"` and `"rspCode"` — that's enough.
            let isReolinkJSON = body.contains("\"cmd\"") && body.contains("rspCode")
            if isReolinkJSON || http.statusCode == 200 {
                let kind = Self.parseKindHint(body: body, headers: http.allHeaderFields)
                // Without auth, the HTTP probe can't get a marketing name.
                // Use the host until Bonjour merges in something prettier.
                return DiscoveredDevice(
                    host: ip,
                    port: port,
                    displayName: ip,
                    kindHint: kind,
                    confirmedReolink: isReolinkJSON
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Best-effort device-type label. Reolink's unauth JSON sometimes leaks
    /// the `type` field; otherwise we fall back to a generic bucket.
    private static func parseKindHint(body: String, headers: [AnyHashable: Any]) -> String {
        if let range = body.range(of: "\"type\":\"") {
            let after = body[range.upperBound...]
            if let endQuote = after.firstIndex(of: "\"") {
                return String(after[..<endQuote])
            }
        }
        return "Reolink"
    }

    // MARK: - Bonjour / mDNS

    /// Browse the local network for all `_http._tcp` and `_rtsp._tcp` Bonjour
    /// advertisers, resolve each to an IPv4 address, and return a map of
    /// `host → service name`. The HTTP-probe path looks names up in this
    /// map after confirming a Reolink CGI envelope at the IP — so we never
    /// have to guess whether a service-name string contains a Reolink-y
    /// keyword (the user might have renamed the device to anything).
    private static func bonjourIndex(duration: TimeInterval) async -> [String: String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: String], Never>) in
            let collector = BonjourCollector(continuation: cont)
            collector.startBrowses(serviceTypes: ["_http._tcp", "_rtsp._tcp"], duration: duration)
        }
    }
}

/// Internal helper: browses one or more Bonjour service types for a fixed
/// duration, resolves each result to an IPv4 host, and returns a
/// `host → advertised-service-name` map. Lives outside the actor because
/// `NWBrowser` callbacks fire on an arbitrary dispatch queue.
package final class BonjourCollector: @unchecked Sendable {
    private let continuation: CheckedContinuation<[String: String], Never>
    private var browsers: [NWBrowser] = []
    private var didFinish = false
    private let lock = NSLock()
    private var nameByHost: [String: String] = [:]
    private var resolving: [NWConnection] = []

    package init(continuation: CheckedContinuation<[String: String], Never>) {
        self.continuation = continuation
    }

    /// Start a browser per service type. We capture `self` STRONGLY in all
    /// closures — `bonjourIndex` returns immediately after calling this,
    /// so without a strong reference the collector would be deallocated
    /// and the timer would never fire `finish()`, hanging the scan.
    package func startBrowses(serviceTypes: [String], duration: TimeInterval) {
        for type in serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: type, domain: nil),
                using: params
            )
            browser.browseResultsChangedHandler = { results, _ in
                for r in results { self.consider(result: r, fromServiceType: type) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            browsers.append(browser)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + duration) {
            self.finish()
        }
    }

    /// Resolve every advertised service — no name filter. The caller will
    /// decide which IPs are interesting (from the HTTP-probe side) and
    /// look up names here for the matched ones. This dodges the problem
    /// of guessing whether a user-set device name contains a Reolink
    /// keyword (e.g. "Home Hub Pro", "Driveway").
    private func consider(result: NWBrowser.Result, fromServiceType: String) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        lock.lock()
        resolving.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                if let host = Self.ipv4(from: connection.currentPath?.remoteEndpoint) {
                    self.record(host: host, name: name, type: fromServiceType)
                }
                connection.cancel()
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private static func ipv4(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        if case let .hostPort(host: host, port: _) = endpoint {
            switch host {
            case .ipv4(let addr):
                let octets = withUnsafeBytes(of: addr.rawValue) { Array($0) }
                guard octets.count == 4 else { return nil }
                return "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
            default:
                return nil
            }
        }
        return nil
    }

    /// Strip a trailing `-<hex/numeric serial>` so e.g.
    /// `"Home Hub Pro-EFA51F"` → `"Home Hub Pro"`. Conservative: only
    /// strips the suffix when it actually looks like a serial / MAC tail.
    package static func prettyName(from raw: String) -> String {
        var name = raw
        if let dash = name.lastIndex(of: "-") {
            let after = name[name.index(after: dash)...]
            let isSerial = after.allSatisfy { $0.isHexDigit || $0 == ":" }
            if isSerial, after.count >= 4 {
                name = String(name[..<dash])
            }
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func kindHint(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("hub") { return "Hub" }
        if lower.contains("nvr") || lower.contains("rln") { return "NVR" }
        return "Camera"
    }

    private func record(host: String, name: String, type: String) {
        lock.lock()
        // First name wins. `_http._tcp` is generally the most descriptive
        // (it's the camera's web-UI advertisement). `_rtsp._tcp` names are
        // sometimes generic like "Reolink_NNN" — we keep them as a
        // backup only when nothing else is known.
        if nameByHost[host] == nil {
            nameByHost[host] = name
        }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        let snapshot = nameByHost
        let connections = resolving
        resolving.removeAll()
        nameByHost.removeAll()
        lock.unlock()

        for b in browsers { b.cancel() }
        for c in connections { c.cancel() }
        continuation.resume(returning: snapshot)
    }
}

// MARK: - Local IP helpers (CameraDiscovery static)
package extension CameraDiscovery {

    /// Find the /24 prefix of the Mac's primary IPv4 interface (en0/en1/en2
    /// — any non-loopback, up-and-running interface with a valid v4 addr).
    /// Returns e.g. `"192.168.1"` for a Mac at `192.168.1.42`.
    package static func primarySubnetPrefix() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var candidate: String?
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &hostBuf, socklen_t(hostBuf.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostBuf)
            // Skip self-assigned (169.254.x.x) and weird ranges
            if ip.hasPrefix("169.254.") { continue }
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            // Prefer typical home-network ranges; otherwise return whatever
            // valid v4 address we got.
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") {
                return "\(parts[0]).\(parts[1]).\(parts[2])"
            }
            candidate = "\(parts[0]).\(parts[1]).\(parts[2])"
        }
        return candidate
    }

    private static func ipNumeric(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
