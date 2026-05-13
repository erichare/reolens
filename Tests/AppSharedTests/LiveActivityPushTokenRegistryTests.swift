import Testing
import Foundation
@testable import AppShared

/// 0.5.1 — Push token registry persists per-activity APNs tokens
/// so a future server-driven sender can update Live Activities
/// remotely. Round-trip and forget contracts pinned here.
@Suite("LiveActivityPushTokenRegistry")
struct LiveActivityPushTokenRegistryTests {

    @Test("Register + snapshot round-trips a token")
    func registerRoundTrips() async {
        let registry = LiveActivityPushTokenRegistry()
        let token = LiveActivityPushTokenRegistry.Token(
            activityID: "act-123",
            cameraID: UUID(),
            pushTokenHex: "deadbeef",
            issuedAt: Date()
        )
        await registry.register(token)
        let snapshot = await registry.snapshot()
        #expect(snapshot.contains(where: { $0.activityID == "act-123" && $0.pushTokenHex == "deadbeef" }))
    }

    @Test("forget(activityID:) removes the token")
    func forgetRemoves() async {
        let registry = LiveActivityPushTokenRegistry()
        let token = LiveActivityPushTokenRegistry.Token(
            activityID: "act-456",
            cameraID: UUID(),
            pushTokenHex: "cafebabe",
            issuedAt: Date()
        )
        await registry.register(token)
        await registry.forget(activityID: "act-456")
        let snapshot = await registry.snapshot()
        #expect(!snapshot.contains(where: { $0.activityID == "act-456" }))
    }

    @Test("Re-registering the same activity ID overwrites the previous token")
    func reRegisterOverwrites() async {
        let registry = LiveActivityPushTokenRegistry()
        let cameraID = UUID()
        let first = LiveActivityPushTokenRegistry.Token(
            activityID: "act-789",
            cameraID: cameraID,
            pushTokenHex: "aaaaaa",
            issuedAt: Date()
        )
        let second = LiveActivityPushTokenRegistry.Token(
            activityID: "act-789",
            cameraID: cameraID,
            pushTokenHex: "bbbbbb",
            issuedAt: Date()
        )
        await registry.register(first)
        await registry.register(second)
        let snapshot = await registry.snapshot()
        let matches = snapshot.filter { $0.activityID == "act-789" }
        #expect(matches.count == 1)
        #expect(matches.first?.pushTokenHex == "bbbbbb")
    }
}
