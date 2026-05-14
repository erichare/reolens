import SwiftUI
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.app", category: "motion-schedule")

/// 0.6.0 Slice 12b — UI for editing the per-channel motion-detection
/// schedule plus optional per-AI-tag override schedules.
///
/// Flow: open → `GetMdAlarm` → render `WeeklyScheduleEditor` (main
/// schedule, plus a tag-picker that opens a secondary editor for
/// per-tag overrides) → user edits → "Apply" diffs against the
/// original and `SetMdAlarm`s.
///
/// Capability fallback identical to `RecordingScheduleView`: rspCode
/// = -9 turns the editor read-only with a notice.
public struct MotionScheduleView: View {
    public let session: CameraSession
    public let channel: ChannelStatus

    public init(session: CameraSession, channel: ChannelStatus) {
        self.session = session
        self.channel = channel
    }

    @State private var workingMain: WeeklySchedule = WeeklySchedule()
    @State private var originalMain: WeeklySchedule = WeeklySchedule()
    @State private var workingTagOverrides: [String: WeeklySchedule] = [:]
    @State private var originalTagOverrides: [String: WeeklySchedule] = [:]
    @State private var loadPhase: SchedulePhase = .loading
    @State private var applyError: String?
    @State private var applyToast: String?
    /// Currently editing this tag's override schedule (sheet
    /// destination). nil = editing the main channel schedule.
    @State private var editingTag: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch loadPhase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading motion schedule…").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()

            case .ready, .unsupported:
                editor

