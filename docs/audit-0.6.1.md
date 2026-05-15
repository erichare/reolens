# 0.6.1 Documentation Audit

Working file. Per release-plan WS1 — every doc claim is verified against current code, every gap is captured here, fixes land in subsequent commits.

## Top-level summary

10 docs audited end-to-end. 10 actionable findings across 5 files. Highest-impact gaps:

- `README.md` is silent on multiple 0.6.0 headline features (Notification Diagnostics screen, NL Search wiring, schedule editors, HomeKit bridge, XCUITest harness, the 0.6.0 architecture pass).
- `docs/RELEASE.md` has a 0.5.1-specific verification section but no equivalent for 0.6.0.
- `AppiOS/README.md` highlights section omits the HomeKit bridge.
- `AGENTS.md` carve-out phrasing is stuck at "Added in 0.5.x" and doesn't acknowledge 0.6.0 enhancements.
- Scattered "future work" notes across `AGENTS.md` / `SECURITY.md` / `CHANGELOG.md` need consolidation into a new `docs/ROADMAP.md`.

## Per-file findings

### `README.md`

- **1.1** Missing 0.6.0 features in Notifications section (lines 149–186). Add Diagnostics screen + 1,000-record log to the bullet list.
- **1.2** Cross-day NL Search mentioned but not flagged as new-in-0.6.0 with the FoundationModels / regex-fallback story.
- **1.3** Schedule editors (recording + motion + per-AI-tag override) missing from feature list; should call out the shared 7×24 grid and the `-9 notSupport` fallback.
- **1.4** HomeKit bridge scaffolding (iOS-only, MFi-blocked) not mentioned — users may expect a complete feature.
- **1.5** XCUITest harness omitted (low priority; infrastructure).
- **1.6** Architecture section (lines 261–285) silent on the 0.6.0 carve-out work (`RecordingsLoader`, `RecordingIndex`, `PollManager`, etc.).

### `CHANGELOG.md`

No issues. Authoritative reference for this audit.

### `AGENTS.md`

- **3.1** Lines 42–66 carve-outs phrased as "Added in 0.5.x" — restate to include 0.6.0 enhancements where applicable.
- **3.2** HomeKit carve-out (line 49–55) is accurate.
- **3.3** §7 schema-version notes for 0.6.0 are accurate.

### `CONTRIBUTING.md`

- **4.1** Coverage gate phrasing "enforced as of 0.6.0" reads fine now but will get stale. Defer to 0.7.0.
- **4.2** XCUITest mention could cross-reference `AppiOS/UITests/ReolensiOSUITests.swift`.

### `SECURITY.md`

- **5.1** Supported versions table (lines 161–171) needs a `0.6.x` row; 0.5.x moves to maintenance.
- **5.2** HomeKit scaffolding-vs-attack-surface note for the in-scope list.

### `docs/RELEASE.md`

- **6.1** Missing "0.6.0-specific verification" section. Add a pre-release checklist for: Diagnostics screen rendering, log captures + deep-links, NL Search both paths, schedule editor round-trip, motion editor + per-tag overrides, battery auto-wake on detail view, last-camera-on-launch restore (iOS/iPadOS), bookmark reconcile re-enqueue, bookmark delete cascade, XCUITest pass on iPhone simulator, HomeKit section renders on iOS and is hidden on macOS.
- **6.2** Test count phrasing "49 suites at 0.5.1 baseline" → "68 suites at 0.6.0 baseline."

### `docs/IOS_RELEASE.md`

No issues. Timeless procedures.

### `App/Widgets/README.md`

No issues.

### `AppiOS/README.md`

- **9.1** 0.6.0 highlights section (lines 78–96) omits the HomeKit bridge.
- **9.2** XCUITest mention needs a file path cross-reference.
- **9.3** Duplicated "### What's wired up now" headers (lines 97 and 106) — clarify they're cumulative.

### `.github/PULL_REQUEST_TEMPLATE.md`

No issues.

## Cross-file: roadmap candidates

These items currently live scattered across `AGENTS.md`, `SECURITY.md`, and `CHANGELOG.md`. They should consolidate into `docs/ROADMAP.md`:

- HomeKit full HKSV integration — pending Apple MFi certification ([Sources/AppShared/HomeKitBridge.swift:34](../Sources/AppShared/HomeKitBridge.swift:34) and AGENTS.md §1)
- Live Activity push relay server — token persistence exists (`live-activity-tokens_v1.json`), sender doesn't (AGENTS.md §16 and §5)
- Coverage baselines ratchet toward 80% (AGENTS.md §12; tracked in `Scripts/coverage-baselines.txt`)
- Future OS-floor bumps as Apple ships new APIs

## Action plan (resolved during 0.6.1)

1. Patch README.md feature bullets (1.1–1.4, 1.6). 1.5 deferred.
2. Restate AGENTS.md §1 carve-out language (3.1).
3. Add SECURITY.md `0.6.x` row + HomeKit scaffold note (5.1, 5.2).
4. Add `docs/RELEASE.md` § "0.6.0-specific verification" plus a § "0.6.1-specific verification" (6.1). Fix test-count phrasing (6.2).
5. Patch AppiOS/README.md (9.1, 9.2, 9.3).
6. Create `docs/ROADMAP.md` (cross-file).
