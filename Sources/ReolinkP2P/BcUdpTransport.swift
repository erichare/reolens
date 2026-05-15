import Foundation
import ReolinkBcUdp

/// Errors a `BcUdpTransport` may surface. Held at the protocol
/// level so `P2PDiscovery`'s fallback state machine can react
/// uniformly regardless of which concrete transport is in use.
public enum BcUdpTransportError: Error, Sendable, Equatable {
    /// Local-side problem opening or sending — host unreachable,
    /// no route, NWConnection failed to enter `.ready`. Not
    /// retried against the same host; the discovery actor moves
    /// to the next server.
    case unreachable(host: String, port: UInt16, detail: String)

    /// No reply arrived before `timeout` elapsed. This is the
    /// most common cause of a server-pool fallback — Reolink
    /// rotates which server in the pool answers a given UID, so
    /// the first one or two often quietly drop a request.
    case timedOut(host: String, port: UInt16)

    /// Bytes arrived but didn't decode to a BcUdp packet (wrong
    /// magic, truncated, etc.). Treated as fatal for the current
    /// server attempt — we don't trust the channel after a
    /// malformed reply.
    case malformedReply(host: String, port: UInt16)

    /// Reply decoded but its packet kind isn't usable for the
    /// caller's purpose (e.g. Discovery received a `Data` packet
    /// when it expected `Disc`). Treated the same as malformed.
    case unexpectedKind(host: String, port: UInt16, got: BcUdpPacketKind)
}

/// One-shot UDP send-and-await primitive. Each call opens, sends,
/// waits for the first reply, and closes — no connection state is
/// retained across calls. Phase 3 will add a stateful
/// `BcUdpConnection` protocol for the data-plane channel; for
/// discovery (request/response over UDP) the one-shot surface is
/// sufficient and keeps the test seam narrow.
///
/// ## Conformance contract
///
/// - Implementations MUST resolve `host` themselves. Discovery
///   passes hostnames from the server pool, not IP literals.
/// - Implementations MUST honor `timeout` as a wall-clock cap on
///   total time, not as a per-receive idle timer. The discovery
///   actor relies on this to bound its iteration over the server
///   pool.
/// - Implementations MUST NOT retry internally. Retry is the
///   actor's job — internal retries would hide a misbehaving
///   server from the fallback logic.
/// - Implementations MAY return any BcUdp packet kind; the
///   actor checks `kind` itself and surfaces
///   `unexpectedKind` when the reply isn't what it asked for.
public protocol BcUdpTransport: Sendable {
    func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket
}
