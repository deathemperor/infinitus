import SwiftUI
import InfinitusCore

/// CodexBar-faithful usage bar (steipete/CodexBar UsageProgressBar.swift,
/// studied 2026-08-30 at user request), themed:
///  - continuous capsule track + remaining fill
///  - boundary ticks dividing it into small segments (day marks on a
///    weekly bar, hour marks on a session bar — the "smaller bars" look)
///  - a slanted pace stripe where the burn SHOULD be (green = reserve,
///    red = deficit), punched through the fill
///  - a warning marker near empty
///  - the fill ANIMATES; a big refill (window reset) springs full.
public struct GaugeBar: View {
    let remaining: Double
    let color: Color
    var paceRemaining: Double? = nil
    /// Boundary ticks (0-100, remaining axis) — day/hour segment marks.
    var dividers: [Double] = []
    /// False in the settings theme previews: the numericText roll never
    /// resolves inside the card's horizontal ScrollView (macOS 26 —
    /// percent labels froze mid-roll as ":" slivers, user screenshot
    /// 2026-08-30) and the intro fill has nothing to choreograph there.
    var animated: Bool = true
    /// Pace fire ("off"/"ember"/"flame"/"limit") + heat 0…1 (how far
    /// ahead of pace, GaugeMath.burnHeat) — 7d/model bars burn when
    /// usage outruns the clock (user 2026-08-31).
    var burnStyle: String = "off"
    var burnHeat: Double = 0
    /// Cool glow 0…1 (behind pace, GaugeMath.chillDepth) — the burn's
    /// inverse: reserve breathes a slow mint halo. Mutually exclusive
    /// with burnHeat by construction (aheadOfPace true vs false).
    var chill: Double = 0
    /// Where the HP-drop zoom grows from. Columns near the popup's
    /// right edge (weekly/spend/scoped on the wide grid) anchor
    /// center or trailing so the 5× bar stays inside the window
    /// (user 2026-08-31: "fable drop: overflown hidden as fable is
    /// far right of window — happens only on list").
    var dropAnchor: UnitPoint = .leading
    /// All Lucky 7s: the call site decides the trigger; the label
    /// flashes the fever digits instead of the plain percent.
    var lucky: Bool = false
    /// The unit-frame skin (the phone's Game HUD header): same effects
    /// engine, drawn as a full-width glossy bar with the glyph and the
    /// value INSIDE. Nil = the capsule with the percent beside it.
    var hud: GaugeHUD? = nil
    @ScaledMetric(relativeTo: .caption) private var baseBarWidth = 56.0
    @ScaledMetric(relativeTo: .caption) private var baseBarHeight = 6.0
    /// The solo card (one account, nothing to compare against) grows
    /// its gauges through this; rows in a grid keep 1.
    @Environment(\.gaugeScale) private var gaugeScale
    private var barWidth: Double { hud?.width ?? baseBarWidth * gaugeScale }
    private var barHeight: Double { hud?.height ?? baseBarHeight * min(gaugeScale, 1.5) }
    /// The capsule is a rounded rect at half height; the HUD bar squarer.
    private var radius: Double { hud?.cornerRadius ?? barHeight / 2 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius) }
    /// The HP-drop zoom: 5× on a 56pt capsule is the drama; a bar that
    /// already spans its panel grows 1.5× so it stays on screen.
    private var dropScale: Double { hud == nil ? 5 : 1.5 }
    /// The halos were drawn for the 6pt capsule — a 1pt ring and a few
    /// points of shadow. On the 14pt HUD bar that read as a tinted rim,
    /// not a glow (user 2026-09-05, phone: "death2nd is supposed to have
    /// glow effect on 7d and fable"); ring and shadow scale with height.
    private var haloScale: Double { max(1, barHeight / 6) }
    @State private var shown: Double = 0
    // HP-drop drama (user 2026-08-31): a big one-refresh plunge zooms
    // the bar 5×, flashes the doomed chunk, then drains it. dropSeq
    // invalidates the pending closures when a newer change lands.
    @State private var dropTo: Double? = nil
    @State private var dropZoom = false
    @State private var cutFlash = false
    @State private var dropSeq = 0
    /// Killing blow: a drop that drains the bar to zero bursts shards
    /// and shakes at full zoom (user 2026-08-31).
    @State private var killTick = 0
    // Ahead-of-pace effects hold until the intro fill has landed
    // (user 2026-08-31: "ahead effect: should only starts when intro
    // ended") — a burn riding the bar WHILE it fills from empty reads
    // as a glitch, not drama. Armed by playFill's timer; seq-guarded
    // like the drop closures.
    @State private var burnArmed = false
    @State private var burnArmSeq = 0
    /// A one-refresh plunge of 10+ remaining-points is a dramatic burn.
    /// 60+ is a data correction, not a burn (an account/window swap —
    /// and the debug pane's refill demo hops 100→8 on its way to the
    /// spring refill; theatre there would fight the refill animation).
    private static let dropMin = 10.0
    private static let dropMax = 60.0
    // Intro choreography inputs (default 0 outside the popup — the
    // settings playground keeps its instant behavior).
    @Environment(\.introTick) private var introTick
    @Environment(\.introBarDelay) private var introBarDelay
    @Environment(\.gaugeIntroOnAppear) private var introOnAppear

    public init(remaining: Double, color: Color, paceRemaining: Double? = nil,
                dividers: [Double] = [], animated: Bool = true,
                burnStyle: String = "off", burnHeat: Double = 0,
                chill: Double = 0, dropAnchor: UnitPoint = .leading,
                lucky: Bool = false, hud: GaugeHUD? = nil) {
        self.remaining = remaining
        self.color = color
        self.paceRemaining = paceRemaining
        self.dividers = dividers
        self.animated = animated
        self.burnStyle = burnStyle
        self.burnHeat = burnHeat
        self.chill = chill
        self.dropAnchor = dropAnchor
        self.lucky = lucky
        self.hud = hud
    }

    public var body: some View {
        HStack(spacing: 3) {
            bar
            if hud == nil { percentLabel }
        }
        .onAppear {
            if animated, introOnAppear {
                playFill()
            } else {
                // Straight to the value, burn armed: a bar that appears
                // on a tab switch is not an entrance.
                shown = remaining
                burnArmed = true
            }
        }
        // Replay intro re-runs the fill too (it was missing from the
        // debug pane's Replay, user 2026-08-30).
        .onChange(of: introTick) { _, _ in playFill() }
        .onChange(of: remaining) { old, new in
            // Every change invalidates a running drop sequence AND resets
            // its visuals unconditionally — restoration must never live
            // only in a cancellable closure (or the bar sticks at 5×).
            dropSeq += 1
            if dropZoom || dropTo != nil {
                withAnimation(.easeOut(duration: 0.2)) { dropZoom = false }
                dropTo = nil
                cutFlash = false
            }
            // A jump UP of 25+ points is a window reset: replay the refill
            // from empty (the restore animation, user 2026-08-30).
            if new - old > 25 {
                // Visibly fill: sit empty a beat, then a slow spring
                // ("runs too fast", user 2026-08-30 playground test).
                shown = 0
                withAnimation(.spring(duration: 1.8, bounce: 0.2).delay(0.25)) {
                    shown = new
                }
            } else if old - new >= Self.dropMin,
                      old - new <= Self.dropMax || new <= 0.5,
                      animated {
                // A drop past dropMax still plays when it KILLS — a
                // 63-point killing blow is the drama, not a data
                // correction.
                playDrop(to: new)
            } else {
                withAnimation(.easeOut(duration: 0.5)) { shown = new }
            }
        }
    }

    /// The percent: the fever digits when the 7s align, else the plain
    /// number rolling to its value. Beside the capsule; inside the HUD bar.
    @ViewBuilder private var percentLabel: some View {
        if lucky, animated {
            LuckySevens(text: "\(Int(remaining))%", font: hud?.font ?? PopupFont.caption)
        } else if let hud {
            Text("\(Int(remaining))%")
                .font(hud.font).monospacedDigit()
                .contentTransition(animated ? .numericText(value: remaining) : .identity)
        } else {
            Text("\(Int(remaining))%")
                .font(PopupFont.caption).monospacedDigit()
                .contentTransition(animated ? .numericText(value: remaining)
                                            : .identity)
                .foregroundStyle(remaining <= 0 ? Color.red : color.opacity(0.9))
        }
    }

    private var bar: some View {
            ZStack(alignment: .leading) {
                if let hud {
                    shape.fill(hud.plain ? Color.primary.opacity(0.1) : Color.black.opacity(0.7))
                } else {
                    shape.fill(Color.secondary.opacity(0.22))
                }
                // Fill animates via frame width (Canvas can't animate).
                if let hud {
                    // Glossy: a top-to-bottom fade with the top half
                    // catching the light (the WoW unit frame).
                    shape.fill(LinearGradient(colors: [color.opacity(1), color.opacity(0.55)],
                                              startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) {
                            shape.fill(Color.white.opacity(0.22))
                                .frame(height: hud.height * 0.45)
                        }
                        .frame(width: max(0, barWidth * min(100, max(0, shown)) / 100))
                        .clipShape(shape)
                } else {
                    shape.fill(color)
                        .frame(width: max(0, barWidth * min(100, max(0, shown)) / 100))
                }
                // The doomed chunk: from the drop floor to the live fill
                // edge — derived from `shown`, so the filldown eats it in
                // perfect sync with the fill (no separate choreography).
                if let to = dropTo {
                    let x0 = barWidth * min(100, max(0, to)) / 100
                    let x1 = barWidth * min(100, max(0, shown)) / 100
                    Rectangle().fill(.white)
                        .frame(width: max(0, x1 - x0))
                        .offset(x: x0)
                        .opacity(cutFlash ? 0.95 : 0.35)
                }
                overlayMarks
            }
            .frame(width: barWidth, height: barHeight)
            .clipShape(shape)
            // The HUD bar is rimmed by the frame's ring.
            .overlay {
                if let hud { shape.stroke(hud.ring.opacity(0.55), lineWidth: 1) }
            }
            // Unclipped overlay so flames lick a few points above the
            // capsule; BurnOverlay caps its own rise (grid rows sit
            // close above). Gated here so the TimelineView inside
            // doesn't exist — and costs nothing — on calm bars.
            .overlay(alignment: .bottom) {
                if animated, burnArmed, burnHeat > 0, burnStyle != "off" {
                    BurnOverlay(style: burnStyle, heat: burnHeat,
                                fillFraction: min(100, max(0, shown)) / 100,
                                barWidth: barWidth, barHeight: barHeight,
                                cornerRadius: radius)
                }
            }
            // Heat halo (user 2026-08-31: "bar with few left the
            // effects on remaining is too subtle"): the burn rides the
            // FILL, which nearly vanishes near empty — a heat-tinted
            // glowing border on the whole capsule keeps ahead-of-pace
            // readable at any fill. Ember orange -> core white as heat
            // climbs (BurnOverlay's palette).
            .overlay {
                if animated, burnArmed, burnHeat > 0, burnStyle != "off" {
                    let tint = Color(red: 1,
                                     green: 0.45 + 0.51 * burnHeat,
                                     blue: 0.10 + 0.75 * burnHeat)
                    shape
                        .strokeBorder(tint.opacity(0.4 + 0.5 * burnHeat),
                                      lineWidth: haloScale)
                        .shadow(color: tint.opacity(0.5 + 0.5 * burnHeat),
                                radius: (2 + 5 * burnHeat) * haloScale)
                        .allowsHitTesting(false)
                }
            }
            // Cool halo (todo 2026-09-01: "effects to accounts that are
            // behind in usage"): the heat halo's inverse — usage running
            // behind the clock breathes a slow mint glow. Deliberately
            // calmer than the burn: reserve is good news, not drama.
            .overlay {
                if animated, burnArmed, chill > 0, burnStyle != "off" {
                    ChillHalo(chill: chill, cornerRadius: radius, scale: haloScale)
                }
            }
            // The HUD bar carries its glyph and value inside, on the
            // theme's ink over a hard shadow — above the fire, so the
            // words stay legible while the bar burns.
            .overlay {
                if let hud {
                    HStack {
                        Text(hud.glyph).font(hud.font)
                        Spacer(minLength: 0)
                        percentLabel
                    }
                    .lineLimit(1)
                    .foregroundStyle(hud.ink)
                    .shadow(color: .black.opacity(hud.plain ? 0 : 0.9), radius: 1)
                    .padding(.horizontal, 5)
                }
            }
            // Shard burst on a killing blow — above the bar, zooming
            // with it.
            .overlay {
                KillBurst(tick: killTick)
                    .frame(width: barWidth * 1.8, height: 44)
            }
            // The kill shake: hard jitter, zoomed.
            .keyframeAnimator(initialValue: 0.0, trigger: killTick) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.001, duration: 0.001)
                    CubicKeyframe(-2.5, duration: 0.05)
                    CubicKeyframe(2.5, duration: 0.05)
                    CubicKeyframe(-2, duration: 0.05)
                    CubicKeyframe(1.5, duration: 0.05)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
            // The HP-drop zoom — after the burn overlay so flames zoom
            // with the bar. Overlapping neighbor rows is the drama.
            .scaleEffect(dropZoom ? dropScale : 1, anchor: dropAnchor)
            .zIndex(dropZoom ? 10 : 0)
    }

    /// The HP-drop sequence (user 2026-08-31): zoom the bar 5× in
    /// place, flash the chunk about to be lost, then drain it with an
    /// easeIn filldown and settle back to size.
    private func playDrop(to: Double) {
        let seq = dropSeq
        dropTo = to                       // chunk = [to, shown]; hold at old
        withAnimation(.spring(duration: 0.3, bounce: 0.45)) { dropZoom = true }
        withAnimation(.easeInOut(duration: 0.11)
            .repeatCount(7, autoreverses: true).delay(0.25)) { cutFlash = true }
        let kill = to <= 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            guard seq == dropSeq else { return }
            withAnimation(.easeIn(duration: 0.5)) { shown = to }
            if kill {
                // The finisher lands as the drain hits bottom: shards
                // fly, the bar shakes, the zoom lingers on the corpse.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard seq == dropSeq else { return }
                    killTick += 1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (kill ? 1.6 : 0.75)) {
                guard seq == dropSeq else { return }
                withAnimation(.spring(duration: 0.4)) { dropZoom = false }
                dropTo = nil
                cutFlash = false
            }
        }
    }

    /// The intro fill-up: from empty, held until the popup's content
    /// entrance has landed (introBarDelay; 0 outside the popup).
    private func playFill() {
        shown = 0
        burnArmed = false
        burnArmSeq += 1
        let seq = burnArmSeq
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.25 + introBarDelay + 1.6) {
            guard seq == burnArmSeq else { return }
            burnArmed = true
        }
        withAnimation(.spring(duration: 1.8, bounce: 0.2)
            .delay(0.25 + introBarDelay)) {
            shown = remaining
        }
    }

    /// Ticks + pace stripe + warning mark, drawn over fill and track.
    private var overlayMarks: some View {
        Canvas { context, size in
            // Segment boundary ticks (CodexBar workday markers): thin
            // primary lines from the bottom, subtle.
            for d in dividers where d > 1 && d < 99 {
                let x = size.width * d / 100
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height * 0.35,
                                width: 1, height: size.height * 0.65)),
                    with: .color(.black.opacity(0.5)))
            }
            // Warning marker near empty (CodexBar quota warning): a
            // fixed tick at 10% remaining, red-tinted.
            let warnX = size.width * 0.10
            context.fill(
                Path(CGRect(x: warnX - 0.75, y: 0, width: 1.5,
                            height: size.height)),
                with: .color(.red.opacity(remaining <= 12 ? 0.9 : 0.45)))
            // Pace stripe: slanted double-tick, green ahead / red behind.
            if let pace = paceRemaining {
                let clamped = min(100, max(0, pace))
                let x = size.width * clamped / 100
                let slant = size.height * 0.35
                func stripe(_ cx: CGFloat, _ w: CGFloat) -> Path {
                    Path { p in
                        p.move(to: CGPoint(x: cx - w / 2 + slant, y: 0))
                        p.addLine(to: CGPoint(x: cx + w / 2 + slant, y: 0))
                        p.addLine(to: CGPoint(x: cx + w / 2 - slant, y: size.height))
                        p.addLine(to: CGPoint(x: cx - w / 2 - slant, y: size.height))
                        p.closeSubpath()
                    }
                }
                context.blendMode = .destinationOut
                context.fill(stripe(x, 5), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal
                let deficit = remaining < clamped
                context.fill(stripe(x, 1.8),
                             with: .color(deficit ? .red : .green))
            }
        }
    }
}


