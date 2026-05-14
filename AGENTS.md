# AGENTS.md — Reolens engineering principles

This file is the source of truth for how to work on Reolens. It applies to humans and to agentic coding tools (Claude Code, Codex, Cursor, etc.) — both should read it before making changes.

Reolens is a Reolink camera client for macOS, iPadOS, and iOS. It streams live video over RTSP from cameras the user owns, exposes recordings and PTZ, and syncs the camera list across the user's own Apple devices via iCloud Drive.

The product is small, opinionated, and trust-sensitive. People install it because they want a clean, native, ad-free way to look at their own cameras. Every change should reinforce that.

---

## 1. Platform parity is the default

Any user-visible feature shipped on one Apple platform must work on the others. macOS, iPadOS, and iPhone are not tiers — they are equal targets. If a feature is genuinely platform-only (e.g. Sparkle auto-update, which is macOS-only because iOS uses TestFlight/App Store), it must be a documented carve-out with rationale in the relevant view/file's header comment.

When you add a feature, ship it everywhere or open a tracking issue for the missing platform in the same PR.

**Documented carve-outs (current as of 0.6.0):**

- Sparkle auto-update — macOS only (iOS uses TestFlight / App Store).
- Picture-in-Picture — iOS / iPadOS only (no macOS analog).
- Menu-bar mode + Launch at Login — macOS only.
- Local-network Bonjour discovery sheet — historical iOS-only, gained macOS parity in 0.5.0.
- **iOS Live Activities + Dynamic Island** — iOS / iPadOS only (ActivityKit has no macOS equivalent; macOS users see the menu-bar mode + desktop widget instead). Added in 0.5.0; 0.5.1 widened to hub-grouped semantics + APNs push-token registration (`pushType: .token`).
- **Widgets** — ship on both platforms (Home Screen / Lock Screen / Control Center on iOS, desktop widgets on macOS). No carve-out needed for widgets themselves.
- **FoundationModels on-device inference** — ships on both platforms (iOS 26 / macOS 26 SDK floor) but availability is device-dependent (Apple Intelligence-eligible hardware only). `EventSummarizer` and 0.6.0's new `RecordingNLSearcher.planWithModel(...)` both fall back to deterministic implementations when `SystemLanguageModel.default.availability` is not `.available`. The fallback is documented behaviour, not a carve-out — both code paths ship on both platforms.
- **HomeKit bridge (added in 0.6.0)** — iOS / iPadOS only. Apple removed the public HomeKit framework from the macOS SDK; native macOS apps (not Mac Catalyst) can't `import HomeKit`. `HomeKitSection` returns `EmptyView()` on macOS so the macOS Privacy tab doesn't surface a misleading "framework not available" message. The per-camera `homeKitEnabled` flag still rides `cameras.json` through iCloud, so a user flipping it on iPhone propagates to the device that has the entitlement. The full HKSV recording-tier is **gated on Apple's MFi certification process** — the bridge ships scaffolding and a stubbed `registerAccessoryIfNeeded(for:)` rather than a working `HMCameraProfile` until that's resolved.

## 2. Native libraries on each platform

Don't bridge `NSView` into iOS or `UIView` into macOS. Don't import AppKit on iOS or UIKit on macOS. The established pattern is:

- One SwiftUI surface in shared code.
- Two thin platform adapters (`NSViewRepresentable` for macOS, `UIViewRepresentable` for iOS) when SwiftUI alone isn't enough.
- A shared model below the adapters.

See `Sources/ReolinkStreaming/Player/LiveVideoView.swift` for the canonical example. The whole UI layer currently has only ~5 `#if os(...)` blocks. Keep that count low. If you find yourself reaching for a conditional compile, first try: protocol-driven split, environment-driven branching, or moving the platform-specific code behind a thin representable.

**Cross-platform image bridging (0.5.0):** the `ScrubberView` thumbnail rail uses a `PlatformImage` typealias (`NSImage` on macOS, `UIImage` on iOS) with a small `jpegData(quality:)` extension in `Sources/AppShared/ScrubberView.swift`. Reach for the same typealias pattern before adding a fresh `#if`.

**Liquid Glass tokens (0.5.0):** every glass-surface adoption goes through `Sources/AppShared/ReolensGlass.swift` — `reolensGlassBadge`, `reolensGlassCard`, `reolensGlassToolbar`, `reolensGlassToast`, `reolensGlassChip`, `reolensGlassPanel`. New surfaces use one of those rather than calling `.glassEffect(...)` directly, so a future design tweak is a one-file change. **0.5.1 update:** `reolensGlassChip` now applies the interactive variant (`.glassEffect(.regular.interactive())`) on iOS 26 / macOS 26 so pills morph on press — if you need a non-interactive chip variant later, fork a sibling token rather than adding a parameter to this one.

