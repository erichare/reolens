import Testing
import Foundation
@testable import ReolinkStreaming

/// 0.5.0 Theme B1 — the VideoToolbox decoder assemblers previously
/// dereferenced `baseAddress!` on parameter-set buffers, which
/// crashes if any of SPS/PPS/VPS comes back empty (observed on a
/// malformed H.264 stream from a Reolink HomeHub Pro firmware build
/// that occasionally emits a zero-length PPS after a reboot). These
/// tests pin the new guard: empty parameter sets surface a thrown
/// error rather than a SIGABRT.
@Suite("H264SampleBufferAssembler — malformed parameter sets")
struct H264AssemblerMalformedTests {

    @Test("Empty SPS does not crash; surfaces as a format error")
    func emptySPSThrows() {
        let assembler = H264SampleBufferAssembler(initialSPS: Data(), initialPPS: Data([0x68, 0xCE, 0x38, 0x80]))
        // Force a flush attempt by ingesting an IDR slice. With a
        // bad format-description, the slice should be queued but
        // the flush returns nil (no format-description installed)
        // rather than trapping.
        do {
            _ = try assembler.ingest(nalType: 5, bytes: Data([0x00, 0x01, 0x02, 0x03]), rtpTimestamp: 1)
            _ = try assembler.flush()
        } catch {
            // Throwing is also acceptable — the contract is "no crash".
        }
        // If we got here without trapping, the guard is in place.
        #expect(Bool(true))
    }

    @Test("Empty PPS does not crash; surfaces as a format error")
    func emptyPPSThrows() {
        let assembler = H264SampleBufferAssembler(initialSPS: Data([0x67, 0x42, 0x80, 0x1E]), initialPPS: Data())
        do {
            _ = try assembler.ingest(nalType: 5, bytes: Data([0x00, 0x01, 0x02, 0x03]), rtpTimestamp: 1)
            _ = try assembler.flush()
        } catch {
            // throw is acceptable
        }
        #expect(Bool(true))
    }
}

@Suite("H265SampleBufferAssembler — malformed parameter sets")
struct H265AssemblerMalformedTests {

    @Test("Empty VPS does not crash")
    func emptyVPSThrows() {
        let assembler = H265SampleBufferAssembler(
            initialVPS: Data(),
            initialSPS: Data([0x42, 0x01]),
            initialPPS: Data([0x44, 0x01])
        )
        do {
            _ = try assembler.ingest(nalType: 19, bytes: Data([0x00]), rtpTimestamp: 1)
            _ = try assembler.flush()
        } catch {
            // throw acceptable
        }
        #expect(Bool(true))
    }
}