/// GaugeBar's unit-frame skin (the phone's Game HUD header, user
/// 2026-09-05: "keep bar effects and animation"): a full-width glossy
/// bar in the panel's ink and ring colors, the window's glyph at the
/// left and the value at the right, inside. Every effect the capsule
/// plays — burn, chill, HP drop, kill, fever digits, refill — plays here.
public struct GaugeHUD {
    public var glyph: String
    public var ink: Color
    public var ring: Color
    /// The Off theme: a neutral track, no shadow under the text.
    public var plain: Bool
    public var width: Double
    public var height: Double = 14
    public var cornerRadius: Double = 3
    public var font: Font = .system(size: 10, weight: .heavy, design: .rounded)

    public init(glyph: String, ink: Color, ring: Color, plain: Bool, width: Double) {
        self.glyph = glyph
        self.ink = ink
        self.ring = ring
        self.plain = plain
        self.width = width
    }
}

/// Which pace-fire style a bar wears, from the burn-style pref and the
/// theme (user 2026-08-31: "only and always apply for RPG and apply on
/// Fable"). Shared by the Mac rows and the phone's chat header.
public enum BurnRules {
    /// Limit break is an RPG-exclusive: other themes downgrade a
    /// selected limit style to ember.
    public static func weekly(pref: String, theme: RowTheme) -> String {
        pref == "limit" && theme.id != "rpg" ? "ember" : pref
    }