**Multi-window scenes (0.5.0):** the `ReolensScene` enum + `WindowGroup(for: ReolensScene.self)` declared on both `ReolensApp` and `ReolensiOSApp` is the only path for opening a camera in its own window. Reuse `CameraSceneHost` (macOS) / `CameraSceneHostiOS` (iOS) for additional scene types rather than spinning up an ad-hoc `WindowGroup`.

## 3. Cameras are sensitive

Treat every change as touching live video feeds, authentication, and the user's home network.

- Any PR that modifies authentication, RTSP, credential storage, or networking must explicitly call out the security implications in its description.
- Run the `security-reviewer` agent before any release tag.
- Never log credentials, hostnames, or auth tokens at any level (`info`, `debug`, `verbose`).
- Never include credentials in crash reports, error messages shown to the user, or diagnostic exports.

## 4. Credentials are device-local by default

Passwords live in `Keychain` with `kSecAttrAccessibleWhenUnlocked`. By default they **do not** sync across devices. This is by design.

The camera list (`cameras.json`) **does** sync via iCloud Drive (see `Sources/AppShared/ICloudCameraStorage.swift`). Camera metadata — host, port, username, display name, grid layout, channel order — is synced. Passwords are not, unless the user has explicitly opted in (see below).

Don't blur this line:

- Never write a password to `UserDefaults`, `cameras.json`, or any other persisted store.
- Never write a password to a log.
- Cross-device password sync is an **explicit user-facing opt-in to iCloud Keychain**, never a silent change. Surface the trade-off in the UI.

### iCloud Keychain Sync opt-in (added in 0.4.0)

Settings → Privacy → "Sync camera passwords to iCloud Keychain" is the only path that flips passwords onto the synchronizable side of Keychain. Off by default. Controlled by `Sources/AppShared/Keychain.swift` (`syncEnabled` reads `UserDefaults` for `com.reolens.iCloudKeychainSync`) and `CameraStore.iCloudKeychainSyncEnabled`.

Behavior:

- **Off (default):** writes set `kSecAttrSynchronizable: false`. Reads use `kSecAttrSynchronizableAny`, so a device that opted in earlier and then opted out still sees its previously-synced passwords on this device.
- **On:** writes set `kSecAttrSynchronizable: true`. The user's existing local-only passwords are migrated to the synced side via `Keychain.migrate(accounts:toSync:)` so the toggle isn't ambient — it takes effect immediately.

Don't add a third state ("partial" / "per-camera"). The opt-in is one flag for the whole device.

### Per-camera notification mute (added in 0.5.1)

Per-camera notification on/off is a separate, much narrower opt-out from the iCloud Keychain Sync flag. The semantic is:

- Default: every camera notifies.
- The user can flip individual cameras off (e.g. an indoor camera during the day).
- State syncs across the user's devices via `NSUbiquitousKeyValueStore` (the "mute set") so the choice is consistent — muting on Mac mutes on iPad.

This is allowed to be per-camera because the data is non-credential and the user-experience requirement (silence one room without silencing everything) doesn't have a one-flag analog. `CameraNotificationPreferences` is the single source of truth; the `EventNotifier.notify(...)` dispatch path consults it off the main actor through `isNotificationsEnabledOffMainActor(for:)` so busy hubs don't hop the MainActor on every alarm event.

## 5. Privacy

- No third-party analytics. None.
- No remote crash reporting that captures screen contents, network payloads, or PII.
- The app must function fully without any network call to non-Reolink hosts. The only exceptions are the Sparkle appcast (macOS auto-update) and Apple's own services (iCloud, TestFlight, App Store).
- No telemetry pings. No A/B testing infrastructure. No silent background fetches to our servers — there are no "our servers."

If you find yourself wanting to add a network call, ask whether it can be avoided. If it cannot, document why in the PR.

**Shared App-Group container (0.5.0).** The WidgetKit extension and the Live Activity extension read snapshots + recent motion-event metadata from a *device-local* App Group container at `group.com.reolens.Reolens`. The container holds:

