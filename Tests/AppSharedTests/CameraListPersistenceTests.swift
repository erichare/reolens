import Testing
import Foundation
@testable import AppShared
import ReolinkAPI

/// 0.6.0 Slice 15c — `CameraListPersistence` is the carve-out of
/// CameraStore's iCloud encode / decode boundary. Tests exercise the
/// pure JSON path against an in-memory backend so the developer's
/// real iCloud storage stays untouched.
@MainActor
@Suite("CameraListPersistence")
struct CameraListPersistenceTests {

    // MARK: - Helpers

    /// In-memory `Backend` that lets each test see its own bytes.
    final class InMemoryBackend: CameraListPersistence.Backend {
        var buffer: Data?
        func read() -> Data? { buffer }
        func write(_ data: Data) { buffer = data }
    }

    private func makeEntry(name: String) -> CameraEntry {
        CameraEntry(
            id: UUID(),
            displayName: name,
            host: "10.0.0.1",
            port: 80,
            username: "admin",
            useHTTPS: false,
            preferredCodec: .h264
        )
    }

    // MARK: - Round trips

    @Test("save → load round-trips a one-entry list")
    func roundTripSingle() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        let entry = makeEntry(name: "Front Door")

        persistence.save([entry])
        let loaded = persistence.load()
        try? #require(loaded != nil)
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.id == entry.id)
        #expect(loaded?.first?.displayName == "Front Door")
    }

    @Test("save → load round-trips a multi-entry list and preserves order")
    func roundTripMulti() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        let a = makeEntry(name: "A")
        let b = makeEntry(name: "B")
        let c = makeEntry(name: "C")

        persistence.save([a, b, c])
        let loaded = persistence.load() ?? []
        #expect(loaded.map(\.id) == [a.id, b.id, c.id])
    }

    @Test("load returns nil when the backend is empty")
    func loadFromEmpty() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        #expect(persistence.load() == nil)
    }

    @Test("load returns nil when the backend has malformed bytes (no throw)")
    func loadMalformed() {
        let backend = InMemoryBackend()
        backend.buffer = Data([0xff, 0xfe, 0xfd])
        let persistence = CameraListPersistence(backend: backend)
        #expect(persistence.load() == nil)
    }

    // MARK: - hasChanged

    @Test("hasChanged is false when the in-memory list matches the backend")
    func hasChangedFalseWhenMatch() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        let entry = makeEntry(name: "Front")
        persistence.save([entry])
        #expect(!persistence.hasChanged(comparedTo: [entry]))
    }

    @Test("hasChanged is true when the backend has different entries")
    func hasChangedTrueWhenDiverged() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        let entryOnBackend = makeEntry(name: "On disk")
        persistence.save([entryOnBackend])
        let entryInMemory = makeEntry(name: "In memory")
        #expect(persistence.hasChanged(comparedTo: [entryInMemory]))
    }

    @Test("hasChanged is false when the backend is empty (no diff to publish)")
    func hasChangedFalseWhenEmpty() {
        let backend = InMemoryBackend()
        let persistence = CameraListPersistence(backend: backend)
        #expect(!persistence.hasChanged(comparedTo: [makeEntry(name: "any")]))
    }
}
