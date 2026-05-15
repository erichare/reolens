# Changelog

All notable changes to Reolens are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.1] — 2026-05-?? (pending journey sweep)

A hardening release. No new storylines — every surface 0.6.0 shipped
got a careful second look. Settings is reorganized from the ground up,
the half-wired NL Search UI is finished, the live-view time-to-first-
frame is now measurable end-to-end, and a new local-only diagnostics
layer surfaces errors the app used to swallow — without phoning home.
Plus a tighter accessibility pass on the high-traffic surfaces and a
handful of small features.

### Added

- **Diagnostics Center** — local-only error log surface in
  Settings → Advanced. `AppError` (typed enum: network, streaming,
  auth, playback, persistence, notification, schedule, bookmark) +
  `AppErrorRecorder` (file-backed actor in the App Group container,
  500-record cap, atomic writes, never relayed to a server). Browse,
  filter by category, copy-to-clipboard for support threads. Preserves
  AGENTS.md §5 "zero telemetry" posture.
- **NL Search history** — last 10 successful queries surface as
  "Recent" suggestions on the no-match state, with an inline Clear.
  Device-local in `UserDefaults`; case-insensitive de-dup so re-typing
  a query lifts the existing entry instead of stacking.
- **macOS keyboard shortcuts** — new Camera menu wires ⌘R to "Refresh
  Live Tiles" and ⌘1–⌘9 to jump to the first nine cameras. Wiring
  rides Notification.Name so the menu stays decoupled from view state.
- **TTFF signposter** — `LiveVideoPlayer` emits an `OSSignposter`
  interval on `com.reolens.streaming` / category `TTFF`. Open
  Instruments with the os_signpost instrument and the cold/warm time-
  to-first-frame is directly measurable. See
  [docs/perf-baselines/README.md](docs/perf-baselines/README.md).
- **`docs/ROADMAP.md`** — consolidates the scattered future-work
  notes from AGENTS.md / SECURITY.md / CHANGELOG into one place.

### Changed

- **Settings reorganized into seven shared buckets** — Cameras,
  Notifications & Events, Display, Background & Storage, Privacy &
  Sync, Advanced, About. Both platforms compose from the same bucket
  views (`SettingsBucketSections.swift`) so iOS Form and macOS TabView
  can't drift apart again. Behind `AppPreferences.useReorganizedSettings`
  (default on); legacy layout preserved as an emergency revert until
  0.7.x.
- **NL Search UI completed** — search-result rows are now tappable
  (jump to the hit's day in the standard list). The no-match state
  shows three concrete example prompts plus "Recent" history. A
  privacy footer reinforces that the search runs on-device.
- **Coverage baselines ratcheted** — AppShared 13.81% → 14.31%,
  ReolinkAPI 56.47% → 58.82%, ReolinkStreaming 23.70% → 23.82%. Total
  test count 354 (up from 340 in 0.6.0).
- macOS `CFBundleVersion` 15 → 16, iOS 10 → 11.

### Fixed

- **Battery camera wake failures now logged** — five sites
  (`ChannelSettingsView`, `LiveCameraTile`, `LiveTileView`) used to
  swallow `wakeBatteryCamera` errors silently, leaving snap endpoints
  returning stale frames with no diagnostic trail. Failures now route
  through `AppErrorRecorder` so a flapping battery camera is
  discoverable from Diagnostics Center.
- **`requestPermission` distinguishes denial from error** —
  `EventNotifier.requestPermission` used to collapse a thrown
  `requestAuthorization` error and a user-denied permission into the
  same `granted = false`. They're now distinct; thrown errors record
  to Diagnostics Center.
- **Recording index decode failures surface** — `RecordingIndex` used
  to log a warning on a corrupt `recording-index.v1.json` but the
  user had no way to discover the index had reset. Failures now also
  record to Diagnostics Center.
- **Notification permission denied is no longer silently retried** —
  the diagnostic capture means support threads can include the
  specific failure mode.

### Accessibility

- **PTZ controls** — directional pad, zoom buttons, and focus buttons
  now have VoiceOver labels ("Pan up", "Zoom in", "Focus near", …) via
  a shared `PTZAccessibility.label(for:)` helper. Pad / zoom / focus
  groups carry containing labels.
- **WeeklyScheduleEditor cells** — each of the 168 cells announces
  weekday + hour + on/off state via `accessibilityValue`. AGENTS.md §9
  — no information conveyed by color alone.

Full Dynamic Type sweep, reduced-motion guards, and tile-level labels
defer to a follow-up — text styles already do most of that work, and
the deeper sweep needs a real device.

### Internal

- New audits: `docs/audit-0.6.1.md` (documentation gaps),
  `docs/audit-0.6.1-error-sites.md` (top-10 `try?` triage),
  `docs/audit-0.6.1-journey.md` (pre-release click-through checklist).
- New tests: `AppErrorRecorderTests` (10), `DiagnosticsBundleTests`
  (4), `NLSearchHistoryTests` (7), three new `AppPreferences` cases.
- Three RTSP `Task.sleep` `try?` sites annotated `// safe:` so future
  audits skip them — the cancellation throw is intentional.
- Three remaining 0.6.0 carve-out files (`AllRecordingsView`,
  `RecordingsView` macOS + iOS) stay over the 800-LOC repo guideline.
  The view split is timeboxed to 0.7.x because the snapshot-test
  safety net would push beyond the 0.6.1 cycle.

## [0.6.0] — 2026-05-14

The largest release the project has shipped. Five storylines pulled
together by a single unifying piece of plumbing.

1. **The user-reported notification fix.** iOS / iPadOS push
   notifications now actually arrive. The root cause was
   `MotionEventRelaySettings.subscriberEnabled` gating
   `registerForRemoteNotifications()` with no iOS UI to flip it; the
   release lands the toggle in Settings → Notifications, defaults it
   ON when the user grants notification permission, and pairs it with
   a new **Notification Diagnostics** screen + a 1,000-record rolling
   **Notification log** so this class of issue is self-diagnosing
   forever.
2. **Cross-day AI search.** Type "packages this week" or "vehicles
   yesterday at the driveway" in the All Recordings search bar and get
   results across the last 30 days. On Apple Intelligence hardware the
   prompt goes through an on-device `FoundationModels` `@Generable`
   query plan (synonym handling, fuzzy camera-name matching); every
   other device falls back to a deterministic regex parser. The
   user's prompt is the only thing the model sees — no recording data
   crosses the model boundary.
3. **Visual schedule editors.** Two surfaces share a reusable 7×24
   weekly grid (`WeeklyScheduleEditor`): one for the camera's
   recording schedule (`GetRec` / `SetRec`), one for motion-detection
   alarms (`GetMdAlarm` / `SetMdAlarm`) with optional per-AI-tag
   overrides — "quiet vehicles overnight, still alert on people."
   Capability-aware: firmware that responds with `rspCode = -9`
   degrades to a read-only display rather than failing silently.
4. **Architecture pass.** Five tech-debt extractions land at once:
   `RecordingsLoader` actor pulls 12+ duplicated `@State` variables
   out of the iOS / macOS RecordingsView pair (with a generation
   guard that stops stale reloads from publishing previous-day data
   on rapid date flips, and a three-tier detection memoization that
   eliminates per-render re-scans); `RecordingIndex` actor stores
   30 days of cross-day metadata; `PollManager` extracts the polling
   lifecycle out of `CameraSession`; `CameraStore` carves into three
   focused stores (`AppPreferences`, `CameraKeychainStore`,
   `CameraListPersistence`); `RecordingsScreenHeader` consolidates
   the shared chrome stack between the two platform shells.
5. **The bookmark, finally working.** New `sourceFileName` field on
   the bookmark schema so the launch-time reconciler can re-enqueue
   any background download that silently failed. HTTP-status
   validation on the URLSession delegate stops expired-token 401
   error pages from being saved as a `.mp4`. Explicit Delete button
   on every bookmark row with a confirmation dialog that names the
   downloaded clip when present. Tapping a bookmark whose local file
   is missing now actually re-triggers the download rather than just
   toasting "still downloading…" forever.

Plus a long tail of UX fixes the user surfaced during the release:
auto-wake battery cameras on single-camera detail open (no more
"tap the sleeping overlay" second tap), restore the last-viewed
camera on iOS / iPadOS cold launch, hide the AI filter chips on
empty days, pin empty-state messages to the top of the window
instead of centering them in a void, drop the macOS HomeKit section
(non-Catalyst macOS can't reach the public HomeKit framework
anyway), and lazy bookmark enumeration off the main thread.

### Added

- **Notification fix + iOS UI** — Settings → Notifications →
  "Receive motion events from other devices" toggle bound to
  `MotionEventRelaySettings.subscriberEnabled`. Defaults ON the
  first time the user grants notification permission. `Motion
  RelayPublisherSection` moves from Settings → Privacy to Settings
  → Notifications on macOS for symmetry.
- **Notification Diagnostics screen** — `RelayDiagnostics` actor
  surfaces `UNAuthorizationStatus`, APNS registration timestamp +
  last failure, `CKAccountStatus`, subscription-install state,
  publisher save-error history, recent silent-push receipt count,
  per-camera mute summary, and the throttle drop counter. Send-
  test-notification button. New view: Settings → Notifications →
  Diagnostics.
- **Notification log** — `NotificationHistory` actor backs a 1,000-
  record rolling SQLite-style JSON log in the App Group container.
  Captures every notification's outcome at each gate (`posted` /
  `throttledCooldown` / `permissionDenied` / `perCameraMuted` /
  `tagMuted` / `globallyDisabled` / etc.) plus silent-push receipts
  and tap events. New `NotificationLogView` reachable from Settings
  → Notifications and from the Diagnostics screen. Filters: per-
  camera, per-tag, per-delivery-status. Tap → deep-link to the
  matching recording when within retention.