- `LatestSnapshots.plist` — per-camera last snapshot + last-motion timestamp.
- `RecentMotionEvents.plist` — capped to 50 entries, rotated by `EventNotifier`.
- `digests/<yyyy-MM-dd>.json` — daily-digest records (≤ 30 days).
- `snapshots/<cameraID>_ch<channel>.jpg` — small jpegs for widget reads.
- `activity-assets/<eventID>.jpg` — Live Activity trigger frames, purged at 4 h.

This container is **never CloudKit-synced** and the widget / activity extensions have **no network entitlement** (App Groups grant filesystem-only access). Widgets MUST NOT read Keychain entries. AGENTS.md §16 codifies the lifecycle.

## 6. Shared logic lives in `AppShared`

The `AppShared` library target holds all state management, persistence, networking, domain models, and cross-platform business logic. UI may diverge per platform. Logic must not.

If you find yourself about to write the same function twice (once in `App/`, once in `AppiOS/`), stop and put it in `AppShared` instead. The Sources/ libraries are the right shape — `ReolinkAPI`, `ReolinkStreaming`, `ReolinkBaichuan`, `AppShared` — extend them rather than duplicating.

**0.6.0 actor / store split.** The 0.5.x release accumulated a 775-LOC `CameraStore` god object and a 1,430-LOC macOS `RecordingsView` whose 12+ `@State` variables were duplicated in the 789-LOC iOS twin. 0.6.0 split that into focused, single-responsibility components — when adding a new feature, look at the existing pieces before extending `CameraStore` or the per-platform views:

- **`RecordingsLoader`** (`Sources/AppShared/RecordingsLoader.swift`) — `@MainActor @Observable` class that owns the per-camera Recordings tab's network state (files, sub-files, alarm-video entries, month statuses, event log). Has a generation-counter cancellation guard so rapid date flips never publish stale results, and three-tier memoized `effectiveDetections(for:)`. Both platform RecordingsView shells delegate to this rather than holding the state directly.
- **`RecordingIndex`** (`Sources/AppShared/RecordingIndex.swift`) — cross-day actor for the NL-search window. Same shape as `NotificationHistory` (actor + lazy file-backed JSON + atomic write). Idempotent per-(camera, day) ingest; fed from `RecordingsLoader.reload()` as a side-effect so no new network traffic is required.
- **`PollManager`** (`Sources/AppShared/PollManager.swift`) — depth-counted polling lifecycle that used to live inline in `CameraSession`. Use `pausingBackgroundPolling(_:)` (throwing or non-throwing) when a user-initiated CGI op must not race the motion-state poll.
- **`AppPreferences`** (`Sources/AppShared/AppPreferences.swift`) — UserDefaults-backed prefs (`developerMode`, `showCameraNameOnFeed`, `lastViewedCameraID`) with injectable `UserDefaults` for test isolation. `CameraStore` embeds one and proxies the legacy property names so existing consumers don't change.
- **`CameraKeychainStore`** (`Sources/AppShared/CameraKeychainStore.swift`) — Keychain reads/writes/deletes + iCloud sync toggle + sync-mode migration. Owns the observable `passwordSaveError`. Public `MigrationResult` type mirrors the package-private `Keychain.MigrationResult`.
- **`CameraListPersistence`** (`Sources/AppShared/CameraListPersistence.swift`) — iCloud-backed JSON encode/decode boundary with an injectable `Backend` protocol for tests. `CameraStore`'s `load()` / `save()` / `reloadFromStorageIfChanged()` forward through it.
- **`RecordingsScreenHeader`** (`Sources/AppShared/RecordingsScreenHeader.swift`) — shared 3-row glass toolbar stack (density / timeline / filter) consumed by both platform RecordingsView shells. The date picker stays in each platform shell because their toolbars differ; everything below the picker is shared.
- **`BookmarkAutoDownloader.reconcile(across:)` / `enqueueIfMissing(...)` / `removeBookmark(_:)`** — the full bookmark lifecycle is centralized here. New deletion sites *must* route through `removeBookmark` so the URLSession-cancel + clip-file delete + JSON-store remove always happen together.

If you're tempted to add a 13th `@State` variable to a RecordingsView shell, or a 14th setter to `CameraStore`, that's a signal the right move is to extend the relevant carve-out instead.

## 7. Backward-compatible sync schema

`cameras.json` is read by every Reolens install signed in to the same iCloud account, including older versions that haven't updated yet. Schema changes must be:

