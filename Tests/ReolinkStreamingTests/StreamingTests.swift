import Testing
import Foundation
@testable import ReolinkStreaming

@Suite("SDP parsing")
struct SDPTests {

    @Test func parses_real_reolink_home_hub_sdp() {
        // Verbatim from a Reolink Home Hub Pro DESCRIBE response (May 2026).
        let sdp = """
        v=0
        o=- 1778403679040442 1 IN IP4 10.0.0.1
        s=Session streamed by "preview"
        i=reolink rtsp stream
        t=0 0
        a=tool:Reolink Streaming Media 2024.12.11
        a=type:broadcast
        a=control:*
        a=range:npt=now-
        a=x-qt-text-nam:Session streamed by "preview"
        m=video 0 RTP/AVP 96
        c=IN IP4 0.0.0.0
        b=AS:8192
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1;profile-level-id=4D0029;sprop-parameter-sets=Z00AKZ2oFAFuQA==,aO48gA==
        a=control:trackID=1
        m=audio 0 RTP/AVP 97
        a=rtpmap:97 MPEG4-GENERIC/16000
        a=control:trackID=2
        """
        let parsed = SDPParser.parse(sdp)
        #expect(parsed.firstVideoTrack != nil, "Hub SDP must yield a video track")
        #expect(parsed.firstVideoTrack?.rtpmap?.codec == "H264")
        #expect(parsed.firstVideoTrack?.control == "trackID=1")
        #expect(parsed.firstVideoTrack?.h264ParameterSets != nil)
    }

    @Test func parses_with_crlf_line_endings() {
        let sdp = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=1\r\n"
        let parsed = SDPParser.parse(sdp)
        #expect(parsed.firstVideoTrack != nil)
        #expect(parsed.firstVideoTrack?.rtpmap?.codec == "H264")
    }

    @Test func parses_with_trailing_nul_byte() {
        // Reolink firmware sometimes pads body to declared Content-Length with NULs.
        let sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=1\r\n\0\0\0"
        let parsed = SDPParser.parse(sdp)
        #expect(parsed.firstVideoTrack != nil)
    }

    @Test func parses_video_track_with_h264_params() {
        let sdp = """
        v=0
        o=- 0 0 IN IP4 0.0.0.0
        s=Reolink Live
        t=0 0
        m=video 0 RTP/AVP 96
        a=control:trackID=1
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1;profile-level-id=4D0029;sprop-parameter-sets=Z00AKZ2oFAFuQA==,aO48gA==
        m=audio 0 RTP/AVP 97
        a=control:trackID=2
        a=rtpmap:97 MPEG4-GENERIC/16000
        """
        let parsed = SDPParser.parse(sdp)
        let video = parsed.firstVideoTrack
        #expect(video != nil)
        #expect(video?.rtpmap?.codec == "H264")
        #expect(video?.rtpmap?.payloadType == 96)
        #expect(video?.rtpmap?.clockRate == 90_000)
        #expect(video?.control == "trackID=1")
        #expect(video?.fmtp["packetization-mode"] == "1")
        let sets = video?.h264ParameterSets
        #expect(sets != nil)
        #expect(sets?.sps.count ?? 0 > 0)
        #expect(sets?.pps.count ?? 0 > 0)
    }
}

@Suite("RTP parsing")
struct RTPTests {

    @Test func parses_basic_packet() {
        // Version=2, payload type=96, seq=0x1234, ts=0xDEADBEEF, payload "hi"
        var raw = Data([0x80, 0x60, 0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00])
        raw.append(Data("hi".utf8))
        let packet = RTPPacket(raw: raw)
        #expect(packet != nil)
        #expect(packet?.sequenceNumber == 0x1234)
        #expect(packet?.timestamp == 0xDEADBEEF)
        #expect(packet?.payloadType == 96)
        #expect(packet?.payload == Data("hi".utf8))
        #expect(packet?.marker == false)
    }

    @Test func parses_marker_and_padding() {
        // Padding bit set; one byte of padding (`0x01` at end).
        var header: [UInt8] = [0xA0, 0xE0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        var raw = Data(header)
        raw.append(0xAB)
        raw.append(0x01) // padding length byte
        let packet = RTPPacket(raw: raw)
        #expect(packet?.marker == true)
        #expect(packet?.payload == Data([0xAB]))
        _ = header
    }
}

@Suite("H.264 FU-A reassembly")
struct H264DepacketizerTests {

    @Test func single_nal_unit_passes_through() {
        var dep = H264Depacketizer()
        let nal = Data([0x65, 0x88, 0x84, 0x21]) // type 5 (IDR)
        let units = dep.depacketize(nal)
        #expect(units.count == 1)
        #expect(units.first?.nalType == 5)
        #expect(units.first?.isKeyframe == true)
        #expect(units.first?.bytes == nal)
    }

