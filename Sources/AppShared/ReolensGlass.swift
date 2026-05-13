import SwiftUI

/// 0.5.0 Theme D2 — Liquid Glass design tokens.
///
/// Centralizes Reolens's adoption of the iOS 26 / macOS 26 Liquid
/// Glass material so every surface (toolbars, sidebars, tile chrome,
/// popover, sheets, widgets) renders against the same shape, tint,
/// and corner-radius vocabulary. Pulling the choices into one place
/// keeps the visual language coherent and makes a future tweak a
/// one-file edit. AGENTS.md §1 (platform parity): identical helpers
/// work on macOS, iPadOS, iOS.
///
/// Falls back gracefully on older OSes via `if #available`. The
/// deployment floor for 0.5.0 is iOS 26 / macOS 26 so the fallback is
/// rarely exercised — it's there for the rare bridging case where a
/// preview/embedded build runs against an older SDK.
public enum ReolensGlass {

    // MARK: - Shape tokens

    public static let tileBadgeRadius: CGFloat = 10
    public static let toolbarItemRadius: CGFloat = 12
    public static let sheetChromeRadius: CGFloat = 18
    public static let cardRadius: CGFloat = 16
}

public extension View {

    /// Apply Liquid Glass to a tile-level badge (camera name pill,
    /// motion-state indicator, save-snapshot HUD). Subtle, never
    /// fights the underlying video.
    @ViewBuilder
    func reolensGlassBadge(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(tint.map { .regular.tint($0.opacity(0.4)) } ?? .regular,
                             in: .rect(cornerRadius: ReolensGlass.tileBadgeRadius))
        } else {
            self
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: ReolensGlass.tileBadgeRadius))
        }
    }

    /// Apply Liquid Glass to a card-shaped surface (settings rows,
    /// sheet sections, the trust-changed alert, AddCameraSheet's
    /// container).
    @ViewBuilder
    func reolensGlassCard() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: ReolensGlass.cardRadius))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: ReolensGlass.cardRadius))
        }
    }

    /// Apply Liquid Glass to a sheet's outer chrome — the
    /// rounded-rect title bar + bottom action row that frames the
    /// scrollable content.
    @ViewBuilder
    func reolensGlassSheetChrome() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: ReolensGlass.sheetChromeRadius))
        } else {
            self.background(.thickMaterial, in: .rect(cornerRadius: ReolensGlass.sheetChromeRadius))
        }
    }

    /// Apply Liquid Glass to a button or interactive control so it
    /// reads as a tappable surface even on top of arbitrary content.
    /// Use this on the toolbar's icon-only buttons + the menu-bar
    /// popover's footer buttons.
    @ViewBuilder
    func reolensGlassControl(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(tint.map { .regular.tint($0.opacity(0.35)) } ?? .regular,
                             in: .rect(cornerRadius: ReolensGlass.toolbarItemRadius))
        } else {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: .rect(cornerRadius: ReolensGlass.toolbarItemRadius))
        }
    }

    /// Apply Liquid Glass to a popover or panel background — the
    /// container surface for the menu-bar quick-glance, the snapshot
    /// HUD, etc.
    @ViewBuilder
    func reolensGlassPanel() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.background {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    .ignoresSafeArea()
            }
        } else {
            self.background(.regularMaterial)
        }
    }

    /// Apply Liquid Glass to a capsule-shaped chip — used by AI
    /// event filter chips, AI-capability badges in Channel Settings,
    /// and the bookmark-tag pills on recording rows.
    @ViewBuilder
    func reolensGlassChip(selected: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(selected ? .regular.tint(tint.opacity(0.55)) : .regular,
                             in: .capsule)
        } else {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? AnyShapeStyle(tint.opacity(0.35)) : AnyShapeStyle(.ultraThinMaterial),
                            in: .capsule)
        }
    }

    /// Apply Liquid Glass to a toolbar / header bar that lives above
    /// scrollable content. Differs from `reolensGlassPanel` in that
    /// it doesn't ignore safe area — the bar sits inside its
    /// parent's layout.
    @ViewBuilder
    func reolensGlassToolbar() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.background {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
            }
        } else {
            self.background(.thinMaterial)
        }
    }

    /// Apply Liquid Glass to a small toast / HUD — the snapshot-
    /// saved confirmation, retry hint, etc.
    @ViewBuilder
    func reolensGlassToast() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
        } else {
            self
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: .capsule)
        }
    }

    /// Group a related set of glass surfaces so they morph together
    /// when they overlap during gestures or transitions. iOS 26+
    /// ships this as `GlassEffectContainer`; on earlier OSes this
    /// is a transparent pass-through.
    @ViewBuilder
    func reolensGlassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}

/// 0.5.0 — `GlassEffectContainer` wrapper for grouping multiple
/// glass-surfaced views. Use this around clusters of small glass
/// chips/buttons so iOS 26's continuous-morph effect can blend them
/// when they overlap (filter chip rows, the recordings toolbar, the
/// detail-view action bar).
@available(iOS 26.0, macOS 26.0, *)
public struct ReolensGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View {
        GlassEffectContainer { content }
    }
}