- **Forward-compatible reading**: older apps must tolerate unknown fields (Swift's `Codable` does this by default — don't break it with custom decoders).
- **Backward-compatible writing**: new versions must continue to populate any field older versions require, or the user's other devices will misbehave.
- **Migrated, not mutated**: when an existing field's semantics change, version the field name (e.g. `order_v2`) rather than overloading the old one.

When you bump the schema, write the migration in the PR description.

**0.5.0 introductions and their `_v1` markers:**

- `bookmarks_v1.json` — recording bookmarks (per-camera) added in 0.5.0. Stored in the per-camera iCloud Drive directory; references only, no media.
- `DailyDigestRecord` schema-version `1` — overnight-digest JSON files (`digests/<yyyy-MM-dd>.json` under the App Group, capped at 30 days).
- `MaskSettings` / `MaskArea` — privacy-zone wire model for `GetMask` / `SetMask`. Lives under `Sources/ReolinkAPI/Models/Mask.swift`; tied to Reolink firmware, not a versioned format on our side, but `Sources/AppShared/PrivacyZoneEditorModel.swift` stores the editor's working set in `UserDefaults` keyed by `com.reolens.privacyZones.<deviceID>.<channel>` — bump that key prefix on any breaking shape change.
- `LatestSnapshots.plist` and `RecentMotionEvents.plist` (in the App Group) carry implicit schema versioning via the Codable types in `Sources/AppShared/SharedContainer.swift`. Add new optional fields freely; never rename or remove an existing field without bumping the file name.

**0.5.1 introductions:**

- `live-activity-tokens_v1.json` — APNs push tokens per in-flight Live Activity. Stored in the iCloud Drive ubiquity container (`Documents/live-activity-tokens/`). Schema is a `[String: Token]` dict keyed by `Activity.id`; bump the suffix on any breaking shape change. The future server-driven Live Activity sender (or a peer Apple device acting as relay) consumes this; the local Baichuan-event-driven path keeps running regardless.
- `com.reolens.collapsedHubs` (`NSUbiquitousKeyValueStore` key) — `[String]` of UUIDs for currently-collapsed sidebar hub groups. Empty set is the default "every hub expanded" state. UserDefaults mirror for offline / no-iCloud devices.
- `com.reolens.mutedCameraNotifications` (`NSUbiquitousKeyValueStore` key) — `[String]` of UUIDs for cameras the user has silenced. Default empty = every camera notifies.
- `com.reolens.bookmarkDL.allowCellular` (`UserDefaults` key) — bool, default false. **Device-local only** (no iCloud sync) — cellular plans differ device-to-device, so per-device is the safer default.
- `com.reolens.showCameraNameOnFeed` (`UserDefaults` key) — bool, default false (badges hidden). Per-channel `CameraEntry.hiddenAppBadgeChannels` (in synced `cameras.json`) overrides per-channel; the global is device-local because the feature reads as a display preference.

**0.6.0 introductions:**

- `notifications.v1.json` — rolling 1,000-record notification log inside the App Group. Device-local only (`AGENTS.md §5`). Versioned by file name; bump the suffix on any breaking field change. `NotificationHistory` actor handles read/write with atomic side-path-then-rename.
- `recording-index.v1.json` — cross-day metadata index for the 30-day NL-search window. Lives in the App Group container, device-local. The `RecordingIndex` actor follows the same versioned-codable + atomic-write pattern as `NotificationHistory`.
- `RecordingBookmark.sourceFileName: String?` — new optional field on the existing `bookmarks_v1.json` schema. Forward-compat: legacy bookmark files without the field decode to `nil`. The launch-time `BookmarkAutoDownloader.reconcile(across:)` uses this to re-enqueue background downloads without needing a Search to find the source file; legacy bookmarks resolve themselves on next interaction.
- `CameraEntry.homeKitEnabled: Bool` — additive field in synced `cameras.json`. Forward-compat decode-and-default-false. Encode only when true so the JSON payload stays clean.
- `com.reolens.developerMode`, `com.reolens.showCameraNameOnFeed`, `com.reolens.lastViewedCameraID` (`UserDefaults` keys) — now read/written via the new `AppPreferences` carve-out from `CameraStore`. The key names stay the same so existing prefs migrate transparently. `lastViewedCameraID` is iOS/iPadOS-only (macOS has its own sidebar state restoration).
- Reolink wire types `RecordingScheduleSettings` and `MotionScheduleSettings` decode **both** observed firmware shapes (`schedule.table` canonical + `scheduleTable.mainStream` legacy) and always emit the canonical shape on write. Adding a future variant means extending `CodingKeys` + the custom `init(from:)` fall-back chain — never break the existing two paths.

