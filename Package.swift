// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reolens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ReolinkAPI", targets: ["ReolinkAPI"]),
        .library(name: "ReolinkStreaming", targets: ["ReolinkStreaming"]),
        .library(name: "ReolinkBaichuan", targets: ["ReolinkBaichuan"]),
        .executable(name: "Reolens", targets: ["Reolens"])
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
        .executableTarget(
            name: "Reolens",
            dependencies: ["ReolinkAPI", "ReolinkStreaming", "ReolinkBaichuan"],
            path: "App",
            exclude: ["Info.plist", "Reolens.entitlements"],
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
        )
    ]
)
