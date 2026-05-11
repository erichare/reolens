import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "battery")

/// Battery status for a paired camera. Populated from Baichuan msg 252
/// (`batteryInfoList`) pushes and on-demand requests. Reolink emits this
/// every few seconds while a battery cam is awake, and at irregular
/// intervals while it sleeps.
public struct BaichuanBatteryInfo: Sendable, Hashable {
    public let channelID: Int
    /// 0…100 — the battery's state of charge.
    public let percent: Int
    /// Raw `chargeStatus` string from the XML (e.g. `"none"`, `"charging"`,
    /// `"chargeComplete"`, `"fullyCharged"`). Useful for tooltips even if we
    /// don't enumerate every variant.
    public let chargeStatus: String
    /// True when the camera reports an active charge in progress.
    public let isCharging: Bool
    /// True when the camera is plugged into mains power (solar panel or USB).
    public let isPluggedIn: Bool
    /// Battery temperature in °C, if reported. Useful for diagnosing thermal
    /// throttling on outdoor cameras.
    public let temperatureC: Int?

    public var isLow: Bool { percent < 20 }
    public var isCritical: Bool { percent < 10 }
}

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

    /// Subscribe to ongoing battery status pushes. The hub emits msg 252
    /// (`batteryInfoList`) periodically and whenever a paired battery
    /// camera updates its state. Each push covers ALL paired battery cams
    /// in one frame, so the returned stream yields one `BaichuanBatteryInfo`
    /// per camera per push.
    public func subscribeToBatteryInfo() -> AsyncStream<BaichuanBatteryInfo> {
        let raw = subscribe()
        let (stream, continuation) = AsyncStream<BaichuanBatteryInfo>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let bridge = Task {
            for await msg in raw {
                guard msg.header.msgID == BcMessageID.batteryInfoList else { continue }
                let xml = String(data: msg.body, encoding: .utf8) ?? ""
                let infos = Self.parseBatteryInfoList(xml: xml)
                if !infos.isEmpty {
                    log.debug("Parsed \(infos.count) BatteryInfo entries from msg 252")
                }
                for info in infos {
                    continuation.yield(info)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridge.cancel() }
        return stream
    }

    /// Parse one or more `<BatteryInfo>` blocks from a `BatteryInfoList`
    /// push. The hub uses slightly different tag names across firmware
    /// versions — we accept both `batteryPercent`/`battery_percent` and
    /// camelCase variants for charge/adapter state.
    static func parseBatteryInfoList(xml: String) -> [BaichuanBatteryInfo] {
        var results: [BaichuanBatteryInfo] = []
        for block in BcXmlBody.allBlocks(in: xml, tag: "BatteryInfo") {
            guard let channel = (BcXmlBody.firstTagContent(in: block, tag: "channelId")
                                 ?? BcXmlBody.firstTagContent(in: block, tag: "channel"))
                                .flatMap(Int.init) else { continue }
            let percent = (BcXmlBody.firstTagContent(in: block, tag: "batteryPercent")
                           ?? BcXmlBody.firstTagContent(in: block, tag: "battery_percent")
                           ?? BcXmlBody.firstTagContent(in: block, tag: "percent"))
                          .flatMap(Int.init) ?? 0
            let chargeStatus = BcXmlBody.firstTagContent(in: block, tag: "chargeStatus")
                ?? BcXmlBody.firstTagContent(in: block, tag: "charge_status")
                ?? "none"
            let chargeLower = chargeStatus.lowercased()
            let isCharging = chargeLower.contains("charg") && !chargeLower.contains("complete") && !chargeLower.contains("full")
            let adapterRaw = BcXmlBody.firstTagContent(in: block, tag: "adapterStatus")
                ?? BcXmlBody.firstTagContent(in: block, tag: "adapter_status")
                ?? "0"
            let isPluggedIn = adapterRaw == "1"
                || adapterRaw.lowercased() == "in"
                || adapterRaw.lowercased() == "connected"
                || isCharging
            let temp = BcXmlBody.firstTagContent(in: block, tag: "temperature").flatMap(Int.init)
            results.append(BaichuanBatteryInfo(
                channelID: channel,
                percent: max(0, min(100, percent)),
                chargeStatus: chargeStatus,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                temperatureC: temp
            ))
        }
        return results
    }
}
