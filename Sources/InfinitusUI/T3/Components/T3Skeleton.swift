import SwiftUI
import QuartzCore

/// T3's `<Skeleton>` (ui/skeleton.tsx): "rounded-sm bg-muted-foreground/15"
/// under `animate-skeleton` — the stepped 1 → 0.55 → 1 breath of index.css's
/// `@keyframes skeleton`, as a CAAnimation so nothing ticks in-process (#18).
public struct T3Skeleton: View {
    @Environment(\.t3) private var t3
    let width: Double?
    let height: Double
    public init(width: Double? = nil, height: Double = 16) { self.width = width; self.height = height }
    public var body: some View {
        let c = t3.web.mutedForeground
        return LayerEffect { host, bounds in
            let bar = CALayer()
            bar.frame = bounds
            bar.cornerRadius = T3Theme.Metrics.radius - 4   // rounded-sm = calc(--radius - 4px)
            bar.contentsScale = host.contentsScale
            bar.backgroundColor = rgb(c.r / 255, c.g / 255, c.b / 255, c.a * 0.15)
            let breath = CAKeyframeAnimation(keyPath: "opacity")
            breath.values = [1, 1, 0.55, 0.55, 1]
            breath.keyTimes = [0, 0.42, 0.5, 0.92, 1]
            breath.duration = 2.4
            breath.repeatCount = .infinity
            breath.isRemovedOnCompletion = false
            bar.add(breath, forKey: "skeleton")
            host.addSublayer(bar)
        }
        .frame(width: width.map { CGFloat($0) }, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
}
