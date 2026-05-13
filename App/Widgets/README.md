# Reolens macOS Widgets

0.5.0 Theme A1 (macOS twin) — desktop WidgetKit extension.

## Contents

- `ReolensWidgetsBundle.swift` — `@main WidgetBundle` registering the three widget kinds
- `CameraSnapshotWidget.swift` — last cached snapshot for a configurable camera (small / medium / large)
- `LastMotionWidget.swift` — which camera fired most recently (small / medium / large; the iOS-only accessory families are stripped on macOS automatically)
- `MotionDigestWidget.swift` — overnight digest summary (medium / large)
- `SelectCameraIntent.swift` — `AppIntent` that lets the user pick which camera the snapshot widget shows
- `Info.plist` — extension Info.plist (WidgetKit extension point)
- `ReolensWidgets.entitlements` — App-Group + sandbox

The Live Activity widget and Control Center widget are **iOS-only**
(AGENTS.md §1 carve-out). They live under `AppiOS/Widgets/`.

## Wiring it up

The macOS app doesn't yet have an xcodegen project; the widget
extension target must be added to the manually-managed Xcode
project (or the eventual `project.yml`) as:

```yaml
ReolensWidgets:
  type: app-extension
  platform: macOS
  deploymentTarget: "26.0"
  sources:
    - App/Widgets
  dependencies:
    - target: AppShared
  settings:
    base:
      INFOPLIST_FILE: App/Widgets/Info.plist
      CODE_SIGN_ENTITLEMENTS: App/Widgets/ReolensWidgets.entitlements
      PRODUCT_BUNDLE_IDENTIFIER: com.reolens.Reolens.ReolensWidgets
```

Both the main app target and this extension target must have the
**App-Groups** entitlement listing `group.com.reolens.Reolens`.
The main app already does (see `App/Reolens.entitlements`).

## Data flow

All three widgets read from the App-Group container at
`group.com.reolens.Reolens`:

- `LatestSnapshots.plist` — written by `CameraPreviewService.storeFromLiveAndPublishToWidget(...)` after every live keyframe
- `RecentMotionEvents.plist` — written by `EventNotifier.publishToWidgetContainer(...)` on every motion fire
- `digests/<yyyy-MM-dd>.json` — written by `DigestScheduler.runDigest(...)`

No widget code performs network requests, reads Keychain, or
touches CloudKit. AGENTS.md §16.
