import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OSLog

#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
import Photos
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "snapshot")

/// Platform-aware save flow for captured live-camera frames.
///
/// macOS: writes a PNG to `~/Pictures/Reolens/` using a sortable
/// timestamped filename (`Reolens-{camera}-{yyyyMMdd-HHmmss}.png`).
/// No save panel — the goal is "I tapped Snapshot, where did it go" being
/// answerable from the toolbar item action without any modal click.
///
/// iOS/iPadOS: requests `add-only` Photos authorization (the minimum
/// privilege Apple supports) and writes the frame to the camera roll
/// via `PHPhotoLibrary`. Failing authorization surfaces a system alert
/// and the save no-ops.
public enum SnapshotSaver {

    public enum Result: Sendable, Equatable {
        case saved(URL?)
        case denied
        case noFrame
        case failed(String)
    }

    /// Save the given image as a PNG. `cameraName` is used in the file
    /// name so a Photos library or a `~/Pictures/Reolens/` folder is
    /// browsable without inspecting metadata.
    public static func save(_ image: CGImage?, cameraName: String) async -> Result {
        guard let image else { return .noFrame }
        let stamp = Self.timestamp()
        let safeName = sanitize(cameraName)
        let filename = "Reolens-\(safeName)-\(stamp).png"
        #if os(macOS)
        return await saveOnMac(image: image, filename: filename)
        #elseif os(iOS) || os(visionOS)
        return await saveOnPhone(image: image, filename: filename)
        #else
        return .failed("Unsupported platform")
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    private static func saveOnMac(image: CGImage, filename: String) async -> Result {
        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return .failed("Pictures folder not available")
        }
        let dir = pictures.appendingPathComponent("Reolens", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failed("Couldn't create folder: \(error.localizedDescription)")
        }
        let url = dir.appendingPathComponent(filename)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return .failed("Couldn't create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            return .failed("PNG encode failed")
        }
        log.info("Saved snapshot to \(url.path, privacy: .public)")
        return .saved(url)
    }
    #endif

    // MARK: - iOS / iPadOS

    #if os(iOS) || os(visionOS)
    private static func saveOnPhone(image: CGImage, filename: String) async -> Result {
        // Request the minimum privilege Photos supports: add-only access.
        // We don't read the user's library; we only append.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            log.info("Photos access denied")
            return .denied
        case .notDetermined:
            // The above call resolves .notDetermined, so this branch is
            // defensive — treat as denied if we somehow land here.
            return .denied
        @unknown default:
            return .denied
        }
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.pngData() else {
            return .failed("PNG encode failed")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            // Filename includes the (sanitized) camera display name. Mark
            // private so a user's camera names don't end up in unified
            // logs / sysdiagnose / Console.app dumps.
            log.info("Saved snapshot \(filename, privacy: .private) to Photos")
            return .saved(nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    #endif

    // MARK: - Filename helpers

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = name
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return trimmed.isEmpty ? "camera" : String(trimmed.prefix(40))
    }
}
