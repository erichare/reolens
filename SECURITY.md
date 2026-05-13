# Security policy

Reolens handles live video feeds from users' own security cameras and
the credentials needed to authenticate to those cameras. We take
security reports seriously.

## Reporting a vulnerability

**Please do not file a public GitHub issue for security problems.**

Use one of these private channels instead:

1. **GitHub Security Advisories (preferred).** Open a draft advisory:
   https://github.com/jestatsio/reolens/security/advisories/new
   This keeps the discussion private until a fix is published.
2. **Email.** `security@reolens.io`. Include "Reolens security" in
   the subject. If you want to PGP-encrypt, ask in your first message
   and we'll share a key.

What to include in your report:

- A clear description of the issue and its impact (what an attacker
  could achieve).
- Reproduction steps. Minimum viable repro: app version, OS version,
  Reolink device model + firmware version, and the exact actions
  that trigger the vulnerability.
- Suggested mitigation if you have one (welcome but not required).

## Response timeline

- **48 hours** — first acknowledgment that we received the report.
- **7 days** — initial triage with a CVSS-style severity assessment
  and a rough fix timeline.
- **30 days** — fixed and released for issues we've confirmed as
  reproducible, unless the fix requires upstream coordination (e.g.
  a Reolink firmware change) — in which case we'll tell you the new
  ETA.

We'll keep you posted at each step and credit you in the
[`CHANGELOG.md`](CHANGELOG.md) entry for the fix, unless you'd rather
stay anonymous.

## What we consider a security issue

In scope:

- Credential exposure (host, username, password, session token) via
  logs, crash reports, sync, telemetry, or any output Reolens
  produces.
- Authentication bypass against Reolink devices.
- Local-network attacks against the app itself (e.g. malformed RTSP
  packets crashing the player, certificate-validation bypasses).
- Privilege escalation on the host OS via the app's entitlements.
- Tampering with the Sparkle update channel (signature bypass,
  appcast spoofing) or the App Store distribution.
- Privacy regressions: Reolens making network calls to anywhere other
  than your Reolink devices, iCloud, the Sparkle appcast, or Apple's
  own services.
- iCloud sync schema regressions that would expose camera passwords
  to other devices.
- **App Group container leakage (0.5.0).** Widgets and the Live
  Activity extension read snapshots and recent motion-event metadata
  from `group.com.reolens.Reolens`. Any path that lets data outside
  of (a) recent snapshot JPEGs, (b) recent motion-event metadata, or
  (c) daily digest records into that container, or that lets the
  extensions write *back* to the container, is in scope.
- **CloudKit motion-event relay regressions.** The relay publishes
  to the user's private CloudKit database. Any change that increases
  the per-record payload beyond the documented `MotionEvent` /
  `MotionEventRecordID` shape, that bypasses the per-camera rate
  limit, or that publishes after the multi-account guard has fired
  is in scope.
- **Live Activity push token leakage (0.5.1).**
  `LiveActivityPushTokenRegistry` persists per-activity APNs tokens
  to the iCloud Drive ubiquity container
  (`live-activity-tokens_v1.json`). Tokens are tied to specific
  Activity IDs and rotate when iOS tears down and rebuilds the
  activity. Any path that (a) logs the raw token at any level,
  (b) writes the token outside this designated file, or (c)
  serializes anything beyond `activityID + cameraID + pushTokenHex
  + issuedAt` is in scope. Token storage outside iCloud Drive
  (e.g. into `cameras.json`, `UserDefaults`, or the App Group) is
  a regression.
- **Background bookmark-download payload widening (0.5.1).** The
  background URLSession at identifier `com.reolens.bookmarkDL`
  downloads recording clips to
  `Application Support/Reolens/bookmarks/<bookmarkID>.mp4`. The
  source URL embeds the user's CGI token; if the
  `task.taskDescription` (used to bind a task back to a bookmark
  on relaunch) ever carries anything other than the bookmark UUID,
  or if downloaded files land outside the designated directory, or
  if cellular access is allowed without the explicit
  `BackgroundDownloadPreferences.allowCellular` opt-in being true,
  that's in scope.
