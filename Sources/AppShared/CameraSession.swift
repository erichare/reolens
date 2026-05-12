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
    /// `channels` filtered to drop the empty paired-camera slots that
    /// Reolink Home Hub reports for unused channels (no name AND no
    /// typeInfo). Use this anywhere the UI shows real cameras to the
    /// user — sidebars, grid layouts, primary pickers — so we don't
    /// have to duplicate the filter at every call site.
    public var liveChannels: [ChannelStatus] {
        channels.filter { ch in
            (ch.name?.isEmpty == false) || (ch.typeInfo?.isEmpty == false)
        }
    }
    public var motionState: [Int: Bool] = [:]
    public var aiTriggered: [Int: Bool] = [:]

    /// Rolling log of Baichuan-delivered AI events, newest first. Capped at
    /// `eventLogCapacity` entries per channel.
    public var aiEventLog: [TimestampedAIEvent] = []
    public static let eventLogCapacity = 500

    /// Battery info per channel (only present for battery-powered cameras).
    /// Updated from Baichuan msg 252 (`batteryInfoList`) pushes, which the
    /// hub emits every few seconds for each paired battery cam.
    public var batteryByChannel: [Int: BaichuanBatteryInfo] = [:]

    private var pollTask: Task<Void, Never>?
    private var baichuanTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    public private(set) var baichuanClient: BaichuanClient?

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
                // Capture the raw JSON before decoding so we can see EVERY
                // field the hub returns per channel — useful when a paired
                // camera doesn't carry `typeInfo` and we need an alternate
                // signal for dual-lens / battery classification.
                let raw = try await client.sendCapturingRaw(Commands.getChannelStatus())
                if let pretty = String(data: raw, encoding: .utf8) {
                    log.info("GetChannelstatus raw payload (first 4 KB):\n\(pretty.prefix(4096), privacy: .public)")
                }
                let env = try JSONDecoder().decode([CGIResponse<ChannelStatusEnvelope>].self, from: raw)
                channels = env.first?.value?.status ?? []
            } else {
                channels = [ChannelStatus(channel: 0, name: info.DevInfo.name, online: 1, typeInfo: info.DevInfo.model, uid: nil, sleep: 0)]
            }
            // Dump the per-channel `typeInfo` so we can see exactly what
            // string Reolink reports for each paired camera. This is the
            // only field we use to recognize dual-lens / battery hardware,
            // and Reolink changes its naming across firmware versions —
            // logging it makes it cheap to add new model codes when a
            // camera doesn't get classified correctly.
            for ch in channels {
                log.info("Channel \(ch.channel) name=\(ch.name ?? "<none>", privacy: .public) typeInfo=\(ch.typeInfo ?? "<nil>", privacy: .public) sleep=\(ch.sleep ?? 0) online=\(ch.online)")
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
        batteryTask?.cancel()
        batteryTask = nil
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
                // Spin up the battery-info reader alongside alarm events.
                // Both consume the same unsolicited push stream — the hub
                // multiplexes msgID=33 (motion) and msgID=252 (battery) on
                // the single TCP connection it already gave us.
                self.startBatterySubscriber(client: client)
                let events = try await client.subscribeToAlarmEvents()
                for await event in events {
                    self.recordAIEvent(event)
                }
            } catch {
                log.warning("Baichuan task ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startBatterySubscriber(client: BaichuanClient) {
        batteryTask?.cancel()
        batteryTask = Task { @MainActor [weak self] in
            let stream = await client.subscribeToBatteryInfo()
            for await info in stream {
                guard let self else { return }
                let prior = self.batteryByChannel[info.channelID]
                self.batteryByChannel[info.channelID] = info
                // Log transitions to make low-battery diagnosis easy without
                // spamming on every push (~once per few seconds per cam).
                if prior?.percent != info.percent {
                    log.info("Battery ch=\(info.channelID) \(info.percent)% \(info.chargeStatus, privacy: .public)\(info.isPluggedIn ? " [plugged]" : "")")
                }
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
        // Fan the event out to the shared notification gateway. The
        // notifier itself decides whether to actually post (enabled,
        // permission, throttle, per-kind preferences) — we always hand it
        // the event so the user only has to configure once and every
        // device with a session forwards into the same pipeline.
        let channelID = Int(event.channelID)
        let cameraName = channels.first(where: { $0.channel == channelID })?.name
            ?? "Camera \(channelID + 1)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snap = await self.snapshotURL(channel: channelID)
            await EventNotifier.shared.notify(
                event: event,
                cameraName: cameraName,
                snapshotURL: snap
            )
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

    /// Authoritative "is this a battery-powered camera" check. The hub
    /// pushes msg 252 (`batteryInfoList`) for every paired battery cam, so
    /// presence of an entry in `batteryByChannel` is ground truth. We fall
    /// back to the `typeInfo` string heuristic for the moment between
    /// session connect and the first push.
    public func isBatteryPowered(channel: Int) -> Bool {
        if batteryByChannel[channel] != nil { return true }
        return channels.first(where: { $0.channel == channel })?.isBatteryPowered ?? false
    }

    /// Optional manual override consulted before the heuristic. When the
    /// hub's `GetChannelstatus` returns `typeInfo: nil` for paired cameras
    /// (common on Home Hub Pro firmware), the user can flip a toggle in
    /// channel settings to force dual-lens rendering. This closure is set
    /// up from `ContentView` at session-binding time.
    public var dualLensOverride: (@MainActor (Int) -> Bool)?

    /// Authoritative "does this camera have two physical lenses on one
    /// stream" check. Checks the user-supplied manual override first, then
    /// the `typeInfo` heuristic on `ChannelStatus`.
    public func isDualLens(channel: Int) -> Bool {
        if dualLensOverride?(channel) == true { return true }
        guard let ch = channels.first(where: { $0.channel == channel }) else { return false }
        return ch.isDualLens
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