- **Cross-day AI search via `RecordingIndex` actor** — versioned
  file-backed cross-day index (`recording-index.v1.json` in the
  App Group container, 30-day rolling retention, idempotent per-
  (camera, day) ingest, Baichuan tag merge by filename + time
  overlap). Ingestion hooks fire from `RecordingsLoader.reload()`
  and `AllRecordingsView`'s streaming load — no new network calls,
  just stores what was already fetched. New `RecordingNLSearcher`
  translates prompts → structured queries (`tagFilter` /
  `dateRange` / `cameraIDs`). `AllRecordingsView` gains a
  `.searchable` field that calls `planWithModel` (FoundationModels
  on Apple Intelligence devices, deterministic regex everywhere
  else); the model and deterministic parser's outputs are
  *unioned* on tags + camera IDs so the FM path never produces a
  worse result than deterministic alone.
- **Recording schedule editor** — `RecordingScheduleView` reachable
  from per-channel Settings. Reads via `GetRec` (handles both the
  canonical `Rec.schedule.table` shape and the legacy
  `Rec.scheduleTable.mainStream` shape), edits via the reusable
  7×24 `WeeklyScheduleEditor`, writes via `SetRec` (always emits the
  canonical shape). Capability fallback: `-9 notSupport` puts the
  editor in read-only mode with an explanatory notice.
- **Motion-detection schedule editor + per-tag overrides** —
  `MotionScheduleView` for the channel's main `MdAlarm` schedule
  plus optional per-AI-tag override schedules. Example: main
  schedule on 06:00-22:00, but quiet `vehicle` overnight and
  trigger `people` 24/7. New `Commands.getMotionSchedule` /
  `setMotionSchedule` mirror the recording-schedule shape.
- **`WeeklyScheduleEditor` reusable component** — 7×24 grid (one
  cell per hour, Sun..Sat × 00..23) with single-tap toggle and a
  drag-paint gesture for sweeping multiple cells. Always / Never /
  Revert / Apply controls. Pure SwiftUI, no networking — drives
  both schedule surfaces above.
- **iOS bookmarks parity** — toolbar bookmark button with scoped
  count badge on the per-camera Recordings tab, reusing the
  existing cross-platform `BookmarksSheet`. macOS gains the auto-
  download path on `addBookmark` so iOS users see clips already
  cached when iCloud syncs the bookmark over.
- **`sourceFileName` on `RecordingBookmark`** — additive,
  forward-compatible field so the launch-time bookmark reconciler
  can re-enqueue downloads without doing a Search to find the
  matching file. Legacy bookmarks created pre-0.6.0 decode to
  `nil`; the next interaction repopulates the field.
- **Bookmark reconciler + tap re-enqueue** —
  `BookmarkAutoDownloader.reconcile(across:)` waits up to 30 s per
  session for `.connected`, then re-enqueues every bookmark whose
  local clip is missing. Fired on app launch + scene activation.
  `playBookmark` on `AllRecordingsView` now re-triggers the
  download when the local file is missing and surfaces an accurate
  toast (`alreadyDownloaded` / `alreadyInFlight` / `enqueued` /
  `cannotResolveSource`).
- **Explicit bookmark delete** — every row in `BookmarksSheet` has
  a red trash button next to Play / Export. Confirmation dialog
  adapts its copy to "Removes the bookmark and the downloaded clip
  from this device" vs just "Removes the bookmark." Both the
  button and the iOS swipe-delete route through
  `BookmarkAutoDownloader.removeBookmark(_:)` which cancels any in-
  flight URLSession download, deletes the local `<id>.mp4`, and
  removes the JSON entry.
- **Per-camera health badges** — `CameraNotificationHealth` surfaces
  "last notification at X" annotation on the camera list so users
  can spot a camera that's been silent.
- **Adaptive motion-event polling** — `AdaptivePollSchedule`:
  10 s foreground / 60 s background / 120 s under Low Power Mode.
  Phase changes take effect on the next sleep, never mid-poll.
- **`HomeKitBridge` scaffolding (iOS only)** — `HomeKitBridge`
  actor with availability state machine, entitlement detection,
  per-camera opt-in (`CameraEntry.homeKitEnabled`). Settings →
  Notifications → HomeKit section on iOS. Actual `HMCameraProfile`
  registration is stubbed pending Apple MFi certification —
  treated as a 0.7 opportunity, not a 0.6.0 deliverable. macOS
  doesn't render the section because Apple removed public HomeKit
  framework headers from the macOS SDK.
- **Single-camera battery-cam auto-wake** — opening a battery /
  sleeping camera's detail view now auto-fires the Baichuan wake
  call on appear. Grid tiles skip the wake to avoid burning
  battery cams on every Live-grid render.
- **iOS / iPadOS last-camera-on-launch** — `AppPreferences.last
  ViewedCameraID` round-trips through UserDefaults; the platform
  shell restores the previous camera on cold launch (skipped when
  an App Intent has a more-specific destination).
- **XCUITest harness** — new `ReolensiOSUITests` target with 3
  baseline journeys (cold-launch reaches primary navigation,
  Settings → Notifications header renders, Notification log row
  scrolls into view + pushes a navigation destination). Wired into
  CI as a best-effort step that auto-selects the first available
  iPhone simulator.

### Changed

- **Coverage gate is now enforced** — `Scripts/coverage-gate.sh`
  switched from a single global 80% threshold (which nothing met)
  to a per-target regression gate against
  `Scripts/coverage-baselines.txt`. Failed PRs now block on
  coverage *regression* rather than absolute floor; baselines
  ratchet upward via `COVERAGE_FORCE_UPDATE_BASELINE=1`. The CI
  step lost its `continue-on-error: true` flag. Long-term 80%
  goal is still tracked in the script's header.
- **`CameraStore` carved into three focused stores** —
  `AppPreferences` (developerMode, showCameraNameOnFeed,
  lastViewedCameraID), `CameraKeychainStore` (password reads /
  writes / deletes + iCloud sync toggle + migration), and
  `CameraListPersistence` (the iCloud-backed JSON encode / decode
  boundary, with an injectable `Backend` protocol for tests).
  `CameraStore` proxies all three so the dozens of existing view
  consumers don't change.
- **`PollManager` extracted from `CameraSession`** — depth-
  counted `pausingBackgroundPolling`, injectable interval +
  `shouldContinue` gate. The session loses `pollTask` +
  `foregroundCGIOperationDepth` + `shouldResumePollingAfter
  ForegroundCGI`. Tested in isolation.
- **`RecordingsLoader` is the single source of truth for the
  per-camera recordings tab.** Both the iOS and macOS
  RecordingsView shells delegate all network state (files, sub
  files, alarm-video entries, month statuses, event log,
  `eventsUnsupported`) to the loader. Generation guard on
  `reload()` drops stale results on rapid date flips (previously a
  race could publish previous-day rows on top of the current
  day). Three-tier `effectiveDetections` (triggers → Baichuan
  overlap → live aiEventLog) is memoized per file id.
- **`RecordingsScreenHeader` consolidates the shared 3-row glass
  toolbar stack** (`MonthRecordingDensity` /
  `DayTimelineStrip` / `AIEventFilterBar`) between the iOS and
  macOS shells. The AI filter bar hides when there are zero
  loaded files — the chip row was useless when nothing could be
  filtered and contributed to the empty-state void users were
  surfacing.
- **Empty-state messages pin to the top** rather than centering in
  the full remaining window height. `ContentUnavailableView`
  centers by default, which left a visible void above the message;
  the new `topPinnedEmptyState` wrapper pushes the empty space to
  the bottom where it reads as "no more list" instead of "this
  window is broken."
- **`CameraPreviewPrefetcher` respects Low Power Mode** + macOS
  resign-active stop. The prefetcher's sweep short-circuits when
  `ProcessInfo.processInfo.isLowPowerModeEnabled` returns true and
  bumps a `skippedSweepCount` for diagnostics. macOS now stops the
  prefetcher loop when the app loses front-most (was iOS only);
  `didBecomeActive` re-starts + immediate-sweeps.
- **Lazy bookmark loading off the per-day reload path** — both
  RecordingsView shells move `loadBookmarks()` out of `.task(id:
  selectedDate)` (which re-enumerated iCloud Drive on every date
  flip) into a separate one-shot `.task { }` that runs on a
  detached high-priority Task, keeping the first-render path
  unblocked.