Bump the suffix on any breaking field change in a future minor release; never overload an existing `_v1` field's semantics.

## 8. Swift 6 concurrency

- Use actors for shared mutable state.
- Mark cross-isolation types `Sendable`.
- Use structured concurrency (`async let`, `TaskGroup`) over unstructured `Task {}` when possible.
- Don't write `DispatchQueue.main.async` in new code. Use `@MainActor` annotations or `MainActor.run { }`.

## 9. Accessibility

- Every interactive element has a VoiceOver label.
- All text supports Dynamic Type. No hardcoded `.font(.system(size: 14))`-style absolutes for body text.
- No information conveyed by color alone — pair color with icon, label, or text weight.
- Gestures must have a non-gesture alternative. If long-press enters reorder mode, there's also a toolbar button. If drag reorders, there's also a Move Up / Move Down menu item.
- Respect `@Environment(\.accessibilityReduceMotion)` — replace bouncy/jiggle animations with static cues when it's true.

## 10. Performance

- Default to the sub-stream in grids; only main-stream when a tile is focused or expanded to single view.
- Never decode more streams than visible tiles. Pause off-screen streams.
- Be conservative on thermal/battery — RTSP decode is expensive. On iOS, surface `ProcessInfo.processInfo.thermalState` if we ever throttle.
- Profile before optimizing. Measure with Instruments, not vibes.

## 11. Logging

