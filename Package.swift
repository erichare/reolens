// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reolens",
    platforms: [
        // 0.5.0 raises the floor to macOS 26 / iOS 26 to adopt Liquid Glass
        // and the ActivityKit + ControlWidget APIs that ship in those
        // releases. Users on macOS 14 / iOS 18 receive security-only
        // backports against the 0.4.x track per SECURITY.md.
        .macOS(.v26),
        .iOS(.v26),
        // 0.6.4 adds the AppWatch product (companion watchOS target).
        // Setting the floor at watchOS 11 lets the watch app run on
        // Series 6+ — the iOS/macOS floors are only consulted when
        // those platforms are the build destination, so this doesn't
        // affect the main app's deployment target.
        .watchOS(.v11)
    ],
    products: [
        .library(name: "ReolinkAPI", targets: ["ReolinkAPI"]),
        .library(name: "ReolinkStreaming", targets: ["ReolinkStreaming"]),
        .library(name: "ReolinkBaichuan", targets: ["ReolinkBaichuan"]),
        .library(name: "AppShared", targets: ["AppShared"]),
        // 0.6.4 — Minimal watchOS-facing surface used by the
        // companion Watch App target in `ReolensiOS.xcodeproj`.
        // Depends only on `ReolinkAPI` (pure HTTP+JSON) to avoid
        // dragging UIKit/AppKit-leaning code into the watch build.
        .library(name: "AppWatch", targets: ["AppWatch"]),
        .executable(name: "Reolens", targets: ["Reolens"])
    ],
    dependencies: [
        // Sparkle 2 powers the in-app updater. The SPM artifact is an
        // XCFramework — `swift build` links it, and `Scripts/build-app.sh`
        // copies + re-signs Sparkle.framework into the produced .app
        // bundle so the framework is on the runtime rpath.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "ReolinkAPI",
            path: "Sources/ReolinkAPI",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "ReolinkStreaming",
            dependencies: ["ReolinkAPI"],
            path: "Sources/ReolinkStreaming",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "ReolinkBaichuan",
            dependencies: ["ReolinkAPI"],
            path: "Sources/ReolinkBaichuan",
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // Cross-platform app domain layer shared by the macOS app and
            // the iPad/iPhone app: camera persistence, sessions, discovery,
            // notifications, downloads, Keychain. Anything that does NOT
            // require AppKit/UIKit lives here.
            name: "AppShared",
            // 0.5.1 — `AllRecordingsView` and the recording-row
            // helpers import `ReolinkStreaming` for `StreamURLs`.
            // Declared explicitly here so a clean build resolves
            // cleanly and the iOS Xcode build's dependency-scan
            // warning stops firing.
            dependencies: ["ReolinkAPI", "ReolinkStreaming", "ReolinkBaichuan"],
            path: "Sources/AppShared",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.6.4 — Watch-app-facing library. Kept deliberately
            // thin: a slim Codable mirror of `CameraEntry` so the
            // watch can decode `cameras.json` from the App Group
            // container without compiling all of AppShared (which
            // pulls in SwiftUI views, AVFoundation playback, etc.).
            // The watch target consumes this product from Xcode and
            // adds its own minimal `@main` shell. See
            // `Sources/AppWatch/README.md` for setup steps.
            name: "AppWatch",
            dependencies: ["ReolinkAPI"],
            path: "Sources/AppWatch",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "Reolens",
            dependencies: [
                "ReolinkAPI",
                "ReolinkStreaming",
                "ReolinkBaichuan",
                "AppShared",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "App",
            // 0.5.0 — Widgets/ is a separate WidgetKit app-extension
            // target built by Xcode, not by SPM. Excluding it from
            // the main Reolens target keeps `swift build` clean and
            // prevents the @main collision between
            // `ReolensApp` and `ReolensWidgetsBundle`.
            exclude: ["Info.plist", "Reolens.entitlements", "Reolens.dev.entitlements", "Widgets"],
            swiftSettings: [
                // StrictConcurrency is implicit at swift-tools-version 6.0;
                // enabling it explicitly is rejected by the toolchain.
                // Keep ExistentialAny as an opt-in until the codebase is
                // fully migrated.
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "ReolinkAPITests",
            dependencies: ["ReolinkAPI"],
            path: "Tests/ReolinkAPITests"
        ),
        .testTarget(
            name: "ReolinkStreamingTests",
            dependencies: ["ReolinkStreaming"],
            path: "Tests/ReolinkStreamingTests"
        ),
        .testTarget(
            name: "ReolinkBaichuanTests",
            dependencies: ["ReolinkBaichuan", "ReolinkAPI"],
            path: "Tests/ReolinkBaichuanTests"
        ),
        // End-to-end integration test target. Drives the full
        // ReolinkAPI client through a mocked Reolink device using
        // URLProtocol — covers the path no unit test can: login →
        // token cache → batched commands → retry-on-loginRequired.
        .testTarget(
            name: "ReolensE2ETests",
            dependencies: ["ReolinkAPI"],
            path: "Tests/ReolensE2ETests"
        ),
        // AppShared privacy / sync semantics tests. The protocol
        // tests cover Reolink wire format; this target covers the
        // app's *differentiator* — Keychain sync, notification
        // routing, log redaction, preview-cache atomicity, and the
        // recording-downloader URL-leak prevention. AGENTS.md §12.
        .testTarget(
            name: "AppSharedTests",
            dependencies: ["AppShared", "ReolinkAPI"],
            path: "Tests/AppSharedTests"
        )
    ]
)
