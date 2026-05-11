import Testing
import Foundation
@testable import ReolinkAPI

@Suite("CGI Codable round-trips")
struct CodableTests {

    @Test func encodesLoginCommand() throws {
        let cmd = Commands.login(username: "admin", password: "secret")
        let data = try JSONEncoder().encode([cmd])
        let str = try #require(String(data: data, encoding: .utf8))
        #expect(str.contains("\"cmd\":\"Login\""))
        #expect(str.contains("\"userName\":\"admin\""))
        #expect(str.contains("\"password\":\"secret\""))
        #expect(str.contains("\"Version\":\"0\""))
    }

    @Test func decodesLoginResponse() throws {
        let json = """
        [{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"44aecc633acd413"}}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<LoginResult>].self, from: json)
        #expect(result.count == 1)
        let first = try #require(result.first)
        #expect(first.isSuccess)
        #expect(first.value?.Token.name == "44aecc633acd413")
        #expect(first.value?.Token.leaseTime == 3600)
    }

    @Test func decodesErrorResponse() throws {
        let json = """
        [{"cmd":"GetMdState","code":-10,"error":{"rspCode":-10,"detail":"please login first"}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<MotionStateValue>].self, from: json)
        let first = try #require(result.first)
        #expect(!first.isSuccess)
        #expect(first.error?.rspCode == -10)
        #expect(first.error?.detail == "please login first")
        #expect(CGIErrorCode(rawValue: first.error!.rspCode) == .loginRequired)
    }

