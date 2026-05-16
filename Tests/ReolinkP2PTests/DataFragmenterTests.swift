import Testing
import Foundation
import ReolinkBcUdp
@testable import ReolinkP2P

@Suite("DataFragmenter — split + sequence")
struct DataFragmenterTests {

    @Test("Payload shorter than the MTU produces exactly one fragment")
    func smallPayloadOneFragment() {
        var f = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 1350)
        let payload = Data(repeating: 0x42, count: 100)
        let fragments = f.fragment(payload)
        #expect(fragments.count == 1)
        #expect(fragments[0].connectionID == 0xABCD)
        #expect(fragments[0].sequence == 0)
        #expect(fragments[0].payload == payload)
        #expect(f.nextSequence == 1)
    }

    @Test("Payload exactly equal to the MTU still produces one fragment")
    func mtuBoundaryOneFragment() {
        var f = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 100)
        let payload = Data(repeating: 0x55, count: 100)
        let fragments = f.fragment(payload)
        #expect(fragments.count == 1)
        #expect(fragments[0].payload.count == 100)
    }

    @Test("Payload larger than the MTU splits into multiple sequential fragments")
    func largePayloadSplits() {
        var f = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 100)
        let payload = Data(repeating: 0xAA, count: 250)
        let fragments = f.fragment(payload)
        #expect(fragments.count == 3)
        #expect(fragments[0].sequence == 0)
        #expect(fragments[0].payload.count == 100)
        #expect(fragments[1].sequence == 1)
        #expect(fragments[1].payload.count == 100)
        #expect(fragments[2].sequence == 2)
        #expect(fragments[2].payload.count == 50)
        #expect(f.nextSequence == 3)
    }

    @Test("Successive fragment() calls keep the sequence space monotonic")
    func sequenceContinuesAcrossCalls() {
        var f = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 100)
        _ = f.fragment(Data(count: 250))   // produces seq 0, 1, 2
        let next = f.fragment(Data(count: 50))
        #expect(next.count == 1)
        #expect(next[0].sequence == 3)
        #expect(f.nextSequence == 4)
    }

    @Test("Empty payload produces zero fragments and does not advance sequence")
    func emptyProducesNothing() {
        var f = DataFragmenter(connectionID: 0xABCD)
        let fragments = f.fragment(Data())
        #expect(fragments.isEmpty)
        #expect(f.nextSequence == 0)
    }

    @Test("Custom starting sequence is honored")
    func customStartingSequence() {
        var f = DataFragmenter(
            connectionID: 0xABCD,
            maxPayloadBytesPerPacket: 100,
            startingSequence: 42
        )
        let fragments = f.fragment(Data(count: 150))
        #expect(fragments[0].sequence == 42)
        #expect(fragments[1].sequence == 43)
        #expect(f.nextSequence == 44)
    }

    @Test("Round-trip with DataReassembler reconstructs the original bytes")
    func roundTripWithReassembler() {
        // Real-world byte pattern (varies per index) so the
        // round-trip is sensitive to order errors.
        let original = Data((0..<2700).map { UInt8($0 & 0xFF) })
        var fragmenter = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 1350)
        let fragments = fragmenter.fragment(original)
        #expect(fragments.count == 2)   // 2700 / 1350 = 2 exactly

        var reassembler = DataReassembler(connectionID: 0xABCD)
        for packet in fragments {
            _ = reassembler.ingest(packet)
        }
        #expect(reassembler.pullAssembled() == original)
    }

    @Test("Round-trip survives shuffled fragments")
    func roundTripWithShuffledOrder() {
        let original = Data((0..<3500).map { UInt8($0 & 0xFF) })
        var fragmenter = DataFragmenter(connectionID: 0xABCD, maxPayloadBytesPerPacket: 700)
        let fragments = fragmenter.fragment(original)
        #expect(fragments.count == 5)

        // Deliver out of order: last → first → middle.
        let shuffled = [fragments[4], fragments[0], fragments[3], fragments[1], fragments[2]]
        var reassembler = DataReassembler(connectionID: 0xABCD)
        for packet in shuffled {
            _ = reassembler.ingest(packet)
        }
        #expect(reassembler.pullAssembled() == original)
    }
}
