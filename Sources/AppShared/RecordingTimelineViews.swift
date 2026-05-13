import SwiftUI
import ReolinkAPI
import ReolinkBaichuan

/// Two reusable SwiftUI primitives for the 0.4.0 recording timeline:
///
/// 1. `MonthRecordingDensity` — a horizontal calendar strip that
///    highlights days in the currently-selected month that have at
///    least one recording. Driven by the `Status` bitfield Reolink
///    returns from every `Search` command. Tapping a day jumps the
///    `DatePicker` binding to that date.
///
/// 2. `DayTimelineStrip` — a horizontal proportional 24-hour bar with
///    one rectangle per recording segment + tiny ticks marking AI
///    events. Tap a segment to invoke the same play action the file
///    list uses.
///
/// Neither view does any I/O. The parent `RecordingsView` already has
/// the data (the SearchResult bitfield, the day's [SearchFile], and
/// the live `CameraSession.aiEventLog`); these views are pure
/// presentation.

// MARK: - MonthRecordingDensity

public struct MonthRecordingDensity: View {
    @Binding public var selectedDate: Date
    /// All status responses surfaced from the latest Search call. We
    /// look up the entry for the displayed month inside the body so
    /// the parent doesn't have to filter by month.
    public let monthStatuses: [SearchStatus]

    public init(selectedDate: Binding<Date>, monthStatuses: [SearchStatus]) {
        self._selectedDate = selectedDate
        self.monthStatuses = monthStatuses
    }

