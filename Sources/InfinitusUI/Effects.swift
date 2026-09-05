import SwiftUI

/// The account-switch celebration: a bright sweep that runs across the row
/// plus a brief accent glow. Attach to the active row; fires whenever
/// `trigger` changes (AppModel bumps it on every observed switch).
struct SwitchFlash: ViewModifier {
    let trigger: Int
    var color: Color = .accentColor

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    // keyframeAnimator restarts cleanly on every trigger
                    // bump — phaseAnimator would keep cycling forever.
                    let width = geo.size.width
                    Rectangle()
                        .fill(
                            // The shoulders carry the THEME color — with
                            // them at opacity 0 the band was pure white
                            // and every theme celebrated identically
                            // (user report 2026-08-30).
                            LinearGradient(
                                colors: [.clear,
                                         color.opacity(0.30),
                                         Color.white.opacity(0.35),
                                         color.opacity(0.30),
                                         .clear],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(60, width * 0.25))
                        .keyframeAnimator(
                            initialValue: -0.35,
                            trigger: trigger
                        ) { view, x in
                            view.offset(x: x * width)
                        } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(-0.35, duration: 0.001)
                                CubicKeyframe(1.15, duration: 0.85)
                            }
                        }
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, glow in
                // A translucent wash, not just a shadow: the Grid layout
                // hosts this on a CLEAR overlay rect, and a shadow of
                // transparent content is invisible.
                view
                    .overlay { color.opacity(glow * 0.15).allowsHitTesting(false) }
                    .shadow(color: color.opacity(glow),
                            radius: 8 * glow)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: 0.25)
                    CubicKeyframe(0.0, duration: 0.9)
                }
            }
    }
}

/// Highlights the EXACT data point that changed: when `value` moves, the
/// view flashes a soft accent glow + brief brightness lift, right where
/// the number is. Attach to any cell showing live data.
struct ValueChangedGlow<V: Equatable>: ViewModifier {
    let value: V
    var color: Color = .accentColor
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: value) { tick += 1 }
            .keyframeAnimator(initialValue: 0.0, trigger: tick) { view, glow in
                view
                    .shadow(color: color.opacity(glow), radius: 6 * glow)
                    .brightness(glow * 0.25)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(0.9, duration: 0.2)
                    CubicKeyframe(0.0, duration: 1.0)
                }
            }
    }
}

extension View {
    /// Theme-tinted celebration sweep (color from RowTheme.flashColor).
    public func switchFlash(_ trigger: Int, color: Color = .accentColor) -> some View {
        modifier(SwitchFlash(trigger: trigger, color: color))
    }

    /// Glow in place whenever `value` changes.
    public func glowOnChange<V: Equatable>(of value: V, color: Color = .accentColor) -> some View {
        modifier(ValueChangedGlow(value: value, color: color))
    }
}

/// The death beat — the switch celebration's grim mirror (user
/// 2026-08-30: "play dead animation too when account goes alive ->
/// dead"). A red hit that flickers while the row drains gray, then a
/// small slump that settles. On the wide Grid this wraps a clear
/// overlay band (saturation is a no-op there; the row's own
/// dead-restyle does the draining) — stacked cards wrap real content
/// and get the full drain.
struct DeathFlash: ViewModifier {
    let trigger: Int
    var color: Color = .red

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, f in
                view
                    .saturation(1 - f)
                    .overlay { color.opacity(f * 0.22).allowsHitTesting(false) }
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(0.9, duration: 0.15)   // the hit
                    CubicKeyframe(0.35, duration: 0.15)  // flicker
                    CubicKeyframe(1.0, duration: 0.15)
                    CubicKeyframe(0.0, duration: 0.9)    // settle into gray
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, y in
                view.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(4, duration: 0.25)     // slump
                    SpringKeyframe(0, duration: 0.6, spring: .bouncy)
                }
            }
    }
}

extension View {
    /// Death beat; fires when `trigger` changes (0 = never armed).
    public func deathFlash(_ trigger: Int, color: Color = .red) -> some View {
        modifier(DeathFlash(trigger: trigger, color: color))
    }
}

