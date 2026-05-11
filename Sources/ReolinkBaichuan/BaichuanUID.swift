import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "uid")

extension BaichuanClient {

    /// Fetch the device UID for a given channel. Reolink uses this in
    /// queries that need to identify the specific paired camera under a
    /// Home Hub (e.g. `findAlarmVideo`). Empty string if not available.
    public func fetchUID(channelID: UInt8 = 0) async -> String {
        let header = BcHeader(
            msgID: BcMessageID.uid,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: nextMessageNumber(),
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let request = BcMessage(header: header, body: Data())
        do {
            let reply = try await sendAndAwait(request, timeout: 4, stage: "getUID")
            let body = String(data: reply.body, encoding: .utf8) ?? ""
            log.info("UID reply (channel=\(channelID) code=\(reply.header.responseCode)): \(body.prefix(300), privacy: .public)")
            return BcXmlBody.firstTagContent(in: body, tag: "uid")
                ?? BcXmlBody.firstTagContent(in: body, tag: "Uid")
                ?? ""
        } catch {
            log.debug("UID fetch failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
