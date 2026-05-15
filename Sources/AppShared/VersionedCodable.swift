import Foundation

/// Lightweight versioning framework for persisted documents.
///
/// Today the codebase has three Codable persistence paths that
/// silently fall back on missing fields (`CameraEntry`,
/// `RecordingBookmark`, `SharedContainer.RecentMotionEvent`). Adding a
/// new required field anywhere in that chain is silently
/// data-loss-prone — a 0.7 device reading a 0.6 archive can't
/// distinguish "user never set X" from "this archive predates X". The
/// utilities here let new persisted Codable types adopt a forward-
/// stable, explicit-version schema without inventing the wheel each
/// time.
///
/// Pattern:
///   1. Wrap your records in a `VersionedFile`.
///   2. Pick a current version number in your model module.
///   3. Use `VersionedDecoder.decode(...)` at the read side. Provide a
///      `migrate` closure for any older version you still want to
///      support; throw to refuse a future version cleanly.
///
/// `NotificationHistory` is the in-tree reference adopter (see
/// `NotificationHistoryFile`); future persisted formats should follow
/// the same shape so users get the same forward/backward behavior
/// everywhere.

/// Generic versioned file envelope. Stores a single `version` plus a
/// body of any Codable + Sendable type. Encoders / decoders use this
/// directly; no custom CodingKeys plumbing required.
public struct VersionedFile<Body: Codable & Sendable>: Codable, Sendable {
    public let version: Int
    public let body: Body

    public init(version: Int, body: Body) {
        self.version = version
        self.body = body
    }
}

/// Read-side helpers. The `decode` family decodes only `version` on
/// the first pass so the caller can dispatch on the version without
/// throwing on a future-version body shape.
public enum VersionedDecoder {

    /// Just peek at the `version` field. Returns nil if the data
    /// doesn't have a `version` key (i.e. it's a pre-versioning
    /// archive — the caller can treat that as version 1 or any other
    /// default).
    public static func peekVersion(
        _ data: Data,
        decoder: JSONDecoder = VersionedDecoder.iso8601
    ) -> Int? {
        struct Peek: Decodable { let version: Int? }
        // safe: peek is the API contract — pre-versioning archives
        // legitimately decode as nil and the caller treats that as the
        // baseline schema version.
        let peek = try? decoder.decode(Peek.self, from: data)
        return peek?.version
    }

    /// Decode a `VersionedFile` whose body shape exactly matches the
    /// current schema. Throws on version mismatch — the caller is
    /// expected to wrap this with a migration closure when supporting
    /// older versions.
    public static func decodeCurrent<Body: Codable & Sendable>(
        _ data: Data,
        expectedVersion: Int,
        as bodyType: Body.Type = Body.self,
        decoder: JSONDecoder = VersionedDecoder.iso8601
    ) throws -> Body {
        let file = try decoder.decode(VersionedFile<Body>.self, from: data)
        guard file.version == expectedVersion else {
            throw VersionedCodableError.versionMismatch(found: file.version, expected: expectedVersion)
        }
        return file.body
    }

    /// Decode with explicit migration support. The `migrate` closure
    /// receives the raw `Data` and the peeked `version`, and is
    /// responsible for returning a `Body` at the current shape. For
    /// the common case where the file is already at the current
    /// version, the closure is skipped — call `decodeCurrent` directly
    /// inside the closure to read the as-is body.
    public static func decode<Body: Codable & Sendable>(
        _ data: Data,
        currentVersion: Int,
        as bodyType: Body.Type = Body.self,
        decoder: JSONDecoder = VersionedDecoder.iso8601,
        migrate: (_ data: Data, _ fromVersion: Int) throws -> Body
    ) throws -> Body {
        let found = peekVersion(data, decoder: decoder) ?? 0
        if found == currentVersion {
            return try decodeCurrent(data, expectedVersion: currentVersion, decoder: decoder)
        }
        return try migrate(data, found)
    }

    /// Default ISO-8601 JSON decoder used by every adopter for date
    /// consistency. Adopters that prefer their own encoder may pass it
    /// explicitly.
    public static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Write-side helpers.
public enum VersionedEncoder {

    public static func encode<Body: Codable & Sendable>(
        _ body: Body,
        version: Int,
        encoder: JSONEncoder = VersionedEncoder.iso8601
    ) throws -> Data {
        try encoder.encode(VersionedFile(version: version, body: body))
    }

    public static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()
}

public enum VersionedCodableError: Error, Sendable, Equatable {
    case versionMismatch(found: Int, expected: Int)
    case missingVersion
    case migrationFailed(fromVersion: Int, reason: String)
}
