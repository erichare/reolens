import SwiftUI
import AppKit

/// Custom About panel content. macOS shows this in a sheet-like floating
/// window when the user picks **Reolens → About Reolens**.
///
/// Reads version + build from the running bundle so we never duplicate the
/// version string in Swift — `Info.plist` is the single source of truth.
struct AboutView: View {
    private let appName: String
    private let version: String
    private let build: String
    private let copyright: String

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        self.appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Reolens"
        self.version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        self.build = (info["CFBundleVersion"] as? String) ?? "0"
        self.copyright = "© 2026 J&E Stats. MIT licensed."
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon. `NSApplication.shared.applicationIconImage` returns
            // the bundle's icon at the size requested via `.size = …`.
            // Falling back to `NSImage(named: NSImage.applicationIconName)`
            // keeps the dev build (no .icns embedded yet) from rendering a
            // blank square.
            if let icon = NSApplication.shared.applicationIconImage
                ?? NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
            }

            VStack(spacing: 4) {
                Text(appName)
                    .font(.system(size: 22, weight: .semibold))
                Text("Version \(version) (\(build))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("A modern, Apple-silicon-native macOS client for Reolink cameras and NVRs.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            HStack(spacing: 12) {
                Link("Website", destination: URL(string: "https://reolens.io")!)
                Link("GitHub",  destination: URL(string: "https://github.com/jestatsio/reolens")!)
                Link("Issues",  destination: URL(string: "https://github.com/jestatsio/reolens/issues")!)
                Link("J&E Stats", destination: URL(string: "https://jestats.io")!)
            }
            .font(.system(size: 11))

            Text(copyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 360)
    }
}

#Preview {
    AboutView()
}