    /// Under RPG the Fable bar ALWAYS burns limit-style — the rainbow
    /// marquee is its signature ("off" still masters it off).
    public static func scoped(pref: String, theme: RowTheme) -> String {
        guard pref != "off" else { return "off" }
        return theme.id == "rpg" ? "limit" : weekly(pref: pref, theme: theme)
    }
}

// MARK: Intro environment plumbing — set once on MenuContent, read by
// every bar (GaugeBar takes no model).
private struct IntroTickKey: EnvironmentKey {
    static let defaultValue = 0
}
private struct IntroBarDelayKey: EnvironmentKey {
    static let defaultValue = 0.0
}
/// Whether a bar plays its fill-from-empty when it first appears. The
/// popup wants the entrance on every open; the phone, where SwiftUI
/// re-creates a tab's bars on every switch, wants them still (user
/// 2026-09-04: "switching screens the animations replay — supposed to
/// stay static"). `introTick` still replays on demand.
private struct GaugeIntroOnAppearKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    public var gaugeIntroOnAppear: Bool {
        get { self[GaugeIntroOnAppearKey.self] }
        set { self[GaugeIntroOnAppearKey.self] = newValue }
    }
    public var introTick: Int {
        get { self[IntroTickKey.self] }
        set { self[IntroTickKey.self] = newValue }
    }
    public var introBarDelay: Double {
        get { self[IntroBarDelayKey.self] }
        set { self[IntroBarDelayKey.self] = newValue }
    }
}

