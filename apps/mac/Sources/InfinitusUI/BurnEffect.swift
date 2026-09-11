import SwiftUI

/// Pace-fire overlays for GaugeBar: when a window burns faster than
/// time passes, its bar catches fire (user 2026-08-31 — "flaming or
/// FFVII limit break", then "need flaming effects, full bar effects").
/// Three auditionable styles; `heat` 0…1 (GaugeMath.burnHeat — +30
/// points ahead saturates) scales COVERAGE as well as size, count,
/// speed and brightness: low heat burns near the fill tip, heat ≈ 1
/// sets the whole fill ablaze.
///
/// Pure Core Animation on a `LayerEffect` host (#18): the heat fill,
/// coals and tongues are layers with looping flicker/sway animations,
/// sparks are a CAEmitterLayer, the limit marquee a stepped gradient
/// walking in 2pt keyframes — nothing per frame in-process. The old
/// 20 fps TimelineView/Canvas cost ~11% idle CPU with a few bars
/// ablaze, all of it commit overhead. Layout (coal spots, tongue
/// slots) comes from hashed seeds, so a bar looks the same each time.
/// The overlay exists ONLY while something burns (the caller gates on
/// heat > 0 and style).
struct BurnOverlay: View {
    let style: String
    let heat: Double
    let fillFraction: Double   // 0…1, the animated fill tip
    let barWidth: Double
    let barHeight: Double
    /// The bar's corner radius — the capsule's half height, the HUD's 3.
    let cornerRadius: Double

    /// How far flames rise above the capsule. Tall on purpose — the
    /// first cut capped this at 6 and read as "not dramatic enough"
    /// (user 2026-08-31); overlapping the row above is accepted drama.
    private let rise: Double = 11

    var body: some View {
        LayerEffect { host, bounds in
            guard fillFraction > 0.03, heat > 0 else { return }
            let bar = CGRect(x: 0, y: rise, width: bounds.width,
                             height: bounds.height - rise)
            let tipX = bar.width * fillFraction
            // The WHOLE fill burns at any heat (user 2026-08-31,
            // twice: limit round then "amber effect still looking
            // missing left parts of bar") — heat drives intensity,
            // count and speed, never span.
            let x0 = 0.0
            switch style {
            case "ember": ember(host, bar, x0, tipX)
            case "flame": flame(host, bar, x0, tipX)
            case "limit": limit(host, bar, x0, tipX)
            default: break
            }
        }
        .frame(width: barWidth, height: barHeight + rise)
        .allowsHitTesting(false)
    }

    // MARK: shared bits

    private var bright: Double { 0.5 + 0.5 * heat }

    /// Deterministic hash noise 0…1 (replayable, unlike Double.random).
    private func n(_ i: Double) -> Double {
        let v = sin(i * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }

    private func emberOrange(_ a: Double) -> CGColor { rgb(1.00, 0.45, 0.10, a) }
    private func flameYellow(_ a: Double) -> CGColor { rgb(1.00, 0.85, 0.30, a) }
    private func coreWhite(_ a: Double) -> CGColor { rgb(1.00, 0.96, 0.85, a) }

    /// The capsule-shaped clip every in-bar layer lives in.
    private func clip(_ bar: CGRect) -> CALayer {
        let c = CALayer()
        c.frame = bar
        c.cornerRadius = cornerRadius
        c.masksToBounds = true
        return c
    }

    /// A soft radial glow (coals, the tip coal): yellow core → orange →
    /// clear, `r` radius, flickering by scale between `low` and 1.
    private func coal(at center: CGPoint, r: Double, core: CGColor, mid: Double,
                      low: Double, period: Double) -> CALayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.frame = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.colors = [core, emberOrange(mid * bright), emberOrange(0)]
        g.locations = [0, 0.5, 1]
        g.add(CABasicAnimation.loop("transform.scale", from: 1, to: low, duration: period / 2,
                                    autoreverses: true, easeInOut: true), forKey: "flicker")
        return g
    }

