import Testing
import Foundation
@testable import AppShared

/// 0.5.1 — Cellular toggle defaults to OFF; setting flips persist
/// through UserDefaults so `BookmarkAutoDownloader.makeSession()`
/// reads the live value on next session creation.
@Suite("BackgroundDownloadPreferences", .serialized)
struct BackgroundDownloadPreferencesTests {

    @Test("Cellular access defaults to false on a fresh install")
    func defaultIsFalse() {
        UserDefaults.standard.removeObject(forKey: BackgroundDownloadPreferences.allowCellularKey)
        #expect(!BackgroundDownloadPreferences.allowCellular)
    }

    @Test("Setting allowCellular persists through UserDefaults")
    func setterPersists() {
        UserDefaults.standard.removeObject(forKey: BackgroundDownloadPreferences.allowCellularKey)
        BackgroundDownloadPreferences.allowCellular = true
        #expect(UserDefaults.standard.bool(forKey: BackgroundDownloadPreferences.allowCellularKey))
        BackgroundDownloadPreferences.allowCellular = false
        #expect(!UserDefaults.standard.bool(forKey: BackgroundDownloadPreferences.allowCellularKey))
    }
}