- **Honest error messages for the schedule editors** — catch
  `ReolinkClientError` separately and render its
  `CustomStringConvertible.description` (which prints the actual
  case + payload like `Malformed response: keyNotFound...`)
  instead of `localizedDescription`'s opaque NSError-bridged
  "(Domain error N.)" string. Users no longer stare at "error 4"
  with no path forward.

### Fixed

- **Push notifications on iOS / iPadOS** (the headline user-
  reported bug). The subscriber-enabled toggle is reachable from
  Settings; default-ON behaviour matches the macOS publisher.
- **Bookmark downloads complete reliably.** Adds the
  `sourceFileName` schema field for the reconciler, HTTP-status
  validation on the URLSession delegate (a 401 expired-token
  response no longer gets saved as a `.mp4`), tap-time re-enqueue
  when the local file is missing, and launch-time reconciler that
  walks every camera's bookmarks.
- **Battery cameras don't require a second tap.** Single-camera
  detail tiles auto-wake on appear.
- **macOS HomeKit section** removed (Apple doesn't expose the
  HomeKit framework to native macOS apps, only Mac Catalyst).
- **DetectionType is now `Codable`** — necessary for the
  `RecordingIndex` persistence path.
- **`BaichuanAlarmVideoFile` gains a public memberwise init** so
  tests can construct it without poking module internals.

### Architecture / new files

- `Sources/AppShared/RecordingsLoader.swift` + `CameraSession+
  RecordingsLoader.swift`
- `Sources/AppShared/RecordingIndex.swift` +
  `RecordingNLSearcher.swift`
- `Sources/AppShared/RecordingsScreenHeader.swift`
- `Sources/AppShared/PollManager.swift`
- `Sources/AppShared/AppPreferences.swift` +
  `CameraKeychainStore.swift` + `CameraListPersistence.swift`
- `Sources/AppShared/WeeklyScheduleEditor.swift` +
  `RecordingScheduleView.swift` + `MotionScheduleView.swift`
- `Sources/AppShared/HomeKitBridge.swift` +
  `HomeKitSection.swift`
- `Sources/AppShared/RelayDiagnostics.swift` +
  `RelayDiagnosticsSection.swift` +
  `MotionRelaySubscriberSection.swift`
- `Sources/AppShared/NotificationHistory.swift` +
  `NotificationLogView.swift` +
  `CameraNotificationHealth.swift`
- `Sources/AppShared/AdaptivePollSchedule.swift` +
  `VersionedCodable.swift`
- `Sources/ReolinkAPI/Models/RecordingSchedule.swift` +
  `MotionSchedule.swift`
- `AppiOS/UITests/ReolensiOSUITests.swift` (new XCUITest target)
- `Scripts/coverage-baselines.txt`

### Tests

**~340 tests across 68 suites** (up from 183 / 49 at 0.5.1). New
suites cover `RecordingsLoader` (race condition + memoization +
3-tier detection fallback), `RecordingIndex` (idempotent ingest,
tag merge, retention purge, persistence round-trip),
`RecordingNLSearcher` (deterministic parser + merge policy),
`WeeklySchedule` (wire-format multi-shape decode), `MotionSchedule`,
`PollManager` (depth-counted pause / resume, shouldContinue gate),
`AppPreferences`, `CameraKeychainStore`, `CameraListPersistence`,
`CameraPreviewPrefetcher` (Low Power Mode skip + counter),
`HomeKitBridge` (per-camera flag round-trip + CameraEntry forward-
compat decode), and `BookmarkAutoDownloader` (sourceFileName
schema + full-cleanup delete path). XCUITest baseline added for the
iOS / iPadOS shell.

### Notes for upgraders

- **No breaking changes.** `cameras.json` decodes legacy entries
  unchanged. Bookmarks created pre-0.6.0 lack `sourceFileName` and
  resolve themselves the first time the user reopens the camera.
  All new schedule wire types tolerate both observed Reolink
  firmware shapes.
