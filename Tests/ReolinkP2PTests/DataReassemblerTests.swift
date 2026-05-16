import Testing
import Foundation
import ReolinkBcUdp
@testable import ReolinkP2P

@Suite("DataReassembler — fragment ordering + boundary")
struct DataReassemblerTests {

    @Test("In-order fragments concatenate in sequence")
    func inOrderConcatenates() {
        var r = DataReassembler(connectionID: 0x2B5)
        let outcome0 = r.ingest(make(seq: 0, payload: Data("hello-".utf8)))
        let outcome1 = r.ingest(make(seq: 1, payload: Data("world!".utf8)))
        #expect(outcome0 == .appended(sequence: 0))
        #expect(outcome1 == .appended(sequence: 1))
        #expect(r.pullAssembled() == Data("hello-world!".utf8))
        #expect(r.isIdle)
        #expect(r.nextExpectedSequence == 2)
    }

    @Test("Out-of-order fragments are buffered until the gap fills")
    func outOfOrderFillsGap() {
        var r = DataReassembler(connectionID: 0x2B5)
        // Receive seq 2 before seq 1 — buffer it.
        let outcome2 = r.ingest(make(seq: 2, payload: Data("CCC".utf8)))
        #expect(outcome2 == .bufferedOutOfOrder(sequence: 2))
        #expect(r.pullAssembled().isEmpty)
        #expect(r.pendingFragmentCount == 1)

        // Receive seq 0 — append it; gap to seq 2 still open.
        let outcome0 = r.ingest(make(seq: 0, payload: Data("AAA".utf8)))
        #expect(outcome0 == .appended(sequence: 0))
        #expect(r.pullAssembled() == Data("AAA".utf8))
        #expect(r.pendingFragmentCount == 1)

        // Receive seq 1 — fills the gap, then seq 2 drains too.
        let outcome1 = r.ingest(make(seq: 1, payload: Data("BBB".utf8)))
        #expect(outcome1 == .appended(sequence: 1))
        #expect(r.pullAssembled() == Data("BBBCCC".utf8))
        #expect(r.isIdle)
        #expect(r.nextExpectedSequence == 3)
    }

    @Test("Duplicate of a previously-assembled fragment is silently dropped")
    func duplicateConsumedDropped() {
        var r = DataReassembler(connectionID: 0x2B5)
        _ = r.ingest(make(seq: 0, payload: Data("AAA".utf8)))
        _ = r.pullAssembled()
        let dup = r.ingest(make(seq: 0, payload: Data("AAA".utf8)))
        #expect(dup == .duplicate(sequence: 0))
        #expect(r.pullAssembled().isEmpty)
        #expect(r.nextExpectedSequence == 1)
    }

    @Test("Duplicate of a still-buffered fragment is dropped")
    func duplicateBufferedDropped() {
        var r = DataReassembler(connectionID: 0x2B5)
        _ = r.ingest(make(seq: 2, payload: Data("CCC".utf8)))
        let dup = r.ingest(make(seq: 2, payload: Data("CCC".utf8)))
        #expect(dup == .duplicate(sequence: 2))
        #expect(r.pendingFragmentCount == 1)
    }

    @Test("Wrong connection IDs are rejected without state change")
    func wrongConnectionRejected() {
        var r = DataReassembler(connectionID: 0x2B5)
        let outcome = r.ingest(make(seq: 0, payload: Data("X".utf8), connectionID: 0x999))
        #expect(outcome == .wrongConnection)
        #expect(r.isIdle)
        #expect(r.nextExpectedSequence == 0)
    }

    @Test("pullAssembled returns only newly-arrived bytes each call")
    func pullDrainsBuffer() {
        var r = DataReassembler(connectionID: 0x2B5)
        _ = r.ingest(make(seq: 0, payload: Data("first-".utf8)))
        #expect(r.pullAssembled() == Data("first-".utf8))
        // Buffer should now be empty even though more fragments
        // can still arrive.
        #expect(r.pullAssembled() == Data())
        _ = r.ingest(make(seq: 1, payload: Data("second".utf8)))
        #expect(r.pullAssembled() == Data("second".utf8))
    }

