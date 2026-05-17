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
    /// Original LAN credentials supplied at init time. Kept for
    /// diagnostics and for the LAN-first retry on every fresh
    /// `connect()` call. The *active* credentials may swap to a
    /// remote host (`entry.remoteHost`) at runtime — see
    /// `activeCredentials`.
    public let credentials: CameraCredentials
    /// Credentials currently in use. Equal to `credentials` for
    /// LAN-mode sessions; swapped to a `host = entry.remoteHost`
    /// variant when the connect fallback engages. Read-only
    /// outside the session.
    public private(set) var activeCredentials: CameraCredentials
    /// CGI client bound to `activeCredentials`. Rebuilt on
    /// LAN→remote (or remote→LAN) fallback. External callers
    /// access fresh state each read.
    public private(set) var client: CGIClient
    /// RTSP/HTTP URL builder bound to `activeCredentials`.
    /// Rebuilt alongside `client`.
    public private(set) var streamURLs: StreamURLs
    /// The mode the *last successful* connect used. Surfaced in
    /// the UI (sidebar pip) so the user can tell at a glance
    /// which path the camera is reached over.
    public private(set) var connectionMode: CameraConnectionMode = .lan
    /// TLS pinning policy passed at init. Held so the fallback
    /// path can build a new `CGIClient` with the same setting.
    private let tlsPolicy: TLSPinningPolicy

    public var status: ConnectionStatus = .disconnected
    /// 0.5.0 Theme E — richer step-by-step progress signal for the UI.
    /// Kept alongside `status` (which older view code reads) so the
    /// migration is incremental.
    public var connectionStage: ConnectionStage = .idle
    /// Retry attempt counter exposed for UIs that want to show
    /// "(retry 2)" badges on a long connect.
    public var connectionAttempt: Int = 0
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
    private static let initialMotionPollDelaySeconds: TimeInterval = 3
    private static let motionPollIntervalSeconds: TimeInterval = 10

    /// Battery info per channel (only present for battery-powered cameras).
    /// Updated from Baichuan msg 252 (`batteryInfoList`) pushes, which the
    /// hub emits every few seconds for each paired battery cam.
    public var batteryByChannel: [Int: BaichuanBatteryInfo] = [:]

    private var baichuanTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    /// 0.7.0 Phase 4b — set after the first successful UID
    /// fetch within this session's lifetime, so the per-
    /// reconnect Baichuan loop doesn't re-issue `msg_id=114`
    /// every time the TCP connection blips. The persisted UID
    /// on `CameraEntry` is the cross-session source of truth;
    /// this flag just avoids redundant fetches inside a single
    /// app run.
    private var uidCapturedThisSession: Bool = false
    private var connectGeneration: Int = 0
    /// 0.6.0 Slice 14 — polling lifecycle extracted to `PollManager`.
    /// Replaces the prior `pollTask` + `foregroundCGIOperationDepth +
    /// shouldResumePollingAfterForegroundCGI` triad. `@Observation
    /// Ignored` keeps the property out of the SwiftUI observation
    /// graph (the manager exposes its own observable state if a UI
    /// later needs to surface paused / running). Implicitly-unwrapped
    /// because `@Observable` is incompatible with `lazy`, so we set
    /// this in `init` after the other stored properties.
    @ObservationIgnored
    private var pollManager: PollManager!
    public private(set) var baichuanClient: BaichuanClient?

    public init(
        entry: CameraEntry,
        credentials: CameraCredentials,
        tlsPolicy: TLSPinningPolicy = .alwaysAccept
    ) {
        self.entry = entry
        self.credentials = credentials
        self.activeCredentials = credentials
        self.tlsPolicy = tlsPolicy
        self.client = CGIClient(credentials: credentials, tlsPolicy: tlsPolicy)
        self.streamURLs = StreamURLs(credentials: credentials)
        // PollManager captures `self` weakly so the session can vend
        // it via `init` without the cycle SwiftUI normally flags.
        self.pollManager = PollManager(
            initialDelay: Self.initialMotionPollDelaySeconds,
            intervalProvider: { @MainActor in
                AdaptivePollSchedule.shared.currentIntervalSeconds
            },
            shouldContinue: { @MainActor [weak self] in
                self?.status == .connected
            },
            work: { @MainActor [weak self] in
                await self?.pollOnce()
            }
        )
    }

    /// Re-attempt a hung or failed connection. Tears down any half-open
    /// CGI state, then runs `connect()` again. Used by the "Try Again"
    /// button the UI shows after the connection has been stuck in
    /// `.connecting` for ~12 seconds. URLSession requests in flight
    /// don't observe Task cancellation, so a previously-hung `connect`
    /// may still resolve in the background after this — `status` will
    /// reflect the most recent attempt to finish either way.
    public func reconnect() async {
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        await client.logout()
        await connect()
    }

    public func connect(policy: ConnectRetryPolicy = .default) async {
        if status == .connected { return }
        if let connectTask {
            await connectTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runConnect(policy: policy)
        }
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = task
        await task.value
        if connectGeneration == generation {
            connectTask = nil
        }
    }

    /// Result of one host's attempt loop. Drives the LAN →
    /// remote fallback decision in `runConnect`.
    private enum HostAttemptOutcome {
        /// Connect succeeded — the session is now `.connected`.
        case succeeded
        /// Credentials were rejected. Terminal — never falls
        /// back to remote because the same creds will fail
        /// there too.
        case authFailure(reason: String)
        /// Couldn't reach this host (timeout / network error
        /// / non-auth error). Caller may try the next host.
        case unreachable(any Error)
        /// Overall deadline elapsed while retries were in
        /// flight. Caller may still try a remote host within
        /// any remaining time.
        case deadlineExceeded(lastError: (any Error)?)
    }

    private func runConnect(policy: ConnectRetryPolicy) async {
        status = .connecting
        connectionAttempt = 0
        let deadline = Date().addingTimeInterval(policy.overallDeadlineSeconds)

        // Every connect() starts fresh with the LAN credentials,
        // even if the previous session failed over to remote.
        // Moving back home, the user expects LAN to win.
        switchToHost(credentials.host, mode: .lan)

        // iOS only: a missing Local Network permission silently
        // strands every camera request for ~30 s before the
        // URLSession deadline trips. Probe up front so the UI can
        // surface "Allow Local Network" instead of an unexplained
        // spinner. macOS short-circuits to .granted.
        connectionStage = .awaitingLocalNetworkPermission
        let permission = await LocalNetworkPermission.check(timeoutSeconds: 0.4)
        switch permission {
        case .denied:
            status = .error("Local Network permission denied")
            connectionStage = .failed(reason: "Allow Local Network in Settings → Privacy → Local Network")
            return
        case .pending:
            // Permission prompt is showing; the user will tap shortly.
            // Don't fail — proceed and let the first request show the
            // prompt. The progress label tells them what we're waiting on.
            log.info("Local Network permission pending; proceeding optimistically")
        case .granted, .unknown:
            break
        }

        // Attempt 1: LAN. Most cameras succeed here.
        let lanOutcome = await attemptHostUntilDeadline(
            mode: .lan,
            deadline: deadline,
            policy: policy
        )
        switch lanOutcome {
        case .succeeded:
            return
        case .authFailure(let reason):
            status = .error(reason)
            connectionStage = .failed(reason: reason)
            return
        case .unreachable, .deadlineExceeded:
            break   // fall through to remote
        }

        // Attempt 2: WAN, only if the user has configured a
        // remote host. The earlier zero-config Reolink-P2P path
        // turned out to be account-gated; this manual DDNS /
        // static-IP fallback is the 0.7.0 ship.
        let trimmedRemote = (entry.remoteHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRemote.isEmpty, !Task.isCancelled {
            log.info("LAN unreachable; falling back to remote host \(trimmedRemote, privacy: .public)")
            switchToHost(trimmedRemote, mode: .remote)
            let remoteOutcome = await attemptHostUntilDeadline(
                mode: .remote,
                deadline: deadline,
                policy: policy
            )
            switch remoteOutcome {
            case .succeeded:
                return
            case .authFailure(let reason):
                status = .error(reason)
                connectionStage = .failed(reason: reason)
                return
            case .unreachable(let err), .deadlineExceeded(let err?):
                status = .error(String(describing: err))
                connectionStage = .failed(reason: "Couldn't reach the camera over LAN or its configured remote address. Check the network and try again.")
                return
            case .deadlineExceeded(nil):
                status = .error("Couldn't reach the camera")
                connectionStage = .failed(reason: "Couldn't reach the camera over LAN or its configured remote address. Check the network and try again.")
                return
            }
        }

        // No remote configured: emit the LAN-only failure as before.
        switch lanOutcome {
        case .unreachable(let err), .deadlineExceeded(let err?):
            status = .error(String(describing: err))
            connectionStage = .failed(reason: "Couldn't reach the camera (\(String(describing: err))). Try again.")
        case .deadlineExceeded(nil):
            status = .error("Couldn't reach the camera")
            connectionStage = .failed(reason: "Couldn't reach the camera. Try again.")
        case .succeeded, .authFailure:
            break   // already handled above
        }
    }

    /// Run the per-attempt retry loop against the currently-
    /// active host (`activeCredentials.host`). Returns when
    /// either the connect succeeds (terminal), the credentials
    /// are rejected (terminal), every attempt has failed with
    /// non-auth errors, or the wall-clock deadline elapses.
    private func attemptHostUntilDeadline(
        mode: CameraConnectionMode,
        deadline: Date,
        policy: ConnectRetryPolicy
    ) async -> HostAttemptOutcome {
        var lastError: (any Error)?
        var attempt = 0
        while attempt < policy.maxAttempts, !Task.isCancelled, Date() < deadline {
            attempt += 1
            connectionAttempt = attempt
            connectionStage = .loggingIn(attempt: attempt)
            do {
                _ = try await client.login()

                // Keep the first metadata pass serialized. Reolink hubs
                // are sensitive to overlapping CGI requests during the
                // first login window; shaving a few hundred milliseconds
                // here is not worth turning startup into a coin toss.
                connectionStage = .fetchingDeviceMetadata
                let info = try await client.send(Commands.getDevInfo(), as: DeviceInfoEnvelope.self)
                deviceInfo = info.DevInfo

                if info.DevInfo.isNVR {
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
                connectionStage = .establishingPushChannel
                connectionMode = mode
                status = .connected
                startEventPolling()
                startBaichuanEvents()
                // Baichuan handshake races in the background; flip
                // the stage to .connected immediately so the UI shows
                // a working live tile.
                connectionStage = .connected
                return .succeeded
            } catch {
                lastError = error
                if Self.isAuthFailure(error) {
                    log.warning("connect attempt \(attempt) auth-failed; stopping retries")
                    return .authFailure(reason: "Authentication failed — check the password.")
                }
                log.warning("connect attempt \(attempt) failed (mode=\(String(describing: mode), privacy: .public)): \(error.localizedDescription, privacy: .public)")
                if attempt >= policy.maxAttempts { break }
                let backoff = policy.backoffSeconds(attempt: attempt)
                // Don't sleep past the overall deadline.
                let remaining = deadline.timeIntervalSinceNow
                let effective = max(0, min(backoff, remaining))
                if effective <= 0 { break }
                connectionStage = .retrying(after: effective, reason: error.localizedDescription)
                // safe: cancellation throw is the intended exit path.
                try? await Task.sleep(for: .seconds(effective))
            }
        }
        if Date() >= deadline {
            return .deadlineExceeded(lastError: lastError)
        }
        if let lastError {
            return .unreachable(lastError)
        }
        // Loop exited without an error captured (cancellation
        // before the first attempt produced one). Surface as
        // a deadline-exceeded with no error.
        return .deadlineExceeded(lastError: nil)
    }

    /// Rebuild `activeCredentials`, `client`, and `streamURLs`
    /// for the supplied host. Mode is recorded but only
    /// committed to `connectionMode` on a successful connect.
    private func switchToHost(_ host: String, mode: CameraConnectionMode) {
        let newCreds = CameraCredentials(
            host: host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            useHTTPS: credentials.useHTTPS
        )
        self.activeCredentials = newCreds
        self.client = CGIClient(credentials: newCreds, tlsPolicy: tlsPolicy)
        self.streamURLs = StreamURLs(credentials: newCreds)
    }

    /// "Stop retrying" classifier. 0.5.1: rewritten to inspect the
    /// **typed** error rather than substring-match
    /// `"\(error)".lowercased()` — the previous version misclassified
    /// transient Reolink response codes as auth failures because
    /// their descriptions all contain the word "login":
    ///
    ///   -10 loginRequired   → token expired, retry with fresh login
    ///   -11 loginError      → ambiguous, often transient on cold start
    ///   -15 loginAlready    → another session is mid-login, retry
    ///   -16 lockedByOthers  → temporary lock, retry
    ///   -20 loginFailed     → ambiguous, sometimes hub-busy on boot
    ///
    /// Users saw "Authentication failed" on startup and a subsequent
    /// "Try Again" tap succeeded because the original was just a
    /// boot-race that should have been retried. We now treat only
    /// the codes that *unambiguously* mean "wrong credentials" as
    /// fatal:
    ///
    ///   -14 invalidUser     → username genuinely doesn't exist
    ///   HTTP 401 / 403      → server explicitly rejected the auth
    ///
    /// Everything else — including ambiguous Reolink error codes
    /// and any URL transport error — is treated as transient and
    /// goes through the normal retry path. Worst case (genuinely
    /// wrong password producing `-11` / `-20`): we burn through
    /// `maxAttempts` retries before surfacing the error, which the
    /// user-facing UI already labels with the actual error string.
    // `internal` so the regression test can lock the precise mapping
    // from typed errors to "stop retrying" decisions. `nonisolated`
    // because the implementation is a pure function over the error
    // payload — no MainActor state involved.
    nonisolated static func isAuthFailure(_ error: any Error) -> Bool {
        // Typed Reolink wrap with an inner CGI error code.
        if let reolinkErr = error as? ReolinkClientError {
            switch reolinkErr {
            case .loginFailed(let cgiError):
                guard let cgiError else { return false }
                return cgiError.rspCode == CGIErrorCode.invalidUser.rawValue
            case .commandFailed(_, let cgiError):
                return cgiError.rspCode == CGIErrorCode.invalidUser.rawValue
            case .http(let status, _):
                return status == 401 || status == 403
            default:
                return false
            }
        }
        return false
    }

    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        pollManager.stop()
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
        connectionStage = .idle
        connectionAttempt = 0
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
            // Use the host the CGI connect actually succeeded
            // against — LAN normally, remote (DDNS / WAN) when
            // the LAN attempt timed out and the fallback fired.
            // Baichuan rides the same TCP path, so reusing the
            // active host keeps the two control planes in sync.
            let creds = BaichuanCredentials(
                host: self.activeCredentials.host,
                username: self.activeCredentials.username,
                password: self.activeCredentials.password
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
                    // 0.7.0 Phase 4b — opportunistically capture
                    // the camera UID for the future P2P remote-
                    // access path. Only fetched when we don't
                    // already have one stored AND haven't already
                    // captured it this session; `fetchUID` returns
                    // "" on failure, which we treat as "try again
                    // next login" rather than persisting an empty
                    // string. Never blocks the event stream
                    // below.
                    if !self.uidCapturedThisSession, self.entry.uid == nil {
                        let uid = await client.fetchUID()
                        if !uid.isEmpty {
                            self.onUIDObserved?(uid)
                            self.uidCapturedThisSession = true
                        }
                    }
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
                // safe: cancellation throw is the intended exit path.
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

    /// Temporarily stop low-priority background CGI polling while a
    /// user-initiated request runs. Recording searches, OSD writes,
    /// and similar foreground actions should not sit behind per-
    /// channel motion-state polling on busy hubs.
    ///
    /// 0.6.0 Slice 14 — delegates to `PollManager.pausingBackground
    /// Polling` which owns the depth counter + cancel/resume.
    public func withBackgroundPollingPaused<T: Sendable>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        // `throws` rather than `rethrows` because the underlying
        // PollManager method is `throws` unconditionally — `rethrows`
        // can't see through the indirection. Net behaviour is the
        // same: the body's error is forwarded.
        try await pollManager.pausingBackgroundPolling(operation)
    }

    /// Non-throwing convenience used by call sites whose body returns
    /// a `Result`-like enum and never `throws` (e.g. the
    /// `RecordingsDataSource.search` adapter, which already wraps
    /// network errors into `RecordingsSearchOutcome.failure`).
    public func withBackgroundPollingPausedNoThrow<T: Sendable>(
        _ operation: @MainActor () async -> T
    ) async -> T {
        await pollManager.pausingBackgroundPolling(operation)
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

    /// 0.7.0 Phase 4b — back-channel from the session to the
    /// store so a freshly-fetched Reolink P2P UID can be
    /// persisted to `cameras.json` without the session itself
    /// taking a hard reference to `CameraStore`. Wired in
    /// `CameraStore.session(for:)`, mirrored on the same pattern
    /// as `dualLensOverride`. Idempotent on the store side, so
    /// invoking it on every successful login (rather than only
    /// the first one) doesn't thrash iCloud sync.
    public var onUIDObserved: (@MainActor (String) -> Void)?

    /// Authoritative "does this camera have two physical lenses on one
    /// stream" check. Checks the user-supplied manual override first, then
    /// the `typeInfo` heuristic on `ChannelStatus`.
    public func isDualLens(channel: Int) -> Bool {
        if dualLensOverride?(channel) == true { return true }
        guard let ch = channels.first(where: { $0.channel == channel }) else { return false }
        return ch.isDualLens
    }

    private func startEventPolling() {
        // 0.6.0 Slice 14 — delegated to PollManager. The manager's
        // initial-delay + adaptive interval + shouldContinue gate
        // mirror the previous inline behaviour exactly.
        pollManager.start()
    }

    private func pollOnce() async {
        for ch in liveChannels where ch.isOnline && !Task.isCancelled {
            // safe: best-effort capability probe. Failure → keep the
            // last-known state for this channel; the next poll retries
            // and a persistent failure is already surfaced by the
            // session's connection-stage machinery.
            if let md = try? await client.send(Commands.getMdState(channel: ch.channel), as: MotionStateValue.self) {
                motionState[ch.channel] = md.isTriggered
            }
            guard !Task.isCancelled else { return }
            // safe: same as above for AI state.
            if let ai = try? await client.send(Commands.getAiState(channel: ch.channel), as: AIStateValue.self) {
                aiTriggered[ch.channel] = ai.anyTriggered
            }
        }
    }
}
