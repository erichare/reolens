import Foundation

/// Strongly typed command constructors. Each returns a tuple of (command, value-type) so the client
/// can decode the response automatically.
public enum Commands {

    public static func login(username: String, password: String) -> CGICommand<LoginParam> {
        CGICommand(
            cmd: "Login",
            action: .get,
            param: LoginParam(User: .init(userName: username, password: password))
        )
    }

    public static func logout() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "Logout", action: .get, param: EmptyParam())
    }

    public static func getDevInfo() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "GetDevInfo", action: .get, param: EmptyParam())
    }

    public static func getAbility(username: String = "admin") -> CGICommand<AbilityRequest> {
        CGICommand(cmd: "GetAbility", action: .get, param: .init(User: .init(userName: username)))
    }

    public struct AbilityRequest: Encodable, Sendable {
        public let User: UserName
        public struct UserName: Encodable, Sendable {
            public let userName: String
        }
    }

    public static func getChannelStatus() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "GetChannelstatus", action: .get, param: EmptyParam())
    }

    public static func getMdState(channel: Int = 0) -> CGICommand<ChannelParam> {
        CGICommand(cmd: "GetMdState", action: .get, param: .init(channel: channel))
    }

    public static func getAiState(channel: Int = 0) -> CGICommand<ChannelParam> {
        CGICommand(cmd: "GetAiState", action: .get, param: .init(channel: channel))
    }

    public static func ptzCtrl(channel: Int, op: PtzOp, speed: Int? = 32, id: Int? = nil) -> CGICommand<PtzCtrlParam> {
        CGICommand(cmd: "PtzCtrl", action: .get, param: .init(channel: channel, op: op, speed: speed, id: id))
    }

    public static func getLocalLink() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "GetLocalLink", action: .get, param: EmptyParam())
    }

    public static func getTime() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "GetTime", action: .get, param: EmptyParam())
    }

    /// Search the recorder/hub storage for recordings on a given channel and
    /// time range. `onlyStatus=true` returns a per-day overview (cheap), while
    /// `onlyStatus=false` returns the full file list (heavier).
    public static func search(
        channel: Int,
        onlyStatus: Bool,
        streamType: String = "main",
        start: Date,
        end: Date
    ) -> CGICommand<SearchParam> {
        CGICommand(
            cmd: "Search",
            action: .getDetailed,
            param: SearchParam(.init(
                channel: channel,
                onlyStatus: onlyStatus,
                streamType: streamType,
                start: start,
                end: end
            ))
        )
    }

    public static func getOsd(channel: Int = 0) -> CGICommand<ChannelParam> {
        CGICommand(cmd: "GetOsd", action: .get, param: .init(channel: channel))
    }

    public static func setOsd(_ osd: OsdSettings) -> CGICommand<SetOsdParam> {
        CGICommand(cmd: "SetOsd", action: .get, param: SetOsdParam(Osd: osd))
    }

    public static func getHddInfo() -> CGICommand<EmptyParam> {
        CGICommand(cmd: "GetHddInfo", action: .get, param: EmptyParam())
    }

    /// 0.5.0 Theme C2 — fetch the current privacy-mask rectangles for
    /// a channel. Reolink firmware returns up to 4 areas in
    /// normalized 0…1 image-space. Older firmware responds with
    /// rspCode = -9 (not supported); callers fall back to local-only
    /// persistence in that case.
    public static func getMask(channel: Int = 0) -> CGICommand<ChannelParam> {
        CGICommand(cmd: "GetMask", action: .get, param: .init(channel: channel))
    }

    /// 0.5.0 Theme C2 — write the privacy-mask rectangles back to
    /// the camera. Most firmware caps `area.count` at 4; the caller
    /// (`PrivacyZoneEditorModel`) enforces that ceiling before
    /// reaching this command.
    public static func setMask(_ mask: MaskSettings) -> CGICommand<SetMaskParam> {
        CGICommand(cmd: "SetMask", action: .get, param: SetMaskParam(Mask: mask))
    }

    /// Speculative probe for an alarm-event log endpoint. Reolink's official
    /// CGI docs don't mention this command, but some newer NVR/hub firmware
    /// implements it. Returns -9 (not supported) on hubs that don't.
    public static func getEvents(
        channel: Int,
        start: Date,
        end: Date
    ) -> CGICommand<EventsParam> {
        CGICommand(
            cmd: "GetEvents",
            action: .get,
            param: EventsParam(
                channel: channel,
                StartTime: ReolinkTime(date: start),
                EndTime: ReolinkTime(date: end)
            )
        )
    }

    public struct EventsParam: Encodable, Sendable {
        public let channel: Int
        public let StartTime: ReolinkTime
        public let EndTime: ReolinkTime
    }
}
