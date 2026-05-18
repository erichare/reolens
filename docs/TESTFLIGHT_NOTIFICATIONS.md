# Enabling motion notifications on TestFlight iOS / iPadOS

Reolens has no Reolens server (AGENTS.md §5). Motion notifications on iPhone /
iPad reach you over Apple Push (APNS + CloudKit), but **a publisher device on
your home network has to be running** to feed those notifications into your
private iCloud database. Today, that publisher is the **macOS app**.

Once it's set up, your TestFlight iPhone gets banners anywhere — wifi or
cellular, miles from home.

## Architecture in one diagram

```
[Reolink camera on LAN]
        │  motion / AI event
        ▼
[macOS Reolens — publisher at home]
        │  CKRecord → your *private* iCloud DB
        ▼
[Apple CloudKit + APNS]
        │  silent push (any network the phone has)
        ▼
[TestFlight Reolens on iPhone / iPad — subscriber]
        │  wake → fetch record → post local notification
        ▼
🔔 banner
```

Everything runs inside your own iCloud account. Reolens has no server in the
loop and never sees your camera credentials or motion events.

## One-time setup

You need **all** of these:

1. **macOS Reolens installed from a GitHub Release DMG.** Local `swift run`
   builds and `Scripts/build-app.sh` ad-hoc builds intentionally drop the iCloud
   entitlement (macOS 26 AMFI requires a matching provisioning profile, which
   ad-hoc signing doesn't have). The release DMG is signed with Developer ID
   and carries the full entitlements.

   Verify your installed copy has CloudKit:

   ```sh
   codesign -d --entitlements - /Applications/Reolens.app 2>/dev/null \
     | grep -A1 icloud-services
   ```

   You should see `CloudKit` and `CloudDocuments` listed. If not, reinstall
   from the latest [GitHub Release](https://github.com/jestatsio/reolens/releases/latest).

2. **TestFlight Reolens on the iPhone / iPad.** No special setup; the iOS
   build ships with `aps-environment = production` and the
   `remote-notification` background mode.

3. **Both devices signed into the same iCloud account.** Different accounts =
   different private DBs = no relay.

4. **Both devices signed into the same iCloud account on the same Apple ID.**
   Family Sharing doesn't help here — CloudKit private DBs are per-Apple-ID.

## Enable the toggles

**On the Mac (publisher):**

- Open Reolens → Settings → **Motion Notifications**
- Turn **"Relay motion events to my other Apple devices"** ON
- Optional: hit the **"Send test event"** button to fire a synthetic event
  through the pipeline immediately

**On the iPhone / iPad (subscriber):**

- Open Reolens → Settings → **Motion Notifications**
- Turn **"Receive on this iPhone / iPad"** ON (default ON since 0.6.0, but
  worth confirming)
- Accept the system notification permission prompt on first launch (Reolens
  auto-prompts; if you missed it, iOS Settings → Reolens → Notifications →
  Allow)

That's it. Within a few seconds of a real motion event on the camera, you
should see a banner on the phone.

## Troubleshooting

If notifications aren't arriving:

- **Check both devices are signed into the same iCloud account**
  (Settings → \[your name\] on each device). Account hashes are recorded by
  the publisher; if the iCloud account differs from the last enrollment, the
  publisher refuses to push and logs `accountChanged` to the diagnostics
  screen. Re-enroll via the trust-changed modal that surfaces in Settings.

- **Check the relay diagnostics screen** on both devices
  (Settings → Motion Notifications → "Relay diagnostics"). It records:
  - whether the binary has the iCloud entitlement
  - whether APNS registration succeeded (iOS only)
  - the last few silent-push arrival times
  - publisher save outcomes (`saved`, `deduped`, `accountChanged`,
    `noEntitlement`, `rateLimitedSuppressed`, …)

- **The Mac has to be awake.** The publisher only runs while the Mac is
  online and Reolens is running (it can be in the background — does not need
  to be foreground). If you close Reolens or the Mac sleeps, no events get
  published until it wakes.

- **One camera at a time, by design.** The publisher relays motion events
  for every camera the Mac is connected to. Cameras the Mac hasn't connected
  to (e.g. a battery camera only the phone has paired with) won't generate
  relayed events.

- **Test event didn't arrive on the phone:**
  1. iOS notifications fully off? Settings → Reolens → Notifications.
  2. Per-tag muted? Settings → Motion Notifications → check each tag toggle.
  3. APNS registration failed? Open the relay diagnostics on iOS; the
     "APNS registered" row should show a recent timestamp and a non-zero
     token byte count.

- **Per-camera mute on the receiver.** Per-camera notification preferences
  sync via `NSUbiquitousKeyValueStore` across all your devices. If you
  muted a camera on the Mac, the iPhone honors that mute.

## Deploying schema changes (maintainer-only)

CloudKit stores two separate schemas per container — **Development**
and **Production** — and TestFlight / App Store / Developer-ID DMG
builds all run against Production. Development auto-creates record
types and fields the first time the app writes them; Production is
**locked** and never auto-creates anything. A release that adds a new
`MotionEvent` field will compile and run fine on dev builds but fail
silently on every release-signed device until the schema is promoted.

The on-device **Settings → Motion Notifications → Push diagnostics**
screen surfaces these failures: a red "Schema decode" row with text
like `Schema mismatch on 'channel' 3m ago` means Production is
missing a field. The macOS publisher row likewise turns red with a
`Did not find record type: MotionEvent` outcome when the record type
itself was never promoted.

To deploy:

1. One-time machine setup — save a CloudKit management token:

   ```sh
   xcrun cktool save-token --type management
   # paste a token from https://icloud.developer.apple.com/dashboard
   ```

2. Snapshot the current Development schema into the repo so the
   committed `.ckdb` file is the source of truth for future diffs:

   ```sh
   export CKTOOL_TEAM_ID=5M9UT7VQ8Q
   export CKTOOL_CONTAINER=iCloud.com.reolens.Reolens
   Scripts/deploy-cloudkit-schema.sh export
   git add CloudKit/MotionEvent.ckdb && git commit -m 'chore: snapshot CloudKit schema'
   ```

3. Promote Development → Production:

   ```sh
   Scripts/deploy-cloudkit-schema.sh promote
   ```

   The script prompts for `y/N` because the deploy is a one-way write
   to Production; recovery requires a counter-deploy.

4. Verify in the CloudKit Console (Schema → Record Types →
   `MotionEvent` → toggle Production) that all six fields are
   present: `cameraID` (String), `channel` (Int(64)), `detection`
   (String), `timestamp` (Date/Time), `snapshot` (Asset), and
   `cameraName` (String, optional — receivers fall back to
   "Channel <n+1>" if it's missing on a record). Then trigger a test
   motion event and watch the diagnostics row flip back to green
   within ~10s.

To check whether the live Development schema has drifted from the
committed file (e.g. a new field appeared from running a fresh build
against Dev) without overwriting the snapshot, run
`Scripts/deploy-cloudkit-schema.sh diff`.

### Adding a new field

CloudKit Development normally auto-creates fields the first time the
app writes them. But Reolens has no Mac binary that publishes to Dev:
the release DMG hits Production, and ad-hoc-signed local builds drop
the iCloud entitlement entirely (see `App/Reolens.dev.entitlements`).
So adding a field requires either the Console or `cktool`:

**Console (easiest):**
1. <https://icloud.developer.apple.com> → container → environment toggle
   to **Development**.
2. Schema → Record Types → `MotionEvent` → Add Field → name + type → Save.
3. Schema → Deploy Schema Changes → Development → Production → Deploy.

**`cktool` (reproducible):**
1. `Scripts/deploy-cloudkit-schema.sh export` — pull current Dev to
   `CloudKit/MotionEvent.ckdb`.
2. Edit the file to add the new field. The format is human-readable;
   model the new line on the existing field entries.
3. `Scripts/deploy-cloudkit-schema.sh push` — import the edited file
   back to Dev.
4. `Scripts/deploy-cloudkit-schema.sh promote` — Dev → Production.

## What this setup does **not** give you

- **Notifications without a Mac at home.** There's no iOS-only path today.
  An always-on iPad-at-home publisher is on the roadmap but would need new
  code and is not shipping yet.
- **Faster-than-CloudKit latency.** Silent pushes typically arrive within a
  few seconds, but Apple makes no guarantee. Critical alerting workflows
  should not depend on this.
- **End-to-end audio / video.** The relay only carries event metadata + an
  optional snapshot JPEG. Tapping a notification opens the iOS app and pulls
  live video from the camera if reachable.
