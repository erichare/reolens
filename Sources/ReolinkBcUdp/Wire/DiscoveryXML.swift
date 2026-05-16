import Foundation

/// Encode / decode the `<P2P>` XML payloads carried inside
/// [`BcUdpDiscPacket.payload`](./BcUdpPacket.swift).
///
/// The Reolink P2P discovery flow is request-and-response over
/// UDP/9999: the client sends a `<C2M_Q>` (Client-to-Mediator
/// Query) keyed on the camera's UID; the server replies with a
/// `<M2C_Q_R>` (Mediator-to-Client Query Reply) carrying the
/// camera's currently-registered WAN endpoint and a relay
/// fallback.
///
/// ## Wire-format status
///
/// **Validated against the 2026-05-16 `p2p*.reolink.com`
/// capture.** Both request and response schemas below were
/// decrypted from real Reolink-macOS-app traffic with
/// [`DiscoveryXMLCrypto`](./DiscoveryXMLCrypto.swift). Tag names
/// and structural nesting match the wire byte-for-byte.
///
/// Wire payloads ARE encrypted — the codec here operates on
/// plaintext XML. The caller (typically `P2PDiscovery`) is
/// responsible for running `DiscoveryXMLCrypto.encrypt(...)`
/// before stamping bytes into `BcUdpDiscPacket.payload` and
/// `DiscoveryXMLCrypto.decrypt(...)` after pulling them out.
///
/// Pure value-type codec — no networking, no actors.
public enum DiscoveryXML {

    // MARK: - Tag names (single source of truth)

    /// Element-name constants — every tag we read or emit is
    /// listed here so the wire schema is one searchable
    /// definition. Validated against the May 2026 pcap.
    public enum Tag {
        public static let root = "P2P"
        public static let clientRequest = "C2M_Q"
        public static let serverReply = "M2C_Q_R"

        // Request children
        public static let uid = "uid"
        /// Protocol version. Observed value `3` from the
        /// Reolink macOS app's discovery query.
        public static let version = "ver"
        /// Protocol family. Observed value `6` (likely
        /// "Reolink P2P v6").
        public static let family = "family"
        /// Client platform identifier. The wire tag is `<p>`
        /// (likely "platform"). Observed values: `MAC` from
        /// the macOS app; presumably `IOS`/`AND`/`WIN` from
        /// other Reolink clients.
        public static let clientSource = "p"

        // Response children
        /// Camera's current WAN registration — the primary
        /// direct hole-punch target.
        public static let registration = "reg"
        /// Relay endpoint — TURN-style fallback when direct
        /// punch fails.
        public static let relay = "relay"
        /// Endpoint sub-elements (nested under `reg`/`relay`).
        public static let ip = "ip"
        public static let port = "port"
        /// Status code. `0` = candidates returned; non-zero
        /// (observed `-3`) = camera not registered at this
        /// server, try the next pool entry.
        public static let responseCode = "rsp"
    }

    // MARK: - Request

    /// A camera-lookup request the client sends to a discovery
    /// server. The `clientID` from Phase 1 isn't actually used
    /// at this protocol layer — request/reply correlation runs
    /// off the BcUdp `senderID` field, not anything XML-level.
    public struct LookupRequest: Sendable, Hashable {
        public var uid: String
        /// Protocol version. Default `3` matches the Reolink
        /// macOS app's wire bytes.
        public var version: Int
        /// Protocol family. Default `6` matches the wire.
        public var family: Int
        /// Client source / OS marker. The macOS app sends
        /// `"MAC"`; we send `"MAC"` from macOS and `"IOS"`
        /// from iOS so the server gets a recognisable signal.
        public var clientSource: String

        public init(
            uid: String,
            clientID: String = "",   // retained for API compatibility; ignored on the wire
            version: Int = 3,
            family: Int = 6,
            clientSource: String = "MAC"
        ) {
            _ = clientID
            self.uid = uid
            self.version = version
            self.family = family
            self.clientSource = clientSource
        }

        /// Encode to UTF-8 XML bytes ready to drop into a
        /// `BcUdpDiscPacket.payload` (after encryption via
        /// `DiscoveryXMLCrypto.encrypt`). Trailing newline-free
        /// for byte-for-byte parity with the captured Reolink
        /// app traffic — some firmware lines have been observed
        /// to reject extra whitespace between tags.
        public func encode() -> Data {
            let xml = "<\(Tag.root)>" +
                "<\(Tag.clientRequest)>" +
                "<\(Tag.uid)>\(uid)</\(Tag.uid)>" +
                "<\(Tag.version)>\(version)</\(Tag.version)>" +
                "<\(Tag.family)>\(family)</\(Tag.family)>" +
                "<\(Tag.clientSource)>\(clientSource)</\(Tag.clientSource)>" +
                "</\(Tag.clientRequest)>" +
                "</\(Tag.root)>"
            return Data(xml.utf8)
        }

