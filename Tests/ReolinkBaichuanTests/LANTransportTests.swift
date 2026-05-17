import Testing
import Foundation
import Network
import Darwin
@testable import ReolinkBaichuan

/// End-to-end tests for `LANTransport` that round-trip a real
/// `BcMessage` through a real `NWConnection` against a loopback
/// `NWListener`. These aren't unit tests in the strict sense —
/// they hit `Network.framework` — but they're hermetic (no
/// external network), fast (<200 ms each), and deterministic
/// (Swift Testing + NWListener give us a stable seam).
///
/// What they validate:
/// - `connect()` completes when the TCP socket reaches `.ready`.
/// - `sendAndAwait` writes a Baichuan-framed message and returns
///   the first reply matching its `msg_num`.
/// - `subscribe()` delivers unsolicited messages (no matching
///   `msg_num`) to all subscribers.
/// - `sendAndAwait` honours its timeout when no reply lands.
/// - `nextMessageNumber()` is a monotonic per-transport counter.
/// - `setCipher` / `currentCipher` round-trip.
///
/// What they intentionally don't validate:
/// - AES encryption negotiation (that's `BaichuanLogin`'s job,
///   not the transport's — covered by the existing
///   `BaichuanLoginTests`).
/// - Cancellation behaviour mid-handshake (would require
///   exposing actor internals; deferred to the on-device
///   manual test in Phase 3c).
@Suite("LANTransport — loopback round-trips")
struct LANTransportTests {

    @Test("connect + sendAndAwait round-trips a Baichuan message")
    func sendAndAwaitRoundTrip() async throws {
        let peer = try await LoopbackPeer.start()
        defer { peer.stop() }

        let transport = LANTransport(credentials: peer.credentials)
        try await transport.connect()
        defer { Task { await transport.close() } }

        let msgNum = await transport.nextMessageNumber()
        let request = makeRequest(msgID: 80, msgNum: msgNum)

        // Have the loopback peer echo back the same msgNum with
        // a 200 response code as soon as it receives any bytes.
        peer.replyToFirstRequest(msgNum: msgNum, responseCode: 200)

        let reply = try await transport.sendAndAwait(
            request,
            timeout: 2,
            stage: "test-fetch-version"
        )
        #expect(reply.header.msgNum == msgNum)
        #expect(reply.header.responseCode == 200)
        #expect(reply.header.msgID == 80)
    }

    @Test("subscribe receives unsolicited messages")
    func subscribeReceivesUnsolicited() async throws {
        let peer = try await LoopbackPeer.start()
        defer { peer.stop() }

        let transport = LANTransport(credentials: peer.credentials)
        try await transport.connect()
        defer { Task { await transport.close() } }

        let stream = await transport.subscribe()

        // Push a server-initiated message with a msgNum the
        // client never sent (so no reply slot matches).
        peer.sendUnsolicited(msgID: 33, msgNum: 0xBEEF)

        // Race the first stream element against a wall-clock
        // timeout via two independent unstructured tasks. The
        // first to finish wins; the loser is cancelled.
        let received = await firstMessage(from: stream, timeout: .seconds(2))
        let msg = try #require(received)
        #expect(msg.header.msgID == 33)
        #expect(msg.header.msgNum == 0xBEEF)
    }