- **HomeKit exposure** lights up only on iOS / iPadOS and only
  when the build's been signed with the `com.apple.developer.
  homekit` entitlement (commented out in both
  `*.entitlements` files for now; flip to uncommented when MFi
  cert lands). Until then the bridge stays in `.entitlement
  Missing` state and renders an explanatory line.

## [0.5.1] — 2026-05-13

A "big minor" on top of 0.5.0. Five storylines:

1. **UX polish — the punch list.** Click targets, iPad layout, hub
   auto-expand, battery-camera taps, the camera-name badge that
   collided with Reolink's burned-in OSD. Every one of these was a
   small daily friction; collectively they make the app feel
   noticeably more cared-for.
2. **All Recordings.** A single hub-scoped (and cross-hub) recordings
   feed lands above the existing per-camera Recordings tab. AI filter
   pill + new Camera filter pill stack, fan-out across every channel
   in the hub (and across hubs when multiple are configured) is
   bounded so large NVRs don't slam the network.
3. **Per-camera notification toggles.** Default ON for every camera;
   silence individual cameras (indoor while you're home, contractor
   in the back yard for the afternoon) and the state syncs across
   your Apple devices via `NSUbiquitousKeyValueStore`.
4. **Pre-view bookmarks + background download.** Bookmark a recording
   without playing it (long-press / right-click / trailing-swipe on
   iOS) and the clip downloads in the background so it's available
   offline. Wi-Fi only by default; the cellular toggle is in Settings.
5. **iOS 26 / macOS 26 deepening.** FoundationModels-powered "Today"
   digest at the top of All Recordings (deterministic count-based
   fallback on devices without Apple Intelligence). Two new App
   Intents — Show Today's Events, Mute Camera Notifications — join
   Open Camera. Live Activities expand to hub-grouped semantics
   with an 8-hour stale window, relevance score, and push-token
   registration via `pushType: .token` (tokens persisted to iCloud
   Drive next to bookmarks so a future server-driven sender can pick
   them up). Filter chips adopt `glassEffect(.regular.interactive())`.

### Added

- **Hub-scoped + cross-hub All Recordings view.** New
  [`Sources/AppShared/AllRecordingsView.swift`](Sources/AppShared/AllRecordingsView.swift)
  with `AllRecordingsLoader` fanning out parallel `Commands.search`
  calls across every (hub, channel) pair via `TaskGroup`. Bounded to
  6-way concurrent globally so multi-hub setups stay polite to the
  network. Reachable from the macOS hub-detail toolbar ("All
  Recordings" button) and from the iPad sidebar's Recordings section.
  **Streaming + cache (0.5.1):** rows paint progressively as each
  (session, channel) `Search` resolves — no more waiting on the
  slowest channel before the first row appears — and the result
  caches in a new
  [`RecordingsCache`](Sources/AppShared/RecordingsCache.swift)
  actor so subsequent opens of the sheet for the same day paint
  instantly (30 s TTL on today, 1 h TTL on past days). A "Refreshing…"
  indicator surfaces while the stream fills in fresh data over the
  cache hit. The Refresh button (⌘R) bypasses the cache.
- **Bookmarks inline in All Recordings.** All Recordings shows
  **every bookmark across every camera, every day** alongside the
  selected day's recordings, in one chronological feed. The toggle
  in the header controls visibility and shows the bookmark count
  (`bookmark.fill 12`). Bookmark rows tagged with a yellow
  `bookmark.fill` glyph + a `★ Bookmarked` pill; bookmarks from
  other days carry a date prefix (`Jan 5 · 12:34:56 PM`) so the
  cross-day mix stays readable when browsing a specific day's
  recordings. Rows show a green check when the clip is downloaded
  (per `BookmarkAutoDownloader.hasLocalClip(for:)`), play from the
  local file when present, and surface a "Bookmark still
  downloading…" toast when not yet on disk. Long-press / right-
  click → Delete bookmark for cleanup.
- **Close button on the All Recordings sheet.** The controls bar
  always carries an explicit Close button (`.keyboardShortcut(.cancelAction)`),
  matching the existing `Done` button on the rich viewer, bookmarks,
  digest detail, and recording-preview sheets. On iPad / iPhone
  (where the view is pushed in a NavigationStack) the same button
  pops the stack. Audit confirmed every overlay sheet in the app
  has a clearly-labeled close affordance.
- **Background snapshot prefetcher.** New
  [`Sources/AppShared/CameraPreviewPrefetcher.swift`](Sources/AppShared/CameraPreviewPrefetcher.swift)
  proactively sweeps every connected non-battery channel and
  refreshes its cached snapshot on a 15-minute cycle (plus once on
  every `.active` scene transition). Tiles for cameras the user has
  never opened now show a real frame instead of the "No preview
  yet" placeholder. Battery / sleeping cameras are deliberately
  skipped — periodic wake to refresh a still would drain battery
  for low value; they still snapshot on demand via the existing
  `prepareForFetch` wake path. Bounded to 3 concurrent HTTP calls
  globally so multi-hub setups don't stampede the network.
  Snapshots also publish to the shared App-Group container so the
  widgets see the same fresh frames.
- **Camera filter pill.** New
  [`Sources/AppShared/CameraFilterBar.swift`](Sources/AppShared/CameraFilterBar.swift)
  mirrors the AI event filter pill; sits below it in the All
  Recordings header. Empty selection = all cameras; chips compose
  with AI filters (AND semantics).
- **Hub auto-expand + iCloud collapse memory.**
  [`Sources/AppShared/HubExpansionStore.swift`](Sources/AppShared/HubExpansionStore.swift)
  inverts the previous expanded-set semantic to a collapsed-set so
  every hub is open by default. Collapse a hub on the Mac and the
  iPad / iPhone sidebar reflects within ~30 s via
  `NSUbiquitousKeyValueStore`. Local `UserDefaults` mirror for
  iCloud-signed-out devices.
- **Per-camera notification toggles.**
  [`Sources/AppShared/CameraNotificationPreferences.swift`](Sources/AppShared/CameraNotificationPreferences.swift)
  + [`PerCameraNotificationsSection`](Sources/AppShared/PerCameraNotificationsSection.swift)
  add a Settings → Notifications row per camera. Default ON. State
  syncs across devices via `NSUbiquitousKeyValueStore`.
  `EventNotifier.notify(...)` reads it off the main actor through a
  nonisolated `isNotificationsEnabledOffMainActor(for:)` to avoid
  per-event MainActor hops on busy hubs.
- **Pre-view bookmarking on iOS.** Recording rows on iOS gain a
  "Bookmark this clip" entry in the long-press context menu plus a
  trailing-swipe action. Neither requires playing the clip first.
  Both flows route through `bookmarkAndDownload(file:)` which
  persists the bookmark via `RecordingBookmarkStore.add(_:)` and
  enqueues the clip with `BookmarkAutoDownloader`.
- **Background URLSession auto-download.**
  [`Sources/AppShared/BookmarkAutoDownloader.swift`](Sources/AppShared/BookmarkAutoDownloader.swift)
  manages a `URLSessionConfiguration.background(withIdentifier:)`
  session. Bookmark creation enqueues the clip; iOS keeps the
  download going across app suspensions, force-quits, and relaunches.
  Final files land in
  `~/Library/Application Support/Reolens/bookmarks/<bookmarkID>.mp4`
  so they survive cache eviction. New
  [`BookmarkAutoDownloadDelegate`](Sources/AppShared/BookmarkAutoDownloader.swift)
  handles `didFinishDownloadingTo` by synchronously moving the file
  to its permanent destination before the OS purges the temp file.
- **Cellular background download toggle.** New
  [`Sources/AppShared/BackgroundDownloadPreferences.swift`](Sources/AppShared/BackgroundDownloadPreferences.swift)
  + [`BackgroundDownloadsSection`](Sources/AppShared/BackgroundDownloadsSection.swift)
  surface a "Allow downloads on cellular" toggle (default OFF) in
  Settings. Background URLSessions ignore per-task
  `allowsCellularAccess` overrides, so the downloader listens for a
  `preferencesDidChange` notification, calls
  `finishTasksAndInvalidate()` on the in-flight session, and
  recreates it with the new config — toggle takes effect on the
  next enqueue without an app restart.
- **FoundationModels "Today" event digest.** New
  [`Sources/AppShared/EventSummarizer.swift`](Sources/AppShared/EventSummarizer.swift)
  produces a 1-line headline + 1–3 bullet points summarizing the
  day's recordings across every camera on the hub. On-device
  inference via Apple's `FoundationModels` framework when
  Apple Intelligence is available; deterministic count-based
  fallback otherwise ("12 clips today: 5 pet, 4 person, 3 vehicle.").
  Surfaces inline at the top of All Recordings when the date is
  today; cached per `(day, cameraIDs, totalClips)` so repeated
  re-loads short-circuit.
- **Camera-name badge toggle.** New Settings → Display section
  exposes "Show camera name on live feed" (default OFF). 0.5.1
  inverts the previous semantic: badges are hidden by default so
  Reolink's own date / time / name OSD (top-left of every frame)
  isn't covered. Per-channel hide overrides preserved in
  `ChannelSettingsView`.
- **Battery camera one-tap auto-wake.** Tapping the sleeping tile
  (macOS [`LiveCameraTile`](App/Views/LiveCameraTile.swift) +
  iOS [`LiveTileView`](AppiOS/Sources/Views/LiveTileView.swift))
  now triggers the Baichuan wake call directly and shows a "Waking…"
  indicator while the RTSP probe lands — no separate Connect button.
  Duplicate taps debounced via a per-channel `isWaking` flag.
- **Two new App Intents.**
  [`ShowTodayEventsIntent`](Sources/AppShared/AppIntents/CameraIntents.swift)
  jumps to today's events (optionally filtered to a specific camera)
  and [`MuteCameraNotificationsIntent`](Sources/AppShared/AppIntents/CameraIntents.swift)
  flips the per-camera notification preference. Both join the
  existing `OpenCameraIntent` in `ReolensShortcuts` so "Hey Siri,
  show today's events" and "Hey Siri, mute the Driveway camera"
  work from any Apple platform.
- **Hub-grouped Live Activities.**
  [`MotionEventActivityController`](AppiOS/Sources/LiveActivities/MotionEventActivityController.swift)
  keys activities by hub (`cameraID`) and *merges* follow-up fires
  on the same hub into the existing activity (dedup tags, bump
  `coalescedCount`) rather than replacing it. Dynamic Island stays
  readable on multi-channel NVRs that emit several events in quick
  succession.
- **Live Activity push token registry.** New
  [`Sources/AppShared/LiveActivityPushTokenRegistry.swift`](Sources/AppShared/LiveActivityPushTokenRegistry.swift)
  is an actor that persists per-activity APNs tokens to iCloud Drive
  next to bookmarks (`live-activity-tokens_v1.json`). The controller
  now requests activities with `pushType: .token` and forwards every
  issued token via `for await tokenData in activity.pushTokenUpdates`.
  Lays the foundation for a future server-driven sender (or a peer
  Apple device acting as relay) to push updates remotely. The local
  Baichuan-event-driven update path remains the primary driver; push
  is purely additive.

### Changed

- **iPad layout — stale-detail-pane fix.**
  [`iPadSplitShell`](AppiOS/Sources/Views/iPadSplitShell.swift)
  collapsed from a three-column `NavigationSplitView` (where the
  third "Select a camera" column never updated) to a two-column
  one. Detail column wraps `sectionContent` in a `NavigationStack`
  keyed off `selectedSection` so any sidebar tap hard-resets the
  navigation stack — fixes the user-reported "panel on the right
  stays all the time."
- **Whole-row click targets.**
  [`DeviceSidebarRow`](App/Views/CameraListView.swift) and
  [`ChannelSidebarRow`](App/Views/CameraListView.swift) on macOS
  and [`iPadSplitShell`](AppiOS/Sources/Views/iPadSplitShell.swift)
  on iPadOS now apply `.contentShape(.rect)` so clicking anywhere
  in the row (text, status dot, trailing whitespace) selects the
  camera. Channel sub-rows under hubs / NVRs get the same treatment.
- **macOS detail-pane identity.**
  [`ContentView`](App/Views/ContentView.swift) now applies
  `.id(store.selection)` so SwiftUI rebuilds
  `ChannelDetailContent` when the sidebar selection changes —
  no more carrying the previous channel's `@State tab` across
  camera switches.
- **Hub-grouped Live Activity stale window widened** from 4h to
  8h. A slow-burn evening of events no longer expires mid-watch.
- **Live Activity relevance scoring.** When multiple hubs have
  active LAs, the most-recently-active one scores higher (linear
  decay over the 8 h stale window) so Dynamic Island prefers it.
- **Filter pills are now interactive Liquid Glass.** The
  [`reolensGlassChip`](Sources/AppShared/ReolensGlass.swift)
  modifier adopts `.glassEffect(.regular.interactive())` on iOS 26
  / macOS 26 so chips morph subtly on press — matches the system
  pill behavior elsewhere in the OS. Material fallback on lower OSes
  unchanged.
- **iPad Recordings tab.**
  [`RecordingsPlaceholderView`](AppiOS/Sources/Views/Placeholders.swift)
  now lands directly in the cross-hub All Recordings view (was: a
  per-camera picker that funneled into the per-channel
  RecordingsView).
- **macOS multi-channel grid.**
  [`MultiChannelGridView`](App/Views/CameraDetailView.swift)
  gains an "All Recordings" toolbar button that opens the cross-hub
  feed in a sheet.
- **`CameraStore.expandedDevices`** replaced by
  `CameraStore.hubExpansion: HubExpansionStore` — the in-memory
  set is gone in favor of the iCloud-synced collapsed set. Internal
  API change; binding helpers in the three sidebar views updated.

### Tests

- New `Tests/AppSharedTests/HubExpansionStoreTests.swift` — default-on
  expansion, collapse round-trip, forget-on-remove.
- New `Tests/AppSharedTests/CameraNotificationPreferencesTests.swift` —
  default-on, mute round-trip, off-main-actor reader sees the
  UserDefaults mirror synchronously.
- New `Tests/AppSharedTests/EventSummarizerTests.swift` — pinned
  to the deterministic fallback path (empty input, total + top
  triggers in headline, busiest-camera bullets, quiet cameras
  omitted).
- New `Tests/AppSharedTests/LiveActivityPushTokenRegistryTests.swift` —
  register + snapshot round-trip, forget removes, re-register
  overwrites.
- New `Tests/AppSharedTests/BackgroundDownloadPreferencesTests.swift` —
  default false, UserDefaults round-trip.
- New `Tests/AppSharedTests/RecordingsCacheTests.swift` —
  set/get round-trip, past-day-fresh TTL boundary, key includes
  session ID set, single-entry + all-entries invalidation,
  startOfDay normalization.
- Final test count: **183 tests across 49 suites** (was 158 in 43
  suites at 0.5.0).

### Migration / breaking changes

- `CameraStore.expandedDevices: Set<UUID>` is gone — replaced by
  `CameraStore.hubExpansion: HubExpansionStore`. Internal-only; no
  out-of-tree consumers affected. Existing in-memory expansion state
  was already ephemeral, so there's nothing to migrate.
- `AllRecordingsView` initializer changed to take
  `sessions: [CameraSession]` rather than a single session. The
  single-session convenience `init(session:)` is preserved so
  existing call sites compile without changes.
- Camera-name badge default flipped to hidden. Users who relied on
  the badge will see it disappear on first launch of 0.5.1; the
  Settings → Display toggle restores it.

## [0.5.0] — 2026-05-12

The biggest release Reolens has shipped. Three storylines:

1. **Widgets and Live Activities.** Home Screen, Lock Screen, and Control Center widgets land on iOS / iPadOS, alongside in-flight motion-event Live Activities with full Dynamic Island support. macOS gets desktop widgets so platform parity holds.
2. **Hardening pass.** Two real force-unwrap crash paths (Baichuan talkback audio format, VideoToolbox decoder buffer pointers) replaced with typed guards. CloudKit motion-event relay grew deduplication, per-camera rate-limiting with burst summaries, and a multi-account guard. A handful of `try?` swallows in long-running protocol paths now log failures explicitly. CI gained two new gates: an 80%-coverage floor on `AppShared` + `Reolink*` libraries (was aspirational), and a version-alignment check between macOS and iOS marketing versions.
3. **Two new features.** Clip bookmarks + MP4 export pairs naturally with the upgraded recording scrubber. Motion privacy zones expose Reolink's per-channel privacy-mask arrays as a visual rectangle editor on both platforms.
4. **Connection robustness overhaul (Theme E).** Connect is now parallelized after login (DevInfo + GetChannelstatus race instead of running back-to-back), jittered exponential backoff replaces the flat 2/4/8 s schedule, a 30 s overall connect deadline keeps stuck attempts bounded, and the sidebar shows step-by-step progress text ("Logging in…", "Fetching channels…", "Retrying in 3 s") instead of just a yellow dot. iOS Local Network permission is probed up front and the discovery sheet shows a "Settings → Privacy" hint when denied. /24 discovery is throttled to 32 concurrent probes (was unbounded — saturated iOS's network stack and starved Bonjour). Probe timeout dropped from 1.5 s → 1 s so a full scan completes in ~3 s.

Deployment floor moves to **iOS 26 / macOS 26** to adopt Liquid Glass and the ActivityKit / ControlWidget APIs that ship in those releases. Users on iOS 18 / macOS 14 continue to receive security backports against the 0.4.x track per [`SECURITY.md`](SECURITY.md).

### Added

- **Widgets + Live Activities (iOS / iPadOS + macOS desktop).** New `ReolensiOSWidgets` extension target ([AppiOS/Widgets/](AppiOS/Widgets/)) ships five widget surfaces:
  - `CameraSnapshotWidget` — Home Screen widget (small / medium / large) showing the latest cached snapshot for a configurable camera plus the last-motion timestamp. Configurable via a new `SelectCameraIntent` App Intent.
  - `LastMotionWidget` — Lock Screen widget (inline / circular / rectangular) showing which camera most recently fired and how long ago.
  - `MotionDigestWidget` — Home Screen widget (medium / large) rendering the overnight digest count, top cameras, and an hourly sparkline.
  - `OpenCameraControlWidget` — Control Center widget (iOS 26+) wiring `OpenCameraIntent` to a one-tap shortcut into a camera's live view.
  - `MotionEventActivityWidget` — in-flight motion-event Live Activity for Lock Screen + Dynamic Island, with compact, expanded, and minimal presentations. Auto-dismisses at the 4-hour cap; a fresh fire on the same camera replaces the prior activity (no stacking).
- **Shared App-Group container.** New [`Sources/AppShared/SharedContainer.swift`](Sources/AppShared/SharedContainer.swift) is the only path widget / activity extensions use to read snapshots, recent events, and daily digests. Device-local, never CloudKit-synced. Codified in AGENTS.md §16.
- **Live Activity controller.** [`AppiOS/Sources/LiveActivities/MotionEventActivityController.swift`](AppiOS/Sources/LiveActivities/MotionEventActivityController.swift) holds the start / update / end lifecycle. Replace-on-new-event semantics keep Dynamic Island readable during busy scenes; trigger frames live in the App-Group `activity-assets/` directory and are purged at 4 h.
- **Multi-window scenes (iPad Stage Manager).** New `ReolensScene` enum in [`Sources/AppShared/ReolensScene.swift`](Sources/AppShared/ReolensScene.swift) feeds a `WindowGroup(for:)` setup so each camera can open in its own scene under Stage Manager. macOS gains "Open in New Window" on every camera row.
- **Recording scrubber phase 2 (domain layer).** New [`ThumbnailCache`](Sources/AppShared/ThumbnailCache.swift) (content-addressed JPEG cache with 500 MB LRU eviction) and `SegmentScrubModel` (cross-segment seek + snap-to-nearest within 90 s) ship the data layer for the custom scrubber UI.
- **Overnight digest.** Deterministic [`DigestBuilder`](Sources/AppShared/DigestBuilder.swift) summarizes a day's motion events by camera, AI tag, hourly histogram, and peak hour. Settings expose a per-user time picker (default 07:00 local); the daily-digest task drops a `DailyDigestRecord` into the shared container for the `MotionDigestWidget` to pick up.
- **Clip bookmarks + MP4 export.** [`RecordingBookmark`](Sources/AppShared/RecordingBookmark.swift) is a forward-compatible per-camera bookmark model (`bookmarks_v1.json` per AGENTS.md §7) synced via iCloud Drive — references only, no media uploaded. [`ClipExporter`](Sources/AppShared/ClipExporter.swift) composes one or more underlying MP4 segments via `AVMutableComposition` and exports to MP4 via `AVAssetExportSession`.
- **Motion privacy zones.** [`PrivacyZone`](Sources/AppShared/PrivacyZoneEditorModel.swift) + `PrivacyZoneEditorModel` + `RectEditor` cover the up-to-4-rectangle privacy-mask editor; [`PrivacyZoneEditorView`](Sources/AppShared/PrivacyZoneEditorView.swift) renders the SwiftUI surface in per-channel Settings on both platforms (drag to draw, drag to move, × to delete, glass-card chrome). Persists via `SetMask` to the camera with rspCode = -9 graceful fallback to local-only when firmware doesn't accept the API — see [`Sources/ReolinkAPI/Models/Mask.swift`](Sources/ReolinkAPI/Models/Mask.swift) and `Commands.getMask` / `Commands.setMask`.
- **Overnight digest scheduler + UI.** [`DigestScheduler`](Sources/AppShared/DigestScheduler.swift) actor registers a daily `UNCalendarNotificationTrigger(repeats: true)` at the user-configured hour (default 07:00), builds the `DailyDigestRecord` from yesterday's events in the App-Group container, writes it to `<AppGroup>/digests/<yyyy-MM-dd>.json`, and posts a tap-handling local notification. [`DigestDetailView`](Sources/AppShared/DigestDetailView.swift) renders the headline number, 24-hour bar chart, per-camera + per-tag breakdowns in Liquid Glass cards. Settings expose an `OvernightDigestSection` on both macOS and iOS with enable / hour-picker / preview / build-now controls.
- **MP4 clip export from bookmarks.** [`BookmarksSheet`](App/Views/BookmarksSheet.swift) gets an "Export…" button per row that routes through `RecordingsView.exportBookmark(_:)` → `NSSavePanel` → high-quality download → [`ClipExporter.export(sources:to:)`](Sources/AppShared/ClipExporter.swift) trim to the bookmark's range → final MP4 at the chosen destination. `PlayableRecording.bookmarkTrim` carries the per-source-relative range through the download/save pipeline.
- **Custom recording scrubber (phase 2).** New [`ScrubberView`](Sources/AppShared/ScrubberView.swift) sits underneath the existing `AVPlayerView` with a thumbnail rail (one keyframe per 5 s default), draggable position cursor with time-preview bubble, and time row. Background thumbnail extraction via `AVAssetImageGenerator` against the local downloaded MP4, cached through `ThumbnailCache.shared`. Cross-platform `PlatformImage` typealias bridge (NSImage on macOS, UIImage on iOS) with `jpegData(quality:)` extensions. `AVPlayerHostView` extended with optional `playerSink` callback so the surrounding sheet can drive the scrubber against the same player instance. Native AVPlayerView controls stay for accessibility fallback.
- **iPadOS multi-window.** Long-press context menu on iPadOS sidebar device + per-channel rows surfaces "Open in New Window", routing through `@Environment(\.openWindow)` against the new secondary `WindowGroup(for: ReolensScene.self)` declared on `ReolensiOSApp`. Stage Manager picks up the new scenes automatically.
- **macOS desktop widgets twin.** `App/Widgets/` mirrors `AppiOS/Widgets/` minus the iOS-only Live Activity + Control Center widgets. `CameraSnapshotWidget` switches to `NSImage(data:)`; `LastMotionWidget` drops the iOS-only accessory families and ships with `systemSmall`/`systemMedium`. `Package.swift` excludes `App/Widgets` from the main `Reolens` SPM target so `@main` doesn't collide; the directory is wired to an Xcode app-extension target (see `App/Widgets/README.md`).

### Changed

- **CloudKit motion-event relay (B3 hardening).** [`Sources/AppShared/MotionEventRelayHardening.swift`](Sources/AppShared/MotionEventRelayHardening.swift) introduces:
  - **Content-addressed record IDs** (`MotionEventRecordID.recordName(...)`) — two retries of the same event collapse to one server-side record via `serverRecordChanged` rather than creating duplicates. The timestamp is bucketed to 5 s so genuinely-different events on a busy camera stay distinct.
  - **Token-bucket rate limiting** (`MotionEventRateLimiter`) — capped at 30 events / 10 min / camera by default, with a once-per-minute "burst summary" record carrying the suppressed count so receiving devices still see *that* a burst happened.
  - **Multi-account guard** (`CloudKitAccountIdentityGuard`) — hashes the iCloud ubiquity-identity-token at first publish and refuses to publish from a different account on later runs. Surfaces a trust-changed flag for the UI to render a re-enroll modal.
- **Deployment floors raised.** `Package.swift` now declares `.macOS(.v26)` / `.iOS(.v26)` (was `.macOS(.v14)` / `.iOS(.v18)`) and `swift-tools-version: 6.2` (was `6.0`). `App/Info.plist` `LSMinimumSystemVersion` → `26.0`. `AppiOS/project.yml` deployment target → `26.0`.
- **CI gates added (B6).** Two new scripts under `Scripts/`:
  - [`check-versions.sh`](Scripts/check-versions.sh) — fails the build if `App/Info.plist` `CFBundleShortVersionString` and `AppiOS/project.yml` `MARKETING_VERSION` diverge. Wired into both `ci.yml` (every PR) and `release.yml` (first step before signing).
  - [`coverage-gate.sh`](Scripts/coverage-gate.sh) — enforces ≥ 80% line coverage on `AppShared` + the three `Reolink*` library targets. Promotes AGENTS.md §12 from aspirational to enforced.
- **B1: Force-unwrap removal.** `AVAudioFormat(...)!` in [`BaichuanTalkback.swift`](Sources/ReolinkBaichuan/BaichuanTalkback.swift) is now a guarded init with a typed failure. The `baseAddress!.assumingMemoryBound(...)` patterns in [`H264Decoder.swift`](Sources/ReolinkStreaming/Player/H264Decoder.swift) and [`H265Decoder.swift`](Sources/ReolinkStreaming/Player/H265Decoder.swift) check for nil + empty inputs and throw a format-description error instead of trapping. Eliminates two known crash paths under malformed streams.
- **B4: `try?` swallows replaced with explicit logged catches** in [`CGIClient.swift` (`logout`)](Sources/ReolinkAPI/CGIClient.swift), [`RTSPClient.swift` (`teardown`)](Sources/ReolinkStreaming/RTSP/RTSPClient.swift), [`BaichuanTalkback.swift` (`TalkReset` during `stop`)](Sources/ReolinkBaichuan/BaichuanTalkback.swift), and [`BaichuanAlarmVideo.swift` (`findAlarmVideo close`)](Sources/ReolinkBaichuan/BaichuanAlarmVideo.swift). Failures now log at the appropriate level so regressions become observable.
- **AGENTS.md amendments** (§1 carve-outs list updated, §5 documents the App-Group shared container, §7 lists `_v1` introductions, §12 promotes coverage to CI-enforced, §13 promotes version alignment to CI-enforced, new §16 codifies Widgets / Live Activities rules).
- **Liquid Glass adoption across the app.** New [`Sources/AppShared/ReolensGlass.swift`](Sources/AppShared/ReolensGlass.swift) centralizes design tokens (`reolensGlassBadge`, `reolensGlassCard`, `reolensGlassToolbar`, `reolensGlassToast`, `reolensGlassChip`, `reolensGlassPanel`, `reolensGlassContainer`) with iOS 26 / macOS 26 `glassEffect(...)` modifiers and `.ultraThinMaterial` / `.regularMaterial` fallbacks. Applied broadly: live-tile name + motion/AI indicator pills (macOS + iOS), failure-overlay retry buttons, snapshot HUD toast, iOS PTZ control card, fullscreen overlay name pill + Done button, AI event filter chips (with `GlassEffectContainer` morph), AI capability chips in Channel Settings, recordings header toolbar (controls + calendar + day timeline + filter bar all use one glass-toolbar surface), recordings footer notices, recordings player Raw-JSON card, trust-changed sheet fingerprint comparison block, privacy zone editor canvas, channel-detail tab picker, AddCameraSheet segmented mode picker, scrub-position bubble on the day timeline, menu-bar popover background, Bookmarks sheet header, macOS detail-view channel-name pill, digest detail sheet cards.
- **Theme E — connection-robustness overhaul.** New `ConnectionStage` enum + `ConnectRetryPolicy` in [Sources/AppShared/ConnectionProgress.swift](Sources/AppShared/ConnectionProgress.swift). `CameraSession.connect()` now exposes `connectionStage` + `connectionAttempt` to the UI, parallelizes `GetDevInfo` and `GetChannelstatus` after login, applies jittered exponential backoff (±20%) with a 30 s overall deadline, and surfaces auth failures immediately. The sidebar's `DeviceRowLabel` shows the stage label in place of the host string while a session is mid-connect. Discovery (`CameraDiscovery`) throttles the /24 sweep to 32 concurrent probes, drops the per-probe timeout from 1.5 s → 1 s, and runs a Local Network permission check up front via the new `LocalNetworkPermission` helper. iOS `AddCameraView` shows a dedicated "Local Network access denied" state with a Settings → Privacy hint when the user has explicitly denied.

### Fixed

- **iOS local-network scan never found cameras.** Two compounding bugs. (1) `LocalNetworkPermission.ProbeBox` captured `self` weakly in every NWBrowser callback and the dispatch-after timer, but the only strong reference to the box was a local `let` inside `withCheckedContinuation` that went out of scope as soon as `start(...)` returned. The box was deallocated before any callback could fire `resolve()`, so the continuation leaked (`SWIFT TASK CONTINUATION MISUSE: probe(timeoutSeconds:) leaked its continuation without resuming it`) and `scanWithPermissionGate` never returned. Mirrored the strong-capture pattern documented on `BonjourCollector` (same file, lines 256–259) so the closures themselves keep the box alive until `resolve()` cancels the browser. (2) The scan raced Bonjour and the 32-concurrent HTTP /24 sweep, and the URLSession TCP probes fired into local-IP space *before* the iOS Local Network prompt was answered — every probe failed in 1.5 s and the scan returned empty even after the user tapped "Allow". `scan()` now runs Bonjour to completion first (≈3 s — long enough for the prompt to resolve), then fires the HTTP sweep. `scanWithPermissionGate` also bumps the permission probe timeout from 0.5 s → 8 s so the gate actually waits for the user.
- **Recordings list silently failing to load.** `sendCapturingRaw` (the path used by `RecordingsView.reload()` for `Search`, `GetEvents`, and `GetChannelstatus`) didn't perform the loginRequired (`rspCode == -10`) retry that `sendBatchRetrying` does. When the cached CGI token expired between launches the camera returned an error envelope, the typed decode succeeded with a `nil` `value` field, and the UI surfaced an unhelpful "Empty response from camera." `sendCapturingRaw` now drops the cached token and retries on `-10`, and additionally retries once on transient URL transport errors (timed out, connection lost, host unreachable, secure-connection failed). `RecordingsView` also waits up to 1.5 s for the session to reach `.connected` before firing Search, and surfaces specific error copy for `-10` ("Session expired…"), `-17` ("Camera is busy…"), URL transport errors, and decode failures — replacing the generic "Empty response" copy.
- **Recordings list felt slow because the spinner gated on four sequential CGI calls.** `reload()` previously awaited main Search → sub Search → GetEvents → Baichuan `findAlarmVideo` before clearing `isLoading`, even though the user-visible file list only needs the main Search. Now the spinner clears the moment main Search returns; the sub-stream lookup (for low-quality previews), the GetEvents probe, and the Baichuan AI-tag enrichment all run as detached `@MainActor` tasks that update their respective state when they finish. The Baichuan path retains its own small "AI tags loading…" indicator. On a busy day's recordings, perceived load time drops from ~4–6 s to under 1 s on a healthy LAN.
- **OSD + AI Detection didn't refresh when switching cameras in the sidebar.** `ChannelSettingsView.loadOsd()` had `guard osd == nil else { return }` which short-circuited every subsequent camera selection — the panel kept showing the first-loaded camera's values. The `.task` also wasn't keyed on identity, so SwiftUI reused the same view instance across camera switches. The load is now keyed on a composite `(deviceID, channel)` identifier, and `loadOsd()` resets the OSD state before re-fetching so users see a fresh "Loading…" rather than stale toggles.
- **Menu-bar popover showed "Motion · Home Hub · 6:45 PM" for every event.** Three bugs: (1) `aiEventLog.suffix(20)` returned the OLDEST events because the log is inserted at index 0; (2) `channel.name` being nil or empty fell through to the hub's `displayName` for every row, making multi-channel hubs unreadable; (3) repeated alarm-stream events for a single motion burst rendered as duplicate rows. Now: prefix-not-suffix, "Camera N" fallback when the per-channel name is empty, 3-second coalescing window, and AI tag rendering prefers the raw Reolink tag string when the category doesn't map to a known `DetectionType`.
- Empty / malformed H.264 SPS or PPS would crash the decoder by force-unwrapping `baseAddress` on a zero-length `Data`. Observed sporadically on Reolink HomeHub Pro firmware after a reboot that emitted a zero-length PPS NAL. Now surfaces as a typed `AssemblerError.formatDescriptionFailed`.
- Empty H.265 VPS / SPS / PPS gets the same treatment.
- `AVAudioFormat` initializer refusing the 16 kHz mono Int16 configuration would SIGABRT inside `BaichuanTalkbackSession.start()` rather than reporting a recoverable failure. Now throws and logs.
- Logout / RTSP TEARDOWN / talkback-reset / alarm-video-close network errors were silently dropped via `try?`. Failures now log at the appropriate level so regressions surface in unified logging.

### Tests

- New `Tests/AppSharedTests/SharedContainerTests.swift` — Codable round-trips for `LatestSnapshot`, `RecentMotionEvent`, `DailyDigestRecord`, plus `ReolensScene` enum.
- New `Tests/AppSharedTests/MotionEventRelayHardeningTests.swift` — `MotionEventRecordID` determinism + bucket boundaries, `MotionEventRateLimiter` allow / suppress / burst summary transitions, `CloudKitAccountIdentityGuard` enroll / allow / account-changed / reset flow.
- New `Tests/AppSharedTests/DigestBuilderTests.swift` — `DigestBuilder.build(...)` total-in-window, per-camera sorting, peak hour, empty-input edge cases.
- New `Tests/ReolinkStreamingTests/DecoderHardeningTests.swift` — empty SPS / PPS / VPS no-crash regression coverage.
- New `Tests/ReolinkBaichuanTests/WireTests.swift` — `BcHeader` round-trips for both modern (20-byte) and offset-carrying (24-byte) classes, foreign-magic rejection, short-buffer rejection, `BcMessage` bodyLength stamping.
- New `Tests/ReolinkBaichuanTests/XMLTests.swift` — `BcXmlBody.firstTagContent` (simple / missing / repeated), `allBlocks` against a 3-event AlarmEventList, `extractNonce` (present / missing), `loginUserAndNet` + `channelExtension` body emission.
- New `Tests/AppSharedTests/EventNotifierTests.swift` — per-tag mute persistence defaults + explicit-set round-trip, `RecentMotionEvent` Codable round-trip.
- Final test count: **158 tests across 43 suites** (was 96 in 32 suites at 0.4.1).

### Migration / breaking changes

- iOS 18 and macOS 14 are no longer supported on the 0.5 track. Users on those versions should stay on the 0.4.x track, which receives security-only backports through the 0.5 cycle. See SECURITY.md.
- Existing CloudKit `MotionEvent` records remain readable; new records published from 0.5.0 onward use content-addressed record IDs instead of UUIDs. Mixed-version deployments coexist without issue.

## [0.4.3] — 2026-05-12

Single-fix patch on top of 0.4.2 — fixes a build break on iOS introduced
by the 0.4.2 patch.

### Fixed

- **iOS archive build was failing** with `cannot find
  'SecTaskCreateFromSelf' / 'SecTaskCopyValueForEntitlement' in scope`.
  The 0.4.2 `CloudKitAvailability` probe leaned on `SecTask*` to read
  the running task's signed entitlements, but those symbols are
  private SPI and aren't surfaced in the Swift overlay on either
  platform — they only "worked" in 0.4.2's local `swift build`
  because nothing exercised that file path. The CI iOS archive
  predictably failed, which would have shipped no TestFlight build
  for 0.4.2.

  Replaced with platform-specific paths: macOS uses
  `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`
  (public Security framework APIs that read the codesign blob's
  embedded entitlements dict, returning the iCloud-container
  identifiers); iOS unconditionally returns `true` because every
  iOS distribution path — App Store, TestFlight, dev-device — embeds
  the entitlements declared in `AppiOS/project.yml`, so the
  `CKContainer.init` trap simply cannot fire on iOS. Same
  user-facing behavior as 0.4.2's intent (release DMG reads `true`
  whether or not iCloud Drive is enabled), now in a form that
  actually compiles for both platforms.

## [0.4.2] — 2026-05-12

Single-fix patch on top of 0.4.1.

### Fixed

- **macOS Settings → Privacy → "Push notifications to iPhone / iPad"
  was incorrectly showing "iCloud isn't available on this Reolens
  build"** on properly-signed release DMGs. Root cause: 0.4.1's
  `CloudKitAvailability.canUseCloudKit(containerID:)` probe used
  `FileManager.url(forUbiquityContainerIdentifier:)` as a proxy for
  "does this binary carry the iCloud entitlement." That URL is nil
  not only when the entitlement is missing — also when the user
  hasn't signed into iCloud, hasn't enabled iCloud Drive, hasn't
  enabled Reolens for iCloud Drive in System Settings, or simply
  hasn't triggered lazy container materialization yet on this
  install. A correctly-signed Reolens with the full iCloud
  entitlement chain therefore read as "unavailable" on first
  launches and the relay toggle stayed disabled.

  Replaced with a direct read of the running task's signed
  entitlements via `SecTaskCopyValueForEntitlement`. That returns
  the bytes embedded by the signing process and has no system-state
  side dependencies — the Developer-ID-signed release DMG reports
  `true` immediately, ad-hoc dev builds without the entitlement
  report `false` immediately, regardless of iCloud account state.

## [0.4.1] — 2026-05-12

A trust-and-polish release on top of 0.4.0. Headlines: **CloudKit
motion-event relay** for iOS background notifications (no Reolens
server — events ride through the user's own iCloud account),
**trust-on-first-use TLS pinning** for HTTPS cameras, a **logging
redaction sweep** to close gaps between AGENTS.md §11's promise
and reality, two **real bugs from 0.4.0 user feedback** (macOS
camera-switching, iPad/iPhone sidebar showing only the device), and
the **notification-tap → exact-clip routing** that the 0.4.0
release notes acknowledged was still landing broadly.

### Added

- **CloudKit motion-event relay (push notifications to iPhone /
  iPad).** New shared `MotionEventRelay` infrastructure in
  `AppShared` (`MotionEvent`, `CloudKitMotionEventPublisher`,
  `CloudKitMotionEventSubscriber`). The macOS app (running 24/7 in
  menu-bar mode shipped in 0.4.0) writes motion / AI events to the
  user's *private* CloudKit database; iOS subscribes via
  `CKQuerySubscription` and posts a local notification when CloudKit
  delivers a silent push. **No Reolens server — events ride
  through Apple's CloudKit under the user's own iCloud account**
  (AGENTS.md §5). Opt-in via Settings → Privacy → "Relay motion
  events to my other Apple devices" on the macOS app. iOS app
  installs the subscription idempotently on every launch (opt-out
  via `MotionEventRelaySettings.subscriberEnabledKey`). CloudKit
  silent-push delivery is throttled by Apple for free-tier
  accounts; busy households may not receive every event but the
  steady stream is preserved.
- **Trust-on-first-use TLS pinning** for HTTPS cameras. New
  `TLSPinningPolicy` in `ReolinkAPI` records the leaf cert's
  SHA-256 on the first successful HTTPS handshake; subsequent
  connections reject any mismatch. Mismatch surfaces as a global
  modal (`TrustChangedSheet`) with the expected vs. observed
  fingerprints and "Cancel" / "Trust new certificate" actions —
  hard block per AGENTS.md §3. HTTP-only cameras skip pinning.
  Schema bump: optional `CameraEntry.tlsFingerprint: String?`,
  forward-compatible (older apps decode-and-ignore).
- **Per-channel sidebar rows on iPad / iPhone**, matching the macOS
  `DeviceSidebarRow` behavior since 0.3. Multi-channel hubs / NVRs
  expand into a `DisclosureGroup` of channels; tapping a channel
  opens its single-channel detail directly. `SidebarSection.channel`
  case added to `iPadSplitShell.SidebarSection`.
- **Notification-tap → exact-clip routing.** Tapping a
  recording-aged motion notification (>60 s old) now drills into
  the camera's Recordings tab and auto-plays the clip whose time
  range contains the event (or the closest clip by start time).
  New `PendingRecordingScroll` struct on `CameraStore` holds the
  hand-off between the shell's intent-routing handler and the
  inner `RecordingsView.scrollTarget` parameter; both consumed
  read-once.
- **Hide-app-badges toggle in Channel Settings.** New per-channel
  preference (`CameraEntry.hiddenAppBadgeChannels: Set<Int>`,
  forward-compatible schema) and a "Show app badges over video"
  toggle in Channel Settings → Overlay. Hides the in-tile camera
  name + motion / AI icons for users who want the cleanest possible
  image, or whose camera OSD overlaps the upper-left.
- **Local-network camera discovery on iOS.** `AddCameraView` gains a
  "Scan local network for cameras" entry that opens a discovery
  sheet powered by the existing `CameraDiscovery` actor (Bonjour +
  HTTP /24 sweep). Picking a discovered device prefills the host
  and display name. The "v0.2 ships manual entry only" copy is
  gone. iOS Local Network permission prompt now fires in the right
  context.
- **Time-cursor scrub overlay on the recording timeline.** Drag
  across the day's segment strip to surface a live time-cursor
  with the current scrub position; release inside a segment plays
  that clip, release near a segment (≤90 s) plays the closest.
  Phase one of the recordings timeline shipped in 0.4.0; the full
  thumbnail-preview-on-scrub + cross-segment seek is on the 0.5
  roadmap (requires replacing AVPlayerView with a custom AVPlayer-
  backed scrubber).
- **`Tests/AppSharedTests/`** target. 22 new Swift Testing tests
  covering `LogRedaction` round-trip, `TLSPinningPolicy`
  fingerprint computation, `AppIntentFocus` notification routing,
  `CameraEntry` Codable schema (forward + backward compatible),
  `PendingRecordingScroll` equality, and `CameraPreviewService`
  atomic-write + purge contracts. Total test count 74 → 96.

### Fixed

- **macOS: switching cameras in the sidebar leaves the live view
  stuck on the previous camera until you tab to Recordings or
  Settings and back.** Root cause: `ChannelDetailContent.liveTab`
  didn't `.id(channel.channel)` its inner `LiveCameraTile`, so
  SwiftUI treated the tile as the same view across channel changes;
  the persisting `@State` `player` kept showing the previous
  camera's RTSP stream, and the `.task(id: channel.channel)`
  guard short-circuited the restart because `didStart` was still
  true from the previous channel. Added the missing `.id(...)`
  and a defensive copy on the iOS `SingleChannelView`.
- **iPad / iPhone sidebar shows only the device row** ("Home Hub"),
  not the individual cameras the device exposes. Now expands into
  a per-channel list — same idiom macOS has had since 0.3. iPhone
  Live tab uses the same `DisclosureGroup` idiom too.
- **Dev build crash when CloudKit relay is enabled.**
  `CKContainer.init(identifier:)` calls Apple's
  `EXC_BREAKPOINT` trap when the running binary lacks the iCloud-
  container entitlement — observed on ad-hoc-signed
  `./Scripts/build-app.sh` outputs whose `Reolens.dev.entitlements`
  deliberately drop iCloud to keep AMFI happy. Wrapped both the
  publisher and subscriber paths in a `CloudKitAvailability` probe
  (`FileManager.default.url(forUbiquityContainerIdentifier:)` —
  doesn't trap, just returns nil) so dev builds silently no-op
  instead of crashing. The Settings toggle is also disabled with
  an explanatory note when iCloud isn't reachable, so users on
  dev builds see the "install the DMG" hint rather than a mystery
  crash.
- **"No password on this Mac" persisted after entering a password.**
  Root cause: `Keychain.set` silently swallowed `SecItemAdd`
  failures (most commonly `errSecDuplicateItem` from a stale
  iCloud-synced item that `delete`'s `kSecAttrSynchronizableAny`
  didn't reach). Now falls back to `SecItemUpdate` on duplicate,
  reads the password back after every write to verify, and bubbles
  failures up via a new `CameraStore.passwordSaveError` published
  property → user-visible alert on both platforms. Silent password-
  save regressions become observable.

### Changed

- **Logging redaction sweep across protocol + app layers.** Every
  URL going through unified logging now flows through a new
  `LogRedaction.redact(_:)` helper that strips embedded
  `user:password@host` userInfo segments and elides sensitive
  query parameters (`token`, `user`, `password`) with the
  ASCII placeholder `REDACTED`. Defense-in-depth regex scrub
  applies on the result so even malformed-but-URL-encodable
  inputs can't leak credentials. Specifically:
  - `LiveVideoPlayer.swift:174` no longer logs the bare
    `rtsp://user:password@host/...` URL.
  - `RecordingDownloader` failure messages no longer carry the
    download URL — that's logged internally with redaction; the
    user-visible error gets the status code only.
  - `CameraSession.swift:128` raw `GetChannelstatus` payload now
    gated behind `CameraStore.developerModeIsOn` and emitted at
    `.debug` with `.private` privacy.
  - `RecordingsView.swift:581` `GetEvents` raw response —
    same treatment.
  - `CameraDiscovery.swift:62` subnet prefix marked `.private`.
  - Baichuan TX/RX hex dumps, UID replies, alarm-video reply
    bodies, nonces, RTSP DESCRIBE / SETUP / PLAY URIs — all
    marked `.private`, raw bodies demoted to `.debug`.
  - AGENTS.md §11 amended to codify the new rules (URL helper,
    user-visible error strings without URLs, dev-mode-gated raw
    payloads, `.private` on hostnames / subnets).
