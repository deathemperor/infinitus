import SwiftUI

/// The twin loop as a pure SwiftUI `Shape` — the same geometry the status
/// item's NSBezierPath draws (Infinitus/MenuBarGlyph.swift, the identity's
/// source of truth alongside make-icon.swift), ported so the popup header
/// renders on a platform without AppKit (#9 phase B2). AppKit keeps its
/// copy: NSStatusItem needs an NSImage, not a View.
///
/// Two coordinate flips to keep in mind against MenuBarGlyph:
///   * NSImage(flipped: false) is y-up, SwiftUI is y-down — `pt` mirrors
///     y about the 16pt-tall design box, so every literal below stays
///     verbatim from the AppKit path.
///   * The mirror also reverses winding, so the arc that AppKit sweeps
///     counter-clockwise from 70° to 10° is `clockwise: true` here (and
///     the end angle is written as -370° so the sweep is the LONG way
///     round, leaving the 10°–70° gap the swap arrow lives in).
public struct InfinitusGlyph: Shape {
    /// Ring geometry in the 17×16 design box; mirrors MenuBarGlyph's.
    public static let radius: CGFloat = 3.2
    public static let leftCenter = CGPoint(x: 6.0, y: 8.0)
    public static let rightCenter = CGPoint(x: 11.0, y: 8.0)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Aspect-fit the design box, exactly like the header's
        // Image().scaledToFit() did with the 17×16 template.
        let s = min(rect.width / 17, rect.height / 16)
        let ox = rect.minX + (rect.width - 17 * s) / 2
        let oy = rect.minY + (rect.height - 16 * s) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + (16 - y) * s)
        }
        let r = Self.radius * s
        var path = Path()
        let left = pt(Self.leftCenter.x, Self.leftCenter.y)
        let ring = Path(ellipseIn: CGRect(x: left.x - r, y: left.y - r,
                                          width: r * 2, height: r * 2))
        path.addPath(ring.strokedPath(StrokeStyle(lineWidth: 2 * s)))
        var arc = Path()
        arc.addArc(center: pt(Self.rightCenter.x, Self.rightCenter.y), radius: r,
                   startAngle: .degrees(-70), endAngle: .degrees(-370),
                   clockwise: true)
        path.addPath(arc.strokedPath(StrokeStyle(lineWidth: 2 * s, lineCap: .round)))
        // Arrowhead at the arc's start, pointing clockwise into the gap.
        let a = 70.0 * CGFloat.pi / 180
        let p = CGPoint(x: Self.rightCenter.x + Self.radius * cos(a),
                        y: Self.rightCenter.y + Self.radius * sin(a))
        let t = CGPoint(x: sin(a), y: -cos(a))
        let n = CGPoint(x: cos(a), y: sin(a))
        var head = Path()
        head.move(to: pt(p.x + 2.3 * t.x, p.y + 2.3 * t.y))
        head.addLine(to: pt(p.x + 1.7 * n.x, p.y + 1.7 * n.y))
        head.addLine(to: pt(p.x - 1.7 * n.x, p.y - 1.7 * n.y))
        head.closeSubpath()
        path.addPath(head)
        return path
    }
}