/// The revival fanfare — the death beat's bright mirror (user
/// 2026-08-31: "account revive needs dramatic full line revival
/// glowing effect"). A green surge washes the whole row while a wide
/// bright sweep runs its length, the row lifts out of the slump and
/// settles, and the glow breathes twice before fading. Overlay-first
/// like SwitchFlash, so the wide Grid's CLEAR band hosts it too
/// (brightness alone is a no-op on transparent content).
struct ReviveFlash: ViewModifier {
    let trigger: Int
    var color: Color = .green

    func body(content: Content) -> some View {
        content
            // Full-length sweep: wider and slower than the switch
            // celebration — a resurrection, not a handoff. Parked
            // outside the clipped bounds until triggered.
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear,
                                         color.opacity(0.45),
                                         Color.white.opacity(0.55),
                                         color.opacity(0.45),
                                         .clear],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(80, width * 0.35))
                        .keyframeAnimator(
                            initialValue: -0.5,
                            trigger: trigger
                        ) { view, x in
                            view.offset(x: x * width)
                        } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(-0.5, duration: 0.001)
                                CubicKeyframe(1.2, duration: 1.1)
                            }
                        }
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, glow in
                view
                    .overlay { color.opacity(glow * 0.28).allowsHitTesting(false) }
                    .shadow(color: color.opacity(glow), radius: 12 * glow)
                    .brightness(glow * 0.18)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(1.0, duration: 0.20)   // the surge
                    CubicKeyframe(0.45, duration: 0.30)  // breathe out
                    CubicKeyframe(0.9, duration: 0.30)   // second pulse
                    CubicKeyframe(0.0, duration: 1.2)    // glow fades
                }
            }
            // The anti-slump: rise and settle.
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, y in
                view.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(-4, duration: 0.25)    // lift
                    SpringKeyframe(0, duration: 0.7, spring: .bouncy)
                }
            }
    }
}

extension View {
    /// Revival fanfare; fires when `trigger` changes (0 = never armed).
    public func reviveFlash(_ trigger: Int, color: Color = .green) -> some View {
        modifier(ReviveFlash(trigger: trigger, color: color))
    }
}

/// FFVII "All Lucky 7s" fever, done AUTHENTICALLY (user 2026-08-31
/// screenshot: Barret's menu entry): the character NAME wears a
/// per-letter rainbow whose colors travel along the text — a marquee,
/// not a blink — over a steady rainbow gradient band. Nothing flashes;
/// the original doesn't. Trigger (Fable at 77%, or 5h AND 7d both 77)
/// is decided at the call sites.
/// The fever's FULL-ROW treatment (user 2026-08-31, refined: "not
/// flashing but border will loop in circle"): a steady hue-cycling
/// rainbow wash over the whole row, rimmed by a neon border whose
/// rainbow CHASES around the perimeter — a rotating angular gradient,
/// no blinking anywhere. Sits BEHIND content.
public struct LuckyRowBackground: View {
    var cornerRadius: Double = 5

    public init(cornerRadius: Double = 5) {
        self.cornerRadius = cornerRadius
    }

    private static let rainbow: [CGColor] = [
        rgb(1.0, 0.2, 0.2), rgb(1.0, 0.6, 0.1), rgb(1.0, 0.95, 0.2),
        rgb(0.3, 1.0, 0.35), rgb(0.25, 0.9, 1.0), rgb(0.4, 0.45, 1.0),
        rgb(0.85, 0.4, 1.0), rgb(1.0, 0.2, 0.2),
    ]

    // Pure Core Animation (see LayerEffect): the wash cycles its colour
    // stops, the comet is a run of trimmed strokes sliding along the
    // outline. A SwiftUI TimelineView/Canvas here cost a full pop-out
    // commit per frame — 20+% idle CPU per effect (#18).
    public var body: some View {
        LayerEffect { host, bounds in
            let radius = cornerRadius
            // Steady wash; the slow colour walk keeps it alive without
            // any brightness change (no flash).
            let wash = CAGradientLayer()
            wash.frame = bounds
            wash.cornerRadius = radius
            wash.startPoint = CGPoint(x: 0, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 0.5)
            wash.colors = Self.rainbow
            wash.opacity = 0.18
            let n = Self.rainbow.count - 1   // last == first
            wash.add(CAKeyframeAnimation.cycle(
                "colors",
                values: (0...n).map { k in (0...n).map { Self.rainbow[(($0 - k) % n + n) % n] } },
                duration: 9), forKey: "walk")
            host.addSublayer(wash)
            // The neon border, Gemini-style (user 2026-08-31
            // screenshot): ONE luminous comet orbiting the outline — a
            // bright head with a soft tail fading behind it; the glow
            // pass is the same comet, wider and blurred.
            host.addSublayer(Self.comet(bounds: bounds, radius: radius, width: 4.5, glow: true))
            host.addSublayer(Self.comet(bounds: bounds, radius: radius, width: 1.8, glow: false))
        }
        .allowsHitTesting(false)
    }

