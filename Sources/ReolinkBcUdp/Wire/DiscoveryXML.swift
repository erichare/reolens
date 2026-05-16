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
        /// Rendezvous server endpoint — receives the next step
        /// of the handshake (`C2R_C`). NOT the camera's direct
        /// address; the camera's NAT'd public address comes
        /// back later in the rendezvous reply's `<dmap>`.
        public static let rendezvous = "reg"
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

        // MARK: Rendezvous (C2R_C → R2C_C_R / R2C_T)

        /// Wrapper for the client-to-rendezvous-server step
        /// (step 2 of the handshake). Carries the UID plus
        /// the client's external IP/port hint and the
        /// connection ID we want to use.
        public static let rendezvousRequest = "C2R_C"
        /// Compact rendezvous reply — minimal address payload.
        public static let rendezvousReplyT = "R2C_T"
        /// Full rendezvous reply — includes relay paths and
        /// NAT classification.
        public static let rendezvousReplyC = "R2C_C_R"

        /// Camera's NAT'd public endpoint — the address we
        /// actually hole-punch to. Lives inside the rendezvous
        /// reply.
        public static let deviceMappedAddress = "dmap"
        /// Camera's LAN endpoint — useful if we happen to be
        /// on the same network.
        public static let deviceLanAddress = "dev"
        /// Server-assigned session identifier; round-tripped
        /// into the punch probe.
        public static let sessionID = "sid"
        /// Client-minted connection identifier. We pick this
        /// in `C2R_C` and the server echoes it.
        public static let connectionID = "cid"
        /// Client's perceived external IP (rendezvous request).
        public static let clientHint = "cli"
        /// Free-form debug counter sent by the Reolink app —
        /// echoed by us with a stable value so we look like a
        /// well-behaved client.
        public static let debug = "debug"
        /// Retry / round counter the Reolink macOS app sends
        /// (always `3` in captures).
        public static let retryCount = "r"

        // MARK: Punch probe (C2D_T)

        /// Wrapper for the final client-to-device hole-punch
        /// probe (step 3 of the handshake). Carries the
        /// session + connection IDs from rendezvous.
        public static let punchProbe = "C2D_T"
        /// Connection type the client requests. Observed
        /// value `local` in captures.
        public static let connectionType = "conn"
        /// MTU hint the client offers. Observed value `1350`.
        public static let mtu = "mtu"
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
            // Newline-separated tags — captured Reolink-macOS-app
            // packets put a `\n` between every element. 2026-05-16
            // smoke test surfaced that the server silently drops
            // newline-free packets (sends went out fine; zero
            // replies came back). Matches the wire byte-for-byte.
            let xml = "<\(Tag.root)>\n" +
                "<\(Tag.clientRequest)>\n" +
                "<\(Tag.uid)>\(uid)</\(Tag.uid)>\n" +
                "<\(Tag.version)>\(version)</\(Tag.version)>\n" +
                "<\(Tag.family)>\(family)</\(Tag.family)>\n" +
                "<\(Tag.clientSource)>\(clientSource)</\(Tag.clientSource)>\n" +
                "</\(Tag.clientRequest)>\n" +
                "</\(Tag.root)>\n"
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
    /// - `rendezvous`: the address of the next step in the
    ///   handshake — a Reolink-operated server that brokers
    ///   the actual hole-punch. **Not** the camera's direct
    ///   address; the camera's NAT'd public address comes
    ///   back from the rendezvous server in its own reply
    ///   (`R2C_C_R.dmap`).
    /// - `relay`: a Reolink-operated TURN-style relay used
    ///   when direct hole-punch fails.
    ///
    /// Several diagnostic fields (the `<log>`, `<t>`,
    /// `<mtu>`, `<debug>`, `<ac>` elements observed on the
    /// wire) are intentionally NOT modelled here — the
    /// state machine only consumes `rendezvous` + `relay`.
    ///
    /// The `responseCode` field is the server's verdict: `0`
    /// means "candidates included", a non-zero value (`-3`
    /// observed = "not registered at this server") means the
    /// caller should try the next pool entry.
    public struct LookupResponse: Sendable, Hashable {
        public var rendezvous: Endpoint?
        public var relay: Endpoint?
        public var responseCode: Int

        public init(
            rendezvous: Endpoint? = nil,
            relay: Endpoint? = nil,
            responseCode: Int = 0
        ) {
            self.rendezvous = rendezvous
            self.relay = relay
            self.responseCode = responseCode
        }

        /// True when the response carries no usable candidate.
        /// The caller treats this as a soft "not found" and
        /// tries the next discovery server.
        public var isEmpty: Bool {
            rendezvous == nil && relay == nil
        }

        public func encode() -> Data {
            var inner = ""
            if let rendezvous {
                inner += "<\(Tag.rendezvous)>" +
                    "<\(Tag.ip)>\(rendezvous.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(rendezvous.port)</\(Tag.port)>" +
                    "</\(Tag.rendezvous)>"
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
            let rendezvous = parseEndpoint(in: text, parentTag: Tag.rendezvous)
            let relay = parseEndpoint(in: text, parentTag: Tag.relay)
            let responseCode = TagScan.firstTagContent(in: text, tag: Tag.responseCode).flatMap(Int.init) ?? 0
            return LookupResponse(
                rendezvous: rendezvous,
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

    // MARK: - Rendezvous (step 2)

    /// Client-to-rendezvous-server request (`<C2R_C>`). Sent
    /// to the endpoint returned in `LookupResponse.rendezvous`.
    public struct RendezvousRequest: Sendable, Hashable {
        public var uid: String
        public var clientHint: Endpoint
        public var relayHint: Endpoint
        public var connectionID: UInt32
        public var debug: Int
        public var family: Int
        public var clientSource: String
        public var retryCount: Int

        public init(
            uid: String,
            clientHint: Endpoint,
            relayHint: Endpoint,
            connectionID: UInt32,
            debug: Int = 251_658_240,
            family: Int = 6,
            clientSource: String = "MAC",
            retryCount: Int = 3
        ) {
            self.uid = uid
            self.clientHint = clientHint
            self.relayHint = relayHint
            self.connectionID = connectionID
            self.debug = debug
            self.family = family
            self.clientSource = clientSource
            self.retryCount = retryCount
        }

        public func encode() -> Data {
            let xml = "<\(Tag.root)>" +
                "<\(Tag.rendezvousRequest)>" +
                "<\(Tag.uid)>\(uid)</\(Tag.uid)>" +
                "<\(Tag.clientHint)>" +
                    "<\(Tag.ip)>\(clientHint.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(clientHint.port)</\(Tag.port)>" +
                    "</\(Tag.clientHint)>" +
                "<\(Tag.relay)>" +
                    "<\(Tag.ip)>\(relayHint.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(relayHint.port)</\(Tag.port)>" +
                    "</\(Tag.relay)>" +
                "<\(Tag.connectionID)>\(connectionID)</\(Tag.connectionID)>" +
                "<\(Tag.debug)>\(debug)</\(Tag.debug)>" +
                "<\(Tag.family)>\(family)</\(Tag.family)>" +
                "<\(Tag.clientSource)>\(clientSource)</\(Tag.clientSource)>" +
                "<\(Tag.retryCount)>\(retryCount)</\(Tag.retryCount)>" +
                "</\(Tag.rendezvousRequest)>" +
                "</\(Tag.root)>"
            return Data(xml.utf8)
        }
    }

    /// Rendezvous server reply (`<R2C_C_R>` or `<R2C_T>`).
    /// Both wrappers carry the same core payload — the
    /// camera's `<dev>` (LAN) and `<dmap>` (NAT'd public)
    /// endpoints plus the server-assigned session ID. The
    /// full `R2C_C_R` variant adds relay paths and a NAT
    /// classification field.
    public struct RendezvousReply: Sendable, Hashable {
        /// Camera's LAN IP — useful if we happen to be on
        /// the same network.
        public var deviceLanEndpoint: Endpoint?
        /// Camera's NAT'd public endpoint. **This is the
        /// hole-punch target.**
        public var deviceMappedEndpoint: Endpoint?
        /// Server-side relay endpoint (only in `R2C_C_R`).
        public var relay: Endpoint?
        /// Server-assigned session ID. Round-tripped into
        /// the final punch probe.
        public var sessionID: UInt32
        /// Status code (`0` on success).
        public var responseCode: Int

        public init(
            deviceLanEndpoint: Endpoint? = nil,
            deviceMappedEndpoint: Endpoint? = nil,
            relay: Endpoint? = nil,
            sessionID: UInt32 = 0,
            responseCode: Int = 0
        ) {
            self.deviceLanEndpoint = deviceLanEndpoint
            self.deviceMappedEndpoint = deviceMappedEndpoint
            self.relay = relay
            self.sessionID = sessionID
            self.responseCode = responseCode
        }

        public func encode() -> Data {
            // Encode as the richer R2C_C_R variant. Decoder
            // accepts either wrapper.
            var inner = ""
            if let dmap = deviceMappedEndpoint {
                inner += "<\(Tag.deviceMappedAddress)>" +
                    "<\(Tag.ip)>\(dmap.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(dmap.port)</\(Tag.port)>" +
                    "</\(Tag.deviceMappedAddress)>"
            }
            if let dev = deviceLanEndpoint {
                inner += "<\(Tag.deviceLanAddress)>" +
                    "<\(Tag.ip)>\(dev.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(dev.port)</\(Tag.port)>" +
                    "</\(Tag.deviceLanAddress)>"
            }
            if let relay {
                inner += "<\(Tag.relay)>" +
                    "<\(Tag.ip)>\(relay.host)</\(Tag.ip)>" +
                    "<\(Tag.port)>\(relay.port)</\(Tag.port)>" +
                    "</\(Tag.relay)>"
            }
            inner += "<\(Tag.sessionID)>\(sessionID)</\(Tag.sessionID)>"
            inner += "<\(Tag.responseCode)>\(responseCode)</\(Tag.responseCode)>"
            let xml = "<\(Tag.root)>" +
                "<\(Tag.rendezvousReplyC)>" +
                inner +
                "</\(Tag.rendezvousReplyC)>" +
                "</\(Tag.root)>"
            return Data(xml.utf8)
        }

        public static func decode(from payload: Data) -> RendezvousReply? {
            guard let text = String(data: payload, encoding: .utf8) else { return nil }
            // Accept either wrapper variant — both carry the
            // same payload elements.
            guard text.contains("<\(Tag.rendezvousReplyT)>")
                || text.contains("<\(Tag.rendezvousReplyC)>") else {
                return nil
            }
            let dev = parseEndpoint(in: text, parentTag: Tag.deviceLanAddress)
            let dmap = parseEndpoint(in: text, parentTag: Tag.deviceMappedAddress)
            let relay = parseEndpoint(in: text, parentTag: Tag.relay)
            let sid = TagScan.firstTagContent(in: text, tag: Tag.sessionID).flatMap(UInt32.init) ?? 0
            let rsp = TagScan.firstTagContent(in: text, tag: Tag.responseCode).flatMap(Int.init) ?? 0
            return RendezvousReply(
                deviceLanEndpoint: dev,
                deviceMappedEndpoint: dmap,
                relay: relay,
                sessionID: sid,
                responseCode: rsp
            )
        }

        private static func parseEndpoint(in xml: String, parentTag: String) -> Endpoint? {
            guard let inner = TagScan.firstTagContent(in: xml, tag: parentTag),
                  !inner.isEmpty else { return nil }
            guard let host = TagScan.firstTagContent(in: inner, tag: Tag.ip),
                  !host.isEmpty else { return nil }
            let port = TagScan.firstTagContent(in: inner, tag: Tag.port).flatMap(UInt16.init) ?? 0
            return Endpoint(host: host, port: port)
        }
    }

    // MARK: - Punch probe (step 3)

    /// Final client-to-device hole-punch probe (`<C2D_T>`),
    /// sent to the camera's `<dmap>` address from the
    /// rendezvous reply. Carries the session + connection
    /// IDs and an MTU hint.
    public struct PunchProbe: Sendable, Hashable {
        public var sessionID: UInt32
        public var connectionID: UInt32
        /// Observed value `local`; matches the Reolink macOS
        /// app's wire bytes.
        public var connectionType: String
        public var mtu: Int

        public init(
            sessionID: UInt32,
            connectionID: UInt32,
            connectionType: String = "local",
            mtu: Int = 1350
        ) {
            self.sessionID = sessionID
            self.connectionID = connectionID
            self.connectionType = connectionType
            self.mtu = mtu
        }

        public func encode() -> Data {
            let xml = "<\(Tag.root)>" +
                "<\(Tag.punchProbe)>" +
                "<\(Tag.sessionID)>\(sessionID)</\(Tag.sessionID)>" +
                "<\(Tag.connectionType)>\(connectionType)</\(Tag.connectionType)>" +
                "<\(Tag.connectionID)>\(connectionID)</\(Tag.connectionID)>" +
                "<\(Tag.mtu)>\(mtu)</\(Tag.mtu)>" +
                "</\(Tag.punchProbe)>" +
                "</\(Tag.root)>"
            return Data(xml.utf8)
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
