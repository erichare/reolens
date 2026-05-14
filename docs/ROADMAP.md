# Reolens Roadmap

This file consolidates the "future work" notes scattered across
`AGENTS.md`, `SECURITY.md`, and the `CHANGELOG.md` headers. The
roadmap is intentionally loose — Reolens is small and opinionated, and
priorities shift with what users surface in the field.

Status keys:

- **Scaffolded** — code is in the repo, but the feature is gated on
  something external (Apple cert, missing server, design decision).
- **Planned** — committed to a future release.
- **Considering** — being weighed; not committed.
- **Won't do** — explicitly out of scope. Listed so the conversation
  doesn't recur.

---

## HomeKit Secure Video — full integration

- **Status:** Scaffolded (0.6.0).
- **Owner:** Eric.
- **Blocker:** Apple MFi certification for the HKSV recording tier.
  Until that completes, the public HomeKit framework on macOS isn't
  available to native apps (only Mac Catalyst), and the
  `HMCameraProfile` registration path can't be implemented.
- **Code:** [Sources/AppShared/HomeKitBridge.swift](../Sources/AppShared/HomeKitBridge.swift) (stubbed `registerAccessoryIfNeeded(for:)`),
  [Sources/AppShared/HomeKitSection.swift](../Sources/AppShared/HomeKitSection.swift) (Settings UI).
- **What ships today:** per-camera `homeKitEnabled` flag (synced via
  iCloud `cameras.json`), Settings → Privacy & Sync → HomeKit section
  on iOS / iPadOS only, availability state machine, MFi-blocker
  explainer in the UI.
- **What 0.6.1 adds:** clearer MFi explainer copy in the HomeKit
  Settings section.

## Live Activity push relay server

- **Status:** Scaffolded (0.5.1 token persistence; 0.6.0 unchanged).
- **Blocker:** No server-side sender yet. The current local
  Baichuan-event-driven path is the only updater — push wiring is
  purely additive.
- **Code:** [Sources/AppShared/LiveActivityPushTokenRegistry.swift](../Sources/AppShared/LiveActivityPushTokenRegistry.swift),
  `live-activity-tokens_v1.json` in iCloud Drive.
- **Considering:** a peer-Apple-device relay (one Mac acts as sender
  for other devices on the same iCloud account, similar to the
  existing motion-event relay) before standing up dedicated server
  infrastructure.

## Coverage ratchet toward 80%

- **Status:** In progress.
- **Code:** [Scripts/coverage-baselines.txt](../Scripts/coverage-baselines.txt),
  [Scripts/coverage-gate.sh](../Scripts/coverage-gate.sh).
- **0.6.0 baseline:** AppShared 13.81%, ReolinkAPI 56.47%,
  ReolinkStreaming 23.70%, ReolinkBaichuan 32.70%. ~340 tests across
  68 suites.
- **0.6.1 target:** raise AppShared baseline by ≥10pp by targeting
  `EventNotifier`, `RecordingsLoader`, `RecordingIndex`, `PollManager`,
  `BookmarkAutoDownloader`, and the new `AppErrorRecorder`.

## Long-tail `try?` migration

- **Status:** Planned.
- **Driver:** Release-plan WS7. Top-10 worst offenders fixed in 0.6.1
  (see [docs/audit-0.6.1-error-sites.md](audit-0.6.1-error-sites.md));
  the remaining ~176 sites migrate incrementally as `AppError`
  adoption widens.
- **Approach:** opportunistic. Every PR that touches an error-prone
  call site should route the failure through `AppErrorRecorder` if it
  matters to the user.

## Settings redesign rollout

- **Status:** In progress (0.6.1).
- **Driver:** Release-plan WS3. New 7-bucket IA lands behind a DEBUG
  flag, validated by simulator click-through, then flipped default-on
  before tag.

## Larger view-file decomposition

- **Status:** In progress (0.6.1).
- **Driver:** Release-plan WS5. `AllRecordingsView` (1140 LOC) and per-
  platform `RecordingsView` shells (1086 / 670 LOC) decompose into
  files under 800 LOC.

## Privacy-zone editor cross-platform parity

- **Status:** Considering.
- **Note:** privacy zones currently edit on macOS; iOS has a thinner
  surface. Bring iOS to parity in a future release.

## Recordings export to Files / Photos

- **Status:** Considering (0.6.1 candidate small feature).
- **Note:** `ClipExporter` already handles the file-side work; the
  Settings flag and share-sheet wiring are the missing pieces.

## Keyboard shortcuts on macOS

- **Status:** Considering (0.6.1 candidate small feature).
- **Note:** primary actions (camera switch, play/pause, scrub) would
  benefit from `.keyboardShortcut(...)`. Track which actions are
  candidates in a follow-up.

## Won't do

- **In-app telemetry** — Reolens has a hard "zero telemetry" rule
  ([AGENTS.md §5](../AGENTS.md)). Diagnostics stay local (`AppErrorRecorder`,
  `NotificationHistory`, `RelayDiagnostics`).
- **Cross-vendor camera support** — Reolens is opinionated about
  Reolink. Wide multi-vendor support would change the product surface.
- **Cloud relay servers operated by us** — Reolens has no servers and
  isn't planning any. The CloudKit relay rides the user's own iCloud
  account.
