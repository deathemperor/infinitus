import SwiftUI
import InfinitusCore

/// One-line usage summary for a gauge's instant tooltip — the CodexBar
/// vocabulary ("24% in reserve · lasts until reset" / "6% in deficit ·
/// runs out in ~2d"), built from the engine's weekly pace fields.
enum WindowSummary {
    static func line(_ w: UsageWindow, kind: String) -> String {
        let left = max(0, 100 - w.pct)
        var parts = ["\(kind) \(Int(left))% left"]
        if let expected = w.expectedPct {
            let delta = Int((expected - w.pct).rounded())
            if delta >= 1 {
                parts.append("\(delta)% in reserve")
            } else if delta <= -1 {
                parts.append("\(-delta)% in deficit")
            } else {
                parts.append("on pace")
            }
        }
        if w.willLastToReset == true {
            parts.append("lasts until reset")
        } else if let out = WeeklyRoll.parse(w.projectedExhaustionAt) {
            parts.append("runs out \(out.formatted(.relative(presentation: .numeric)))")
        }
        if let reset = w.countdown ?? w.clock {
            parts.append("resets \(reset)")
        }
        // CodexBar's quota math: how many 5h session windows fit in the
        // time left on a weekly bar.
        if kind.hasPrefix("Weekly"), let reset = WeeklyRoll.parse(w.resetsAt) {
            let hoursLeft = max(0, reset.timeIntervalSinceNow / 3600)
            parts.append(String(format: "%.0f session windows until reset",
                                (hoursLeft / 5).rounded()))
        }
        return parts.joined(separator: " · ")
    }
}

/// Layout chooser: wide grid rows (the classic) or stacked per-account
/// cards (narrow popup, e.g. on an ultrawide where the bar sits far away).
/// The advisory marker beside an account number, both layouts.
/// Green solid triangle: the auto-switcher's likely next target.
/// Gray hollow triangle: EVERY account is at a limit and this one
/// recovers first — visibly distinct from "no candidate shown", which
/// used to be indistinguishable from broken (user report 2026-08-30).
/// Always in the layout so numbers stay aligned.
struct NextMarker<M: FleetModel>: View {
    @ObservedObject var model: M
    let number: Int

    var body: some View {
        let theme = model.rowTheme
        if model.nextCandidate == number {
            if theme.plain || theme.nextIcon.isEmpty {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(PopupFont.caption2).foregroundStyle(.green)
                    .instantTip("Next auto-switch target — the engine "
                                + "would rotate to account \(number) first")
            } else {
                // Themed candidates carry the icon IN the number cell
                // (slotDisplay: 🍿 replaces 🎬5); keep the slot here so
                // columns stay aligned.
                Image(systemName: "arrowtriangle.right.fill")
                    .font(PopupFont.caption2).opacity(0)
            }
        } else if model.nextCandidate == nil,
                  let recovery = model.nextRecovery,
                  recovery.number == number {
            // Orange, not secondary: the first row to recover is the
            // one to watch while everything is limited (todo 2026-09-01).
            Image(systemName: "arrowtriangle.right")
                .font(PopupFont.caption2)
                .foregroundStyle(.orange)
                .instantTip("All accounts are at a limit — this one "
                            + "recovers first\(Self.eta(recovery.at))")
        } else {
            Image(systemName: "arrowtriangle.right.fill")
                .font(PopupFont.caption2)
                .opacity(0)
        }
    }

    private static func eta(_ iso: String) -> String {
        guard let date = WeeklyRoll.parse(iso) else { return "" }
        return " (" + date.formatted(date: .abbreviated, time: .shortened) + ")"
    }
}

