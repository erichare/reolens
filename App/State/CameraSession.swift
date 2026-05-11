import Foundation
import Observation
import ReolinkAPI

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
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

    private var pollTask: Task<Void, Never>?

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
        } catch {
            status = .error("\(error)")
        }
    }

    public func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        await client.logout()
        status = .disconnected
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
