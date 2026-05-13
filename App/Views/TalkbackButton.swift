import SwiftUI
import ReolinkBaichuan
import AppShared

/// Push-to-talk button. Holding the button captures the Mac mic,
/// ADPCM-encodes at 16 kHz mono, and streams to the camera via
/// Baichuan's `MSG_ID_TALK`.
///
/// 0.5.1 redesign: big blue circular mic button rather than a small
/// bordered pill. The push-to-talk gesture is the same; the visual
/// is now obvious and inviting rather than blending into the rest
/// of the control bar chrome.
struct TalkbackButton: View {
    let session: CameraSession
    let channelID: UInt8

    @State private var talk: BaichuanTalkbackSession?
    @State private var isTalking = false
    @State private var error: String?

    /// 56 pt circle keeps the button comfortably hit-targeted on a
    /// trackpad while not dominating the control bar. Red when
    /// talking so the live state is unmistakable.
    private static let diameter: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isTalking ? Color.red : Color.accentColor)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .shadow(color: (isTalking ? Color.red : Color.accentColor).opacity(0.35),
                            radius: isTalking ? 10 : 4,
                            x: 0,
                            y: 2)
                Image(systemName: isTalking ? "mic.fill" : "mic")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isTalking ? 1.05 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTalking)
            .contentShape(Circle())
            .accessibilityLabel(isTalking ? "Talking — release to stop" : "Hold to talk")
            .accessibilityAddTraits(.isButton)
            .help(error ?? (isTalking ? "Release to stop talking." : "Hold to talk over Reolink Baichuan."))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isTalking { Task { await start() } } }
                    .onEnded { _ in if isTalking { Task { await stop() } } }
            )
            Text(isTalking ? "Talking…" : "Hold to talk")
                .font(.caption)
                .foregroundStyle(isTalking ? Color.red : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func start() async {
        guard !isTalking, let client = session.baichuanClient else {
            error = session.baichuanClient == nil ? "Baichuan not connected yet" : nil
            return
        }
        let session = BaichuanTalkbackSession(client: client, channelID: channelID)
        self.talk = session
        do {
            try await session.start()
            isTalking = true
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func stop() async {
        await talk?.stop()
        talk = nil
        isTalking = false
    }
}
