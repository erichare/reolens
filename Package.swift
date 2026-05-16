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
        .iOS(.v26)
    ],
    products: [
        .library(name: "ReolinkAPI", targets: ["ReolinkAPI"]),
        .library(name: "ReolinkStreaming", targets: ["ReolinkStreaming"]),
        .library(name: "ReolinkBaichuan", targets: ["ReolinkBaichuan"]),
        // 0.7.0 — Reolink UDP P2P wire format. Pure value-type
        // codec; transport / discovery / NAT-traversal layers
        // sit on top in later phases. See
        // `docs/remote-connectivity.md`.
        .library(name: "ReolinkBcUdp", targets: ["ReolinkBcUdp"]),
        // 0.7.0 Phase 2 — discovery client + transport surface
        // for the Reolink P2P service. Depends on ReolinkBcUdp
        // for the wire codec.
        .library(name: "ReolinkP2P", targets: ["ReolinkP2P"]),
        .library(name: "AppShared", targets: ["AppShared"]),
        .executable(name: "Reolens", targets: ["Reolens"]),
        // 0.7.0 — small diagnostic CLI for end-to-end smoke
        // tests of the remote-connectivity stack against a real
        // Reolink camera. Not shipped to users; lives in the
        // package so `swift run RemoteSmoke <uid> <user> <pass>`
        // works from a checkout.
        .executable(name: "RemoteSmoke", targets: ["RemoteSmoke"])
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
            // 0.7.0 Phase 1 (remote connectivity) — BcUdp wire
            // codec. Pure value-type encode/decode of the three
            // packet kinds (Disc / Data / Ack) Reolink uses when
            // the camera is reached over UDP via their P2P
            // service. No networking, no actors, no transport.
            // See `docs/remote-connectivity.md`.
            name: "ReolinkBcUdp",
            path: "Sources/ReolinkBcUdp",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            // 0.7.0 Phase 2 (remote connectivity) — discovery
            // client + BcUdp transport protocol. Depends on the
            // pure-codec ReolinkBcUdp module for the wire shapes;
            // adds the actor + state machine that looks a camera
            // up by UID via the `p2p*.reolink.com` cluster.
            // Concrete NWConnection-backed transport lands in a
            // follow-up; this phase ships the actor with a stub-
            // able transport surface so the fallback / retry
            // logic is fully testable today.
            name: "ReolinkP2P",
            // 0.7.0 Phase 3d — `RemoteTransport` conforms to
            // `BcMessageTransport` from ReolinkBaichuan, so the
            // P2P module gains a Baichuan dependency. The
            // direction is "Baichuan defines the control-plane
            // protocol; P2P provides a transport that satisfies
            // it" — kept acyclic by leaving Baichuan unaware of
            // the concrete remote-transport type.
            dependencies: ["ReolinkBcUdp", "ReolinkBaichuan"],
            path: "Sources/ReolinkP2P",
            swiftSettings: [
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
        .executableTarget(
            // 0.7.0 — diagnostic CLI for end-to-end smoke
            // tests of `RemoteTransport` against a real
            // Reolink camera. Run as:
            //   swift run RemoteSmoke <uid> <username> <password>
            name: "RemoteSmoke",
            dependencies: ["ReolinkP2P", "ReolinkBaichuan", "ReolinkBcUdp"],
            path: "Sources/RemoteSmoke",
            swiftSettings: [
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
        .testTarget(
            // 0.7.0 Phase 1 — BcUdp codec round-trips. Pinned
            // by structural property tests (encode → decode is
            // identity) plus byte-layout tests that assert each
            // field lives at the documented offset.
            name: "ReolinkBcUdpTests",
            dependencies: ["ReolinkBcUdp"],
            path: "Tests/ReolinkBcUdpTests"
        ),
        .testTarget(
            // 0.7.0 Phase 2 — discovery client fallback /
            // redirect / timeout behavior, driven by a stub
            // transport so the suite runs offline.
            name: "ReolinkP2PTests",
            dependencies: ["ReolinkP2P", "ReolinkBcUdp"],
            path: "Tests/ReolinkP2PTests"
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
