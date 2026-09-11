import SwiftUI
import QuartzCore

/// T3's `<Spinner>` (ui/spinner.tsx): the lucide `loader-circle` under
/// `animate-spin` (one linear turn a second). The rotation is a CAAnimation
/// on a `LayerEffect` host — the app does no work per frame (#18).
public struct T3Spinner: View {
    @Environment(\.t3) private var t3
    let size: Double
    public init(size: Double = 16) { self.size = size }
    public var body: some View {
        let c = t3.web.iconMuted
        return LayerEffect { host, bounds in
            let arc = CAShapeLayer()
            arc.frame = bounds
            arc.path = LucideShape(icon: .loaderCircle).path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
            arc.contentsScale = host.contentsScale   // a stroked path rasterizes at this scale
            arc.fillColor = nil
            arc.strokeColor = rgb(c.r / 255, c.g / 255, c.b / 255, c.a)
            arc.lineWidth = 2 * bounds.width / 24
            arc.lineCap = .round
            arc.lineJoin = .round
            arc.add(CABasicAnimation.loop("transform.rotation.z", from: 0, to: 2 * Double.pi, duration: 1),
                    forKey: "spin")
            host.addSublayer(arc)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }
}
