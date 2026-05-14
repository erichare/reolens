import Testing
import Foundation
@testable import AppShared

/// Tests for the 0.6.1 `NLSearchHistory` carve-out.
@MainActor
@Suite("NLSearchHistory")
struct NLSearchHistoryTests {

    private func makeFreshDefaults() -> UserDefaults {
        let suiteName = "reolens-nl-search-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Empty history on a fresh install")
    func emptyOnFreshInstall() {
        let history = NLSearchHistory(defaults: makeFreshDefaults())
        #expect(history.entries.isEmpty)
    }

    @Test("Recording a query pushes it to the head")
    func recordPushesNewest() {
        let history = NLSearchHistory(defaults: makeFreshDefaults())
        history.record("vehicles today")
        history.record("people yesterday")
        #expect(history.entries == ["people yesterday", "vehicles today"])
    }

    @Test("Duplicate query (case-insensitive) rises to the top, not stacks")
    func duplicateRisesToTop() {
        let history = NLSearchHistory(defaults: makeFreshDefaults())
        history.record("vehicles today")
        history.record("people yesterday")
        history.record("Vehicles Today")
        #expect(history.entries.count == 2)
        #expect(history.entries.first == "Vehicles Today")
    }

    @Test("Empty / whitespace-only query is ignored")
    func emptyIgnored() {
        let history = NLSearchHistory(defaults: makeFreshDefaults())
        history.record("")
        history.record("   ")
        history.record("\n")
        #expect(history.entries.isEmpty)
    }

    @Test("Cap trims oldest entries on overflow")
    func capTrims() {
        let history = NLSearchHistory(defaults: makeFreshDefaults(), cap: 3)
        for i in 0..<5 {
            history.record("query-\(i)")
        }
        #expect(history.entries.count == 3)
        #expect(history.entries == ["query-4", "query-3", "query-2"])
    }

    @Test("Clear empties history and persists the empty state")
    func clear() {
        let defaults = makeFreshDefaults()
        let writer = NLSearchHistory(defaults: defaults)
        writer.record("disposable")
        writer.clear()

        let reader = NLSearchHistory(defaults: defaults)
        #expect(reader.entries.isEmpty)
    }

    @Test("History persists across instances pointing at same defaults")
    func persistenceRoundTrip() {
        let defaults = makeFreshDefaults()
        let writer = NLSearchHistory(defaults: defaults)
        writer.record("packages this week")
        writer.record("vehicles yesterday")

        let reader = NLSearchHistory(defaults: defaults)
        #expect(reader.entries == ["vehicles yesterday", "packages this week"])
    }
}
