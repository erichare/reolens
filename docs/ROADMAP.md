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
- **What 0.6.2 adds:** dark `HomeKitBridge.fullIntegrationEnabled`
  prep flag. Centralizes the gate so 0.7.0 can light up the real
  `HMCameraProfile` registration from one place if MFi resolves.
- **0.7.0 plan:** if the cert lands, flip the prep flag and implement
  the real `HMCameraProfile` registration + RTSP-to-HKSV piping +
  Baichuan-tag-to-HMCharacteristicEvent translation. If MFi doesn't
  resolve, the flag stays dark and the integration defers further.

## Live Activity push relay (peer-device)

- **Status:** Planned (0.7.0).
- **Blocker:** No sender yet. The current local Baichuan-event-driven
  path is the only updater — push wiring is purely additive. Reolens
  has no servers and isn't standing any up, so the relay rides peer
  Apple devices on the same iCloud account.
- **Approach:** a peer-Apple-device relay (one Mac acts as sender for
  other devices on the same iCloud account, similar to the existing
  motion-event relay). Token persistence already lives in
  [Sources/AppShared/LiveActivityPushTokenRegistry.swift](../Sources/AppShared/LiveActivityPushTokenRegistry.swift)
  / `live-activity-tokens_v1.json`; 0.7.0 wires the sender.
- **Code:** [Sources/AppShared/LiveActivityPushTokenRegistry.swift](../Sources/AppShared/LiveActivityPushTokenRegistry.swift).

## Coverage ratchet toward 80%

- **Status:** In progress.
- **Code:** [Scripts/coverage-baselines.txt](../Scripts/coverage-baselines.txt),
  [Scripts/coverage-gate.sh](../Scripts/coverage-gate.sh).
- **0.6.0 baseline:** AppShared 13.81%, ReolinkAPI 56.47%,
  ReolinkStreaming 23.70%, ReolinkBaichuan 32.70%. ~340 tests across
  68 suites.
- **0.6.1 actuals:** AppShared 13.81% → 14.31%, ReolinkAPI 56.47% →
  58.82%, ReolinkStreaming 23.70% → 23.82%. 354 tests.
- **0.6.2 target:** ratchet AppShared via the new `ClipExporter`
  export surfaces (Photos / share-sheet / drag-out unit + XCUITest
  coverage) and the view-decomposition snapshot suite.
- **0.6.2 CI:** coverage gate promoted from informational → required.

## Long-tail `try?` migration

- **Status:** In progress.
- **Driver:** Release-plan WS7. Top-10 worst offenders fixed in 0.6.1
  (see [docs/audit-0.6.1-error-sites.md](audit-0.6.1-error-sites.md));
  0.6.2 takes the next 30 sites, with tests covering the ones the
  ClipExporter storyline naturally touches. The remaining ~150 sites
  migrate incrementally as `AppError` adoption widens.
- **Approach:** opportunistic. Every PR that touches an error-prone
  call site should route the failure through `AppErrorRecorder` if it
  matters to the user.

## iOS-build CI gate promotion

- **Status:** Planned (0.6.3) — was originally planned for 0.6.2,
  deferred because GitHub's `macos-26` runner image still ships
  Xcode 26 variants that can't resolve `generic/platform=iOS`
  (stable 26.3 lacks the device-platform component; beta 26.5
  lacks matching simulator runtimes).
- **Workflow change required:** drop the `continue-on-error: true`
  on the three iOS-build steps in `.github/workflows/ci.yml` once
  the runner image carries a non-beta Xcode 26.x with both the
  device-platform bits and matching simulator runtimes.
- **Why deferred:** the iOS code is already covered by the
  required `swift build` job via `.iOS(.v26)` in Package.swift,
  and the real iOS build (`release.yml`) runs end-to-end on tag
  push with maintainer certs. Promoting CI's xcodebuild-iOS step
  is for catching regressions earlier, not for shipping safety.

Update the RELEASE.md 0.6.2 verification step that pins both CI
gates as required — only the coverage gate is required (already
since 0.6.0); the iOS build job stays informational this cycle.

## Accessibility follow-ups

- **Status:** Planned (0.6.3).
- **Driver:** items 1 and 4 of the 0.6.2 a11y batch deferred because
  both require device verification rather than source-only review.
- **Items:**
  - Full Dynamic Type pass on the player chrome at AX5 / AX5+ across
    iPhone / iPad / macOS. The 0.6.2 audit confirmed text styles are
    in use on the chrome; this is the visual regression sweep.
  - WCAG-AA contrast measurement on the macOS sidebar selection /
    hover / disabled states in light / dark / increase-contrast
    modes. Source uses semantic colors that adapt; the sweep
    confirms the rendered output clears the AA threshold.

## Larger view-file decomposition

- **Status:** Partial (0.6.2) — carries to 0.6.3.
- **Driver:** AGENTS.md / repo 800-LOC view-file guideline.
- **0.6.2 progress:** macOS `RecordingsView` 1116 → 784 LOC via
  `RecordingPlayerSheet` extract. iOS `RecordingsView` 767 LOC,
  already under threshold. `AllRecordingsView` 1282 → 1120 LOC via
  the three trailing sub-views extract.
- **0.6.3 plan:** `AllRecordingsView` indexed-search panel cluster
  (~230 LOC) lifts into a dedicated view struct, which needs the
  snapshot-test safety net to land confidently. Brings the parent
  under 800 LOC.

## Privacy-zone editor cross-platform parity

- **Status:** Planned (0.7.0).
- **Note:** privacy zones currently edit on macOS; iOS has a thinner
  surface. 0.7.0 brings iOS to parity.

## Bulk multi-select export

- **Status:** Planned (0.7.0).
- **Driver:** follow-up to the 0.6.2 `ClipExporter` storyline. 0.6.2
  ships single-clip export through Files / Photos / drag-out; 0.7.0
  layers a multi-select picker on top so users can export a day's
  worth of clips in one action.

## User-customizable macOS keyboard shortcuts

- **Status:** Planned (0.7.0).
- **Note:** 0.6.1 added the Camera menu (⌘R, ⌘1–⌘9). 0.6.2 expands the
  standard set. 0.7.0 makes the bindings user-customizable via a
  Keyboard Shortcuts pane in Settings.

## Won't do

- **In-app telemetry** — Reolens has a hard "zero telemetry" rule
  ([AGENTS.md §5](../AGENTS.md)). Diagnostics stay local (`AppErrorRecorder`,
  `NotificationHistory`, `RelayDiagnostics`).
- **Cross-vendor camera support** — Reolens is opinionated about
  Reolink. Wide multi-vendor support would change the product surface.
- **Cloud relay servers operated by us** — Reolens has no servers and
  isn't planning any. The CloudKit relay rides the user's own iCloud
  account.
