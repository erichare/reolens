import Foundation
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "rendezvous")

/// Step 2 of the Reolink P2P handshake: client → rendezvous
/// server. Counterpart to `P2PDiscovery` for the second
/// exchange.
///
/// ## Flow
///
/// 1. Discovery (`P2PDiscovery`) returned a rendezvous endpoint
///    via `LookupResponse.rendezvous`. Pass it here.
/// 2. We send a `<C2R_C>` packet to that endpoint, encrypted
///    against our minted `senderID`, with the camera's UID, a
///    placeholder client-IP hint, the relay endpoint we'd
///    prefer if direct fails, and a client-minted connection
///    ID.
/// 3. The server replies with `<R2C_T>` (compact) or
///    `<R2C_C_R>` (full). Both carry the camera's `<dmap>`
///    (NAT'd public endpoint) — the hole-punch target — plus a
///    server-assigned session ID we'll quote in the final
///    probe.
///
/// ## Status (Phase 3d.2 finish)
///
/// All wire details validated against the 2026-05-16 probe
/// pcap (`reolink-p2p-probe.pcap`). Untested: how the
/// rendezvous server reacts to our specific client-hint IP
/// value (the Reolink macOS app sent `192.0.0.3:19031`, which
/// looks placeholder-ish — IANA-reserved range — and the
/// server presumably figures the real source from the UDP
/// envelope). We send the same placeholder.
public actor RendezvousClient {

    private let transport: any BcUdpTransport
    private let clientHintProvider: @Sendable () -> DiscoveryXML.Endpoint

    public init(
        transport: any BcUdpTransport,
        clientHintProvider: @escaping @Sendable () -> DiscoveryXML.Endpoint = RendezvousClient.defaultClientHint
    ) {
        self.transport = transport
        self.clientHintProvider = clientHintProvider
    }

    /// Run the rendezvous exchange. On success, returns the
    /// camera's `<dmap>` + `<dev>` endpoints plus the
    /// server-assigned session ID.
    public func rendezvous(
        uid: String,
        rendezvousEndpoint: DiscoveryXML.Endpoint,
        relayHint: DiscoveryXML.Endpoint,
        connectionID: UInt32,
        timeout: Duration = .seconds(3)
    ) async throws -> DiscoveryXML.RendezvousReply {
        let senderID = UInt32.random(in: 1...UInt32.max)
        let request = DiscoveryXML.RendezvousRequest(
            uid: uid,
            clientHint: clientHintProvider(),
            relayHint: relayHint,
            connectionID: connectionID
        )
        let plaintext = request.encode()
        let ciphertext = DiscoveryXMLCrypto.encrypt(plaintext, offset: senderID)
        let packet = BcUdpPacket.disc(
            BcUdpDiscPacket(senderID: senderID, payload: ciphertext)
        )

        log.info("Rendezvous to \(rendezvousEndpoint.host, privacy: .public):\(rendezvousEndpoint.port) uid=\(uid, privacy: .private) cid=\(connectionID)")
        let reply = try await transport.sendAndAwaitReply(
            packet,
            to: rendezvousEndpoint.host,
            port: rendezvousEndpoint.port,
            timeout: timeout
        )
        guard case .disc(let disc) = reply else {
            throw RendezvousError.unexpectedKind(reply.kind)
        }
        let plain = DiscoveryXMLCrypto.decrypt(disc.payload, offset: disc.senderID)
        guard let parsed = DiscoveryXML.RendezvousReply.decode(from: plain) else {
            throw RendezvousError.malformedReply
        }
        if parsed.responseCode != 0 {
            throw RendezvousError.serverRejected(code: parsed.responseCode)
        }
        guard parsed.deviceMappedEndpoint != nil else {
            // A success-coded reply with no dmap is degenerate
            // — the server says OK but didn't tell us where to
            // punch. Surface as malformed so the caller can
            // fall back.
            throw RendezvousError.malformedReply
        }
        log.info("Rendezvous OK sid=\(parsed.sessionID)")
        return parsed
    }

    /// Default client hint matches what the Reolink macOS app
    /// sends — `192.0.0.3:19031`. The IP is IANA-reserved
    /// (`192.0.0.0/29`); the server appears to ignore the
    /// value and use the source address from the UDP envelope.
    /// Tests can inject a different provider via the init.
    public static let defaultClientHint: @Sendable () -> DiscoveryXML.Endpoint = {
        DiscoveryXML.Endpoint(host: "192.0.0.3", port: 19031)
    }
}

public enum RendezvousError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// Reply was not a `BcUdpPacket.disc`. Treat as a hard
    /// failure — the rendezvous protocol doesn't use Data /
    /// Ack at this stage.
    case unexpectedKind(BcUdpPacketKind)
    /// Reply decoded to a Disc but the payload didn't parse
    /// as a valid `R2C_*` schema, or had no `<dmap>`.
    case malformedReply
    /// Server returned a non-zero `<rsp>`. Code values aren't
    /// fully documented; `-3` is the canonical "no
    /// registration" response (same as discovery).
    case serverRejected(code: Int)

    public var description: String {
        switch self {
        case .unexpectedKind(let kind):
            "Rendezvous reply had unexpected BcUdp kind \(kind)"
        case .malformedReply:
            "Rendezvous reply payload was missing required fields"
        case .serverRejected(let code):
            "Rendezvous server returned rsp=\(code)"
        }
    }

    public var errorDescription: String? { description }
}
