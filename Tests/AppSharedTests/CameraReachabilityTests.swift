import Testing
@testable import AppShared

/// Unit tests for the `CameraReachability.decide` rule. The
/// rule is pure, so the tests just enumerate the truth table
/// and pin the expected mode for each combination.
@Suite("CameraReachability decision matrix")
struct CameraReachabilityTests {

    @Test("LAN reachable -> .lan regardless of remoteHost or opt-out")
    func lanReachableAlwaysWins() {
        #expect(CameraReachability.decide(lanReachable: true, hasRemoteHost: false, remoteAccessAllowed: true) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, hasRemoteHost: true, remoteAccessAllowed: true) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, hasRemoteHost: true, remoteAccessAllowed: false) == .lan)
        #expect(CameraReachability.decide(lanReachable: true, hasRemoteHost: false, remoteAccessAllowed: false) == .lan)
    }

    @Test("LAN unreachable + remoteHost set + remote allowed -> .remote")
    func remoteFallback() {
        #expect(CameraReachability.decide(lanReachable: false, hasRemoteHost: true, remoteAccessAllowed: true) == .remote)
    }

    @Test("LAN unreachable + remoteHost set + remote disabled -> .offline")
    func remoteDisabledOptOut() {
        // App-wide "Allow remote access" toggle: when OFF, the
        // user is opted out and an unreachable LAN cam stays
        // offline rather than dialing the DDNS host.
        #expect(CameraReachability.decide(lanReachable: false, hasRemoteHost: true, remoteAccessAllowed: false) == .offline)
    }

    @Test("LAN unreachable + no remoteHost -> .offline")
    func noRemoteHostMeansOffline() {
        // Camera was added with LAN-only config; nothing the
        // session can do when off-network.
        #expect(CameraReachability.decide(lanReachable: false, hasRemoteHost: false, remoteAccessAllowed: true) == .offline)
    }
}
