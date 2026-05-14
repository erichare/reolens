# Performance Baselines

This directory holds before/after measurements for the perf-targeted
workstreams in each release. Numbers, traces, and the methodology that
produced them — so regressions are catchable and improvements are
defensible.

## Time-to-First-Frame (TTFF) — added 0.6.1

The most user-visible perf metric in Reolens: time from tap on a
camera tile to the first decoded `CMSampleBuffer` appearing on the
display layer.

### How to measure

The `LiveVideoPlayer` emits an `OSSignposter` interval named **TTFF**
on subsystem `com.reolens.streaming`, category `TTFF`.

1. Open **Instruments** → **Time Profiler** template (or any template
   that includes the **os_signpost** instrument).
2. Add a custom os_signpost filter: subsystem `com.reolens.streaming`,
   category `TTFF`, name `TTFF`.
3. Launch a debug build of the app — `swift build` (macOS) or
   `./Scripts/build-ios.sh debug` (iOS) — and attach Instruments.
4. Tap a camera tile cold (after a fresh launch). The signpost
   interval represents the cold TTFF.
5. Repeat the tap after stopping the player and immediately
   re-tapping. That's the warm TTFF.

Capture at least 5 trials per camera per scenario; report median.

### 0.6.1 baseline (pre-improvements)

Not yet captured. Fill this section in once the first set of
measurements is in. Expected format:

| Camera | Resolution | Cold TTFF (ms, median) | Warm TTFF (ms, median) | Notes |
|--------|-----------|------------------------|------------------------|-------|
| (pending) | | | | |

### 0.6.1 target

- **Warm TTFF**: ≥ 20% reduction vs. baseline.
- **Cold TTFF**: ≥ 10% reduction vs. baseline. (Network variance
  makes this looser.)

### Likely investigation candidates

Inventory only — none of these are commitments. Once the baseline is
in, profile traces will narrow this list.

- `URLSessionConfiguration.ephemeral` in
  [Sources/AppShared/CameraPreviewService.swift:40-42](../../Sources/AppShared/CameraPreviewService.swift:40) —
  may force TLS handshakes on every preview refresh.
- RTSP TCP socket setup cost — the actor in
  [Sources/ReolinkStreaming/RTSP/RTSPClient.swift:45](../../Sources/ReolinkStreaming/RTSP/RTSPClient.swift:45)
  opens a fresh socket per session; could a per-camera pool win warm
  re-open?
- VTDecompressionSession recreation — currently per `start()`; caching
  the format-description + session across stop/start cycles would
  skip a CoreVideo init.
- Snapshot-then-stream race — does the preview snapshot block first
  frame? If yes, parallelize.

## Adding a new perf workstream

When a release ships measurable perf work, add a new section here
with the same shape: methodology, baseline, target, candidates. Keep
the file flat — flat lists of measurements age better than a deep
hierarchy.
