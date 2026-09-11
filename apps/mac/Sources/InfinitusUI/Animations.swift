import SwiftUI
import InfinitusCore

// SwitchFlash, ValueChangedGlow, DeathFlash, ReviveFlash, LuckyRowBackground,
// LuckySevens, LuckyName, PulseOpacity and CriticalPulse moved to
// InfinitusUI/Effects.swift (#9 phase A) — they take no AppModel, so the
// phone app renders them too. What's left here all reads the host's
// FleetModel (#9 phase B).

/// One shared trigger for the fever: Fable (any scoped window) showing
/// exactly 77 remaining, or the 5h AND 7d pair both at 77.
extension Account {
    var allLucky7s: Bool {
        if let five = usage?.fiveHour?.pct,
           let seven = usage?.sevenDay?.pct,
           Int(GaugeMath.remaining(usedPct: five)) == 77,
           Int(GaugeMath.remaining(usedPct: seven)) == 77 { return true }
        return (usage?.scoped ?? []).contains {
            Int(GaugeMath.remaining(usedPct: $0.pct)) == 77
        }
    }
}


// MARK: - Launch intro choreography (user script, 2026-08-30)
//
// app starts -> footer controls slide in (left group from the left,
// right group from the right) while the account content enters
// (dev-tunable: slide from top / bottom / fade, with speed) -> the
// bars play their fill-up and the active row flashes (GaugeBar
// onAppear + firstLoad switchFlashTick) -> the Infinitus title lands
// with an exaggerated flourish (several styles to audition).

struct IntroSlideIn<M: FleetModel>: ViewModifier {
    @ObservedObject var model: M
    let fromLeft: Bool
    @State private var on = true

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(x: on ? 0 : (fromLeft ? -70 : 70))
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30). Same
            // for an engine with an EMPTY fleet: once the first snapshot
            // decoded, what's there (FirstAccountCard) is the content
            // (found live 2026-09-01 — blank panel).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    && !model.snapshotLoaded
                    ? (on = false) : play()
            }
            .onChange(of: model.snapshotLoaded) { _, _ in if !on { play() } }
            .onChange(of: model.introTick) { _, _ in play() }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.6 / speed, bounce: 0.25)) {
            on = true
        }
    }
}

struct IntroContentReveal<M: FleetModel>: ViewModifier {
    @ObservedObject var model: M
    @State private var on = true

    /// "rows" hands the entrance to the per-row IntroRowSlide stagger —
    /// a container fade on top would just dim the sliding rows.
    private var delegated: Bool { model.introStyle == "rows" }

    func body(content: Content) -> some View {
        let dy: CGFloat = switch model.introStyle {
        case "top": -44
        case "bottom": 44
        default: 0
        }
        content
            .opacity(delegated || on ? 1 : 0)
            .offset(y: delegated || on ? 0 : dy)
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30). Same
            // for an engine with an EMPTY fleet: once the first snapshot
            // decoded, what's there (FirstAccountCard) is the content
            // (found live 2026-09-01 — blank panel).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    && !model.snapshotLoaded
                    ? (on = false) : play()
            }
            .onChange(of: model.snapshotLoaded) { _, _ in if !on { play() } }
            .onChange(of: model.introTick) { _, _ in play() }
            .onChange(of: model.introStyle) { _, _ in play() }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.7 / speed, bounce: 0.2)) {
            on = true
        }
    }
}

/// One account row's entrance for the "rows" content style: slide in
/// from the right, each row a beat after the one above (user
/// 2026-08-30). Inert for every other style. On the wide Grid the
/// modifier rides a Group INSIDE each GridRow — a Group distributes a
/// modifier to each child, so the row's cells move as one without
/// collapsing the GridRow (a modified GridRow is one cell).
struct IntroRowSlide<M: FleetModel>: ViewModifier {
    @ObservedObject var model: M
    let index: Int
    @State private var on = true

    private var active: Bool { model.introStyle == "rows" }

    func body(content: Content) -> some View {
        content
            .opacity(!active || on ? 1 : 0)
            .offset(x: !active || on ? 0 : 90)
            .onAppear {
                guard active else { return }
                model.accounts.isEmpty && !model.engineMissing
                    ? (on = false) : play()
            }
            .onChange(of: model.introTick) { _, _ in if active { play() } }
            .onChange(of: model.introStyle) { _, _ in
                if active { play() } else { on = true }
            }
    }

    private func play() {
        let speed = max(0.2, model.introSpeed)
        on = false
        withAnimation(.spring(duration: 0.55 / speed, bounce: 0.22)
            .delay(Double(index) * 0.09 / speed)) { on = true }
    }
}

/// The title's landing — deliberately exaggerated; styles to audition:
///  zoom  — grows from a dot with a big overshoot bounce
///  slam  — stamps down from 3.4x with a tilt, flash on impact
///  spin  — spins up two turns while growing
struct IntroTitleFlourish<M: FleetModel>: ViewModifier {
    @ObservedObject var model: M
    @State private var on = true
    @State private var glow = 0.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1 : startScale)
            .rotationEffect(.degrees(on ? 0 : startRotation))
            .opacity(on ? 1 : 0)
            .brightness(glow)
            // Hold hidden only while data is COMING. With no engine
            // installed nothing ever arrives — the onboarding card must
            // show, not an empty sliver (found live 2026-08-30). Same
            // for an engine with an EMPTY fleet: once the first snapshot
            // decoded, what's there (FirstAccountCard) is the content
            // (found live 2026-09-01 — blank panel).
            .onAppear {
                model.accounts.isEmpty && !model.engineMissing
                    && !model.snapshotLoaded
                    ? (on = false) : play()
            }
            .onChange(of: model.snapshotLoaded) { _, _ in if !on { play() } }
            .onChange(of: model.introTick) { _, _ in play() }
            .onChange(of: model.introTitle) { _, _ in play() }
    }

    private var startScale: CGFloat {
        switch model.introTitle {
        case "slam": 3.4
        case "spin", "zoom": 0.1
        default: 1
        }
    }

    private var startRotation: Double {
        switch model.introTitle {
        case "slam": -12
        case "spin": -720
        default: 0
        }
    }

    private func play() {
        guard model.introTitle != "off" else { on = true; return }
        let speed = max(0.2, model.introSpeed)
        on = false
        glow = 0
        // Lands while the bars' fill-up is under way — anchored to the
        // same introBarDelay gate as the bars themselves.
        let delay = model.introBarDelay + 0.9 / speed
        let anim: Animation = switch model.introTitle {
        case "slam": .spring(duration: 0.5 / speed, bounce: 0.35)
        case "spin": .spring(duration: 0.9 / speed, bounce: 0.3)
        default: .spring(duration: 0.7 / speed, bounce: 0.55)
        }
        withAnimation(anim.delay(delay)) { on = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.15) {
            glow = 0.8
            withAnimation(.easeOut(duration: 0.8 / speed)) { glow = 0 }
        }
    }
}

public extension View {
    func introSlide<M: FleetModel>(_ model: M, fromLeft: Bool) -> some View {
        modifier(IntroSlideIn(model: model, fromLeft: fromLeft))
    }
    func introContent<M: FleetModel>(_ model: M) -> some View {
        modifier(IntroContentReveal(model: model))
    }
    func introRow<M: FleetModel>(_ model: M, index: Int) -> some View {
        modifier(IntroRowSlide(model: model, index: index))
    }
    func introTitle<M: FleetModel>(_ model: M) -> some View {
        modifier(IntroTitleFlourish(model: model))
    }
}
