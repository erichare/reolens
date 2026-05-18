import SwiftUI
import OSLog
import UniformTypeIdentifiers

#if os(iOS) || os(visionOS)
import UIKit
#endif

private let log = Logger(subsystem: "com.reolens.app", category: "playback.sheet")

/// The single shared recording playback sheet — used by per-camera
/// `RecordingsView` (iOS + macOS) and by `AllRecordingsView`.
///
/// Pre-rewrite each platform had its own variant with different
/// capabilities and an incompatible `PlayableRecording` shape. This
/// file consolidates the three into one. Streaming starts on `.task`
/// via `RecordingPlaybackEngine`; the engine surfaces an AVPlayer
/// the moment AVPlayer reports `.readyToPlay` — first-frame latency
/// becomes ~1 round trip instead of "full file download."
///
/// Export goes through the Menu in the header. Each destination
/// triggers a small staging job, then hands the resulting file to
/// the platform-native surface:
///   * `.file`   → SwiftUI `.fileExporter` (works on iOS + macOS).
///   * `.photos` → `ClipPhotosSaver` (iOS / iPadOS / visionOS only).
///   * `.share`  → `ShareLink` over `PlayableRecordingTransferable`.
public struct RecordingPlayerSheet: View {

    public let recording: PlayableRecording
    @Environment(\.dismiss) private var dismiss
    @State private var engine: RecordingPlaybackEngine
    @State private var startedAt: Date?
    @State private var exportState: ExportState = .idle
    @State private var fileExportingDocument: ExportedClipDocument?
    @State private var isPresentingFileExporter: Bool = false
    @State private var isPresentingShareSheet: Bool = false
    @State private var shareTransferable: PlayableRecordingTransferable?

    public init(recording: PlayableRecording) {
        self.recording = recording
        self._engine = State(wrappedValue: RecordingPlaybackEngine(recording: recording))
    }

    public var body: some View {
        // The frame() lower-bound only applies on macOS — iOS sheets
        // are sized by the system presentation chrome. Forcing
        // minWidth: 720 on iPhone (~390 pt) overflows the sheet, which
        // clips the toolbar quality picker to a single character and
        // pushes the AVPlayer surface off-axis.
        sizedChrome
            .task(id: recording.id) {
                startedAt = Date()
                engine.start()
            }
            .onDisappear {
                engine.stop()
            }
            // SwiftUI `.fileExporter` works on iOS + macOS. Triggered
            // when the Save to Files / Save As… flow has staged its
            // MP4 and built a document representation.
            .fileExporter(
                isPresented: $isPresentingFileExporter,
                document: fileExportingDocument,
                contentType: .mpeg4Movie,
                defaultFilename: fileExportingDocument?.suggestedFilename
            ) { result in
                handleFileExporterResult(result)
            }
            // Share path. iOS + macOS both honor ShareLink-from-
            // Transferable; the system chrome owns the "Preparing…"
            // indicator while `PlayableRecordingTransferable`'s
            // FileRepresentation closure stages the bytes.
            .sheet(isPresented: $isPresentingShareSheet) {
                shareSheetContent
            }
            .overlay(alignment: .center) { exportOverlay }
    }

    @ViewBuilder
    private var sizedChrome: some View {
        #if os(macOS)
        platformChrome
            .frame(minWidth: 720, idealWidth: 880, minHeight: 480, idealHeight: 560)
        #else
        platformChrome
        #endif
    }

