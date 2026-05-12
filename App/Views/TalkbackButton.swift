import SwiftUI
import ReolinkBaichuan
import AppShared

/// Push-to-talk button. Holding the button captures the Mac mic, ADPCM-encodes
/// at 16 kHz mono, and streams to the camera via Baichuan's `MSG_ID_TALK`.
struct TalkbackButton: View {
    let session: CameraSession
    let channelID: UInt8

    @State private var talk: BaichuanTalkbackSession?
    @State private var isTalking = false
    @State private var error: String?

    var body: some View {
        Button {
            // press handled via gesture below
        } label: {
            Label(isTalking ? "Talking…" : "Hold to Talk", systemImage: isTalking ? "mic.fill" : "mic")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isTalking ? Color.red : Color.primary)
        .help(error ?? "Push-to-talk over Reolink Baichuan")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isTalking { Task { await start() } } }
                .onEnded { _ in if isTalking { Task { await stop() } } }
        )
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
