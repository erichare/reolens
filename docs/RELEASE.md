# Release runbook

How to ship a new version of Reolens. Total time once everything is set
up: about 10 minutes of human attention plus 5–10 minutes of CI build.

## One-time setup (per-machine)

You only do this the first time you cut a release from a machine.

### 1. Sparkle EdDSA keypair

Generate the keypair Sparkle uses to sign update archives. Keep the
private key in your keychain — never commit it.

```sh
# Download Sparkle's CLI tools (only the tarball needed; doesn't need to
# match the version we link in Package.swift exactly).
curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz -o /tmp/sparkle.tar.xz
tar -xJf /tmp/sparkle.tar.xz -C /tmp/
/tmp/bin/generate_keys
```

`generate_keys` prints the public key to stdout and stores the private
key in your login keychain. Copy the public key into `App/Info.plist`
(`SUPublicEDKey`), and copy it into the `SPARKLE_PUBLIC_KEY` GitHub
secret.

For the private key, base64-encode it and store it in the
`SPARKLE_ED_PRIVATE_KEY` GitHub secret:

```sh
/tmp/bin/generate_keys -p | base64 | pbcopy
```

(Then paste into the secret.)

### 2. App Store Connect API key (for notarization)

In App Store Connect → Users and Access → Keys, create a key with the
"Developer" role. Download the `.p8`. Note the Key ID and Issuer ID.
Store these as GitHub secrets:

- `AC_API_KEY_ID`
- `AC_API_ISSUER_ID`
- `AC_API_KEY_P8_BASE64` (the `.p8` contents, base64-encoded)

### 3. Developer ID code-signing cert

Export your "Developer ID Application" certificate from Keychain.app as
a `.p12`. Pick a password. Then:

```sh
base64 -i Reolens-DevID.p12 | pbcopy
```

