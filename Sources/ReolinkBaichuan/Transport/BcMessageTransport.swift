import Foundation

/// Abstract transport surface for Baichuan messages. Decouples
/// `BaichuanClient`'s control-plane state machines (login,
/// events, battery, talkback, …) from the wire-level pipe that
/// actually moves bytes.
///
/// ## Why this exists
///
/// Reolens started life as a strict LAN client: a single
/// `NWConnection` over TCP/9000, owned by `BaichuanClient`,
/// carrying Baichuan messages directly. Remote connectivity
/// (0.7.0) introduces a second pipe — BcUdp Data packets over a
/// hole-punched UDP socket, brokered through Reolink's discovery
/// servers — that ferries the same `BcMessage` payloads. Both
/// pipes need to expose the same surface so the control plane
/// doesn't care which one it's standing on.
///
/// ## Conformance contract
///
/// - **Statefulness.** A conformer represents one connection to
///   one camera. Implementations may not hold per-app shared
///   state; the lifecycle is bounded by `connect()` … `close()`.
/// - **Encryption is the transport's problem.** The negotiated
///   cipher (BCEncrypt → AES-128-CFB after login) is stored on
///   the transport because both the send path (encode) and the
///   receive loop (decode) need it. Higher layers consult
///   `currentCipher()` / `setCipher(_:)` during the login
///   handshake; afterwards they should not touch the cipher.
/// - **Message-num counter is the transport's problem.** Each
///   conformer maintains its own 16-bit rolling counter and
///   hands out monotonically-increasing values from
///   `nextMessageNumber()`. The counter is per-connection, not
///   per-camera — reconnecting yields a fresh sequence.
/// - **`sendAndAwait` is request/response only.** It registers a
///   reply slot keyed by the message's `msg_num` before writing
///   to the wire, so a reply that arrives before the caller's
///   continuation suspends is buffered. Implementations MUST NOT
///   route replies to `subscribe()` once a `sendAndAwait` is in
///   flight for that `msg_num`.
/// - **`subscribe()` carries server-initiated pushes only.**
///   Motion events, battery state notifications, etc. The
///   stream finishes when the connection closes for any reason.
/// - **Cancellation propagates.** If the task awaiting
///   `sendAndAwait` is cancelled, the transport is free to
///   abandon the reply slot. The wire send may or may not have
///   reached the camera; the caller is responsible for any
///   recovery.
///
/// ## What this protocol does NOT cover
///
/// - **Reconnection.** A transport closes on connection drop;
///   the caller (`CameraSession`) decides whether and how to
///   build a fresh one. Mixing reconnect logic into the
///   transport would couple it to the reachability state
///   machine.
/// - **Authentication.** Login is a Baichuan-level state
///   machine that lives in `BaichuanLogin` and runs *on top of*
///   the transport. The transport sees the login messages as
///   ordinary `sendAndAwait` calls.
/// - **Channel multiplexing.** Some Baichuan command IDs carry
///   a `channel_id` for per-camera-on-NVR routing. That field
///   lives in `BcHeader` and is the caller's concern, not the
///   transport's.
public protocol BcMessageTransport: Sendable {
    /// Bring the transport up. For LAN this opens TCP/9000;
    /// for remote this drives discovery + hole punching to
    /// completion. Throws if the connection cannot be
    /// established. Idempotent: calling `connect()` twice is a
    /// no-op when the transport is already up.
    func connect() async throws

    /// Tear down the transport. Closes the underlying socket(s)
    /// and finishes any outstanding `subscribe()` streams and
    /// pending `sendAndAwait` continuations (the latter throw
    /// `BaichuanError.cancelled`). Idempotent.
    func close() async

    /// Send `message` and await the reply matching its
    /// `msg_num`. `timeout` is wall-clock from the start of the
    /// call; if no reply arrives in time, throws
    /// `BaichuanError.timedOut(stage:)`. `stage` is a diagnostic
    /// label that appears in logs and timeout errors — pick
    /// something a developer reading a crash log would
    /// recognise (e.g. "legacy-login", "fetch-uid",
    /// "battery-info").
    func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval,
        stage: String
    ) async throws -> BcMessage

    /// Subscribe to server-initiated messages (events, status
    /// pushes, anything the camera sends without a prior
    /// request from this client). The returned stream finishes
    /// when the transport closes. Multiple subscribers are
    /// allowed and each receives every message; the transport
    /// fan-outs internally.
    func subscribe() -> AsyncStream<BcMessage>

    /// Allocate the next 16-bit message-num value for this
    /// transport. Wraps at `UInt16.max`. Callers stamp the
    /// returned value into `BcHeader.msgNum` before calling
    /// `sendAndAwait`.
    func nextMessageNumber() async -> UInt16

    /// Current negotiated cipher. Read by the login state
    /// machine to decide whether AES is in effect.
    func currentCipher() async -> BcCipher

    /// Install a new cipher. Used exactly once per connection,
    /// during the login upgrade from BCEncrypt to AES. Calling
    /// this after login is a programmer error — the camera
    /// won't decrypt messages with a re-keyed AES.
    func setCipher(_ new: BcCipher) async
}