public struct AccountRows<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U

    public init(model: M, usage: U) {
        self.model = model
        self.usage = usage
    }

    public var body: some View {
        Group {
            if model.popupLayout == "stacked" {
                AccountStack(model: model, usage: usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if model.popupLayout == "hstack" {
                // Horizontal cards: the stacked card, laid side by side
                // (user 2026-08-31: "still cards but stack horizontal").
                AccountStack(model: model, usage: usage, horizontal: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                AccountGrid(model: model, usage: usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.popupLayout)
        // Warm the cash figures when the popup opens in a themed mode: a
        // background `cswap usage` run, cached in the shared UsageModel.
        .onAppear { if !model.rowTheme.plain { usage.loadIfNeeded() } }
    }
}

/// Shared cell builders for both layouts — one vocabulary (RowTheme),
/// one set of rendering rules (compact hides untouched/exhausted cells,
/// themed gauges show what's LEFT, plain shows used %).
@MainActor
struct AccountCells<M: FleetModel, U: UsageSource> {
    let model: M
    let usage: U
    let account: Account
    /// Wide grid rows paint the active band per cell; stacked cards paint
    /// one rounded background instead.
    var banded = true

    var theme: RowTheme { model.rowTheme }
    var dead: Bool { AccountVitals.isDead(account.usage) }

    /// Narrow contexts: compact rows, and the stacked cards ("make width
    /// smaller even", user 2026-08-30) — both use the short vocabulary.
    var compactText: Bool { model.compactRows || !banded }

    /// Themed plan ("Max 20x" -> "Lv 20x" in RPG); compact keeps it short.
    var planText: String? {
        guard let plan = account.plan else { return nil }
        return theme.plain ? (compactText
            ? plan.replacingOccurrences(of: "Max ", with: "")
                .replacingOccurrences(of: "Enterprise", with: "Ent")
            : plan)
            : theme.planLabel(plan, compact: compactText)
    }

    /// Themed account number ("P1", "S3"); the raw number stays in
    /// tooltips and identifies the row for switching.
    var slotText: String {
        theme.plain ? "\(account.number)"
                    : PopupGlyph.text(theme.slotPrefix) + "\(account.number)"
    }

    /// What the number cell SHOWS: the themed next-candidate icon
    /// REPLACES the slot text outright (🍿 instead of 🎬5 — user
    /// 2026-08-30, emphatically); the tooltip keeps the real number.
    var slotDisplay: String {
        // Active outranks next: the engine never proposes the active
        // account, but "you are here" would beat "up next" if it did.
        if account.active, !theme.plain, !theme.activeIcon.isEmpty {
            return PopupGlyph.text(theme.activeIcon)
        }
        if model.nextCandidate == account.number,
           !theme.plain, !theme.nextIcon.isEmpty {
            return PopupGlyph.text(theme.nextIcon)
        }
        return slotText
    }

    var slotTip: String {
        var tip = "Account \(account.number)"
        if account.active { tip += " — active" }
        if model.nextCandidate == account.number {
            tip += " — next auto-switch target"
        }
        if account.preferred == true { tip += " — preferred (lands here first)" }
        return tip
    }

    var displayName: String {
        // The pause mark leads: a long alias truncates the tail, so a
        // suffix-only tag vanished on real fleets (user 2026-09-01).
        // The star (pick-first, #15) leads too: the lists used to show
        // nothing for it (user 2026-09-03 "doesn't show the star on list").
        let name = [(account.disabled ?? false) ? PopupGlyph.text("⏸") : nil,
                    account.preferred == true ? PopupGlyph.text("★") : nil,
                    showAsDead ? PopupGlyph.text(theme.deadMarker) : nil,
                    account.icon, account.alias ?? account.email]
            .compactMap { $0 }.joined(separator: " ")
        return (account.disabled ?? false) ? "\(name)  (disabled)" : name
    }

    /// Compact mode drops cells that carry no signal: untouched (0%) and
    /// exhausted (100% — the dead marker already says it).
    func hiddenInCompact(_ pct: Double) -> Bool {
        model.compactRows
            && (pct <= 0 || (pct >= 100 && !model.dying.contains(account.number)))
    }

    func resetText(_ w: UsageWindow) -> String? {
        guard let when = compactText
            ? ResetLabel.compact(w) : ResetLabel.label(w) else { return nil }
        return (w.pct >= 100 ? PopupGlyph.text(theme.revivePrefix) : "") + when
    }

    /// Reset label that goes LIVE under ten minutes: a per-second m:ss
    /// countdown, then a pulsing "resetting…" until the next snapshot
    /// replaces the data. No numericText roll here: on macOS 26 a
    /// per-second `.contentTransition(.numericText)` grows the CG glyph
    /// cache ~2 MB/min for as long as it ticks (#18, measured
    /// 2026-09-03: with it 2.1 MB/min, without 0). Fine on the pct
    /// texts, which change once a minute at most.
    @ViewBuilder func resetLabelView(resetsAt: String?, staticText: String?) -> some View {
        if let date = WeeklyRoll.parse(resetsAt),
           date.timeIntervalSinceNow < 600 {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = date.timeIntervalSince(ctx.date)
                if left <= 0 {
                    Text(theme.plain || theme.resetWord.isEmpty
                         ? "resetting…" : PopupGlyph.text(theme.resetWord))
                        .font(PopupFont.caption).bold().foregroundStyle(.green)
                        .opacity(0.35 + 0.65 * abs(sin(
                            ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                } else {
                    Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                        .font(PopupFont.caption).bold().monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
        } else if let staticText {
            Text(staticText).font(PopupFont.caption).foregroundStyle(.secondary)
        }
    }

    var deadCause: AccountVitals.DeadCause? { AccountVitals.cause(account.usage) }

    /// Every present window untouched — in compact mode all its cells are
    /// hidden, so the row needs SOMETHING or it reads as broken.
    var allFresh: Bool {
        guard let u = account.usage else { return false }
        var pcts: [Double] = []
        if let p = u.fiveHour?.pct { pcts.append(p) }
        if let p = u.sevenDay?.pct { pcts.append(p) }
        for w in u.scoped ?? [] { pcts.append(w.pct) }
        // Spend is deliberately absent: a spent credit cap left account 1
        // (0%/0%) rendering as anything but ready (user report 2026-08-30);
        // like AccountVitals, only the plan windows carry the verdict —
        // the ready cell wears the spent credit as a footnote.
        return !pcts.isEmpty && pcts.allSatisfy { $0 <= 0 }
    }

    @ViewBuilder var readyCell: some View {
        let spent = (account.usage?.spend?.pct ?? 0) >= 100
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(PopupFont.caption).foregroundStyle(.green)
            Text(theme.plain ? "ready" : PopupGlyph.text(theme.readyLabel))
                .font(PopupFont.caption).foregroundStyle(.secondary)
            // The weekly clock keeps ticking on an untouched account —
            // show when it rolls ("full hp: also show 7d time", user
            // 2026-09-02). The engine drops resetsAt at 0% (issue #16):
            // fall back to the account's remembered weekly slot, stepped
            // to its next occurrence (Anthropic's weekly reset is a fixed
            // per-account time), else say the slot is unknown.
            if let weekly = account.usage?.sevenDay,
               let when = ReadyWeeklyCaption.text(
                    pct: weekly.pct, resetsAt: weekly.resetsAt,
                    countdown: weekly.countdown, clock: weekly.clock,
                    remembered: WeeklyResetMemory.shared.futureReset(email: account.email),
                    compact: compactText) {
                Text("·").font(PopupFont.caption).foregroundStyle(.tertiary)
                Text(when).font(PopupFont.caption).foregroundStyle(.tertiary)
            }
            if spent {
                Text("·").font(PopupFont.caption).foregroundStyle(.tertiary)
                Text("\(PopupGlyph.text(theme.creditLabel)) spent")
                    .font(PopupFont.caption).foregroundStyle(.tertiary)
            }
        }
        .help(spent
              ? "All plan limits untouched — usage credit spent (footnote only; the account is fully usable)"
              : "All plan limits untouched")
        .fixedSize()
        .activeBand(banded && account.active)
    }

    /// One line replacing every usage cell on a dead row. Plain words, not
    /// themed icon soup — "📦 💊 spent" read as a riddle (user-verified);
    /// only the color and the dead marker carry the theme here.
    @ViewBuilder var deadCell: some View {
        if let cause = deadCause {
            HStack(spacing: 4) {
                // Themed label + themed verb ("MP down", "🎬 sold out");
                // the plain theme keeps plain words. The tooltip carries
                // the plain-English translation either way.
                Text(theme.plain
                     ? "\(causeWord(cause)) out"
                     : "\(causeLabel(cause)) \(PopupGlyph.text(theme.deadVerb))")
                    .font(PopupFont.caption).bold()
                    .foregroundStyle(ThemeColor.resolve(causeColor(cause)))
                Text("·").font(PopupFont.caption).foregroundStyle(.tertiary)
                if let text = model.compactRows
                    ? ResetLabel.compact(resetsAt: cause.resetsAt,
                                         countdown: cause.countdown)
                    : ResetLabel.label(
                        resetsAt: cause.resetsAt, countdown: cause.countdown,
                        clock: cause.clock) {
                    // Themed revival word ("🩸", "re-release", "💊") in the
                    // cause's color; plain keeps "back" ("themify all
                    // info", user 2026-08-30).
                    let revive = PopupGlyph.text(theme.revivePrefix)
                        .trimmingCharacters(in: .whitespaces)
                    Text(theme.plain || revive.isEmpty ? "back" : revive)
                        .font(PopupFont.caption)
                        .foregroundStyle(theme.plain || revive.isEmpty
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(ThemeColor.resolve(causeColor(cause)).opacity(0.8)))
                    resetLabelView(resetsAt: cause.resetsAt, staticText: text)
                } else {
                    // No reset on record (a spent credit cap).
                    Text("spent").font(PopupFont.caption).foregroundStyle(.secondary)
                }
            }
            .instantTip("\(plainCause(cause)) is used up (100%) — the "
                        + "account can't serve requests until it resets"
                        + (cause.countdown.map { " in \($0)" } ?? ""))
            .fixedSize()
            .activeBand(banded && account.active)
        }
    }

    private func causeLabel(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return PopupGlyph.text(theme.sessionLabel)
        case .weekly: return PopupGlyph.text(theme.weeklyLabel)
        case .scoped: return PopupGlyph.text(theme.scopedPrefix) + theme.modelName(cause.name)
        case .credit: return PopupGlyph.text(theme.creditLabel)
        }
    }

    private func plainCause(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "The 5-hour session limit"
        case .weekly: return "The weekly limit"
        case .scoped: return "The \(cause.name ?? "model") weekly limit"
        case .credit: return "The usage-credit spend cap"
        }
    }

    private func causeWord(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "session"
        case .weekly: return "weekly"
        case .scoped: return cause.name ?? "model"
        case .credit: return "credit"
        }
    }

    private func causeColor(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return theme.sessionColor
        case .weekly: return theme.weeklyColor
        case .scoped: return theme.scopedColor
        case .credit: return theme.creditColor
        }
    }

    /// FFVII All Lucky 7s, the paired trigger: BOTH the 5h and 7d
    /// windows showing exactly 77 remaining (the solo trigger is a
    /// scoped/Fable bar at 77 — checked at its own call site).
    /// Fever is an RPG-theme move (user 2026-08-31: "only activated on
    /// RPG theme") — other skins stay in character.
    /// Layout gate: dead, AND past the dying grace — a freshly killed
    /// row keeps its gauges long enough for the drama to play.
    var showAsDead: Bool {
        dead && !model.dying.contains(account.number)
    }

    var allLucky: Bool {
        model.rowTheme.id == "rpg" && account.allLucky7s
    }

    /// The 7d bar's pace fire and the Fable bar's (BurnRules: limit
    /// break is RPG-only, and RPG's Fable always burns limit-style).
    var effectiveBurnStyle: String {
        BurnRules.weekly(pref: model.burnStyle, theme: model.rowTheme)
    }

    var fableBurnStyle: String {
        BurnRules.scoped(pref: model.burnStyle, theme: model.rowTheme)
    }

    /// The paired trigger alone — the 5h/7d labels flash only when
    /// BOTH windows sit at 77 (a scoped bar at 77 flashes itself).
    var luckyPair: Bool {
        guard model.rowTheme.id == "rpg" else { return false }
        guard let five = account.usage?.fiveHour?.pct,
              let seven = account.usage?.sevenDay?.pct else { return false }
        return Int(GaugeMath.remaining(usedPct: five)) == 77
            && Int(GaugeMath.remaining(usedPct: seven)) == 77
    }

    /// The account name, wearing the fever when the 7s align.
    @ViewBuilder var nameLabel: some View {
        if allLucky {
            LuckyName(text: displayName)
        } else {
            Text(displayName)
        }
    }

    @ViewBuilder func windowCell(_ w: UsageWindow?, session: Bool,
                                 timer: Bool = true) -> some View {
        Group {
            if let w, !hiddenInCompact(w.pct) {
                HStack(spacing: 3) {
                    // No ahead-of-pace badge: the burn effect on the bar
                    // itself carries that signal now (user 2026-08-31,
                    // "remove flame icon now with effects") — and with
                    // every cell slot-free, columns still align.
                    if theme.plain {
                        Text(session ? theme.sessionLabel : theme.weeklyLabel)
                            .foregroundStyle(.secondary)
                        Text("\(Int(w.pct))%")
                            .foregroundStyle(w.pct >= 100 ? .red : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: w.pct))
                    } else {
                        Text(PopupGlyph.text(session ? theme.sessionLabel : theme.weeklyLabel))
                            .font(PopupFont.caption).bold()
                            .foregroundStyle(ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor))
                            .help(session ? "Session window left" : "Weekly window left")
                        GaugeBar(
                            remaining: GaugeMath.remaining(usedPct: w.pct),
                            color: ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor),
                            paceRemaining: w.expectedPct.map { 100 - $0 },
                            dividers: session
                                ? (1..<5).map { Double($0) * 20 }
                                : (1..<7).map { Double($0) * 100 / 7 },
                            // Pace fire on the 7d bar only (5h stays calm).
                            burnStyle: session ? "off" : effectiveBurnStyle,
                            burnHeat: session ? 0 : GaugeMath.burnHeat(
                                usedPct: w.pct, expectedPct: w.expectedPct,
                                ahead: w.aheadOfPace),
                            chill: session ? 0 : GaugeMath.chillDepth(
                                usedPct: w.pct, expectedPct: w.expectedPct,
                                ahead: w.aheadOfPace),
                            // Mid-row on the wide grid: grow both ways.
                            dropAnchor: banded && !session ? .center : .leading,
                            lucky: luckyPair)
                    }
                    if timer {
                        resetLabelView(resetsAt: w.resetsAt, staticText: resetText(w))
                    }
                }
                .instantTip(WindowSummary.line(
                    w, kind: session ? "Session (5h)" : "Weekly (7d)"))
                // fixedSize: usage is the row's payload — grow the popup
                // rather than truncate; the name column stays flexible.
                .fixedSize()
                .glowOnChange(of: w.pct, color: ThemeColor.flash(theme))
            } else if w == nil, !session, creditOnly, let spend = account.usage?.spend {
                // A credit-only plan (9Router's Kiro rows) wears its pool
                // in the weekly slot as the SAME gauge the other rows
                // wear — label + bar + reset — the count lives in the
                // tooltip (user 2026-09-03: raw "0 / 10,000" is bad design).
                let color = ThemeColor.resolve(theme.weeklyColor)
                HStack(spacing: 3) {
                    if theme.plain {
                        Text(theme.weeklyLabel).foregroundStyle(.secondary)
                        Text("\(Int(spend.pct))%")
                            .foregroundStyle(spend.pct >= 100 ? .red : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: spend.pct))
                    } else {
                        Text(PopupGlyph.text(theme.weeklyLabel))
                            .font(PopupFont.caption).bold()
                            .foregroundStyle(color)
                            .help("Monthly credit pool left")
                        GaugeBar(remaining: GaugeMath.remaining(usedPct: spend.pct),
                                 color: color,
                                 dividers: [25, 50, 75],
                                 dropAnchor: banded ? .center : .leading,
                                 lucky: luckyPair)
                    }
                    if timer {
                        resetLabelView(resetsAt: spend.resetsAt, staticText: spend.clock ?? spend.countdown)
                    }
                }
                .instantTip(String(format: "Credits: %@ of %@ used (%d%%)%@",
                                   CreditFormat.count(spend.used), CreditFormat.count(spend.limit),
                                   Int(spend.pct), spend.clock.map { " · resets \($0)" } ?? ""))
                .fixedSize()
                .glowOnChange(of: spend.pct, color: ThemeColor.flash(theme))
            } else if w == nil, session, creditOnly, banded, !model.compactRows {
                // Credit-only row: no MP slot to point at — keep the
                // column filled for the band, without an orphaned dash.
                Text(verbatim: "")
                    .frame(maxWidth: .infinity)
                    .gridCellUnsizedAxes(.horizontal)
            } else if w == nil, banded, !model.compactRows {
                Text("—").foregroundStyle(.tertiary)
            } else if banded, !model.compactRows {
                // Placeholder stretches to its COLUMN width: a zero-width
                // cell left a hole in the active row's highlight band.
                // gridCellUnsizedAxes: fill the column WITHOUT driving its
                // size — a bare infinity frame inflated the grid's measured
                // width past the popover (user: overflow both edges).
                Text(verbatim: "")
                    .frame(maxWidth: .infinity)
                    .gridCellUnsizedAxes(.horizontal)
            }
        }
        .activeBand(banded && account.active)
    }

    /// A credit pool with no windows behind it (9Router's Kiro rows):
    /// the credit gauge is the row's only gauge, so it never hides.
    private var creditOnly: Bool {
        guard let u = account.usage else { return false }
        return u.spend != nil && u.fiveHour == nil && u.sevenDay == nil && (u.scoped ?? []).isEmpty
    }

    @ViewBuilder var spendCell: some View {
        if let spend = account.usage?.spend, spend.pct >= 100, !creditOnly {
            // Spent credit is a footnote, not a death: the overflow buffer
            // is gone, the subscription windows still rule the row. The
            // invisible pace slot keeps it aligned with the gauge lines
            // in the stacked cards.
            HStack(spacing: 3) {
                Text("\(PopupGlyph.text(theme.creditLabel)) spent")
            }
                .font(PopupFont.caption).foregroundStyle(.tertiary)
                .help(String(format: "usage credit exhausted: %.2f of %.0f %@ — "
                             + (creditOnly ? "nothing left until it resets"
                                           : "account still usable on its plan limits"),
                             spend.used, spend.limit, spend.currency))
                .fixedSize()
                .activeBand(banded && account.active)
        } else if let spend = account.usage?.spend, !creditOnly, !hiddenInCompact(spend.pct) {
            HStack(spacing: 3) {
                Text(PopupGlyph.text(theme.creditLabel))
                    .font(theme.plain ? PopupFont.body : PopupFont.caption.bold())
                    .foregroundStyle(theme.plain
                                     ? Color.secondary
                                     : ThemeColor.resolve(theme.creditColor))
                if theme.plain {
                    Text("\(Int(spend.pct))%")
                        .foregroundStyle(spend.pct >= 100 ? .red : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: spend.pct))
                } else {
                    GaugeBar(remaining: GaugeMath.remaining(usedPct: spend.pct),
                             color: ThemeColor.resolve(theme.creditColor),
                             dropAnchor: banded ? .center : .leading)
                }
            }
            .instantTip(String(format: "usage credit: %.2f of %.0f %@",
                               spend.used, spend.limit, spend.currency))
            .fixedSize()
            .glowOnChange(of: spend.pct, color: ThemeColor.flash(theme))
            .activeBand(banded && account.active)
        } else if banded, !model.compactRows {
            // Text, not Color.clear: a zero-size cell renders the active
            // band as a stray blob; an empty Text has line height. Stretch
            // so the band fills the column other rows widened. Grid only —
            // in the stacked VStack this rendered as a stray blank line
            // (user screenshot 2026-08-30).
            Text(verbatim: "")
                .frame(maxWidth: .infinity)
                .gridCellUnsizedAxes(.horizontal)
                .activeBand(banded && account.active)
        }
    }

    /// ForEach element for the scoped cells: the theme id rides along
    /// so a pure theme flip changes the element — with `w` alone the
    /// cached child is never re-rendered (the frozen "Dragon" label,
    /// user 2026-08-31). The id stays the window name, so gauge state
    /// (drops, burn arming) survives the flip.
    struct ScopedEntry: Identifiable {
        let win: UsageWindow
        let themeID: String
        var id: String { win.name ?? "?" }
    }

    @ViewBuilder var scopedCells: some View {
        ForEach((account.usage?.scoped ?? []).map {
            ScopedEntry(win: $0, themeID: theme.id)
        }) { entry in
            let w = entry.win
            Group {
                if hiddenInCompact(w.pct) {
                    if banded, !model.compactRows {
                        Text(verbatim: "")
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                } else {
                    HStack(spacing: 3) {
                        if theme.plain {
                            Text(w.name ?? "?").foregroundStyle(.secondary)
                            Text("\(Int(w.pct))%")
                                .foregroundStyle(w.pct >= 100 ? .red : .primary)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: w.pct))
                        } else {
                            Text(PopupGlyph.text(theme.scopedPrefix) + theme.modelName(w.name))
                                .font(PopupFont.caption).bold()
                                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
                            GaugeBar(remaining: GaugeMath.remaining(usedPct: w.pct),
                                     color: ThemeColor.resolve(theme.scopedColor),
                                     paceRemaining: w.expectedPct.map { 100 - $0 },
                                     dividers: (1..<7).map { Double($0) * 100 / 7 },
                                     burnStyle: fableBurnStyle,
                                     burnHeat: GaugeMath.burnHeat(
                                         usedPct: w.pct, expectedPct: w.expectedPct,
                                         ahead: w.aheadOfPace),
                                     chill: GaugeMath.chillDepth(
                                         usedPct: w.pct, expectedPct: w.expectedPct,
                                         ahead: w.aheadOfPace),
                                     // Far right on the wide grid: grow
                                     // leftward, into the window.
                                     dropAnchor: banded ? .trailing : .leading,
                                     lucky: model.rowTheme.id == "rpg"
                                         && Int(GaugeMath.remaining(
                                             usedPct: w.pct)) == 77)
                        }
                    }
                    .instantTip(WindowSummary.line(
                        w, kind: "\(w.name ?? "Model") weekly"))
                }
            }
            .fixedSize()
            .glowOnChange(of: w.pct, color: ThemeColor.flash(theme))
            .alignedColumn(banded ? "scoped:\(w.name ?? "?")" : "")
            .activeBand(banded && account.active)
        }
    }

    /// Estimated 7-day API-price spend from the Usage tab's cached
    /// report — never triggers the multi-second scan itself.
    @ViewBuilder var cashCell: some View {
        if !theme.plain, usage.report == nil {
            // The report loads seconds after launch; an empty cell here
            // made the popup visibly expand when the numbers landed
            // (user 2026-08-30) — hold a representative width.
            Text(verbatim: "\(PopupGlyph.text(theme.cashIcon))8,888")
                .font(PopupFont.caption)
                .fixedSize()
                .opacity(0)
        } else if !theme.plain,
           let row = usage.report?.accounts.first(where: { $0.number == account.number }) {
            let usd = Int(row.estimatedUSD)
            Text(verbatim: model.compactRows && usd >= 1000
                 ? "\(PopupGlyph.text(theme.cashIcon))\(Int((Double(usd) / 1000).rounded()))k"
                 : "\(PopupGlyph.text(theme.cashIcon))\(usd.formatted())")
                .font(PopupFont.caption).foregroundStyle(.yellow)
                .instantTip("Estimated API-price spend, last "
                            + "\(usage.report?.days ?? 7) days — an estimate, "
                            + "never a bill")
                .fixedSize()
                .activeBand(banded && account.active)
        }
    }
}

/// "10,000" — grouped whole credits for the credit-only rows.
public enum CreditFormat {
    public static func count(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? String(Int(n))
    }
}
