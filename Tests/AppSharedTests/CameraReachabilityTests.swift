import Testing
@testable import AppShared

/// Unit tests for the `CameraReachability.decide` rule. The
/// rule is pure, so the tests just enumerate the truth table
/// and pin the expected mode for each combination.
///
/// `CameraSession`'s integration with this rule lands in a
/// follow-up (Phase 4-era) — gating the integration on a
/// working video pipeline avoids the regression of showing a
/// "connected (remote)" state where the camera tile loads but
/// has no playable stream. The decision rule itself is
/// stable enough to ship now.
@Suite("CameraReachability decision matrix")
struct CameraReachabilityTests {

    @Test("LAN reachable -> .lan regardless of UID or opt-out")
    func lanReachableAlwaysWins() {
        #expect(CameraReachability.decide(lanReachable: true, storedUID: nil, remoteAccessAllowed: true) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, storedUID: "FEED", remoteAccessAllowed: true) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, storedUID: "FEED", remoteAccessAllowed: false) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, storedUID: nil, remoteAccessAllowed: false) == .lan)
    }

    @Test("LAN unreachable + UID stored + remote allowed -> .remote")
    func remoteFallback() {
        #expect(CameraReachability.decide(lanReachable: false, storedUID: "FEED1234", remoteAccessAllowed: true) == .remote)
    }

    @Test("LAN unreachable + UID stored + remote disabled -> .offline")
    func remoteDisabledOptOut() {
        // Decision #10: app-wide "Allow remote access" toggle.
        // When OFF, the user is opted out and an unreachable
        // LAN cam stays offline rather than failing over.
        #expect(CameraReachability.decide(lanReachable: false, storedUID: "FEED1234", remoteAccessAllowed: false) == .offline)
    }

    @Test("LAN unreachable + no UID -> .offline")
    func noUIDMeansOffline() {
        // Camera was never successfully logged into on LAN, so
        // we have no key to look it up via discovery.
        #expect(CameraReachability.decide(lanReachable: false, storedUID: nil, remoteAccessAllowed: true) == .offline)
    }

    @Test("LAN unreachable + empty UID string -> .offline")
    func emptyUIDTreatedAsMissing() {
        // `BaichuanClient.fetchUID` returns "" on failure;
        // recordUID never persists empty strings, but tests
        // and defensive code paths still need the rule to
        // treat empty same as missing.
        #expect(CameraReachability.decide(lanReachable: false, storedUID: "", remoteAccessAllowed: true) == .offline)
    }
}
