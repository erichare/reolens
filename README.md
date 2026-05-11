# Reolens

A modern, Apple Silicon–native macOS client for Reolink cameras and NVRs.

Built with Swift 6.3, SwiftUI, strict concurrency, `@Observable` state, and the
URLSession + Network + AVFoundation/VideoToolbox stack — no Electron, no Java,
no QtWebEngine.

## Project status

| Layer | Status |
| --- | --- |
| Reolink CGI JSON API client (login/token, command batching) | done |
| Codable models for the most common commands | done (Login, DevInfo, ChannelStatus, Ability, MdState, AiState, PTZ) |
| Stream URL builder (RTSP, FLV, JPEG snapshot) | done |
| Unit tests (Swift Testing) | 16/16 passing |
| SwiftUI app shell (sidebar, add-camera, multi-cam grid, PTZ pad) | done |
| JPEG-snapshot live preview (placeholder until RTSP lands) | done |
| Event polling (motion + AI) | done |
| RTSP playback (VLCKit fast path) | next |
| Native RTSP + VideoToolbox `AVSampleBufferDisplayLayer` | phase 2 |
| Playback timeline (Search + RTSP seek) | planned |
| Baichuan port-9000 client (talkback, TCP push, battery wakeup) | planned |
| Live Activities / widgets / local notifications | planned |

## Repository layout

```
Package.swift               — SwiftPM manifest (lib + lib + executable + tests)
Sources/
  ReolinkAPI/               — pure-Swift CGI client + Codable models (no UI deps)
    CGIClient.swift         — actor-isolated client, manages one token lease
    StreamURLs.swift        — RTSP / FLV / snapshot URL builders
    Camera.swift            — credentials + token value types
    Models/                 — DeviceInfo, ChannelStatus, Ability, Login, AI/MD
    Commands/               — strongly-typed CGI command constructors + envelope
  ReolinkStreaming/         — video module (stub; RTSP playback lands here)
App/                        — Reolens executable (SwiftUI)
  ReolensApp.swift          — @main scene + Settings scene
  State/                    — CameraStore (@Observable), CameraSession, Keychain
  Views/                    — sidebar, detail, grid, PTZ pad, add-camera sheet
Tests/
  ReolinkAPITests/          — Swift Testing suite for codable + URL building
```

## Architecture

### Layered, dependency-only-downward

```
┌────────────────────────────────────────────────┐
│ App (SwiftUI views, @Observable state)         │
├────────────────────────────────────────────────┤
│ ReolinkStreaming (RTSP + VideoToolbox)         │ ← upcoming
├────────────────────────────────────────────────┤
│ ReolinkAPI (CGI client, models, URLs)          │
└────────────────────────────────────────────────┘
```

`ReolinkAPI` knows nothing about SwiftUI, AppKit, or video frameworks — it's
testable in isolation and could ship as a standalone SPM package.

### Concurrency model

- `CGIClient` is an **actor** — one instance per camera/NVR. Reolink devices
  have a notoriously small global session cap, so the actor serializes
  login/refresh and reuses one token across all commands for that device.
- `CameraSession` is `@MainActor`-isolated and `@Observable` — SwiftUI views
  observe `status`, `deviceInfo`, `channels`, `motionState`, `aiTriggered`
  directly.
- Token refresh is implicit: every batched call goes through `login()`, which
  reuses the cached token unless it's within 60 s of expiry.
- If the device returns `loginRequired` mid-session, the client drops the
  token and retries once.

## API coverage today

Implemented as typed `Commands.*` constructors:

- `Login` / `Logout`
- `GetDevInfo`
- `GetAbility` (with capability-tree navigation + per-channel accessors)
- `GetChannelstatus`
- `GetMdState`
- `GetAiState` (people / vehicle / dog_cat / face / package / other / visitor)
- `PtzCtrl` (all 17 ops including presets, patrol, zoom, focus)
- `GetLocalLink`, `GetTime`

Adding a new command is mechanical:

```swift
public static func getOsd(channel: Int) -> CGICommand<ChannelParam> {
    CGICommand(cmd: "GetOsd", action: .get, param: .init(channel: channel))
}
```

Then define a `Decodable` value type and call `client.send(_:as:)`.

## Building & running

```sh
swift build              # builds the library + the Reolens app
swift test               # runs the test suite
.build/debug/Reolens     # launches the app (debug build)
```

For a release build:

```sh
swift build -c release
.build/release/Reolens
```

For App Store / signed distribution, the SwiftPM executable can be wrapped in
an Xcode App project, or the entitlements plist can be hand-crafted — to be
done when we add Live Activities and push notifications.

## Roadmap notes

### Video — three paths, pick in order

1. **VLCKit (`MobileVLCKit`)** — fastest path to pixels on screen.
   ~25 MB binary, LGPL, supports H.264/H.265/AAC out of the box, hardware
   decode through VideoToolbox under the hood. We'll ship this first.

2. **Native RTSP + VideoToolbox**. RTSP is text-based RTP/RTSP over TCP/UDP;
   ~2-3 weeks of work over `Network.framework` (`NWConnection`) and
   `VTDecompressionSession`. Render `CMSampleBuffer`s into a per-tile
   `AVSampleBufferDisplayLayer`. Lets us drop the VLCKit binary.

3. **Baichuan port 9000** — proprietary protocol; the only way to do
   talkback and to wake battery cameras. Port from
   [`thirtythreeforty/neolink`](https://github.com/thirtythreeforty/neolink).

### Events

Today we poll `GetMdState` + `GetAiState` every 2 s. Two upgrades:

- **ONVIF PullPoint** subscriptions on port 8000 — long-poll, no busy poll.
- **Baichuan TCP push** on port 9000 — server-initiated, lowest latency,
  doesn't burn through the device's session cap.

## Sources of API knowledge

- Reolink CGI v1.61 PDF — `https://reolink.com/wp-content/uploads/2017/01/Reolink-CGI-command-v1.61.pdf`
- Reolink API v8 community thread — `https://community.reolink.com/topic/4196/`
- [starkillerOG/reolink_aio](https://github.com/starkillerOG/reolink_aio) — Python ref, used by Home Assistant
- [thirtythreeforty/neolink](https://github.com/thirtythreeforty/neolink) — Rust ref for Baichuan protocol
