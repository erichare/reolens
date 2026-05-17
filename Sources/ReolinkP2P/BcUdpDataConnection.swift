import Foundation
import ReolinkBcUdp

/// Stateful UDP channel that carries BcUdp packets in both
/// directions after the hole-punch handshake completes. Distinct
/// from `BcUdpTransport` — that's a one-shot request/response
/// primitive for the discovery phase; `BcUdpDataConnection` is a
/// long-lived bidirectional pipe over a single 5-tuple.
///
/// ## Why this is a separate protocol
///
/// `RemoteTransport`'s state machine has two distinct surfaces:
/// the *discovery* call (one-shot, lives on
/// `BcUdpTransport.sendAndAwaitReply`) and the *data path*
/// (long-lived, multi-direction, lives on
/// `BcUdpDataConnection`). Splitting them keeps the discovery
/// surface narrow and lets tests inject a scripted peer that
/// drives the post-punch state machine without spinning up an
/// `NWConnection`.
///
/// ## Conformance contract
///
/// - **Connect is a no-op or a punch.** The contract is that
///   after `connect()` returns, the channel is usable. Concrete
///   implementations may drive the hole-punch state machine
///   from `connect()`, or they may accept a pre-established
///   socket and treat `connect()` as a no-op (test stubs do
///   this).
/// - **Send is best-effort.** UDP loses packets; the caller
///   layers retransmit/ack on top via `BcUdpAckPacket`. The
///   transport doesn't retry internally.
/// - **Receive is a fan-out.** Multiple subscribers each get
///   every inbound packet. The stream finishes when `close()`
///   is called.
/// - **Close is idempotent.**
public protocol BcUdpDataConnection: Sendable {
    func connect() async throws
    func send(_ packet: BcUdpPacket) async throws
    func subscribe() async -> AsyncStream<BcUdpPacket>
    func close() async
}

/// Errors specific to the remote-transport state machine.
/// Separate from `BaichuanError` because they describe
/// pre-control-plane failures (discovery, hole-punch, relay)
/// rather than Baichuan-level issues.
public enum RemoteTransportError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// No usable candidate returned by discovery. The supplied
    /// UID may be wrong, the camera may be offline, or every
    /// discovery server in the pool may have failed.
    case noCandidates(uid: String)

    /// Hole-punch probes were sent to every candidate but none
    /// responded within the deadline, and the relay fallback
    /// also failed. The caller should treat this the same as
    /// "camera offline" for the user-visible state.
    case holePunchExhausted(uid: String, deadline: Duration)

    /// The concrete remote transport hasn't been wired to a
    /// real UDP channel yet. Returned by the skeleton built in
    /// Phase 3d.1; cleared once Phase 3d.2 lands the
    /// `NWConnectionBcUdpDataConnection` with tcpdump-validated
    /// magic constants.
    case notYetImplemented(detail: String)

    public var description: String {
        switch self {
        case .noCandidates(let uid):
            "Discovery returned no usable candidates for UID \(uid)"
        case .holePunchExhausted(let uid, let deadline):
            "Hole-punch exhausted for UID \(uid) within \(deadline)"
        case .notYetImplemented(let detail):
            "Remote transport not yet implemented: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
