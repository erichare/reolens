# AGENTS.md — Reolens engineering principles

This file is the source of truth for how to work on Reolens. It applies to humans and to agentic coding tools (Claude Code, Codex, Cursor, etc.) — both should read it before making changes.

Reolens is a Reolink camera client for macOS, iPadOS, and iOS. It streams live video over RTSP from cameras the user owns, exposes recordings and PTZ, and syncs the camera list across the user's own Apple devices via iCloud Drive.

The product is small, opinionated, and trust-sensitive. People install it because they want a clean, native, ad-free way to look at their own cameras. Every change should reinforce that.

---

## 1. Platform parity is the default

Any user-visible feature shipped on one Apple platform must work on the others. macOS, iPadOS, and iPhone are not tiers — they are equal targets. If a feature is genuinely platform-only (e.g. Sparkle auto-update, which is macOS-only because iOS uses TestFlight/App Store), it must be a documented carve-out with rationale in the relevant view/file's header comment.

When you add a feature, ship it everywhere or open a tracking issue for the missing platform in the same PR.

## 2. Native libraries on each platform

Don't bridge `NSView` into iOS or `UIView` into macOS. Don't import AppKit on iOS or UIKit on macOS. The established pattern is:

- One SwiftUI surface in shared code.
- Two thin platform adapters (`NSViewRepresentable` for macOS, `UIViewRepresentable` for iOS) when SwiftUI alone isn't enough.
- A shared model below the adapters.

See `Sources/ReolinkStreaming/Player/LiveVideoView.swift` for the canonical example. The whole UI layer currently has only ~5 `#if os(...)` blocks. Keep that count low. If you find yourself reaching for a conditional compile, first try: protocol-driven split, environment-driven branching, or moving the platform-specific code behind a thin representable.

## 3. Cameras are sensitive

Treat every change as touching live video feeds, authentication, and the user's home network.

- Any PR that modifies authentication, RTSP, credential storage, or networking must explicitly call out the security implications in its description.
- Run the `security-reviewer` agent before any release tag.
- Never log credentials, hostnames, or auth tokens at any level (`info`, `debug`, `verbose`).
- Never include credentials in crash reports, error messages shown to the user, or diagnostic exports.

## 4. Credentials are device-local

Passwords live in `Keychain` with `kSecAttrAccessibleWhenUnlocked`. They **do not** sync across devices. This is by design.

The camera list (`cameras.json`) **does** sync via iCloud Drive (see `Sources/AppShared/ICloudCameraStorage.swift`). Camera metadata — host, port, username, display name, grid layout, channel order — is synced. Passwords are not.

Don't blur this line:

- Never write a password to `UserDefaults`, `cameras.json`, or any other persisted store.
- Never write a password to a log.
- If a future feature needs cross-device credentials, that's an **explicit user-facing opt-in to iCloud Keychain**, not a silent change. Surface the trade-off in the UI.

## 5. Privacy

- No third-party analytics. None.
- No remote crash reporting that captures screen contents, network payloads, or PII.
- The app must function fully without any network call to non-Reolink hosts. The only exceptions are the Sparkle appcast (macOS auto-update) and Apple's own services (iCloud, TestFlight, App Store).
- No telemetry pings. No A/B testing infrastructure. No silent background fetches to our servers — there are no "our servers."

If you find yourself wanting to add a network call, ask whether it can be avoided. If it cannot, document why in the PR.

## 6. Shared logic lives in `AppShared`

The `AppShared` library target holds all state management, persistence, networking, domain models, and cross-platform business logic. UI may diverge per platform. Logic must not.

If you find yourself about to write the same function twice (once in `App/`, once in `AppiOS/`), stop and put it in `AppShared` instead. The Sources/ libraries are the right shape — `ReolinkAPI`, `ReolinkStreaming`, `ReolinkBaichuan`, `AppShared` — extend them rather than duplicating.

## 7. Backward-compatible sync schema

`cameras.json` is read by every Reolens install signed in to the same iCloud account, including older versions that haven't updated yet. Schema changes must be:

