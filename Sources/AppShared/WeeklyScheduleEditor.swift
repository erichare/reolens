import SwiftUI
import ReolinkAPI

/// 0.6.0 Slice 12 — reusable weekly schedule editor.
///
/// Pure SwiftUI component (no networking). Renders a 7×24 grid (one
/// cell per hour, Sun..Sat × 00..23) with single-tap toggle and a
/// drag-paint gesture for sweeping multiple cells at once.
///
/// Designed so two surfaces share the exact same UX:
/// - **Recording schedule** (`RecordingScheduleView`) — write back via
///   `SetRec` CGI command.
/// - **Motion-zone schedule** (per-zone, follow-up) — same model, just
///   written through the motion-zone CGI plumbing.
///
/// The state model is a `WeeklySchedule` (binding) so the parent owns
/// undo/redo + the diff-against-original computation that lets us
/// write only changed slots to the wire.
public struct WeeklyScheduleEditor: View {
    @Binding public var schedule: WeeklySchedule
    /// When non-nil, renders the editor read-only with a tint —
    /// "schedule not supported on this firmware" path. The editor
    /// still shows the current schedule so users can see what the
    /// camera was provisioned with via the stock Reolink app.
    public let readOnlyReason: String?

    public init(
        schedule: Binding<WeeklySchedule>,
        readOnlyReason: String? = nil
    ) {
        self._schedule = schedule
        self.readOnlyReason = readOnlyReason
    }

    @State private var dragOrigin: WeeklySchedule.CellCoord?
    @State private var dragSetValue: Bool = true

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = readOnlyReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                weekdayColumn
                grid
            }
            controlsRow
        }
    }

    // MARK: - Subviews

    private var weekdayColumn: some View {
        VStack(spacing: 2) {
            Text(" ").font(.caption2).frame(height: 14)
            ForEach(0..<7, id: \.self) { day in
                Text(Self.weekdayLabel(day))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(width: 32, height: 18, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 2) {
            // Hour-label header.
            HStack(spacing: 1) {
                ForEach(0..<24, id: \.self) { hour in
                    Text("\(hour)")
                        .font(.system(size: 9).monospacedDigit())
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 1) {
                    ForEach(0..<24, id: \.self) { hour in
                        cell(day: day, hour: hour)
                    }
                }
            }
        }
    }

    private func cell(day: Int, hour: Int) -> some View {
        let coord = WeeklySchedule.CellCoord(weekday: day, hour: hour)
        let isOn = schedule.isEnabled(at: coord)
        return Rectangle()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18))
            .frame(width: 14, height: 18)
            .contentShape(.rect)
            .onTapGesture {
                guard readOnlyReason == nil else { return }
                schedule.toggle(coord)
            }
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard readOnlyReason == nil else { return }
                let coord = coordinate(from: value.location)
                if dragOrigin == nil {
                    dragOrigin = coord
                    dragSetValue = !schedule.isEnabled(at: coord)
                }
                schedule.set(coord, to: dragSetValue)
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    /// Snap a touch point back to a (day, hour) cell. Hard-coded to
    /// the cell dimensions above; if those change, update here too.
    private func coordinate(from point: CGPoint) -> WeeklySchedule.CellCoord {
        let hour = max(0, min(23, Int(point.x / 15)))
        let day = max(0, min(6, Int((point.y - 14) / 20)))
        return WeeklySchedule.CellCoord(weekday: day, hour: hour)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                schedule.fill(value: true)
            } label: {
                Label("Always", systemImage: "checkmark.circle.fill")
            }
            .disabled(readOnlyReason != nil)
            Button {
                schedule.fill(value: false)
            } label: {
                Label("Never", systemImage: "minus.circle")
            }
            .disabled(readOnlyReason != nil)
            Spacer()
            Text("\(schedule.activeHourCount) of 168 hours")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private static func weekdayLabel(_ day: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day]
    }
}

// MARK: - Phase

/// Shared loading-phase state for the recording-schedule + motion-
/// schedule views. Both go through the same lifecycle (fetch → render
/// or fall back to read-only on `-9 notSupport` → apply / surface
/// error), so the type is unified rather than duplicated.
public enum SchedulePhase: Equatable, Sendable {
    case loading
    case ready
    case unsupported
    case error(String)
}

// MARK: - Model

/// Editor data model. Backed by a 168-element `Bool` array so
/// modifications are O(1); serializes to a 168-char `01` string for the
/// wire via `scheduleTable`.
public struct WeeklySchedule: Equatable, Sendable, Hashable {
    public private(set) var cells: [Bool]

    public struct CellCoord: Hashable, Sendable {
        public let weekday: Int  // 0..6, Sun..Sat
        public let hour: Int     // 0..23

        public init(weekday: Int, hour: Int) {
            self.weekday = weekday
            self.hour = hour
        }

        var index: Int { weekday * 24 + hour }
    }

    public init(cells: [Bool] = Array(repeating: false, count: 168)) {
        precondition(cells.count == 168, "WeeklySchedule needs exactly 168 cells")
        self.cells = cells
    }

    /// Build from a wire-format `01` string. Returns nil on malformed
    /// input so callers can surface an explicit "couldn't parse" error.
    public init?(scheduleString: String) {
        guard scheduleString.count == 168 else { return nil }
        var arr: [Bool] = []
        arr.reserveCapacity(168)
        for ch in scheduleString {
            switch ch {
            case "0": arr.append(false)
            case "1": arr.append(true)
            default: return nil
            }
        }
        self.cells = arr
    }

    /// Wire-format `01` string. 168 chars, row-major Sun..Sat × 00..23.
    public var scheduleString: String {
        cells.map { $0 ? "1" : "0" }.joined()
    }

    public func isEnabled(at coord: CellCoord) -> Bool {
        cells[coord.index]
    }

    public mutating func set(_ coord: CellCoord, to value: Bool) {
        cells[coord.index] = value
    }

    public mutating func toggle(_ coord: CellCoord) {
        cells[coord.index].toggle()
    }

    public mutating func fill(value: Bool) {
        cells = Array(repeating: value, count: 168)
    }

    public var activeHourCount: Int {
        cells.lazy.filter { $0 }.count
    }

    /// Indices that differ vs `other`. Used by the "write only changed
    /// slots" code path so a small edit doesn't push 168 chars when 4
    /// would do.
    public func changedIndices(comparedTo other: WeeklySchedule) -> [Int] {
        zip(cells, other.cells).enumerated().compactMap { idx, pair in
            pair.0 != pair.1 ? idx : nil
        }
    }
}
