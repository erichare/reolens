# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.3] — TBD

Hotfix release — first iOS TestFlight upload to actually land.

### Fixed
- iOS upload to App Store Connect was rejected by altool with three
  validation errors:
  - "Missing required icon file ... 120x120"
  - "Missing required icon file ... 152x152"
  - "Missing Info.plist value ... CFBundleIconName"

  The `AppiOS/Resources/Assets.xcassets/AppIcon.appiconset/` directory
  shipped with `Contents.json` declaring a 1024×1024 universal icon
  but no actual PNG file alongside it, so the asset compiler emitted
  an empty icon set. Apple's "single 1024 source, generate the rest"
  workflow needs both the PNG present *and* `CFBundleIconName=AppIcon`
  in the iOS Info.plist (declared via `project.yml`'s
  `info.properties`).

  Fix: copied `Resources/icon-master.png` into the iOS asset catalog
  as `icon-1024.png`, referenced it from `Contents.json`, and added
  the `CFBundleIconName` key. Also bumped the iOS marketing version
  from `0.2.0` to `0.2.3` so it's aligned with the macOS app version.

## [0.2.2] — TBD

Hotfix release — v0.2.1's macOS DMG still failed to launch.

### Fixed
- v0.2.1's macOS build *did* run the embedded-provisioning-profile
  step in `Scripts/build-app.sh`, but the guard that protects that
  step required `AC_API_KEY_P8_PATH` (a file path), and the release
  workflow only provides `AC_API_KEY_P8_BASE64` (the contents). The
  guard fell through silently and the .app shipped without an
  `embedded.provisionprofile`, hitting the same AMFI -413 we thought
  we fixed in 0.2.1.

  Two changes:
  1. `Scripts/build-app.sh` now decodes `AC_API_KEY_P8_BASE64` into
     a temp file when the path env isn't set — same dance
     `Scripts/build-ios.sh` already does.
  2. The guard is now hard-fail rather than silent-skip: if we're
     signing with a real Developer ID identity, the script aborts
     unless the profile-embed step succeeds. Catches future
     regressions of the same shape before they ship.

## [0.2.1] — TBD

Hotfix release.

### Fixed
- macOS app failed to launch with `Trace/BPT trap: 5` / `RBSRequestErrorDomain
  Code=5 / NSPOSIXErrorDomain Code=163`. AMFI was rejecting the bundle
  with `AppleMobileFileIntegrityError -413 "No matching profile found"`
  because v0.2.0's iCloud entitlements
  (`com.apple.developer.icloud-container-identifiers`,
  `ubiquity-container-identifiers`, `icloud-services`) require an
  embedded provisioning profile, and the Developer ID Direct build
  pipeline wasn't producing one. v0.1.x didn't have iCloud entitlements
  so the gap was invisible.

  Fix: extended `Scripts/asc_ensure_profile.py` (originally for the iOS
  App Store profile) to also create a `MAC_APP_DIRECT` profile via the
  App Store Connect REST API; `Scripts/build-app.sh` now downloads it
  and copies it into `Reolens.app/Contents/embedded.provisionprofile`
  before code-signing. Idempotent — repeated builds reuse the same
  profile.

## [0.2.0] — 2026-05-12

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

[Unreleased]: https://github.com/jestatsio/reolens/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/jestatsio/reolens/releases/tag/v0.2.3
[0.2.2]: https://github.com/jestatsio/reolens/releases/tag/v0.2.2
[0.2.1]: https://github.com/jestatsio/reolens/releases/tag/v0.2.1
[0.2.0]: https://github.com/jestatsio/reolens/releases/tag/v0.2.0
[0.1.1]: https://github.com/jestatsio/reolens/releases/tag/v0.1.1
[0.1.0]: https://github.com/jestatsio/reolens/releases/tag/v0.1.0
