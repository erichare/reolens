# 0.6.1 Error-Site Triage

Working file. Per release-plan WS7 — every `try?` / empty `catch` is bucketed into safe / log / surface / fix. Top-10 offenders fixed in 0.6.1; long tail moves to `docs/ROADMAP.md`.

## Counts

- `try?` (silent): **186** sites
- `_ = try?` (explicit discard): **7** sites
- Empty `catch { }`: **0** sites
- `try!`: **7** sites — all test-only, safe

## Top-10 offenders (fixed in 0.6.1 — WS7b)

| # | Location | Pattern | Bucket | User-visible impact |
|---|----------|---------|--------|---------------------|
| 1 | [Sources/AppShared/ChannelSettingsView.swift:258](../Sources/AppShared/ChannelSettingsView.swift:258), [App/Views/LiveCameraTile.swift:108,567](../App/Views/LiveCameraTile.swift:108), [AppiOS/Sources/Views/LiveTileView.swift:92,461](../AppiOS/Sources/Views/LiveTileView.swift:92) | `_ = try? await baichuan.wakeBatteryCamera(...)` | **surface** | Battery camera doesn't wake — user sees blank/stale frame |
| 2 | [Sources/ReolinkBaichuan/BaichuanTalkback.swift:176](../Sources/ReolinkBaichuan/BaichuanTalkback.swift:176) | `Task { _ = try? await client.sendAndAwait(...) }` | **log** | Audio frames silently dropped during talkback |
| 3 | [Sources/AppShared/EventNotifier.swift:488-489,501](../Sources/AppShared/EventNotifier.swift:488) | `let jpegData = try? Data(...)` | **surface** | Notification thumbnails silently absent |
| 4 | [Sources/AppShared/RecordingDownloader.swift:92,144,237,373,441,446](../Sources/AppShared/RecordingDownloader.swift:92) | `try? fm.createDirectory(...)` | **surface** | Bookmark download silently fails (no progress, no error) |
| 5 | [Sources/AppShared/EventNotifier.swift:204](../Sources/AppShared/EventNotifier.swift:204) | `let granted = (try? await center.requestAuthorization(...)) ?? false` | **surface** | Permission denial conflated with thrown error |
| 6 | [Sources/ReolinkStreaming/RTSP/RTSPClient.swift:237,302,538](../Sources/ReolinkStreaming/RTSP/RTSPClient.swift:237) | `try? await Task.sleep(...)` | **safe** | Annotate — these are cancellation-safe sleeps |
| 7 | [Sources/AppShared/RecordingIndex.swift:330](../Sources/AppShared/RecordingIndex.swift:330) | `guard let file = try? Self.decoder.decode(...)` | **log** | Index load failure hides all recordings silently |
| 8 | [Sources/AppShared/CameraSession+RecordingsLoader.swift:151](../Sources/AppShared/CameraSession+RecordingsLoader.swift:151) | `try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])` | **safe** | Log prettification only — annotate |
| 9 | [Sources/AppShared/RecordingDownloader.swift:198,453,534](../Sources/AppShared/RecordingDownloader.swift:198) | `let size = (try? FileManager.default.attributesOfItem(...)[.size] as? Int64) ?? 0` | **safe** | Progress bar fallback — annotate |
| 10 | Schedule save paths in [Sources/AppShared/RecordingScheduleView.swift](../Sources/AppShared/RecordingScheduleView.swift), [Sources/AppShared/MotionScheduleView.swift](../Sources/AppShared/MotionScheduleView.swift) | Various — verify each save path surfaces failures | **surface** | Schedule save silently dropped (data loss UX) |

## Process per offender

- **surface**: `do { try await ... } catch { await AppErrorRecorder.shared.record(.<bucket>(...), context: "<call.site>"); /* show user message */ }`
- **log**: route to `os.Logger` with redacted context, no user message; record to `AppErrorRecorder` when category is meaningful.
- **safe**: annotate with `// safe: <reason>` so future audits skip these.

## Long tail (deferred to 0.7.x)

The other ~176 `try?` sites are not in user-facing action paths (most are sleeps, format probes, fire-and-forget logging, or paths already routed through other diagnostics). Tracked in `docs/ROADMAP.md` for incremental migration as `AppError` adoption widens.
