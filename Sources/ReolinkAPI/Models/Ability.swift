import Foundation

/// `Ability` is huge and varies by firmware. We model permissively as a dictionary of
/// `(ver, permit)` pairs nested two levels deep, plus typed accessors for the most useful flags.
public struct Ability: Sendable, Codable {
    public let raw: AbilityNode

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(AbilityNode.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public func capability(_ path: String...) -> AbilityCapability? {
        node(at: path)?.capability
    }

    public func has(_ path: String...) -> Bool {
        if let cap = node(at: path)?.capability {
            return cap.ver > 0 && cap.permit > 0
        }
        return false
    }

    /// Capability for a specific channel under `abilityChn[index]`.
    public func channelCapability(_ key: String, channel: Int) -> AbilityCapability? {
        guard let chn = node(at: ["abilityChn"])?.items, channel < chn.count else { return nil }
        return chn[channel].children?[key]?.capability
    }

    private func node(at path: [String]) -> AbilityNode? {
        var node: AbilityNode? = raw
        for key in path { node = node?.children?[key] }
        return node
    }
}

public struct AbilityCapability: Sendable, Codable, Hashable {
    public let ver: Int
    public let permit: Int
}

public indirect enum AbilityNode: Sendable, Codable {
    case capability(AbilityCapability)
    case branch([String: AbilityNode])
    case list([AbilityNode])

    public var capability: AbilityCapability? {
        if case let .capability(c) = self { return c } else { return nil }
    }
    public var children: [String: AbilityNode]? {
        if case let .branch(c) = self { return c } else { return nil }
    }
    public var items: [AbilityNode]? {
        if case let .list(a) = self { return a } else { return nil }
    }

    // safe: the two `try?` sites below are intentional polymorphic
    // probes — the Ability node accepts three shapes (capability,
    // array of children, dict of named children) and we fall through
    // to the dict branch which `try`s and throws if none matched.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try capability first (a strict {ver, permit} shape).
        if let cap = try? container.decode(AbilityCapability.self),
           // Guard against ambient int dicts; require BOTH keys present.
           !Self.looksLikeBranch(cap) {
            self = .capability(cap)
            return
        }
        if let arr = try? container.decode([AbilityNode].self) {
            self = .list(arr)
            return
        }
        let dict = try container.decode([String: AbilityNode].self)
        self = .branch(dict)
    }

    private static func looksLikeBranch(_ cap: AbilityCapability) -> Bool { false }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .capability(let c): try container.encode(c)
        case .branch(let d): try container.encode(d)
        case .list(let a): try container.encode(a)
        }
    }
}

public struct AbilityEnvelope: Sendable, Codable {
    public let Ability: Ability
}
