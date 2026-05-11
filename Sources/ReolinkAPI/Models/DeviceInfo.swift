import Foundation

public struct DeviceInfo: Sendable, Codable, Hashable {
    public let name: String?
    public let model: String?
    public let hardVer: String?
    public let firmVer: String?
    public let serial: String?
    public let buildDay: String?
    public let cfgVer: String?
    public let detail: String?
    public let diskNum: Int?
    public let channelNum: Int?
    public let type: String?
    public let wifi: Int?
    public let b485: Int?
    public let IOInputNum: Int?
    public let IOOutputNum: Int?
    public let audioNum: Int?
    public let pakSuffix: String?
    public let exactType: String?

    public var isNVR: Bool {
        let t = type?.lowercased() ?? ""
        return t == "nvr" || t == "hub" || ((channelNum ?? 1) > 1)
    }

    /// Reolink Home Hub identifies itself with `type: "Hub"` (case-varies) or a
    /// model name beginning with `Reolink Home Hub` / `RLN-Hub`.
    public var isHomeHub: Bool {
        if type?.lowercased() == "hub" { return true }
        let m = (model ?? "").lowercased()
        return m.contains("home hub") || m.hasPrefix("rln-hub") || m.contains("hub pro")
    }
}

public struct DeviceInfoEnvelope: Sendable, Codable {
    public let DevInfo: DeviceInfo
}

public struct ChannelStatus: Sendable, Codable, Hashable, Identifiable {
    public let channel: Int
    public let name: String?
    public let online: Int
    public let typeInfo: String?
    public let uid: String?
    public let sleep: Int?

    public init(channel: Int, name: String?, online: Int, typeInfo: String?, uid: String? = nil, sleep: Int? = nil) {
        self.channel = channel
        self.name = name
        self.online = online
        self.typeInfo = typeInfo
        self.uid = uid
        self.sleep = sleep
    }

    public var id: Int { channel }
    public var isOnline: Bool { online == 1 }
    public var isAsleep: Bool { sleep == 1 }

    /// Reolink Duo (RLC-81xA Duo, Duo 2, Duo 3, Duo PoE, TrackMix) cameras
    /// encode two physical lenses into a single wide frame (typically 8:3 or
    /// 16:5). Detection is heuristic — the camera identifies via the `typeInfo`
    /// field returned in `GetChannelstatus`. When true, the UI should render
    /// the tile with the natural aspect instead of cropping to 16:9.
    public var isDualLens: Bool {
        let s = (typeInfo ?? "").lowercased()
        return s.contains("duo") || s.contains("trackmix") || s.contains("dualtag")
    }

    /// Heuristic identification of battery-powered cameras. We can't rely on
    /// `sleep == 1` because a battery cam that happens to be momentarily awake
    /// (e.g., responding to a motion event) reports `sleep == 0`. Battery
    /// cameras shouldn't auto-stream because every connection drains the
    /// battery and the camera goes back to sleep moments later anyway.
    public var isBatteryPowered: Bool {
        let s = (typeInfo ?? "").lowercased()
        return s.contains("argus")
            || s.contains("go")
            || s.contains("battery")
            || s.contains("wireguard")  // older Reolink internal label
            || s.contains("pir")
    }
}

public struct ChannelStatusEnvelope: Sendable, Codable {
    public let count: Int
    public let status: [ChannelStatus]
}

public struct LinkLocal: Sendable, Codable {
    public let activeLink: String?
    public let mac: String?
    public let dns: DNSInfo?
    public let `static`: StaticIP?

    public struct DNSInfo: Sendable, Codable {
        public let auto: Int?
        public let dns1: String?
        public let dns2: String?
    }
    public struct StaticIP: Sendable, Codable {
        public let ip: String?
        public let mask: String?
        public let gateway: String?
    }
}

public struct LinkLocalEnvelope: Sendable, Codable {
    public let LocalLink: LinkLocal
}
