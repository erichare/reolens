import Testing
import Foundation
@testable import AppShared

/// Tests for `AppErrorRecorder`. New in 0.6.1.
///
/// Each test gets a freshly-keyed temporary file URL so there's no
/// shared state across tests. Mirrors `NotificationHistoryTests` —
/// same persistence posture, same isolation strategy.
@Suite("AppErrorRecorder — record, query, persistence")
struct AppErrorRecorderTests {

    private static func makeFreshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "reolens-app-error-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "app-errors.json")
    }

    // MARK: - Basic recording

    @Test("Empty recorder returns no snapshot")
    func emptySnapshot() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL())
        let items = await recorder.snapshot()
        #expect(items.isEmpty)
    }

    @Test("Recorded errors stored newest-first")
    func newestFirst() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL())
        await recorder.record(.network(.init(rspCode: 1, detail: "first")), context: "ctx1")
        await recorder.record(.streaming(.cancelled), context: "ctx2")
        await recorder.record(.auth(.tokenExpired), context: "ctx3")
        let items = await recorder.snapshot()
        #expect(items.count == 3)
        #expect(items[0].context == "ctx3")
        #expect(items[2].context == "ctx1")
    }

    @Test("Cap trims oldest records on overflow")
    func capTrims() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL(), cap: 3)
        for i in 0..<5 {
            await recorder.record(.other("entry-\(i)"))
        }
        let items = await recorder.snapshot()
        #expect(items.count == 3)
        // Newest-first: entry-4, entry-3, entry-2 survive
        #expect(items[0].detail.contains("entry-4"))
        #expect(items[2].detail.contains("entry-2"))
    }

    // MARK: - Persistence round-trip

    @Test("Records persist across actor instances pointed at same URL")
    func persistenceRoundTrip() async {
        let url = Self.makeFreshURL()
        let writer = AppErrorRecorder(storeURL: url)
        await writer.record(.schedule(.notSupported), context: "channel-1")
        await writer.record(.bookmark(.fileMissing))

        let reader = AppErrorRecorder(storeURL: url)
        let items = await reader.snapshot()
        #expect(items.count == 2)
        #expect(items.contains(where: { $0.category == .schedule }))
        #expect(items.contains(where: { $0.category == .bookmark }))
    }

    // MARK: - Filtering

    @Test("Query filters by category")
    func queryByCategory() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL())
        await recorder.record(.auth(.tokenExpired))
        await recorder.record(.notification(.permissionDenied))
        await recorder.record(.auth(.invalidCredentials))

        let auths = await recorder.query(category: .auth)
        #expect(auths.count == 2)
        #expect(auths.allSatisfy { $0.category == .auth })
    }

    @Test("Query filters by since date")
    func queryBySince() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL())
        let oldRecord = AppErrorRecord(
            timestamp: Date().addingTimeInterval(-3600),
            category: .other,
            detail: "old"
        )
        let newRecord = AppErrorRecord(
            timestamp: Date(),
            category: .other,
            detail: "new"
        )
        await recorder.record(oldRecord)
        await recorder.record(newRecord)

        let recent = await recorder.query(since: Date().addingTimeInterval(-60))
        #expect(recent.count == 1)
        #expect(recent.first?.detail == "new")
    }

    @Test("Counts groups records by category")
    func counts() async {
        let recorder = AppErrorRecorder(storeURL: Self.makeFreshURL())
        await recorder.record(.auth(.tokenExpired))
        await recorder.record(.auth(.invalidCredentials))
        await recorder.record(.notification(.throttled))

        let counts = await recorder.counts()
        #expect(counts[.auth] == 2)
        #expect(counts[.notification] == 1)
        #expect(counts[.network] == nil)
    }

    // MARK: - Clear

    @Test("Clear empties the cache and persisted store")
    func clear() async {
        let url = Self.makeFreshURL()
        let recorder = AppErrorRecorder(storeURL: url)
        await recorder.record(.other("disposable"))
        await recorder.clear()

        let items = await recorder.snapshot()
        #expect(items.isEmpty)

        // Re-open from disk to confirm persistence reflects clear
        let fresh = AppErrorRecorder(storeURL: url)
        let freshItems = await fresh.snapshot()
        #expect(freshItems.isEmpty)
    }

    // MARK: - Category mapping

    @Test("Category mapping is exhaustive and stable")
    func categoryMapping() {
        let cases: [(AppError, AppError.Category)] = [
            (.streaming(.cancelled), .streaming),
            (.auth(.tokenExpired), .auth),
            (.playback(.timeout), .playback),
            (.persistence(.write(path: "/tmp/x")), .persistence),
            (.notification(.relayUnreachable), .notification),
            (.schedule(.notSupported), .schedule),
            (.bookmark(.fileMissing), .bookmark),
            (.other("misc"), .other)
        ]
        for (error, expected) in cases {
            #expect(error.category == expected)
        }
    }

    @Test("LocalizedError provides user-facing copy")
    func errorDescription() {
        #expect(AppError.auth(.tokenExpired).errorDescription != nil)
        #expect(AppError.schedule(.notSupported).errorDescription != nil)
        #expect(AppError.bookmark(.fileMissing).errorDescription != nil)
    }

    // MARK: - H-1 redaction guard

    /// 0.6.1 H-1 — `categorizeBaichuanFailure(_:)` must never embed
    /// the raw error description (which can contain LAN IP /
    /// hostname material from `NWError`) in the resulting
    /// `AppError`'s `description`. Regression guard: feed a synthetic
    /// error whose description is a fake LAN endpoint and verify the
    /// IP doesn't survive the categorization.
    @Test("categorizeBaichuanFailure strips raw NWError-shaped strings")
    func categorizeStripsRawErrorString() {
        struct FakeNWError: Error, CustomStringConvertible {
            var description: String { "connection refused — 192.168.1.105:9000" }
            var localizedDescription: String { description }
        }
        let categorized = AppError.categorizeBaichuanFailure(FakeNWError())
        let detail = categorized.description
        #expect(!detail.contains("192.168.1.105"))
        #expect(!detail.contains("9000"))
    }
}
