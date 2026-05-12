# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — TBD

First multi-platform release. Reolens now ships natively for macOS,
iPad, and iPhone from a single repository, with shared protocol and
domain code.

### Added
- **iPad and iPhone apps** — true native SwiftUI experience for both
  size classes (not a Catalyst port). Same brand and design cues as
  the Mac app, adapted to touch idioms: TabView on iPhone,
  three-column `NavigationSplitView` on iPad, swipe actions, and
  hold-to-talk talkback. iOS 18 minimum.
- **iCloud Drive sync** — camera list, grid layout, channel order,
  rotation, dual-lens overrides, and codec preferences sync across
  all your devices via the `iCloud.com.reolens.Reolens` ubiquity
  container. Passwords stay per-device in Keychain (never leave the
  device they were entered on). Falls back to local-only storage
  when iCloud is unavailable.
- New `AppShared` SPM library that holds the cross-platform domain
  layer (camera persistence, sessions, discovery, notifications,
  Reolink Keychain) — consumed by both the macOS and iOS app
  targets so platform-specific UI does not duplicate logic.

### Changed
- `Sources/ReolinkStreaming/LiveVideoView` is now multi-platform
  (`NSViewRepresentable` on macOS, `UIViewRepresentable` on iOS) so
  the existing RTSP/RTP/VideoToolbox stack renders identically on
  both platforms with no logic changes.
- `Package.swift` now declares `.iOS(.v18)` alongside `.macOS(.v14)`.

## [0.1.1] — TBD

Hotfix release.

### Fixed
- App crashed on launch with `Trace/BPT trap: 5` inside the
  `UNUserNotificationServiceConnection.call-out` queue. Swift 6.2's
  approachable concurrency was inferring the
  `UNUserNotificationCenter` callback closures in `EventNotifier` as
  inheriting `@MainActor` isolation; UN dispatches them on its own
  serial queue, so the runtime's actor-isolation check tripped and
  killed the process before the window could appear. The two relevant
  closures (in `refreshPermissionStatus` and `notify`) are now
  explicitly typed `@Sendable` to opt out of caller isolation.

## [0.1.0] — 2026-05-11

First public release.

### Added
- Native macOS app for Reolink cameras and NVRs (SwiftUI, Apple Silicon + Intel)
- Multi-camera grid with adaptive, spotlight, 2×2, 3×3, and 4×4 layouts
- Drag-to-rearrange tile order, persisted per device
- Full PTZ control (all 17 ops including presets and patrol)
- Two-way talkback for supported cameras
- JPEG-snapshot live preview with hardware-decoded streaming fallback
- Rich macOS push notifications for motion / AI alarm events with trigger
  frame inline
- Auto-update infrastructure via Sparkle (signed appcast on reolens.io)
- About panel with version + Check-for-Updates menu item
- Homebrew cask available via the `jestatsio/reolens` tap
- Direct download as a signed, notarized DMG
- End-to-end integration test for the CGI client
- CI smoke launch test on every PR

### Notes
- macOS 14 Sonoma minimum
- All camera passwords stored in the macOS Keychain — never in plain text
- No analytics, no telemetry, no accounts

[Unreleased]: https://github.com/jestatsio/reolens/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jestatsio/reolens/releases/tag/v0.1.1
[0.1.0]: https://github.com/jestatsio/reolens/releases/tag/v0.1.0
