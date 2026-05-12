import Testing
import Foundation
@testable import AppShared

/// AGENTS.md §7 — `cameras.json` is read by every Reolens install on
/// the user's iCloud account, including older versions. New fields
/// must decode-and-ignore on old apps; absent fields must be
/// tolerated by new apps. These tests pin both directions.
@Suite("CameraEntry schema")
struct CameraEntrySchemaTests {

    @Test("Decoding a 0.3.0-shaped entry tolerates absent 0.4.x fields")
    func decodesOldSchema() throws {
        // 0.3.0 entries had no `tlsFingerprint` and no
        // `hiddenAppBadgeChannels`. New apps must still decode them.
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "displayName": "Front Door",
            "host": "192.168.1.42",
            "port": 80,
            "username": "admin",
            "useHTTPS": false,
            "preferredCodec": "h264",
            "channelStreamRotations": {},
            "dualLensOverrides": [],
            "gridPreset": "adaptive",
            "channelOrder": []
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(CameraEntry.self, from: json)
        #expect(entry.displayName == "Front Door")
        #expect(entry.tlsFingerprint == nil)
        #expect(entry.hiddenAppBadgeChannels.isEmpty)
    }

    @Test("Encoding a 0.4.1 entry preserves new fields for older apps to ignore")
    func encodesNewFields() throws {
        let id = UUID()
        let entry = CameraEntry(
            id: id,
            displayName: "Driveway",
            host: "10.0.0.5",
            username: "admin",
            tlsFingerprint: "abc123base64==",
            hiddenAppBadgeChannels: [0, 2]
        )
        let data = try JSONEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("tlsFingerprint"))
        #expect(json.contains("abc123base64=="))
        #expect(json.contains("hiddenAppBadgeChannels"))
    }

    @Test("Round-trip preserves all fields")
    func roundTrips() throws {
        let id = UUID()
        let entry = CameraEntry(
            id: id,
            displayName: "Back Yard",
            host: "192.168.1.7",
            port: 443,
            username: "user",
            useHTTPS: true,
            tlsFingerprint: "xyz==",
            hiddenAppBadgeChannels: [1, 3]
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CameraEntry.self, from: data)
        #expect(decoded == entry)
    }
}
