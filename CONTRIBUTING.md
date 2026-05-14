# Contributing to Reolens

Thanks for thinking about contributing. Reolens is a small, opinionated
app — a few rules upfront save us all time.

## Before you start

1. Read [`AGENTS.md`](AGENTS.md). It's the engineering principles for
   this repo — platform parity, credentials are device-local, no
   third-party analytics, backward-compatible iCloud schema. Every
   change is reviewed against these.
2. For non-trivial work, open an issue first to discuss the approach.
   Trivial means "fix a typo" or "tighten a comment"; a UI change or
   a new feature is not trivial.
3. Security issues: don't open a public issue. Follow the private
   reporting flow in [`SECURITY.md`](SECURITY.md).

## Dev setup

Tooling:

- Xcode 26 (both platforms). 0.5.0 raised the deployment floor to
  macOS 26 / iOS 26 to adopt Liquid Glass + ActivityKit + WidgetKit
  desktop widgets; 0.5.1 leans on the same floor for
  `FoundationModels`; 0.6.0 keeps it. The macOS app builds through
  SwiftPM; iOS uses an xcodegen-managed Xcode project.
- Swift 6.2 (strict concurrency on by default).
- An Apple Developer account for code signing iOS builds locally;
  unsigned macOS dev builds run fine via `./Scripts/build-app.sh run`.

Build & test:

```sh
swift build                 # libs + macOS app
swift test                  # ~340 tests across 68 suites
./Scripts/build-app.sh run  # bundled .app with Local Network entitlement
```

CI gates also runnable locally (both block PRs in `.github/workflows/ci.yml`):

```sh
bash Scripts/check-versions.sh   # macOS + iOS marketing versions must match (AGENTS.md §13)
bash Scripts/coverage-gate.sh    # per-target coverage regression gate (AGENTS.md §12)
```

The coverage gate is **enforced as of 0.6.0** — it now fails on a
regression against `Scripts/coverage-baselines.txt` rather than a
single global 80% floor. If your PR drops coverage on any of the
four library targets by more than 1 pp, the gate fails. Intentional
regressions (e.g. removing dead test code) require running
`COVERAGE_FORCE_UPDATE_BASELINE=1 ./Scripts/coverage-gate.sh`
locally and committing the updated baselines file.

iOS:

```sh
brew install xcodegen
cd AppiOS && xcodegen generate
open ReolensiOS.xcodeproj
# Set DEVELOPMENT_TEAM, ⌘R to a Simulator or device
```

## What to change where

Layered, dependency-only-downward — see [`README.md`](README.md) for
the diagram. The short version:

| If you're changing... | It probably lives in... |
|---|---|
| RTSP / VideoToolbox / sample buffer / H.264 + H.265 decode | `Sources/ReolinkStreaming/` |
| CGI commands, Codable models, URL building, `MaskSettings` | `Sources/ReolinkAPI/` |
| Baichuan (port 9000, talkback, push, `findAlarmVideo`, XML helpers) | `Sources/ReolinkBaichuan/` |
| State, persistence, iCloud, Keychain, App Intents, EventNotifier, SharedContainer, DigestScheduler, ThumbnailCache, ClipExporter, RecordingBookmarkStore, PrivacyZoneEditor*, ReolensGlass, ScrubberView, MotionEventActivityAttributes, ReolensScene, AllRecordingsView, AllRecordingsLoader, RecordingsCache, CameraFilterBar, HubExpansionStore, CameraNotificationPreferences, PerCameraNotificationsSection, BookmarkAutoDownloader, BackgroundDownloadPreferences, EventSummarizer, LiveActivityPushTokenRegistry, **RecordingsLoader, RecordingIndex, RecordingNLSearcher, PollManager, AppPreferences, CameraKeychainStore, CameraListPersistence, RecordingsScreenHeader, WeeklyScheduleEditor, NotificationHistory, RelayDiagnostics, CameraNotificationHealth, AdaptivePollSchedule, HomeKitBridge** | `Sources/AppShared/` |
| macOS SwiftUI views | `App/Views/` |
| macOS menu-bar item + Recent-events popover | `App/MenuBar/` |
| macOS desktop widgets (extension target) | `App/Widgets/` |
| iOS / iPadOS SwiftUI views | `AppiOS/Sources/Views/` |
| iOS WidgetKit + Control Center + ActivityKit extension | `AppiOS/Widgets/` |
| iOS Live Activity controller + bridge adapter | `AppiOS/Sources/LiveActivities/` |
| Build/sign/notarize/DMG | `Scripts/` |
| Landing page | `docs/` |

