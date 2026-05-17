import Foundation
import CoreMedia

/// Abstraction over the thing that *produces* video samples
/// for `LiveVideoPlayer`'s display layer (and `AVAudioEngine`
/// for audio, once Phase 4c wires it through).
///
/// ## Why this exists
///
/// Reolens started life with a single video path: RTSP/RTP →
/// depacketize H.264 or H.265 NALUs → `CMSampleBuffer` →
/// `AVSampleBufferDisplayLayer`. The protocol abstracted here
/// keeps room for a second path (e.g. Baichuan `msg_id=3` frames
/// over the BcUdp-backed transport) that produces NALUs by
/// another means and feeds the same depacketize → `CMSampleBuffer`
/// → display layer pipeline.
///
/// Everything past "depacketize NALUs" is identical between
/// paths. Everything before it differs. `VideoSource` is the
/// seam — `LiveVideoPlayer` accepts any conformer.
///
/// ## Phasing
///
/// - **Phase 4a (this commit):** protocol + value types.
///   No conformers yet; the existing `LiveVideoPlayer` keeps
///   running against `RTSPClient` directly.
/// - **Phase 4b:** `RTSPVideoSource` lifts the current RTSP
///   playback path into a conformer. `LiveVideoPlayer`
///   refactors to consume the protocol instead of
///   `RTSPClient` directly. Existing first-frame latency
///   and snapshot semantics must stay byte-identical.
/// - **Phase 4c:** `BaichuanVideoSource` conforms by
///   consuming `msg_id=3` frames from a `BcMessageTransport`
///   and assembling them through the same NALU pipe.
///
/// ## Conformance contract
///
/// - `start()` brings the underlying transport up — RTSP
///   handshake, or remote-transport hole-punch — and begins
///   yielding samples on `samples` / `audio`. Throws if the
///   source can't be started.
/// - `stop()` is idempotent. After `stop()`, both streams
///   finish; further callers iterating the streams exit
///   their `for await` loops cleanly.
/// - A conformer that doesn't produce audio (e.g. the
///   current RTSP path) returns an `audio` stream that
///   finishes immediately. Callers must handle empty
///   streams without special-casing the source type.
/// - Samples are vended in source order. Out-of-order
///   delivery (UDP reordering, retransmits) is the
///   transport's problem to fix before the sample reaches
///   the protocol surface.
public protocol VideoSource: Sendable {
    /// Bring the underlying transport up. After this returns,
    /// samples may begin landing on `samples` / `audio` at any
    /// time. Throws if the source can't be started (no
    /// candidates, auth failure, etc.).
    func start() async throws

    /// Tear the source down. Idempotent. The `samples` /
    /// `audio` streams finish as a side effect.
    func stop() async

    /// Stream of video samples ready for display-layer
    /// enqueue or VT-session decode. Each `VideoSample`
    /// wraps a `CMSampleBuffer` containing one frame of
    /// encoded H.264 or H.265 (the display layer / VT
    /// decoder handle the actual pixel decode internally).
    /// The stream finishes when `stop()` is called or the
    /// underlying transport ends.
    var samples: AsyncStream<VideoSample> { get async }

    /// Stream of audio samples ready for an
    /// `AVAudioConverter` + `AVAudioEngine` sink. A source
    /// that doesn't produce audio (e.g. today's RTSP path
    /// — Reolens has never played camera audio) returns an
    /// immediately-finished stream.
    var audio: AsyncStream<AudioSample> { get async }
}

// MARK: - Value types

/// One frame of encoded video on its way to the display
/// pipeline. Wraps `CMSampleBuffer` because that's the type
/// the existing decoder + display layer consume directly —
/// no additional decode work happens at the protocol seam.
///
/// `CMSampleBuffer` isn't `Sendable` in Swift 6 strict
/// concurrency, but we never mutate it after creation — the
/// only operation is to hand it off to the display layer or
/// to VT. The `@unchecked Sendable` matches the same pattern
/// `LiveVideoPlayer.SendablePixelBuffer` uses for cross-
/// isolation `CVPixelBuffer` transfers.
public struct VideoSample: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    /// `true` when this sample starts a new IDR / keyframe.
    /// The display layer needs at least one keyframe before
    /// any subsequent P-frame becomes decodable; `LiveVideoPlayer`
    /// uses this to log first-frame timing and to gate
    /// resume-after-stall recovery.
    public let isKeyFrame: Bool

    public init(sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        self.sampleBuffer = sampleBuffer
        self.isKeyFrame = isKeyFrame
    }
}

/// One chunk of audio on its way to `AVAudioEngine`. The
/// `codec` field tells the consumer which decoder to apply;
/// today Baichuan delivers AAC and the RTSP path (if it ever
/// surfaces audio) speaks G.711.
public struct AudioSample: Sendable {
    public let data: Data
    public let codec: AudioCodec
    /// Presentation timestamp in the source's clock domain.
    /// Phase 4d's per-source clock-mapper normalises this to
    /// the engine's monotonic time-base. `nil` when the source
    /// doesn't expose a timestamp (e.g. probe frames during
    /// codec discovery).
    public let pts: CMTime?

    public init(data: Data, codec: AudioCodec, pts: CMTime?) {
        self.data = data
        self.codec = codec
        self.pts = pts
    }
}

/// Audio codecs Reolens may encounter on the wire. Kept
/// narrow on purpose — adding a codec is a one-line change
/// when the decoder support actually lands.
public enum AudioCodec: Sendable, Equatable {
    /// AAC-LC. Baichuan `msg_id=3` audio frames are AAC in
    /// the standard ADTS framing the official app speaks.
    case aac
    /// G.711 µ-law. Sometimes appears in RTSP audio tracks
    /// (older Reolink firmware). Not currently consumed by
    /// the player.
    case g711uLaw
    /// G.711 A-law. As above; some EU-region firmwares.
    case g711aLaw
}
