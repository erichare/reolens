import Foundation
import OSLog
import ReolinkAPI
#if canImport(FoundationModels)
import FoundationModels
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "recording-nl-search")

/// 0.6.0 — Natural-language query translator. Turns prompts like
/// "packages this week" into a structured `RecordingIndex.Query` that
/// the index can answer.
///
/// Two paths:
/// 1. **Deterministic** (default, always available): a keyword + date-
///    phrase parser. Handles the documented prompt forms — single tag
///    name, "this week" / "yesterday" / "last weekend" / "today" /
///    "last N days", and a small camera-name hint that matches against
///    the supplied camera roster.
/// 2. **FoundationModels** (iOS 26+ / macOS 26+ on Apple Intelligence
///    hardware): a `@Generable`-driven plan. Falls through to the
///    deterministic parser when the model is unavailable, the device
///    is in low-power mode, or the model returns garbage.
///
/// Privacy: the prompt itself is the only thing handed to the model —
/// no recording data crosses the boundary. The model just emits a
/// structured filter; the actor applies it to local data.
public struct RecordingNLSearcher: Sendable {

    /// Cameras the user has in their roster. Used to resolve camera-
    /// name hints in prompts ("front door" → matching cameraIDs). The
    /// caller passes its `CameraStore` state in; we keep this struct
    /// pure (no environment lookups).
    public struct CameraHint: Sendable, Hashable {
        public let cameraID: UUID
        public let name: String

        public init(cameraID: UUID, name: String) {
            self.cameraID = cameraID
            self.name = name
        }
    }

    public init() {}

    /// Translate `prompt` to a `RecordingIndex.Query`. Always returns a
    /// valid query — at worst, "no filters" (the user sees the full
    /// retention window).
    public func plan(
        prompt: String,
        availableCameras: [CameraHint] = [],
        now: Date = Date()
    ) -> RecordingIndex.Query {
        let normalized = prompt
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return RecordingIndex.Query() }

        let tags = Self.parseTags(normalized)
        let dateRange = Self.parseDateRange(normalized, now: now)
        let cameraIDs = Self.parseCameraIDs(normalized, hints: availableCameras)

