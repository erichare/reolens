# AppWatch — Reolens companion watchOS library

Minimal source-of-truth for the Reolens watchOS app. The watch app is
intentionally thin: it consumes the App Group container that the iOS
app's widget pipeline already publishes (`LatestSnapshots.plist`,
snapshot JPEGs, `RecentMotionEvents.plist`) and renders a flat camera
list, a polled "live" snapshot view, and a 24-hour recordings digest.

Rich notifications work automatically — iOS auto-forwards every
`UNUserNotificationCenter` notification to the paired watch, including
the snapshot attachment.

## Architecture (v1)

```
                                                       paired Watch
iPhone (Reolens app)                                      ┌───────────────┐
  EventNotifier ──► UNNotificationCenter ──[auto]────────►│ system banner │
                                                          └───────────────┘
  Widget pipeline ──► SharedContainer ──► App Group       ┌───────────────┐
                                       (group.com…)──────►│ Watch reads   │
                                                          │ via mirror in │
                                                          │ this library  │
                                                          └───────────────┘
```

The watch never talks to the camera directly in v1. Truly-live polling
and a credentials-backed recordings search are sketched out below as a
v2 — both need cross-target Keychain Sharing (or Watch Connectivity)
that's out of scope for the initial cut.

## Setting up the Xcode target

The SPM library is wired in [Package.swift](../../Package.swift) under the
`AppWatch` product. The companion Xcode target needs to be created in
[ReolensiOS.xcodeproj](../../AppiOS/ReolensiOS.xcodeproj) — Xcode's
`File > New > Target > watchOS > Watch App` wizard is the right path.

1. **Bundle Identifier:** `com.reolens.Reolens.watchkitapp`
2. **Minimum Deployment:** watchOS 11.0
3. **Embed in:** ReolensiOS (paired companion).
4. **App Group entitlement:** `group.com.reolens.Reolens` — same
   group ID the iOS target already declares. Without this entitlement
   `WatchSharedContainer.containerURL` returns `nil` and the watch
   shows "No cameras yet" forever.
5. **Package Dependencies:** add the `AppWatch` library product from
   the local Swift package.
6. **Create `WatchApp.swift` in the target** with:

   ```swift
   import SwiftUI
   import AppWatch

   @main
   struct ReolensWatchApp: App {
       var body: some Scene {
           WindowGroup {
               WatchRootView()
           }
       }
   }
   ```

That's it for v1.

## What's intentionally NOT in v1

Documenting these so the path back to them is clear:

- **Direct-from-watch live polling.** Would let the watch refresh the
  snapshot independent of the iPhone. Needs Keychain Sharing (a
  shared access group on the iOS Keychain entries) so the watch can
  read passwords. The right plumbing is a Keychain access group on
  `com.reolens.cameraPassword` + matching `keychain-access-groups`
  entitlement on both targets. Migration: rewrite existing items into
  the new access group on first launch.
- **Cross-camera recordings list via `cmd=Search`.** Same credential
  story. Until then, the watch shows the iPhone's locally-cached
  `RecentMotionEvents.plist` (capped at 50 entries by
  `SharedContainer.appendMotionEvent`).
- **Recording playback on watch.** WatchOS can play short MP4 clips
  via AVPlayer, but at 41/45/49mm the UX is rough. v1 surfaces metadata
  only; users hand off to iPhone for playback.
- **Watch Connectivity.** Not used in v1 — the App Group + auto-
  forwarded notifications cover the read-only experience. A WCSession
  proxy ("ask iPhone to fetch a fresh snapshot") becomes valuable
  once we want true-live polling without exposing credentials to the
  watch.
- **Complications.** Out of scope; same `SharedContainer` data
  source would feed a watchOS 11 widget extension as v1.5.

## Files

- `WatchSharedContainer.swift` — slim Codable mirrors of
  `SharedContainer.LatestSnapshot` and `RecentMotionEvent` plus a
  read-only facade. Field layout MUST match the iOS source of truth
  in `Sources/AppShared/SharedContainer.swift` — drift causes silent
  decode failures.
- `WatchRootView.swift` — `@main`-facing scene entry point.
- `WatchCameraListView.swift` — flat list of `LatestSnapshot` rows,
  each with thumbnail + camera name + last-motion relative timestamp.
- `WatchLiveView.swift` — 2-second snapshot poll for one camera,
  auto-pauses on wrist-down via `.task(id: scenePhase)`.
- `WatchRecordingsView.swift` — last-24-h motion event list.

## Maintenance notes

- If `SharedContainer.LatestSnapshot` or `RecentMotionEvent` changes
  shape, mirror the change in `WatchSharedContainer.swift` and bump
  the encoder/decoder version comment. The decode path treats
  failures as empty data — symptom of drift is "the watch never shows
  any cameras even after opening Reolens on iPhone".
- `groupIdentifier` is hard-coded to match the iOS app's entitlement.
  If the App Group ID ever changes, both this file AND the iOS
  entitlements need to be updated together.