- `Sources/AppShared/CameraStore.swift` — `CameraEntry` schema
  gains `tlsFingerprint` and `hiddenAppBadgeChannels` fields,
  both forward-compatible.
- `Sources/ReolinkAPI/CGIClient.swift` —
  `PermissiveTLSDelegate` replaced with `PinningTLSDelegate`
  consuming a `TLSPinningPolicy`. `CGIClient.init` takes a
  policy parameter (default `.alwaysAccept` for tests / legacy
  call sites).
- `EventNotifier.notify(...)` on macOS now publishes the event to
  CloudKit *before* the local-notification gates, so an opted-in
  Mac with locally-muted notifications still relays to iPhone /
  iPad. Per-tag + master AI / motion mutes apply to both local
  and relayed notifications.
- iOS `aps-environment` entitlement set to `production`, plus
  `remote-notification` added to `UIBackgroundModes`, so CloudKit
  silent pushes wake the app. macOS entitlements gain `CloudKit`
  under `com.apple.developer.icloud-services`.
- `AppiOS/README.md` refreshed for the 0.4.x state — parity
  bullets, iOS-only carve-outs, and the 0.5 roadmap.

### Security

- **TLS pinning is a hard block on mismatch** (not a warning).
  AGENTS.md §3 — TLS changes require explicit user re-consent. The
  trust-changed sheet surfaces both fingerprints for out-of-band
  verification before the user accepts the new cert.
