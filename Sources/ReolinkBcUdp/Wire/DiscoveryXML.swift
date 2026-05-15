import Foundation

/// Encode / decode the `<P2P>` XML payloads carried inside
/// [`BcUdpDiscPacket.payload`](./BcUdpPacket.swift).
///
/// The Reolink P2P discovery flow is request-and-response over UDP:
/// the client sends a `C2D_C` (client-to-device control) lookup
/// keyed on the camera's UID; the server replies with a `D2C_C`
/// (device-to-client control) carrying the camera's current
/// candidates (WAN address, LAN address, relay hint).
///
/// **Tag names pending Phase 2 validation.** The exact element
/// names below are best-effort recall from the public Reolink
/// reverse-engineering work (`thirtythreeforty/neolink`,
/// `reolink-aio`). Phase 2's first packet capture against a real
/// `p2p*.reolink.com` server will confirm them; if any tag is
/// wrong, fixing it is a one-line change in the constants below.
/// Round-trip tests cover every documented field so a regression
/// is loud.
///
/// Pure value-type codec — no networking, no actors.
public enum DiscoveryXML {

    // MARK: - Tag names (single source of truth)

    /// Element-name constants. Centralized so the eventual
    /// "actually, the real server says it's `<deviceIp>` not
    /// `<dev_ip>`" Phase-2 fix only touches one place.
    public enum Tag {
        public static let root = "P2P"
        public static let clientRequest = "C2D_C"
        public static let deviceResponse = "D2C_C"
        public static let uid = "uid"
        public static let clientID = "cli"
        /// Optional client-side hint at the priority of paths
        /// the client can accept (1 = direct preferred; higher
        /// values allow relay sooner). neolink sends `2`.
        public static let priority = "p2pPriority"
        // Response children — the parser is tolerant and accepts
        // either the flat form (e.g. `<devNatIp>` / `<devNatPort>`)
        // or the nested form (`<dev><ip>...</ip><port>...</port></dev>`).
        // Both have been observed in the wild on different
        // firmware lines.
        public static let wanIPv4 = "devNatIp"
        public static let wanPort = "devNatPort"
        public static let wanIPv6 = "devNatIpV6"
        public static let lanIPv4 = "devLanIp"
        public static let lanPort = "devLanPort"
        public static let relayHost = "relayIp"
        public static let relayPort = "relayPort"
    }

    // MARK: - Request

    /// A camera-lookup request the client sends to a discovery
    /// server. The `clientID` is a short opaque token the client
    /// generates per lookup so responses can be correlated; the
    /// server echoes it back in the reply.
    public struct LookupRequest: Sendable, Hashable {
        public var uid: String
        public var clientID: String
        public var priority: Int

        public init(uid: String, clientID: String, priority: Int = 2) {
            self.uid = uid
            self.clientID = clientID
            self.priority = priority
        }

