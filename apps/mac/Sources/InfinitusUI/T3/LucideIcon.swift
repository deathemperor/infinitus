import SwiftUI
import InfinitusCore

/// A lucide icon drawn the way lucide-react draws it: 24-unit view box,
/// `stroke="currentColor"`, `stroke-width` 2, round caps and joins, no fill.
public struct LucideIcon: View {
    public let icon: Lucide
    public let size: Double
    public let strokeWidth: Double
    public init(_ icon: Lucide, size: Double = 16, strokeWidth: Double = 2) {
        self.icon = icon; self.size = size; self.strokeWidth = strokeWidth
    }
    public var body: some View {
        LucideShape(icon: icon)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LucideShape: Shape {
    let icon: Lucide
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var p = Path()
        for d in icon.paths {
            var cur = CGPoint.zero
            for c in SVGPath.parse(d) {
                switch c {
                case let .move(x, y): cur = CGPoint(x: x, y: y); p.move(to: pt(cur, s, rect))
                case let .line(x, y): cur = CGPoint(x: x, y: y); p.addLine(to: pt(cur, s, rect))
                case let .cubic(x1, y1, x2, y2, x, y):
                    cur = CGPoint(x: x, y: y)
                    p.addCurve(to: pt(cur, s, rect), control1: pt(CGPoint(x: x1, y: y1), s, rect), control2: pt(CGPoint(x: x2, y: y2), s, rect))
                case let .quad(x1, y1, x, y):
                    cur = CGPoint(x: x, y: y)
                    p.addQuadCurve(to: pt(cur, s, rect), control: pt(CGPoint(x: x1, y: y1), s, rect))
                case let .arc(rx, ry, rotation, large, sweep, x, y):
                    let to = CGPoint(x: x, y: y)
                    p.addPath(SVGArc.path(from: cur, to: to, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, scale: s, in: rect))
                    cur = to
                case .close: p.closeSubpath()
                }
            }
        }
        return p
    }
    private func pt(_ p: CGPoint, _ s: CGFloat, _ r: CGRect) -> CGPoint { CGPoint(x: r.minX + p.x * s, y: r.minY + p.y * s) }
}

/// SVG elliptical arc → cubic Béziers (the standard endpoint→centre conversion, SVG spec §B.2.4).
enum SVGArc {
    static func path(from: CGPoint, to: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool, scale: CGFloat, in rect: CGRect) -> Path {
        var p = Path()
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || from == to { p.move(to: CGPoint(x: rect.minX + from.x * scale, y: rect.minY + from.y * scale)); p.addLine(to: CGPoint(x: rect.minX + to.x * scale, y: rect.minY + to.y * scale)); return p }
        let phi = rotation * .pi / 180, cosφ = cos(phi), sinφ = sin(phi)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1p = cosφ * dx + sinφ * dy, y1p = -sinφ * dx + cosφ * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(num / den); if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cosφ * cxp - sinφ * cyp + (from.x + to.x) / 2, cy = sinφ * cxp + cosφ * cyp + (from.y + to.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let θ1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dθ = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, dθ > 0 { dθ -= 2 * .pi } else if sweep, dθ < 0 { dθ += 2 * .pi }
        let segments = Int(ceil(abs(dθ) / (.pi / 2)))
        let δ = dθ / Double(segments), t = 4 / 3 * tan(δ / 4)
        var θ = θ1
        func point(_ a: Double) -> CGPoint {
            let x = cx + rx * cos(a) * cosφ - ry * sin(a) * sinφ, y = cy + rx * cos(a) * sinφ + ry * sin(a) * cosφ
            return CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func deriv(_ a: Double) -> CGPoint {
            let x = -rx * sin(a) * cosφ - ry * cos(a) * sinφ, y = -rx * sin(a) * sinφ + ry * cos(a) * cosφ
            return CGPoint(x: x * scale, y: y * scale)
        }
        p.move(to: point(θ))
        for _ in 0..<segments {
            let θ2 = θ + δ
            let p0 = point(θ), p3 = point(θ2), d0 = deriv(θ), d3 = deriv(θ2)
            p.addCurve(to: p3, control1: CGPoint(x: p0.x + t * d0.x, y: p0.y + t * d0.y), control2: CGPoint(x: p3.x - t * d3.x, y: p3.y - t * d3.y))
            θ = θ2
        }
        return p
    }
}

#Preview {
    HStack {
        LucideIcon(.arrowUp)
        LucideIcon(.gitBranch)
        LucideIcon(.circleCheck)
    }
    .padding()
}