        /// Best-effort decode — used by the in-process tests
        /// that synthesise a fake discovery server.
        public static func decode(from payload: Data) -> LookupRequest? {
            guard let text = String(data: payload, encoding: .utf8) else { return nil }
            guard let uid = TagScan.firstTagContent(in: text, tag: Tag.uid),
                  !uid.isEmpty else { return nil }
            let version = TagScan.firstTagContent(in: text, tag: Tag.version).flatMap(Int.init) ?? 3
            let family = TagScan.firstTagContent(in: text, tag: Tag.family).flatMap(Int.init) ?? 6
            let clientSource = TagScan.firstTagContent(in: text, tag: Tag.clientSource) ?? "MAC"
            return LookupRequest(
                uid: uid,
                version: version,
                family: family,
                clientSource: clientSource
            )
        }
    }

    // MARK: - Response

    /// Single host/port pair returned by the discovery server.
    /// Port is `UInt16` (wire width); host is a string because
    /// the server returns IPv4 dotted-quad or IPv6.
    public struct Endpoint: Sendable, Hashable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// Parsed result of a discovery lookup.
    ///
    /// The wire reply carries two endpoints of interest:
    ///
    /// - `registration`: the camera's currently-registered WAN
    ///   IP:port. This is the primary direct hole-punch target.
    /// - `relay`: a Reolink-operated relay that brokers traffic
    ///   when direct punch fails.
    ///
    /// Several diagnostic fields (the `<log>`, `<t>`, `<mtu>`,
    /// `<debug>`, `<ac>` elements observed on the wire) are
    /// intentionally NOT modelled here — the hole-punch state
    /// machine only consumes `registration` + `relay`, and
    /// surfacing the diagnostic fields would invite premature
    /// reliance on values that Reolink might silently repurpose.
    ///
    /// The `responseCode` field is the server's verdict: `0`
    /// means "candidates included", a non-zero value (`-3`
    /// observed = "not registered at this server") means the
    /// caller should try the next pool entry.
    public struct LookupResponse: Sendable, Hashable {
        public var registration: Endpoint?
        public var relay: Endpoint?
        public var responseCode: Int

        public init(
            registration: Endpoint? = nil,
            relay: Endpoint? = nil,
            responseCode: Int = 0
        ) {
            self.registration = registration
            self.relay = relay
            self.responseCode = responseCode
        }

        /// True when the response carries no usable candidate.
        /// The caller treats this as a soft "not found" and
        /// tries the next discovery server.
        public var isEmpty: Bool {
            registration == nil && relay == nil
        }

        public func encode() -> Data {
            var inner = ""
            if let registration {
                inner += "<\(Tag.registration)>" +
                    "<\(Tag.ip)>\(registration.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(registration.port)</\(Tag.port)>" +
                    "</\(Tag.registration)>"
            }
            if let relay {
                inner += "<\(Tag.relay)>" +
                    "<\(Tag.ip)>\(relay.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(relay.port)</\(Tag.port)>" +
                    "</\(Tag.relay)>"
            }
            inner += "<\(Tag.responseCode)>\(responseCode)</\(Tag.responseCode)>"
            let xml = "<\(Tag.root)>" +
                "<\(Tag.serverReply)>" +
                inner +
                "</\(Tag.serverReply)>" +
                "</\(Tag.root)>"
            return Data(xml.utf8)
        }

        public static func decode(from payload: Data) -> LookupResponse? {
            guard let text = String(data: payload, encoding: .utf8) else { return nil }
            // The reply must carry the `<M2C_Q_R>` wrapper to be a
            // valid discovery response. Anything else is treated as
            // malformed.
            guard text.contains("<\(Tag.serverReply)>") else { return nil }
            let registration = parseEndpoint(in: text, parentTag: Tag.registration)
            let relay = parseEndpoint(in: text, parentTag: Tag.relay)
            let responseCode = TagScan.firstTagContent(in: text, tag: Tag.responseCode).flatMap(Int.init) ?? 0
            return LookupResponse(
                registration: registration,
                relay: relay,
                responseCode: responseCode
            )
        }

        /// Extracts `<ip>` + `<port>` from inside a `<parentTag>`
        /// element. Returns nil if the parent isn't present or its
        /// children are malformed.
        private static func parseEndpoint(in xml: String, parentTag: String) -> Endpoint? {
            guard let inner = TagScan.firstTagContent(in: xml, tag: parentTag),
                  !inner.isEmpty else { return nil }
            guard let host = TagScan.firstTagContent(in: inner, tag: Tag.ip),
                  !host.isEmpty else { return nil }
            let port = TagScan.firstTagContent(in: inner, tag: Tag.port).flatMap(UInt16.init) ?? 0
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
