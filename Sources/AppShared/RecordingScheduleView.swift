import SwiftUI
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.app", category: "recording-schedule")

/// 0.6.0 Slice 12 — UI for editing the weekly recording schedule on
/// a single channel.
///
/// Flow: open → `GetRec` → render `WeeklyScheduleEditor` → user edits
/// → "Apply" diffs against the original and `SetRec`s. Capability
/// fallback: if the camera responds with `-9` (not supported), the
/// editor renders read-only with a "schedule not supported on this
/// firmware" notice.
public struct RecordingScheduleView: View {
    public let session: CameraSession
    public let channel: ChannelStatus

    public init(session: CameraSession, channel: ChannelStatus) {
        self.session = session
        self.channel = channel
    }

    @State private var working: WeeklySchedule = WeeklySchedule()
    @State private var original: WeeklySchedule = WeeklySchedule()
    @State private var loadPhase: SchedulePhase = .loading
    @State private var applyError: String?
    @State private var applyToast: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch loadPhase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading current schedule…").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()

            case .ready, .unsupported:
                editor

            case .error(let msg):
                ContentUnavailableView {
                    Label("Couldn't read schedule", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg).font(.caption).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            }
        }
        .padding()
        .task { await load() }
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap or drag cells to toggle. Each cell is one hour, Sunday → Saturday × 00:00 → 23:00.")
                .font(.caption)
                .foregroundStyle(.secondary)
            WeeklyScheduleEditor(
                schedule: $working,
                readOnlyReason: loadPhase == .unsupported
                    ? "Recording schedules aren't supported on this camera's firmware. Showing the current schedule for reference."
                    : nil
            )
            HStack(spacing: 12) {
                if let applyError {
                    Label(applyError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button {
                    working = original
                    applyError = nil
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(loadPhase == .unsupported || working == original)
                Button {
                    Task { await apply() }
                } label: {
                    Label("Apply", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loadPhase == .unsupported || working == original)
            }
        }
    }

    // MARK: - Networking

    private func load() async {
        loadPhase = .loading
        let cmd = Commands.getRecordingSchedule(channel: channel.channel)
        do {
            let envelope = try await session.client.send(cmd, as: RecordingScheduleEnvelope.self)
            guard let parsed = WeeklySchedule(scheduleString: envelope.Rec.scheduleTable.mainStream) else {
                loadPhase = .error("Camera returned a schedule we couldn't parse.")
                return
            }
            original = parsed
            working = parsed
            loadPhase = .ready
        } catch let cgi as CGIError where cgi.rspCode == CGIErrorCode.notSupport.rawValue {
            // -9 → firmware doesn't expose the schedule. Show a
            // placeholder so the user understands what they're seeing.
            original = WeeklySchedule()
            working = original
            loadPhase = .unsupported
        } catch let reolink as ReolinkClientError {
            // 0.6.0 — `ReolinkClientError`'s default `localizedDescription`
            // is Swift's opaque "(Domain error N.)" bridge string, which
            // told the user nothing. Render the actual case + payload
            // via `CustomStringConvertible.description` instead.
            log.error("GetRec failed: \(String(describing: reolink), privacy: .public)")
            loadPhase = .error(reolink.description)
        } catch {
            log.error("GetRec failed: \(String(describing: error), privacy: .public)")
            loadPhase = .error(String(describing: error))
        }
    }

    private func apply() async {
        guard loadPhase == .ready else { return }
        applyError = nil
        let table = ScheduleTable(mainStream: working.scheduleString)
        guard table.isWellFormed else {
            applyError = "Schedule didn't pass the 168-character validator. Reset and try again."
            return
        }
        let settings = RecordingScheduleSettings(channel: channel.channel, scheduleTable: table)
        do {
            try await session.client.sendIgnoringValue(Commands.setRecordingSchedule(settings))
            original = working
            applyToast = "Schedule applied"
            Task {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { applyToast = nil }
            }
        } catch let cgi as CGIError where cgi.rspCode == CGIErrorCode.notSupport.rawValue {
            applyError = "Camera firmware rejected the write — schedule isn't writable here. (Reolink rspCode -9: \(cgi.detail ?? "no detail"))"
            loadPhase = .unsupported
        } catch let reolink as ReolinkClientError {
            applyError = reolink.description
        } catch {
            applyError = String(describing: error)
        }
    }
}
