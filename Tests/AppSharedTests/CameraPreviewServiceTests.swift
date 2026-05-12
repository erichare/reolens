import Testing
import Foundation
@testable import AppShared

/// CameraPreviewService caches snapshots on disk and is consumed
/// synchronously from SwiftUI view bodies. Pin its atomicity +
/// purge-on-remove contracts.
@Suite("CameraPreviewService")
struct CameraPreviewServiceTests {

    @Test("storeFromLive writes the bytes to disk")
    func storeFromLiveWrites() async {
        let svc = CameraPreviewService.shared
        let id = UUID()
        let channel = 0
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("payload".utf8)) // JPEG SOI + junk
        await svc.storeFromLive(data: data, cameraID: id, channel: channel)
        let read = svc.cachedData(cameraID: id, channel: channel)
        #expect(read == data)
        await svc.purge(cameraID: id)
    }

    @Test("cachedAt reflects the write timestamp")
    func cachedAtReturnsRecentDate() async {
        let svc = CameraPreviewService.shared
        let id = UUID()
        let channel = 1
        let before = Date()
        await svc.storeFromLive(data: Data([0x01, 0x02]), cameraID: id, channel: channel)
        let mod = svc.cachedAt(cameraID: id, channel: channel)
        let after = Date()
        let modDate = try? #require(mod)
        if let modDate {
            #expect(modDate >= before.addingTimeInterval(-1))
            #expect(modDate <= after.addingTimeInterval(1))
        }
        await svc.purge(cameraID: id)
    }

    @Test("purge removes the cached file")
    func purgeRemoves() async {
        let svc = CameraPreviewService.shared
        let id = UUID()
        let channel = 2
        await svc.storeFromLive(data: Data([0xAA]), cameraID: id, channel: channel)
        #expect(svc.cachedData(cameraID: id, channel: channel) != nil)
        await svc.purge(cameraID: id)
        #expect(svc.cachedData(cameraID: id, channel: channel) == nil)
    }

    @Test("purge is per-camera (other cameras' caches survive)")
    func purgeIsScopedToCamera() async {
        let svc = CameraPreviewService.shared
        let purgedID = UUID()
        let survivorID = UUID()
        await svc.storeFromLive(data: Data([0x01]), cameraID: purgedID, channel: 0)
        await svc.storeFromLive(data: Data([0x02]), cameraID: survivorID, channel: 0)
        await svc.purge(cameraID: purgedID)
        #expect(svc.cachedData(cameraID: purgedID, channel: 0) == nil)
        #expect(svc.cachedData(cameraID: survivorID, channel: 0) != nil)
        await svc.purge(cameraID: survivorID)
    }
}
