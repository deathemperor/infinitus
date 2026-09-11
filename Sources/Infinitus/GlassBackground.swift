import SwiftUI
import AppKit
import InfinitusUI

/// macOS glass for the popover and the pop-out window: NSGlassEffectView
/// in EVERY state. The round-7 focus-swap rested on a false observation —
/// a probe window (2026-08-30) proves plain NSGlassEffectView keeps full
/// glass when the window resigns key; the "went solid" repro was the
/// probe being occluded, and in-app the swap itself was what removed the
/// glass. FrameRetuner still rewrites the NSPopover frame's own
/// near-opaque material — without that the anchored popup never shows
/// any backdrop, whatever we stack inside it.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Side-effect view: fades the popover frame's own material so our glass
/// layer supplies the look. Draws nothing itself.
///
/// macOS 26 frame anatomy (probed 2026-08-30): NSPopoverFrame is itself
/// an NSVisualEffectView hosting a private NSGlassView, whose OWN
/// _NSCoreHostingView sibling of ContentHolderView paints the heavy
/// popover material — our content hangs inside ContentHolderView, so
/// fading that hosting view fades only the frame's paint. Probe-verified:
/// backdrop text reads through crisply, rounded border survives.
private final class FrameRetunerView: NSView {
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let w = window else { return }
        applyToFrame()
        // The frame reacts to key transitions (the base effect view
        // follows window activity, the private glass repaints), so the
        // retune must chase every transition, not run once (user
        // 2026-08-30: "out of focus needs to look the same too").
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            tokens.append(nc.addObserver(forName: name, object: w,
                                         queue: .main) { [weak self] _ in
                self?.applyToFrame()
            })
        }
        // App-level deactivation also drops the window's active
        // appearance without a resign-key on this window.
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil,
                                         queue: .main) { [weak self] _ in
                self?.applyToFrame()
            })
        }
    }

    /// The genuine glass render is keyed off the window's private
    /// "active appearance" — without this, an unfocused window swaps
    /// glass for a flat frosted fallback and the transparency dial
    /// becomes plain opacity (user 2026-08-30: "doesn't look like glass
    /// transparency but just opacity"). Probe-verified: forcing it back
    /// on restores real backdrop blur while unfocused. Guarded so a
    /// future macOS that drops the selector just degrades to frosted.
    private func forceActiveAppearance() {
        guard let w = window, !w.isKeyWindow else { return }
        let sel = NSSelectorFromString("_setHasActiveAppearance:")
        guard w.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: w), sel)
        else { return }
        typealias SetBool = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: SetBool.self)(w, sel, true)
    }

    /// Frame paint alpha ceiling; the per-focus strength dial scales it.
    var paintAlpha: CGFloat = 0.2 {
        didSet { if paintAlpha != oldValue { applyToFrame() } }
    }

    private func applyToFrame() {
        forceActiveAppearance()
        // Once more after AppKit's own key-state handling settles — the
        // notification order between our observer and the appearance
        // drop is not guaranteed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.forceActiveAppearance()
        }
        guard let frameView = window?.contentView?.superview else { return }
        // NSPopoverFrame itself is an effect view following window
        // activity — inactive it swaps to a grayer, more solid material.
        if let base = frameView as? NSVisualEffectView {
            base.state = .active
        }
        retune(frameView)
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    private func retune(_ frame: NSView) {
        for sub in frame.subviews {
            if String(describing: type(of: sub)) == "NSGlassView" {
                for inner in sub.subviews
                where String(describing: type(of: inner)).contains("HostingView") {
                    inner.alphaValue = paintAlpha
                }
            }
            // Pre-26 frames kept their material in effect-view subviews.
            if let effect = sub as? NSVisualEffectView {
                effect.material = .hudWindow
                effect.state = .active
            }
            retune(sub)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct FrameRetuner: NSViewRepresentable {
    var paintAlpha: CGFloat

    func makeNSView(context: Context) -> FrameRetunerView {
        let view = FrameRetunerView()
        view.paintAlpha = paintAlpha
        return view
    }
    func updateNSView(_ view: FrameRetunerView, context: Context) {
        view.paintAlpha = paintAlpha
    }
}

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

    /// Dial → scrim: frosty (0) lays 0.85, clear (1) lays 0.25 with the
    /// backdrop obviously present. One monotone ramp, so the dial is the
    /// only knob; GlassCeilingView underneath handles bright backdrops
    /// and window captures at every setting.
    static func strength(forClarity clarity: Double) -> CGFloat {
        CGFloat(0.85 - 0.60 * min(max(clarity, 0), 1))
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

    /// The dial-driven scrim, when this container wraps the popup or
    /// pop-out; Settings' fixed wash leaves it nil.
    private(set) var scrim: GlassScrimView?

    /// Re-tune the wash from the transparency dial (ThemedGlassChrome
    /// calls this whenever the model's dial changes).
    func follow(clarity: Double) {
        scrim?.strength = GlassScrimView.strength(forClarity: clarity)
    }

    static func wrap(_ hosted: NSView, scrim: Bool = false,
                     scrimStrength: CGFloat = 0.5) -> GlassContainerView {
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
            // what sits behind. Settings only: the popup/pop-out carry
            // ThemedGlassChrome's wash and the transparency dial.
            if scrim {
                let ceiling = GlassCeilingView(frame: container.bounds)
                ceiling.autoresizingMask = [.width, .height]
                container.addSubview(ceiling)
                let wash = GlassScrimView(frame: container.bounds, strength: scrimStrength)
                wash.autoresizingMask = [.width, .height]
                container.addSubview(wash)
                container.scrim = wash
            }
        }
        hosted.frame = container.bounds
        hosted.autoresizingMask = [.width, .height]
        container.addSubview(hosted)
        return container
    }
}

/// The popup container's full chrome: focus-swapped glass, a theme-tinted
/// wash, and a themed border glow. Observes the model so a theme change
/// re-tints the live popup.
struct ThemedGlassChrome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // ONE state, ONE dial (final semantics). The tuned blur renders
        // identically in every focus state, so the chrome reads no
        // focus signal — any focus-reactive piece here made the popup
        // "randomly transition" as key state flapped (user 2026-08-30).
        let clarity = model.glassFocused
        let milk = 1 - clarity
        ZStack {
            if BackdropGlassNSView.available {
                // The blur and the scrim live under the hosting view
                // (GlassContainerView); the scrim IS the frost, so
                // nothing is layered here — a second black wash on top
                // was what buried the backdrop. ScrimFollower pushes the
                // dial down to the container.
                ScrimFollower(clarity: clarity)
            } else if #available(macOS 26.0, *) {
                FrameRetuner(paintAlpha: 0.2 * milk)
                GlassEffectLayer().opacity(1 - 0.75 * clarity)
            } else {
                FrameRetuner(paintAlpha: 0.2 * milk)
                GlassBackground().opacity(1 - 0.75 * clarity)
            }
            ThemeWash(theme: model.rowTheme, milk: milk)
            if model.setupStepShown {
                Color(nsColor: .windowBackgroundColor)   // setup steps: no glass
            }
        }
        .ignoresSafeArea()
    }
}

