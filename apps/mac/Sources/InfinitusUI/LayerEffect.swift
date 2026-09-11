import SwiftUI
import QuartzCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A SwiftUI leaf that hosts a Core Animation layer tree. The effects
/// built on it (LuckyRowBackground, CriticalPulse, …) animate with
/// CAAnimations, which run in the render server: the app process does
/// NO work per frame. Any SwiftUI-driven motion — a TimelineView tick
/// or a repeatForever `.animation` — commits a transaction per frame
/// (display-list diff, AppKit region + tracking-area updates, a
/// WindowServer fence), ~7 ms each at display rate: an RPG popup idled
/// at 40% CPU with the pop-out open (#18, 2026-09-03).
///
/// `install` runs once per size change with a fresh, empty host layer
/// (sublayers and animations are rebuilt — bounds rarely change) and
/// again when the view re-enters a window (CA drops animations from a
/// detached layer).
struct LayerEffect {
    let install: (CALayer, CGRect) -> Void
}

final class LayerEffectHost: PlatformView {
    var install: ((CALayer, CGRect) -> Void)?
    private var installedFor: CGRect = .null

    func reinstall() {
        installedFor = .null
        #if canImport(AppKit)
        needsLayout = true
        #else
        setNeedsLayout()
        #endif
    }

    private func installIfNeeded() {
        #if canImport(AppKit)
        guard let layer else { return }
        #endif
        guard bounds != installedFor, !bounds.isEmpty, let install else { return }
        installedFor = bounds
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        install(layer, bounds)
        CATransaction.commit()
    }

    #if canImport(AppKit)
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        installIfNeeded()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { reinstall() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        installIfNeeded()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { reinstall() }
    }
    #endif
}

#if canImport(AppKit)
typealias PlatformView = NSView
extension LayerEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> LayerEffectHost {
        let v = LayerEffectHost(frame: .zero)
        v.install = install
        return v
    }
    func updateNSView(_ v: LayerEffectHost, context: Context) {
        v.install = install
        v.reinstall()
    }
}
#else
typealias PlatformView = UIView
extension LayerEffect: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerEffectHost {
        let v = LayerEffectHost(frame: .zero)
        v.install = install
        return v
    }
    func updateUIView(_ v: LayerEffectHost, context: Context) {
        v.install = install
        v.reinstall()
    }
}
#endif

extension CABasicAnimation {
    /// A forever loop of `keyPath` from → to (autoreversing = a breath).
    static func loop(_ keyPath: String, from: Any, to: Any, duration: Double,
                     autoreverses: Bool = false, easeInOut: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = autoreverses
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: easeInOut ? .easeInEaseOut : .linear)
        return a
    }
}

// MARK: colour helpers (CGColor on both platforms)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    let hue = h - floor(h)
    #if canImport(AppKit)
    return NSColor(hue: hue, saturation: s, brightness: b, alpha: a).cgColor
    #else
    return UIColor(hue: hue, saturation: s, brightness: b, alpha: a).cgColor
    #endif
}

public extension CAKeyframeAnimation {
    /// A forever keyframe loop; `discrete` = hard steps (PSX palette flips).
    static func cycle(_ keyPath: String, values: [Any], duration: Double,
                      discrete: Bool = false) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.calculationMode = discrete ? .discrete : .linear
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }
}
