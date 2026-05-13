import Testing
import Foundation
import ReolinkAPI
@testable import AppShared

/// 0.5.1 — `CameraSession.isAuthFailure(_:)` decides whether to stop
/// retrying or keep going on a failed `connect()` attempt. The
/// previous substring-based heuristic mis-fired on transient Reolink
/// errors whose descriptions contained "login" (e.g. -10
/// loginRequired, -15 loginAlready), surfacing "Authentication
/// failed" on startup when a "Try Again" click would immediately
/// succeed. Pin the new typed classifier so that regression can't
/// silently come back.
@Suite("CameraSession.isAuthFailure classifier")
struct AuthFailureClassifierTests {

    private func cgiError(_ code: CGIErrorCode) -> CGIError {
        CGIError(rspCode: code.rawValue, detail: nil)
    }

    // MARK: - Real auth failures (stop retrying)

    @Test("invalidUser (-14) is a real auth failure")
    func invalidUserStopsRetry() {
        let err = ReolinkClientError.loginFailed(cgiError(.invalidUser))
        #expect(CameraSession.isAuthFailure(err))
    }

    @Test("invalidUser on a non-login command is still a real auth failure")
    func invalidUserOnAnyCommand() {
        let err = ReolinkClientError.commandFailed(cmd: "GetDevInfo", error: cgiError(.invalidUser))
        #expect(CameraSession.isAuthFailure(err))
    }

    @Test("HTTP 401 is a real auth failure")
    func http401() {
        let err = ReolinkClientError.http(status: 401, body: nil)
        #expect(CameraSession.isAuthFailure(err))
    }

    @Test("HTTP 403 is a real auth failure")
    func http403() {
        let err = ReolinkClientError.http(status: 403, body: nil)
        #expect(CameraSession.isAuthFailure(err))
    }

    // MARK: - Transient errors (keep retrying) — the bug regressions

    @Test("loginRequired (-10) is transient — token expired, retry")
    func loginRequiredIsTransient() {
        let err = ReolinkClientError.loginFailed(cgiError(.loginRequired))
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("loginError (-11) is transient — ambiguous, often hub-busy on boot")
    func loginErrorIsTransient() {
        let err = ReolinkClientError.loginFailed(cgiError(.loginError))
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("loginAlready (-15) is transient — race with another session")
    func loginAlreadyIsTransient() {
        let err = ReolinkClientError.loginFailed(cgiError(.loginAlready))
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("lockedByOthers (-16) is transient — temporary lock, retry")
    func lockedByOthersIsTransient() {
        let err = ReolinkClientError.loginFailed(cgiError(.lockedByOthers))
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("loginFailed (-20) is transient — ambiguous, prefer retry")
    func loginFailedIsTransient() {
        let err = ReolinkClientError.loginFailed(cgiError(.loginFailed))
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("loginFailed with no inner CGI error is transient")
    func loginFailedNoInnerError() {
        let err = ReolinkClientError.loginFailed(nil)
        #expect(!CameraSession.isAuthFailure(err))
    }

    // MARK: - Non-Reolink errors

    @Test("URLError transport failures are never auth failures")
    func urlErrorIsNotAuth() {
        let err = URLError(.timedOut)
        #expect(!CameraSession.isAuthFailure(err))
    }

    @Test("Random Reolink HTTP failures (5xx) are not auth failures")
    func http5xxIsNotAuth() {
        let err = ReolinkClientError.http(status: 503, body: "service unavailable")
        #expect(!CameraSession.isAuthFailure(err))
    }
}