/// Bridges the SwiftUI dial to the AppKit scrim under the hosting view.
/// Draws nothing; walks up to the GlassContainerView once attached.
private struct ScrimFollower: NSViewRepresentable {
    var clarity: Double

    final class Probe: NSView {
        var clarity: Double = 0.7 { didSet { push() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); push() }
        func push() {
            var v: NSView? = self
            while let cur = v, !(cur is GlassContainerView) { v = cur.superview }
            (v as? GlassContainerView)?.follow(clarity: clarity)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.clarity = clarity
        return p
    }
    func updateNSView(_ view: Probe, context: Context) { view.clarity = clarity }
}

/// AppKit Liquid Glass (macOS 26): the genuine article, live in every
/// focus state. In a popover window the stock view subdues itself when
/// the window resigns key (milkier, less backdrop); the subclass pins
/// the private _subduedState at 0 on every key transition so focused
/// and unfocused read identically (user 2026-08-30).
@available(macOS 26.0, *)
private final class SteadyGlassView: NSGlassEffectView {
    // A view attached to a never-key window is born subdued; the
    // neutered key handler only stops later transitions.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setValue(0, forKey: "_subduedState")
    }

    static let neuter: Void = {
        let sel = NSSelectorFromString("_windowChangedKeyState")
        let imp = imp_implementationWithBlock({ (v: NSView) in
            v.setValue(0, forKey: "_subduedState")
        } as @convention(block) (NSView) -> Void)
        class_addMethod(SteadyGlassView.self, sel, imp, "v@:")
    }()
}

@available(macOS 26.0, *)
private struct GlassEffectLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        _ = SteadyGlassView.neuter
        let view = SteadyGlassView()
        view.style = .clear
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

extension View {
    /// Glass + themed tint behind the popover / pop-out content.
    /// Compiled against the 26 SDK; guarded for the 14 deployment target.
    func glassChrome(model: AppModel) -> some View {
        background { ThemedGlassChrome(model: model) }
    }
}
