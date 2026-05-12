import Foundation

/// Rate-limits concurrent RTSP player starts so a many-camera hub
/// doesn't get slammed when the user flips Stills → Live and every
/// tile tries to open a session simultaneously.
///
/// Reolink hubs (Home Hub, Home Hub Pro, NVR) cap the number of
/// concurrent RTSP sessions per device. The cap varies by firmware
/// (commonly 4–8) and isn't queryable, so we conservatively rate-
/// limit *our side* of the connection — at most one new player
/// start per `minStartIntervalSeconds`. The trade-off is a slower
/// "all tiles live" warm-up (around 8 seconds for a 16-camera hub)
/// vs the previous behavior of N parallel starts where most got
/// rejected and the user saw a sea of error overlays.
///
/// AGENTS.md §10: defaults to the sub-stream in grids; this gate is
/// the complementary rate-limit for the moment the user opts into
/// live grids.
public actor LivePlayerStartGate {
    public static let shared = LivePlayerStartGate()

    /// Minimum spacing between successive `acquire()` returns.
    /// Tuned empirically — 500 ms is fast enough that the user
    /// sees tiles coming alive progressively, slow enough that the
    /// hub doesn't drop sessions.
    private let minStartIntervalSeconds: Double = 0.5

    private var lastStartTime: ContinuousClock.Instant = .now - .seconds(60)

    /// Wait until enough time has elapsed since the previous
    /// `acquire()` return, then mark this slot as taken. Callers
    /// should call this *immediately before* opening their RTSP
    /// stream so the inter-arrival spacing applies to the actual
    /// network attempts, not to bookkeeping.
    ///
    /// Returns immediately when the gate has been idle longer than
    /// `minStartIntervalSeconds` — the rate-limit only kicks in when
    /// many starts pile up at once.
    public func acquire() async {
        let now = ContinuousClock.now
        let elapsed = lastStartTime.duration(to: now)
        let minimum = Duration.seconds(minStartIntervalSeconds)
        if elapsed < minimum {
            let wait = minimum - elapsed
            try? await Task.sleep(for: wait)
        }
        lastStartTime = .now
    }
}
