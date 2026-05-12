# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-05-12

The "see further, see faster" release. 0.3.0 brought parity across
macOS, iPadOS, and iPhone for live viewing; 0.4.0 pulls the existing
recording, event, and AI-detection data that's already coming back
from the camera into ambient, glanceable surfaces on every platform.

The biggest user-visible default change is **the camera grid no
longer auto-streams every tile live** — it now shows still previews
that refresh on demand. The old behavior is one toggle away (Settings
→ General → "Live previews in grid").

### Added

- **Recording timeline scrubber, phase 1.** Two new visual surfaces
  above the recordings list, on macOS, iPad, and iPhone:
  - **Day-density calendar** — every day of the current month is
    rendered as a small cell with a coloured dot for days that have
    recordings. Tap a day to jump there. Powered by the `Status`
    bitfield the Reolink CGI `Search` response has been returning all
    along but nothing was consuming. Implemented in a new shared
    `MonthRecordingDensity` view in `AppShared`.
  - **Per-day segment timeline** — a horizontal 24-hour proportional
    bar showing each recording segment plus AI-event ticks from the
    live Baichuan alarm stream (`CameraSession.aiEventLog`). Tap a
    segment to play. New shared `DayTimelineStrip` view in `AppShared`.
  - The fully custom cross-segment scrub UI with thumbnail preview is
    on the 0.5 roadmap; 0.4.0 keeps using the native `AVPlayer` for
    intra-clip seeking.
- **AI event filters.** Multi-select chip row above every recordings
  view: Motion · People · Vehicle · Pet · Face · Package · Visitor ·
  Other. Filters the list and the new timeline strip. New shared
  `AIEventFilterBar` view in `AppShared`.
- **Per-AI-tag notification filters.** Settings → Notifications gains
  an "AI event categories" section so users can mute the specific
  triggers that flood (often "pet" or "other") without losing person /
  vehicle alerts. Backed by per-tag bools in `EventNotifier`.
- **iCloud Keychain Sync opt-in (Settings → Privacy on macOS,
  Settings → "iCloud Keychain Sync" section on iOS/iPadOS).** Off by
  default — passwords stay device-local exactly as AGENTS.md §4
  describes. Turning the toggle on re-saves every camera password on
  the synchronizable side of Keychain via the new
  `Keychain.migrate(accounts:toSync:)` and `CameraStore.migrateKeychainSync(toSync:)`
  API. Turning it off only changes where new writes go; entries
  already synced to iCloud are left in place so the user's other
  devices keep working. AGENTS.md §4 is amended in this release to
  document the opt-in path.
