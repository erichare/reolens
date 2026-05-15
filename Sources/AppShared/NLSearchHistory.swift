import Foundation

/// 0.6.1 — Lightweight local history of NL search queries the user has
/// run. Surfaces as suggestion rows below the search field when it's
/// empty, so the user doesn't have to retype common queries.
///
/// Per AGENTS.md §5: device-local only. Stored in `UserDefaults`
/// because the volume is small (cap 10) and the data isn't worth
/// syncing across devices — search habits typically differ per
/// device (iPhone "outside on the deck" vs Mac "in the office").
///
/// `@Observable` so SwiftUI can pick up additions without an extra
/// publisher; isolated to `MainActor` because the only writers are
/// view bodies + small user-driven actions.
@MainActor
@Observable
public final class NLSearchHistory {

    /// Default singleton wired to `UserDefaults.standard`. Tests
    /// construct their own instance with an injected `UserDefaults`.
    public static let shared = NLSearchHistory()

    /// Cap on stored entries. 10 is enough to surface a few rows
    /// without burying the user under a long list of forgotten queries.
    public let cap: Int

    @ObservationIgnored
    private let defaults: UserDefaults

    public private(set) var entries: [String]

    public init(defaults: UserDefaults = .standard, cap: Int = 10) {
        self.defaults = defaults
        self.cap = cap
        self.entries = (defaults.array(forKey: Self.key) as? [String]) ?? []
    }

    /// Record a successful (non-empty result) search. Trims any
    /// existing copy so duplicates rise to the top of the list
    /// instead of stacking. No-op for empty / whitespace-only
    /// strings — those aren't real queries.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > cap {
            entries = Array(entries.prefix(cap))
        }
        persist()
    }

    /// Wipe history. Surfaced as a "Clear" button on the suggestions
    /// row so users can reset without diving into Settings.
    public func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(entries, forKey: Self.key)
    }

    static let key = "com.reolens.nlSearchHistory"
}
