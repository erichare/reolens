# 0.6.2 Error-Site Triage

Working file. Continuation of the 0.6.1 audit
([docs/audit-0.6.1-error-sites.md](audit-0.6.1-error-sites.md)) per
release-plan WS7. 0.6.1 covered the top-10 user-impact offenders;
0.6.2 takes the next 20 — a mix of SURFACE migrations (real silent
failures users have seen) and SAFE annotations (sites that were
already correctly written but trigger every audit grep).

## Counts (post-0.6.1, pre-0.6.2)

- `try?` sites: ~163 (down from 186 in 0.6.1)
- `_ = try?` explicit-discard sites: 7
- Empty `catch { }`: 0
- `try!`: 7 — all test-only, safe

## Top-30 batch — full triage

### SURFACE (5 sites — typed throws + `AppErrorRecorder` routing)

| # | Location | Pattern | User-visible impact |
|---|----------|---------|---------------------|
| 1 | [Sources/AppShared/CameraListPersistence.swift:55](../Sources/AppShared/CameraListPersistence.swift) | `try? JSONDecoder().decode([CameraEntry].self, from: data)` | Corrupted `cameras.json` → user opens app to empty camera list, no clue why |
| 2 | [Sources/AppShared/CameraListPersistence.swift:66](../Sources/AppShared/CameraListPersistence.swift) | `try? JSONEncoder().encode(entries)` | Encode failure → cameras don't sync to other devices, silent |
| 3 | [Sources/AppShared/ICloudCameraStorage.swift:55](../Sources/AppShared/ICloudCameraStorage.swift) | `data = try? Data(contentsOf: url)` inside coordinator | iCloud read failure → cameras don't load on second device, silent |
| 4 | [Sources/AppShared/NotificationHistory.swift:207,210](../Sources/AppShared/NotificationHistory.swift) | `try? Data(contentsOf: url)` + `try? Self.decoder.decode(...)` | Notification log unreadable → Diagnostics Center shows empty history, can't help support thread |
| 5 | [Sources/AppShared/RelayDiagnostics.swift:130](../Sources/AppShared/RelayDiagnostics.swift) | `try? JSONDecoder.iso8601.decode(RelayDiagnosticsState.self, ...)` | Relay diag state unreadable → Notification Diagnostics screen shows initial values, can't help support thread |

### LOG → folded into SAFE

The three sites originally bucketed LOG were re-classified to SAFE
after second look. SharedContainer's widget reads (`readLatestSnapshots`,
`readRecentMotionEvents`, the `appendMotionEvent` internal read) are
deliberately tolerant — the empty-fallback IS the correct UX, the
widget itself is the visibility surface for stale data, and recorder
records would be noisier than useful. `ICloudCameraStorage.migrate
LegacyLocalIfNeeded`'s legacy-load is one-shot and the missing-legacy
case is the common path (fresh install). All four annotated SAFE.

### SAFE (22 sites — annotate `// safe:` so future grep counts drop)

Annotation-only sweep — none of these are migration candidates; they're correctly written for their context but trigger every `try?` grep.

| Location | Pattern | Why safe |
|----------|---------|----------|
| [Sources/AppShared/ClipExporter.swift:90](../Sources/AppShared/ClipExporter.swift) | `try? FileManager.default.removeItem(at: outputURL)` | Stale-output cleanup before export; missing-file case is the common case |
| [Sources/AppShared/ClipExportCoordinator.swift:230,240](../Sources/AppShared/ClipExportCoordinator.swift) | `contentsOfDirectory` + `resourceValues` in `pruneStaging` | Best-effort prune; missing directory / unreadable mtime → skip-and-continue is correct |
| [Sources/AppShared/ThumbnailCache.swift:56,74,81,98,100](../Sources/AppShared/ThumbnailCache.swift) | Various cache read / cleanup ops | Cache is rebuildable from source on every miss |
| [Sources/AppShared/RecordingDownloader.swift:585](../Sources/AppShared/RecordingDownloader.swift) | `try? handle?.close()` | Close-on-deinit best-effort |
| [Sources/AppShared/CameraSession.swift:247,380](../Sources/AppShared/CameraSession.swift) | `try? await Task.sleep(...)` in backoff loops | Cancellation throw is intentional |
| [Sources/AppShared/CameraSession.swift:541,545](../Sources/AppShared/CameraSession.swift) | `try? await client.send(Commands.getMdState...)` | Capability probe — falls back to last-known state |
| [Sources/AppShared/CameraSession+RecordingsLoader.swift:135,150,151](../Sources/AppShared/CameraSession+RecordingsLoader.swift) | Envelope fallback + log prettification | Log-only formatters; failure → use raw |
| [Sources/AppShared/RecordingNLSearcher.swift:213](../Sources/AppShared/RecordingNLSearcher.swift) | `try? pattern.firstMatch(in: prompt)` | Regex over user input; mismatch is the common case |
| [Sources/ReolinkAPI/Models/RecordingSchedule.swift:42-46](../Sources/ReolinkAPI/Models/RecordingSchedule.swift) | Decodable shape fallback | Firmware-shape variation — known + handled |
| [Sources/ReolinkAPI/Models/MotionSchedule.swift:56-67](../Sources/ReolinkAPI/Models/MotionSchedule.swift) | Decodable shape fallback | Same as above |
| [Sources/ReolinkAPI/Models/Search.swift:85,87,101,102](../Sources/ReolinkAPI/Models/Search.swift) | size + trigger field tolerance | Reolink firmware sends ints-as-strings sometimes |
| [Sources/ReolinkAPI/Models/Ability.swift:65,71](../Sources/ReolinkAPI/Models/Ability.swift) | Polymorphic decode | Capability field accepts two shapes |
| [Sources/AppShared/VersionedCodable.swift:54](../Sources/AppShared/VersionedCodable.swift) | Version-peek decode | Peek is the API contract |
| [Sources/AppShared/CGIClient.swift:282](../Sources/ReolinkAPI/CGIClient.swift) | Single-vs-array response peek | Reolink batches sometimes echo single | 
| [Sources/ReolinkStreaming/Player/H264Decoder.swift:34,94](../Sources/ReolinkStreaming/Player/H264Decoder.swift) | Format descriptor probe | Decoder bring-up retries on next IDR |
| [Sources/ReolinkStreaming/Player/H265Decoder.swift:43,115](../Sources/ReolinkStreaming/Player/H265Decoder.swift) | Format descriptor probe | Same as above |
| [Sources/ReolinkStreaming/Player/LiveVideoPlayer.swift:296](../Sources/ReolinkStreaming/Player/LiveVideoPlayer.swift) | Per-NAL ingest | Per-frame fault — drop frame, keep stream |

## Process per offender

- **SURFACE**: `do { ... } catch { Task { await AppErrorRecorder.shared.record(.persistence(...), context: "<call.site>") }; /* graceful fallback */ }`
- **LOG**: same pattern, but no user-visible message — Diagnostics Center is the discovery surface
- **SAFE**: `// safe: <reason>` comment so future `rg "try\?"` audits skip these

## Long tail (deferred to 0.7.x)

After 0.6.2: ~140 `try?` sites remaining, none in user-facing action paths. Tracked in [docs/ROADMAP.md](ROADMAP.md) for incremental migration as the typed-throws surface widens.
