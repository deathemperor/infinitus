import SwiftUI
import AppKit
import InfinitusUI

/// The Settings window's glass: a retuned NSVisualEffectView backdrop, a
/// ceiling and a wash, all plain AppKit siblings under the hosting view
/// (SwiftUI's offscreen flattening silently breaks CABackdropLayer capture).
///
/// NSVisualEffectView with its guts retuned: the effect view's
/// window-server plumbing is the RELIABLE way to get behind-window
/// compositing (a hand-rolled CABackdropLayer captured only
/// sometimes — the popup "randomly transitioned" between blurred and
/// plain alpha, user 2026-08-30). Inside it: replace the material's
/// stock filters with one gaussian at a SMALL radius, and hide the
/// tint layers. Small radius is the point — heavy blur over a dark
/// backdrop averages to an opaque-looking slab; at ~10 the backdrop
/// stays present as soft, obviously-blurred shapes. AppKit rebuilds
/// material layers on appearance/state changes, so the retune re-runs
/// on every such hook. Degrades to the stock hud material if the
/// private classes vanish.
final class BackdropGlassNSView: NSVisualEffectView {
    static var available: Bool { NSClassFromString("CABackdropLayer") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func findBackdrop(_ layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == "CABackdropLayer" { return layer }
        for sub in layer.sublayers ?? [] {
            if let found = findBackdrop(sub) { return found }
        }
        return nil
    }

    private func retune() {
        guard let root = layer, let backdrop = findBackdrop(root) else { return }
        if let filterCls = NSClassFromString("CAFilter") as? NSObject.Type,
           let blur = filterCls.perform(NSSelectorFromString("filterWithType:"),
                                        with: "gaussianBlur")?
               .takeUnretainedValue() as? NSObject {
            blur.setValue(10.0, forKey: "inputRadius")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            backdrop.filters = [blur]
        }
        // Everything that isn't (or doesn't hold) the backdrop is
        // tint/overlay — hide it.
        func hideTints(_ layer: CALayer) {
            for sub in layer.sublayers ?? [] {
                if sub === backdrop { continue }
                if findBackdrop(sub) != nil { hideTints(sub) }
                else { sub.isHidden = true }
            }
        }
        hideTints(root)
    }

    override func updateLayer() {
        super.updateLayer()
        retune()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retune()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.retune()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retune()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Luminance-stabilizing wash over the backdrop blur: dark appearance
/// lays black, light lays white, so text keeps contrast over any app
/// behind the window. Static — never focus-driven (glass runs in all
/// states).
final class GlassScrimView: NSView {
    /// Wash opacity. Settings keeps the light 0.5 wash. The popup and
    /// pop-out DRIVE it from the transparency dial (see `follow`): a
    /// fixed 0.85 fixed window captures (a per-window capture can't
    /// sample the backdrop, so the window's own pixels must carry the
    /// dark look) but killed the live glass at every dial setting —
    /// 15% of the backdrop reads as a solid slab (user 2026-09-03:
    /// "the liquid glass effect is gone AGAIN", after d5fe8f2).
    var strength: CGFloat {
        didSet { if strength != oldValue { needsDisplay = true } }
    }

    init(frame: NSRect, strength: CGFloat = 0.5) {
        self.strength = strength
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = dark
            ? NSColor.black.withAlphaComponent(strength).cgColor
            : NSColor.white.withAlphaComponent(strength + 0.05).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Luminance ceiling over the backdrop blur: a darken blend against a
/// dark gray (light appearance: a lighten blend against a light gray),
/// so a bright app behind the window is clamped to a legible level while
/// a dark backdrop passes through untouched — unlike the alpha wash,
/// which scales every backdrop the same. A per-window capture renders
/// the blur as a flat light gray (probed 2026-09-04: a red view under
/// the blur shows in neither the live window nor the capture), which is
/// exactly the bright-backdrop case, so captures clamp too (#4).
final class GlassCeilingView: NSView {
    /// Clamp level (0…1 luminance). Dark appearance: backdrop brighter
    /// than this is pulled down to it.
    static let level: CGFloat = 0.35

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.compositingFilter = dark ? "darkenBlendMode" : "lightenBlendMode"
        layer?.backgroundColor = NSColor(white: dark ? Self.level : 1 - Self.level, alpha: 1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Window content wrapper: [backdrop blur] under [SwiftUI hosting],
/// both plain AppKit siblings so the blur escapes SwiftUI's offscreen
/// flattening. Rounds and masks the whole stack.
final class GlassContainerView: NSView {
    private var tokens: [NSObjectProtocol] = []

    /// Text vibrancy dims with the window's active appearance — one
    /// more focus-driven shift. Pin it (guarded private setter;
    /// degrades to normal dimming if the selector goes away).
    private func forceActive() {
        guard let w = window, !w.isKeyWindow else { return }
        let sel = NSSelectorFromString("_setHasActiveAppearance:")
        guard w.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: w), sel)
        else { return }
        typealias SetBool = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: SetBool.self)(w, sel, true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard window != nil else { return }
        forceActive()
        let nc = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil,
                                         queue: .main) { [weak self] _ in
                self?.forceActive()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.forceActive()
                }
            })
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    static func wrap(_ hosted: NSView, scrim: Bool = false) -> GlassContainerView {
        let container = GlassContainerView(frame: hosted.frame)
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        if BackdropGlassNSView.available {
            let blur = BackdropGlassNSView(frame: container.bounds)
            blur.autoresizingMask = [.width, .height]
            container.addSubview(blur)
            // The retuned backdrop is pure blur — over a white app the
            // sidebar text washes out (user screenshot 2026-09-01). A
            // static appearance-following wash keeps contrast no matter
            // what sits behind.
            if scrim {
                let ceiling = GlassCeilingView(frame: container.bounds)
                ceiling.autoresizingMask = [.width, .height]
                container.addSubview(ceiling)
                let wash = GlassScrimView(frame: container.bounds)
                wash.autoresizingMask = [.width, .height]
                container.addSubview(wash)
            }
        }
        hosted.frame = container.bounds
        hosted.autoresizingMask = [.width, .height]
        container.addSubview(hosted)
        return container
    }
}