Store as GitHub secrets:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD` (any random string — used for the temporary CI keychain)

And as repo variables (Settings → Variables):

- `SIGNING_IDENTITY` (e.g. `Developer ID Application: Eric Hare (TEAM12345)`)
- `TEAM_ID` (e.g. `TEAM12345`)

### 4. Homebrew tap

Create `jestatsio/homebrew-reolens` on GitHub. Copy
`dist/homebrew/reolens.rb` into `Casks/reolens.rb` of the tap repo.
After each release, update `version` and `sha256` in that file.

### 5. DNS for reolens.io → GitHub Pages

In your DNS provider, point `reolens.io` at GitHub Pages:

- `A` records on the apex pointing to `185.199.108.153`, `185.199.109.153`,
  `185.199.110.153`, `185.199.111.153`
- `CNAME www → erichare.github.io`

In repo Settings → Pages: source = `main`, folder = `/docs`, custom
domain = `reolens.io`, enforce HTTPS.

## Per-release checklist

Each new version, walk this list. It takes about 10 minutes.

### Pre-flight

- [ ] **Tests green on `main`** — check the [CI badge](https://github.com/jestatsio/reolens/actions/workflows/ci.yml). Local sanity:
  ```sh
  swift test                       # 361 tests, 71 suites at 0.6.1 baseline
  bash Scripts/check-versions.sh   # macOS + iOS marketing versions match (AGENTS.md §13)
  bash Scripts/coverage-gate.sh    # baselines in Scripts/coverage-baselines.txt; long-term goal 80% (AGENTS.md §12)
  ```
- [ ] **Smoke launch passes** locally:
  ```sh
  ./Scripts/build-app.sh && ./Reolens.app/Contents/MacOS/Reolens --smoke-test
  ```
- [ ] **Bump version in BOTH platforms** — `App/Info.plist`
  (`CFBundleShortVersionString` and `CFBundleVersion`) AND
  `AppiOS/project.yml` (`MARKETING_VERSION`). `check-versions.sh`
  blocks the build if they diverge.
- [ ] **Update CHANGELOG.md** — move items from `[Unreleased]` into the
  new version section; update the diff link at the bottom
- [ ] **Refresh screenshots** in `docs/screenshots/` if the UI changed.
  Run `./Scripts/blur-screenshot.sh` over any frames showing real
  camera footage
- [ ] **Regenerate the iOS Xcode project** if `AppiOS/project.yml` or
  any source under `AppiOS/Widgets/` / `AppiOS/Sources/LiveActivities/`
  changed:
  ```sh
  cd AppiOS && xcodegen generate
  ```
- [ ] **Commit the bumps** as a single `chore(release): vX.Y.Z` commit

### 0.6.2-specific verification

Walk these on macOS and on iPhone + iPad simulators (iOS 26) before
tagging. The 0.6.2 storyline is `ClipExporter`, so the export routes
get the lion's share of the manual coverage.

- [ ] **Clip export to Photos (iOS / iPadOS)** — bookmark or open a
  recording, choose Export → Save to Photos. Confirm the clip lands
  in the Photos library with the expected duration and that the
  first Photos-permission prompt is the system one (not a Reolens
  custom modal).
- [ ] **Clip export to Files / share-sheet (both platforms)** — same
  source clip, Export → share-sheet. Save to iCloud Drive / a local
  folder; confirm the file opens in QuickTime / Files with the
  expected duration.
- [ ] **macOS Finder drag-out** — drag a bookmark row out of the
  Bookmarks sheet onto the Finder; the dropped file opens cleanly.
- [ ] **Diagnostics bundle export** — Settings → Advanced →
  Diagnostics → Export. The redacted bundle reaches Files /
  share-sheet with the same header + ISO8601 + category + detail
  shape the 0.6.1 copy-to-clipboard path produced.
- [ ] **NL Search regex fallback** — on a non-AI-eligible device (or
  with Apple Intelligence disabled), type the newly-supported
  synonym phrases; results should match. Run on an AI-eligible
  device too to confirm the FoundationModels path still wins.
- [ ] **macOS keyboard shortcuts (expanded)** — verify the
  newly-added shortcuts fire from the Camera / View menus. The
  existing ⌘R and ⌘1–⌘9 from 0.6.1 still work.
- [ ] **TTFF improvement** — open Instruments with the os_signpost
  instrument on `com.reolens.streaming` / `TTFF`, do a cold-start
  live view, capture the interval. Record the number; it should
  improve against the 0.6.1 baseline in `docs/perf-baselines/`.
- [ ] **Accessibility — Dynamic Type on player chrome** — bump
  content size to AX5 in Settings → Accessibility. Open a live view
  and a recording; chrome adapts without clipping.
- [ ] **Accessibility — focus order on `RecordingsView`** — with
  VoiceOver on iOS and Full Keyboard Access on macOS, tab through
  the screen. Order: day picker → filter chips → list.
- [ ] **Accessibility — scrubber VoiceOver** — focus the recording
  scrubber thumb; it announces position + duration. The rail
  announces total duration.
- [ ] **Accessibility — macOS sidebar contrast** — toggle between
  light / dark / increase-contrast modes. Selection, hover, and
  disabled states stay legible.
- [ ] **Decomposed views render unchanged** — open
  `AllRecordingsView`, macOS `RecordingsView`, iOS `RecordingsView`
  and confirm no visual regressions vs. the 0.6.1 build. Snapshot
  suite is the primary guard; this is the visual spot-check.
- [ ] **Reorganized-Settings flag removed** — confirm the legacy
  Settings layout is gone and there's no longer a way to flip back
  to it via `defaults write com.reolens.useReorganizedSettings false`.
- [ ] **HomeKit prep flag dark** — confirm
  `HomeKitBridge.fullIntegrationEnabled` is `false` in the shipped
  binary; the existing scaffolded surface in
  Settings → Privacy & Sync → HomeKit (iOS) still shows the MFi
  explainer rather than attempting registration.
- [ ] **CI gates** — confirm the coverage regression gate is a
  required check on `main` in repo Settings → Branches (enforced
  since 0.6.0). The iOS build job stays informational this cycle
  pending the runner-image fix tracked in docs/ROADMAP.md.

### 0.6.1-specific verification

Run the full journey checklist at
[docs/audit-0.6.1-journey.md](audit-0.6.1-journey.md) on macOS and on
iPhone + iPad simulators (iOS 26). Highlights to spot-check:

- [ ] **Settings redesign** — 7 buckets across both platforms. The
  0.6.1 emergency-revert flag (`useReorganizedSettings`) was deleted
  in 0.6.2 along with the legacy layout; there's only the new IA now.
- [ ] **Diagnostics Center** — Settings → Advanced → opens; clear
  button works; copy-to-clipboard emits the redacted bundle format
  (header line + ISO8601 timestamp + category + detail).
- [ ] **NL Search** — search field on All Recordings is reachable; a
  successful query stores in Recent; "Clear" wipes Recent.
- [ ] **macOS keyboard shortcuts** — ⌘R refreshes tiles; ⌘1–⌘9 switch
  cameras; out-of-range indices are no-ops.
- [ ] **PTZ + schedule-grid VoiceOver labels** — VoiceOver announces
  "Pan up" / "Zoom in" / day-hour-state on each cell.
- [ ] **Battery wake / permission request paths** — verify a forced
  failure shows up in Diagnostics Center with the right category.

### 0.6.0-specific verification (still applies)

- [ ] **Notification Diagnostics screen** renders all rows green or
  explains failures.
- [ ] **Notification log** captures outcomes and deep-links to the
  matching recording on tap.
- [ ] **Cross-day NL Search** — both the FoundationModels path
  (Apple Intelligence devices) and the deterministic regex fallback.
- [ ] **Recording schedule editor** round-trips via `GetRec` /
  `SetRec`; `-9 notSupport` firmware degrades to read-only.
- [ ] **Motion schedule + per-AI-tag overrides** save correctly.
- [ ] **Battery camera auto-wake** on single-camera detail-view appear.
- [ ] **Last-camera-on-launch** restores on iOS / iPadOS.
- [ ] **BookmarkAutoDownloader.reconcile** re-enqueues missing clips.
- [ ] **Bookmark delete** removes both entry + local file.
- [ ] **XCUITest harness** passes on iPhone simulator.
- [ ] **HomeKit section** renders on iOS only.

### 0.5.1-specific verification

The 0.5.1 release surface added the cross-hub All Recordings view,
per-camera notifications, pre-view bookmarking with background
auto-download (Wi-Fi by default + cellular toggle), the
FoundationModels Today digest, two new App Intents, and a hub-grouped
Live Activity rewrite with push-token registration. Walk this list
before tagging:

- [ ] **Sidebar click targets (macOS + iPadOS).** Click far-right
  whitespace of every camera row; selects + jumps to Live.
  Channel sub-rows under a hub do the same.
- [ ] **iPad detail-pane refresh.** Switch from Cam A → Cam B in the
  sidebar; right column updates within ~1 s. Re-select Cam A;
  still rebuilds cleanly (force-reset is intentional).
- [ ] **Camera-name badge default.** Fresh install with no
  per-channel overrides: every live tile shows no name badge.
  Settings → Display → "Show camera name on live feed" restores
  it; flipping back hides again.
- [ ] **Battery camera one-tap wake.** Tap a sleeping battery tile;
  "Waking…" spinner appears, RTSP starts within ~5 s. Double-tap
  is debounced (no second wake).
- [ ] **Hub auto-expand + iCloud sync.** Add a fresh hub on Mac;
  channels visible immediately under it. Collapse on Mac; iPad
  reflects within ~30 s. Sign out of iCloud on a third device;
  local UserDefaults fallback keeps the app working.
- [ ] **All Recordings view (hub-scoped).** Open the macOS toolbar
  "All Recordings" button on a multi-channel hub; ≤3 s to load
  an 8-channel NVR's day. Camera pill narrows; AI pill stacks
  (AND).
- [ ] **All Recordings (cross-hub).** With ≥ 2 hubs configured,
  open the same sheet; chips prefix the hub display name so
  same-named cameras stay distinguishable. Bounded fan-out caps
  network at ~6 in-flight requests.
- [ ] **Today digest.** With Apple Intelligence available, the
  digest at the top of All Recordings reads as FM-generated
  (sparkles icon). On a non-AI device or with Apple Intelligence
  disabled, falls back to "N clips today: …" (chart icon).
- [ ] **Per-camera notifications.** Settings → Notifications →
  Per-camera shows every camera with a toggle, default ON.
  Flip one off on Mac; iPad reflects within ~30 s. Motion event
  on the muted camera does NOT produce a notification.
- [ ] **Pre-view bookmark (iOS).** Long-press a recording row →
  Bookmark; row's bookmark appears in the Bookmarks sheet without
  the clip having been played. Trailing-swipe also works.
- [ ] **Background bookmark download.** Bookmark a clip; check
  `~/Library/Application Support/Reolens/bookmarks/<id>.mp4`
  appears after the background download finishes. Background
  the app for 5 minutes; the clip still finishes downloading.
- [ ] **Cellular toggle.** Default OFF. With cellular off and
  Wi-Fi disabled, bookmark a clip; URLSession waits for Wi-Fi
  rather than burning cellular. Flip the toggle on; next enqueue
  proceeds on cellular.
- [ ] **App Intents — Open Camera, Show Today's Events, Mute.**
  Use Spotlight / Siri to fire each. "Hey Siri, mute the
  Driveway camera" silences it; "Hey Siri, show today's events
  from Front Door" lands in the filtered All Recordings.
- [ ] **Hub-grouped Live Activity.** Trigger motion on channel 0
  of a Hub; activity appears. Trigger motion on channel 1 of the
  same Hub; the existing activity *updates* (no second activity
  appears in Dynamic Island). `coalescedCount` bumps. Stale
  date is now 8 h from start (was 4 h in 0.5.0).
- [ ] **Live Activity push tokens.** After triggering an activity,
  inspect the iCloud Drive
  `Documents/live-activity-tokens/live-activity-tokens_v1.json`
  file — entry exists with `activityID`, `cameraID`,
  `pushTokenHex`. Ending the activity removes the entry.

### 0.5.0-specific verification (still applies)

The 0.5.0 release surface added widgets, Live Activities, and
multi-window scenes. Walk this verification list before tagging:

- [ ] **App Group container** — confirm `group.com.reolens.Reolens`
  is in both `App/Reolens.entitlements` and `AppiOS/Resources/ReolensiOS.entitlements`.
  Widgets / extensions inherit it from their own entitlements files.
- [ ] **macOS desktop widgets** — appear in the widget gallery under
  "Reolens"; CameraSnapshot renders with placeholder + real data once
  a session has run.
- [ ] **iOS Home Screen widgets** — add small / medium / large
  `CameraSnapshotWidget` variants; each renders the latest snapshot.
- [ ] **iOS Lock Screen widgets** — `LastMotionWidget` in each of
  inline / circular / rectangular families.
- [ ] **iOS Control Center widget** — `OpenCameraControlWidget` tap
  opens the chosen camera within ~1 s cold-start.
- [ ] **iOS Live Activity** — trigger a motion event; activity appears
  in Dynamic Island compact + expanded states. A second event on the
  same camera replaces (does not stack). Auto-dismiss at 4 h verified
  via `Activity.activityState` mock or wall-clock wait.
- [ ] **Stage Manager (iPad)** — drag two camera scenes side-by-side;
  each has independent state.
- [ ] **macOS multi-window** — right-click camera in sidebar → "Open in
  New Window" produces a separate scene with its own state.
- [ ] **Recording scrubber** — thumbnail rail populates within ~5 s of
  opening a clip; drag cursor updates `currentTime`; cache directory
  size respects the 500 MB LRU cap.
- [ ] **Clip bookmark + export** — right-click a recording → Bookmark
  this clip; in the Bookmarks sheet, Export → save MP4; verify the
  file opens in QuickTime / Files with the expected duration.
- [ ] **Privacy zones** — draw a zone, save; refresh the editor and
  confirm the zones round-trip. If the firmware supports `SetMask`
  the rectangles mask the live video; otherwise the "saved on this
  device" notice appears.
- [ ] **Overnight digest** — trigger via Settings → "Build a digest
  now"; preview the resulting digest sheet; confirm a one-shot
  notification fires with the correct count.
- [ ] **Hardening regression** — feed a zero-length SPS / PPS NAL,
  malformed `AVAudioFormat` config, and a 100-events-in-5-minutes
  motion burst. App does not crash; CloudKit relay publishes ≤ 30
  events + 1 burst-summary record.
- [ ] **Logging redaction sweep** — run a full session, grep
  `Console.app` archives for `password=`, `token=`, RTSP URLs with
  `user:pass@`; nothing leaks.

### Cut the release

```sh
git tag vX.Y.Z
git push origin main vX.Y.Z
```

This triggers `.github/workflows/release.yml`, which:

1. Builds the .app with Developer ID signing (with the real
   `SUPublicEDKey` injected from secrets)
2. Submits to Apple notary, staples
3. Builds a signed DMG, notarizes + staples it
4. Signs the DMG with your Sparkle EdDSA private key
5. Regenerates `docs/appcast.xml` with the new entry
6. Commits the appcast back to `main`
7. Creates a GitHub Release with the DMG + sha256

### Post-release

- [ ] **Smoke install** — on a clean Mac (or a new user account):
  ```sh
  curl -L https://github.com/jestatsio/reolens/releases/latest/download/Reolens.dmg \
    -o /tmp/Reolens.dmg
  xcrun stapler validate /tmp/Reolens.dmg     # should print "Validation: success"
  open /tmp/Reolens.dmg
  ```
  Drag to Applications, launch — should open with no Gatekeeper warning
- [ ] **Update Homebrew cask**:
  ```sh
  cd ../homebrew-reolens
  # Edit Casks/reolens.rb: bump version, update sha256 from the release page
  git commit -am "reolens vX.Y.Z"
  git push
  brew update && brew install --cask jestatsio/reolens/reolens
  ```
- [ ] **Verify auto-update path** — install the previous version on a
  test Mac, launch it, choose Reolens → Check for Updates… and confirm
  Sparkle offers and applies the new version
- [ ] **Verify the landing page** — `https://reolens.io` renders with
  the new version number and Download button works
- [ ] **Announce** — issue tracker, any user-facing channels

## Rolling back

If a release is broken:

1. **Yank the GitHub Release** so the appcast permalink no longer
   resolves: edit the release in the GitHub UI → "Delete this release"
2. **Re-publish a previous good DMG** as the latest release
3. **Manually edit `docs/appcast.xml`** to point Sparkle back at the
   prior version, commit, push — within the next polling interval
   (~24h) clients on the bad version will be offered the rollback
4. **Tag a `v.X.Y.Z+1` patch** with the actual fix and run the normal
   release flow on top of that

Sparkle won't downgrade users — they're stuck on the bad version until
they re-download the previous DMG manually, OR you ship a higher version
number with a fix. Cutting a `+1` patch is almost always the right call.
