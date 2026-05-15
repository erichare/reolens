import Foundation

/// Connection mode picked for a camera based on what's
/// currently reachable. Used by `CameraSession` to decide
/// which `BcMessageTransport` to build when bringing the
/// Baichuan control plane up, and by Phase 5a's tile pip to
/// label the connection.
public enum CameraConnectionMode: Sendable, Equatable {
    /// LAN reachable; build a `LANTransport` and proceed
    /// normally. Green pip in the UI.
    case lan

    /// LAN unreachable but a stored UID exists; build a
    /// `RemoteTransport` and route through Reolink's P2P
    /// service. Amber/orange pip in the UI depending on
    /// whether the hole-punch lands direct or relayed (the
    /// transport itself surfaces that distinction once
    /// Phase 3d.2 ships).
    case remote

    /// Neither path is available — LAN is unreachable AND no
    /// UID is stored (so we can't even attempt remote). The
    /// camera tile shows the existing "offline" state.
    case offline
}

/// Pure decision rule. Lives in its own type so the LAN/
/// Remote/Offline logic can be unit-tested independently of
/// `CameraSession`'s networking state machine, and so the
/// branching is named (not buried inside an `if` cascade).
///
/// ## Why this is a pure function
///
/// The decision needs only three observable inputs and
/// produces exactly one mode. Anchoring it as a static
/// function keeps it deterministic, easy to test, and easy
/// to read without scanning the surrounding actor isolation.
///
/// ## Inputs
///
/// - `lanReachable`: Result of the existing CGI/HTTP probe.
///   `true` means the camera answered on the local network
///   within the 3-second window (decision #2 in
///   `docs/0.7.0-plan.md`); `false` covers both DNS failure
///   and timeout.
/// - `storedUID`: The UID captured during a prior LAN login
///   and persisted to `CameraEntry.uid` (Phase 4b). `nil`
///   means we've never observed the UID, so we cannot
///   attempt remote.
/// - `remoteAccessAllowed`: The user's app-wide opt-out
///   (decision #10 → single toggle in Settings, default ON).
///   When `false`, the rule short-circuits any remote path
///   even when a UID is available.
///
/// ## Decision matrix
///
/// | LAN reachable | UID stored | Remote allowed | Result    |
/// |---------------|------------|----------------|-----------|
/// | yes           | any        | any            | `.lan`    |
/// | no            | yes        | yes            | `.remote` |
/// | no            | yes        | no             | `.offline`|
/// | no            | no         | any            | `.offline`|
public enum CameraReachability {
    public static func decide(
        lanReachable: Bool,
        storedUID: String?,
        remoteAccessAllowed: Bool
    ) -> CameraConnectionMode {
        if lanReachable {
            return .lan
        }
        guard remoteAccessAllowed,
              let uid = storedUID,
              !uid.isEmpty else {
            return .offline
        }
        return .remote
    }
}
