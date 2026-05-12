import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Full-screen single-channel view. Three tabs mirror the macOS app's
/// per-channel detail: Live, Recordings, Settings. Phase 4 wired Live
/// + PTZ + Talkback; Phase 5 wires the Recordings tab; Settings comes
/// in a follow-up release.
///
/// The Live tab supports Picture-in-Picture so the user can keep an eye
/// on a camera while using another app. PiP is routed through
/// `LiveVideoPiP` which targets the player's `AVSampleBufferDisplayLayer`
/// directly — same display layer the inline view uses, so entering PiP
/// is a smooth handoff with no extra decode.
struct SingleChannelView: View {
    let session: CameraSession
    let channel: ChannelStatus
    @State private var pipController: LiveVideoPiP?
    @State private var attachedPlayerID: ObjectIdentifier?

    var body: some View {
        TabView {
            LiveTab(session: session, channel: channel, pipController: $pipController, attachedPlayerID: $attachedPlayerID)
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            RecordingsView(session: session, channel: channel)
                .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
        }
        .navigationTitle(channel.name ?? "Channel \(channel.channel + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let pip = pipController {
                ToolbarItem(placement: .primaryAction) {
                    PiPToolbarButton(controller: pip)
                }
            }
        }
    }
}

/// Toolbar button that toggles Picture-in-Picture. Greyed out until the
/// system signals that PiP is possible (display layer attached to a
/// window, screen recording not in progress, etc.).
private struct PiPToolbarButton: View {
    @ObservedObject private var observable: PiPObservable

    init(controller: LiveVideoPiP) {
        _observable = ObservedObject(wrappedValue: PiPObservable(controller: controller))
    }

    var body: some View {
        Button {
            if observable.isActive {
                observable.controller.stop()
            } else {
                observable.controller.start()
            }
        } label: {
            Label(
                observable.isActive ? "Stop Picture-in-Picture" : "Start Picture-in-Picture",
                systemImage: observable.isActive
                    ? "pip.exit"
                    : "pip.enter"
            )
        }
        .disabled(!observable.isPossible)
        .accessibilityLabel(observable.isActive ? "Stop Picture-in-Picture" : "Start Picture-in-Picture")
    }
}

/// Bridges `LiveVideoPiP`'s KVO-tracked `isActive` / `isPossible` into
/// SwiftUI's ObservableObject world so the button updates without
/// requiring the @Observable macro on a class that needs to inherit
/// from NSObject for KVO.
@MainActor
private final class PiPObservable: ObservableObject {
    let controller: LiveVideoPiP
    @Published var isActive: Bool = false
    @Published var isPossible: Bool = false

    private var observations: [NSKeyValueObservation] = []

    init(controller: LiveVideoPiP) {
        self.controller = controller
        self.isActive = controller.isActive
        self.isPossible = controller.isPossible
        observations.append(
            controller.observe(\.isActive, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in
                    self?.isActive = value
                }
            }
        )
        observations.append(
            controller.observe(\.isPossible, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in
                    self?.isPossible = value
                }
            }
        )
    }

    deinit {
        for obs in observations { obs.invalidate() }
    }
}

/// "Live" tab: the main-stream tile + PTZ controls + talkback button.
/// Pulled into its own struct so the parent TabView gets a clean child.
///
/// The live tile supports **pinch-to-zoom and drag-to-pan** for digital
/// zoom on still frames you want to inspect (license plate, package
/// label, etc.). Double-tap resets to fit. The zoom is purely visual —
/// no PTZ command is sent; for optical pan/tilt/zoom on supported
/// cameras, use the PTZ control bar below the tile.
private struct LiveTab: View {
    let session: CameraSession
    let channel: ChannelStatus
    @Binding var pipController: LiveVideoPiP?
    @Binding var attachedPlayerID: ObjectIdentifier?

    @State private var zoom: CGFloat = 1.0
    @State private var anchorZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var anchorPan: CGSize = .zero

    /// Allowed zoom range. 1× is "fit" — anything below would just letterbox
    /// the camera; 4× is enough to inspect text within a 16:9 frame on an
    /// iPhone screen without rendering compression artifacts.
    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 4.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                zoomableTile

                PTZControlView(session: session, channelID: channel.channel)

                TalkbackButtonView(
                    session: session,
                    channelID: UInt8(channel.channel)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var zoomableTile: some View {
        LiveTileView(
            session: session,
            channel: channel,
            stream: .main,
            onPlayerChanged: { newPlayer in
                attachPiPIfNeeded(to: newPlayer)
            }
        )
        .aspectRatio(channel.isDualLens ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)
        .scaleEffect(zoom)
        .offset(pan)
        // Clip pan/zoom output to the tile's rect so a magnified frame
        // doesn't spill over the PTZ controls below it.
        .clipShape(.rect(cornerRadius: 10))
        .gesture(magnifyGesture.simultaneously(with: dragGesture))
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.25)) {
                zoom = 1.0
                pan = .zero
                anchorZoom = 1.0
                anchorPan = .zero
            }
        }
        .accessibilityHint("Pinch to zoom, drag to pan, double-tap to reset.")
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let target = clamp(anchorZoom * value.magnification, min: Self.minZoom, max: Self.maxZoom)
                zoom = target
            }
            .onEnded { _ in
                anchorZoom = zoom
                // If the user pinched all the way back to 1× while panned,
                // recenter so they're not left looking at the edge of the
                // image.
                if zoom <= Self.minZoom + 0.001 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        pan = .zero
                        anchorPan = .zero
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Pan is only meaningful while zoomed in.
                guard zoom > Self.minZoom + 0.001 else { return }
                pan = CGSize(
                    width: anchorPan.width + value.translation.width,
                    height: anchorPan.height + value.translation.height
                )
            }
            .onEnded { _ in
                anchorPan = pan
            }
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, value))
    }

    /// Build a fresh `LiveVideoPiP` controller the first time the tile
    /// creates a player, or re-attach when the player object changes
    /// (e.g. the tile cycled through pause/resume). Idempotent: a no-op
    /// when the same player is already bound.
    private func attachPiPIfNeeded(to player: LiveVideoPlayer?) {
        guard let player else {
            // Player went away (tile disappeared, view closed, etc.) —
            // discard the controller so we don't hold a dangling
            // reference to a stale display layer.
            pipController = nil
            attachedPlayerID = nil
            return
        }
        let id = ObjectIdentifier(player)
        guard id != attachedPlayerID else { return }
        attachedPlayerID = id
        pipController = LiveVideoPiP(player: player)
    }
}