- **Per-camera notification-mute state.**
  `com.reolens.mutedCameraNotifications` is a synced `[UUID-string]`
  set. Any path that carries additional fields (e.g. timestamps,
  hostnames) or that publishes anything beyond a UUID list is in
  scope. The `NSUbiquitousKeyValueStore` value is plaintext-readable
  by anyone signed into the same Apple ID — by design — but it must
  never carry credentials or hostnames.

Out of scope:

- Issues in Reolink firmware itself — report those to Reolink.
- Issues that require a malicious app already running on the user's
  device with the same entitlements as Reolens.
- Theoretical issues without a concrete impact assessment (e.g. "you
  should use longer keys").
- Social engineering of the maintainers.

## Architectural baseline

Reolens enforces these properties at the architectural level. A bug
report alleging any of them is broken is automatically in scope:

1. **Camera passwords never leave the device.** They live in Keychain
   with `kSecAttrSynchronizable: false`; they are not written to
   `cameras.json`, `UserDefaults`, logs at any level, or any network
   payload other than RTSP/HTTP authentication to the specific
   Reolink device.
2. **iCloud sync carries metadata only.** `cameras.json` contains
   display name, host, port, username, grid layout, channel order,
   rotations — never a password.
3. **No third-party analytics, no remote crash reporting.** The app
   talks to your Reolink devices, iCloud, the Sparkle appcast
   (macOS), and Apple's TestFlight / App Store — that's it.
4. **Drag and intent payloads carry IDs, never credentials.** The
   `com.reolens.channelDrag`, `com.reolens.deviceDrag`, and App
   Intents `OpenCameraIntent` paths all transport only UUIDs / channel
   integers.
5. **Widget / Live Activity extensions are filesystem-only.** They
   have no `com.apple.security.network.client` entitlement and no
   Keychain access. Their only data source is the
   `group.com.reolens.Reolens` App Group container, which is
   device-local and never CloudKit-synced. AGENTS.md §16 codifies
   the full constraint set.
6. **On-device-only AI (0.5.1).** The Today digest uses Apple's
   `FoundationModels` framework, which runs **on-device**. No
   recording metadata, AI tags, camera names, or any other data
   crosses the device boundary. The `FoundationModels` framework
   itself enforces this contract; we never proxy the inference to a
   cloud model.
7. **Live Activity push channel is opt-in-by-OS.**
   `pushType: .token` tells iOS to issue a push token for the
   activity; the OS decides whether to honor it. Reolens does not
   send pushes today (no server infrastructure); the registry
   merely persists tokens for a future sender. Until that sender
   exists, the local Baichuan-event-driven update path is the only
   updater.

See [`AGENTS.md`](AGENTS.md) for the full engineering principles.

## Disclosure

Once a fix is released:

- The fix lands in a tagged release with the security note in
  `CHANGELOG.md`.
- The GitHub Security Advisory is published with the CVE if one was
  assigned.
- Reporters who consent are credited by name (or handle, or
  anonymously, as preferred).

## Supported versions

| Release | Platform floors                | Status                                                                                  |
|---------|--------------------------------|-----------------------------------------------------------------------------------------|
| 0.5.x   | macOS 26 / iOS 26 / iPadOS 26  | **Current.** Receives all security fixes and feature work.                              |
| 0.4.x   | macOS 14 / iOS 18 / iPadOS 18  | **Security backports only**, through the end of the 0.5 cycle (~6 months after 0.5.0). |
| ≤ 0.3.x | various                        | End of life. No backports.                                                              |

The 0.5.0 deployment-floor bump exists so the app can adopt Liquid Glass plus the ActivityKit / WidgetKit / ControlWidget APIs Apple shipped in iOS 26 / macOS 26. Users who can't upgrade their OS should stay on the 0.4.x track. Any security fix that applies to both tracks will land on `main` (which targets 0.5.x) and be cherry-picked to the `release/0.4.x` branch for backport.

Outside this support matrix, we will not backport.
