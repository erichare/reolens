import Foundation
import Observation
import ReolinkAPI
import ReolinkBaichuan
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "session")

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// AI/motion event received from the Baichuan push stream. Used to retro-tag
/// recordings whose time range overlaps the event time.
public struct TimestampedAIEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let channelID: Int
    public let kind: BaichuanEvent.Kind
    /// e.g. "people", "vehicle", "dog_cat" if `kind == .ai(...)`, else nil.
    public let aiTag: String?

    public init(id: UUID = UUID(), timestamp: Date, channelID: Int, kind: BaichuanEvent.Kind, aiTag: String?) {
        self.id = id
        self.timestamp = timestamp
        self.channelID = channelID
        self.kind = kind
        self.aiTag = aiTag
    }

    public var detectionType: DetectionType? {
        if let aiTag { return DetectionType.fromReolinkString(aiTag) }
        if case .motionStart = kind { return .motion }
        return nil
    }
}

@MainActor
@Observable
public final class CameraSession {
    public let entry: CameraEntry
    public let credentials: CameraCredentials
    public let client: CGIClient
    public let streamURLs: StreamURLs

    public var status: ConnectionStatus = .disconnected
    public var deviceInfo: DeviceInfo?
    public var channels: [ChannelStatus] = []
    public var motionState: [Int: Bool] = [:]
    public var aiTriggered: [Int: Bool] = [:]

    /// Rolling log of Baichuan-delivered AI events, newest first. Capped at
    /// `eventLogCapacity` entries per channel.
    public var aiEventLog: [TimestampedAIEvent] = []
    public static let eventLogCapacity = 500

    private var pollTask: Task<Void, Never>?
    private var baichuanTask: Task<Void, Never>?
    private var baichuanClient: BaichuanClient?

    public init(entry: CameraEntry, credentials: CameraCredentials) {
        self.entry = entry
        self.credentials = credentials
        self.client = CGIClient(credentials: credentials)
        self.streamURLs = StreamURLs(credentials: credentials)
    }

    public func connect() async {
        status = .connecting
        do {
            _ = try await client.login()
            let info = try await client.send(Commands.getDevInfo(), as: DeviceInfoEnvelope.self)
            deviceInfo = info.DevInfo

            if info.DevInfo.isNVR {
                let env = try await client.send(Commands.getChannelStatus(), as: ChannelStatusEnvelope.self)
                channels = env.status
            } else {
                channels = [ChannelStatus(channel: 0, name: info.DevInfo.name, online: 1, typeInfo: info.DevInfo.model, uid: nil, sleep: 0)]
            }
            status = .connected
            startEventPolling()
            startBaichuanEvents()
        } catch {
            status = .error("\(error)")
        }
    }

    public func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        baichuanTask?.cancel()
        baichuanTask = nil
        if let baichuanClient {
            await baichuanClient.close()
        }
        baichuanClient = nil
        await client.logout()
        status = .disconnected
    }

    /// Opens the proprietary Baichuan TCP connection on port 9000, logs in
    /// with the same credentials, and subscribes to live alarm-event pushes.
    /// AI events are appended to `aiEventLog` for the recordings view to
    /// match against by timestamp.
    private func startBaichuanEvents() {
        baichuanTask?.cancel()
        baichuanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let creds = BaichuanCredentials(
                host: self.credentials.host,
                username: self.credentials.username,
                password: self.credentials.password
            )
            let client = BaichuanClient(credentials: creds)
            self.baichuanClient = client
            do {
                try await client.connect()
                let deviceName = try await client.login()
                log.info("Baichuan login OK device=\(deviceName, privacy: .public)")
                let events = try await client.subscribeToAlarmEvents()
                for await event in events {
                    self.recordAIEvent(event)
                }
            } catch {
                log.warning("Baichuan task ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func recordAIEvent(_ event: BaichuanEvent) {
        let aiTag: String? = {
            if case let .ai(tag) = event.kind { return tag }
            return nil
        }()
        let entry = TimestampedAIEvent(
            timestamp: Date(),
            channelID: Int(event.channelID),
            kind: event.kind,
            aiTag: aiTag
        )
        aiEventLog.insert(entry, at: 0)
        if aiEventLog.count > Self.eventLogCapacity {
            aiEventLog.removeLast(aiEventLog.count - Self.eventLogCapacity)
        }
        // Reflect into the live indicator maps so the sidebar dots update.
        switch event.kind {
        case .motionStart:
            motionState[Int(event.channelID)] = true
        case .motionStop:
            motionState[Int(event.channelID)] = false
        case .ai:
            aiTriggered[Int(event.channelID)] = true
        case .other:
            break
        }
    }

    public func ptz(channel: Int, op: PtzOp, speed: Int = 32, presetID: Int? = nil) async {
        do {
            try await client.sendIgnoringValue(Commands.ptzCtrl(channel: channel, op: op, speed: speed, id: presetID))
        } catch {
            // Surface to UI later via an alert pipeline.
        }
    }

    public func snapshotURL(channel: Int) async -> URL? {
        let token = await client.currentToken?.name
        return streamURLs.snapshot(channel: channel, token: token)
    }

    private func startEventPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.status == .connected {
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollOnce() async {
        for ch in channels where ch.isOnline {
            if let md = try? await client.send(Commands.getMdState(channel: ch.channel), as: MotionStateValue.self) {
                motionState[ch.channel] = md.isTriggered
            }
            if let ai = try? await client.send(Commands.getAiState(channel: ch.channel), as: AIStateValue.self) {
                aiTriggered[ch.channel] = ai.anyTriggered
            }
        }
    }
}