- **Static previews in the camera grid (default behavior change).**
  New `CameraPreviewService` actor in `AppShared` owns a per-(camera,
  channel) JPEG cache under `~/Library/Caches/Reolens/previews/`. The
  grid tile renders the cached image; the live RTSP stream only starts
  when the user opens a single-channel detail view. The first decoded
  keyframe of every live view silently updates the cache via the new
  `CameraPreviewImage` shared SwiftUI view + the `storeFromLive`
  hook in `LiveCameraTile` / `LiveTileView`. New Settings toggle
  "Live previews in grid" restores 0.3.0's continuous-streaming
  behavior. Big battery / thermal / cellular-data win on iOS, and
  aligns with AGENTS.md §10 ("default to the sub-stream in grids;
  only main-stream when a tile is focused").
- **Pull-to-refresh on the grid.** iOS / iPadOS attach a `.refreshable`
  modifier to the camera grid; pulling down re-fetches `cmd=Snap` for
  every visible tile in parallel via the actor's deduped refresh
  pipeline. macOS gets an explicit ⌘R "Refresh" toolbar button in
  the grid control bar (macOS has no native pull idiom, but the same
  action is one keystroke away).
- **Continuity / Handoff between iPhone, iPad, and Mac.** Each camera
  detail view publishes an `NSUserActivity` with type
  `io.reolens.camera-detail`; the receiving device routes it through
  the existing `OpenCameraIntent` execution path so handoff reuses
  the same code Shortcuts and Siri already do. AGENTS.md §11 — the
  payload carries only the camera UUID + channel index, no hostnames
  or credentials. Spotlight indexing falls out for free because
  `isEligibleForSearch` is on by default. New shared
  `CameraContinuity` helper + `.reolensCameraActivity(...)` view
  modifier in `AppShared`. `NSUserActivityTypes` declared in both
  Info.plists.
- **macOS: "Run in the menu bar when closed" mode (Settings → General).**
  Off by default. When enabled, closing the main window leaves Reolens
  running with a small camera icon in the menu bar; clicking the icon
  shows a popover with the latest motion / AI events across every
  active camera session plus "Open Reolens" and "Quit" actions.
  Closes the long-standing gap where macOS notifications stopped firing
  the moment the user closed the window. New
  `App/MenuBar/MenuBarController.swift` singleton owns the
  `NSStatusItem`, the popover, and (macOS 13+) the
  `SMAppService.mainApp` login-item registration so Reolens can start
  in the menu bar at login.
- **iOS Settings tab → per-channel settings (parity with macOS).**
  iOS / iPadOS `SingleChannelView` gains a third tab next to Live and
  Recordings; renders the same OSD toggles, AI-capability summary,
  and battery info macOS has had since 0.3. The `ChannelSettingsView`
  itself moved from the macOS app target into `Sources/AppShared/`
  per AGENTS.md §1 — same code on every platform.

### Fixed

- **iOS / iPadOS rich motion notifications now actually fire.** The
  notification pipeline (`EventNotifier`) ran identically on both
  platforms, but iOS users were never prompted for notification
  permission unless they manually visited Settings → Notifications
  → "Request permission". `EventNotifier.notify` gates delivery on
  `permissionStatus == .authorized`, which never reached
  `.authorized` until that prompt fired. `ReolensiOSApp` now
  auto-requests permission on first launch (with a `.notDetermined`
  idempotence guard), mirroring the macOS app's behavior. Rich
  alarm notifications with the trigger-frame attachment described in
  the README will now actually appear on iPhone and iPad.
- **macOS AI events: Baichuan subscription now auto-reconnects.**
  `CameraSession.startBaichuanEvents` was fire-and-forget: any failure
  (Reolink hub session cap, brief LAN blip, hub reboot) silently
  killed the push stream and only the 2-second CGI poll caught
  subsequent state. The macOS case is especially likely to lose the
  hub's session cap to a paired iPad. Now wrapped in a bounded
  exponential-backoff loop (2 s → 60 s) that resumes the alarm-event
  subscription automatically once the hub frees the slot.
- **Notification tap now opens the correct camera.** `recordAIEvent`
  was passing the per-event UUID to `EventNotifier.notify(cameraID:)`
  instead of the camera's UUID, so every tap landed on a camera that
  didn't exist and silent-returned. On top of that, cold-launching
  via a notification tap lost the pending intent because
  `NotificationTapDelegate.didReceive` fires *after* the scene's
  launch `.task` already drained it. `AppIntentFocus.request` now
  posts an `AppIntentFocus.didUpdate` NotificationCenter
  notification; both app scenes subscribe via `.onReceive` and
  re-drain — taps now route to the camera reliably on hot and cold
  launch.
- **First-launch hub connect auto-retries.** `CameraSession.connect()`
  used to do a single login attempt and surface any failure as
  `.error`, which forced the user to click Reconnect after every
  launch where macOS hadn't quite finished joining Wi-Fi / resolving
  the hub yet. Now does up to 4 attempts with 2/4/8 s exponential
  backoff while the status stays `.connecting`. Auth-style failures
  (the error mentions "login" / "auth" / "unauthorized" /
  "password") short-circuit the loop so a bad password doesn't get
  hammered. Total budget on a truly-unreachable hub is ~14 s.
- **Reconnect on iCloud-synced hub no longer silently fails.**
  Two stacked bugs. (a) `CameraDetailView.task(id:)` was keyed off
  `session.entry.id` — Reconnect creates a *new* session for the
  same camera UUID, so the task didn't re-fire and the new session
  sat at `.disconnected` forever. Both macOS and iPadOS views now
  key the task off `ObjectIdentifier(session)`. (b) Old session
  disconnect was fired in a detached Task; the new session's login
  raced it and the hub rejected with "too many sessions."
  `CameraStore.reconnect(_:)` now awaits the old session's
  `disconnect()` before creating the new one. Reconnect now works
  the way delete-and-readd previously did, without losing camera
  metadata or the iCloud sync state.
- **Grid layouts no longer let tiles overlap.** Mixed-aspect cells in
  a `LazyVGrid` rendered at fractional pixel boundaries on some
  window sizes and produced visible overlap between adjacent tiles.
  Adaptive grids now use `GridItem(.fixed(tileWidth))` (not
  `.flexible()`) so SwiftUI uses the exact column dimensions we
  computed. Fixed N×N grids constrain each cell to the smaller of
  "fit by width" and "fit by height" so the grid never asks for a
  cell larger than what fits the visible area.
- **Dual-lens cameras no longer letterbox to a thin strip in the
  grid.** Adaptive grids now give dual-lens (32:9) cells their own
  shorter row height, so the stitched frame fills its cell naturally.
  Fixed N×N grids keep uniform 16:9 cells but center-crop dual-lens
  snapshots to fill — matching what `.resizeAspectFill` already does
  in live mode. Users no longer see "the dual-lens cameras are too
  long" with huge black bars.
- **Battery cameras now get an initial preview.** Preview-mode tiles
  for sleeping cameras showed "No preview yet" forever because the
  `cmd=Snap` JPEG endpoint returns nothing useful while the camera
  is offline at the radio layer. `CameraPreviewImage` gained an
  optional `prepareForFetch` closure; both tile views now wake the
  camera via Baichuan before the first snapshot fetch, then it goes
  back to sleep on its own — same flow `startPlayer()` uses for
  live view.
- **First-keyframe preview cache update no longer races VT decode.**
  The `naturalSize` hook fired the moment the first sample was
  enqueued, but `currentSnapshot()` reads `latestPixelBuffer` which
  is populated by a parallel VideoToolbox decode that hasn't
  finished yet. Now polls up to 5 times (0.8 s apart) so the decode
  has time to produce the pixel buffer before we silently write a
  nil to disk.
- **Stills → Live toggle now actually starts the player on every
  tile.** `.task(id: channel.channel)` doesn't re-fire when
  `preferPreview` flips (the channel hasn't changed), so tiles
  stayed frozen on the cached snapshot. Both tile views gained
  `.onChange(of: preferPreview)` that tears down the player on
  Stills and starts it (subject to the same eligibility guards) on
  Live.
- **Failed RTSP players fall back to the cached still.** When the
  hub rejected a session with "stream stalled after 6 s" the full
  tile turned into a red error block, covering an otherwise-fine
  cached snapshot. Failed-state tiles now render `CameraPreviewImage`
  under a compact "Live unavailable" badge with a Retry button; the
  detailed error survives in the tooltip / accessibility label.
- **Layout `Edit Layout` toolbar button removed.** Long-press is
  already discoverable (the helper text below the layout picker calls
  it out) and the new Layout menu has a "Rearrange Cameras" entry
  for accessibility users. ⌘E still works via an invisible binding,
  preserving AGENTS.md §9's "every gesture needs a non-gesture
  alternative."
- **Menu bar popover surfaces channel names.** Recent-events rows
  led with the device's `displayName` ("Home Hub") for every event,
  so a multi-channel hub couldn't tell you which paired camera
  fired. Rows now lead with the channel's name ("Back Yard",
  "Front Door") and only show the device name on the secondary
  line when it differs from the channel name.
- **Menu bar icon is now a Reolens-logo template image** drawn at
  runtime as a lens-ring + iris + pupil silhouette and marked
  `isTemplate = true`, so macOS auto-tints it to match the menu
  bar's appearance (light, dark, graphite, accent) regardless of
  system theme.

### Performance

- **Stills → Live no longer slams the hub's RTSP cap.** New
  `LivePlayerStartGate` actor in `AppShared` enforces ≥500 ms
  spacing between concurrent player starts. Reolink hubs cap
  simultaneous RTSP sessions (commonly 4–8, varies by firmware,
  not queryable) — without throttling, a 16-tile grid flipping
  Live opened 16 sessions in parallel, the hub accepted a few and
  left the rest stuck in connecting forever. The 16-tile grid now
  warms up over ~8 s instead of all-or-nothing; the indefinite-
  spin case disappears.

### Changed

- `Sources/AppShared/Keychain.swift` no longer hard-codes
  `kSecAttrSynchronizable: false`. Writes read the user's opt-in flag
  (`com.reolens.iCloudKeychainSync` UserDefaults key); reads use
  `kSecAttrSynchronizableAny` so a device that previously synced and
  later opted out still sees its passwords.
- `EventNotifier.notifyAI` is now the master switch for AI
  notifications; per-tag bools (`notifyPerTag[.person]` etc.) gate
  individual categories beneath it. Existing users upgrade with all
  per-tag bools defaulting to true, so behavior is unchanged unless
  they customize.
- `Sources/AppShared/CameraStore.swift` purges any cached preview
  snapshots for a camera the moment it's removed, alongside the
  existing Keychain delete.
- `AGENTS.md` §4 amended to describe the iCloud Keychain Sync
  opt-in carve-out; the default remains device-local.

### Deferred to 0.5

These roadmap items have foundational dependencies (a new
WidgetExtension Xcode target, a `WindowGroup`-scene refactor) that
deserve their own focused PR cycle so they can soak through
TestFlight without holding the rest of 0.4.0 back:

- Home Screen / Lock Screen / Control Center widgets and iOS Live
  Activities for in-flight motion events. The motion-event pipeline
  in `CameraSession.aiEventLog` is already shaped for the Activity
  request — the missing piece is the widget-extension target plus its
  signing / provisioning profile.
- Stage Manager / multi-window on iPad. The single-`WindowGroup`
  scene works fine today; multi-window needs a `WindowGroup(for:)`
  refactor and per-window state.
- "Overnight digest" notification + widget. Depends on widget
  infrastructure landing first.

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

[Unreleased]: https://github.com/jestatsio/reolens/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/jestatsio/reolens/releases/tag/v0.4.0
[0.3.0]: https://github.com/jestatsio/reolens/releases/tag/v0.3.0
[0.2.3]: https://github.com/jestatsio/reolens/releases/tag/v0.2.3
[0.2.2]: https://github.com/jestatsio/reolens/releases/tag/v0.2.2
[0.2.1]: https://github.com/jestatsio/reolens/releases/tag/v0.2.1
[0.2.0]: https://github.com/jestatsio/reolens/releases/tag/v0.2.0
[0.1.1]: https://github.com/jestatsio/reolens/releases/tag/v0.1.1
[0.1.0]: https://github.com/jestatsio/reolens/releases/tag/v0.1.0
