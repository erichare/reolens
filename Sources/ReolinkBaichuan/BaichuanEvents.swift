import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "events")

/// A motion / AI event delivered by the camera over the Baichuan TCP push.
public struct BaichuanEvent: Sendable, Hashable {
    public let channelID: UInt8
    public let kind: Kind
    public let raw: String   // raw XML for diagnostic

    public enum Kind: Sendable, Hashable {
        case motionStart
        case motionStop
        case ai(String)      // raw AI tag, e.g. "people", "vehicle", "dog_cat"
        case other
    }
}

extension BaichuanClient {

    /// Ask the camera to start delivering motion / AI alarm events. Returns
    /// an `AsyncStream` of decoded `BaichuanEvent`s that closes when the
    /// connection drops.
    public func subscribeToAlarmEvents(channelID: UInt8 = 0) async throws -> AsyncStream<BaichuanEvent> {
        // Register the unsolicited-message listener BEFORE sending the request,
        // so any fast push that arrives immediately after the camera accepts
        // the subscription doesn't slip through unobserved.
        let raw = subscribe()

        let header = BcHeader(
            msgID: BcMessageID.motionRequest,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: nextMessageNumber(),
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let req = BcMessage(header: header, body: Data())
        _ = try? await sendAndAwait(req, timeout: 5)
        log.info("Subscribed to alarm events on channel \(channelID)")

        let (stream, continuation) = AsyncStream<BaichuanEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        let bridgeTask = Task {
            var loggedFirstAlarm = false
            for await msg in raw {
                if msg.header.msgID == BcMessageID.motion {
                    if !loggedFirstAlarm {
                        loggedFirstAlarm = true
                        let preview = String(data: msg.body.prefix(400), encoding: .utf8) ?? "<non-utf8>"
                        log.info("First AlarmEventList (msgID=33) body preview: \(preview, privacy: .public)")
                    }
                    let xml = String(data: msg.body, encoding: .utf8) ?? ""
                    let events = Self.parseAlarmEvents(xml: xml, channelID: msg.header.channelID)
                    if !events.isEmpty {
                        log.info("Parsed \(events.count) alarm events from msgID=33")
                    }
                    for event in events {
                        continuation.yield(event)
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridgeTask.cancel() }
        return stream
    }

    static func parseAlarmEvents(xml: String, channelID: UInt8) -> [BaichuanEvent] {
        // The camera emits an `<AlarmEventList>` containing one or more
        // `<AlarmEvent>` blocks. Each has fields like:
        //
        //     <AlarmEvent>
        //       <channelId>0</channelId>
        //       <status>MD</status>          (or "none")
        //       <recording>0</recording>
        //       <timeStamp>1747...</timeStamp>
        //       <ai_type>people</ai_type>    (newer firmware)
        //     </AlarmEvent>
        //
        // We pick out `status` and `ai_type` to classify.
        var events: [BaichuanEvent] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let blockOpen = xml.range(of: "<AlarmEvent>", range: searchRange),
              let blockClose = xml.range(of: "</AlarmEvent>", range: blockOpen.upperBound..<xml.endIndex) {
            let blockText = String(xml[blockOpen.upperBound..<blockClose.lowerBound])
            let status = BcXmlBody.firstTagContent(in: blockText, tag: "status") ?? ""
            let aiType = BcXmlBody.firstTagContent(in: blockText, tag: "ai_type")

            let kind: BaichuanEvent.Kind
            if let aiType, !aiType.isEmpty, aiType != "none" {
                kind = .ai(aiType)
            } else if status == "MD" {
                kind = .motionStart
            } else if status == "none" || status.isEmpty {
                kind = .motionStop
            } else {
                kind = .other
            }
            events.append(BaichuanEvent(channelID: channelID, kind: kind, raw: blockText))
            searchRange = blockClose.upperBound..<xml.endIndex
        }
        return events
    }
}
