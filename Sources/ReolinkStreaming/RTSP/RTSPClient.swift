import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.reolens.streaming", category: "rtsp")

public enum RTSPError: Error, CustomStringConvertible {
    case connectionFailed(any Error)
    case protocolError(String)
    case authenticationFailed
    case status(Int, reason: String)
    case noVideoTrack
    case malformedURL
    case cancelled

    public var description: String {
        switch self {
        case .connectionFailed(let e): "Connection failed: \(e)"
        case .protocolError(let s): "Protocol error: \(s)"
        case .authenticationFailed: "Authentication failed"
        case .status(let c, let r): "RTSP \(c) \(r)"
        case .noVideoTrack: "No video track in SDP"
        case .malformedURL: "Malformed URL"
        case .cancelled: "Cancelled"
        }
    }
}

public enum RTPChannelMessage: Sendable {
    case rtp(channel: UInt8, packet: RTPPacket)
    case rtcp(channel: UInt8, data: Data)
    case closed
}

/// An actor-isolated RTSP client over TCP with interleaved RTP/RTCP.
///
/// Lifecycle:
///   1. `connect(url:credentials:)` — opens TCP, OPTIONS, DESCRIBE, parses SDP.
///   2. `setupVideo()` — SETUP with interleaved channels 0/1.
///   3. `play()` — PLAY; returns an `AsyncStream<RTPChannelMessage>` for the caller.
///   4. `teardown()` — TEARDOWN + close the socket.
///
/// Interleaved framing per RFC 2326 §10.12:
///   `$<channel:1><length:2><RTP-or-RTCP-payload>`
public actor RTSPClient {

    public struct Configuration: Sendable {
        public let url: URL
        public let username: String
        public let password: String
        public let userAgent: String
        public let connectTimeout: TimeInterval

        public init(url: URL, username: String, password: String, userAgent: String = "Reolens/0.1", connectTimeout: TimeInterval = 5) {
            self.url = url
            self.username = username
            self.password = password
            self.userAgent = userAgent
            self.connectTimeout = connectTimeout
        }
    }

    private let config: Configuration
    private var connection: NWConnection?
    private var cseq = 0
    private var session: String?
    private var sdp: SessionDescription?
    private var pendingResponse: CheckedContinuation<RTSPResponse, any Error>?
    private var readBuffer = Data()
    private var dataStream: AsyncStream<RTPChannelMessage>.Continuation?
    private var receiveLoopStarted = false
    private var contentBase: String?
    /// Session timeout reported by the server in the SETUP response. Used to
    /// drive the keepalive cadence. RFC 2326 default is 60s; Reolink uses 30s.
    private var sessionTimeoutSeconds: TimeInterval = 60
    private var keepaliveTask: Task<Void, Never>?

    /// Reolink and most RTSP servers expect the client to send periodic RTCP
    /// Receiver Reports. Without them the server eventually concludes the
    /// client has gone away (or its outgoing buffer fills) and stops sending
    /// RTP — which manifests as a freeze ~5–10 s into playback.
    private var rtcpInterleavedChannel: UInt8 = 1
    private var ourRtcpSSRC: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var lastSenderSSRC: UInt32 = 0
    private var highestSeenSeq: UInt16 = 0
    private var rtcpTask: Task<Void, Never>?
    /// Cached challenge from the server's 401. Used to compute fresh Authorization
    /// headers per request (since HA2 = MD5(method:uri) varies).
    private var authChallenge: DigestChallenge?
    private var ncCounter: Int = 0
    private let sessionCnonce: String = DigestAuth.makeCnonce()

    public init(configuration: Configuration) {
        self.config = configuration
    }

    /// One-shot wrapper that hides the `Sendable` weirdness of `NWConnection` callbacks.
    private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, any Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation = continuation
        }

        func resumeSuccess(_ value: T) {
            consume()?.resume(returning: value)
        }

        func resumeFailure(_ error: any Error) {
            consume()?.resume(throwing: error)
        }

        private func consume() -> CheckedContinuation<T, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            let c = continuation
            continuation = nil
            return c
        }
    }

    public func connect() async throws -> SessionDescription {
        try await openTCP()
        startReceiveLoop()

        _ = try await sendRequest(method: "OPTIONS", uri: rtspURI)
        let describeResp = try await sendRequest(
            method: "DESCRIBE",
            uri: rtspURI,
            extraHeaders: ["Accept": "application/sdp"]
        )
        guard describeResp.statusCode == 200 else {
            throw RTSPError.status(describeResp.statusCode, reason: describeResp.reason)
        }
        // Some Reolink Home Hub channels return a Content-Base whose host is the
        // camera's INTERNAL ip (e.g. 172.16.x.x on the hub-camera link), which is
        // unreachable from the user's LAN. Only honor Content-Base if its host
        // matches the URL we used to connect — otherwise fall back to rtspURI.
        if let cbStr = describeResp.header("Content-Base") ?? describeResp.header("Content-Location"),
           let cbURL = URL(string: cbStr),
           let cbHost = cbURL.host,
           cbHost == config.url.host {
            self.contentBase = cbStr
        } else {
            self.contentBase = nil
            if let cb = describeResp.header("Content-Base") {
                log.debug("Ignoring Content-Base \(cb, privacy: .public) — host mismatch with \(self.config.url.host ?? "?", privacy: .public)")
            }
        }

        log.debug("DESCRIBE body (\(describeResp.body.count) bytes):\n\(describeResp.body, privacy: .public)")
        let parsed = SDPParser.parse(describeResp.body)
        self.sdp = parsed
        guard parsed.firstVideoTrack != nil else {
            let preview = String(describeResp.body.prefix(900))
            let firstLineBytes = describeResp.body.prefix(80).unicodeScalars.map { String(format: "%02X", $0.value) }.joined(separator: " ")
            let hasMVideo = describeResp.body.contains("m=video")
            let mediaKinds = parsed.media.map { $0.kind }.joined(separator: ",")
            throw RTSPError.protocolError(
                """
                No video track in SDP.
                len=\(describeResp.body.count) parsedMedia=[\(mediaKinds)] containsLiteralMVideo=\(hasMVideo)
                first80HEX: \(firstLineBytes)
                Body:
                \(preview)
                """
            )
        }
        return parsed
    }

    public func setupVideo(interleavedChannels: (rtp: UInt8, rtcp: UInt8) = (0, 1)) async throws {
        guard let video = sdp?.firstVideoTrack else { throw RTSPError.noVideoTrack }
        self.rtcpInterleavedChannel = interleavedChannels.rtcp
        let uri = trackURI(control: video.control)
        log.debug("SETUP uri=\(uri, privacy: .public)")
        let resp = try await sendRequest(
            method: "SETUP",
            uri: uri,
            extraHeaders: [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=\(interleavedChannels.rtp)-\(interleavedChannels.rtcp)"
            ]
        )
        log.debug("SETUP response status=\(resp.statusCode) session=\(resp.header("Session") ?? "(none)", privacy: .public)")
        guard resp.statusCode == 200 else { throw RTSPError.status(resp.statusCode, reason: resp.reason) }
        if let sess = resp.header("Session") {
            // `Session: 12345678;timeout=30` — parse both halves.
            let parts = sess.split(separator: ";")
            self.session = String(parts.first ?? Substring(sess))
            for part in parts.dropFirst() {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0].lowercased() == "timeout", let t = TimeInterval(kv[1]) {
                    self.sessionTimeoutSeconds = t
                }
            }
            log.debug("Session=\(self.session ?? "?", privacy: .public) timeout=\(self.sessionTimeoutSeconds)s")
        }
    }

    public func play() async throws -> AsyncStream<RTPChannelMessage> {
        let uri = aggregateURI
        log.debug("PLAY uri=\(uri, privacy: .public)")
        let resp = try await sendRequest(
            method: "PLAY",
            uri: uri,
            extraHeaders: ["Range": "npt=0.000-"]
        )
        log.debug("PLAY response status=\(resp.statusCode)")
        guard resp.statusCode == 200 else { throw RTSPError.status(resp.statusCode, reason: resp.reason) }

        // Unbounded buffer: dropping RTP fragments under load corrupts H.265
        // FU reassembly and makes the decoder lock up. Better to grow memory
        // briefly than to lose fragments.
        let (stream, continuation) = AsyncStream<RTPChannelMessage>.makeStream(bufferingPolicy: .unbounded)
        self.dataStream = continuation
        // Fire an immediate keepalive so the server sees activity right away,
        // then begin the periodic schedule.
        Task { [weak self] in await self?.sendKeepalive() }
        startKeepalive()
        startRTCPReports()
        return stream
    }

    /// Periodically transmit an RTCP Receiver Report. Servers use this as a
    /// signal that the receiver is alive and able to consume more RTP. Without
    /// it, Reolink (and many other RTSP servers) stop sending RTP after the
    /// outgoing buffer fills — typically a 5–10s window.
    private func startRTCPReports() {
        rtcpTask?.cancel()
        rtcpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.sendRTCPReceiverReport()
            }
        }
    }

    private func sendRTCPReceiverReport() async {
        // Build an RTCP Receiver Report with one report block. 32 bytes total.
        // Header (4): V=2, P=0, RC=1 = 0x81; PT=201 = 0xC9; Length = 7 (in 32-bit words, minus 1).
        // Sender SSRC (4): our SSRC.
        // Report Block (24): SSRC of source, fraction lost, cumulative lost,
        //   extended highest sequence number, jitter, LSR, DLSR.
        let senderSSRC = lastSenderSSRC
        guard senderSSRC != 0 else { return }

        var rr = Data(count: 32)
        rr[0] = 0x81                                 // V=2, P=0, RC=1
        rr[1] = 0xC9                                 // PT=201 (RR)
        rr[2] = 0x00
        rr[3] = 0x07                                 // length=7 → 32 bytes
        writeUInt32(ourRtcpSSRC, to: &rr, offset: 4)
        writeUInt32(senderSSRC, to: &rr, offset: 8)
        // fraction lost (1) + cumulative lost (3) = 4 bytes of zeros (no losses reported)
        rr[12] = 0; rr[13] = 0; rr[14] = 0; rr[15] = 0
        writeUInt32(UInt32(highestSeenSeq), to: &rr, offset: 16) // extended highest seq
        writeUInt32(0, to: &rr, offset: 20)          // jitter = 0
        writeUInt32(0, to: &rr, offset: 24)          // LSR = 0 (no SR yet seen)
        writeUInt32(0, to: &rr, offset: 28)          // DLSR = 0

        // Wrap in TCP-interleaved frame: '$' channel length payload.
        var frame = Data(capacity: 4 + rr.count)
        frame.append(0x24)
        frame.append(rtcpInterleavedChannel)
        frame.append(UInt8((rr.count >> 8) & 0xFF))
        frame.append(UInt8(rr.count & 0xFF))
        frame.append(rr)

        guard connection != nil, rtcpTask?.isCancelled == false else { return }
        do {
            try await sendData(frame)
        } catch RTSPError.cancelled {
            // Expected during teardown.
        } catch {
            log.debug("RTCP RR send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        data[offset]     = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    /// Sends an RTSP OPTIONS with the active Session header every half-timeout
    /// to prevent the server from tearing the stream down.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        // Use 1/3 of the session timeout so we always have at least 2 successful
        // round-trips before the server would consider the session stale.
        let interval = max(3, sessionTimeoutSeconds / 3)
        log.debug("Starting RTSP keepalive every \(interval, format: .fixed(precision: 1))s")
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.sendKeepalive()
            }
        }
    }

    private func sendKeepalive() async {
        // Skip if the connection is already torn down — keepalive losing the
        // race against close() is expected, not an error worth logging at
        // .error level.
        guard connection != nil, keepaliveTask?.isCancelled == false else { return }
        do {
            _ = try await sendRequest(method: "OPTIONS", uri: aggregateURI)
        } catch RTSPError.cancelled {
            // Connection closed mid-request — silent.
        } catch {
            log.debug("Keepalive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func teardown() async {
        if connection != nil {
            _ = try? await sendRequest(method: "TEARDOWN", uri: aggregateURI)
        }
        close()
    }

    public func close() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        rtcpTask?.cancel()
        rtcpTask = nil
        dataStream?.yield(.closed)
        dataStream?.finish()
        dataStream = nil
        connection?.cancel()
        connection = nil
        if let pending = pendingResponse {
            pending.resume(throwing: RTSPError.cancelled)
            pendingResponse = nil
        }
    }

    // MARK: - private

    /// The URI we put in the RTSP request line. Reolink (and most RTSP servers)
    /// reject URIs that embed `user:pass@` — credentials must go through the
    /// `Authorization: Digest` header instead. Build a clean version once.
    private var rtspURI: String { Self.makeCleanURI(config.url) }

    static func makeCleanURI(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// The URI used for aggregate-level requests (PLAY, PAUSE, TEARDOWN) and as
    /// the base for track-level URIs (SETUP). Uses `Content-Base` from the
    /// DESCRIBE response if it matches the connected host; otherwise falls back
    /// to the original RTSP URL. Reolink's hub returns a canonicalized
    /// `Content-Base` and won't start streaming if PLAY uses a different URI
    /// than SETUP — so unify all requests on this value.
    private var aggregateURI: String { contentBase ?? rtspURI }

    private func trackURI(control: String?) -> String {
        let base = aggregateURI
        guard let control, !control.isEmpty else { return base }
        if control == "*" { return base }
        if control.hasPrefix("rtsp://") { return control }
        if base.hasSuffix("/") { return base + control }
        return base + "/" + control
    }

    private func openTCP() async throws {
        let host = NWEndpoint.Host(config.url.host ?? "")
        let port = NWEndpoint.Port(rawValue: UInt16(config.url.port ?? 554)) ?? 554
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn

        // Use an isolated continuation to avoid Sendable closure capture issues.
        let connectionRef = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            // Box the continuation so the @Sendable handler only sees a class reference.
            let box = ContinuationBox(cont)
            connectionRef.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resumeSuccess(())
                case .failed(let err):
                    box.resumeFailure(RTSPError.connectionFailed(err))
                case .cancelled:
                    box.resumeFailure(RTSPError.cancelled)
                default:
                    break
                }
            }
            connectionRef.start(queue: .global(qos: .userInitiated))
        }
        // Replace the handler with a no-op after we're ready, so subsequent state changes
        // don't try to resume an already-consumed continuation.
        conn.stateUpdateHandler = { _ in }
    }

    private func sendRequest(
        method: String,
        uri: String,
        extraHeaders: [String: String] = [:]
    ) async throws -> RTSPResponse {
        cseq += 1
        // If we already have a challenge, attach a fresh Authorization computed from
        // it for THIS request's method+uri+nc. Otherwise send unauthenticated; the
        // server will challenge us with 401.
        let attempt1Auth = currentAuthorization(for: method, uri: uri)
        let firstAttempt = try await rawSend(method: method, uri: uri, cseq: cseq, authorization: attempt1Auth, extraHeaders: extraHeaders)
        if firstAttempt.statusCode == 401, let www = firstAttempt.header("WWW-Authenticate"),
           let challenge = DigestChallenge(headerValue: www) {
            // Cache (or refresh) the challenge for future requests.
            self.authChallenge = challenge
            cseq += 1
            let auth = currentAuthorization(for: method, uri: uri)
            let retry = try await rawSend(method: method, uri: uri, cseq: cseq, authorization: auth, extraHeaders: extraHeaders)
            if retry.statusCode == 401 { throw RTSPError.authenticationFailed }
            return retry
        }
        return firstAttempt
    }

    /// Compute a fresh `Authorization: Digest …` value for this request, if we
    /// have a cached challenge. Returns nil before the first 401.
    private func currentAuthorization(for method: String, uri: String) -> String? {
        guard let challenge = authChallenge else { return nil }
        ncCounter += 1
        let nc = String(format: "%08x", ncCounter)
        return DigestAuth.response(
            username: config.username,
            password: config.password,
            method: method,
            uri: uri,
            challenge: challenge,
            cnonce: sessionCnonce,
            nc: nc
        )
    }

    private func rawSend(
        method: String,
        uri: String,
        cseq: Int,
        authorization: String?,
        extraHeaders: [String: String]
    ) async throws -> RTSPResponse {
        var lines: [String] = [
            "\(method) \(uri) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: \(config.userAgent)"
        ]
        if let session { lines.append("Session: \(session)") }
        if let authorization { lines.append("Authorization: \(authorization)") }
        for (k, v) in extraHeaders { lines.append("\(k): \(v)") }
        lines.append("\r\n")

        let request = lines.joined(separator: "\r\n")
        try await sendData(Data(request.utf8))
        return try await awaitResponse()
    }

    private func sendData(_ data: Data) async throws {
        guard let connection else { throw RTSPError.cancelled }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { box.resumeFailure(RTSPError.connectionFailed(error)) }
                else { box.resumeSuccess(()) }
            })
        }
    }

    private func awaitResponse(timeout: TimeInterval = 8) async throws -> RTSPResponse {
        // Schedule a timeout that resumes the continuation with an error if the
        // server is unresponsive. The actor serializes resume/clear so we won't
        // double-resume.
        let timeoutTask = Task<Void, Never> { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if Task.isCancelled { return }
            await self?.failPendingResponse(with: RTSPError.protocolError("response timed out"))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTSPResponse, any Error>) in
            self.pendingResponse = cont
            tryDeliverPendingResponse()
        }
    }

    private func failPendingResponse(with error: any Error) {
        guard let cont = pendingResponse else { return }
        pendingResponse = nil
        cont.resume(throwing: error)
    }

    private func tryDeliverPendingResponse() {
        guard let cont = pendingResponse else { return }
        // Consume any pending data first.
        consumeBuffer()
        // After consuming, see if we can parse a response.
        if let (resp, consumed) = RTSPMessageParser.parse(readBuffer), consumed <= readBuffer.count {
            readBuffer.removeFirst(consumed)
            pendingResponse = nil
            cont.resume(returning: resp)
        }
    }

    private func startReceiveLoop() {
        guard !receiveLoopStarted, let connection else { return }
        receiveLoopStarted = true
        scheduleReceive(connection: connection)
    }

    private func scheduleReceive(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceived(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            readBuffer.append(data)
            // Drain the buffer until no further progress can be made. A TCP
            // chunk may contain a text response followed by interleaved RTP, or
            // interleaved RTP followed by more text — keep alternating until
            // both `consumeBuffer` and `tryDeliverPendingResponse` are idle.
            var lastSize = -1
            while readBuffer.count != lastSize {
                lastSize = readBuffer.count
                consumeBuffer()
                tryDeliverPendingResponse()
            }
        }
        if isComplete || error != nil {
            close()
            return
        }
        if let connection { scheduleReceive(connection: connection) }
    }

    /// Drain interleaved RTP/RTCP packets from the buffer until we hit either
    /// the end of the buffer or text data (an RTSP response).
    private func consumeBuffer() {
        while !readBuffer.isEmpty {
            if readBuffer[readBuffer.startIndex] != 0x24 { // '$'
                // RTSP text response — leave it for the message parser.
                return
            }
            guard readBuffer.count >= 4 else { return }
            let channel = readBuffer[readBuffer.startIndex + 1]
            let length = Int(UInt16(readBuffer[readBuffer.startIndex + 2]) << 8
                | UInt16(readBuffer[readBuffer.startIndex + 3]))
            guard readBuffer.count >= 4 + length else { return }
            let payload = readBuffer.subdata(in: (readBuffer.startIndex + 4)..<(readBuffer.startIndex + 4 + length))
            readBuffer.removeFirst(4 + length)

            if channel % 2 == 0 {
                if let pkt = RTPPacket(raw: payload) {
                    rtpPacketCount += 1
                    lastSenderSSRC = pkt.ssrc
                    highestSeenSeq = pkt.sequenceNumber
                    if rtpPacketCount == 1 {
                        log.debug("First RTP packet: channel=\(channel) seq=\(pkt.sequenceNumber) ts=\(pkt.timestamp) ssrc=\(pkt.ssrc) payloadBytes=\(pkt.payload.count)")
                    }
                    dataStream?.yield(.rtp(channel: channel, packet: pkt))
                }
            } else {
                dataStream?.yield(.rtcp(channel: channel, data: payload))
            }
        }
    }

    private var rtpPacketCount: Int = 0
}
