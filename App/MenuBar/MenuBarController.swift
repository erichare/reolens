#if os(macOS)
import AppKit
import SwiftUI
import ServiceManagement
import AppShared
import os

/// Singleton that owns the macOS menu-bar status item, the popover that
/// surfaces recent motion events, and the `SMAppService` login-item
/// registration. New in 0.4.0.
///
/// "Run in the menu bar when closed" mode (Settings → General):
///
/// - Closing the main window does NOT terminate the app
///   (`applicationShouldTerminateAfterLastWindowClosed` returns false).
/// - A menu-bar icon shows the most recent events from any active
///   `CameraSession.aiEventLog` so the user can glance at what's
///   happening without surfacing the full UI.
/// - Clicking "Open Reolens" in the popover routes through
///   `AppIntentFocus.requestFocus` to re-show the window. Quit is its
///   own row so users can still close the process from the menu bar
///   when the window is gone.
///
/// "Launch at login" is opt-in alongside menu-bar mode and registers
/// the main app via `SMAppService.mainApp` (macOS 13+). Disabling it
/// unregisters in the same call.
///
/// The status item is created lazily — instantiating it without the
/// user opting in adds a permanent menu-bar icon on every launch,
/// which is exactly the kind of "silent install" AGENTS.md §5 forbids.
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    /// UserDefaults key for "run in menu bar when closed" — read also
    /// by `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`.
    static let menuBarModeKey = "com.reolens.menuBarMode"
    /// UserDefaults key for "launch at login". Distinct from the
    /// menu-bar flag so the user can opt into one without the other.
    static let launchAtLoginKey = "com.reolens.launchAtLogin"

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let log = Logger(subsystem: "com.reolens.Reolens", category: "MenuBar")

    private init() {}

    /// Menu-bar-tinted Reolens logo. Drawn at runtime as a monochrome
    /// silhouette (lens ring + offset pupil, echoing the app icon's
    /// camera-eye motif) and marked as a template image so macOS
    /// renders it in the menu bar's text color regardless of light /
    /// dark / graphite / accent appearance.
    ///
    /// Drawing here instead of shipping a PNG keeps the menu-bar icon
    /// crisp at every retina factor and avoids carrying an extra
    /// asset just for this 18×18 use.
    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let outer = rect.insetBy(dx: 1.5, dy: 1.5)
            let lineWidth: CGFloat = 1.6
            // Outer lens ring.
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: outer)
            ring.lineWidth = lineWidth
            ring.stroke()
            // Inner iris ring — slightly thinner, gives the icon depth
            // and reads as "lens" rather than a plain circle.
            let irisInset: CGFloat = outer.width * 0.18
            let iris = NSBezierPath(ovalIn: outer.insetBy(dx: irisInset, dy: irisInset))
            iris.lineWidth = 1.0
            iris.stroke()
            // Solid pupil, offset slightly up-and-right like the app
            // icon's catchlight — reads as the same logo at 18pt.
            let pupilSize = outer.width * 0.32
            let pupilRect = NSRect(
                x: outer.midX - pupilSize / 2 + 0.5,
                y: outer.midY - pupilSize / 2 + 0.5,
                width: pupilSize,
                height: pupilSize
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: pupilRect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Reolens"
        return image
    }()

    /// Read the persisted flag and install or remove the status item
    /// accordingly. Called on launch and whenever the user flips the
    /// Settings toggle.
    func syncFromDefaults(store: CameraStore) {
        let enabled = UserDefaults.standard.bool(forKey: Self.menuBarModeKey)
        if enabled {
            install(store: store)
        } else {
            uninstall()
        }
    }

    func install(store: CameraStore) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Reolens-logo template image — macOS auto-tints template
            // images to match the menu bar's appearance (light/dark,
            // graphite/accent), so a single drawn silhouette renders
            // correctly in every menu-bar style.
            button.image = Self.menuBarIcon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(store: store, onOpenApp: { [weak self] in
                self?.showMainWindow()
            }, onQuit: {
                NSApp.terminate(nil)
            })
            .environment(store)
        )
        self.statusItem = item
        self.popover = popover
        log.info("Menu-bar item installed")
    }

    func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        popover = nil
        log.info("Menu-bar item removed")
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Activate so the popover gets keyboard focus and clicks
            // outside dismiss it (NSPopover transient behavior misses
            // clicks across spaces without this).
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMainWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Bring an existing window forward; if none, the system creates
        // one because WindowGroup tracks the app activation. Iterating
        // visible windows is safer than `NSApp.windows[0]`, which
        // returns popovers and About panels too.
        for window in NSApp.windows where window.title == "Reolens" {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Fall through: ask AppKit to open a new window via the standard
        // "new" responder chain action. SwiftUI's WindowGroup wires this
        // up automatically.
        NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
    }

    // MARK: - Launch at login (macOS 13+)

    @available(macOS 13.0, *)
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    log.info("SMAppService.mainApp registered for launch at login")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    log.info("SMAppService.mainApp unregistered from launch at login")
                }
            }
        } catch {
            log.error("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct MenuBarPopoverView: View {
    let store: CameraStore
    let onOpenApp: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reolens")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Text("Recent events across all cameras")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let events = recentEvents()
                    if events.isEmpty {
                        Text("No events yet this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    } else {
                        ForEach(events, id: \.id) { entry in
                            eventRow(entry)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Open Reolens") { onOpenApp() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Quit") { onQuit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(12)
        }
        // 0.5.0 — Liquid Glass background for the popover container.
        // The Recent-events list renders directly over the user's
        // desktop without an opaque wrapper, matching the rest of
        // macOS 26's quick-glance HUDs.
        .reolensGlassPanel()
    }

    /// Latest events from every running camera session, newest first,
    /// capped at 20 — fits inside the popover without scrolling for the
    /// usual case while still bounded if a battery cam went chatty.
    ///
    /// 0.5.0 fixes:
    ///   * iterate the log NEWEST-FIRST (`aiEventLog` is inserted at
    ///     index 0, so `.suffix(20)` previously returned the OLDEST).
    ///   * coalesce repeats of the same (camera, channel, detection)
    ///     within a 3 s window — a single motion burst on the hub
    ///     fires several events on the push channel and produced
    ///     duplicate rows.
    ///   * fall back to "Camera <N>" (1-indexed) when the channel's
    ///     `name` is nil OR empty — Reolink firmware doesn't always
    ///     populate the OSD-side name even when the user has set one
    ///     on the camera itself, and rendering the hub's displayName
    ///     for every row obscured which channel fired.
    private func recentEvents() -> [PopoverEvent] {
        var combined: [PopoverEvent] = []
        for camera in store.cameras {
            guard let session = store.sessions[camera.id] else { continue }
            // aiEventLog is newest-first (inserted at index 0). Take
            // the prefix, not the suffix.
            for event in session.aiEventLog.prefix(60) {
                let resolved = session.channels.first { $0.channel == event.channelID }
                let trimmedName = resolved?.name?.trimmingCharacters(in: .whitespaces) ?? ""
                let channelName: String? = trimmedName.isEmpty ? nil : trimmedName
                combined.append(PopoverEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    deviceName: camera.displayName,
                    channelName: channelName,
                    channelIndex: event.channelID,
                    detection: event.detectionType,
                    rawAITag: event.aiTag
                ))
            }
        }
        let sorted = combined.sorted { $0.timestamp > $1.timestamp }
        return Self.coalesce(events: sorted, withinSeconds: 3).prefix(20).map { $0 }
    }

    /// Collapse adjacent same-camera same-detection events that fire
    /// within `withinSeconds`. Motion bursts on a Reolink hub push
    /// several events through the alarm stream for one physical
    /// trigger; the popover should show them as a single row.
    private static func coalesce(events: [PopoverEvent], withinSeconds: TimeInterval) -> [PopoverEvent] {
        var out: [PopoverEvent] = []
        for event in events {
            if let last = out.last,
               last.deviceName == event.deviceName,
               last.channelIndex == event.channelIndex,
               last.detection == event.detection,
               abs(last.timestamp.timeIntervalSince(event.timestamp)) <= withinSeconds {
                continue
            }
            out.append(event)
        }
        return out
    }

    private func eventRow(_ entry: PopoverEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.detection?.systemImage ?? "circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                // Lead with the channel name (the camera the user
                // actually thinks about — "Back Yard", "Front Door")
                // so multi-channel hubs surface which camera fired,
                // not just which hub. Falls back to "Camera <N>" when
                // the firmware didn't populate the per-channel name —
                // never to the hub's displayName, which is the same
                // for every channel and so doesn't help the user
                // identify which camera fired.
                Text(Self.primaryLabel(for: entry))
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    // Prefer the raw AI tag (Reolink's wire format —
                    // "people", "vehicle", "dog_cat") rendered via
                    // DetectionType. When the live push stream has
                    // delivered AItype="none" the event is still a
                    // genuine motion fire; surface that explicitly.
                    Text(Self.detectionLabel(for: entry))
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.deviceName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private struct PopoverEvent: Sendable, Identifiable {
        let id: UUID
        let timestamp: Date
        let deviceName: String
        /// Trimmed, non-empty channel name when the firmware reported
        /// one. Otherwise nil — `primaryLabel` falls back to
        /// "Camera <N>".
        let channelName: String?
        /// 0-indexed Reolink channel number. The user-facing
        /// "Camera N" label is 1-indexed.
        let channelIndex: Int
        let detection: ReolinkAPI.DetectionType?
        /// Raw Reolink AI tag string from `<AItype>` — e.g. "people",
        /// "vehicle", "dog_cat", "face". Carried separately so the
        /// label fallback can distinguish "motion" from "AI-classified
        /// but unknown tag".
        let rawAITag: String?
    }

    /// Primary label shown on the popover row's first line. Channel
    /// name wins; "Camera <N>" fallback keeps multi-channel hubs
    /// readable even when the per-channel name field is empty.
    private static func primaryLabel(for entry: PopoverEvent) -> String {
        if let name = entry.channelName {
            return name
        }
        return "Camera \(entry.channelIndex + 1)"
    }

    /// Secondary-line detection label. Prefers the AI tag rendered
    /// through `DetectionType.label` ("Person", "Vehicle", "Pet")
    /// when present; falls back to "Motion" for motion-only events
    /// and to the raw tag string when the AI category isn't one we
    /// know how to map (older firmware that ships a custom string).
    private static func detectionLabel(for entry: PopoverEvent) -> String {
        if let detection = entry.detection {
            return detection.label
        }
        if let raw = entry.rawAITag, !raw.isEmpty, raw.lowercased() != "none" {
            return raw.capitalized
        }
        return "Motion"
    }
}

import ReolinkAPI
#endif