- `os.Logger` only. No `print()` in shipped code. (Tests may use `print` for debugging during development, but don't commit them.)
- Choose log levels deliberately: `.debug` for developer-only signal, `.info` for user-relevant events, `.error` for failures the user might see, `.fault` for invariant violations.
- Subsystems should be the bundle ID; categories should describe the subsystem (e.g. `category: "RTSP"`, `category: "iCloudSync"`).
- Credentials, tokens, full URLs with auth, or hostnames the user explicitly enters: never logged.
- **Use `LogRedaction.redact(_:)`** for any URL going through unified logging. Don't `\(url.absoluteString, privacy: .public)` — RTSP URLs embed `user:password@host`, and CGI URLs embed `token=` / `user=` / `password=` query params. The helper drops userInfo and sensitive query items while preserving the LAN host + path for diagnosis.
- **User-visible error strings must never carry URLs.** Internal log line gets the redacted URL with `privacy: .public`; user-facing message gets a status code or short error name only.
- **Raw protocol payloads** (`GetChannelstatus` / `GetEvents` JSON, Baichuan `findAlarmVideo` reply bodies, RTSP DESCRIBE / SDP bodies, hex dumps of TX/RX frames) carry hardware UIDs and other fingerprinting data — gate behind `CameraStore.developerModeIsOn`, emit at `.debug`, and mark the payload itself `privacy: .private`. Operational metadata (status code, length, count) can stay `.public` for support purposes.
- **Hostnames and subnet prefixes** are LAN-fingerprint material — `privacy: .private` for IP / hostname interpolations even though the log line stays at `.info`. Apple's unified-logging redaction handles the elision in sysdiagnose / Console.app exports.

## 12. Testing

- Use Swift Testing (`import Testing`, `@Test`, `#expect`). New tests should not be XCTest.
- 80% coverage **long-term target** on `AppShared`, `ReolinkAPI`, `ReolinkStreaming`, and `ReolinkBaichuan`. The 0.5.0 release introduced `Scripts/coverage-gate.sh` and wired it into CI. **0.6.0 flipped the gate to enforced** with a different strategy: per-target *baselines* in `Scripts/coverage-baselines.txt` rather than a single global 80% floor. CI now blocks on coverage *regression* against the baseline (with a 1 pp slack); intentional regressions require running `COVERAGE_FORCE_UPDATE_BASELINE=1 ./Scripts/coverage-gate.sh` locally and committing the updated baselines file. The 80% goal is still tracked in the script header — baselines ratchet upward as new tests land. **0.6.0 baseline is ~340 tests across 68 suites** (AppShared 13.81%, ReolinkAPI 56.47%, ReolinkStreaming 23.70%, ReolinkBaichuan 32.70%). The bar moves on every new feature.
- **XCUITest harness (added in 0.6.0)** — `AppiOS/UITests/ReolensiOSUITests.swift` covers the high-risk navigation journeys (cold-launch → primary navigation, Settings → Notifications, Notification log push). Wired into CI as a best-effort step that auto-selects the first available iPhone simulator. New journeys should land here when they cover regressions a unit test couldn't catch.
- No real network in tests. Use fixture servers (`URLProtocol` stubs, in-process HTTP servers) or protocol-injected fakes.
- Each test gets a fresh instance — `init`/`deinit`, no shared mutable state.
- Tests must be deterministic. If a test depends on timing, it's wrong.

## 13. Versioning

- SemVer. `MAJOR.MINOR.PATCH`.
- macOS (`App/Info.plist`) and iOS (`AppiOS/project.yml`) `MARKETING_VERSION` must stay aligned. A 0.3.0 release means both platforms ship 0.3.0 — never 0.3.0 on macOS and 0.2.9 on iOS. **CI-enforced** as of 0.5.0 via `Scripts/check-versions.sh`, which runs in both `ci.yml` (on every PR) and `release.yml` (as the first step before signing).
- Every release lands as a `## [X.Y.Z]` section in `CHANGELOG.md` following Keep-a-Changelog, with `Added` / `Changed` / `Fixed` / `Removed` subsections.

## 14. Commit & PR conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
- Subject line under 70 characters. Body explains the *why*.
- PRs reference the originating issue when there is one.
- PRs touching auth, network, credentials, or sync MUST include a "Security" section explicitly stating what was reviewed.

## 15. Agent usage

Default to delegating to subagents for parallel exploration. Specifically:

- `planner` — new features, refactors, anything where the design isn't obvious.
- `tdd-guide` — bug fixes, write the failing test first.
- `code-reviewer` — after writing code, before committing.
- `security-reviewer` — before tagging any release, plus any PR touching auth/network/credentials.
- `Explore` — broad codebase research that would take more than 3 lookups.

Subagents protect the main context window and parallelize work. Use them.

## 16. Widgets & Live Activities (added in 0.5.0)

The WidgetKit and ActivityKit extensions are special-purpose bundles with significantly tighter constraints than the main app. Codifying the rules here so they don't get bent by accident.

**Data flow:**

- Extensions read from the App-Group container `group.com.reolens.Reolens` only — see [Sources/AppShared/SharedContainer.swift](Sources/AppShared/SharedContainer.swift) for the canonical I/O paths.
- The main app writes; extensions read. Atomically. Never the other way around.
- The container is **device-local**, never CloudKit-synced. Cross-device widget consistency relies on each device's main app publishing locally; nothing fans out via iCloud.

**Forbidden inside widget / activity extensions:**

- No network. The extensions don't have a `com.apple.security.network.client` entitlement (App Group access is filesystem-only).
- No Keychain reads — both because we don't want widgets touching credentials and because synchronizable Keychain items aren't reachable from extension processes anyway.
- No CloudKit. No camera traffic. No Reolink RTSP / CGI. If the extension needs data, the main app pre-publishes it.
- No `print()` or `os_log` of host names, IPs, or credentials — same logging rules as the main app (§11), enforced by review.

**Live Activity lifecycle (updated in 0.5.1):**

- One activity **per hub** (not per camera). A fresh fire on the **same hub** *merges* into the existing activity — dedup `aiTags`, bump `coalescedCount`, refresh `lastUpdatedAt`. Activities never stack; previous-per-camera replacement semantics from 0.5.0 are gone.
- 8-hour stale-date window (was 4h in 0.5.0). `SharedContainer.purgeStaleActivityAssets()` still runs on every activity start to keep the trigger-frame directory bounded.
- `Activity.request(... pushType: .token)` opts the activity in to APNs push updates; iOS hands us a token via `for await tokenData in activity.pushTokenUpdates`, which `MotionEventActivityController` forwards to `LiveActivityPushTokenRegistry`. The registry persists tokens to iCloud Drive (`live-activity-tokens_v1.json`) for a future server-driven sender to consume. Until that sender exists, the local Baichuan-event-driven `update(...)` path is still the only updater — push wiring is purely additive.
- `relevanceScore` is recency-decayed (linear over the stale window) so Dynamic Island prefers the currently-active hub when multiple activities are running.

**Why this matters:** widgets and Live Activities run in user-visible OS-managed surfaces (Home Screen, Lock Screen, Dynamic Island). A leaked URL or credential here is visible system-wide. The constraints above are deliberate and non-negotiable. AGENTS.md §3, §5, §11 all apply double in this directory.

---

## How to add to this file

This is a living document. If you find yourself making the same judgment call twice, codify it here. Keep entries short and concrete. The goal is fewer, sharper rules — not exhaustive checklists.
