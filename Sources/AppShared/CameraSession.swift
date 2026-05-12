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

    public init(
        entry: CameraEntry,
        credentials: CameraCredentials,
        tlsPolicy: TLSPinningPolicy = .alwaysAccept
    ) {
        self.entry = entry
        self.credentials = credentials
        self.client = CGIClient(credentials: credentials, tlsPolicy: tlsPolicy)
        self.streamURLs = StreamURLs(credentials: credentials)
    }

    /// Re-attempt a hung or failed connection. Tears down any half-open
    /// CGI state, then runs `connect()` again. Used by the "Try Again"
    /// button the UI shows after the connection has been stuck in
    /// `.connecting` for ~12 seconds. URLSession requests in flight
    /// don't observe Task cancellation, so a previously-hung `connect`
    /// may still resolve in the background after this — `status` will
    /// reflect the most recent attempt to finish either way.
    public func reconnect() async {
        await client.logout()
        await connect()
    }

    public func connect() async {
        status = .connecting
        // Bounded auto-retry. The "first launch fails, Reconnect
        // works" case is almost always a transient: macOS hasn't
        // finished joining Wi-Fi, the hub is still booting, mDNS
        // hasn't resolved, etc. A single attempt buries those in
        // `.error` and forces the user to manually click Reconnect.
        // 4 attempts × 2/4/8 s backoff covers ~14 s of transient
        // unavailability without spamming the hub or hanging forever
        // on truly-broken setups. Auth failures stop early because a
        // bad password isn't going to start working.
        let maxAttempts = 4
        var attempt = 0
        var lastError: (any Error)?
        while attempt < maxAttempts, !Task.isCancelled {
            attempt += 1
            do {
                _ = try await client.login()
                let info = try await client.send(Commands.getDevInfo(), as: DeviceInfoEnvelope.self)
                deviceInfo = info.DevInfo

                if info.DevInfo.isNVR {
                    // Capture the raw JSON before decoding so we can see
                    // EVERY field the hub returns per channel — useful
                    // when a paired camera doesn't carry `typeInfo` and
                    // we need an alternate signal for dual-lens /
                    // battery classification.
                    let raw = try await client.sendCapturingRaw(Commands.getChannelStatus())
                    // Raw GetChannelstatus payloads carry per-channel
                    // UIDs and hardware-fingerprinting fields. Gate
                    // behind developer mode AND emit at .debug so the
                    // dump doesn't surface in sysdiagnose exports for
                    // ordinary users. AGENTS.md §11.
                    if CameraStore.developerModeIsOn, let pretty = String(data: raw, encoding: .utf8) {
                        log.debug("GetChannelstatus raw payload (first 4 KB):\n\(pretty.prefix(4096), privacy: .private)")
                    }
                    let env = try JSONDecoder().decode([CGIResponse<ChannelStatusEnvelope>].self, from: raw)
                    channels = env.first?.value?.status ?? []
                } else {
                    channels = [ChannelStatus(channel: 0, name: info.DevInfo.name, online: 1, typeInfo: info.DevInfo.model, uid: nil, sleep: 0)]
                }
                for ch in channels {
                    log.info("Channel \(ch.channel) name=\(ch.name ?? "<none>", privacy: .public) typeInfo=\(ch.typeInfo ?? "<nil>", privacy: .public) sleep=\(ch.sleep ?? 0) online=\(ch.online)")
                }
                status = .connected
                startEventPolling()
                startBaichuanEvents()
                return
            } catch {
                lastError = error
                // Auth-style failures are permanent — don't waste
                // retries (and don't lock the user out of their hub by
                // hammering it with bad credentials). Network /
                // timeout / "host unreachable" failures fall through
                // to the backoff sleep.
                if Self.isAuthFailure(error) {
                    log.warning("connect attempt \(attempt) auth-failed; stopping retries")
                    break
                }
                log.warning("connect attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt >= maxAttempts { break }
                let backoffSeconds = pow(2.0, Double(attempt))   // 2, 4, 8
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
        if let lastError {
            status = .error("\(lastError)")
        }
    }

    /// Heuristic for "stop retrying" failure cases. CGIClient surfaces
    /// auth errors with a specific message; anything else is treated
    /// as transient. False positives just mean we retry an
    /// unrecoverable error a few times before giving up — acceptable.
    private static func isAuthFailure(_ error: any Error) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("login") || text.contains("auth") || text.contains("unauthorized") || text.contains("invalid password") || text.contains("password")
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
    ///
    /// Auto-retries on failure with bounded backoff. Reolink hubs cap
    /// concurrent Baichuan logins per credential — if another instance
    /// of the app on a different device is connected first, the second
    /// login fails. The retry loop covers that, plus brief network
    /// blips and hub reboots, so pushes resume automatically without
    /// the user having to reconnect.
    private func startBaichuanEvents() {
        baichuanTask?.cancel()
        baichuanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let creds = BaichuanCredentials(
                host: self.credentials.host,
                username: self.credentials.username,
                password: self.credentials.password
            )
            var backoffSeconds: UInt64 = 2
            let maxBackoffSeconds: UInt64 = 60
            while !Task.isCancelled, self.status == .connected {
                let client = BaichuanClient(credentials: creds)
                self.baichuanClient = client
                do {
                    try await client.connect()
                    let deviceName = try await client.login()
                    log.info("Baichuan login OK device=\(deviceName, privacy: .public)")
                    backoffSeconds = 2
                    // Spin up the battery-info reader alongside alarm
                    // events. Both consume the same unsolicited push
                    // stream — the hub multiplexes msgID=33 (motion)
                    // and msgID=252 (battery) on a single TCP
                    // connection it already gave us.
                    self.startBatterySubscriber(client: client)
                    let events = try await client.subscribeToAlarmEvents()
                    for await event in events {
                        self.recordAIEvent(event)
                    }
                    // Stream finished cleanly (Baichuan TCP dropped).
                    // Fall through to the retry below.
                    log.info("Baichuan alarm stream ended; will retry in \(backoffSeconds, privacy: .public)s")
                } catch {
                    log.warning("Baichuan task error (retrying in \(backoffSeconds, privacy: .public)s): \(error.localizedDescription, privacy: .public)")
                }
                // Tear down the failed client before sleeping so the
                // next iteration starts fresh. Skips the wait if the
                // session has since been disconnected.
                await client.close()
                if self.status != .connected || Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(Double(backoffSeconds)))
                backoffSeconds = min(maxBackoffSeconds, backoffSeconds * 2)
            }
            self.baichuanClient = nil
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
        // The cameraID we pass to `EventNotifier.notify` is the user-
        // visible camera UUID (i.e. the `CameraEntry.id` this session
        // is bound to), NOT the timestamped event's UUID. Notification
        // tap routing looks up the camera by this ID; using the
        // per-event UUID — as a previous version of this code did —
        // made every notification tap land on a nonexistent camera.
        let cameraID = self.entry.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snap = await self.snapshotURL(channel: channelID)
            await EventNotifier.shared.notify(
                event: event,
                cameraID: cameraID,
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

    /// True when the channel is either battery-powered (which implies
    /// it sleeps between motion events) or currently asleep. Used by
    /// preview-mode tiles to decide whether to nudge the camera awake
    /// via Baichuan before hitting `cmd=Snap`.
    public func isBatteryPoweredOrAsleep(channel: Int) -> Bool {
        if isBatteryPowered(channel: channel) { return true }
        return channels.first(where: { $0.channel == channel })?.isAsleep ?? false
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
