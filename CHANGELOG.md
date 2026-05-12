# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-05-12

The first release with full platform parity between macOS, iPadOS, and
iPhone. Three blocker bugs in the iOS/iPadOS app are fixed, and tile
rearrangement lands across every list and grid in the app with the
iOS-home-screen jiggle UX.

Also introduces `AGENTS.md` at the repo root — the engineering
principles that gate every change going forward: platform parity by
default, device-local credentials, no third-party analytics, no
credentials in logs, backward-compatible sync schema.

### Added
- **Picture-in-Picture on iOS/iPadOS.** Tap the PiP button on a camera's
  single-channel view and the live feed pops out into a draggable,
  resizable floating window — keep an eye on a camera while you use
  another app. Routes through `AVPictureInPictureController` against
  the player's existing `AVSampleBufferDisplayLayer`, so entering PiP
  is a smooth handoff with no extra decode. Audio session is set up
  defensively so an active Talkback session isn't clobbered.
- **Save Snapshot** on every camera tile. Captures the latest decoded
  frame and saves it as a PNG. macOS writes to `~/Pictures/Reolens/`
  (the new file is revealed in Finder). iOS writes to Photos via the
  minimum `.addOnly` PhotoKit permission — Reolens never reads your
  library. Available from the tile's context menu / long-press menu;
  a brief HUD confirms the save on iOS.
- **Pinch-to-zoom + drag-to-pan** in the iOS single-channel view.
  Digital zoom up to 4× for inspecting still detail (license plates,
  package labels). Double-tap resets to fit. Purely visual — for
  optical pan/tilt/zoom on supported cameras, the PTZ control bar
  below the tile is still the right surface.
- **Grid presets on iOS/iPadOS** — full parity with macOS. The Layout
  menu in the toolbar exposes Adaptive, Spotlight, Single, 2×2, 3×3,
  4×4, and 5×5. Spotlight mirrors the macOS layout exactly: one big
  primary tile + four right-column thumbnails + three bottom-strip
  tiles. The preset is persisted per device and syncs across all your
  Apple devices via iCloud.
- **Camera search** with a `.searchable` field in the macOS sidebar,
  the iPad sidebar, and the iOS Live / Devices tabs. Matches display
  name or host, case- and diacritic-insensitive. Useful when an NVR
  has 16+ channels or you've added several hubs.
- **Shortcuts & Siri integration.** Defines an `OpenCameraIntent` and
  `ReolensShortcuts` provider so users can say "Hey Siri, open the
  Front Door camera in Reolens" or chain a camera open into a
  Shortcuts automation. The intent only stores the camera's UUID — no
  credentials cross the intent boundary. macOS opens the camera in the
  detail pane; iPad routes through the sidebar's content/detail
  columns; iPhone switches to the Live tab and pushes the camera's
  detail view.
- **iPad: "Devices" entry in the sidebar and a "+" toolbar button.**
  iPad users previously had no path to `AddCameraView` at all — the
  sidebar showed Live / Recordings / Settings but never Devices, and
  the "+" only existed inside the unreachable Devices view. Now the
  sidebar mirrors macOS: always-visible "+" plus a "More" menu with
  "Rearrange Cameras".
- **"Enter Password" recovery flow across all three platforms.**
  Synced cameras (iCloud Drive carries the camera list; passwords stay
  device-local in Keychain by design) now have a discoverable path to
  store the password on this device. Surfaces:
  - iOS/iPadOS: action button on the "No password on this device"
    placeholder, swipe action on the camera row, context-menu item.
  - macOS: dedicated `MissingPasswordDetailView` in the detail pane
    when a credentials-less device is selected, plus a context-menu
    item on every sidebar row. New `LiveCameraTile.onEnterPassword`
    callback for grid-tile entry points.
  - New shared `EnterPasswordSheet` view in `AppShared` — read-only
    host/port/username, password-only editing, never writes anywhere
    but Keychain.
- **Tap-and-hold reorder with jiggle, everywhere tiles or rows appear.**
  Long-press 0.7s on any tile in the channel grid or any row in the
  device sidebar / Cameras section enters reorder mode. Tiles do the
  iOS-home-screen jiggle (randomized phase per tile, ±2° amplitude),
  drag-and-drop is enabled (uses `ChannelDragPayload` / new
  `DeviceDragPayload`), and tap-to-view is suppressed so the user
  can't accidentally launch the player while moving things around.
  Tap Done, press Escape (macOS), or tap outside any tile to exit.
  Honors Reduce Motion: a static dashed outline replaces the rotation
  for users who have that accessibility setting enabled.
  - New shared `JiggleModifier` in `AppShared`.
  - New `Reorderable.swift` (`ReorderList.move` / `.reconciled`)
    primitives for the device-list reorder.
  - New `DeviceDragPayload` (UTI `com.reolens.deviceDrag`, exported).
  - Device-list order is **device-local** (UserDefaults) — different
    platforms have different layouts, and avoiding a `cameras.json`
    schema bump keeps older Reolens versions on the user's other
    Apple devices fully compatible.

### Fixed
- **iOS/iPadOS: tap-to-view a camera tile actually works.** The grid
  previously wrapped each tile in a `NavigationLink` without passing
  the tile's `onTap` closure, so the tile's gesture recognizer fought
  with the navigation link and the user saw no response or a delayed
  push. Reworked `CameraGridView` to use programmatic
  `.navigationDestination(item:)` driven by an `onTap` closure,
  mirroring the "tap → state → destination" pattern macOS already
  uses. Each tile also gets proper accessibility labels and hints.
- **Recording download URL no longer leaks credentials to the unified
  log.** `RecordingDownloader.start(_:)` previously logged the full
  URL at `privacy: .public`, which embeds the camera username and
  password as query parameters when no session token is available.
  Sanitized via a new `RecordingDownloader.sanitizedDescription(of:)`
  that strips `user` / `password` / `token` query items before
  logging. Per AGENTS.md §3.

### Changed
- **Keychain items are explicitly non-syncing.** Added
  `kSecAttrSynchronizable: false` to all Keychain reads/writes so
  passwords can't sync via iCloud Keychain even if the user enables
  that setting system-wide. Belt-and-suspenders alignment with the
  AGENTS.md "credentials are device-local" principle. Delete-by-id
  matches on `kSecAttrSynchronizableAny` so legacy items from
  pre-0.3.0 are still cleaned up.
- `ChannelDragPayload` is now `public` (was `package`) so the iOS app
  target (a separate Xcode project consuming `AppShared` as an SPM
  library product) can also wire `.draggable`/`.dropDestination` for
  channel reorder. Same UTI (`com.reolens.channelDrag`, exported).
- macOS sidebar's "+" toolbar item is now a `ToolbarItemGroup` with a
  "More" menu containing "Rearrange Devices" so reorder mode has a
  non-gesture entry point (AGENTS.md accessibility rule).

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

[Unreleased]: https://github.com/jestatsio/reolens/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/jestatsio/reolens/releases/tag/v0.3.0
[0.2.3]: https://github.com/jestatsio/reolens/releases/tag/v0.2.3
[0.2.2]: https://github.com/jestatsio/reolens/releases/tag/v0.2.2
[0.2.1]: https://github.com/jestatsio/reolens/releases/tag/v0.2.1
[0.2.0]: https://github.com/jestatsio/reolens/releases/tag/v0.2.0
[0.1.1]: https://github.com/jestatsio/reolens/releases/tag/v0.1.1
[0.1.0]: https://github.com/jestatsio/reolens/releases/tag/v0.1.0
