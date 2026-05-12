<h1 align="center">
  <img src="docs/assets/icon-256.png" alt="Reolens" width="128" height="128"><br>
  Reolens
</h1>

<p align="center">
  A modern, Apple-silicon-native client for Reolink cameras and NVRs — on Mac, iPad, and iPhone.
</p>

<p align="center">
  <a href="https://github.com/jestatsio/reolens/actions/workflows/ci.yml"><img src="https://github.com/jestatsio/reolens/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jestatsio/reolens/releases/latest"><img src="https://img.shields.io/github/v/release/jestatsio/reolens?label=download&color=4cd2ff" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1ba6d8" alt="macOS 14+">
  <img src="https://img.shields.io/badge/iOS-18%2B-1ba6d8" alt="iOS 18+">
</p>

<p align="center">
  <a href="https://reolens.io">Website</a> ·
  <a href="https://github.com/jestatsio/reolens/releases/latest/download/Reolens.dmg">Download</a> ·
  <a href="#install">Install</a> ·
  <a href="https://github.com/jestatsio/reolens/issues">Issues</a>
</p>

---

Reolens is a native client for Reolink cameras, NVRs, and Home Hubs, available
on macOS, iPad, and iPhone. SwiftUI, Swift 6 strict concurrency,
AVFoundation/VideoToolbox — no Electron, no Java, no QtWebEngine. Cold
launches in under a second; battery-friendly; feels like every other native
Apple app on each platform.

**As of v0.2.0**, Reolens ships an iPad/iPhone app alongside the Mac one,
sharing the same Reolink protocol stack and syncing your camera list (and
grid layout) across all your devices via iCloud Drive. Passwords stay
per-device in Keychain — they never leave the device they were entered on.
See [`AppiOS/README.md`](AppiOS/README.md) for the iOS-specific layout.

![Adaptive multi-camera grid](docs/screenshots/grid-adaptive.png)

> All footage in screenshots is blurred — your cameras, your privacy.

## Features

- **Live multi-camera grids** — adaptive layout fills the window; switch to
  spotlight, 2×2, 3×3, or 4×4 with one click
- **Drag to rearrange** — pull tiles between slots; the order sticks per device
- **Full PTZ** — all 17 PTZ ops (pan, tilt, zoom, focus, presets, patrols)
  from the dedicated control bar
- **Rich alarm notifications** — when motion fires, get a macOS notification
  with the trigger frame, not just text
- **Two-way talkback** — for Reolink cameras that support it
- **Native streaming** — RTSP / FLV / JPEG fallback, hardware-decoded with
  VideoToolbox
- **Auto-updates** — Sparkle in-app updates from a single signed appcast
- **Open source** — MIT-licensed, build it yourself if you prefer

## System requirements

- macOS 14 Sonoma or later
- Apple Silicon (M-series) or Intel — universal binary
- Reolink camera, NVR, or Home Hub on the local network
- HTTP/HTTPS access to the device's CGI port (default 80 / 443)

## Install

### Homebrew (recommended)

```sh
brew tap jestatsio/reolens
brew install --cask reolens
```

Updates are handled by Sparkle inside the app — no `brew upgrade` needed.

### Direct download

Grab the signed, notarized DMG from the [latest release](https://github.com/jestatsio/reolens/releases/latest):

```
https://github.com/jestatsio/reolens/releases/latest/download/Reolens.dmg
```

Drag **Reolens.app** to your Applications folder and launch.

### Build from source

```sh
git clone https://github.com/jestatsio/reolens.git
cd reolens
./Scripts/build-app.sh run
```

Requires Xcode 16 + Swift 6.

## Quick start

1. **Launch Reolens.** It'll ask for Local Network permission (needed to
   reach your cameras) and Notification permission (for motion alerts).
2. **Click the + in the sidebar** to add a camera. Enter the IP address
   (or hostname), username, and password — the rest is auto-detected.
3. **Pick a camera in the sidebar** to view it. Use the layout picker
   (toolbar) to switch between adaptive / spotlight / 2×2 / 3×3 / 4×4 grids.

Drag tiles to rearrange them. Right-click a tile for "Make primary",
"Rotate", and per-channel settings.

## Screenshots

| | |
|---|---|
| ![Adaptive grid](docs/screenshots/grid-adaptive.png) | ![Spotlight layout](docs/screenshots/spotlight.png) |
| Adaptive multi-camera grid | Spotlight layout |
| ![Detail + PTZ](docs/screenshots/detail-ptz.png) | ![About panel](docs/screenshots/about.png) |
| Detail view with full PTZ controls | About panel — version + Check for Updates |

## Architecture

Layered, dependency-only-downward:

```
┌────────────────────────────────────────────────┐
│ App (SwiftUI views, @Observable state)         │
├────────────────────────────────────────────────┤
│ ReolinkBaichuan (port 9000 protocol)           │
│ ReolinkStreaming (RTSP + VideoToolbox)         │
├────────────────────────────────────────────────┤
│ ReolinkAPI (CGI client, models, URLs)          │
└────────────────────────────────────────────────┘
```

