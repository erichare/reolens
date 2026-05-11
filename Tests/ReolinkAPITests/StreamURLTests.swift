import Testing
import Foundation
@testable import ReolinkAPI

@Suite("Stream URL building")
struct StreamURLTests {

    let creds = CameraCredentials(host: "192.168.1.100", port: 80, username: "admin", password: "p@ss/word")

    @Test func builds_rtsp_h264_main_channel0() {
        let urls = StreamURLs(credentials: creds)
        let url = urls.rtsp(channel: 0, stream: .main, codec: .h264)
        #expect(url.absoluteString.hasPrefix("rtsp://"))
        #expect(url.absoluteString.contains("@192.168.1.100:554/h264Preview_01_main"))
    }

    @Test func builds_rtsp_h265_sub_channel15() {
        let urls = StreamURLs(credentials: creds)
        let url = urls.rtsp(channel: 15, stream: .sub, codec: .h265)
        #expect(url.absoluteString.contains("/h265Preview_16_sub"))
    }

    @Test func snapshot_url_uses_token_when_provided() {
        let urls = StreamURLs(credentials: creds)
        let url = urls.snapshot(channel: 0, token: "abc123")
        #expect(url.absoluteString.contains("cmd=Snap"))
        #expect(url.absoluteString.contains("channel=0"))
        #expect(url.absoluteString.contains("token=abc123"))
        #expect(!url.absoluteString.contains("password="))
    }

    @Test func snapshot_url_falls_back_to_user_pass() {
        let urls = StreamURLs(credentials: creds)
        let url = urls.snapshot(channel: 0, token: nil)
        #expect(url.absoluteString.contains("user=admin"))
        #expect(url.absoluteString.contains("password="))
    }

    @Test func flv_url_formats_channel_and_stream() {
        let urls = StreamURLs(credentials: creds)
        let url = urls.flv(channel: 1, stream: .sub)
        let s = url.absoluteString
        #expect(s.contains("stream=channel1_sub.bcs"))
        #expect(s.contains("app=bcs"))
    }

    @Test func token_expiry_logic() {
        let token = Token(name: "x", issuedAt: Date(), leaseTime: 100)
        #expect(!token.isExpiring(within: 30))
        #expect(token.isExpiring(within: 200))
    }

    @Test func cgi_url_format() {
        let url = creds.cgiURL
        #expect(url.absoluteString == "http://192.168.1.100/cgi-bin/api.cgi")
    }

    @Test func cgi_url_https_default_port() {
        let httpsCreds = CameraCredentials(host: "192.168.1.100", port: 443, username: "u", password: "p", useHTTPS: true)
        #expect(httpsCreds.baseURL.absoluteString == "https://192.168.1.100")
    }
}
