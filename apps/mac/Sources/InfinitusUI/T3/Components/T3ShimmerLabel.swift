import SwiftUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// T3's `<ActivityShimmerOverlay>` (`MessagesTimeline.tsx:2073-2084`) and the
/// `live-tool-shine` utility (`web-index.css:428-455`, `:463-537`): the label
/// is drawn twice — once in `secondary-label`, once in `foreground` behind a
/// 4.5 rem (72 pt) soft-edged window that sweeps left → right, linear, 2.2 s,
/// forever. The mask's alpha stops are the CSS gradient's, verbatim
/// (`web-index.css:487-497`: 0, 12% at 0.675rem, 55% at 1.575rem, black at
/// 2.25rem, 55% at 2.925rem, 12% at 3.825rem, 0 at 4.5rem).
///
/// The travel is a CAAnimation on a `LayerEffect` host, so nothing ticks in
/// process (#18) — and the host's `viewDidMoveToWindow` reinstall is what
/// keeps the sweep alive after a `LazyVStack` row scrolls out and back in
/// (CA drops animations from a detached layer).
///
/// Both copies are `CATextLayer`s, so the highlight aligns with the base by
/// construction; the caller lays the view out under a hidden SwiftUI `Text`
/// of the same string and size (glyph antialiasing therefore differs a hair
/// from the neighbouring SwiftUI labels — the only way to have SwiftUI drive
/// the layout and Core Animation drive the pixels).
///
/// `Equatable` on the inputs, so a caller can wrap it in `.equatable()`:
/// `LayerEffect.updateNSView` reinstalls its layers and the sweep restarts from
/// phase 0, so an update that changed nothing must not reach it.
public struct T3ShimmerLabel: View, Equatable {
    let text: String
    let fontSize: Double
    let base: T3RGBA
    let highlight: T3RGBA

    public init(text: String, fontSize: Double, base: T3RGBA, highlight: T3RGBA) {
        self.text = text; self.fontSize = fontSize; self.base = base; self.highlight = highlight
    }

    public static func == (l: T3ShimmerLabel, r: T3ShimmerLabel) -> Bool {
        l.text == r.text && l.fontSize == r.fontSize && l.base == r.base && l.highlight == r.highlight
    }

    /// `--live-activity-focus-width: 4.5rem`.
    private static let band: Double = 72

    public var body: some View {
        LayerEffect { [text, fontSize, base, highlight] host, bounds in
            #if canImport(UIKit)
            let font = UIFont.systemFont(ofSize: fontSize)
            #else
            let font = NSFont.systemFont(ofSize: fontSize)
            #endif
            func layer(_ colour: T3RGBA) -> CATextLayer {
                let l = CATextLayer()
                l.frame = bounds
                l.contentsScale = host.contentsScale
                l.font = font
                l.fontSize = fontSize
                l.string = text
                l.truncationMode = .end
                l.isWrapped = false
                l.alignmentMode = .left
                l.foregroundColor = rgb(colour.r / 255, colour.g / 255, colour.b / 255, colour.a)
                return l
            }
            let shine = layer(highlight)
            let window = CAGradientLayer()
            window.startPoint = CGPoint(x: 0, y: 0.5)
            window.endPoint = CGPoint(x: 1, y: 0.5)
            window.colors = [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.12), rgb(0, 0, 0, 0.55), rgb(0, 0, 0, 1),
                             rgb(0, 0, 0, 0.55), rgb(0, 0, 0, 0.12), rgb(0, 0, 0, 0)]
            window.locations = [0, 0.15, 0.35, 0.5, 0.65, 0.85, 1]
            window.frame = CGRect(x: -Self.band, y: 0, width: Self.band, height: bounds.height)
            shine.mask = window
            window.add(CABasicAnimation.loop("position.x", from: -Self.band / 2,
                                             to: bounds.width + Self.band / 2, duration: 2.2),
                       forKey: "shine")
            host.masksToBounds = true
            host.addSublayer(layer(base))
            host.addSublayer(shine)
        }
        .allowsHitTesting(false)
    }
}