    private static func comet(bounds: CGRect, radius: Double, width: Double, glow: Bool) -> CALayer {
        let box = CALayer()
        box.frame = bounds
        // The comet is a run of short trimmed strokes (bright head,
        // fading tail) sliding along the outline via strokeStart/End —
        // a fixed ARC LENGTH, so it reads the same on a wide row as on
        // a card. The path is laid twice so the wrap at 1 → 0 is a
        // seamless second lap. Same 14 × 1.2% geometry as the Canvas
        // original, hue drifting as it travels.
        let rect = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        let twice = CGMutablePath()
        twice.addPath(rect)
        twice.addPath(rect)
        let tailN = 14
        let segLen = 0.012 / 2   // fractions of the doubled path
        for k in 0..<tailN {
            let fade = pow(1 - Double(k) / Double(tailN), 2)
            let seg = CAShapeLayer()
            seg.frame = bounds
            seg.path = twice
            seg.fillColor = nil
            seg.lineWidth = width
            seg.lineCap = .round
            seg.opacity = Float(glow ? 0.8 * fade : fade)
            let hueOffset = Double(k) * 0.015
            seg.strokeColor = hsb(hueOffset, glow ? 0.9 : 0.75, 1)
            seg.add(CAKeyframeAnimation.cycle(
                "strokeColor", values: (0...6).map { hsb(Double($0) / 6 + hueOffset, glow ? 0.9 : 0.75, 1) },
                duration: 16.7), forKey: "drift")
            // One lap of the real outline = 0.5 of the doubled path.
            let from = 0.5 - Double(k + 1) * segLen
            seg.strokeStart = from
            seg.strokeEnd = from + segLen
            seg.add(CABasicAnimation.loop("strokeStart", from: from, to: from + 0.5, duration: 6.25),
                    forKey: "orbitStart")
            seg.add(CABasicAnimation.loop("strokeEnd", from: from + segLen, to: from + segLen + 0.5,
                                          duration: 6.25), forKey: "orbitEnd")
            box.addSublayer(seg)
        }
        if glow {
            #if os(macOS)
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(4, forKey: "inputRadius")
                box.filters = [blur]
            }
            #else
            box.opacity = 0.4
            #endif
        }
        return box
    }
}

/// The activating digits themselves (user 2026-08-31: "keep the
/// flashing 77 numbers that activated the effect"): the percent label
/// on a bar sitting at 77 flashes in hard frame steps — gold/white
/// like the 7777 damage pops, with a rainbow run.
struct LuckySevens: View {
    let text: String
    var font: Font = PopupFont.caption

    private static let steps: [CGColor] = [
        rgb(1.00, 0.85, 0.20), rgb(1, 1, 1),
        rgb(1.00, 0.85, 0.20), rgb(1, 1, 1),
        rgb(1.00, 0.25, 0.25), rgb(1.00, 0.60, 0.10), rgb(1.00, 0.95, 0.20),
        rgb(0.30, 1.00, 0.35), rgb(0.25, 0.90, 1.00), rgb(0.85, 0.40, 1.00),
    ]

    var body: some View {
        // The PSX palette flip as a discrete CA colour keyframe under a
        // text mask: hard 0.14s steps, nothing per frame in-process.
        Text(text)
            .font(font).bold().monospacedDigit()
            .foregroundStyle(.clear)
            .overlay {
                LayerEffect { host, bounds in
                    let g = CAGradientLayer()
                    g.frame = bounds
                    g.colors = [Self.steps[0], Self.steps[0]]
                    g.add(CAKeyframeAnimation.cycle(
                        "colors", values: Self.steps.map { [$0, $0] },
                        duration: 0.14 * Double(Self.steps.count), discrete: true), forKey: "flash")
                    host.addSublayer(g)
                }
                .mask(Text(text).font(font).bold().monospacedDigit())
            }
        .help("All Lucky 7s!")
    }
}

