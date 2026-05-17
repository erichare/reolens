import Foundation
import ReolinkBaichuan
import ReolinkBcUdp
import ReolinkP2P

/// End-to-end smoke test for `RemoteTransport` against a real
/// Reolink camera. Runs the three-step handshake (discovery →
/// rendezvous → punch) and reports detailed step-by-step status.
///
/// ## Usage
///
/// ```bash
/// swift run RemoteSmoke <uid> <username> <password>
/// ```
///
/// The UID is the 16-character Reolink-assigned identifier
/// printed on the camera or visible in the official app's
/// device-info screen. Run from any network — the whole point
/// is to exercise the remote path, so cellular hotspot or
/// off-LAN Wi-Fi is preferable.
///
/// ## What it tries
///
/// 1. `P2PDiscovery.lookup(uid:)` against the production
///    `p2p*.reolink.com` cluster.
/// 2. `RendezvousClient.rendezvous(...)` against the discovery
///    server's rendezvous endpoint.
/// 3. `HolePunchScheduler.punch(...)` against the camera's
///    NAT'd public address.
/// 4. If the channel opens, attempts a Baichuan `fetchUID`
///    round-trip to confirm bidirectional Baichuan flow works
///    over the data plane.
///
/// All stages print their inputs and outcomes to stdout. On
/// failure, the error and any diagnostic attempts are printed
/// in a structured form so the next debugging step is obvious.

@main
struct RemoteSmoke {
    static func main() async {
        let rawArgs = CommandLine.arguments
        var verbose = false
        var senderIDOverride: UInt32?
        var positional: [String] = []
        var i = 1
        while i < rawArgs.count {
            let arg = rawArgs[i]
            if arg == "--verbose" || arg == "-v" {
                verbose = true
                i += 1
            } else if arg == "--sender-id" {
                guard i + 1 < rawArgs.count else {
                    print("error: --sender-id requires a hex value (e.g. 0x003D0CCF)")
                    exit(2)
                }
                let hex = rawArgs[i + 1].replacingOccurrences(of: "0x", with: "")
                guard let parsed = UInt32(hex, radix: 16) else {
                    print("error: --sender-id value '\(rawArgs[i + 1])' is not valid hex")
                    exit(2)
                }
                senderIDOverride = parsed
                i += 2
            } else {
                positional.append(arg)
                i += 1
            }
        }
        guard positional.count == 3 else {
            print("usage: swift run RemoteSmoke [--verbose] [--sender-id <hex>] <uid> <username> <password>")
            print("  e.g. swift run RemoteSmoke -v 9527000I500W1NSQ admin secret")
            print("       swift run RemoteSmoke --sender-id 0x003D0CCF <uid> ...")
            exit(2)
        }
        let uid = positional[0]
        let username = positional[1]
        let password = positional[2]
        if verbose {
            PosixBcUdpTransport.verboseLogging = true
            print("[verbose] enabled — every outbound + inbound BcUdp packet will be hex-dumped")
        }
        if let senderIDOverride {
            P2PDiscovery.senderIDOverride = senderIDOverride
            print("[override] senderID = 0x\(String(format: "%08X", senderIDOverride))")
        }

        await run(uid: uid, username: username, password: password)
    }

    static func run(uid: String, username: String, password: String) async {
        section("Configuration")
        // `host` isn't used by `RemoteTransport` — discovery
        // locates the camera via UID — but `BaichuanCredentials`
        // requires a value. Pass a placeholder.
        let credentials = BaichuanCredentials(
            host: "remote",
            username: username,
            password: password
        )
        print("  uid        : \(uid)")
        print("  username   : \(username)")
        print("  password   : <\(password.count) chars>")
        print()

        // Build the production-wired stack against the public
        // `p2p*.reolink.com` cluster.
        let transport = RemoteTransport.production(
            credentials: credentials,
            uid: uid
        )

        section("Step 1-3 — RemoteTransport.connect()")
        let start = Date()
        // Per-second heartbeat so a hang is distinguishable from
        // a long-but-progressing call.
        let heartbeat = Task {
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                seconds += 1
                print("  · waiting (\(seconds)s) …")
            }
        }
        do {
            try await transport.connect()
            heartbeat.cancel()
            let elapsed = Date().timeIntervalSince(start)
            print("  ✓ connect succeeded in \(String(format: "%.2f", elapsed)) s")
            if let path = await transport.connectionPath {
                print("  → path: \(path)")
            }
        } catch {
            heartbeat.cancel()
            let elapsed = Date().timeIntervalSince(start)
            print("  ✗ connect failed after \(String(format: "%.2f", elapsed)) s")
            print("  error: \(error)")
            describe(error: error)
            print()
            print("Next debug step depends on which stage failed:")
            print("  P2PDiscoveryError.exhausted     → discovery: no server in")
            print("                                     pool answered. Check off-LAN.")
            print("  RendezvousError.serverRejected  → rendezvous server doesn't")
            print("                                     have a registration for this")
            print("                                     UID right now. Camera offline?")
            print("  RendezvousError.malformedReply  → wire format drift; need a")
            print("                                     fresh tcpdump to compare.")
            print("  RemoteTransportError.holePunchExhausted → real-NAT problem;")
            print("                                     check the punch engine's")
            print("                                     probe payload (it currently")
            print("                                     sends empty Disc, may need")
            print("                                     the C2D_T payload).")
            await transport.close()
            exit(1)
        }

        section("Step 4 — Baichuan fetchUID round-trip")
        // Wrap the transport in a BaichuanClient so we can drive
        // a real Baichuan operation over the remote path.
        let client = BaichuanClient(credentials: credentials, transport: transport)
        do {
            // The Baichuan layer expects login before most
            // commands, but `fetchUID` is one of the few that
            // works pre-login on most Reolink firmware. Try it
            // as a low-cost probe.
            print("  attempting fetchUID(channelID: 0) ...")
            let fetched = await client.fetchUID(channelID: 0)
            if fetched.isEmpty {
                print("  ✗ fetchUID returned empty (camera reply timed out or was")
                print("    empty). Channel may be up but Baichuan handshake didn't")
                print("    complete — typical if the punch engine's probe payload")
                print("    needs the real C2D_T contents.")
            } else {
                print("  ✓ fetchUID returned: \(fetched)")
                print("  → Remote control plane works end-to-end. Phase 4 (video")
                print("    pipeline) is the next chunk of work.")
            }
        }

        section("Teardown")
        await transport.close()
        print("  ✓ closed")
    }

    static func section(_ title: String) {
        print("== \(title) ==")
    }

    static func describe(error: any Error) {
        switch error {
        case let e as P2PDiscoveryError:
            print("  P2PDiscoveryError:")
            switch e {
            case .emptyServerPool:
                print("    .emptyServerPool")
            case .exhausted(let uid, let attempts):
                print("    .exhausted for uid \(uid):")
                for attempt in attempts {
                    print("      - \(attempt.host):\(attempt.port) → \(attempt.outcome)")
                }
            }
        case let e as RendezvousError:
            print("  RendezvousError: \(e.description)")
        case let e as RemoteTransportError:
            print("  RemoteTransportError: \(e.description)")
        case let e as HolePunchError:
            switch e {
            case .noCandidates:
                print("  HolePunchError.noCandidates")
            case .allFailed(let attempts):
                print("  HolePunchError.allFailed:")
                for attempt in attempts {
                    print("    - \(attempt.endpoint.host):\(attempt.endpoint.port) (\(attempt.path)) → \(attempt.outcome)")
                }
            }
        default:
            print("  raw error: \(type(of: error)) \(error.localizedDescription)")
        }
    }
}
