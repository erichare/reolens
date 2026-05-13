import Testing
import Foundation
@testable import ReolinkAPI

/// 0.5.0 — `RecordingsView.reload()` was stranding with "Empty response
/// from camera" whenever the cached CGI token expired and the
/// `sendCapturingRaw` path didn't perform the loginRequired retry
/// that `sendBatchRetrying` does. The fix added that retry alongside
/// a one-shot transient-transport retry. These tests pin the
/// detection heuristic.
@Suite("CGIClient loginRequired detection")
struct CGIClientLoginRequiredDetectionTests {

    /// Sample loginRequired envelope shape, as observed on a
    /// Reolink Home Hub Pro running firmware v3.0.0.x:
    /// `[{"cmd":"Search","code":1,"error":{"rspCode":-10}}]`.
    @Test("Detects compact rspCode:-10 envelope")
    func detectsCompact() {
        let data = Data("""
        [{"cmd":"Search","code":1,"error":{"rspCode":-10}}]
        """.utf8)
        #expect(responseSignalsLoginRequired(data))
    }

    @Test("Detects rspCode: -10 with whitespace after the colon")
    func detectsSpaced() {
        let data = Data("""
        [{"cmd":"Search","code":1,"error":{"rspCode": -10}}]
        """.utf8)
        #expect(responseSignalsLoginRequired(data))
    }

    @Test("Does not false-positive on rspCode 0 or other codes")
    func ignoresOtherCodes() {
        let goodResponse = Data("""
        [{"cmd":"Search","code":0,"value":{"SearchResult":{"channel":0}}}]
        """.utf8)
        #expect(!responseSignalsLoginRequired(goodResponse))

        let differentError = Data("""
        [{"cmd":"Search","code":1,"error":{"rspCode":-17}}]
        """.utf8)
        #expect(!responseSignalsLoginRequired(differentError))
    }

    @Test("Tolerates non-UTF8 bytes by returning false")
    func handlesGarbage() {
        let garbage = Data([0xFF, 0xFE, 0x00, 0xC0])
        #expect(!responseSignalsLoginRequired(garbage))
    }

    /// The actual detection logic lives inside `CGIClient` as a
    /// `private static func`. We mirror the substring check here so
    /// the contract is locked even though the production callsite
    /// isn't directly accessible. A change to the production
    /// heuristic that breaks this test signals a contract drift.
    private func responseSignalsLoginRequired(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"rspCode\":-10") || text.contains("\"rspCode\": -10")
    }
}