    public var body: some View {
        let cal = Calendar.current
        let (year, month) = (cal.component(.year, from: selectedDate),
                             cal.component(.month, from: selectedDate))
        let status = monthStatuses.first(where: { $0.year == year && $0.mon == month })
        let daysWithRecordings = Set(status?.daysWithRecordings ?? [])
        let daysInMonth = cal.range(of: .day, in: .month, for: selectedDate)?.count ?? 30
        let today = cal.component(.day, from: Date())
        let selectedDay = cal.component(.day, from: selectedDate)
        let isCurrentMonth = (cal.component(.year, from: Date()) == year
                              && cal.component(.month, from: Date()) == month)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(1...daysInMonth, id: \.self) { day in
                    dayCell(
                        day: day,
                        year: year,
                        month: month,
                        hasRecording: daysWithRecordings.contains(day),
                        isSelected: day == selectedDay,
                        isToday: isCurrentMonth && day == today
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func dayCell(day: Int, year: Int, month: Int, hasRecording: Bool, isSelected: Bool, isToday: Bool) -> some View {
        Button {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            if let newDate = Calendar.current.date(from: comps) {
                selectedDate = newDate
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? .white : .primary)
                Circle()
                    .fill(hasRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.2)))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 26, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day), \(hasRecording ? "has recordings" : "no recordings")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - DayTimelineStrip

public struct DayTimelineStrip: View {
    public let day: Date
    public let files: [SearchFile]
    public let events: [TimestampedAIEvent]
    public let onTapSegment: (SearchFile) -> Void

    /// X-position (in strip-local pixels) the user is currently
    /// hovering / scrubbing. Drives the time-cursor overlay added in
    /// 0.4.1 — phase-two of the recordings timeline.
    @State private var scrubX: CGFloat?
    @State private var stripWidth: CGFloat = 0

    public init(
        day: Date,
        files: [SearchFile],
        events: [TimestampedAIEvent],
        onTapSegment: @escaping (SearchFile) -> Void
    ) {
        self.day = day
        self.files = files
        self.events = events
        self.onTapSegment = onTapSegment
    }

    public var body: some View {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let dayInterval = endOfDay.timeIntervalSince(startOfDay)

        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 22)
                    // Segment rectangles
                    ForEach(files) { file in
                        if let frame = frame(for: file, startOfDay: startOfDay, dayInterval: dayInterval, width: geo.size.width) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.tint)
                                .frame(width: max(2, frame.width), height: 22)
                                .offset(x: frame.x)
                                .onTapGesture {
                                    onTapSegment(file)
                                }
                                .accessibilityLabel(accessibilityLabel(for: file))
                        }
                    }
                    // Event ticks — overlay above the segments
                    ForEach(events) { event in
                        if let x = eventX(for: event, startOfDay: startOfDay, dayInterval: dayInterval, width: geo.size.width) {
                            Rectangle()
                                .fill(eventColor(for: event))
                                .frame(width: 2, height: 22)
                                .offset(x: x)
                                .accessibilityHidden(true)
                        }
                    }
                    // Scrub cursor — vertical line at the current
                    // drag position, surfaced when the user is
                    // actively scrubbing across the strip. Added in
                    // 0.4.1 as phase-two of the timeline.
                    if let x = scrubX {
                        Rectangle()
                            .fill(.primary.opacity(0.85))
                            .frame(width: 1.5, height: 26)
                            .offset(x: max(0, min(x, geo.size.width - 1.5)))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
                .onAppear { stripWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in stripWidth = newWidth }
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: 22)
            .overlay(alignment: .top) {
                if let x = scrubX, dayInterval > 0, stripWidth > 0 {
                    let fraction = max(0, min(1, x / stripWidth))
                    let scrubTime = startOfDay.addingTimeInterval(dayInterval * Double(fraction))
                    Text(scrubTime, format: .dateTime.hour().minute().second())
                        .font(.caption2.weight(.medium).monospacedDigit())
                        // 0.5.0 Liquid Glass — scrub-position bubble.
                        .reolensGlassToast()
                        .offset(x: max(0, min(x - 32, stripWidth - 64)), y: -22)
                        .accessibilityHidden(true)
                }
            }

            // Hour-tick labels — 0, 6, 12, 18, 24 — quick orientation
            // for the strip without rendering full chrome.
            GeometryReader { geo in
                let labels = [0, 6, 12, 18, 24]
                ZStack(alignment: .leading) {
                    ForEach(labels, id: \.self) { hour in
                        let fraction = Double(hour) / 24.0
                        Text(hour == 24 ? "24" : "\(hour)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .offset(x: geo.size.width * fraction - (hour == 0 ? 0 : hour == 24 ? 14 : 6))
                    }
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private struct SegmentFrame {
        let x: CGFloat
        let width: CGFloat
    }

    /// DragGesture used to scrub a cursor across the strip. While
    /// scrubbing, `scrubX` drives a time-cursor overlay; on release,
    /// if the scrub landed on a file, we trigger playback. This
    /// gives the user a more controllable "jump to a point in the
    /// day" idiom than the tap-each-segment-individually model.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scrubX = value.location.x
            }
            .onEnded { value in
                defer { scrubX = nil }
                guard width > 0 else { return }
                let fraction = max(0, min(1, value.location.x / width))
                let cal = Calendar.current
                let startOfDay = cal.startOfDay(for: day)
                let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                let dayInterval = endOfDay.timeIntervalSince(startOfDay)
                let scrubbedTime = startOfDay.addingTimeInterval(dayInterval * Double(fraction))
                // Containment first — play the file that includes
                // this exact time. Falls back to nearest start if
                // the user landed in a gap (and the closest is within
                // a 90-second window — beyond that, treat the gap as
                // empty and don't auto-play anything stale).
                if let containing = files.first(where: { file in
                    guard let s = file.startDate, let e = file.endDate else { return false }
                    return s <= scrubbedTime && scrubbedTime <= e
                }) {
                    onTapSegment(containing)
                    return
                }
                let withinWindow: TimeInterval = 90
                let nearest = files.compactMap { file -> (SearchFile, TimeInterval)? in
                    guard let s = file.startDate else { return nil }
                    return (file, abs(s.timeIntervalSince(scrubbedTime)))
                }
                if let (closest, dist) = nearest.min(by: { $0.1 < $1.1 }), dist < withinWindow {
                    onTapSegment(closest)
                }
            }
    }

    private func frame(for file: SearchFile, startOfDay: Date, dayInterval: TimeInterval, width: CGFloat) -> SegmentFrame? {
        guard let s = file.startDate, let e = file.endDate, dayInterval > 0, width > 0 else { return nil }
        let clampedStart = max(s, startOfDay)
        let clampedEnd = min(e, startOfDay.addingTimeInterval(dayInterval))
        guard clampedEnd > clampedStart else { return nil }
        let startFraction = clampedStart.timeIntervalSince(startOfDay) / dayInterval
        let endFraction = clampedEnd.timeIntervalSince(startOfDay) / dayInterval
        return SegmentFrame(
            x: width * CGFloat(startFraction),
            width: width * CGFloat(endFraction - startFraction)
        )
    }

    private func eventX(for event: TimestampedAIEvent, startOfDay: Date, dayInterval: TimeInterval, width: CGFloat) -> CGFloat? {
        let endOfDay = startOfDay.addingTimeInterval(dayInterval)
        guard event.timestamp >= startOfDay, event.timestamp <= endOfDay, dayInterval > 0 else { return nil }
        let fraction = event.timestamp.timeIntervalSince(startOfDay) / dayInterval
        return width * CGFloat(fraction)
    }

    private func eventColor(for event: TimestampedAIEvent) -> Color {
        guard let detection = event.detectionType else { return .yellow }
        switch detection {
        case .person, .face, .visitor: return .green
        case .vehicle: return .blue
        case .packageDelivery: return .brown
        case .pet: return .orange
        case .motion: return .yellow
        case .other: return .secondary
        }
    }

    private func accessibilityLabel(for file: SearchFile) -> String {
        guard let start = file.startDate else { return file.name }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let label = formatter.string(from: start)
        if let duration = file.durationSeconds {
            let mins = Int(duration) / 60
            return "Recording at \(label), \(mins) minutes"
        }
        return "Recording at \(label)"
    }
}
