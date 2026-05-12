import SwiftUI
import AVFoundation
import OSLog
import ReolinkBaichuan
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "ios-talk")

/// Push-to-talk button for iOS/iPadOS. Holding captures mic audio,
/// ADPCM-encodes 16 kHz mono, and streams to the camera via Baichuan
/// `MSG_ID_TALK`.
///
/// Differences from the macOS counterpart:
/// - Configures `AVAudioSession` (`.playAndRecord` + voice-chat mode +
///   allow Bluetooth + duck others) BEFORE asking
///   `BaichuanTalkbackSession` to start. macOS doesn't have
///   `AVAudioSession`; iOS won't capture mic without an active session
///   in a record-capable category.
/// - 44pt minimum hit target (HIG).
/// - Haptic feedback at start/stop.
struct TalkbackButtonView: View {
    let session: CameraSession
    let channelID: UInt8

    @State private var talk: BaichuanTalkbackSession?
    @State private var isTalking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 6) {
            Button { /* gesture below */ } label: {
                Label(
                    isTalking ? "Talking…" : "Hold to Talk",
                    systemImage: isTalking ? "mic.fill" : "mic"
                )
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(isTalking ? .red : .accentColor)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isTalking { Task { await start() } } }
                    .onEnded { _ in if isTalking { Task { await stop() } } }
            )

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func start() async {
        guard !isTalking else { return }
        guard let client = session.baichuanClient else {
            error = "Baichuan not connected yet"
            return
        }
        do {
            try configureAudioSession()
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
            return
        }
        let talkSession = BaichuanTalkbackSession(client: client, channelID: channelID)
        self.talk = talkSession
        do {
            try await talkSession.start()
            await MainActor.run {
                isTalking = true
                error = nil
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } catch {
            log.error("Talkback start failed: \(error.localizedDescription, privacy: .public)")
            self.error = "\(error.localizedDescription)"
        }
    }

    private func stop() async {
        await talk?.stop()
        talk = nil
        deactivateAudioSession()
        await MainActor.run {
            isTalking = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// `.playAndRecord` lets us run capture + camera audio
    /// simultaneously; `.voiceChat` mode applies AEC and noise
    /// suppression matched to two-way intercom use. `.allowBluetooth`
    /// supports AirPods / Bluetooth headsets. `.duckOthers` lowers
    /// other audio while we're talking through the camera.
    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .duckOthers, .defaultToSpeaker]
        )
        try s.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