    @Test("sendAndAwait times out when no reply arrives")
    func sendAndAwaitTimesOut() async throws {
        let peer = try await LoopbackPeer.start()
        defer { peer.stop() }

        let transport = LANTransport(credentials: peer.credentials)
        try await transport.connect()
        defer { Task { await transport.close() } }

        let msgNum = await transport.nextMessageNumber()
        let request = makeRequest(msgID: 80, msgNum: msgNum)
        // Peer is silent — no reply slot is ever yielded.

        await #expect(throws: BaichuanError.self) {
            _ = try await transport.sendAndAwait(
                request,
                timeout: 0.3,
                stage: "test-timeout"
            )
        }
    }

    @Test("nextMessageNumber returns a monotonic counter")
    func messageNumberMonotonic() async {
        let transport = LANTransport(
            credentials: BaichuanCredentials(
                host: "127.0.0.1",
                port: 9000,
                username: "x",
                password: "x"
            )
        )
        let a = await transport.nextMessageNumber()
        let b = await transport.nextMessageNumber()
        let c = await transport.nextMessageNumber()
        #expect(a == 0)
        #expect(b == 1)
        #expect(c == 2)
    }

    @Test("setCipher updates currentCipher")
    func cipherTransition() async {
        let transport = LANTransport(
            credentials: BaichuanCredentials(
                host: "127.0.0.1",
                port: 9000,
                username: "x",
                password: "x"
            )
        )
        let initial = await transport.currentCipher()
        if case .unencrypted = initial {} else {
            Issue.record("Expected initial cipher to be unencrypted")
        }
        await transport.setCipher(.bcEncrypt)
        let after = await transport.currentCipher()
        if case .bcEncrypt = after {} else {
            Issue.record("Expected cipher to be bcEncrypt after setCipher")
        }
    }

    // MARK: - Helpers

    private func firstMessage(from stream: AsyncStream<BcMessage>, timeout: Duration) async -> BcMessage? {
        await withTaskGroup(of: BcMessage?.self) { group in
            group.addTask {
                for await msg in stream { return msg }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    private func makeRequest(msgID: UInt32, msgNum: UInt16) -> BcMessage {
        let header = BcHeader(
            msgID: msgID,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        return BcMessage(header: header)
    }
}

// MARK: - Loopback peer

/// Minimal POSIX-sockets TCP peer bound to 127.0.0.1. Avoids
/// `NWListener` because it surfaces EINVAL inside the
/// `swift test` runner on macOS 15+. The fixture accepts one
/// connection, reads anything the client sends, and on the
/// first chunk of bytes pushes a configured reply (and/or a
/// canned unsolicited message) framed as a Baichuan
/// `unencrypted` `BcMessage`.
private final class LoopbackPeer: @unchecked Sendable {
    let credentials: BaichuanCredentials
    private let listenFD: Int32
    private var acceptedFD: Int32 = -1
    private let lock = NSLock()
    private var pendingReply: (msgNum: UInt16, responseCode: UInt16)?
    private var pendingUnsolicited: (msgID: UInt32, msgNum: UInt16)?
    private var stopped = false
    private let queue = DispatchQueue(label: "LoopbackPeer.accept", qos: .userInitiated)

    static func start() async throws -> LoopbackPeer {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS assigns
        // INADDR_LOOPBACK = 0x7F000001 in host byte order;
        // `.bigEndian` converts to the network byte order that
        // `sin_addr.s_addr` expects.
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        let port = UInt16(bigEndian: bound.sin_port)
        guard Darwin.listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        let peer = LoopbackPeer(listenFD: fd, port: port)
        peer.startAccepting()
        return peer
    }

    private init(listenFD: Int32, port: UInt16) {
        self.listenFD = listenFD
        self.credentials = BaichuanCredentials(
            host: "127.0.0.1",
            port: port,
            username: "x",
            password: "x"
        )
    }

    private func startAccepting() {
        queue.async { [weak self] in
            guard let self else { return }
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = Darwin.accept(self.listenFD, &clientAddr, &clientLen)
            guard clientFD >= 0 else { return }
            self.lock.lock()
            self.acceptedFD = clientFD
            let queuedUnsolicited = self.pendingUnsolicited
            self.lock.unlock()
            // Deliver a queued unsolicited push immediately, if
            // the test scheduled one before accept landed.
            if let u = queuedUnsolicited {
                self.lock.lock()
                self.pendingUnsolicited = nil
                self.lock.unlock()
                self.send(msgID: u.msgID, msgNum: u.msgNum, responseCode: 0, on: clientFD)
            }
            self.readLoop(clientFD: clientFD)
        }
    }

    private func readLoop(clientFD: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.recv(clientFD, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { return }
            self.handleIncoming(clientFD: clientFD)
        }
    }

    private func handleIncoming(clientFD: Int32) {
        lock.lock()
        let reply = pendingReply
        pendingReply = nil
        lock.unlock()
        if let reply {
            send(msgID: 80, msgNum: reply.msgNum, responseCode: reply.responseCode, on: clientFD)
        }
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let accepted = acceptedFD
        lock.unlock()
        if accepted >= 0 { Darwin.close(accepted) }
        Darwin.close(listenFD)
    }

    func replyToFirstRequest(msgNum: UInt16, responseCode: UInt16) {
        lock.lock()
        pendingReply = (msgNum, responseCode)
        lock.unlock()
    }

    func sendUnsolicited(msgID: UInt32, msgNum: UInt16) {
        lock.lock()
        let accepted = acceptedFD
        if accepted < 0 {
            pendingUnsolicited = (msgID, msgNum)
            lock.unlock()
            return
        }
        lock.unlock()
        send(msgID: msgID, msgNum: msgNum, responseCode: 0, on: accepted)
    }

    private func send(msgID: UInt32, msgNum: UInt16, responseCode: UInt16, on clientFD: Int32) {
        let header = BcHeader(
            msgID: msgID,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: msgNum,
            responseCode: responseCode,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let msg = BcMessage(header: header)
        let bytes = msg.encode(cipher: .unencrypted)
        _ = bytes.withUnsafeBytes { ptr in
            Darwin.send(clientFD, ptr.baseAddress, ptr.count, 0)
        }
    }
}
