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
        let raw = await subscribe()

        let msgNum = await nextMessageNumber()
        let header = BcHeader(
            msgID: BcMessageID.motionRequest,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: msgNum,
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
                        log.debug("First AlarmEventList (msgID=33) body preview: \(preview, privacy: .private)")
                    }
                    let xml = String(data: msg.body, encoding: .utf8) ?? ""
                    let events = Self.parseAlarmEvents(xml: xml, channelID: msg.header.channelID)
                    // Trace at debug — these messages arrive every few
                    // seconds per channel, so logging at info here would
                    // flood the unified log. Maintainers can flip to
                    // info via `log config --subsystem com.reolens.baichuan
                    // --mode "level:info"` when chasing a missed event.
                    log.debug("msgID=33 parsed \(events.count) events")
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
        // The hub emits an `<AlarmEventList>` containing one
        // `<AlarmEvent ...>` block per channel. Real shape on a Reolink
        // Home Hub Pro running v3.3.0:
        //
        //     <AlarmEvent version="1.1">
        //       <channelId>0</channelId>
        //       <status>MD</status>            (or "none")
        //       <AItype>people</AItype>        (or "none")
        //       <recording>0</recording>
        //       <timeStamp>1747...</timeStamp>
        //     </AlarmEvent>
        //
        // We must:
        //   - tolerate `<AlarmEvent>` *and* `<AlarmEvent version="…">`
        //     (and any other future attribute) — match the open tag
        //     prefix, then find the next `>` to close it
        //   - look for the AI tag under both casings: newer hub
        //     firmware sends `<AItype>`, older builds and the
        //     community PDF doc use `<ai_type>`
        //   - also accept the per-channel ID embedded in the block
        //     itself, so a single multi-camera msgID=33 dump can route
        //     each event to its correct channel
        var events: [BaichuanEvent] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let openTagStart = xml.range(of: "<AlarmEvent", range: searchRange),
              let openTagEnd = xml.range(of: ">", range: openTagStart.upperBound..<xml.endIndex),
              let blockClose = xml.range(of: "</AlarmEvent>", range: openTagEnd.upperBound..<xml.endIndex) {
            let blockText = String(xml[openTagEnd.upperBound..<blockClose.lowerBound])
            let status = BcXmlBody.firstTagContent(in: blockText, tag: "status") ?? ""
            let aiType = BcXmlBody.firstTagContent(in: blockText, tag: "AItype")
                ?? BcXmlBody.firstTagContent(in: blockText, tag: "ai_type")
            // If the block carries a `<channelId>` use it; otherwise
            // fall back to the message-header channel passed in.
            let inner = BcXmlBody.firstTagContent(in: blockText, tag: "channelId")
            let resolvedChannel: UInt8 = {
                if let inner, let n = UInt8(inner) { return n }
                return channelID
            }()

            let kind: BaichuanEvent.Kind
            if let aiType, !aiType.isEmpty, aiType.lowercased() != "none" {
                kind = .ai(aiType)
            } else if status == "MD" {
                kind = .motionStart
            } else if status == "none" || status.isEmpty {
                kind = .motionStop
            } else {
                kind = .other
            }
            events.append(BaichuanEvent(channelID: resolvedChannel, kind: kind, raw: blockText))
            searchRange = blockClose.upperBound..<xml.endIndex
        }
        return events
    }
}
