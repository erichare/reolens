import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "battery")

extension BaichuanClient {

    /// Ask the hub to wake a battery-powered camera. Reolink's battery
    /// cameras (Argus, Go, battery Doorbell) ignore RTSP entirely while
    /// sleeping; the only way to bring them online is a Baichuan
    /// `BatteryInfo` poke. The hub forwards the request over its proprietary
    /// link to the paired camera and returns once the camera answers (or
    /// after a short delay if the camera doesn't respond).
    @discardableResult
    public func wakeBatteryCamera(channelID: UInt8) async throws -> Bool {
        log.info("Wake battery camera channel=\(channelID)")
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <BatteryInfo version="1.1">
        <channelId>\(channelID)</channelId>
        </BatteryInfo>
        </body>
        """
        let header = BcHeader(
            msgID: BcMessageID.batteryInfo,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: nextMessageNumber(),
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let request = BcMessage(header: header, body: Data(xml.utf8))
        let reply = try await sendAndAwait(request, timeout: 12, stage: "wakeBattery")
        return reply.header.responseCode == 200
    }
}
