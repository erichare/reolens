import SwiftUI
import ReolinkAPI
import ReolinkStreaming
import AppShared

/// Full-screen single-channel view. Two tabs mirror the macOS app's
/// per-channel detail: Live and Recordings.
///
/// The Live tab supports:
/// - **Pinch-to-zoom + drag-to-pan** for digital zoom on still frames.
///   Double-tap to reset. Purely visual; for optical PTZ on supported
///   cameras, the PTZ control panel below is the right surface.
/// - **Toggleable PTZ / Talkback panel** — power users keep them
///   visible; most users with fixed cameras can hide them to give the
///   live tile more breathing room. Toggle from the toolbar.
/// - **Picture-in-Picture** (iOS 15+) so the user can keep an eye on a
///   camera while using another app. PiP routes through
///   `LiveVideoPiP` against the player's existing
///   `AVSampleBufferDisplayLayer` — same layer the inline view uses,
///   so entering PiP is a smooth handoff with no extra decode.
/// - **Fullscreen** — covers the entire screen with the camera feed,
///   no chrome. Pinch-zoom and pan work in fullscreen too. The inline
///   tile is paused while fullscreen is open so the hub only has one
///   active RTSP session per channel (Reolink hubs cap concurrent
///   sessions and silently drop one when both are running).
struct SingleChannelView: View {
    let session: CameraSession
    let channel: ChannelStatus

    /// The most recent `LiveVideoPlayer` produced by the inline tile.
    /// We hold a reference so the PiP button can construct an
    /// `AVPictureInPictureController` against its display layer on
    /// demand — but we do NOT construct one eagerly. Constructing
    /// PiP against an `AVSampleBufferDisplayLayer` during a SwiftUI
    /// render pass (before the layer is in a window) hangs the main
    /// thread on iPad. Lazy construction sidesteps the issue entirely.
    @State private var currentPlayer: LiveVideoPlayer?
    @State private var pipController: LiveVideoPiP?
    @State private var pipObservable: PiPObservable?
    @State private var controlsVisible: Bool = true
    @State private var showingFullscreen: Bool = false

    var body: some View {
        TabView {
            LiveTab(
                session: session,
                channel: channel,
                onPlayerChanged: { newPlayer in
                    currentPlayer = newPlayer
                    // If the player went away, discard the PiP
                    // controller and observable so we don't hold a
                    // dangling reference to a destroyed display layer.
                    if newPlayer == nil {
                        pipController = nil
                        pipObservable = nil
                    }
                },
                controlsVisible: $controlsVisible,
                pausedForFullscreen: showingFullscreen
            )
            .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            RecordingsView(session: session, channel: channel)
                .tabItem { Label("Recordings", systemImage: "clock.arrow.circlepath") }
        }
        .navigationTitle(channel.name ?? "Channel \(channel.channel + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingFullscreen = true
                } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Fullscreen")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible.toggle()
                    }
                } label: {
                    Label(
                        controlsVisible ? "Hide Controls" : "Show Controls",
                        systemImage: "slider.horizontal.3"
                    )
                    .symbolVariant(controlsVisible ? .fill : .none)
                }
                .accessibilityLabel(controlsVisible ? "Hide controls" : "Show controls")

                pipToolbar
            }
        }
        .fullScreenCover(isPresented: $showingFullscreen) {
            FullscreenLiveView(session: session, channel: channel)
        }
    }

    /// Lazily-constructed PiP toolbar. While no controller exists, the
    /// button is a plain "Start Picture-in-Picture" that constructs
    /// the controller on first tap. After that, hands off to
    /// `PiPToolbarButton` which observes the controller's state.
    @ViewBuilder
    private var pipToolbar: some View {
        if let observable = pipObservable {
            PiPToolbarButton(observable: observable)
        } else if currentPlayer != nil {
            Button {
                startPiPLazily()
            } label: {
                Label("Start Picture-in-Picture", systemImage: "pip.enter")
            }
            .accessibilityLabel("Start Picture-in-Picture")
        }
    }

    private func startPiPLazily() {
        guard let player = currentPlayer else { return }
        guard let controller = LiveVideoPiP(player: player) else { return }
        let observable = PiPObservable(controller: controller)
        pipController = controller
        pipObservable = observable
        // Give SwiftUI one runloop turn to mount the now-observed
        // PiPToolbarButton, then start PiP. Starting immediately would
        // race the button rebinding and could miss the active-state
        // KVO toggle.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            controller.start()
        }
    }
}

