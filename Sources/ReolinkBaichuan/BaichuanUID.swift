import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "uid")

extension BaichuanClient {

    /// Fetch the device UID for a given channel. Reolink uses this in
    /// queries that need to identify the specific paired camera under a
    /// Home Hub (e.g. `findAlarmVideo`). Empty string if not available.
    public func fetchUID(channelID: UInt8 = 0) async -> String {
        let msgNum = await nextMessageNumber()
        let header = BcHeader(
            msgID: BcMessageID.uid,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let request = BcMessage(header: header, body: Data())
        do {
            let reply = try await sendAndAwait(request, timeout: 4, stage: "getUID")
            let body = String(data: reply.body, encoding: .utf8) ?? ""
            // UID reply body carries the camera's globally-unique
            // hardware identifier. Diagnostic only; `.private` +
            // `.debug` so it doesn't surface in sysdiagnose for
            // ordinary users.
            log.debug("UID reply (channel=\(channelID) code=\(reply.header.responseCode)): \(body.prefix(300), privacy: .private)")
            return BcXmlBody.firstTagContent(in: body, tag: "uid")
                ?? BcXmlBody.firstTagContent(in: body, tag: "Uid")
                ?? ""
        } catch {
            log.debug("UID fetch failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
