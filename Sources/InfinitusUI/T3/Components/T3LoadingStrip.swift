import SwiftUI
import QuartzCore

/// T3's `<LoadingStrip>` (apps/mobile/src/components/LoadingStrip.tsx): the
/// 2 px indeterminate bar across the top of a screen — a `primary` indicator
/// (30% of the width, at least 48 pt) sweeping in 1.1 s. The travel is a
/// CAAnimation on a `LayerEffect` host, so nothing ticks in-process (#18).
public struct T3LoadingStrip: View {
    @Environment(\.t3) private var t3
    public init() {}
    public var body: some View {
        let c = t3.mobile.primary
        return LayerEffect { host, bounds in
            let width = max(48, bounds.width * 0.3)
            let bar = CALayer()
            bar.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.cornerRadius = bounds.height / 2
            bar.contentsScale = host.contentsScale
            bar.backgroundColor = rgb(c.r / 255, c.g / 255, c.b / 255, c.a)
            let sweep = CABasicAnimation.loop("position.x", from: -width / 2,
                                              to: bounds.width + width / 2, duration: 1.1,
                                              easeInOut: true)
            bar.add(sweep, forKey: "sweep")
            host.masksToBounds = true
            host.addSublayer(bar)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
