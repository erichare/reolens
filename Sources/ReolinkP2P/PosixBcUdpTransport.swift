import Foundation
import Darwin
import OSLog
import ReolinkBcUdp

private let log = Logger(subsystem: "com.reolens.p2p", category: "posix-transport")

/// `BcUdpTransport` backed by BSD sockets instead of
/// `Network.framework`'s `NWConnection`.
///
/// ## Why a POSIX path
///
/// On a 2026-05-16 real-device smoke test, every call through
/// `NWConnectionBcUdpTransport` failed with
/// `POSIXErrorCode(50): Network is down` after ~1 ms per
/// server — `NWConnection.start()` was transitioning straight
/// to `.waiting(ENETDOWN)` synchronously, without actually
/// attempting the send. Forcing IPv4 on the parameters didn't
/// help. The OS could clearly route UDP to the same host:port
/// (`nc -u -w 2 -z p2p.reolink.com 9999` succeeded), so the
/// problem was inside Network.framework — likely a stricter-
/// than-netcat reachability pre-check.
///
/// POSIX sockets don't have that pre-check. This implementation
/// resolves the hostname to an IPv4 address with `getaddrinfo`,
/// opens a UDP socket, sends one packet, and waits up to the
/// caller's deadline for a reply via `poll(2)`. Same behaviour
/// as `nc -u`, same reliability across networks.
///
/// ## Trade-offs
///
/// - Synchronous BSD socket calls; wrapped in
///   `withCheckedThrowingContinuation` on a background thread
///   so the actor never blocks.
/// - No IPv6 support today — `getaddrinfo` is configured for
///   AF_INET only. The wire capture work all happened over IPv4
///   so this isn't a real-world constraint, but if we ever need
///   IPv6 the hint family can change.
/// - One-shot per call, same semantics as
///   `NWConnectionBcUdpTransport` — discovery walks the server
///   pool with a fresh socket per attempt.
public struct PosixBcUdpTransport: BcUdpTransport {

    public init() {}

    /// When set, every outbound packet's bytes are printed to
    /// stdout before send and every received packet's bytes are
    /// printed after receive. Off by default; flipped on in
    /// diagnostic builds (e.g. `RemoteSmoke --verbose`) so
    /// development can compare our wire bytes against captured
    /// official-client traffic.
    public static nonisolated(unsafe) var verboseLogging: Bool = false

    public func sendAndAwaitReply(
        _ packet: BcUdpPacket,
        to host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> BcUdpPacket {
        let bytes = packet.encode()
        if Self.verboseLogging {
            print("[posix-udp] → \(host):\(port) (\(bytes.count) bytes)")
            print("[posix-udp]   \(Self.hexDump(bytes))")
        }
        let timeoutMillis = Self.millisFromDuration(timeout)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BcUdpPacket, any Error>) in
            // Hop to a background queue — POSIX recv blocks the
            // calling thread, so we can't use the actor's queue.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reply = try Self.sync_sendAndAwait(
                        bytes: bytes,
                        to: host,
                        port: port,
                        timeoutMillis: timeoutMillis
                    )
                    cont.resume(returning: reply)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous implementation

    private static func sync_sendAndAwait(
        bytes: Data,
        to host: String,
        port: UInt16,
        timeoutMillis: Int32
    ) throws -> BcUdpPacket {
        // 1. Resolve hostname to IPv4 via getaddrinfo.
        let address: sockaddr_in
        do {
            address = try resolveIPv4(host: host, port: port)
        } catch {
            throw BcUdpTransportError.unreachable(host: host, port: port, detail: "resolve: \(error)")
        }

        // 2. Create UDP socket.
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw BcUdpTransportError.unreachable(host: host, port: port, detail: "socket: errno \(errno)")
        }
        defer { Darwin.close(fd) }

        // 3. Send the packet.
        var addr = address
        let sendResult = bytes.withUnsafeBytes { ptr -> Int in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                    Darwin.sendto(
                        fd,
                        ptr.baseAddress,
                        bytes.count,
                        0,
                        sockAddrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sendResult == bytes.count else {
            throw BcUdpTransportError.unreachable(
                host: host,
                port: port,
                detail: "sendto returned \(sendResult), errno \(errno)"
            )
        }

        // 4. Wait for a reply within the deadline.
        var pfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = withUnsafeMutablePointer(to: &pfd) { ptr in
            Darwin.poll(ptr, 1, timeoutMillis)
        }
        if pollResult == 0 {
            throw BcUdpTransportError.timedOut(host: host, port: port)
        }
        if pollResult < 0 {
            throw BcUdpTransportError.unreachable(
                host: host,
                port: port,
                detail: "poll: errno \(errno)"
            )
        }

        // 5. Read the datagram.
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let received = buf.withUnsafeMutableBufferPointer { bufPtr -> Int in
            Darwin.recv(fd, bufPtr.baseAddress, bufPtr.count, 0)
        }
        guard received > 0 else {
            throw BcUdpTransportError.unreachable(
                host: host,
                port: port,
                detail: "recv returned \(received), errno \(errno)"
            )
        }

        // 6. Decode the BcUdp packet.
        let payload = Data(bytes: buf, count: received)
        if verboseLogging {
            print("[posix-udp] ← \(host):\(port) (\(payload.count) bytes)")
            print("[posix-udp]   \(hexDump(payload))")
        }
        guard let (packet, _) = BcUdpPacket.decode(from: payload) else {
            throw BcUdpTransportError.malformedReply(host: host, port: port)
        }
        return packet
    }

    /// One-line hex dump suitable for terminal output. Shows
    /// the first 96 bytes (enough for a Disc header + the
    /// first chunk of payload); longer packets get an ellipsis.
    private static func hexDump(_ data: Data) -> String {
        let preview = data.prefix(96)
        let hex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > 96 ? "\(hex) … (\(data.count) total)" : hex
    }

    /// Resolve a hostname to an IPv4 `sockaddr_in` via
    /// `getaddrinfo`. Throws on any failure (NXDOMAIN, no v4
    /// records, etc.).
    private static func resolveIPv4(host: String, port: UInt16) throws -> sockaddr_in {
        var hints = Darwin.addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        let err = Darwin.getaddrinfo(host, String(port), &hints, &result)
        guard err == 0, let result else {
            throw NSError(domain: "PosixBcUdpTransport", code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: String(cString: Darwin.gai_strerror(err))
            ])
        }
        defer { Darwin.freeaddrinfo(result) }
        guard result.pointee.ai_addrlen == socklen_t(MemoryLayout<sockaddr_in>.size) else {
            throw NSError(domain: "PosixBcUdpTransport", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected addrinfo size"
            ])
        }
        let sin = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee
        }
        return sin
    }

    /// Convert a Swift `Duration` to milliseconds suitable for
    /// `poll(2)`. `poll` takes Int32 milliseconds; we cap at
    /// Int32.max to avoid overflow (the practical max is
    /// roughly 24 days, which we'll never approach).
    private static func millisFromDuration(_ duration: Duration) -> Int32 {
        let components = duration.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        let millis = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
        if millis > Int64(Int32.max) {
            return Int32.max
        }
        if millis < 0 {
            return 0
        }
        return Int32(millis)
    }
}