**If you find yourself about to write the same function twice** (once
under `App/`, once under `AppiOS/`), stop and put it in `AppShared`
instead — that's the rule from [`AGENTS.md`](AGENTS.md) §6.

## Style

- Swift 6 strict concurrency. `Sendable` value types crossing isolation
  boundaries; actors for shared mutable state; structured concurrency
  over loose `Task {}`.
- Prefer `let` over `var`. Mutate at edges; pass values through.
- Small files (<800 lines is a soft ceiling). High cohesion, low coupling.
- One short comment line per non-obvious decision — what's surprising,
  not what the code does. Don't restate the code.
- `os.Logger`, never `print()`. Pick a `subsystem` matching the bundle
  id and a `category` describing the subsystem.
- Credentials never appear in any log at any level. Period.

## Testing

- Use Swift Testing (`import Testing`, `@Test`, `#expect`). New tests
  are not XCTest. The one exception is XCUITest under
  `AppiOS/UITests/` — `XCTest` is unavoidable there because the iOS
  UI-testing harness predates Swift Testing.
- **Per-target coverage regression gate — CI-enforced as of 0.6.0**
  via `Scripts/coverage-gate.sh` (AGENTS.md §12). PRs that drop
  coverage on any library target by more than 1 pp against
  `Scripts/coverage-baselines.txt` are blocked. The long-term 80%
  goal is tracked in the script header; baselines ratchet upward
  as new tests land.
- No real network in tests. Use `URLProtocol` stubs, fixture servers,
  or protocol-injected fakes.
- Tests must be deterministic. If a test depends on timing or random
  ordering, it's wrong. Actor + persistence tests follow the
  `makeFreshURL()` / `makeFreshDefaults()` pattern (see
  `NotificationHistoryTests`, `RecordingIndexTests`,
  `AppPreferencesTests`) — every test gets an isolated storage path
  so cross-test bleed is impossible.
- Widget / Live Activity extension code is tested via the shared
  `AppShared` model layer (see `Tests/AppSharedTests/SharedContainerTests.swift`).
  The extension targets themselves are integration-tested by
  `xcodebuild` against the regenerated Xcode project; SPM-side tests
  don't exercise them.
- **XCUITest journeys (added in 0.6.0)** live under
  `AppiOS/UITests/ReolensiOSUITests.swift`. New journeys land here
  when a regression class can only be caught at the SwiftUI-shell
  level (e.g. a nav-link that compiles but doesn't route). Keep
  journey count small and high-signal — UI tests are slow.

## Commits & PRs

- Conventional commit subject: `feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `chore:`, `perf:`, `ci:`.
- Subject under 70 characters. Body explains *why*, not *what*.
- PRs touching auth, network, credentials, or sync MUST include a
  `Security` section in the PR description explicitly stating what
  was reviewed.
- Run `swift build` and `swift test` locally before pushing. CI will
  re-run them; pre-check saves the round-trip.

## Screenshots

The committed screenshots under `docs/screenshots/` are procedurally
rendered (see [`Scripts/make-stock-camera-views.swift`](Scripts/make-stock-camera-views.swift)
and [`Scripts/make-placeholder-screenshots.swift`](Scripts/make-placeholder-screenshots.swift)).
If you need to regenerate them:

```sh
./Scripts/make-stock-camera-views.swift
./Scripts/make-placeholder-screenshots.swift
```

If you have real raw captures and want to publish them, run the stock
images through [`Scripts/composite-screenshot.sh`](Scripts/composite-screenshot.sh)
to overlay them onto the camera-tile regions — real footage doesn't
ship in marketing materials.

## Release process

Maintainer-only. See [`docs/RELEASE.md`](docs/RELEASE.md) for the macOS
runbook and [`docs/IOS_RELEASE.md`](docs/IOS_RELEASE.md) for the iOS
one. Short version:

1. Bump `CFBundleShortVersionString` in [`App/Info.plist`](App/Info.plist)
   and the matching `MARKETING_VERSION` in [`AppiOS/project.yml`](AppiOS/project.yml).
   `check-versions.sh` blocks PRs that drift.
2. Regenerate the iOS project: `cd AppiOS && xcodegen generate` —
   picks up the bumped version into both Info.plist files.
3. Add a `## [X.Y.Z] — YYYY-MM-DD` section to
   [`CHANGELOG.md`](CHANGELOG.md).
4. Tag and push: `git tag v0.6.0 && git push --tags`.

The `release.yml` workflow handles signing, notarization, DMG
packaging, appcast regeneration, and publishing the GitHub Release
automatically from the tag.

## Code of conduct

Be kind. Assume good faith. If someone's behavior in an issue or PR
makes you uncomfortable, email `conduct@reolens.io` and a maintainer
will look at it.
