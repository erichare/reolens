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
  desktop widgets. The macOS app builds through SwiftPM; iOS uses an
  xcodegen-managed Xcode project.
- Swift 6.2 (strict concurrency on by default).
- An Apple Developer account for code signing iOS builds locally;
  unsigned macOS dev builds run fine via `./Scripts/build-app.sh run`.

Build & test:

```sh
swift build                 # libs + macOS app
swift test                  # 158 tests across 43 suites (AppShared, RTSP, Baichuan, …)
./Scripts/build-app.sh run  # bundled .app with Local Network entitlement
```

CI gates also runnable locally (both block PRs in `.github/workflows/ci.yml`):

```sh
bash Scripts/check-versions.sh   # macOS + iOS marketing versions must match (AGENTS.md §13)
bash Scripts/coverage-gate.sh    # ≥ 80 % line coverage on AppShared + Reolink* (AGENTS.md §12)
```

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
| State, persistence, iCloud, Keychain, App Intents, EventNotifier, SharedContainer, DigestScheduler, ThumbnailCache, ClipExporter, RecordingBookmarkStore, PrivacyZoneEditor*, ReolensGlass, ScrubberView, MotionEventActivityAttributes, ReolensScene | `Sources/AppShared/` |
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
  are not XCTest.
- **80 % line-coverage floor on `AppShared` and `Reolink*` — CI-enforced**
  by `Scripts/coverage-gate.sh` (AGENTS.md §12). PRs that drop coverage
  on those targets below 80 % are blocked.
- No real network in tests. Use `URLProtocol` stubs, fixture servers,
  or protocol-injected fakes.
- Tests must be deterministic. If a test depends on timing or random
  ordering, it's wrong.
- Widget / Live Activity extension code is tested via the shared
  `AppShared` model layer (see `Tests/AppSharedTests/SharedContainerTests.swift`).
  The extension targets themselves are integration-tested by
  `xcodebuild` against the regenerated Xcode project; SPM-side tests
  don't exercise them.

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
one. Short version: bump versions in both Info.plist files plus the iOS
project.pbxproj `MARKETING_VERSION`, add a `## [X.Y.Z]` section to
[`CHANGELOG.md`](CHANGELOG.md), tag, push.

## Code of conduct

Be kind. Assume good faith. If someone's behavior in an issue or PR
makes you uncomfortable, email `conduct@reolens.io` and a maintainer
will look at it.
