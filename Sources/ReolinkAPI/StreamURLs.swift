import Foundation

/// Builds RTSP/RTMP/snapshot/FLV URLs for a Reolink camera or NVR channel.
public struct StreamURLs: Sendable {

    public let credentials: CameraCredentials

    public init(credentials: CameraCredentials) {
        self.credentials = credentials
    }

    /// Ordered candidate URLs to try for a live view, in order of preference.
    ///
    /// Real-world Reolink Home Hub channels are not uniform — doorbells, Duo cameras,
    /// and TrackMix models expose their "main" view at non-standard paths. We try the
    /// common ones in priority order; the RTSP player walks through them and uses
    /// whichever responds with a video track.
    public func candidatesForLive(channel: Int = 0, stream: StreamKind = .main, rtspPort: Int = 554) -> [URL] {
        switch stream {
        case .sub:
            return [
                rtsp(channel: channel, stream: .sub, codec: .h264, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .sub, codec: .h265, rtspPort: rtspPort)
            ]
        case .main:
            return [
                rtsp(channel: channel, stream: .main, codec: .h265, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .main, codec: .h264, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .ext, codec: .h264, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .ext, codec: .h265, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .sub, codec: .h264, rtspPort: rtspPort)
            ]
        case .ext:
            return [
                rtsp(channel: channel, stream: .ext, codec: .h264, rtspPort: rtspPort),
                rtsp(channel: channel, stream: .ext, codec: .h265, rtspPort: rtspPort)
            ]
        }
    }

    /// Per-channel RTSP URL.
    /// Channel is 1-indexed in the path: channel 0 → `01`, channel 15 → `16`.
    /// For H.265 main streams on 4K/8MP cameras, set `codec` to `.h265`.
    public func rtsp(channel: Int = 0, stream: StreamKind = .main, codec: VideoCodec = .h264, rtspPort: Int = 554) -> URL {
        let prefix = codec == .h265 ? "h265Preview" : "h264Preview"
        let cc = String(format: "%02d", channel + 1)
        let user = credentials.username.addingPercentEncoding(withAllowedCharacters: .reolinkURLUser) ?? credentials.username
        let pass = credentials.password.addingPercentEncoding(withAllowedCharacters: .reolinkURLPassword) ?? credentials.password
        let s = stream == .ext ? "ext" : stream.rawValue
        let host = credentials.host
        let urlString = "rtsp://\(user):\(pass)@\(host):\(rtspPort)/\(prefix)_\(cc)_\(s)"
        return URL(string: urlString)!
    }

    /// JPEG snapshot URL using the `cmd=Snap` GET.
    /// Pass the active token; if nil, embeds `user=` / `password=` as fallback.
    public func snapshot(channel: Int = 0, token: String? = nil) -> URL {
        var components = URLComponents(url: credentials.cgiURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "cmd", value: "Snap"),
            URLQueryItem(name: "channel", value: String(channel)),
            URLQueryItem(name: "rs", value: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        ]
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        } else {
            items.append(URLQueryItem(name: "user", value: credentials.username))
            items.append(URLQueryItem(name: "password", value: credentials.password))
        }
        components.queryItems = items
        return components.url!
    }

    /// HTTP URL for downloading a recording file from the hub/NVR storage.
    /// AVPlayer can stream this directly — Reolink supports HTTP Range requests
    /// for these endpoints, so you don't need to fully download before play.
    public func recordingDownload(
        source: String,
        output: String? = nil,
        token: String? = nil
    ) -> URL {
        var components = URLComponents(url: credentials.cgiURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "cmd", value: "Download"),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "output", value: output ?? source)
        ]
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        } else {
            items.append(URLQueryItem(name: "user", value: credentials.username))
            items.append(URLQueryItem(name: "password", value: credentials.password))
        }
        components.queryItems = items
        return components.url!
    }

    /// FLV-over-HTTP playback URL (works on many models when RTSP is blocked).
    public func flv(channel: Int = 0, stream: StreamKind = .main) -> URL {
        var components = URLComponents(url: credentials.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/flv"
        let streamName = "channel\(channel)_\(stream == .main ? "main" : "sub").bcs"
        components.queryItems = [
            URLQueryItem(name: "port", value: "1935"),
            URLQueryItem(name: "app", value: "bcs"),
            URLQueryItem(name: "stream", value: streamName),
            URLQueryItem(name: "user", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        return components.url!
    }
}

private extension CharacterSet {
    static let reolinkURLUser: CharacterSet = {
        var s = CharacterSet.urlUserAllowed
        s.remove(charactersIn: "@:/?#")
        return s
    }()
    static let reolinkURLPassword: CharacterSet = {
        var s = CharacterSet.urlPasswordAllowed
        s.remove(charactersIn: "@:/?#")
        return s
    }()
}
