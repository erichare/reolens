import Foundation

/// `ReolinkP2P` — discovery client + BcUdp transport surface for
/// the Reolink P2P service. Sits on top of the pure-codec
/// [`ReolinkBcUdp`](../ReolinkBcUdp) module and adds the actor +
/// state machine that maps a camera's UID to a current set of
/// network candidates (WAN address, LAN address, relay hint).
///
/// ## Layering
///
/// ```
///   ReolinkBaichuan  ← BcMessage / TCP login & control
///   ReolinkP2P       ← P2PDiscovery (this module), Transport,
///                       NAT-traversal state machine (Phase 3),
///                       Relay client (Phase 3)
///   ReolinkBcUdp     ← Disc / Data / Ack codec + DiscoveryXML
/// ```
///
/// `ReolinkBaichuan` does not depend on this module today; in
/// Phase 3 the Baichuan client gains a `Transport` protocol so
/// the remote-transport here can be slotted in transparently.
///
/// ## What ships in Phase 2
///
/// - [`P2PDiscovery`](./P2PDiscovery.swift) — actor that, given a
///   UID, walks the `p2p*.reolink.com` server pool and returns
///   the first non-empty `LookupResponse`.
/// - [`BcUdpTransport`](./BcUdpTransport.swift) — abstract
///   send-and-await surface so tests and Phase 3 implementations
///   plug in without touching the actor's logic.
/// - [`DiscoveryServerPool`](./DiscoveryServerPool.swift) —
///   bootstrap list of discovery endpoints, shipped as code
///   constants (the "ship as JSON resource" decision is still
///   open per `docs/remote-connectivity.md` § "Open questions").
///
/// ## What does NOT ship in Phase 2
///
/// - A concrete `NWConnection`-backed `BcUdpTransport`. The actor
///   is pre-wired against the protocol; the concrete UDP
///   transport lands in a focused follow-up where its
///   integration against a real device can be validated
///   end-to-end.
/// - NAT traversal, hole punching, relay client (Phase 3).
/// - Wire integration with `BaichuanClient` (Phase 3 refactor).
public enum ReolinkP2P {
    public static let phase = "0.7.0-phase2"
}
