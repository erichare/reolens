import Foundation

public struct LoginParam: Encodable, Sendable {
    public let User: User
    public struct User: Encodable, Sendable {
        public let userName: String
        public let password: String
        public let Version: String

        public init(userName: String, password: String, version: String = "0") {
            self.userName = userName
            self.password = password
            self.Version = version
        }
    }
}

public struct LoginResult: Decodable, Sendable {
    public let Token: TokenPayload
    public struct TokenPayload: Decodable, Sendable {
        public let leaseTime: Int
        public let name: String
    }
}

public struct MotionStateValue: Decodable, Sendable {
    public let state: Int
    public let channel: Int?

    public var isTriggered: Bool { state == 1 }
}

public struct AIStateValue: Decodable, Sendable {
    public let channel: Int?
    public let people: AIDetection?
    public let vehicle: AIDetection?
    public let dog_cat: AIDetection?
    public let face: AIDetection?
    public let package: AIDetection?
    public let other: AIDetection?
    public let visitor: AIDetection?

    public struct AIDetection: Decodable, Sendable {
        public let alarm_state: Int?
        public let support: Int?

        public var isTriggered: Bool { (alarm_state ?? 0) == 1 }
        public var isSupported: Bool { (support ?? 0) == 1 }
    }

    public var anyTriggered: Bool {
        [people, vehicle, dog_cat, face, package, other, visitor]
            .compactMap { $0 }
            .contains(where: \.isTriggered)
    }
}

public enum PtzOp: String, Sendable, Codable, CaseIterable {
    case left = "Left"
    case right = "Right"
    case up = "Up"
    case down = "Down"
    case leftUp = "LeftUp"
    case leftDown = "LeftDown"
    case rightUp = "RightUp"
    case rightDown = "RightDown"
    case stop = "Stop"
    case auto = "Auto"
    case zoomIn = "ZoomInc"
    case zoomOut = "ZoomDec"
    case focusIn = "FocusInc"
    case focusOut = "FocusDec"
    case toPos = "ToPos"
    case startPatrol = "StartPatrol"
    case stopPatrol = "StopPatrol"
}

public struct PtzCtrlParam: Encodable, Sendable {
    public let channel: Int
    public let op: PtzOp
    public let speed: Int?
    public let id: Int?

    public init(channel: Int, op: PtzOp, speed: Int? = nil, id: Int? = nil) {
        self.channel = channel
        self.op = op
        self.speed = speed
        self.id = id
    }
}
