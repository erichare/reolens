import Foundation
import Observation
import ReolinkAPI

/// Persisted camera definition (no password — that's in Keychain).
public struct CameraEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var useHTTPS: Bool
    public var preferredCodec: VideoCodec
    /// Per-channel rotation in degrees (90/180/270). Defaults to 0 when unset.
    public var channelRotations: [Int: Int] = [:]

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 80,
        username: String,
        useHTTPS: Bool = false,
        preferredCodec: VideoCodec = .h264,
        channelRotations: [Int: Int] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.useHTTPS = useHTTPS
        self.preferredCodec = preferredCodec
        self.channelRotations = channelRotations
    }

    /// Codable conformance: serialize the dict with String keys so JSON is round-trip clean.
    enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, useHTTPS, preferredCodec, channelRotations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.useHTTPS = try c.decode(Bool.self, forKey: .useHTTPS)
        self.preferredCodec = try c.decode(VideoCodec.self, forKey: .preferredCodec)
        let stringDict = (try? c.decode([String: Int].self, forKey: .channelRotations)) ?? [:]
        self.channelRotations = Dictionary(uniqueKeysWithValues: stringDict.compactMap { (key, value) -> (Int, Int)? in
            guard let k = Int(key) else { return nil }
            return (k, value)
        })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(useHTTPS, forKey: .useHTTPS)
        try c.encode(preferredCodec, forKey: .preferredCodec)
        let stringDict = Dictionary(uniqueKeysWithValues: channelRotations.map { (String($0.key), $0.value) })
        try c.encode(stringDict, forKey: .channelRotations)
    }
}

@MainActor
@Observable
public final class CameraStore {
    public var cameras: [CameraEntry] = []
    public var selection: SidebarSelection?
    public var sessions: [CameraEntry.ID: CameraSession] = [:]
    public var expandedDevices: Set<UUID> = []

    private let storageURL: URL

    public init() {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = appSupport?.appendingPathComponent("Reolens", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reolens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("cameras.json")
        load()
    }

    public func add(_ entry: CameraEntry, password: String) {
        cameras.append(entry)
        Keychain.set(password: password, for: entry.id)
        selection = .device(entry.id)
        save()
    }

    public func remove(_ id: CameraEntry.ID) {
        cameras.removeAll { $0.id == id }
        if let session = sessions.removeValue(forKey: id) {
            Task { await session.disconnect() }
        }
        Keychain.deletePassword(for: id)
        if selection?.deviceID == id {
            selection = cameras.first.map { .device($0.id) }
        }
        save()
    }

    public func rotation(for deviceID: UUID, channel: Int) -> Int {
        cameras.first(where: { $0.id == deviceID })?.channelRotations[channel] ?? 0
    }

    public func setRotation(_ degrees: Int, for deviceID: UUID, channel: Int) {
        guard let i = cameras.firstIndex(where: { $0.id == deviceID }) else { return }
        // Normalize to 0/90/180/270.
        let normalized = ((degrees % 360) + 360) % 360
        if normalized == 0 {
            cameras[i].channelRotations.removeValue(forKey: channel)
        } else {
            cameras[i].channelRotations[channel] = normalized
        }
        save()
    }

    public func rotateClockwise(deviceID: UUID, channel: Int) {
        let current = rotation(for: deviceID, channel: channel)
        setRotation(current + 90, for: deviceID, channel: channel)
    }

    public func session(for id: CameraEntry.ID) -> CameraSession? {
        if let s = sessions[id] { return s }
        guard let entry = cameras.first(where: { $0.id == id }),
              let password = Keychain.password(for: id) else { return nil }
        let creds = CameraCredentials(
            host: entry.host,
            port: entry.port,
            username: entry.username,
            password: password,
            useHTTPS: entry.useHTTPS
        )
        let session = CameraSession(entry: entry, credentials: creds)
        sessions[id] = session
        return session
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let entries = try? JSONDecoder().decode([CameraEntry].self, from: data) else { return }
        cameras = entries
        selection = entries.first.map { .device($0.id) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
