import Foundation

/// `ReolinkBcUdp` — wire codec for the UDP packet format Reolink
/// uses when a camera is reached via their P2P service (away from
/// LAN). Pure value-type encode / decode; no networking primitives,
/// no actors, no I/O. The transport, discovery, NAT-traversal,
/// and relay layers are subsequent phases — see
/// `docs/remote-connectivity.md`.
///
/// ## Why a separate module?
///
/// Three reasons:
///
/// 1. **Layering.** The BcUdp framing is *Reolink-UDP-specific* and
///    sits below the Baichuan TCP message types in
///    [`ReolinkBaichuan`](../ReolinkBaichuan). A Baichuan message
///    encoded for TCP is essentially the same bytes that get carried
///    inside a BcUdp `Data` packet (possibly across multiple
///    packets), so the two modules are peers — neither imports the
///    other.
/// 2. **Testability.** All wire-format work for remote connectivity
///    can be exercised through `swift test --filter
///    ReolinkBcUdpTests` without spinning up any network mock.
/// 3. **Iteration safety.** Phase 2 (discovery client) will mature
///    fastest if the codec is stable; isolating it here lets us
///    lock byte layouts before any code reaches the network.
///
/// ## Reference
///
/// Wire format is reverse-engineered in
/// `thirtythreeforty/neolink` (Rust, GPLv3), specifically
/// `crates/core/src/bcudp/{codec.rs, model.rs}`. We do not copy
/// code (license-incompatible with Reolens' MIT) — the wire
/// format itself is a fact and is fair game to re-implement. The
/// constants in [`BcUdpConstants`](./Wire/BcUdpConstants.swift)
/// cite their neolink source lines.
///
/// ## Endianness
///
/// BcUdp is **big-endian** end-to-end. This is the opposite of the
/// Baichuan TCP protocol (`ReolinkBaichuan`), which is
/// little-endian. The mismatch is a Reolink-protocol quirk, not a
/// bug — both modules carry their own `Data` helpers
/// (`readBE` / `appendBE` here; `readLE` / `appendLE` there).
public enum ReolinkBcUdp {
    /// Module-level version string, used in diagnostic logging
    /// when the transport eventually lands. Bumped when the wire
    /// codec gains a backwards-incompatible change (which should
    /// be never — the camera protocol is fixed).
    public static let codecVersion = "0.7.0-phase1"
}