/// The chill halo's breath as one repeatForever opacity (2.4s period,
/// trough at 0.15 of the peak) — a per-frame TimelineView here cost a
/// full pop-out layout per tick (#18). Radius sits at the mid-breath.
private struct ChillHalo: View {
    let chill: Double
    let cornerRadius: Double
    /// 1 on the capsule; the HUD bar's height over the capsule's.
    let scale: Double

    var body: some View {
        let peak = 0.35 + 0.65 * chill
        let radius = (2 + 5 * peak * 0.6) * scale
        // The host is grown by the shadow's spill and the ring drawn inset
        // by the same amount: iOS clips a representable to its frame, so a
        // host the size of the bar showed the ring and not the glow around
        // it (2026-09-06, the phone HUD's "glow" was a tinted rim).
        let outset = radius * 2
        LayerEffect { host, bounds in
            let rect = bounds.insetBy(dx: outset + 0.5, dy: outset + 0.5)
            let corner = min(cornerRadius, rect.height / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner,
                              transform: nil)
            // The glow is three concentric strokes, wide and faint to
            // narrow and bright — iOS renders no shadow for a stroke-only
            // shape layer inside a representable (the ring showed, the
            // spill never did), and a stroke stack reads the same on both
            // platforms. All breathe together on the host's opacity.
            for (width, alpha) in [(radius * 2, 0.10), (radius, 0.22), (scale, 0.85)] {
                let ring = CAShapeLayer()
                ring.frame = bounds
                ring.path = path
                ring.fillColor = nil
                ring.strokeColor = rgb(0.35, 0.95, 0.75, alpha * peak)
                ring.lineWidth = width
                host.addSublayer(ring)
            }
            host.add(CABasicAnimation.loop("opacity", from: 1, to: 0.15, duration: 1.2,
                                           autoreverses: true, easeInOut: true), forKey: "breath")
        }
        .padding(-outset)
        .allowsHitTesting(false)
    }
}

private struct GaugeScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
public extension EnvironmentValues {
    /// Multiplies GaugeBar's width (height caps at 1.5×).
    var gaugeScale: Double {
        get { self[GaugeScaleKey.self] }
        set { self[GaugeScaleKey.self] = newValue }
    }
}