    /// One shared white disc for every spark (CAEmitterCell wants a
    /// CGImage; the cell tints it). 16px, scaled down to ~2pt.
    static let sparkDot: CGImage? = {
        let px = 16
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: px * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: px - 2, height: px - 2))
        return ctx.makeImage()
    }()

    /// Sparks drifting up off the burning region — a CAEmitterLayer,
    /// so the particles live in the render server.
    private func sparks(_ host: CALayer, _ bar: CGRect, _ x0: Double, _ tipX: Double,
                        count: Int) {
        let cell = CAEmitterCell()
        cell.contents = Self.sparkDot
        let life: Float = 1.25
        cell.lifetime = life
        cell.lifetimeRange = 0.45
        cell.birthRate = Float(count) / life
        cell.color = flameYellow(bright)
        cell.alphaSpeed = -1 / life
        // Rasterised at the host's scale (1x on retina reads as a smear);
        // the 16px disc lands at 2pt across.
        let scale = host.contentsScale
        cell.contentsScale = scale
        cell.scale = 2.0 * scale / 16
        cell.scaleSpeed = -0.6 * cell.scale / CGFloat(life)
        // Straight up. Probed 2026-09-03: a `.line` emitter's longitude
        // is rotated a quarter turn from a `.point` one's (0 = up,
        // π/2 = right, π = down) — hence 0, not ±π/2. One bar height
        // per cycle, a little sideways jitter for the sway.
        cell.emissionLongitude = 0
        cell.emissionRange = 0.25
        cell.velocity = (bar.midY + 1) / CGFloat(life)
        cell.velocityRange = 3
        let e = CAEmitterLayer()
        e.contentsScale = scale
        e.frame = CGRect(x: 0, y: 0, width: bar.width, height: bar.maxY)
        e.emitterShape = .line
        e.emitterPosition = CGPoint(x: (x0 + tipX) / 2, y: bar.midY)
        e.emitterSize = CGSize(width: max(1, tipX - x0), height: 1)
        e.emitterCells = [cell]
        e.seed = UInt32(truncatingIfNeeded: Int(x0 * 7 + tipX * 13))
        // Pre-warm: no empty bar while the first particles fill in.
        e.beginTime = CACurrentMediaTime() - Double(life)
        host.addSublayer(e)
    }

    // MARK: styles

    /// Ember glow — the burning region smolders (gradient heat inside
    /// the fill), coals dotted through it, a big pulsing coal at the
    /// tip, sparks everywhere ("more flames and embers", user
    /// 2026-08-31 round 3).
    private func ember(_ host: CALayer, _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let inBar = clip(bar)
        let heatFill = CAGradientLayer()
        heatFill.frame = CGRect(x: x0, y: 0, width: tipX - x0, height: bar.height)
        heatFill.startPoint = CGPoint(x: 0, y: 0.5)
        heatFill.endPoint = CGPoint(x: 1, y: 0.5)
        // A real floor at the left edge — a 0-opacity start read as
        // "missing left parts" (user screenshot).
        heatFill.colors = [emberOrange(0.30 * bright), emberOrange(0.6 * bright),
                           flameYellow(0.8 * bright)]
        heatFill.locations = [0, 0.55, 1]
        heatFill.add(CABasicAnimation.loop("opacity", from: 1, to: 0.8, duration: 0.85,
                                           autoreverses: true, easeInOut: true), forKey: "pulse")
        inBar.addSublayer(heatFill)
        // Coals smoldering along the burning region (not just the tip).
        let coals = 2 + Int(heat * 3.99)
        for i in 0..<coals {
            let seed = Double(i) * 5.13
            let cx = x0 + (0.1 + 0.75 * n(seed)) * max(1, tipX - x0)
            inBar.addSublayer(coal(at: CGPoint(x: cx, y: bar.height / 2),
                                   r: 1.6 + 2.2 * heat, core: flameYellow(0.85 * bright),
                                   mid: 0.5, low: 0.3,
                                   period: 2 * .pi / (3.5 + n(seed + 2) * 3)))
        }
        host.addSublayer(inBar)
        host.addSublayer(coal(at: CGPoint(x: tipX, y: bar.midY), r: 3.0 + 3.5 * heat,
                              core: coreWhite(0.9 * bright), mid: 0.6, low: 0.5,
                              period: 2 * .pi / 5.5))
        sparks(host, bar, x0, tipX, count: 6 + Int(heat * 9.99))
    }

    /// Flame licks — a dense wall of tongues across the WHOLE burning
    /// region, rising well above the bar, biggest at the tip. Each
    /// tongue is a CAShapeLayer flickering by scale (height) and
    /// swaying by a skew keyframe, anchored at its base.
    private func flame(_ host: CALayer, _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let span = max(1, tipX - x0)
        let count = max(5, min(18, Int(span / 3.5) + 1))
        let baseY = bar.midY + 1
        for i in 0..<count {
            let seed = Double(i) * 3.77
            let fx = tipX - span * Double(i) / Double(count) - n(seed + 5) * 2
            // Slight falloff away from the tip; every tongue stays big.
            let falloff = 1.0 - 0.35 * Double(i) / Double(max(1, count - 1))
            let h = 3.0 + (rise - 1.5) * heat * falloff
            let w = 3.8 - 1.2 * Double(i) / Double(max(1, count - 1))
            let flickPeriod = 2 * .pi / (4.0 + n(seed) * 3.5)
            let swayPeriod = 2 * .pi / (2.6 + n(seed + 1) * 2.2)
            for (k, color) in [(1.0, emberOrange(0.6 * bright)), (0.6, flameYellow(0.75 * bright))] {
                let t = CAShapeLayer()
                t.frame = CGRect(x: fx - w / 2, y: baseY - h, width: w, height: h)
                t.anchorPoint = CGPoint(x: 0.5, y: 1)
                t.position = CGPoint(x: fx, y: baseY)
                t.path = tongue(w: w * (k == 1 ? 1 : 0.55), h: h * k, box: t.bounds)
                t.fillColor = color
                // Height flicker 0.6…1 of h (the old hFlick sine).
                t.add(CABasicAnimation.loop("transform.scale.y", from: 1, to: 0.6,
                                            duration: flickPeriod / 2, autoreverses: true,
                                            easeInOut: true), forKey: "flick")
                // Sway: the tip leans ±2.2pt (×0.7 for the core) — a
                // rotation about the base (its own key path, so it
                // composes with the scale flicker).
                let lean = atan(2.2 * (k == 1 ? 1 : 0.7) / h)
                let sway = CAKeyframeAnimation.cycle("transform.rotation.z",
                                                     values: [lean, -lean, lean],
                                                     duration: swayPeriod)
                sway.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                        CAMediaTimingFunction(name: .easeInEaseOut)]
                t.add(sway, forKey: "sway")
                host.addSublayer(t)
            }
        }
        sparks(host, bar, x0, tipX, count: 6 + Int(heat * 7.99))
    }

    /// A tongue in its own box: base along the bottom edge, tip at the
    /// top centre, the old quad-curve silhouette.
    private func tongue(w: Double, h: Double, box: CGRect) -> CGPath {
        let p = CGMutablePath()
        let cx = box.midX, baseY = box.maxY
        p.move(to: CGPoint(x: cx - w / 2, y: baseY))
        p.addQuadCurve(to: CGPoint(x: cx, y: baseY - h),
                       control: CGPoint(x: cx - w / 2, y: baseY - h * 0.55))
        p.addQuadCurve(to: CGPoint(x: cx + w / 2, y: baseY),
                       control: CGPoint(x: cx + w / 2, y: baseY - h * 0.55))
        p.closeSubpath()
        return p
    }

    /// FFVII limit break — the PSX gauge, faithfully (user 2026-08-31:
    /// "pixel perfect & animation fidelity with FFVII"). No gradients,
    /// no anti-aliasing, no alpha ramps: chunky 2pt pixels in hard
    /// palette bands. The burning region runs the classic tip-ward
    /// palette marquee (one white shine head per cycle), the whole
    /// band blinks in stepped palette-swap pulses (a frame flip, not a
    /// sine) and the fill tip runs white-hot. Everything stays INSIDE
    /// the capsule — the FFVII gauge floats nothing above itself.
    ///
    /// As CA: one wide stepped gradient (two palette cycles) sliding
    /// tip-ward one cycle per period — the marquee — its position
    /// keyframed in 2pt steps (discrete, so it stays on the pixel
    /// grid), the blink and tip flip discrete opacity keyframes.
    private func limit(_ host: CALayer, _ bar: CGRect, _ x0: Double, _ tipX: Double) {
        let px = 2.0                                  // the "pixel"
        func q(_ v: Double) -> Double { (v / px).rounded(.down) * px }
        let hot2 = 0.6 + 0.4 * heat
        // The FFVII full-gauge shimmer is a RAINBOW marquee (user
        // 2026-08-31 screenshot note) — one hard band per hue plus the
        // white shine head, cycling end to end.
        let palette: [CGColor] = [
            rgb(1.00, 0.20, 0.20), rgb(1.00, 0.60, 0.10), rgb(1.00, 0.95, 0.20),
            rgb(0.30, 1.00, 0.35), rgb(0.25, 0.90, 1.00), rgb(0.35, 0.45, 1.00),
            rgb(0.85, 0.40, 1.00), coreWhite(1),          // shine head
        ]
        let cellsPerBand = 2
        let cycle = Double(palette.count * cellsPerBand) * px   // 16 cells = 32pt
        let inBar = clip(bar)
        inBar.opacity = Float(0.85 * hot2)
        // The band as hard stops: colour i spans [i/n, (i+1)/n].
        let n = palette.count
        var colors: [CGColor] = [], locations: [NSNumber] = []
        for rep in 0..<2 {
            for (i, c) in palette.enumerated() {
                let lo = (Double(rep * n + i)) / Double(2 * n)
                let hi = (Double(rep * n + i + 1)) / Double(2 * n)
                colors += [c, c]; locations += [NSNumber(value: lo), NSNumber(value: hi)]
            }
        }
        let band = CAGradientLayer()
        band.colors = colors
        band.locations = locations
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        // Cover the fill with whole cycles plus one spare to slide over.
        let copies = Int((tipX / cycle).rounded(.up)) + 1
        let width = cycle * Double(copies)
        band.anchorPoint = .zero
        band.bounds = CGRect(x: 0, y: 0, width: width, height: bar.height)
        // Slide tip-ward one cycle per period in 2pt steps — the palette
        // walks column to column (the old `scroll` integer).
        let steps = Int(cycle / px)
        let xs: [Double] = (0...steps).map { -cycle + Double($0) * px }
        band.position = CGPoint(x: xs[0], y: 0)
        band.add(CAKeyframeAnimation.cycle("position.x", values: xs,
                                           duration: 1.1 - 0.5 * heat, discrete: true),
                 forKey: "marquee")
        // Stepped palette-swap blink: PSX pulsing was a frame flip.
        band.add(CAKeyframeAnimation.cycle("opacity", values: [1, 0.72],
                                           duration: 1 / (1.4 + 1.6 * heat), discrete: true),
                 forKey: "blink")
        // The wide band only shows through the fill columns.
        let fillMask = CALayer()
        fillMask.frame = CGRect(x: 0, y: 0, width: (tipX / px).rounded(.up) * px,
                                height: bar.height)
        fillMask.backgroundColor = rgb(0, 0, 0)
        let bandBox = CALayer()
        bandBox.frame = inBar.bounds
        bandBox.mask = fillMask
        bandBox.addSublayer(band)
        inBar.addSublayer(bandBox)
        // White-hot tip: the leading pixel columns flip harder.
        for j in 1...2 {
            let x = q(tipX) - Double(j) * px
            guard x >= 0 else { break }
            let tip = CALayer()
            tip.frame = CGRect(x: x, y: 0, width: px, height: bar.height)
            tip.backgroundColor = coreWhite(1)   // ×0.85·hot2 from the group
            tip.add(CAKeyframeAnimation.cycle("opacity", values: [1, 0.6], duration: 1.0 / 6,
                                              discrete: true), forKey: "flip")
            inBar.addSublayer(tip)
        }
        host.addSublayer(inBar)
    }
}