    @ViewBuilder
    private var platformChrome: some View {
        #if os(iOS) || os(visionOS)
        NavigationStack {
            VStack(spacing: 0) {
                if recording.canSwitchQuality || streamingStatusLine != nil {
                    iosStatusBanner
                }
                content
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarExportMenu
                }
            }
        }
        #else
        VStack(spacing: 0) {
            RecordingPlayerHeader(
                engine: engine,
                recording: recording,
                onExport: { destination in
                    Task { await beginExport(to: destination) }
                },
                onDismiss: { dismiss() },
                startedAt: startedAt
            )
            Divider()
            content
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch engine.status {
        case .idle, .loading:
            RecordingDownloadProgressPanel(
                bytesReceived: engine.bytesReceived,
                totalBytes: engine.totalBytes,
                startedAt: startedAt,
                title: "Starting playback…"
            )
        case .ready:
            if let player = engine.player {
                AVPlayerSurface(player: player)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                RecordingDownloadProgressPanel(
                    bytesReceived: engine.bytesReceived,
                    totalBytes: engine.totalBytes,
                    startedAt: startedAt,
                    title: "Starting playback…"
                )
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't play this recording", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") { engine.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var headerTitle: String {
        recording.startDate?.formatted(date: .abbreviated, time: .shortened)
            ?? recording.displayName
    }

    // MARK: - iOS toolbar pieces

    #if os(iOS) || os(visionOS)
    /// Slim banner directly under the nav bar. Hosts the quality
    /// picker (when there's more than one variant) and the streaming
    /// progress line so neither competes with the title for toolbar
    /// space — iPhone nav bars truncate aggressively once the title
    /// is even a few characters too long.
    @ViewBuilder
    private var iosStatusBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            if recording.canSwitchQuality {
                Picker("Quality", selection: Binding(
                    get: { engine.currentQuality },
                    set: { engine.switchQuality(to: $0) }
                )) {
                    ForEach(recording.availableQualities, id: \.self) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            Spacer(minLength: 0)
            if let line = streamingStatusLine {
                Text(line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Streaming progress: \(line)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var toolbarExportMenu: some View {
        Menu {
            ForEach(RecordingExportDestination.available) { destination in
                Button {
                    Task { await beginExport(to: destination) }
                } label: {
                    Label(destination.label, systemImage: destination.systemImage)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }
    #endif

    /// Streaming bytes/throughput status line — same format on iOS
    /// (banner) and macOS (header). Returns nil when the file is
    /// fully cached so the chrome strips itself once playback no
    /// longer depends on the network.
    private var streamingStatusLine: String? {
        if engine.isFullyCached { return nil }
        let received = engine.bytesReceived
        guard received > 0 else { return nil }
        let total = max(engine.totalBytes, received)
        let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let totalStr = total > received
            ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            : nil
        let rateStr = throughputString
        var parts: [String] = []
        if let totalStr {
            parts.append("\(receivedStr) / \(totalStr)")
        } else {
            parts.append(receivedStr)
        }
        if let rateStr { parts.append(rateStr) }
        return parts.joined(separator: " · ")
    }

    private var throughputString: String? {
        guard let startedAt, engine.bytesReceived > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else { return nil }
        let rate = Int64(Double(engine.bytesReceived) / elapsed)
        return "\(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s"
    }

    // MARK: - Export overlay

    @ViewBuilder
    private var exportOverlay: some View {
        switch exportState {
        case .idle, .ready:
            EmptyView()
        case .preparing(let description):
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") { exportState = .idle }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Couldn't export")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Done") { exportState = .idle }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
        case .succeeded(let message):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text(message)
                    .font(.headline)
                Button("Done") { exportState = .idle }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Share sheet

    @ViewBuilder
    private var shareSheetContent: some View {
        if let item = shareTransferable {
            #if os(iOS) || os(visionOS)
            VStack(spacing: 12) {
                Text("Share recording")
                    .font(.title3.weight(.semibold))
                Text("Pick where to send the clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareLink(
                    item: item,
                    preview: SharePreview(item.suggestedFilename)
                ) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                Button("Cancel") { isPresentingShareSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .presentationDetents([.medium])
            #else
            VStack(spacing: 12) {
                Text("Share recording").font(.title3.weight(.semibold))
                ShareLink(item: item, preview: SharePreview(item.suggestedFilename))
                Button("Cancel") { isPresentingShareSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(minWidth: 360, minHeight: 200)
            #endif
        } else {
            ProgressView().padding(40)
        }
    }

    // MARK: - Export actions

    private enum ExportState: Equatable, Sendable {
        case idle
        case preparing(String)
        case ready
        case succeeded(String)
        case failed(String)
    }

    private func beginExport(to destination: RecordingExportDestination) async {
        exportState = .preparing("Preparing \(destination.label.lowercased())…")
        do {
            switch destination {
            case .file:
                let url = try await RecordingExportRouter.prepareStagedFile(
                    recording: recording,
                    quality: engine.currentQuality,
                    trim: recording.initialTrim,
                    engine: engine
                )
                let data = try Data(contentsOf: url)
                fileExportingDocument = ExportedClipDocument(
                    data: data,
                    suggestedFilename: RecordingExportRouter.suggestedFilename(
                        for: recording,
                        quality: engine.currentQuality,
                        trimmed: recording.initialTrim != nil
                    )
                )
                exportState = .ready
                isPresentingFileExporter = true

            case .photos:
                let url = try await RecordingExportRouter.prepareStagedFile(
                    recording: recording,
                    quality: engine.currentQuality,
                    trim: recording.initialTrim,
                    engine: engine
                )
                let result = await ClipPhotosSaver.save(videoFileURL: url)
                switch result {
                case .saved:
                    exportState = .succeeded("Saved to Photos.")
                case .denied:
                    exportState = .failed("Photos access denied. Enable it in Settings to save clips.")
                case .unsupported:
                    exportState = .failed("Saving to Photos isn't supported on this platform.")
                case .noFile:
                    exportState = .failed("Couldn't prepare the clip file.")
                case .failed(let msg):
                    exportState = .failed(msg)
                }

            case .share:
                // The transferable handles its own staging; we just
                // build it and present the share-sheet wrapper.
                shareTransferable = PlayableRecordingTransferable(
                    recording: recording,
                    quality: engine.currentQuality,
                    trim: recording.initialTrim
                )
                exportState = .idle
                isPresentingShareSheet = true
            }
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    private func handleFileExporterResult(_ result: Result<URL, any Error>) {
        switch result {
        case .success:
            exportState = .succeeded("Saved.")
        case .failure(let error):
            // `.fileExporter` reports a cancellation as a failure
            // with `CocoaError.userCancelled`. Treat that as a
            // benign dismiss, not an error.
            let nsError = error as NSError
            if nsError.domain == CocoaError.errorDomain,
               nsError.code == CocoaError.userCancelled.rawValue {
                exportState = .idle
            } else {
                exportState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - FileDocument

/// Tiny `FileDocument` adapter so SwiftUI's `.fileExporter` can write
/// a pre-staged MP4 to the user's chosen location. Holds the bytes
/// in-memory — fine for typical recording sizes (≤ a few hundred MB)
/// and the only way to bridge `.fileExporter`, which doesn't accept
/// "I have a file at this URL" out of the box.
public struct ExportedClipDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] { [.mpeg4Movie] }
    public static var writableContentTypes: [UTType] { [.mpeg4Movie] }

    public let data: Data
    public let suggestedFilename: String

    public init(data: Data, suggestedFilename: String) {
        self.data = data
        self.suggestedFilename = suggestedFilename
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        self.suggestedFilename = configuration.file.filename ?? "Recording.mp4"
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
