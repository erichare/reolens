import Foundation

/// Bootstrap list of Reolink discovery servers. Each entry is a
/// `(host, port)` pair the `P2PDiscovery` actor will try in order
/// when looking a UID up.
///
/// **Ship-as-code for now, JSON later.** The original plan in
/// `docs/remote-connectivity.md` floats "ship the pool as a JSON
/// resource so it's hot-fixable without an app release". That's
/// likely the right call eventually, but until Phase 2's first
/// real-world packet captures confirm which servers in the pool
/// actually answer for the user's region, hard-coded constants
/// are simpler to reason about — and the actor consumes a
/// `DiscoveryServerPool` value either way, so swapping the source
/// later is mechanical.
///
/// **Pool composition pending Phase 2 validation.** The hostname
/// list below is best-effort recall from public reverse-
/// engineering work. Phase 2 / 2b will confirm against the
/// official app's DNS queries; if any host is wrong, it gets
/// removed here in a one-line edit.
public struct DiscoveryServerPool: Sendable, Equatable, Hashable {
    public struct Entry: Sendable, Equatable, Hashable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Default UDP port the discovery cluster listens on.
    /// `9999` per neolink's `bcudp` reference; 9000 is the
    /// Baichuan TCP port (different service).
    public static let defaultPort: UInt16 = 9999

    /// Production bootstrap pool. Ordered roughly by observed
    /// availability — Phase 2 telemetry will resort this once we
    /// have real-world failure-rate numbers. Until then, iterating
    /// in the listed order is fine because the actor falls
    /// through on per-host timeout.
    public static let `default` = DiscoveryServerPool(entries: [
        Entry(host: "p2p.reolink.com",   port: defaultPort),
        Entry(host: "p2p2.reolink.com",  port: defaultPort),
        Entry(host: "p2p3.reolink.com",  port: defaultPort),
        Entry(host: "p2p4.reolink.com",  port: defaultPort),
        Entry(host: "p2p5.reolink.com",  port: defaultPort),
        Entry(host: "p2p6.reolink.com",  port: defaultPort),
        Entry(host: "p2p7.reolink.com",  port: defaultPort),
        Entry(host: "p2p8.reolink.com",  port: defaultPort),
        Entry(host: "p2p9.reolink.com",  port: defaultPort)
    ])
}
