import Foundation
import OSLog
import ReolinkAPI
import ReolinkBaichuan

private let log = Logger(subsystem: "com.reolens.app", category: "recordings-loader")

/// Bridges the live `CameraSession` to the
/// `RecordingsDataSource` protocol consumed by `RecordingsLoader`.
/// All work is `@MainActor` because `CameraSession` is — there is no
/// extra hop, the loader just sees the session through a narrow
/// interface that mocks can also conform to.
extension CameraSession: RecordingsDataSource {
    public var currentAIEventLog: [TimestampedAIEvent] {
        aiEventLog
    }

    public func ensureConnectedBeforeFetch() async -> Bool {
        if status == .connected { return true }
        // Mirror the existing macOS view's 1.5 s pre-flight wait —
        // covers the common case of "user pivots to Recordings while
        // the session is still finishing login".
        let deadline = Date().addingTimeInterval(1.5)
        while status != .connected, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
        return status == .connected
    }

    public func search(
        channel: Int,
        streamType: String,
        start: Date,
        end: Date,
        captureRaw: Bool
    ) async -> RecordingsSearchOutcome {
        await withBackgroundPollingPaused {
            await self.runSearch(
                channel: channel,
                streamType: streamType,
                start: start,
                end: end,
                captureRaw: captureRaw
            )
        }
    }

    private func runSearch(
        channel: Int,
        streamType: String,
        start: Date,
        end: Date,
        captureRaw: Bool
    ) async -> RecordingsSearchOutcome {
        let startedAt = Date()
        let command = Commands.search(
            channel: channel,
            onlyStatus: false,
            streamType: streamType,
            start: start,
            end: end
        )
        do {
            let raw = try await client.sendCapturingRaw(command)
            let pretty: String = captureRaw
                ? (Self.prettyPrint(raw) ?? String(data: raw, encoding: .utf8) ?? "<binary>")
                : ""
            let envelopes = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: raw)
            guard let envelope = envelopes.first else {
                return .failure("Camera returned no Search envelope. Try again — if it persists, reconnect the camera.")
            }
            if let cgiError = envelope.error {
                let detail: String = {
                    if cgiError.rspCode == -10 { return "Session expired. Reolens will retry on the next refresh." }
                    if cgiError.rspCode == -17 { return "Camera is busy — retry in a moment." }
                    return "Reolink error \(cgiError.rspCode): \(cgiError.detail ?? "no detail")"
                }()
                return .failure(detail)
            }
            guard let value = envelope.value else {
                return .failure("Search response was missing data. Try Refresh.")
            }
            let result = value.SearchResult.File ?? []
            let statuses = value.SearchResult.Status ?? []
            log.info("Search completed channel=\(channel) stream=\(streamType, privacy: .public) files=\(result.count) statuses=\(statuses.count) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s")
            return .success(result, rawPretty: pretty, statuses: statuses)
        } catch let urlError as URLError {
            return .failure(Self.friendlyTransportMessage(urlError))
        } catch let decodingError as DecodingError {
            return .failure("Couldn't read the camera's response (\(Self.shortDescription(of: decodingError))). The camera firmware may have changed — please report this.")
        } catch {
            return .failure(error.localizedDescription.isEmpty ? "\(error)" : error.localizedDescription)
        }
    }

    public func findAlarmVideos(
        channel: Int,
        start: Date,
        end: Date,
        channelUID: String?
    ) async throws -> [BaichuanAlarmVideoFile] {
        guard let client = baichuanClient else { return [] }

        // Per-camera UID resolution: prefer the value from
        // `GetChannelstatus` (passed in via `channelUID`) since msg 114
        // returns only the hub UID. Fall back to a Baichuan probe when
        // that's empty.
        let uid: String
        if let cgiUID = channelUID, !cgiUID.isEmpty {
            uid = cgiUID
        } else {
            uid = await client.fetchUID(channelID: UInt8(channel))
        }

        return try await client.findAlarmVideos(
            channel: UInt8(channel),
            start: start,
            end: end,
            streamType: "main",
            uid: uid
        )
    }

    public func getEvents(
        channel: Int,
        start: Date,
        end: Date
    ) async -> RecordingsEventsOutcome {
        let cmd = Commands.getEvents(channel: channel, start: start, end: end)
        do {
            let raw = try await client.sendCapturingRaw(cmd)
            let envelopes = (try? JSONDecoder().decode([CGIResponse<HubEventEnvelope>].self, from: raw)) ?? []
            if let firstError = envelopes.first?.error,
               firstError.rspCode == CGIErrorCode.notSupport.rawValue {
                return .unsupported
            }
            let decoded = envelopes.first?.value?.events ?? []
            return .events(decoded)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Diagnostic helpers (moved from view)

    private static func prettyPrint(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) else { return nil }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private static func friendlyTransportMessage(_ urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "Connection to the camera timed out. Check that you're on the same Wi-Fi."
        case .cannotConnectToHost:
            return "Couldn't reach the camera. Is it powered on?"
        case .networkConnectionLost:
            return "Wi-Fi dropped during the request. Try Refresh."
        case .notConnectedToInternet:
            return "Your device isn't on a network."
        case .secureConnectionFailed:
            return "HTTPS connection failed. The camera's certificate may have changed."
        default:
            return "Network error \(urlError.code.rawValue): \(urlError.localizedDescription)"
        }
    }

    private static func shortDescription(of error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
        case .typeMismatch(_, let ctx): return ctx.debugDescription
        case .valueNotFound(_, let ctx): return ctx.debugDescription
        case .dataCorrupted(let ctx): return ctx.debugDescription
        @unknown default: return "decode failure"
        }
    }
}