`ReolinkAPI` knows nothing about SwiftUI, AppKit, or video frameworks — it's
testable in isolation and ships as a standalone SPM library.

### Concurrency model

- `CGIClient` is an **actor** — one instance per camera/NVR. Reolink
  devices have a notoriously small global session cap, so the actor
  serializes login/refresh and reuses one token across all commands.
- `CameraSession` is `@MainActor`-isolated and `@Observable` — SwiftUI
  views observe `status`, `deviceInfo`, `channels`, `motionState`,
  `aiTriggered` directly.
- Token refresh is implicit; if the device returns `loginRequired`
  mid-session the client drops the token and retries once.

## Repository layout

```
Package.swift            — SwiftPM manifest (libs + executable + tests)
App/                     — SwiftUI executable
  ReolensApp.swift       — @main, About panel, Check-for-Updates menu
  State/                 — CameraStore, CameraSession, UpdaterController
  Views/                 — sidebar, grid, detail, PTZ, settings, About
Sources/
  ReolinkAPI/            — CGI client + Codable models (no UI deps)
  ReolinkStreaming/      — RTSP / VideoToolbox / SDP
  ReolinkBaichuan/       — port-9000 protocol (talkback, push, alarms)
Tests/
  ReolinkAPITests/       — Codable + URL builders
  ReolinkStreamingTests/ — SDP parsing, RTSP digest, codec depacketization
  ReolinkBaichuanTests/  — Baichuan encryption + framing
  ReolensE2ETests/       — end-to-end integration test (mocked transport)
Scripts/
  build-app.sh           — assemble .app, embed Sparkle, sign
  build-icns.sh          — slice icon master into AppIcon.icns
  make-icon.swift        — generate icon master from CoreGraphics
  make-dmg.sh            — package .app into a styled DMG
  notarize.sh            — submit to Apple notary + staple
docs/                    — reolens.io landing page (GitHub Pages)
dist/homebrew/reolens.rb — Homebrew cask formula template
.github/workflows/
  ci.yml                 — build + test + smoke launch on every PR
  release.yml            — on tag push: build → notarize → DMG → release
```

## Development

### Build & test

```sh
swift build                # libs + app
swift test                 # 70+ tests
./Scripts/build-app.sh run # bundled .app (needed for Local Network access)
```

### Release process

See [docs/RELEASE.md](docs/RELEASE.md) for the full runbook. Short version:

1. Bump `CFBundleShortVersionString` in [App/Info.plist](App/Info.plist)
2. Add a section to [CHANGELOG.md](CHANGELOG.md)
3. `git tag v0.1.1 && git push --tags`
4. Watch [.github/workflows/release.yml](.github/workflows/release.yml) build,
   notarize, package the DMG, regenerate the appcast, and publish

## API coverage today

Implemented as typed `Commands.*` constructors:

- `Login` / `Logout`
- `GetDevInfo`
- `GetAbility` (with capability-tree navigation + per-channel accessors)
- `GetChannelstatus`
- `GetMdState`
- `GetAiState` (people / vehicle / dog_cat / face / package / other / visitor)
- `PtzCtrl` (all 17 ops including presets, patrol, zoom, focus)
- `GetLocalLink`, `GetTime`, `GetOsd`, `SetOsd`, `GetHddInfo`
- `Search` (recordings list + per-day status)

Adding a new command is mechanical — define a typed param + value model,
construct a `CGICommand`, and call `client.send(_:as:)`. See
[Commands.swift](Sources/ReolinkAPI/Commands/Commands.swift) for examples.

## Roadmap

- Native RTSP + VideoToolbox playback (currently JPEG-snapshot fallback
  while the streaming path matures)
- Baichuan-based talkback for battery cameras
- Recording timeline scrubber
- Live Activities + widgets

See the [GitHub issues](https://github.com/jestatsio/reolens/issues) for
the full plan.

## Privacy

Reolens runs entirely on your Mac. It talks only to:

- Your Reolink devices (over the local network)
- `reolens.io/appcast.xml` (for update checks; you can disable updates
  in Settings)

No analytics. No telemetry. No accounts. Camera passwords live in your
macOS Keychain.

## License

MIT — see [LICENSE](LICENSE).

Reolink is a trademark of Reolink Innovation Inc. Reolens is an
unaffiliated third-party client. The Reolink protocol is reverse-
engineered from public CGI documentation and community projects:

- Reolink CGI v1.61 reference PDF
- [starkillerOG/reolink_aio](https://github.com/starkillerOG/reolink_aio) (Python ref, used by Home Assistant)
- [thirtythreeforty/neolink](https://github.com/thirtythreeforty/neolink) (Rust ref for Baichuan)
