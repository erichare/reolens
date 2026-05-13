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
  swift test                       # 158 tests, 43 suites at 0.5.0 baseline
  bash Scripts/check-versions.sh   # macOS + iOS marketing versions match (AGENTS.md §13)
  bash Scripts/coverage-gate.sh    # ≥ 80% coverage on AppShared + Reolink* (AGENTS.md §12)
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

### 0.5.0-specific verification

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