    @Test func fua_reassembly_across_three_fragments() {
        var dep = H264Depacketizer()
        // FU indicator: NRI=3, type=28; FU header: S=1, type=5 (IDR)
        let start = Data([0x7C, 0x85, 0xAA, 0xBB])
        let middle = Data([0x7C, 0x05, 0xCC, 0xDD])
        // End fragment: E=1
        let end = Data([0x7C, 0x45, 0xEE, 0xFF])
        #expect(dep.depacketize(start).isEmpty)
        #expect(dep.depacketize(middle).isEmpty)
        let units = dep.depacketize(end)
        #expect(units.count == 1)
        let nal = units[0]
        // Reconstructed NAL header: NRI bits from FU indicator (top 3) + type from FU header.
        // 0x7C & 0xE0 = 0x60; type = 5; header = 0x65.
        #expect(nal.bytes.first == 0x65)
        #expect(nal.bytes.count == 1 + 6) // header + 3 chunks of 2 bytes payload
        #expect(nal.bytes.suffix(6) == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        #expect(nal.isKeyframe)
    }

    @Test func stap_a_splits_multiple_nals() {
        var dep = H264Depacketizer()
        // STAP-A header byte (24) + (len=2, 0x67 0x42) + (len=2, 0x68 0xCE)
        let stap = Data([0x78, 0x00, 0x02, 0x67, 0x42, 0x00, 0x02, 0x68, 0xCE])
        let units = dep.depacketize(stap)
        #expect(units.count == 2)
        #expect(units[0].nalType == 7) // SPS
        #expect(units[1].nalType == 8) // PPS
    }
}

@Suite("H.265 depacketization")
struct H265DepacketizerTests {

    @Test func single_nal_unit_passes_through() {
        var dep = H265Depacketizer()
        // Type 19 (IDR_W_RADL): byte0 = (19 << 1) = 0x26
        let nal = Data([0x26, 0x01, 0xAA, 0xBB, 0xCC])
        let units = dep.depacketize(nal)
        #expect(units.count == 1)
        #expect(units.first?.nalType == 19)
        #expect(units.first?.isKeyframe == true)
        #expect(units.first?.bytes == nal)
    }

    @Test func fu_reassembly_across_three_fragments() {
        var dep = H265Depacketizer()
        // PayloadHdr: type=49 (FU). byte0 = (49 << 1) = 0x62
        // FU header: S=1, FuType=19 (IDR) → 0x80 | 19 = 0x93
        let start = Data([0x62, 0x01, 0x93, 0xAA, 0xBB])
        let middle = Data([0x62, 0x01, 0x13, 0xCC, 0xDD])  // S=0,E=0,FuType=19
        let end = Data([0x62, 0x01, 0x53, 0xEE, 0xFF])    // E=1, FuType=19
        #expect(dep.depacketize(start).isEmpty)
        #expect(dep.depacketize(middle).isEmpty)
        let units = dep.depacketize(end)
        #expect(units.count == 1)
        let nal = units[0]
        #expect(nal.nalType == 19)
        #expect(nal.isKeyframe)
        // Reconstructed header: type=19, F=0, LayerId=0, TID=1 → 0x26, 0x01
        #expect(nal.bytes.prefix(2) == Data([0x26, 0x01]))
        #expect(nal.bytes.suffix(6) == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    }

    @Test func ap_splits_multiple_nals() {
        var dep = H265Depacketizer()
        // AP header: type=48 → byte0 = (48 << 1) = 0x60
        // Then [size:2][nal] pairs.
        // First NAL: VPS (type 32), header bytes (32<<1)=0x40, 0x01 + 2 payload bytes → size=4
        // Second NAL: SPS (type 33), header bytes (33<<1)=0x42, 0x01 + 2 payload bytes → size=4
        let ap = Data([0x60, 0x01,
                       0x00, 0x04, 0x40, 0x01, 0xAA, 0xBB,
                       0x00, 0x04, 0x42, 0x01, 0xCC, 0xDD])
        let units = dep.depacketize(ap)
        #expect(units.count == 2)
        #expect(units[0].nalType == 32)  // VPS
        #expect(units[1].nalType == 33)  // SPS
    }
}

@Suite("RTSP URI cleaning")
struct URICleaningTests {
    @Test func strips_user_pass_from_uri() {
        let url = URL(string: "rtsp://admin:s3cret@192.168.1.10:554/h264Preview_01_main")!
        let clean = RTSPClient.makeCleanURI(url)
        #expect(clean == "rtsp://192.168.1.10:554/h264Preview_01_main")
    }

    @Test func leaves_uri_without_creds_alone() {
        let url = URL(string: "rtsp://192.168.1.10:554/h264Preview_01_main")!
        let clean = RTSPClient.makeCleanURI(url)
        #expect(clean == "rtsp://192.168.1.10:554/h264Preview_01_main")
    }
}

@Suite("RTSP digest auth")
struct DigestAuthTests {

