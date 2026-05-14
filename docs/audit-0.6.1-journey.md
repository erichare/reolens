# 0.6.1 Pre-Release Journey Checklist

Manual click-through that has to happen before tagging 0.6.1.
Generate from the 0.6.0 verification checklist and add 0.6.1
deltas. Capture screenshots into `docs/screenshots/0.6.1/` as you go.

## macOS — full journey sweep

Recommended hardware: any Apple Silicon Mac on macOS 26.

- [ ] **Cold launch.** No console errors filtered to
  `subsystem:com.reolens.*`.
- [ ] **Add a camera.** Verify the add-sheet validates input; password
  lands in Keychain (not UserDefaults).
- [ ] **Live grid.** Adaptive, spotlight, and a fixed preset (e.g.
  2×2). Verify the badge OSD position matches user setting.
- [ ] **Single camera detail.** PTZ controls respond. Talkback button
  visible on supported cameras. **A11y:** turn on VoiceOver and
  rotor-navigate the PTZ controls — labels read "Pan up", "Zoom in",
  etc. (0.6.1 WS8.)
- [ ] **Recordings tab.** Per-day timeline, AI ticks, playback scrubs.
- [ ] **All Recordings.** Cross-day list, cross-camera mix, filters.
- [ ] **NL Search (0.6.1 polish).**
  - Search field accepts input.
  - Empty-result state shows the "Try" suggestions + privacy footer.
  - After at least one successful search, "Recent" history appears
    above suggestions.
  - Tap a result row → list returns to the hit's day.
  - Tap "Clear" on Recent → history empties; rows disappear.
- [ ] **Schedule editor (recording + motion).** Open from per-channel
  Settings. Edit + save round-trips. On `-9 notSupport` firmware, the
  read-only banner shows. **A11y:** VoiceOver on a grid cell announces
  weekday + hour + on/off state (0.6.1 WS8).
- [ ] **Notifications.**
  - System permission row reflects current state.
  - Notification Log opens, scrolls, shows per-status filters.
  - Notification Diagnostics screen renders all rows green or
    explains failures.
  - Overnight digest preview button works.
- [ ] **Settings redesign (0.6.1 WS3).**
  - Open Settings (⌘,).
  - Verify the new tabs are Cameras / Notifications / Background /
    Privacy & Sync / Advanced / About (was: General / Notifications
    / Privacy / Developer / About).
  - **Diagnostics Center** — open from Advanced. Empty list shows
    the "No errors recorded" content unavailable view. Trigger
    a failure (e.g. add a camera with a wrong password) and verify
    the row appears with category icon, user message, and detail.
- [ ] **Camera menu (0.6.1 WS11-A).**
  - "Refresh Live Tiles" (⌘R) sweeps every tile.
  - ⌘1 through ⌘9 jump to the first 9 cameras (bounds-checked
    against the actual list).
- [ ] **Menu-bar mode + Launch at Login.** Toggle on, close window,
  verify the icon stays. Restart Mac → app launches into menu-bar.
  Toggle off → app quits cleanly.
- [ ] **Widget rendering.** Add a desktop widget; verify it shows
  the latest snapshot.
- [ ] **About panel.** Version reads `0.6.1`, build `16`.

## iOS / iPadOS — iPhone simulator + iPad simulator

Recommended simulators: iPhone 15 Pro + iPad Pro 13-inch on iOS 26.

- [ ] **Cold launch on iPhone.** Verify the last-viewed camera
  restores (0.6.0 carry-over).
- [ ] **Tab navigation.** Live / Recordings / Devices / Settings —
  no orphaned spinners, no console errors.
- [ ] **iPad split shell.** Two-column NavigationSplitView; sidebar
  selection drives detail without stale state.
- [ ] **Live + recordings paths.** Same checks as macOS.
- [ ] **NL Search (0.6.1 polish).** Same checks as macOS.
- [ ] **Schedule editor.** Same checks; grid a11y verified.
- [ ] **Settings redesign (0.6.1 WS3).**
  - New IA: Cameras → Notifications & Events → Display → Background
    & Storage → Privacy & Sync → Advanced → About.
  - Diagnostics Center accessible from Advanced; navigation pushes
    correctly (no orphaned back arrow).
  - HomeKit section renders only on iOS, with the new MFi explainer
    if Apple Intelligence is available.
- [ ] **A11y pass.** Turn on VoiceOver. Rotor through PTZ + schedule
  grid + notification rows.
- [ ] **Notifications.** Permission request flow distinguishes
  user-denied from system-errored (0.6.1 WS7b) — observe via
  Diagnostics Center.

## Sign-off

Once every box is checked and screenshots are captured, drop a
sentence in `CHANGELOG.md` under `## [0.6.1]` confirming the journey
sweep passed, tag the release, and follow `docs/RELEASE.md` (macOS)
+ `docs/IOS_RELEASE.md` (iOS).
