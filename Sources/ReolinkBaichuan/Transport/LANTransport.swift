import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "lan-transport")

/// `BcMessageTransport` conformance for the LAN path: a single
/// `NWConnection` over TCP/9000 carrying length-prefixed Baichuan
/// messages.
///
/// This is `BaichuanClient`'s historical inner working lifted into
/// a separate actor. In Phase 3b it is added alongside the
/// existing `BaichuanClient` without changing it; Phase 3c will
/// hollow out `BaichuanClient` so it delegates to `any
/// BcMessageTransport` and the LAN path routes through this type.
///
/// ## Behavioural parity
///
/// Every observable detail of the existing `BaichuanClient`
/// connection lifecycle is preserved here:
///
/// - The `NWConnection.stateUpdateHandler` is set *before*
///   `start(queue:)` so the first transition (typically `.ready`)
///   isn't missed.
/// - `replySlots[msgNum] = continuation` is established
///   *synchronously inside the actor* before `sendRaw` is
///   awaited, eliminating the race where a fast reply would
///   otherwise fall through to `subscribe()`.
/// - The receive loop calls `connection.receive` with the same
///   `(minimumIncompleteLength: 1, maximumLength: 64*1024)`
///   bounds and frame-decodes as bytes arrive — partial frames
///   stay in `readBuffer` until the next chunk lands.
/// - `close()` is idempotent and finishes both reply-slot and
///   subscriber continuations, the latter so any consumer's
///   `for await` loop exits cleanly.
///
/// Keeping these invariants byte-identical to today's
/// `BaichuanClient` is the Phase 3 merge gate.
public actor LANTransport: BcMessageTransport {

    public let credentials: BaichuanCredentials
    private var connection: NWConnection?
    private var cipher: BcCipher = .unencrypted
    private var nextMsgNum: UInt16 = 0
    private var readBuffer: Data = Data()
    private var replySlots: [UInt16: AsyncStream<BcMessage>.Continuation] = [:]
    private var unsolicitedContinuations: [UUID: AsyncStream<BcMessage>.Continuation] = [:]
    private var receiveLoopStarted = false
    private var isClosed = false
    private var totalBytesReceived = 0

    public init(credentials: BaichuanCredentials) {
        self.credentials = credentials
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let host = NWEndpoint.Host(credentials.host)
        let port = NWEndpoint.Port(rawValue: credentials.port) ?? .init(integerLiteral: 9000)
        log.info("Connecting to \(self.credentials.host, privacy: .private):\(self.credentials.port)")
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.success(())
                case .failed(let err): box.failure(BaichuanError.connectionFailed("\(err)"))
                case .cancelled: box.failure(BaichuanError.cancelled)
                case .waiting(let err):
                    box.failure(BaichuanError.connectionFailed("waiting: \(err)"))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        conn.stateUpdateHandler = { _ in }
        log.info("TCP connection ready, starting receive loop")
        startReceiveLoop()
    }

    public func subscribe() -> AsyncStream<BcMessage> {
        let (stream, continuation) = AsyncStream<BcMessage>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        unsolicitedContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    private func removeSubscriber(id: UUID) {
        unsolicitedContinuations.removeValue(forKey: id)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection?.cancel()
        connection = nil
        for (_, cont) in replySlots {
            cont.finish()
        }
        replySlots.removeAll()
        for (_, cont) in unsolicitedContinuations {
            cont.finish()
        }
        unsolicitedContinuations.removeAll()
    }

    // MARK: - Send / await reply

    @discardableResult
    public func sendAndAwait(
        _ message: BcMessage,
        timeout: TimeInterval = 8,
        stage: String = "request"
    ) async throws -> BcMessage {
        let msgNum = message.header.msgNum
        let bytes = message.encode(cipher: cipher)
        guard let connection else { throw BaichuanError.connectionFailed("Not connected") }

        // Register the slot synchronously so any reply that
        // arrives during send is buffered.
        let (stream, continuation) = AsyncStream<BcMessage>.makeStream(bufferingPolicy: .bufferingOldest(1))
        replySlots[msgNum] = continuation
        defer {
            replySlots.removeValue(forKey: msgNum)
            continuation.finish()
        }

        log.debug("TX msgNum=\(msgNum) stage=\(stage, privacy: .public) bytes=\(bytes.count) hex=\(bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .private)")
        do {
            try await sendRaw(bytes, via: connection)
            log.info("TX done msgNum=\(msgNum)")
        } catch {
            log.error("TX failed msgNum=\(msgNum): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // Race the reply against a timeout.
        let result = await withTaskGroup(of: BcMessage?.self) { group in
            group.addTask {
                var iter = stream.makeAsyncIterator()
                return await iter.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let msg = result else {
            throw BaichuanError.timedOut(stage: stage)
        }
        return msg
    }

    public func nextMessageNumber() -> UInt16 {
        let n = nextMsgNum
        nextMsgNum &+= 1
        return n
    }

    public func currentCipher() -> BcCipher { cipher }
    public func setCipher(_ new: BcCipher) { self.cipher = new }

    private func sendRaw(_ bytes: Data, via connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(cont)
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { box.failure(BaichuanError.connectionFailed("send: \(error)")) }
                else { box.success(()) }
            })
        }
    }

    // MARK: - Receive

    private func startReceiveLoop() {
        guard !receiveLoopStarted, let connection else { return }
        receiveLoopStarted = true
        scheduleReceive(on: connection)
    }

    private func scheduleReceive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceived(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            totalBytesReceived += data.count
            if totalBytesReceived <= 1024 {
                let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
                log.debug("RX \(data.count) bytes (total=\(self.totalBytesReceived)): \(hex, privacy: .private)\(data.count > 40 ? "..." : "")")
            }
            readBuffer.append(data)
            while !readBuffer.isEmpty {
                guard let (msg, consumed) = BcMessage.decode(from: readBuffer, cipher: cipher) else {
                    log.info("Partial frame, waiting for more bytes (have \(self.readBuffer.count))")
                    break
                }
                log.info("Decoded msgID=\(msg.header.msgID) class=0x\(String(msg.header.msgClass, radix: 16)) msgNum=\(msg.header.msgNum) code=\(msg.header.responseCode) bodyLen=\(msg.header.bodyLength)")
                readBuffer.removeFirst(consumed)
                dispatch(msg)
            }
        }
        if let error {
            log.warning("Receive error: \(error.localizedDescription, privacy: .public)")
        }
        if isComplete {
            log.warning("TCP receive reports complete (peer closed)")
        }
        if isComplete || error != nil {
            close()
            return
        }
        if let connection { scheduleReceive(on: connection) }
    }

    private func dispatch(_ msg: BcMessage) {
        if let slot = replySlots[msg.header.msgNum] {
            slot.yield(msg)
            return
        }
        for (_, sub) in unsolicitedContinuations {
            sub.yield(msg)
        }
    }

    // MARK: - Sendable continuation box

    private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, any Error>?
        private let lock = NSLock()
        init(_ cont: CheckedContinuation<T, any Error>) { self.continuation = cont }
        func success(_ value: T) { take()?.resume(returning: value) }
        func failure(_ error: any Error) { take()?.resume(throwing: error) }
        private func take() -> CheckedContinuation<T, any Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = continuation; continuation = nil; return c
        }
    }
}
