import Testing
import Foundation
@testable import AppShared

/// Tests for `DiagnosticsCenterView.makeBundle(from:)` — the copy-
/// to-clipboard bundle generator. New in 0.6.1.
///
/// The view itself isn't unit-testable cheaply (it touches SwiftUI),
/// but the bundle string format is pure and easy to lock in. Mainly
/// regression coverage: the format is what users will paste into
/// support threads, so a change is visible.
@MainActor
@Suite("DiagnosticsCenterView.makeBundle")
struct DiagnosticsBundleTests {

    @Test("Empty record list produces a header-only bundle")
    func emptyBundle() {
        let bundle = DiagnosticsCenterView.makeBundle(from: [])
        #expect(bundle.contains("# Reolens diagnostic bundle"))
        #expect(bundle.contains("# 0 records"))
        #expect(bundle.contains("# Local to this device"))
    }

    @Test("Singular record line uses 'record' not 'records'")
    func singularPluralization() {
        let bundle = DiagnosticsCenterView.makeBundle(from: [sample()])
        #expect(bundle.contains("# 1 record\n") || bundle.hasSuffix("# 1 record"))
        // Defense: the next line should NOT pluralize.
        #expect(!bundle.contains("# 1 records"))
    }

    @Test("Record lines include ISO8601 timestamp + category + detail")
    func recordFormatting() {
        let when = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01
        let record = AppErrorRecord(
            timestamp: when,
            category: .network,
            detail: "Reolink error 503: timeout",
            userMessage: nil,
            context: "ingest.recording"
        )
        let bundle = DiagnosticsCenterView.makeBundle(from: [record])
        #expect(bundle.contains("2001-01-01T00:00:00Z"))
        #expect(bundle.contains("network"))
        #expect(bundle.contains("[ingest.recording]"))
        #expect(bundle.contains("Reolink error 503: timeout"))
    }

    @Test("Record without context omits the bracketed tag")
    func noContextNoBrackets() {
        let record = AppErrorRecord(
            timestamp: Date(),
            category: .auth,
            detail: "tokenExpired"
        )
        let bundle = DiagnosticsCenterView.makeBundle(from: [record])
        let lines = bundle.split(separator: "\n").map(String.init)
        // Find the record line (not a header line starting with #).
        guard let recordLine = lines.first(where: { !$0.hasPrefix("#") }) else {
            Issue.record("No record line found in bundle")
            return
        }
        #expect(!recordLine.contains("["))
        #expect(recordLine.contains("auth"))
    }

    private func sample() -> AppErrorRecord {
        AppErrorRecord(
            timestamp: Date(),
            category: .other,
            detail: "sample"
        )
    }
}