/// The killing-blow finisher (user 2026-08-31: "a dramatic dead effect
/// if any kind of drops kill"): when an HP drop drains a bar to ZERO,
/// shards burst off it — ember and ash flying radially with a little
/// gravity — while GaugeBar shakes the bar at full zoom. One-shot,
/// deterministic seeds, exists only for ~0.9s per kill.
struct KillBurst: View {
    let tick: Int
    @State private var start: Date?
    /// The TimelineView exists only during the 0.9s burst: an always-on
    /// .animation timeline on EVERY bar re-rendered the row tree at
    /// display rate for nothing (#18).
    @State private var live = false

    var body: some View {
        Group {
            if live {
                burst
            } else {
                Color.clear
            }
        }
        .onChange(of: tick) { _, _ in
            start = Date()
            live = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { live = false }
        }
        .allowsHitTesting(false)
    }

    private var burst: some View {
        TimelineView(.animation) { ctx in
            Canvas { c, size in
                guard let start else { return }
                let t = ctx.date.timeIntervalSince(start)
                guard t >= 0, t < 0.9 else { return }
                let cx = size.width / 2
                let cy = size.height / 2
                for i in 0..<20 {
                    let seed = Double(i) * 3.19
                    let ang = n(seed) * .pi * 2
                    let v = 28 + n(seed + 1) * 60
                    let x = cx + cos(ang) * v * t
                    let y = cy + sin(ang) * v * t * 0.55 + 46 * t * t
                    let fade = max(0, 1 - t / 0.9)
                    let r = (1.1 + n(seed + 2) * 1.7) * fade
                    let color: Color = i % 3 == 0
                        ? Color(red: 1.00, green: 0.96, blue: 0.85)
                        : i % 2 == 0
                        ? Color(red: 1.00, green: 0.45, blue: 0.10)
                        : Color(red: 0.90, green: 0.12, blue: 0.08)
                    c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(color.opacity(fade)))
                }
            }
        }
    }

    private func n(_ i: Double) -> Double {
        let v = sin(i * 12.9898) * 43758.5453
        return v - v.rounded(.down)
    }
}
