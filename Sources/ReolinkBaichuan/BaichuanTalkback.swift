import Foundation
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "talk")

/// Two-way audio (talkback) over the Baichuan TCP channel.
///
/// Protocol shape (from Neolink's `talk.rs` + dissector entries 201/202):
///   1. Negotiate a talk session by sending `<TalkConfig>` (msg_id=201) with
///      audio parameters (sample rate, bits, channels, audio_type).
///   2. Stream ADPCM-encoded mic audio in `msg_id=202` frames.
///   3. Send `<TalkReset>` (msg_id=11) to stop.
///
/// Reolink cameras accept IMA/DVI ADPCM at 16 kHz mono, 16-bit input.
public actor BaichuanTalkbackSession {
    public enum State: Sendable, Equatable {
        case idle
        case capturing
        case stopped
        case failed(String)
    }

    private let client: BaichuanClient
    private let channelID: UInt8
    private var state: State = .idle
    private var engine: AVAudioEngine?
    private var msgNum: UInt16 = 0

    public init(client: BaichuanClient, channelID: UInt8) {
        self.client = client
        self.channelID = channelID
    }

    public func currentState() -> State { state }

    public func start() async throws {
        guard state == .idle else { return }
        log.info("Starting talkback on channel=\(self.channelID)")

        // 1. Negotiate the talk session.
        let configXML = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <TalkConfig version="1.1">
        <channelId>\(channelID)</channelId>
        <duplex>FDX</duplex>
        <audioStreamMode>followVideoStream</audioStreamMode>
        <audioConfig version="1.1">
        <audioType>adpcm</audioType>
        <sampleRate>16000</sampleRate>
        <samplePrecision>16</samplePrecision>
        <lengthPerEncoder>1024</lengthPerEncoder>
        <soundTrack>mono</soundTrack>
        </audioConfig>
        </TalkConfig>
        </body>
        """
        let configMsgNum = await client.nextMessageNumber()
        msgNum = configMsgNum
        let configHeader = BcHeader(
            msgID: BcMessageID.talkConfig,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: configMsgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let configMsg = BcMessage(header: configHeader, body: Data(configXML.utf8))
        let reply = try await client.sendAndAwait(configMsg, timeout: 8, stage: "talkConfig")
        guard reply.header.responseCode == 200 else {
            state = .failed("TalkConfig rejected with code=\(reply.header.responseCode)")
            throw BaichuanError.unexpectedReply(msgID: reply.header.msgID, code: reply.header.responseCode)
        }

        // 2. Start mic capture and stream ADPCM frames.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // Target format: 16 kHz mono 16-bit PCM. AVAudioEngine will route
        // through its converter when we install the tap with this format.
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        let bus: AVAudioNodeBus = 0
        input.installTap(onBus: bus, bufferSize: 1024, format: targetFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard let raw = buffer.int16ChannelData?[0] else { return }
            var samples = [Int16](repeating: 0, count: frames)
            for i in 0..<frames { samples[i] = raw[i] }
            Task { await self.streamFrame(pcm: samples) }
        }

        do {
            try engine.start()
        } catch {
            state = .failed("AVAudioEngine.start failed: \(error)")
            throw error
        }
        self.engine = engine
        state = .capturing
    }

    public func stop() async {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if state == .capturing {
            // Send TalkReset
            let resetHeader = BcHeader(
                msgID: BcMessageID.talkReset,
                bodyLength: 0,
                channelID: channelID,
                streamType: 0,
                msgNum: await client.nextMessageNumber(),
                responseCode: 0,
                msgClass: BcConstants.classModernWithOffset,
                payloadOffset: 0
            )
            _ = try? await client.sendAndAwait(BcMessage(header: resetHeader, body: Data()), timeout: 3, stage: "talkReset")
        }
        state = .stopped
    }

    private var adpcmEncoder = IMAADPCMEncoder()

    private func streamFrame(pcm: [Int16]) async {
        let encoded = adpcmEncoder.encode(pcm: pcm)
        // Reolink expects the ADPCM frame wrapped with a tiny 4-byte preamble
        // (length + flags). The exact layout is reverse-engineered; the most
        // commonly seen pattern is `[0x00, 0x01, len_lo, len_hi]` followed
        // by ADPCM bytes. If the camera rejects the frame, expect a 400 reply
        // — we don't await replies for streaming frames.
        var framed = Data()
        framed.append(0x00)
        framed.append(0x01)
        framed.append(UInt8(encoded.count & 0xFF))
        framed.append(UInt8((encoded.count >> 8) & 0xFF))
        framed.append(encoded)

        let header = BcHeader(
            msgID: BcMessageID.talk,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let msg = BcMessage(header: header, body: framed)
        // Fire-and-forget — talkback frames don't get replies in real time.
        Task { _ = try? await client.sendAndAwait(msg, timeout: 0.5, stage: "talkFrame") }
    }
}

/// IMA / DVI 4-bit ADPCM encoder (RFC 3551 §4.5.1). Encodes 16-bit signed
/// PCM samples into 4 bits per sample. Encoder state is preserved across
/// `encode(pcm:)` calls.
struct IMAADPCMEncoder {
    private var predictor: Int = 0
    private var stepIndex: Int = 0

    private static let stepIndexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8
    ]
    private static let stepSizeTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]

    mutating func encode(pcm: [Int16]) -> Data {
        var output = Data(capacity: pcm.count / 2)
        var nibbleHigh: UInt8 = 0
        var haveHigh = false
        for sample in pcm {
            let nibble = encodeSample(Int(sample))
            if haveHigh {
                let byte = nibbleHigh | (nibble << 4)
                output.append(byte)
                haveHigh = false
            } else {
                nibbleHigh = nibble & 0x0F
                haveHigh = true
            }
        }
        if haveHigh {
            output.append(nibbleHigh)
        }
        return output
    }

    private mutating func encodeSample(_ sample: Int) -> UInt8 {
        let step = Self.stepSizeTable[stepIndex]
        var diff = sample - predictor
        var code: Int = 0
        if diff < 0 {
            code = 8
            diff = -diff
        }
        var tempStep = step
        if diff >= tempStep {
            code |= 4
            diff -= tempStep
        }
        tempStep >>= 1
        if diff >= tempStep {
            code |= 2
            diff -= tempStep
        }
        tempStep >>= 1
        if diff >= tempStep {
            code |= 1
        }

        // Update predictor.
        var diffq = step >> 3
        if (code & 4) != 0 { diffq += step }
        if (code & 2) != 0 { diffq += step >> 1 }
        if (code & 1) != 0 { diffq += step >> 2 }
        if (code & 8) != 0 {
            predictor -= diffq
        } else {
            predictor += diffq
        }
        if predictor > 32767 { predictor = 32767 }
        if predictor < -32768 { predictor = -32768 }
        stepIndex += Self.stepIndexTable[code]
        if stepIndex < 0 { stepIndex = 0 }
        if stepIndex > 88 { stepIndex = 88 }
        return UInt8(code & 0x0F)
    }
}