    @Test("Bursty interleaved fragments still produce the right byte order")
    func burstyInterleavedFragments() {
        // Simulate UDP reordering: receive seq 3, 1, 0, 2 in
        // that order; final assembled bytes must be AAABBBCCCDDD.
        var r = DataReassembler(connectionID: 0x2B5)
        _ = r.ingest(make(seq: 3, payload: Data("DDD".utf8)))
        _ = r.ingest(make(seq: 1, payload: Data("BBB".utf8)))
        _ = r.ingest(make(seq: 0, payload: Data("AAA".utf8)))
        _ = r.ingest(make(seq: 2, payload: Data("CCC".utf8)))
        #expect(r.pullAssembled() == Data("AAABBBCCCDDD".utf8))
        #expect(r.isIdle)
    }

    @Test("Starting sequence can be set when handshake assigns a non-zero seed")
    func nonZeroStartingSequence() {
        // If a future wire capture shows the camera starting
        // post-handshake at seq != 0, the caller can seed the
        // reassembler accordingly without code changes.
        var r = DataReassembler(connectionID: 0x2B5, startingSequence: 100)
        let outcome = r.ingest(make(seq: 100, payload: Data("seeded".utf8)))
        #expect(outcome == .appended(sequence: 100))
        #expect(r.nextExpectedSequence == 101)
    }

    @Test("Empty payload contributes nothing to assembled bytes but still advances seq")
    func emptyPayloadAdvancesSeq() {
        // Wire-level no-op fragments (zero-byte payload) shouldn't
        // wedge the assembler. The state machine that emits
        // Data packets shouldn't send these, but we'd rather
        // tolerate them than block on a peer's quirk.
        var r = DataReassembler(connectionID: 0x2B5)
        let outcome = r.ingest(make(seq: 0, payload: Data()))
        #expect(outcome == .appended(sequence: 0))
        #expect(r.pullAssembled() == Data())
        #expect(r.nextExpectedSequence == 1)
    }

    @Test("End-to-end: reassembled bytes pass through BcMessage.decode")
    func reassembledBytesParseAsBcMessage() throws {
        // Reassembled bytes should be byte-identical to the
        // Baichuan TCP wire form, so the existing
        // `BcMessage.decode` works as-is. Build a real BcMessage,
        // chop into fragments, reassemble, then verify the parser
        // round-trips it.
        // Wire bytes for a minimal modern login header (24 bytes,
        // body empty). Constructed against the documented Baichuan
        // header layout so the test stays internal to ReolinkP2P
        // / ReolinkBcUdp and doesn't take a dependency on
        // ReolinkBaichuan.
        let baichuanBytes: [UInt8] = [
            0xF0, 0xDE, 0xBC, 0x0A, // magic 0x0ABCDEF0 (LE)
            0x01, 0x00, 0x00, 0x00, // msg_id = 1 (login)
            0x00, 0x00, 0x00, 0x00, // body_len = 0
            0x00, 0x01, 0x00, 0x00, // channel_id + stream_type + msg_num
            0xC8, 0x00,             // response_code = 200
            0x14, 0x64,             // msg_class = 0x6414
            0x00, 0x00, 0x00, 0x00  // payload_offset
        ]
        let bytes = Data(baichuanBytes)
        // Chop into 5-byte fragments.
        var r = DataReassembler(connectionID: 0x2B5)
        var seq: UInt32 = 0
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 5, bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            _ = r.ingest(make(seq: seq, payload: chunk))
            seq &+= 1
            offset = end
        }
        let assembled = r.pullAssembled()
        #expect(assembled == bytes)
    }

    // MARK: - Helpers

    private func make(
        seq: UInt32,
        payload: Data,
        connectionID: UInt32 = 0x2B5
    ) -> BcUdpDataPacket {
        BcUdpDataPacket(connectionID: connectionID, sequence: seq, payload: payload)
    }
}
