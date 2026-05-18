import Foundation
import Testing
@testable import AppShared

/// Tests the pure-function pieces of `StreamingEngine` — the
/// coverage tracker (used to know which byte ranges of a streaming
/// clip are already on disk) and the Content-Range header parser.
/// We don't exercise the URL session here; that would require a
/// stub server and the loader's correctness against real Reolink
/// firmware is regression-tested through manual verification.
@Suite("StreamingEngine — byte-range coverage tracker")
struct StreamingEngineCoverageTests {

    private func makeEngine() -> StreamingEngine {
        // The upstream URL doesn't matter for these tests — we only
        // exercise the in-memory coverage math.
        StreamingEngine(upstreamURL: URL(string: "https://hub.test/clip.mp4")!)
    }

    @Test("Adding a fresh range covers exactly its bytes")
    func freshRange() async {
        let engine = makeEngine()
        let added = await engine.addCoverage(0..<100)
        #expect(added == 100)
        let bytes = await engine.bytesReceived
        // bytesReceived doesn't change because addCoverage's caller
        // is responsible for incrementing — but the coverage list
        // should now show the range.
        #expect(bytes == 0) // Not bumped automatically in the test seam.
        let missing = await engine.missingRanges(within: 0..<100)
        #expect(missing.isEmpty)
    }

    @Test("Overlapping range only credits new bytes")
    func overlappingRangeCredit() async {
        let engine = makeEngine()
        _ = await engine.addCoverage(0..<100)
        let added = await engine.addCoverage(50..<150)
        // [0, 100) and [50, 150) overlap on [50, 100). New bytes: 50.
        #expect(added == 50)
    }

    @Test("Disjoint adds merge into a sorted list")
    func disjointMerge() async {
        let engine = makeEngine()
        _ = await engine.addCoverage(200..<300)
        _ = await engine.addCoverage(0..<100)
        let missing = await engine.missingRanges(within: 0..<300)
        // Holes: [100, 200).
        #expect(missing == [100..<200])
    }

    @Test("Adjacent ranges merge into one block")
    func adjacentMerge() async {
        let engine = makeEngine()
        _ = await engine.addCoverage(0..<100)
        _ = await engine.addCoverage(100..<200)
        let missing = await engine.missingRanges(within: 0..<200)
        #expect(missing.isEmpty)
    }

    @Test("missingRanges within a fully-covered span returns empty")
    func fullyCovered() async {
        let engine = makeEngine()
        _ = await engine.addCoverage(0..<1000)
        let missing = await engine.missingRanges(within: 100..<500)
        #expect(missing.isEmpty)
    }

    @Test("missingRanges within a partly-covered span returns holes only")
    func partlyCovered() async {
        let engine = makeEngine()
        _ = await engine.addCoverage(0..<100)
        _ = await engine.addCoverage(300..<400)
        let missing = await engine.missingRanges(within: 0..<500)
        // Holes: [100, 300) and [400, 500).
        #expect(missing == [100..<300, 400..<500])
    }
}

@Suite("StreamingEngine — Content-Range parsing")
struct StreamingEngineHeaderTests {

    @Test("Parses canonical Content-Range header")
    func canonical() {
        let total = StreamingEngine.parseContentRangeTotal(header: "bytes 0-1023/45678")
        #expect(total == 45678)
    }

    @Test("Returns nil for missing header")
    func nilHeader() {
        #expect(StreamingEngine.parseContentRangeTotal(header: nil) == nil)
    }

    @Test("Returns nil when total is unknown (asterisk)")
    func unknownTotal() {
        let total = StreamingEngine.parseContentRangeTotal(header: "bytes 0-1023/*")
        #expect(total == nil)
    }

    @Test("Returns nil for malformed header")
    func malformed() {
        #expect(StreamingEngine.parseContentRangeTotal(header: "bytes 0-1023") == nil)
        #expect(StreamingEngine.parseContentRangeTotal(header: "completely wrong") == nil)
    }
}