- **Forward-compatible reading**: older apps must tolerate unknown fields (Swift's `Codable` does this by default — don't break it with custom decoders).
- **Backward-compatible writing**: new versions must continue to populate any field older versions require, or the user's other devices will misbehave.
- **Migrated, not mutated**: when an existing field's semantics change, version the field name (e.g. `order_v2`) rather than overloading the old one.

When you bump the schema, write the migration in the PR description.

## 8. Swift 6 concurrency

- Use actors for shared mutable state.
- Mark cross-isolation types `Sendable`.
- Use structured concurrency (`async let`, `TaskGroup`) over unstructured `Task {}` when possible.
- Don't write `DispatchQueue.main.async` in new code. Use `@MainActor` annotations or `MainActor.run { }`.

## 9. Accessibility

- Every interactive element has a VoiceOver label.
- All text supports Dynamic Type. No hardcoded `.font(.system(size: 14))`-style absolutes for body text.
- No information conveyed by color alone — pair color with icon, label, or text weight.
- Gestures must have a non-gesture alternative. If long-press enters reorder mode, there's also a toolbar button. If drag reorders, there's also a Move Up / Move Down menu item.
- Respect `@Environment(\.accessibilityReduceMotion)` — replace bouncy/jiggle animations with static cues when it's true.

## 10. Performance

- Default to the sub-stream in grids; only main-stream when a tile is focused or expanded to single view.
- Never decode more streams than visible tiles. Pause off-screen streams.
- Be conservative on thermal/battery — RTSP decode is expensive. On iOS, surface `ProcessInfo.processInfo.thermalState` if we ever throttle.
- Profile before optimizing. Measure with Instruments, not vibes.

## 11. Logging

- `os.Logger` only. No `print()` in shipped code. (Tests may use `print` for debugging during development, but don't commit them.)
- Choose log levels deliberately: `.debug` for developer-only signal, `.info` for user-relevant events, `.error` for failures the user might see, `.fault` for invariant violations.
- Subsystems should be the bundle ID; categories should describe the subsystem (e.g. `category: "RTSP"`, `category: "iCloudSync"`).
- Credentials, tokens, full URLs with auth, or hostnames the user explicitly enters: never logged.

## 12. Testing

- Use Swift Testing (`import Testing`, `@Test`, `#expect`). New tests should not be XCTest.
- 80% coverage target on `AppShared` and the `Reolink*` libraries.
- No real network in tests. Use fixture servers (`URLProtocol` stubs, in-process HTTP servers) or protocol-injected fakes.
- Each test gets a fresh instance — `init`/`deinit`, no shared mutable state.
- Tests must be deterministic. If a test depends on timing, it's wrong.

## 13. Versioning

- SemVer. `MAJOR.MINOR.PATCH`.
- macOS (`App/Info.plist`) and iOS (`AppiOS/ReolensiOS.xcodeproj/project.pbxproj`) `MARKETING_VERSION` must stay aligned. A 0.3.0 release means both platforms ship 0.3.0 — never 0.3.0 on macOS and 0.2.9 on iOS.
- Every release lands as a `## [X.Y.Z]` section in `CHANGELOG.md` following Keep-a-Changelog, with `Added` / `Changed` / `Fixed` / `Removed` subsections.

## 14. Commit & PR conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
- Subject line under 70 characters. Body explains the *why*.
- PRs reference the originating issue when there is one.
- PRs touching auth, network, credentials, or sync MUST include a "Security" section explicitly stating what was reviewed.

## 15. Agent usage

Default to delegating to subagents for parallel exploration. Specifically:

- `planner` — new features, refactors, anything where the design isn't obvious.
- `tdd-guide` — bug fixes, write the failing test first.
- `code-reviewer` — after writing code, before committing.
- `security-reviewer` — before tagging any release, plus any PR touching auth/network/credentials.
- `Explore` — broad codebase research that would take more than 3 lookups.

Subagents protect the main context window and parallelize work. Use them.

---

## How to add to this file

This is a living document. If you find yourself making the same judgment call twice, codify it here. Keep entries short and concrete. The goal is fewer, sharper rules — not exhaustive checklists.