            case .error(let msg):
                ContentUnavailableView {
                    Label("Couldn't read motion schedule", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg).font(.caption).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            }
        }
        .padding()
        .task { await load() }
        .sheet(item: Binding(
            get: { editingTag.map { TagEdit(tag: $0) } },
            set: { editingTag = $0?.tag }
        )) { edit in
            tagOverrideSheet(for: edit.tag)
        }
        .overlay(alignment: .bottom) {
            if let applyToast {
                Text(applyToast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.85), in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: applyToast)
    }

    private struct TagEdit: Identifiable {
        let tag: String
        var id: String { tag }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When can motion / AI events on this camera fire alarms? Tap or drag cells to toggle.")
                .font(.caption)
                .foregroundStyle(.secondary)

            WeeklyScheduleEditor(
                schedule: $workingMain,
                readOnlyReason: loadPhase == .unsupported
                    ? "Motion-detection schedules aren't supported on this camera's firmware. Showing the current schedule for reference."
                    : nil
            )

            // Per-tag overrides — only relevant when the channel
            // already detects AI tags. Listed alongside the main
            // schedule so users see at a glance which tags differ.
            if loadPhase == .ready {
                Divider()
                Text("Per-tag overrides")
                    .font(.subheadline.weight(.semibold))
                Text("Optional: override the schedule for a specific tag. \"Quiet driveway 06:00-09:00 except people\" → leave the main schedule on but override the people tag to suppress that window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.commonTagsForOverride, id: \.self) { tag in
                    tagOverrideRow(tag)
                }
            }

            HStack(spacing: 12) {
                if let applyError {
                    Label(applyError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button {
                    workingMain = originalMain
                    workingTagOverrides = originalTagOverrides
                    applyError = nil
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(loadPhase == .unsupported || !hasChanges)
                Button {
                    Task { await apply() }
                } label: {
                    Label("Apply", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loadPhase == .unsupported || !hasChanges)
            }
        }
    }

    private func tagOverrideRow(_ tag: String) -> some View {
        HStack {
            Label(tagLabel(tag), systemImage: tagSystemImage(tag))
                .labelStyle(.titleAndIcon)
            Spacer()
            if let schedule = workingTagOverrides[tag] {
                Text("\(schedule.activeHourCount) of 168 hours")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Inherits main schedule")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                if workingTagOverrides[tag] == nil {
                    // Initialize from the main schedule when adding
                    // a new override so the user starts from "same
                    // as today" and edits from there.
                    workingTagOverrides[tag] = workingMain
                }
                editingTag = tag
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(workingTagOverrides[tag] == nil ? "Add an override schedule for \(tagLabel(tag))" : "Edit \(tagLabel(tag)) override")
            if workingTagOverrides[tag] != nil {
                Button(role: .destructive) {
                    workingTagOverrides[tag] = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove the per-tag override for \(tagLabel(tag))")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func tagOverrideSheet(for tag: String) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Override schedule for \(tagLabel(tag))")
                    .font(.headline)
                Text("This schedule replaces the main schedule for the \(tagLabel(tag)) tag specifically. When the main schedule is on but this is off (or vice versa), only \(tagLabel(tag)) events follow this table.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let bindingSchedule = bindingForTag(tag) {
                    WeeklyScheduleEditor(schedule: bindingSchedule)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(tagLabel(tag))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { editingTag = nil }
                }
            }
        }
    }

    private func bindingForTag(_ tag: String) -> Binding<WeeklySchedule>? {
        guard workingTagOverrides[tag] != nil else { return nil }
        return Binding(
            get: { self.workingTagOverrides[tag] ?? WeeklySchedule() },
            set: { self.workingTagOverrides[tag] = $0 }
        )
    }

    private var hasChanges: Bool {
        workingMain != originalMain || workingTagOverrides != originalTagOverrides
    }

    // MARK: - Networking

    private func load() async {
        loadPhase = .loading
        let cmd = Commands.getMotionSchedule(channel: channel.channel)
        do {
            let envelope = try await session.client.send(cmd, as: MotionScheduleEnvelope.self)
            guard let parsed = WeeklySchedule(scheduleString: envelope.MdAlarm.scheduleTable.mainStream) else {
                loadPhase = .error("Camera returned a schedule we couldn't parse.")
                return
            }
            originalMain = parsed
            workingMain = parsed

            // Tag overrides — each row's `table.mainStream` follows
            // the same 168-char encoding.
            var overrides: [String: WeeklySchedule] = [:]
            for tagSched in envelope.MdAlarm.perTagOverrides ?? [] {
                if let s = WeeklySchedule(scheduleString: tagSched.table.mainStream) {
                    overrides[tagSched.tag] = s
                }
            }
            originalTagOverrides = overrides
            workingTagOverrides = overrides

            loadPhase = .ready
        } catch let cgi as CGIError where cgi.rspCode == CGIErrorCode.notSupport.rawValue {
            originalMain = WeeklySchedule()
            workingMain = originalMain
            originalTagOverrides = [:]
            workingTagOverrides = [:]
            loadPhase = .unsupported
        } catch let reolink as ReolinkClientError {
            // Same rationale as RecordingScheduleView — render the
            // actual case + payload instead of the opaque NSError
            // bridge string the user would otherwise see.
            log.error("GetMdAlarm failed: \(String(describing: reolink), privacy: .public)")
            loadPhase = .error(reolink.description)
        } catch {
            log.error("GetMdAlarm failed: \(String(describing: error), privacy: .public)")
            loadPhase = .error(String(describing: error))
        }
    }

    private func apply() async {
        guard loadPhase == .ready else { return }
        applyError = nil
        let mainTable = ScheduleTable(mainStream: workingMain.scheduleString)
        guard mainTable.isWellFormed else {
            applyError = "Schedule didn't pass the 168-character validator. Revert and try again."
            return
        }
        let overrides: [TagSchedule] = workingTagOverrides.map { tag, schedule in
            TagSchedule(tag: tag, table: ScheduleTable(mainStream: schedule.scheduleString))
        }
        let settings = MotionScheduleSettings(
            channel: channel.channel,
            scheduleTable: mainTable,
            perTagOverrides: overrides.isEmpty ? nil : overrides
        )
        do {
            try await session.client.sendIgnoringValue(Commands.setMotionSchedule(settings))
            originalMain = workingMain
            originalTagOverrides = workingTagOverrides
            applyToast = "Motion schedule applied"
            Task {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { applyToast = nil }
            }
        } catch let cgi as CGIError where cgi.rspCode == CGIErrorCode.notSupport.rawValue {
            applyError = "Camera firmware rejected the write — motion schedule isn't writable here. (Reolink rspCode -9: \(cgi.detail ?? "no detail"))"
            loadPhase = .unsupported
        } catch let reolink as ReolinkClientError {
            applyError = reolink.description
        } catch {
            applyError = String(describing: error)
        }
    }

    // MARK: - Tag taxonomy helpers

    /// Tags users most often want to override. Matches Reolink's wire
    /// vocabulary so they round-trip through `findAlarmVideo` and
    /// `GetAiState` without translation. We expose the human-readable
    /// label in the UI and the raw string in the wire payload.
    private static let commonTagsForOverride: [String] = [
        "people", "vehicle", "dog_cat", "package", "face"
    ]

    private func tagLabel(_ tag: String) -> String {
        switch tag {
        case "people": return "People"
        case "vehicle": return "Vehicle"
        case "dog_cat": return "Animal"
        case "package": return "Package"
        case "face": return "Face"
        default: return tag.capitalized
        }
    }

    private func tagSystemImage(_ tag: String) -> String {
        switch tag {
        case "people": return "person.fill"
        case "vehicle": return "car.fill"
        case "dog_cat": return "pawprint.fill"
        case "package": return "shippingbox.fill"
        case "face": return "face.smiling.fill"
        default: return "circle.fill"
        }
    }
}
