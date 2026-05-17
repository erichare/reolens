import Foundation

/// Connection mode picked for a camera based on what's
/// currently reachable. Used by `CameraSession` to decide
/// which host to dial when bringing up the CGI + Baichuan
/// control planes, and by the UI to label the connection.
public enum CameraConnectionMode: Sendable, Equatable {
    /// LAN reachable; use `CameraEntry.host` directly. Green
    /// pip in the UI.
    case lan

    /// LAN unreachable but a user-configured remote host
    /// (DDNS / WAN address) is set; dial that instead. Amber
    /// pip in the UI.
    case remote

    /// Neither path is available — LAN is unreachable AND no
    /// `remoteHost` is configured. The camera tile shows the
    /// "offline" state.
    case offline
}

/// Pure decision rule. Lives in its own type so the LAN/
/// Remote/Offline logic can be unit-tested independently of
/// `CameraSession`'s networking state machine.
///
/// ## Why this is a pure function
///
/// The decision needs only three observable inputs and
/// produces exactly one mode. Anchoring it as a static
/// function keeps it deterministic, easy to test, and easy
/// to read without scanning the surrounding actor isolation.
///
/// ## History (0.7.0)
///
/// The earlier draft of this rule keyed remote on a stored
/// camera UID — the input the Reolink P2P discovery path
/// would have needed. That path turned out to be account-
/// gated on Reolink's cloud (see `docs/0.7.0-plan.md` for
/// the full reverse-engineering story) and we pivoted to a
/// manual DDNS / WAN-host fallback instead. The input is now
/// the boolean `hasRemoteHost`, derived from
/// `CameraEntry.remoteHost != nil && !remoteHost.isEmpty`.
///
/// ## Inputs
///
/// - `lanReachable`: result of the existing CGI/HTTP probe.
///   `true` means the camera answered on the local network
///   within the configured timeout; `false` covers both DNS
///   failure and timeout.
/// - `hasRemoteHost`: whether the user has configured a
///   `remoteHost` for this camera. `false` for LAN-only
///   setups.
/// - `remoteAccessAllowed`: the user's app-wide opt-out
///   toggle. When `false`, the rule short-circuits the
///   remote path even when a remote host is configured.
///
/// ## Decision matrix
///
/// | LAN reachable | Remote host set | Remote allowed | Result    |
/// |---------------|-----------------|----------------|-----------|
/// | yes           | any             | any            | `.lan`    |
/// | no            | yes             | yes            | `.remote` |
/// | no            | yes             | no             | `.offline`|
/// | no            | no              | any            | `.offline`|
public enum CameraReachability {
    public static func decide(
        lanReachable: Bool,
        hasRemoteHost: Bool,
        remoteAccessAllowed: Bool
    ) -> CameraConnectionMode {
        if lanReachable {
            return .lan
        }
        guard remoteAccessAllowed, hasRemoteHost else {
            return .offline
        }
        return .remote
    }
}
