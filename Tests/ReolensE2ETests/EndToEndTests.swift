import Foundation
import Testing
@testable import ReolinkAPI

/// End-to-end test for the Reolink CGI client.
///
/// Drives the full command pipeline against an in-process URL-protocol
/// stub that simulates a Reolink Home Hub: login (returns a token),
/// GetDevInfo (one camera attached), GetChannelstatus (one online
/// channel), GetMdState (no motion), then GetMdState again (motion
/// triggered) — all through the same `CGIClient` actor instance, which
/// must reuse its cached token across the second-and-later calls.
///
/// This is the smallest meaningful test that catches:
///   - URL construction (cgiURL append, query items)
///   - JSON encoding of batched commands
///   - Token issue/cache (only one Login should hit the wire)
///   - Per-command response decoding
///   - Retry-on-loginRequired (the test fakes a -10 mid-session and
///     verifies the client transparently re-logs in and retries)
///
/// All without touching SwiftUI, the keychain, or any real network.
/// `.serialized` because the URLProtocol stub holds a process-wide
/// `static var server` reference. Running these tests in parallel would
/// have one test's requests land on another test's mock.
@Suite("Reolink end-to-end (mocked transport)", .serialized)
struct EndToEndTests {

    @Test("Full session flow: login → device info → channels → motion poll → token reuse")
    func fullSessionFlow() async throws {
        let mock = MockReolinkServer()
        await mock.reset()
        MockURLProtocol.server = mock

        let session = makeSession()
        let creds = CameraCredentials(
            host: "192.0.2.10",   // RFC 5737 — guaranteed to never be a real host
            port: 80,
            username: "admin",
            password: "hunter2"
        )
        let client = CGIClient(credentials: creds, urlSession: session)

        // 1. Initial login lands cached token.
        let token = try await client.login()
        #expect(!token.name.isEmpty)
        #expect(token.leaseTime > 0)

        // 2. GetDevInfo. The client should reuse the cached token (not log
        //    in again).
        let devInfo: DeviceInfoEnvelope = try await client.send(
            Commands.getDevInfo(),
            as: DeviceInfoEnvelope.self
        )
        #expect(devInfo.DevInfo.model == "Reolink Home Hub")
        #expect(devInfo.DevInfo.channelNum == 1)
        #expect(devInfo.DevInfo.isHomeHub)

        // 3. GetChannelstatus. One online camera.
        let channels: ChannelStatusEnvelope = try await client.send(
            Commands.getChannelStatus(),
            as: ChannelStatusEnvelope.self
        )
        #expect(channels.count == 1)
        #expect(channels.status.first?.isOnline == true)
        #expect(channels.status.first?.name == "Front Door")

        // 4. First motion poll: nothing happening.
        let quiet: MotionStateValue = try await client.send(
            Commands.getMdState(channel: 0),
            as: MotionStateValue.self
        )
        #expect(quiet.isTriggered == false)

        // 5. Flip the mock to "motion firing" and poll again. Same token.
        await mock.setMotion(triggered: true)
        let firing: MotionStateValue = try await client.send(
            Commands.getMdState(channel: 0),
            as: MotionStateValue.self
        )
        #expect(firing.isTriggered)

        // 6. Confirm token wasn't issued more than once across all calls.
        let stats = await mock.snapshot()
        #expect(stats.loginCount == 1, "client should reuse cached token, not re-login per call")
        #expect(stats.commandsSeen.contains("GetDevInfo"))
        #expect(stats.commandsSeen.contains("GetChannelstatus"))
        #expect(stats.commandsSeen.contains("GetMdState"))
    }