- Logging redaction sweep eliminated five enumerated leak sites
  from the 0.4.0 audit plus several others spotted while sweeping.
  Run `os_log show --predicate 'subsystem == "com.reolens.app" or
  subsystem == "com.reolens.Reolens"'` on a session that includes
  a download failure to verify no `user:` / `password=` / `token=`
  values appear.

### Deferred to 0.5

- Full custom recording scrubber with thumbnail-preview while
  dragging and cross-segment seek. Requires replacing the system
  `AVPlayerView` with a custom `AVPlayer`-backed scrubber UI
  that fetches keyframes via `AVAssetImageGenerator` against
  cached MP4s.
- Home Screen / Lock Screen / Control Center widgets and iOS Live
  Activities (deferred from 0.4.0).
- Stage Manager / multi-window iPad (deferred from 0.4.0).
- "Overnight digest" notification + widget (deferred from 0.4.0).

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

[Unreleased]: https://github.com/jestatsio/reolens/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/jestatsio/reolens/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/jestatsio/reolens/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/jestatsio/reolens/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/jestatsio/reolens/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/jestatsio/reolens/releases/tag/v0.4.3
[0.4.2]: https://github.com/jestatsio/reolens/releases/tag/v0.4.2
[0.4.1]: https://github.com/jestatsio/reolens/releases/tag/v0.4.1
[0.4.0]: https://github.com/jestatsio/reolens/releases/tag/v0.4.0
[0.3.0]: https://github.com/jestatsio/reolens/releases/tag/v0.3.0
[0.2.3]: https://github.com/jestatsio/reolens/releases/tag/v0.2.3
[0.2.2]: https://github.com/jestatsio/reolens/releases/tag/v0.2.2
[0.2.1]: https://github.com/jestatsio/reolens/releases/tag/v0.2.1
[0.2.0]: https://github.com/jestatsio/reolens/releases/tag/v0.2.0
[0.1.1]: https://github.com/jestatsio/reolens/releases/tag/v0.1.1
[0.1.0]: https://github.com/jestatsio/reolens/releases/tag/v0.1.0