    @Test func decodesMotionState() throws {
        let json = """
        [{"cmd":"GetMdState","code":0,"value":{"state":1,"channel":0}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<MotionStateValue>].self, from: json)
        let value = try #require(result.first?.value)
        #expect(value.isTriggered)
        #expect(value.channel == 0)
    }

    @Test func decodesAiState() throws {
        let json = """
        [{"cmd":"GetAiState","code":0,"value":{
          "channel":0,
          "people":{"alarm_state":1,"support":1},
          "vehicle":{"alarm_state":0,"support":1},
          "dog_cat":{"alarm_state":0,"support":1},
          "face":{"alarm_state":0,"support":0}
        }}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<AIStateValue>].self, from: json)
        let value = try #require(result.first?.value)
        #expect(value.anyTriggered)
        #expect(value.people?.isTriggered == true)
        #expect(value.vehicle?.isSupported == true)
        #expect(value.face?.isSupported == false)
    }

    @Test func decodesChannelStatus() throws {
        let json = """
        [{"cmd":"GetChannelstatus","code":0,"value":{"count":2,"status":[
          {"channel":0,"name":"Front Door","online":1,"typeInfo":"Doorbell"},
          {"channel":1,"name":"Backyard","online":1,"typeInfo":"RLC-810A","sleep":0}
        ]}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<ChannelStatusEnvelope>].self, from: json)
        let env = try #require(result.first?.value)
        #expect(env.count == 2)
        #expect(env.status.first?.name == "Front Door")
        #expect(env.status.first?.isOnline == true)
        #expect(env.status[1].typeInfo == "RLC-810A")
    }

    @Test func decodesDevInfo() throws {
        let json = """
        [{"cmd":"GetDevInfo","code":0,"value":{"DevInfo":{
          "name":"Camera1","model":"RLC-810A","hardVer":"IPC_523128M8MP","firmVer":"v3.1.0.951",
          "serial":"0000000000000000","buildDay":"build 23010100","cfgVer":"v3.0.0.0",
          "channelNum":1,"diskNum":0,"type":"IPC","wifi":0,"b485":0,"IOInputNum":0,"IOOutputNum":0,
          "audioNum":1,"pakSuffix":"pak","exactType":"IPC","detail":""}}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<DeviceInfoEnvelope>].self, from: json)
        let info = try #require(result.first?.value?.DevInfo)
        #expect(info.model == "RLC-810A")
        #expect(info.isNVR == false)
        #expect(info.firmVer == "v3.1.0.951")
    }

    @Test func reolinkTime_roundTrip() throws {
        let original = Date(timeIntervalSince1970: 1747000000)
        let rt = ReolinkTime(date: original)
        let recovered = try #require(rt.date())
        // Reolink time stores integer seconds — equality at second precision.
        #expect(abs(recovered.timeIntervalSince(original)) < 1)
    }

    @Test func encodesSearchCommand() throws {
        let start = ReolinkTime(year: 2026, mon: 5, day: 11, hour: 0, min: 0, sec: 0).date()!
        let end = ReolinkTime(year: 2026, mon: 5, day: 11, hour: 23, min: 59, sec: 59).date()!
        let cmd = Commands.search(channel: 1, onlyStatus: false, start: start, end: end)
        let data = try JSONEncoder().encode([cmd])
        let str = try #require(String(data: data, encoding: .utf8))
        #expect(str.contains("\"cmd\":\"Search\""))
        #expect(str.contains("\"channel\":1"))
        #expect(str.contains("\"onlyStatus\":0"))
        #expect(str.contains("\"streamType\":\"main\""))
        #expect(str.contains("\"year\":2026"))
        #expect(str.contains("\"mon\":5"))
        #expect(str.contains("\"day\":11"))
    }

    @Test func decodesSearchStatus() throws {
        let json = """
        [{"cmd":"Search","code":0,"value":{"SearchResult":{
          "channel":0,
          "Status":[{"year":2026,"mon":5,"table":"00000000001111110000111100000000"}]
        }}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: json)
        let r = try #require(result.first?.value?.SearchResult)
        let status = try #require(r.Status?.first)
        #expect(status.year == 2026)
        #expect(status.mon == 5)
        #expect(status.daysWithRecordings == [11, 12, 13, 14, 15, 16, 21, 22, 23, 24])
    }

    @Test func decodesSearchFiles() throws {
        let json = """
        [{"cmd":"Search","code":0,"value":{"SearchResult":{
          "channel":0,
          "File":[
            {"name":"Mon_2305_122105_main_RecS01.mp4","size":12345678,"type":"main",
             "StartTime":{"year":2026,"mon":5,"day":11,"hour":12,"min":21,"sec":5},
             "EndTime":{"year":2026,"mon":5,"day":11,"hour":12,"min":22,"sec":15},
             "frameRate":30,"width":3840,"height":2160}
          ]
        }}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: json)
        let file = try #require(result.first?.value?.SearchResult.File?.first)
        #expect(file.name == "Mon_2305_122105_main_RecS01.mp4")
        #expect(file.type == "main")
        #expect(file.frameRate == 30)
        #expect(file.width == 3840)
        #expect(file.height == 2160)
        #expect(file.durationSeconds == 70)
        #expect((file.sizeMB ?? 0) > 11 && (file.sizeMB ?? 0) < 12)
    }

    /// Regression: Reolink firmware sometimes returns recording sizes as JSON
    /// strings instead of numbers, especially for files larger than 2 GB. The
    /// decoder must tolerate either form.
    @Test func decodesSearchFile_sizeAsString() throws {
        let json = """
        [{"cmd":"Search","code":0,"value":{"SearchResult":{
          "channel":0,
          "File":[
            {"name":"Mon_2305_122105_main.mp4","size":"3500000000","type":"main",
             "StartTime":{"year":2026,"mon":5,"day":11,"hour":12,"min":21,"sec":5},
             "EndTime":{"year":2026,"mon":5,"day":11,"hour":12,"min":22,"sec":15}}
          ]
        }}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: json)
        let file = try #require(result.first?.value?.SearchResult.File?.first)
        #expect(file.size == 3_500_000_000)
    }

    @Test func decodesSearchFile_sizeAsInt() throws {
        let json = """
        [{"cmd":"Search","code":0,"value":{"SearchResult":{
          "channel":0,
          "File":[
            {"name":"x.mp4","size":12345,"type":"main",
             "StartTime":{"year":2026,"mon":5,"day":11,"hour":0,"min":0,"sec":0},
             "EndTime":{"year":2026,"mon":5,"day":11,"hour":0,"min":1,"sec":0}}
          ]
        }}}]
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode([CGIResponse<SearchEnvelope>].self, from: json).first!.value!.SearchResult.File!.first!
        #expect(file.size == 12345)
    }

    @Test func decodesOsd() throws {
        let json = """
        [{"cmd":"GetOsd","code":0,"value":{"Osd":{
          "channel":0,
          "bgcolor":0,
          "osdChannel":{"enable":1,"name":"Test Camera","pos":"Lower Right"},
          "osdTime":{"enable":1,"pos":"Top Center"},
          "watermark":0
        }}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<OsdEnvelope>].self, from: json)
        let osd = try #require(result.first?.value?.Osd)
        #expect(osd.osdChannel?.isEnabled == true)
        #expect(osd.osdChannel?.name == "Test Camera")
        #expect(osd.osdTime?.isEnabled == true)
    }

    @Test func decodesAbility() throws {
        let json = """
        [{"cmd":"GetAbility","code":0,"value":{"Ability":{
          "abilityChn":[{"ptzType":{"ver":1,"permit":7},"mainEncType":{"ver":1,"permit":7}}],
          "videoClip":{"ver":1,"permit":7},
          "push":{"ver":1,"permit":7}
        }}}]
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode([CGIResponse<AbilityEnvelope>].self, from: json)
        let ability = try #require(result.first?.value?.Ability)
        #expect(ability.has("push"))
        #expect(ability.has("videoClip"))
        #expect(ability.capability("push")?.permit == 7)
        #expect(ability.channelCapability("ptzType", channel: 0)?.ver == 1)
        #expect(ability.channelCapability("mainEncType", channel: 0)?.permit == 7)
    }
}