    @Test("Transparent re-login after server signals loginRequired (-10)")
    func reloginOnExpiredToken() async throws {
        let mock = MockReolinkServer()
        await mock.reset()
        // Configure the mock to return -10 (loginRequired) on the next
        // non-Login command, simulating a server-side token expiry.
        await mock.expireTokenOnce()
        MockURLProtocol.server = mock

        let session = makeSession()
        let creds = CameraCredentials(host: "192.0.2.11", port: 80, username: "admin", password: "x")
        let client = CGIClient(credentials: creds, urlSession: session)

        let info: DeviceInfoEnvelope = try await client.send(
            Commands.getDevInfo(),
            as: DeviceInfoEnvelope.self
        )
        #expect(info.DevInfo.model == "Reolink Home Hub")

        let stats = await mock.snapshot()
        // First Login → Server issues token
        // GetDevInfo → mock returns -10, client drops cached token
        // Second Login → Server issues fresh token
        // GetDevInfo retry → success
        #expect(stats.loginCount == 2, "client should re-login exactly once after -10")
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - In-process Reolink mock

/// A minimal, thread-safe stand-in for a Reolink device's CGI endpoint.
/// Tracks issued tokens, command counts, and a couple of toggleable
/// state flags so tests can assert behavior without touching the wire.
actor MockReolinkServer {
    struct Snapshot {
        let loginCount: Int
        let commandsSeen: Set<String>
        let issuedToken: String?
    }

    private var loginCount = 0
    private var commandsSeen: Set<String> = []
    private var issuedToken: String?
    private var motionTriggered = false
    private var pendingExpire = false

    func reset() {
        loginCount = 0
        commandsSeen = []
        issuedToken = nil
        motionTriggered = false
        pendingExpire = false
    }

    func setMotion(triggered: Bool) { motionTriggered = triggered }
    func expireTokenOnce() { pendingExpire = true }

    func snapshot() -> Snapshot {
        Snapshot(loginCount: loginCount, commandsSeen: commandsSeen, issuedToken: issuedToken)
    }

    /// Handle a single CGI request. The body is the JSON array of one
    /// command — we route on `cmd` and return canned JSON.
    func respond(to body: Data) -> Data {
        // Decode the wrapping command array. We only inspect `cmd` —
        // the param payload is opaque for routing.
        struct Wrap: Decodable { let cmd: String }
        let commands: [Wrap]
        do {
            commands = try JSONDecoder().decode([Wrap].self, from: body)
        } catch {
            return jsonError(cmd: "?", code: -5)  // protocol error
        }
        guard let first = commands.first else {
            return jsonError(cmd: "?", code: -1)
        }
        commandsSeen.insert(first.cmd)

        switch first.cmd {
        case "Login":
            loginCount += 1
            let token = "tok-\(loginCount)"
            issuedToken = token
            return loginResponse(token: token)

        case "GetDevInfo":
            if pendingExpire {
                pendingExpire = false
                return jsonError(cmd: "GetDevInfo", code: CGIErrorCode.loginRequired.rawValue)
            }
            return devInfoResponse()

        case "GetChannelstatus":
            return channelStatusResponse()

        case "GetMdState":
            return motionResponse(triggered: motionTriggered)

        default:
            return jsonError(cmd: first.cmd, code: CGIErrorCode.notSupport.rawValue)
        }
    }

    // MARK: response builders

    private func loginResponse(token: String) -> Data {
        let json = """
        [{
          "cmd":"Login","code":0,
          "value":{"Token":{"leaseTime":3600,"name":"\(token)"}}
        }]
        """
        return Data(json.utf8)
    }

    private func devInfoResponse() -> Data {
        let json = """
        [{
          "cmd":"GetDevInfo","code":0,
          "value":{"DevInfo":{
            "name":"Hub","model":"Reolink Home Hub","type":"Hub",
            "hardVer":"IPC_RES1.0","firmVer":"v3.0.0.0",
            "serial":"E2E000000000","channelNum":1,
            "buildDay":"build 20251201","cfgVer":"v3.1.0.0","detail":"e2e",
            "diskNum":1,"wifi":1,"b485":0,"IOInputNum":0,"IOOutputNum":0,
            "audioNum":1,"pakSuffix":"pak","exactType":"NVR"
          }}
        }]
        """
        return Data(json.utf8)
    }

    private func channelStatusResponse() -> Data {
        let json = """
        [{
          "cmd":"GetChannelstatus","code":0,
          "value":{"count":1,"status":[
            {"channel":0,"name":"Front Door","online":1,"typeInfo":"Argus 4 Pro","sleep":0}
          ]}
        }]
        """
        return Data(json.utf8)
    }

    private func motionResponse(triggered: Bool) -> Data {
        let json = """
        [{
          "cmd":"GetMdState","code":0,
          "value":{"state":\(triggered ? 1 : 0),"channel":0}
        }]
        """
        return Data(json.utf8)
    }

    private func jsonError(cmd: String, code: Int) -> Data {
        let json = """
        [{"cmd":"\(cmd)","code":\(code),"error":{"rspCode":\(code),"detail":"mock"}}]
        """
        return Data(json.utf8)
    }
}

// MARK: - URLProtocol stub

/// Routes every URLSession request that mentions `cgi-bin/api.cgi` into
/// the static `server` actor. The server is set per-test before each
/// run; tests that share a server must `await server.reset()` first.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: MockReolinkServer?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("cgi-bin/api.cgi") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = MockURLProtocol.server,
              let body = readBody(from: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let req = request
        let urlClient = client
        Task {
            let data = await server.respond(to: body)
            let url = req.url ?? URL(string: "http://mock/cgi-bin/api.cgi")!
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            urlClient?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlClient?.urlProtocol(self, didLoad: data)
            urlClient?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { /* nothing to cancel */ }

    private func readBody(from req: URLRequest) -> Data? {
        if let direct = req.httpBody { return direct }
        // URLSession converts bodies into a stream when you set
        // `httpBody`; drain it here.
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
