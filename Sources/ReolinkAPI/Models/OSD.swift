import Foundation

public struct OsdSettings: Codable, Sendable, Hashable {
    public let channel: Int
    public var bgcolor: Int?
    public var osdChannel: OsdItem?
    public var osdTime: OsdItem?
    public var watermark: Int?

    public init(
        channel: Int,
        bgcolor: Int? = nil,
        osdChannel: OsdItem? = nil,
        osdTime: OsdItem? = nil,
        watermark: Int? = nil
    ) {
        self.channel = channel
        self.bgcolor = bgcolor
        self.osdChannel = osdChannel
        self.osdTime = osdTime
        self.watermark = watermark
    }

    public struct OsdItem: Codable, Sendable, Hashable {
        public var enable: Int
        public var name: String?
        public var pos: String?

        public init(enable: Int, name: String? = nil, pos: String? = nil) {
            self.enable = enable
            self.name = name
            self.pos = pos
        }

        public var isEnabled: Bool {
            get { enable == 1 }
            set { enable = newValue ? 1 : 0 }
        }
    }
}

public struct OsdEnvelope: Codable, Sendable {
    public var Osd: OsdSettings
}

public struct SetOsdParam: Encodable, Sendable {
    public let Osd: OsdSettings
}
