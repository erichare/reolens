import Testing
import Foundation
import CoreMedia
@testable import ReolinkStreaming

/// Pin tests for the `VideoSource` protocol and its value
/// types. The protocol has no production conformers yet —
/// Phase 4b adds `RTSPVideoSource` and Phase 4c adds
/// `BaichuanVideoSource`. These tests guard the contract that
/// both will conform to.
@Suite("VideoSource — protocol contract (Phase 4a)")
struct VideoSourceTests {

    @Test("AudioCodec is comparable as a value")
    func audioCodecEquality() {
        #expect(AudioCodec.aac == AudioCodec.aac)
        #expect(AudioCodec.aac != AudioCodec.g711uLaw)
        #expect(AudioCodec.g711uLaw != AudioCodec.g711aLaw)
    }

    @Test("VideoSample preserves isKeyFrame flag")
    func videoSamplePreservesKeyFrame() throws {
        // A bare-bones CMSampleBuffer for the round-trip.
        // We don't need a real video format description here
        // — just confirm the struct vends back what was put
        // in.
        let buffer = try makeEmptySampleBuffer()
        let key = VideoSample(sampleBuffer: buffer, isKeyFrame: true)
        let nonKey = VideoSample(sampleBuffer: buffer, isKeyFrame: false)
        #expect(key.isKeyFrame == true)
        #expect(nonKey.isKeyFrame == false)
    }

    @Test("AudioSample carries data + codec + pts")
    func audioSampleStores() {
        let pts = CMTime(value: 12345, timescale: 90_000)
        let bytes = Data([0xFF, 0xF1, 0x50, 0x80])
        let sample = AudioSample(data: bytes, codec: .aac, pts: pts)
        #expect(sample.data == bytes)
        #expect(sample.codec == .aac)
        #expect(sample.pts == pts)
    }

    @Test("AudioSample.pts is optional")
    func audioSampleAllowsNilPTS() {
        let sample = AudioSample(data: Data(), codec: .aac, pts: nil)
        #expect(sample.pts == nil)
    }

    @Test("A trivial conformer can satisfy the protocol")
    func trivialConformerCompiles() async throws {
        // The real value of this test is the compile check —
        // if the protocol signature ever drifts from what
        // Phase 4b/4c expect, this stub will fail to compile
        // and we know to revisit the contract.
        let source: any VideoSource = EmptyVideoSource()
        try await source.start()
        let samples = await source.samples
        let audio = await source.audio
        var sampleCount = 0
        for await _ in samples { sampleCount += 1 }
        var audioCount = 0
        for await _ in audio { audioCount += 1 }
        await source.stop()
        #expect(sampleCount == 0)
        #expect(audioCount == 0)
    }

    // MARK: - Helpers

    /// Minimal empty CMSampleBuffer for the value-type tests.
    /// No format description, no data — just enough of a
    /// reference to round-trip through `VideoSample`.
    private func makeEmptySampleBuffer() throws -> CMSampleBuffer {
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        guard status == noErr, let sb else {
            Issue.record("CMSampleBufferCreate returned status \(status)")
            throw CocoaError(.featureUnsupported)
        }
        return sb
    }
}

/// Conformer used purely to prove the protocol can be
/// satisfied with finished streams (the contract Phase 4b's
/// audio surface uses, since today's RTSP path has no audio).
private struct EmptyVideoSource: VideoSource {
    func start() async throws {}
    func stop() async {}
    var samples: AsyncStream<VideoSample> {
        get async {
            AsyncStream { $0.finish() }
        }
    }
    var audio: AsyncStream<AudioSample> {
        get async {
            AsyncStream { $0.finish() }
        }
    }
}