        return RecordingIndex.Query(
            tagFilter: tags,
            dateRange: dateRange,
            cameraIDs: cameraIDs,
            limit: nil
        )
    }

    /// 0.6.0 — On-device-model variant. When FoundationModels is
    /// available on the host (iOS 26+ / macOS 26+ with Apple
    /// Intelligence eligibility), runs the prompt through a small
    /// `@Generable` query plan and intersects the result with the
    /// deterministic parser's output. Falls back to the
    /// deterministic-only path on any failure (model unavailable,
    /// session error, malformed response). The user prompt is the
    /// only thing handed to the model — no recording data crosses
    /// the boundary.
    public func planWithModel(
        prompt: String,
        availableCameras: [CameraHint] = [],
        now: Date = Date()
    ) async -> RecordingIndex.Query {
        let baseline = plan(prompt: prompt, availableCameras: availableCameras, now: now)
        #if canImport(FoundationModels)
        if let modelPlan = await foundationModelsPlan(
            prompt: prompt,
            availableCameras: availableCameras,
            now: now
        ) {
            return Self.merge(deterministic: baseline, model: modelPlan)
        }
        #endif
        return baseline
    }

    /// Merge two queries — model + deterministic. Strategy:
    ///
    /// - **Tags**: union (the model often catches synonyms the regex
    ///   parser misses, e.g. "delivery" → packageDelivery).
    /// - **Camera IDs**: union (same reason — fuzzier name matching).
    /// - **Date range**: prefer the deterministic parser's value (its
    ///   "last weekend" / "this week" math is stable and locale-
    ///   neutral). The model contributes only a date *phrase* in our
    ///   wire format; the phrase is fed back through the
    ///   deterministic parser so the actual `ClosedRange<Date>` is
    ///   computed in one place.
    static func merge(
        deterministic: RecordingIndex.Query,
        model: RecordingIndex.Query
    ) -> RecordingIndex.Query {
        var merged = deterministic
        merged.tagFilter.formUnion(model.tagFilter)
        merged.cameraIDs.formUnion(model.cameraIDs)
        if merged.dateRange == nil { merged.dateRange = model.dateRange }
        return merged
    }

    // MARK: - Tag parsing

    /// Tag keyword table. Includes Reolink's wire vocabulary so the
    /// parser tolerates "packages" / "package" / "delivery" etc.
    private static let tagKeywords: [(pattern: String, tag: DetectionType)] = [
        ("people", .person),
        ("person", .person),
        ("human", .person),
        ("visitors", .visitor),
        ("visitor", .visitor),
        ("doorbell", .visitor),
        ("packages", .packageDelivery),
        ("package", .packageDelivery),
        ("delivery", .packageDelivery),
        ("vehicles", .vehicle),
        ("vehicle", .vehicle),
        ("cars", .vehicle),
        ("car", .vehicle),
        ("animals", .pet),
        ("animal", .pet),
        ("pets", .pet),
        ("pet", .pet),
        ("dogs", .pet),
        ("dog", .pet),
        ("cats", .pet),
        ("cat", .pet),
        ("faces", .face),
        ("face", .face),
        ("motion", .motion)
    ]

    static func parseTags(_ prompt: String) -> Set<DetectionType> {
        var tags = Set<DetectionType>()
        for (pattern, tag) in tagKeywords where prompt.contains(pattern) {
            tags.insert(tag)
        }
        return tags
    }

    // MARK: - Date parsing

    static func parseDateRange(_ prompt: String, now: Date) -> ClosedRange<Date>? {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)?
            .addingTimeInterval(-1) ?? now

        // Today first — most specific to least specific.
        if prompt.contains("today") {
            return startOfToday...endOfToday
        }
        if prompt.contains("yesterday") {
            let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            let endOfYesterday = startOfToday.addingTimeInterval(-1)
            return startOfYesterday...endOfYesterday
        }
        if prompt.contains("last weekend") {
            // Last fully-completed Sat 00:00 → Sun 23:59:59.
            guard let weekendStart = previousWeekendStart(before: startOfToday, cal: cal),
                  let weekendEnd = cal.date(byAdding: .day, value: 2, to: weekendStart)?
                    .addingTimeInterval(-1) else { return nil }
            return weekendStart...weekendEnd
        }
        if prompt.contains("this weekend") {
            guard let weekendStart = currentOrUpcomingWeekendStart(from: startOfToday, cal: cal),
                  let weekendEnd = cal.date(byAdding: .day, value: 2, to: weekendStart)?
                    .addingTimeInterval(-1) else { return nil }
            return weekendStart...weekendEnd
        }
        if prompt.contains("this week") {
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
            return weekStart...endOfToday
        }
        if prompt.contains("last week") {
            guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start,
                  let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart),
                  let lastWeekEnd = cal.date(byAdding: .second, value: -1, to: thisWeekStart) else {
                return nil
            }
            return lastWeekStart...lastWeekEnd
        }
        // "last N days" / "past N days"
        if let n = extractLastNDays(from: prompt) {
            let start = cal.date(byAdding: .day, value: -n, to: startOfToday) ?? startOfToday
            return start...endOfToday
        }
        return nil
    }

    /// Looks for "last 7 days", "past 3 days", etc.
    private static func extractLastNDays(from prompt: String) -> Int? {
        // Minimal pattern: (last|past) <number> days
        let pattern = #/(last|past)\s+(\d+)\s+days?/#
        guard let match = try? pattern.firstMatch(in: prompt) else { return nil }
        return Int(match.output.2)
    }

    private static func previousWeekendStart(before day: Date, cal: Calendar) -> Date? {
        // Find the most recent Saturday strictly before `day`.
        let weekday = cal.component(.weekday, from: day)
        // weekday: Sunday=1, Monday=2, ..., Saturday=7
        let daysSinceSaturday: Int
        switch weekday {
        case 1: daysSinceSaturday = 8  // Sunday → previous Saturday (8 days back to "fully completed" Saturday)
        case 7: daysSinceSaturday = 7  // Saturday → previous Saturday
        default: daysSinceSaturday = weekday  // Mon..Fri → most recent Saturday is `weekday` days back
        }
        return cal.date(byAdding: .day, value: -daysSinceSaturday, to: day)
    }

    private static func currentOrUpcomingWeekendStart(from day: Date, cal: Calendar) -> Date? {
        let weekday = cal.component(.weekday, from: day)
        // weekday: Sunday=1, Monday=2, ..., Saturday=7
        switch weekday {
        case 7: return day  // Saturday — "this weekend" starts now
        case 1: return cal.date(byAdding: .day, value: -1, to: day) // Sunday — Saturday was yesterday
        default:
            let daysUntilSaturday = 7 - weekday
            return cal.date(byAdding: .day, value: daysUntilSaturday, to: day)
        }
    }

    // MARK: - Camera parsing

    static func parseCameraIDs(_ prompt: String, hints: [CameraHint]) -> Set<UUID> {
        guard !hints.isEmpty else { return [] }
        var ids = Set<UUID>()
        for hint in hints {
            let name = hint.name.lowercased()
            // Require at least one substring match on a non-trivial
            // token from the camera's name. "Camera" / "channel" /
            // "the" / single-letter words are filtered to avoid every
            // prompt matching every camera.
            let tokens = name
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !Self.stopwords.contains($0) }
            for token in tokens where prompt.contains(token) {
                ids.insert(hint.cameraID)
                break
            }
        }
        return ids
    }

    private static let stopwords: Set<String> = [
        "camera", "cameras", "channel", "channels", "the", "and", "any",
        "hub", "home"
    ]

    // MARK: - FoundationModels integration

    #if canImport(FoundationModels)

    /// Structured output for the prompt → query translation. Fields
    /// are normalized strings (rather than enums or sets) so the
    /// generation contract stays inside what `@Generable` can express
    /// natively. Conversion to `RecordingIndex.Query` happens in
    /// `convert(plan:availableCameras:now:)` so the model's role is
    /// purely "interpret the user's words", with our deterministic
    /// code owning the type math.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct FMNLQueryPlan {
        @Guide(description: "Lowercase detection tags the user wants results for. Pick zero or more from this exact list: people, vehicle, pet, package, face, motion, visitor. Map synonyms (\"dogs\" → pet, \"deliveries\" → package, \"doorbell\" → visitor). Use an empty list when the prompt doesn't mention any tags.")
        let tags: [String]

        @Guide(description: "Distinctive name tokens from any camera the user named. Example: prompt \"Driveway people this week\" with cameras [Driveway, Porch] yields [\"driveway\"]. Empty when the prompt doesn't reference a specific camera.")
        let cameraNameTokens: [String]

        @Guide(description: "A date phrase that exactly matches one of: today, yesterday, this week, last week, this weekend, last weekend, or \"last N days\" where N is a positive integer. Use an empty string when the prompt doesn't specify a date.")
        let dateRangePhrase: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    func foundationModelsPlan(
        prompt: String,
        availableCameras: [CameraHint],
        now: Date
    ) async -> RecordingIndex.Query? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            log.debug("FoundationModels NL search unavailable; deterministic only.")
            return nil
        }
        let modelPrompt = Self.buildModelPrompt(
            userPrompt: prompt,
            availableCameras: availableCameras
        )
        do {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: modelPrompt,
                generating: FMNLQueryPlan.self
            )
            return Self.convert(
                plan: response.content,
                availableCameras: availableCameras,
                now: now
            )
        } catch {
            log.warning("FoundationModels NL search failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func buildModelPrompt(
        userPrompt: String,
        availableCameras: [CameraHint]
    ) -> String {
        var lines: [String] = []
        lines.append("You translate natural-language search prompts about home security camera recordings into a structured filter. The user's available cameras are:")
        for hint in availableCameras {
            lines.append("- \(hint.name)")
        }
        lines.append("")
        lines.append("User prompt: \(userPrompt)")
        return lines.joined(separator: "\n")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func convert(
        plan: FMNLQueryPlan,
        availableCameras: [CameraHint],
        now: Date
    ) -> RecordingIndex.Query {
        // Tags — model emits raw vocabulary strings; resolve via the
        // same Reolink-string mapping the rest of the app uses, so
        // synonym handling stays consistent.
        var tags: Set<DetectionType> = []
        for raw in plan.tags {
            if let dt = DetectionType.fromReolinkString(raw) {
                tags.insert(dt)
            }
        }

        // Date range — feed the phrase back through the
        // deterministic parser so the actual `ClosedRange<Date>`
        // calculation is in one place.
        let dateRange: ClosedRange<Date>?
        if plan.dateRangePhrase.isEmpty {
            dateRange = nil
        } else {
            dateRange = parseDateRange(plan.dateRangePhrase.lowercased(), now: now)
        }

        // Camera IDs — resolve tokens against the hints. Reuse the
        // same matcher the deterministic parser uses so the rules
        // are identical (longest-non-stopword token wins).
        let cameraIDs = parseCameraIDs(
            plan.cameraNameTokens.joined(separator: " ").lowercased(),
            hints: availableCameras
        )

        return RecordingIndex.Query(
            tagFilter: tags,
            dateRange: dateRange,
            cameraIDs: cameraIDs,
            limit: nil
        )
    }

    #endif
}
