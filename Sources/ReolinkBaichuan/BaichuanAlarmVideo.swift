import Foundation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.baichuan", category: "alarmVideo")

/// One entry in the hub's alarm-tagged video list (recordings that were
/// triggered by motion or AI events).
public struct BaichuanAlarmVideoFile: Sendable, Hashable, Identifiable {
    public let fileName: String
    public let startTime: ReolinkTime
    public let endTime: ReolinkTime
    /// Comma-separated alarm tags as the hub provides them, e.g.
    /// `"md, people"` or `"md, vehicle, dog_cat"`.
    public let alarmType: String

    public var id: String { fileName }

    public var startDate: Date? { startTime.date() }
    public var endDate: Date? { endTime.date() }

    /// Map the alarm-type string into our `DetectionType` enum from
    /// `ReolinkAPI`. Reolink uses a fixed vocabulary for these tags:
    ///   `md, pir, io, people, face, vehicle, dog_cat, visitor, package,
    ///   other, cry, crossline, intrusion, loitering, legacy, loss`.
    public var detections: [DetectionType] {
        let tokens = alarmType
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [DetectionType] = []
        var seen = Set<DetectionType>()
        for token in tokens {
            let dt: DetectionType?
            switch token {
            case "md", "pir": dt = .motion
            case "people", "person", "human": dt = .person
            case "vehicle", "car": dt = .vehicle
            case "dog_cat", "pet", "animal": dt = .pet
            case "face": dt = .face
            case "package": dt = .packageDelivery
            case "visitor", "doorbell": dt = .visitor
            case "cry", "other", "crossline", "intrusion", "loitering", "io": dt = .other
            default: dt = nil
            }
            if let dt, seen.insert(dt).inserted {
                result.append(dt)
            }
        }
        return result
    }
}

extension BaichuanClient {

    /// Search the hub's SD card for alarm-tagged recordings on a channel in a
    /// time range. Uses Reolink's three-step protocol (cmd_id=272 to open the
    /// search, cmd_id=273 in a loop to fetch pages of results, cmd_id=274 to
    /// close).
    public func findAlarmVideos(
        channel: UInt8,
        start: Date,
        end: Date,
        streamType: String = "main",
        uid: String = ""
    ) async throws -> [BaichuanAlarmVideoFile] {
        log.info("findAlarmVideos channel=\(channel) start=\(start) end=\(end)")
        let openXML = buildFindAlarmOpenXML(channel: Int(channel), uid: uid, streamType: streamType, start: start, end: end)
        let openReply = try await send(cmdID: BcMessageID.findAlarmVideo, channelID: channel, body: openXML, stage: "findAlarmVideo open")
        let openBody = String(data: openReply.body, encoding: .utf8) ?? ""
        guard let fileHandle = BcXmlBody.firstTagContent(in: openBody, tag: "fileHandle"), !fileHandle.isEmpty else {
            log.error("findAlarmVideos: no fileHandle in open reply (body preview: \(openBody.prefix(200), privacy: .public))")
            return []
        }

        var results: [BaichuanAlarmVideoFile] = []
        var finished = false
        var safetyIterations = 0
        while !finished && safetyIterations < 32 {
            safetyIterations += 1
            let pageXML = buildFindAlarmPageXML(channel: Int(channel), fileHandle: fileHandle)
            let pageReply = try await send(cmdID: BcMessageID.alarmVideoInfo, channelID: channel, body: pageXML, stage: "findAlarmVideo page")
            let pageBody = String(data: pageReply.body, encoding: .utf8) ?? ""

            let infoBlocks = BcXmlBody.allBlocks(in: pageBody, tag: "alarmVideoInfo")
            guard let info = infoBlocks.first else {
                log.debug("findAlarmVideos: no <alarmVideoInfo> in page reply, stopping")
                break
            }
            let bFinished = BcXmlBody.firstTagContent(in: info, tag: "bFinished").flatMap(Int.init) ?? 1
            finished = bFinished == 1

            for videoBlock in BcXmlBody.allBlocks(in: info, tag: "alarmVideo") {
                guard let fileName = BcXmlBody.firstTagContent(in: videoBlock, tag: "fileName"),
                      let alarmType = BcXmlBody.firstTagContent(in: videoBlock, tag: "alarmType"),
                      let startTime = BcXmlBody.reolinkTime(in: videoBlock, tag: "startTime"),
                      let endTime = BcXmlBody.reolinkTime(in: videoBlock, tag: "endTime") else { continue }
                results.append(BaichuanAlarmVideoFile(
                    fileName: fileName,
                    startTime: startTime,
                    endTime: endTime,
                    alarmType: alarmType
                ))
            }
        }
        // Close the search on the hub side.
        let closeXML = buildFindAlarmPageXML(channel: Int(channel), fileHandle: fileHandle)
        _ = try? await send(cmdID: 274, channelID: channel, body: closeXML, stage: "findAlarmVideo close", timeout: 4)

        log.info("findAlarmVideos channel=\(channel) returned \(results.count) entries")
        return results
    }

    /// Send a Baichuan message with an XML body, modern class 0x6414.
    fileprivate func send(
        cmdID: UInt32,
        channelID: UInt8,
        body: Data,
        stage: String,
        timeout: TimeInterval = 8
    ) async throws -> BcMessage {
        let header = BcHeader(
            msgID: cmdID,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: nextMessageNumber(),
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let message = BcMessage(header: header, body: body)
        return try await sendAndAwait(message, timeout: timeout, stage: stage)
    }

    private func buildFindAlarmOpenXML(channel: Int, uid: String, streamType: String, start: Date, end: Date) -> Data {
        let s = ReolinkTime(date: start)
        let e = ReolinkTime(date: end)
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <findAlarmVideo version="1.1">
        <channelId>\(channel)</channelId>
        <uid>\(uid)</uid>
        <logicChnBitmap>255</logicChnBitmap>
        <streamType>\(streamType)</streamType>
        <notSearchVideo>0</notSearchVideo>
        <startTime>
        <year>\(s.year)</year>
        <month>\(s.mon)</month>
        <day>\(s.day)</day>
        <hour>\(s.hour)</hour>
        <minute>\(s.min)</minute>
        <second>\(s.sec)</second>
        </startTime>
        <endTime>
        <year>\(e.year)</year>
        <month>\(e.mon)</month>
        <day>\(e.day)</day>
        <hour>\(e.hour)</hour>
        <minute>\(e.min)</minute>
        <second>\(e.sec)</second>
        </endTime>
        <alarmType>md, pir, io, people, face, vehicle, dog_cat, visitor, other, package, cry, crossline, intrusion, loitering, legacy, loss</alarmType>
        </findAlarmVideo>
        </body>
        """
        return Data(xml.utf8)
    }

    private func buildFindAlarmPageXML(channel: Int, fileHandle: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <findAlarmVideo version="1.1">
        <channelId>\(channel)</channelId>
        <fileHandle>\(fileHandle)</fileHandle>
        </findAlarmVideo>
        </body>
        """
        return Data(xml.utf8)
    }
}
