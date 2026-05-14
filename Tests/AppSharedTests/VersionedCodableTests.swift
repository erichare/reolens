import Testing
import Foundation
@testable import AppShared

/// Tests for `VersionedDecoder` + `VersionedEncoder`. Verifies the
/// round-trip, the peek behavior, the current-version fast path, and
/// the migration closure path. These tests pin down the contract so
/// future adopters get predictable forward/backward compatibility.
@Suite("VersionedCodable round-trip + migration")
struct VersionedCodableTests {

    private struct BodyV1: Codable, Sendable, Equatable {
        var name: String
        var count: Int
    }

    private struct BodyV2: Codable, Sendable, Equatable {
        var name: String
        var count: Int
        var label: String  // new field in v2
    }

    @Test("Round-trips a current-version file via encoder + decoder")
    func roundTripCurrent() throws {
        let body = BodyV2(name: "alpha", count: 7, label: "hello")
        let data = try VersionedEncoder.encode(body, version: 2)
        let decoded: BodyV2 = try VersionedDecoder.decodeCurrent(
            data,
            expectedVersion: 2
        )
        #expect(decoded == body)
    }

    @Test("peekVersion reads the version without forcing body decode")
    func peekVersion() throws {
        let body = BodyV2(name: "alpha", count: 7, label: "hello")
        let data = try VersionedEncoder.encode(body, version: 42)
        #expect(VersionedDecoder.peekVersion(data) == 42)
    }

    @Test("peekVersion returns nil for unversioned data")
    func peekUnversioned() throws {
        // Encode a bare BodyV1 (no version field).
        let data = try JSONEncoder().encode(BodyV1(name: "x", count: 0))
        #expect(VersionedDecoder.peekVersion(data) == nil)
    }

    @Test("decodeCurrent throws on version mismatch")
    func decodeCurrentThrows() throws {
        let body = BodyV1(name: "old", count: 3)
        let data = try VersionedEncoder.encode(body, version: 1)
        #expect(throws: VersionedCodableError.self) {
            let _: BodyV1 = try VersionedDecoder.decodeCurrent(
                data,
                expectedVersion: 2
            )
        }
    }

    @Test("decode dispatches to migrate closure on older version")
    func decodeMigratesOlder() throws {
        // Persisted as v1; we want to read as v2.
        let v1 = BodyV1(name: "alpha", count: 7)
        let data = try VersionedEncoder.encode(v1, version: 1)

        let migrated: BodyV2 = try VersionedDecoder.decode(
            data,
            currentVersion: 2
        ) { data, fromVersion in
            #expect(fromVersion == 1)
            let old: BodyV1 = try VersionedDecoder.decodeCurrent(
                data,
                expectedVersion: 1
            )
            // Migration: synthesize the new `label` field from `name`.
            return BodyV2(name: old.name, count: old.count, label: "migrated:\(old.name)")
        }

        #expect(migrated.name == "alpha")
        #expect(migrated.count == 7)
        #expect(migrated.label == "migrated:alpha")
    }

    @Test("decode short-circuits to current version when versions match")
    func decodeCurrentShortCircuits() throws {
        let body = BodyV2(name: "alpha", count: 7, label: "hello")
        let data = try VersionedEncoder.encode(body, version: 2)
        var migrateCalled = false
        let decoded: BodyV2 = try VersionedDecoder.decode(
            data,
            currentVersion: 2
        ) { _, _ in
            migrateCalled = true
            throw VersionedCodableError.missingVersion
        }
        #expect(decoded == body)
        #expect(migrateCalled == false)
    }

    @Test("decode dispatches to migrate when no version key is present")
    func decodeUnversionedTreatedAsZero() throws {
        // Bare-bodied data (no version) — treat as version 0 in the
        // migrate closure. This is the pattern for adopting versioning
        // on an existing unversioned format.
        let data = try JSONEncoder().encode(BodyV1(name: "legacy", count: 99))
        let migrated: BodyV2 = try VersionedDecoder.decode(
            data,
            currentVersion: 2
        ) { data, fromVersion in
            #expect(fromVersion == 0)
            let bare = try JSONDecoder().decode(BodyV1.self, from: data)
            return BodyV2(name: bare.name, count: bare.count, label: "promoted")
        }
        #expect(migrated.name == "legacy")
        #expect(migrated.label == "promoted")
    }
}