public struct LuckyName: View {
    let text: String
    var font: Font = PopupFont.body
    var bold = true

    public init(text: String, font: Font = PopupFont.body, bold: Bool = true) {
        self.text = text
        self.font = font
        self.bold = bold
    }

    public var body: some View {
        // The glyphs are a SwiftUI Text mask (exact metrics) over a CA
        // gradient marquee: rainbow twice across, sliding one period
        // per 2.67s (the old 0.045 hue per 0.12s step). Per-letter
        // colours travel letter-to-letter, nothing per frame in-process.
        let glyphs = Text(text).font(font).fontWeight(bold ? .bold : .regular)
        glyphs
            .foregroundStyle(.clear)
            .overlay {
                LayerEffect { host, bounds in
                    let g = CAGradientLayer()
                    g.startPoint = CGPoint(x: 0, y: 0.5)
                    g.endPoint = CGPoint(x: 1, y: 0.5)
                    // Old spacing: 0.13 hue per letter ≈ one wheel per
                    // ~8 letters; scale the period to the text width.
                    let period = max(24, bounds.width / max(1, Double(text.count)) * 7.7)
                    let copies = Int((bounds.width / period).rounded(.up)) + 1
                    g.frame = CGRect(x: 0, y: 0, width: period * Double(copies), height: bounds.height)
                    let wheel: [CGColor] = (0...8).map { hsb(Double($0) / 8, 0.85, 1) }
                    g.colors = Array((0..<copies).map { _ in wheel.dropLast() }.joined()) + [wheel[0]]
                    g.add(CABasicAnimation.loop("position.x", from: g.position.x,
                                                to: g.position.x - period, duration: 2.67),
                          forKey: "marquee")
                    host.masksToBounds = true
                    host.addSublayer(g)
                }
                .mask(glyphs)
            }
            .help("All Lucky 7s!")
    }
}

/// The "resetting…" pulse as a reusable modifier (debug pane demo).
private struct PulseOpacity: ViewModifier {
    func body(content: Content) -> some View {
        // |sin 4t|: 0.35→1 every 0.39s, as a CA opacity loop on the
        // mask — the content fades with it, nothing per frame (#18).
        content.mask {
            LayerEffect { host, bounds in
                let sheet = CALayer()
                sheet.frame = bounds
                sheet.backgroundColor = rgb(0, 0, 0)
                sheet.add(CABasicAnimation.loop("opacity", from: 1, to: 0.35, duration: 0.39,
                                                autoreverses: true, easeInOut: true), forKey: "pulse")
                host.addSublayer(sheet)
            }
        }
    }
}

extension View {
    public func pulseOpacity() -> some View { modifier(PulseOpacity()) }
}

/// Dying-account flash (user 2026-09-01: "when account is dying —
/// under 10% — flash the row"): a slow red breath over the whole row
/// while its binding window sits in the 90s. Distinct cadence from the
/// death band (one-shot) and the chill halo (mint, per-gauge): this is
/// an ambient alarm, urgent but not seizure bait.
public struct CriticalPulse: View {
    var cornerRadius: Double = 4

    public init(cornerRadius: Double = 4) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        // 1.6s breath: the peak look (fill 0.18, rim 0.50) fading to
        // ~0.29 of itself (0.05 / 0.15) — one CA opacity animation,
        // nothing per frame in-process (#18, see LayerEffect).
        LayerEffect { host, bounds in
            let band = CALayer()
            band.frame = bounds
            band.cornerRadius = cornerRadius
            band.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.18)
            band.borderWidth = 1
            band.borderColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.50)
            band.add(CABasicAnimation.loop("opacity", from: 1, to: 0.29, duration: 0.8,
                           autoreverses: true, easeInOut: true), forKey: "breath")
            host.addSublayer(band)
        }
        .allowsHitTesting(false)
    }
}