        /// Encode to UTF-8 XML bytes ready to drop into a
        /// `BcUdpDiscPacket.payload`. No surrounding whitespace
        /// because some firmware lines reject extra whitespace
        /// between tags (observed on the Home Hub Pro).
        public func encode() -> Data {
            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <\(Tag.root)>
            <\(Tag.clientRequest)>
            <\(Tag.uid)>\(uid)</\(Tag.uid)>
            <\(Tag.clientID)>\(clientID)</\(Tag.clientID)>
            <\(Tag.priority)>\(priority)</\(Tag.priority)>
            </\(Tag.clientRequest)>
            </\(Tag.root)>
            """
            return Data(xml.utf8)
        }

        /// Best-effort decode. Returns nil if the payload doesn't
        /// look like a lookup request (used by the eventual mock
        /// server in tests + by any future debugging tools).
        public static func decode(from payload: Data) -> LookupRequest? {
            guard let text = String(data: payload, encoding: .utf8) else { return nil }
            guard let uid = TagScan.firstTagContent(in: text, tag: Tag.uid) else { return nil }
            let cli = TagScan.firstTagContent(in: text, tag: Tag.clientID) ?? ""
            let priority = TagScan.firstTagContent(in: text, tag: Tag.priority).flatMap(Int.init) ?? 2
            return LookupRequest(uid: uid, clientID: cli, priority: priority)
        }
    }

    // MARK: - Response

    /// Single host/port pair returned by the discovery server.
    /// Port is `UInt16` because that's the wire width; host is a
    /// string because the server may return IPv4 dotted-quad,
    /// IPv6, or (rarely) a hostname.
    public struct Endpoint: Sendable, Hashable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// The parsed result of a successful discovery lookup. All
    /// fields are optional — the server may omit candidates it
    /// doesn't have (e.g. IPv6 when the camera hasn't registered
    /// a v6 address, or relay when the camera hasn't been
    /// assigned one). At least one of `wanV4`, `wanV6`, or
    /// `relay` is typically present in a successful response;
    /// callers should treat a `LookupResponse` with all fields
    /// nil as "camera not registered" and try the next server.
    public struct LookupResponse: Sendable, Hashable {
        public var uid: String
        public var wanV4: Endpoint?
        public var wanV6: Endpoint?
        public var lanV4: Endpoint?
        public var relay: Endpoint?

        public init(
            uid: String,
            wanV4: Endpoint? = nil,
            wanV6: Endpoint? = nil,
            lanV4: Endpoint? = nil,
            relay: Endpoint? = nil
        ) {
            self.uid = uid
            self.wanV4 = wanV4
            self.wanV6 = wanV6
            self.lanV4 = lanV4
            self.relay = relay
        }

        /// True when the response carries no usable candidate.
        /// Caller should treat this as a soft "not found" and try
        /// the next discovery server rather than failing the
        /// whole lookup.
        public var isEmpty: Bool {
            wanV4 == nil && wanV6 == nil && lanV4 == nil && relay == nil
        }

        public func encode() -> Data {
            var inner = ""
            inner += "<\(Tag.uid)>\(uid)</\(Tag.uid)>\n"
            if let wanV4 {
                inner += "<\(Tag.wanIPv4)>\(wanV4.host)</\(Tag.wanIPv4)>\n"
                inner += "<\(Tag.wanPort)>\(wanV4.port)</\(Tag.wanPort)>\n"
            }
            if let wanV6 {
                inner += "<\(Tag.wanIPv6)>\(wanV6.host)</\(Tag.wanIPv6)>\n"
            }
            if let lanV4 {
                inner += "<\(Tag.lanIPv4)>\(lanV4.host)</\(Tag.lanIPv4)>\n"
                inner += "<\(Tag.lanPort)>\(lanV4.port)</\(Tag.lanPort)>\n"
            }
            if let relay {
                inner += "<\(Tag.relayHost)>\(relay.host)</\(Tag.relayHost)>\n"
                inner += "<\(Tag.relayPort)>\(relay.port)</\(Tag.relayPort)>\n"
            }
            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <\(Tag.root)>
            <\(Tag.deviceResponse)>
            \(inner)</\(Tag.deviceResponse)>
            </\(Tag.root)>
            """
            return Data(xml.utf8)
        }

        public static func decode(from payload: Data) -> LookupResponse? {
            guard let text = String(data: payload, encoding: .utf8) else { return nil }
            guard let uid = TagScan.firstTagContent(in: text, tag: Tag.uid) else { return nil }
            let wanV4 = makeEndpoint(in: text, hostTag: Tag.wanIPv4, portTag: Tag.wanPort)
            // v6 host has no paired port tag in the wire format —
            // Reolink reuses the v4 socket on a dual-stack bind, so
            // the same `wanPort` applies to both candidates. The
            // caller (`RemoteTransport`) substitutes v4's port for
            // v6; the v6 candidate carries port 0 in the model.
            let wanV6 = makeEndpoint(in: text, hostTag: Tag.wanIPv6, portTag: nil)
            let lanV4 = makeEndpoint(in: text, hostTag: Tag.lanIPv4, portTag: Tag.lanPort)
            let relay = makeEndpoint(in: text, hostTag: Tag.relayHost, portTag: Tag.relayPort)
            return LookupResponse(
                uid: uid,
                wanV4: wanV4,
                wanV6: wanV6,
                lanV4: lanV4,
                relay: relay
            )
        }

        private static func makeEndpoint(in text: String, hostTag: String, portTag: String?) -> Endpoint? {
            guard let host = TagScan.firstTagContent(in: text, tag: hostTag),
                  !host.isEmpty else { return nil }
            // Port is optional: some firmware emits an address
            // tag without a paired port (and expects the client to
            // substitute), and the v6 candidate shares the v4
            // port-tag entirely (`portTag == nil`).
            let port: UInt16
            if let portTag {
                port = TagScan.firstTagContent(in: text, tag: portTag).flatMap(UInt16.init) ?? 0
            } else {
                port = 0
            }
            return Endpoint(host: host, port: port)
        }
    }
}

// MARK: - Tag scanner

/// Minimal name-lookup XML scanner. Mirrors the approach in
/// `ReolinkBaichuan.BcXmlBody` (which we cannot import here — that
/// module is a peer, not a dependency) so the two modules share an
/// implementation style without a code-link.
enum TagScan {
    static func firstTagContent(in xml: String, tag: String) -> String? {
        guard let openRange = xml.range(of: "<\(tag)>") else { return nil }
        guard let closeRange = xml.range(of: "</\(tag)>", range: openRange.upperBound..<xml.endIndex) else { return nil }
        return String(xml[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