    @Test func parses_typical_challenge() {
        let header = "Digest realm=\"IP Camera\", nonce=\"abcd1234\", qop=\"auth\", algorithm=MD5"
        let challenge = DigestChallenge(headerValue: header)
        #expect(challenge != nil)
        #expect(challenge?.realm == "IP Camera")
        #expect(challenge?.nonce == "abcd1234")
        #expect(challenge?.qop == "auth")
        #expect(challenge?.algorithm == "MD5")
    }

    @Test func response_differs_per_method_and_uri() {
        // Regression: caching the Authorization header across requests was breaking
        // SETUP because HA2 = MD5(method:uri) varies. Two different method+uri
        // combos with the same challenge MUST produce different `response=` hashes.
        let challenge = DigestChallenge(headerValue: "Digest realm=\"r\", nonce=\"n\", qop=\"auth\"")!
        let describe = DigestAuth.response(
            username: "u", password: "p", method: "DESCRIBE",
            uri: "rtsp://host/h264Preview_01_main",
            challenge: challenge, cnonce: "cnonce", nc: "00000001"
        )
        let setup = DigestAuth.response(
            username: "u", password: "p", method: "SETUP",
            uri: "rtsp://host/h264Preview_01_main/trackID=1",
            challenge: challenge, cnonce: "cnonce", nc: "00000002"
        )
        let describeHash = describe.range(of: "response=\"[^\"]+\"", options: .regularExpression).map { describe[$0] }
        let setupHash = setup.range(of: "response=\"[^\"]+\"", options: .regularExpression).map { setup[$0] }
        #expect(describeHash != nil && setupHash != nil)
        #expect(describeHash != setupHash, "response hash must change when method/uri changes")
        #expect(setup.contains("nc=00000002"))
        #expect(setup.contains("uri=\"rtsp://host/h264Preview_01_main/trackID=1\""))
    }

    @Test func computes_rfc2617_response() {
        // Vector from RFC 2617 section 3.5 (slightly adapted).
        let challenge = DigestChallenge(headerValue: "Digest realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\"")!
        let header = DigestAuth.response(
            username: "Mufasa",
            password: "Circle Of Life",
            method: "DESCRIBE",
            uri: "rtsp://example.com/stream",
            challenge: challenge
        )
        #expect(header.hasPrefix("Digest "))
        #expect(header.contains("username=\"Mufasa\""))
        #expect(header.contains("response="))
    }
}

@Suite("RTSP message parsing")
struct RTSPMessageTests {

    @Test func parses_200_with_content_length() {
        let raw = Data("""
        RTSP/1.0 200 OK\r
        CSeq: 2\r
        Content-Type: application/sdp\r
        Content-Length: 5\r
        \r
        helloEXTRA
        """.utf8)
        let parsed = RTSPMessageParser.parse(raw)
        #expect(parsed != nil)
        #expect(parsed?.0.statusCode == 200)
        #expect(parsed?.0.header("Content-Type") == "application/sdp")
        #expect(parsed?.0.body == "hello")
        #expect(parsed?.consumed == raw.count - 5)
    }

    @Test func returns_nil_when_incomplete() {
        let raw = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
        #expect(RTSPMessageParser.parse(raw) == nil)
    }

    /// Regression for "leaked continuation": after the first `removeFirst`, Data's
    /// startIndex becomes non-zero. The parser must still report `consumed` as a
    /// byte COUNT (suitable for `removeFirst`), not an absolute index.
    @Test func parses_second_response_after_removeFirst() {
        let first = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"
        let second = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 5\r\n\r\nhello"
        var buffer = Data((first + second).utf8)

        let (firstResp, c1) = try! #require(RTSPMessageParser.parse(buffer))
        #expect(firstResp.statusCode == 200)
        // Drop the first response just like RTSPClient does.
        buffer.removeFirst(c1)
        // The buffer's startIndex is now > 0 inside Data.

        let (secondResp, c2) = try! #require(RTSPMessageParser.parse(buffer))
        #expect(secondResp.statusCode == 200)
        #expect(secondResp.body == "hello")
        #expect(c2 == buffer.count) // we should have consumed the full remaining buffer
        buffer.removeFirst(c2)
        #expect(buffer.isEmpty)
    }

    @Test func parses_response_appended_after_removeFirst() {
        let first = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"
        var buffer = Data(first.utf8)
        let (_, c1) = try! #require(RTSPMessageParser.parse(buffer))
        buffer.removeFirst(c1)
        #expect(buffer.isEmpty)

        // Now append a new response — startIndex is non-zero internally.
        buffer.append(Data("RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Digest realm=\"x\", nonce=\"y\"\r\n\r\n".utf8))
        let (resp, c2) = try! #require(RTSPMessageParser.parse(buffer))
        #expect(resp.statusCode == 401)
        #expect(resp.header("WWW-Authenticate")?.contains("Digest") == true)
        buffer.removeFirst(c2)
        #expect(buffer.isEmpty)
    }
}
