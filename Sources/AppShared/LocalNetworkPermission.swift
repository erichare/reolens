import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.reolens.app", category: "lan-permission")

/// 0.5.0 Theme E — iOS Local Network permission detection.
///
/// iOS / iPadOS require the user to grant the Local Network permission
/// before any Bonjour browse, mDNS resolution, or `NWConnection` to a
/// local IP address can succeed. Without it the calls hang silently
/// for tens of seconds before timing out, which is the #1 reason
/// "scan local network" feels broken on iOS.
///
/// This helper probes the permission state by firing a fresh Bonjour
/// browse and watching its first `browseResultsChanged` callback. The
/// system surfaces the OS prompt; once it's answered (granted or
/// denied) the callback fires. We time out after a short interval so
/// the caller's UI doesn't hang.
///
/// On macOS the permission doesn't exist — `check` returns `.granted`
/// immediately.
public enum LocalNetworkPermission {

    public enum State: Sendable, Equatable {
        /// Granted (or not applicable on macOS).
        case granted
        /// The prompt is showing and we haven't heard back. UI should
        /// show a hint asking the user to allow Local Network.
        case pending
        /// User explicitly denied — Settings → Privacy → Local Network
        /// is the recovery path. UI should show that hint.
        case denied
        /// Couldn't probe at all (entitlement missing, etc.). Treat as
        /// "we don't know, try anyway and hope for the best."
        case unknown
    }

    /// Probe the permission state. Resolves within `timeoutSeconds`.
    ///
    /// Implementation note: on iOS we listen for *any* browse-result
    /// callback (zero results is still a callback, just one with an
    /// empty set). The system fires this callback only after the user
    /// has answered the permission prompt — pre-grant it never fires.
    /// So `received any callback within timeout` ≈ `permission was
    /// previously granted, OR the user just allowed it`. No callback
    /// within timeout ≈ pending or denied.
    public static func check(timeoutSeconds: TimeInterval = 1.0) async -> State {
        #if os(macOS)
        return .granted
        #else
        return await probe(timeoutSeconds: timeoutSeconds)
        #endif
    }

    #if !os(macOS)
    private static func probe(timeoutSeconds: TimeInterval) async -> State {
        await withCheckedContinuation { (cont: CheckedContinuation<State, Never>) in
            let probe = ProbeBox(cont: cont)
            probe.start(timeout: timeoutSeconds)
        }
    }

    /// Reference-typed continuation holder so the timer and the
    /// browse-result handler both resolve through the same gate
    /// without double-resuming.
    private final class ProbeBox: @unchecked Sendable {
        let cont: CheckedContinuation<State, Never>
        private let lock = NSLock()
        private var resolved = false
        private var browser: NWBrowser?

        init(cont: CheckedContinuation<State, Never>) {
            self.cont = cont
        }

        func start(timeout: TimeInterval) {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_http._tcp", domain: nil),
                using: params
            )
            self.browser = browser
            // 0.5.0 fix — capture self STRONGLY in every callback.
            //
            // Previously these were `[weak self]`. `probe(timeoutSeconds:)`
            // holds the ProbeBox only as a local `let probe = ...` inside
            // the `withCheckedContinuation` closure; that local goes out
            // of scope the instant `start(...)` returns. With weak
            // captures, the box was deallocated before any callback could
            // fire `resolve()`, which leaked the continuation:
            //
            //     SWIFT TASK CONTINUATION MISUSE:
            //     probe(timeoutSeconds:) leaked its continuation without
            //     resuming it. This may cause tasks waiting on it to
            //     remain suspended forever.
            //
            // …and indirectly broke iOS discovery — `scanWithPermissionGate`
            // awaited the gate and never returned, so the actual scan
            // never started.
            //
            // BonjourCollector in CameraDiscovery.swift documents the
            // same trap; mirroring its strong-capture pattern here. The
            // strong references chain through the NWBrowser's closures
            // and the dispatch-after block, so the box lives at least
            // `timeout` seconds OR until the first callback fires and
            // cancels the browser via `resolve(_:)`.
            browser.browseResultsChangedHandler = { _, _ in
                self.resolve(.granted)
            }
            browser.stateUpdateHandler = { state in
                // iOS fires `.waiting(NWError.dns(...))` when the
                // user has explicitly denied Local Network. `.failed`
                // with a permission-related error is the same signal.
                switch state {
                case .waiting(let error), .failed(let error):
                    if error.errorCode == -65555 || "\(error)".lowercased().contains("permission") {
                        self.resolve(.denied)
                    }
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                self.resolve(.pending)
            }
        }

        private func resolve(_ state: State) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            let browser = self.browser
            self.browser = nil
            lock.unlock()
            browser?.cancel()
            cont.resume(returning: state)
        }
    }
    #endif
}
