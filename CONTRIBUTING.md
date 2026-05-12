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

- Xcode 16 (macOS app) / Xcode 26 (iOS app). The macOS app builds
  through SwiftPM; iOS uses a generated Xcode project.
- Swift 6 (strict concurrency on by default).
- An Apple Developer account for code signing iOS builds locally;
  unsigned macOS dev builds run fine via `./Scripts/build-app.sh run`.

Build & test:

```sh
swift build                 # libs + macOS app
swift test                  # unit + integration tests (AppShared, RTSP, Baichuan)
./Scripts/build-app.sh run  # bundled .app with Local Network entitlement
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
| RTSP / VideoToolbox / sample buffer | `Sources/ReolinkStreaming/` |
| CGI commands, Codable models, URL building | `Sources/ReolinkAPI/` |
| Baichuan (port 9000, talkback, push) | `Sources/ReolinkBaichuan/` |
| State, persistence, iCloud, Keychain, App Intents | `Sources/AppShared/` |
| macOS SwiftUI views | `App/Views/` |
| iOS/iPadOS SwiftUI views | `AppiOS/Sources/Views/` |
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
- 80% coverage target on `AppShared` and `Reolink*` libraries.
- No real network in tests. Use `URLProtocol` stubs, fixture servers,
  or protocol-injected fakes.
- Tests must be deterministic. If a test depends on timing or random
  ordering, it's wrong.

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
