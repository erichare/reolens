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

    /// Reolink Duo (RLC-81xA Duo, Duo 2, Duo 3, Duo PoE, TrackMix), Argus 4 /
    /// Argus 4 Pro, and DualTag cameras encode two physical lenses into a
    /// single wide frame (typically 8:3 or 32:9). Detection is heuristic —
    /// `typeInfo` from `GetChannelstatus` carries the model code; we
    /// normalize whitespace/case before matching because Reolink isn't
    /// consistent about either across firmware revisions. When true, the
    /// UI should render the tile with the natural aspect instead of
    /// cropping to 16:9.
    public var isDualLens: Bool {
        let s = (typeInfo ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        // Marketing names (when the firmware reports them):
        if s.contains("duo")
            || s.contains("trackmix")
            || s.contains("dualtag")
            || s.contains("argus4")          // Argus 4 / Argus 4 Pro
            || s.contains("argus_4") {
            return true
        }
        // Internal Reolink model codes for dual-lens hardware. The hub's
        // `GetChannelstatus` reports these instead of the marketing name on
        // most firmware revisions — `Argus4Pro_IPC` for the Kit, `A4Pro` /
        // `A4_Pro` on older payloads, `B400` for OEM Argus 4 boards, and
        // `RLC-A4P` for the wired-PoE sibling. Add more as Reolink ships
        // new dual-lens models.
        let dualLensCodes = ["a4pro", "a4_pro", "b400", "rlc-a4p", "rlca4p"]
        for code in dualLensCodes where s.contains(code) { return true }
        return false
    }

    /// Heuristic identification of battery-powered cameras. We can't rely on
    /// `sleep == 1` because a battery cam that happens to be momentarily awake
    /// (e.g., responding to a motion event) reports `sleep == 0`. Battery
    /// cameras shouldn't auto-stream because every connection drains the
    /// battery and the camera goes back to sleep moments later anyway.
    ///
    /// This is a fallback only — at runtime, prefer
    /// `CameraSession.isBatteryPowered(channel:)`, which consults live
    /// Baichuan msg-252 battery data and is authoritative.
    public var isBatteryPowered: Bool {
        let s = (typeInfo ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        return s.contains("argus")
            || s.contains("go")            // Reolink Go (LTE battery)
            || s.contains("battery")
            || s.contains("wirefree")       // Reolink's marketing term for battery
            || s.contains("wireguard")      // older Reolink internal label
            || s.contains("pir")
            || s.contains("solar")          // solar-charged battery cams
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
