import Testing
import Foundation
import Network
import Darwin
import ReolinkBcUdp
@testable import ReolinkP2P

/// Loopback tests for `NWConnectionBcUdpDataConnection` using a
/// POSIX UDP socket as the peer (NWListener surfaces EINVAL
/// inside `swift test`, same constraint as
/// `LANTransportTests`). The data-connection's send/receive
/// paths drive real `NWConnection.udp` here, so the structural
/// shell is exercised end-to-end even though the on-device
/// hole-punch portion can't be unit-tested.
///
/// What's verified:
/// - `send(_:)` writes the encoded packet bytes to the wire.
/// - The receive loop decodes inbound bytes into `BcUdpPacket`
///   and fans out to subscribers.
/// - `close()` is idempotent and finishes the inbound stream.
///
/// What's still gated on a real device:
/// - The actual hole-punch probe wire format
///   (`NWConnectionBcUdpPunchEngine.probePayload` is currently
///   empty — Reolink may require a specific XML payload).
/// - Whether our self-minted `connectionID` is accepted by the
///   camera, or if the protocol requires a server-assigned
///   value.
@Suite("NWConnectionBcUdpDataConnection — UDP loopback")
struct NWConnectionBcUdpDataConnectionTests {

    @Test("send writes the BcUdp Disc bytes to the wire")
    func sendDiscWrite() async throws {
        let peer = try LoopbackUDPPeer.start()
        defer { peer.stop() }

        let nwConn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: peer.port)!,
            using: .udp
        )
        try await awaitReady(nwConn)
        let channel = NWConnectionBcUdpDataConnection(connection: nwConn)
        try await channel.connect()
        defer { Task { await channel.close() } }

        let packet = BcUdpPacket.disc(BcUdpDiscPacket(
            protocolFlag: 1,
            senderID: 0x1234_5678,
            requestToken: 0,
            payload: Data("hello".utf8)
        ))
        try await channel.send(packet)

        // Wait a short moment for the OS to land the datagram.
        try await Task.sleep(for: .milliseconds(50))
        let received = peer.popReceived()
        #expect(received.count == 1)
        let bytes = try #require(received.first)
        let (decoded, consumed) = try #require(BcUdpPacket.decode(from: bytes))
        #expect(consumed == bytes.count)
        guard case .disc(let disc) = decoded else {
            Issue.record("Expected .disc")
            return
        }
        #expect(disc.senderID == 0x1234_5678)
        #expect(disc.payload == Data("hello".utf8))
    }

    @Test("Inbound BcUdp packet bytes are decoded and fanned out to subscribers")
    func receiveDispatchesToSubscribers() async throws {
        let peer = try LoopbackUDPPeer.start()
        defer { peer.stop() }

        let nwConn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: peer.port)!,
            using: .udp
        )
        try await awaitReady(nwConn)
        let channel = NWConnectionBcUdpDataConnection(connection: nwConn)
        try await channel.connect()
        defer { Task { await channel.close() } }

        let stream = await channel.subscribe()

        // The peer needs to know who to reply to. Trigger the
        // peer to learn our address by sending it a probe.
        try await channel.send(.disc(BcUdpDiscPacket(
            protocolFlag: 1,
            senderID: 0xAAAA_BBBB,
            requestToken: 0,
            payload: Data()
        )))

        // Wait a moment for the peer to learn our address.
        try await Task.sleep(for: .milliseconds(30))

        // Now have the peer push back an Ack packet — a
        // server-initiated message from the channel's
        // perspective.
        let ackPacket = BcUdpPacket.ack(BcUdpAckPacket(
            connectionID: 0xDEAD_BEEF
        ))
        peer.sendToLastClient(ackPacket.encode())

        // Race the first stream element against a wall-clock
        // timeout.
        let received = await withTaskGroup(of: BcUdpPacket?.self) { group in
            group.addTask {
                for await p in stream { return p }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        let pkt = try #require(received)
        guard case .ack(let ack) = pkt else {
            Issue.record("Expected .ack")
            return
        }
        #expect(ack.connectionID == 0xDEAD_BEEF)
    }

    @Test("close is idempotent and finishes the inbound stream")
    func closeIdempotent() async throws {
        let peer = try LoopbackUDPPeer.start()
        defer { peer.stop() }

        let nwConn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: peer.port)!,
            using: .udp
        )
        try await awaitReady(nwConn)
        let channel = NWConnectionBcUdpDataConnection(connection: nwConn)
        try await channel.connect()
        await channel.close()
        await channel.close()

        await #expect(throws: BcUdpTransportError.self) {
            try await channel.send(.ack(BcUdpAckPacket(connectionID: 0)))
        }
    }

    // MARK: - Helpers

    private func awaitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.success(())
                case .failed(let err): box.failure(err)
                case .cancelled: box.failure(CocoaError(.userCancelled))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        conn.stateUpdateHandler = { _ in }
    }
}

// MARK: - Loopback UDP peer

/// Minimal POSIX-socket UDP listener bound to 127.0.0.1.
/// Records every received datagram and remembers the last
/// client address so the test can push replies back.
private final class LoopbackUDPPeer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32
    private let lock = NSLock()
    private var received: [Data] = []
    private var lastClient: sockaddr_in?
    private var stopped = false
    private let queue = DispatchQueue(label: "LoopbackUDPPeer", qos: .userInitiated)

    static func start() throws -> LoopbackUDPPeer {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        // INADDR_LOOPBACK = 0x7F000001 (host) → network order.
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno; Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard getResult == 0 else {
            let err = errno; Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        let port = UInt16(bigEndian: bound.sin_port)
        let peer = LoopbackUDPPeer(fd: fd, port: port)
        peer.startReceiveLoop()
        return peer
    }

    private init(fd: Int32, port: UInt16) {
        self.socketFD = fd
        self.port = port
    }

    private func startReceiveLoop() {
        queue.async { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { return }
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                            Darwin.recvfrom(self.socketFD, ptr.baseAddress, ptr.count, 0, addrPtr, &clientLen)
                        }
                    }
                }
                if n <= 0 { return }
                let received = Data(bytes: buf, count: n)
                self.lock.lock()
                self.received.append(received)
                self.lastClient = clientAddr
                self.lock.unlock()
            }
        }
    }

    func popReceived() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let out = received
        received.removeAll()
        return out
    }

    func sendToLastClient(_ bytes: Data) {
        lock.lock()
        guard var client = lastClient else { lock.unlock(); return }
        lock.unlock()
        _ = withUnsafePointer(to: &client) { clientPtr in
            clientPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                bytes.withUnsafeBytes { dataPtr in
                    Darwin.sendto(
                        socketFD,
                        dataPtr.baseAddress,
                        dataPtr.count,
                        0,
                        addrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        Darwin.close(socketFD)
    }
}

private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, any Error>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, any Error>) { self.continuation = cont }
    func success(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil
        c?.resume(returning: value)
    }
    func failure(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil
        c?.resume(throwing: error)
    }
}