/// Toolbar button that toggles Picture-in-Picture. Greyed out until the
/// system signals that PiP is possible (display layer attached to a
/// window, screen recording not in progress, etc.).
///
/// Receives an *already-constructed* `PiPObservable` from the parent
/// view — does NOT build its own in `init`. Building one here per
/// re-render leaked KVO observers on the underlying controller
/// (multiplied by every pinch-zoom or toolbar update), saturating the
/// main actor with queued notification dispatches and freezing the
/// app on iPad after a few interactions.
private struct PiPToolbarButton: View {
    @ObservedObject var observable: PiPObservable

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
final class PiPObservable: ObservableObject {
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

/// "Live" tab: the main-stream tile + optional PTZ / Talkback panel.
/// Pulled into its own struct so the parent TabView gets a clean child.
private struct LiveTab: View {
    let session: CameraSession
    let channel: ChannelStatus
    /// Bubbled up to `SingleChannelView` so the parent can manage the
    /// `LiveVideoPiP` controller lifecycle in one place.
    let onPlayerChanged: (LiveVideoPlayer?) -> Void
    @Binding var controlsVisible: Bool
    /// True when `FullscreenLiveView` is presented over this view, so
    /// the inline tile pauses its RTSP session. Reolink hubs cap
    /// concurrent sessions and silently drop one if both run.
    let pausedForFullscreen: Bool

    @State private var zoom: CGFloat = 1.0
    @State private var anchorZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var anchorPan: CGSize = .zero

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 4.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                zoomableTile

                if controlsVisible {
                    PTZControlView(session: session, channelID: channel.channel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                    TalkbackButtonView(
                        session: session,
                        channelID: UInt8(channel.channel)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
            paused: pausedForFullscreen,
            onPlayerChanged: onPlayerChanged
        )
        .aspectRatio(channel.isDualLens ? 32.0 / 9.0 : 16.0 / 9.0, contentMode: .fit)
        .scaleEffect(zoom)
        .offset(pan)
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
}

/// Fullscreen camera view. Presented via `.fullScreenCover` from
/// `SingleChannelView`; covers the entire screen with the camera feed
/// and no chrome. A small floating overlay holds the Done button and
/// camera name; it auto-hides after 3 seconds of no interaction and
/// reappears on tap.
///
/// The inline `LiveTab`'s tile is paused while this view is presented,
/// so the camera only has one active RTSP session at a time.
private struct FullscreenLiveView: View {
    let session: CameraSession
    let channel: ChannelStatus

    @Environment(\.dismiss) private var dismiss
    @State private var chromeVisible: Bool = true
    @State private var chromeHideTask: Task<Void, Never>?

    @State private var zoom: CGFloat = 1.0
    @State private var anchorZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var anchorPan: CGSize = .zero

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 4.0
    private static let chromeAutoHideSeconds: UInt64 = 3

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            LiveTileView(
                session: session,
                channel: channel,
                stream: .main
            )
            .scaleEffect(zoom)
            .offset(pan)
            .ignoresSafeArea()
            .gesture(magnifyGesture.simultaneously(with: dragGesture))
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.25)) {
                    zoom = 1.0
                    pan = .zero
                    anchorZoom = 1.0
                    anchorPan = .zero
                }
            }
            // Single-tap toggles the overlay. Doesn't conflict with
            // double-tap (SwiftUI dispatches double-tap first) or the
            // pinch/drag gestures, which take priority via the gesture
            // recognizer hierarchy.
            .onTapGesture {
                showChrome()
            }

            if chromeVisible {
                overlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear { showChrome() }
        .onDisappear { chromeHideTask?.cancel() }
    }

    private var overlay: some View {
        VStack {
            HStack {
                Text(channel.name ?? "Channel \(channel.channel + 1)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("Exit fullscreen")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            Spacer()
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let target = clamp(anchorZoom * value.magnification, min: Self.minZoom, max: Self.maxZoom)
                zoom = target
            }
            .onEnded { _ in
                anchorZoom = zoom
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

    private func showChrome() {
        withAnimation(.easeInOut(duration: 0.15)) {
            chromeVisible = true
        }
        chromeHideTask?.cancel()
        chromeHideTask = Task { [chromeAutoHideSeconds = Self.chromeAutoHideSeconds] in
            try? await Task.sleep(nanoseconds: chromeAutoHideSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    chromeVisible = false
                }
            }
        }
    }
}
