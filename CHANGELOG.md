# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
