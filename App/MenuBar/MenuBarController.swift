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
            HStack {
                Button("Open Reolens") { onOpenApp() }
                Spacer()
                Button("Quit") { onQuit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(12)
        }
    }

    /// Latest events from every running camera session, newest first,
    /// capped at 20 — fits inside the popover without scrolling for the
    /// usual case while still bounded if a battery cam went chatty.
    ///
    /// Resolves each event's channel name from the session so a hub
    /// with multiple paired cameras surfaces "Back Yard" / "Front
    /// Door" rather than "Home Hub" for every event. AGENTS.md §11 —
    /// the channel name is already user-supplied via the camera's
    /// OSD config; it's no more sensitive than the device name and
    /// stays in the menu-bar process boundary.
    private func recentEvents() -> [PopoverEvent] {
        var combined: [PopoverEvent] = []
        for camera in store.cameras {
            guard let session = store.sessions[camera.id] else { continue }
            for event in session.aiEventLog.suffix(20) {
                let channelName = session.channels.first(where: { $0.channel == event.channelID })?.name
                combined.append(PopoverEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    deviceName: camera.displayName,
                    channelName: channelName,
                    detection: event.detectionType
                ))
            }
        }
        return combined.sorted { $0.timestamp > $1.timestamp }.prefix(20).map { $0 }
    }

    private func eventRow(_ entry: PopoverEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.detection?.systemImage ?? "circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                // Lead with the channel name (the camera the user
                // actually thinks about — "Back Yard", "Front Door")
                // so multi-channel hubs surface which camera fired,
                // not just which hub. Falls back to the device's
                // displayName when the channel didn't report a name.
                Text(entry.channelName ?? entry.deviceName)
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text(entry.detection?.label ?? "Motion")
                    // Only show the device name on the secondary line
                    // when it differs from the channel name — keeps
                    // single-camera devices (where channel name ==
                    // device name) from rendering "Foo · Foo".
                    if let channelName = entry.channelName, channelName != entry.deviceName {
                        Text("·").foregroundStyle(.tertiary)
                        Text(entry.deviceName)
                    }
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
        let channelName: String?
        let detection: ReolinkAPI.DetectionType?
    }
}

import ReolinkAPI
#endif
