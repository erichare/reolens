import SwiftUI
import AVFoundation
import OSLog
import ReolinkBaichuan
import AppShared

private let log = Logger(subsystem: "com.reolens.app", category: "ios-talk")

/// Push-to-talk button for iOS / iPadOS. Holding captures mic audio,
/// ADPCM-encodes 16 kHz mono, and streams to the camera via Baichuan
/// `MSG_ID_TALK`.
///
/// 0.5.1 redesign: big blue circular mic button, centered in its
/// container. Replaces the previous "Hold to Talk" pill which read
/// as just another bordered control. The big circle is unmistakable
/// as a push-to-talk affordance.
///
/// Differences from the macOS counterpart:
/// - Configures `AVAudioSession` (`.playAndRecord` + voice-chat mode +
///   allow Bluetooth + duck others) BEFORE asking
///   `BaichuanTalkbackSession` to start. macOS doesn't have
///   `AVAudioSession`; iOS won't capture mic without an active session
///   in a record-capable category.
/// - Hit target is 88 pt (comfortably above the 44 pt HIG minimum,
///   and intentionally large because push-to-talk needs to be
///   confidently held).
/// - Haptic feedback at start/stop.
struct TalkbackButtonView: View {
    let session: CameraSession
    let channelID: UInt8

    @State private var talk: BaichuanTalkbackSession?
    @State private var isTalking = false
    @State private var error: String?

    /// 88 pt circle. Comfortable thumb target and visually
    /// proportional to the live tile that sits above it.
    private static let diameter: CGFloat = 88

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isTalking ? Color.red : Color.accentColor)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .shadow(color: (isTalking ? Color.red : Color.accentColor).opacity(0.4),
                            radius: isTalking ? 14 : 6,
                            x: 0,
                            y: 3)
                Image(systemName: isTalking ? "mic.fill" : "mic")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isTalking ? 1.06 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isTalking)
            .contentShape(Circle())
            .accessibilityLabel(isTalking ? "Talking — release to stop" : "Hold to talk")
            .accessibilityAddTraits(.isButton)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isTalking { Task { await start() } } }
                    .onEnded { _ in if isTalking { Task { await stop() } } }
            )

            Text(isTalking ? "Talking…" : "Hold to talk")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isTalking ? Color.red : .secondary)

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
