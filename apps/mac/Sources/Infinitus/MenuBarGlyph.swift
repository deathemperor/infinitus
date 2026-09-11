import AppKit

/// The status-item glyph: the Infinitus twin loop — two rings fused at
/// the center into a lemniscate. Reads as ∞ at Dock size and as two
/// linked circles at 16pt, which is where the old single-stroke ∞ failed
/// (blur, 2026-08-30). This path is the identity's source of truth —
/// make-icon.swift scales the same coordinates up for AppIcon.icns. The
/// right ring is broken between 10° and 70° for the swap arrow (user
/// 2026-08-30: the bar shows the arrow too). Template image, so the bar
/// tints it for light/dark and the pressed state.
enum MenuBarGlyph {
    /// Ring geometry in the 17×16 design box; shared with make-icon.swift.
    static let radius: CGFloat = 3.2
    static let leftCenter = NSPoint(x: 6.0, y: 8.0)
    static let rightCenter = NSPoint(x: 11.0, y: 8.0)

    static let image: NSImage = draw(tint: nil)

    /// The same loop in the theme's flash color (#90, user 2026-09-05:
    /// "themify the menubar"): not a template, so the bar leaves the
    /// color alone. One image per color, drawn once.
    nonisolated(unsafe) private static var themed: [String: NSImage] = [:]
    static func image(tint: NSColor, key: String) -> NSImage {
        if let cached = themed[key] { return cached }
        let img = draw(tint: tint)
        themed[key] = img
        return img
    }

    private static func draw(tint: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 17, height: 16), flipped: false) { _ in
            (tint ?? NSColor.black).set()
            let ring = NSBezierPath()
            ring.lineWidth = 2.0
            ring.appendOval(in: NSRect(x: leftCenter.x - radius, y: leftCenter.y - radius,
                                       width: radius * 2, height: radius * 2))
            ring.stroke()
            let arc = NSBezierPath()
            arc.lineWidth = 2.0
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: rightCenter, radius: radius,
                          startAngle: 70, endAngle: 10, clockwise: false)
            arc.stroke()
            // Arrowhead at the arc's start, pointing clockwise into the gap.
            let a = 70.0 * CGFloat.pi / 180
            let p = NSPoint(x: rightCenter.x + radius * cos(a), y: rightCenter.y + radius * sin(a))
            let t = NSPoint(x: sin(a), y: -cos(a))
            let n = NSPoint(x: cos(a), y: sin(a))
            let head = NSBezierPath()
            head.move(to: NSPoint(x: p.x + 2.3 * t.x, y: p.y + 2.3 * t.y))
            head.line(to: NSPoint(x: p.x + 1.7 * n.x, y: p.y + 1.7 * n.y))
            head.line(to: NSPoint(x: p.x - 1.7 * n.x, y: p.y - 1.7 * n.y))
            head.close()
            head.fill()
            return true
        }
        img.isTemplate = tint == nil
        return img
    }
}
