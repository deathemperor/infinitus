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
            let what = AccountVitals.spentModel(across: model.accounts)
                .map { "All accounts are out of \($0)" } ?? "All accounts are at a limit"
            Image(systemName: "arrowtriangle.right")
                .font(PopupFont.caption2)
                .foregroundStyle(ThemeColor.flash(theme))
                .instantTip("\(what) — this one recovers first\(Self.eta(recovery.at))")
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

/// A keep-warm account whose 5h clock has stopped. That slot is blank
/// exactly then — the endpoint reports no reset for a window that is not
/// running — so the word goes where the countdown would have been, and
/// where the engine can ignite, one confirmed press starts the window.
struct WarmChip<M: FleetModel>: View {
    @ObservedObject var model: M
    let number: Int
    let name: String
    let word: String

    private var why: String {
        "Keep-warm is on, but \(name)'s 5h window is not running — "
        + "nothing counts down until a request starts one"
    }

    @ViewBuilder var body: some View {
        if model.canIgnite {
            IgniteAction(model: model, number: number) { armed in
                armed ? "Click again within 6 s to start \(name)'s 5h window now"
                      : why + ". Click to start it with one tiny request (asks again before it fires)"
            } label: { armed in
                (Text(Image(systemName: armed ? "flame.fill" : "flame"))
                 + Text(armed ? " Sure?" : " " + word))
                    .font(PopupFont.caption.weight(armed ? .semibold : .regular))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(armed ? Color.orange : Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(armed ? .white : .secondary)
            }
        } else {
            // A fleet this Mac cannot ignite (another machine's rows, #1545)
            // wears the same chip, so "cold" reads the same on every row;
            // only the press is missing, and the tooltip says why.
            (Text(Image(systemName: "flame")) + Text(" " + word))
                .font(PopupFont.caption)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
                .instantTip(why)
        }
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
        // background cost-report run, cached on the fleet's UsageSource.
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
    /// Plan-dead only: a row out of one model keeps its icon and gauges,
    /// and that model's cell says "down" on its own (`ownCause`).
    var dead: Bool { AccountVitals.isPlanDead(account.usage) }

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

    /// "6 min ago" beside the plan, with its tooltip, when the engine
    /// could not refresh this account (#965); nil for every other row.
    var staleAge: (label: String, tip: String)? {
        guard let label = account.staleAgeLabel, let tip = account.staleTip else { return nil }
        return (label, tip)
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
        // No pause mark and no "(disabled)" tag: a paused row said it three
        // times over (user 2026-09-16 "too many disabled labels, just keep
        // the pause icon"), and the one that stays is `AccountPauseButton`
        // beside the name — a marker you can press to resume.
        // The star (pick-first, #15) leads: the lists used to show
        // nothing for it (user 2026-09-03 "doesn't show the star on list").
        return [account.preferred == true ? PopupGlyph.text("★") : nil,
                showAsDead ? PopupGlyph.text(theme.deadMarker) : nil,
                account.icon, account.alias ?? account.email]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Compact mode drops untouched/exhausted cells, but a fully available
    /// account keeps all its gauges so the row never goes blank.
    func hiddenInCompact(_ pct: Double) -> Bool {
        model.compactRows && !allFresh
            && (pct <= 0 || (pct >= 100 && !model.dying.contains(account.number)))
    }

    func resetText(_ w: UsageWindow) -> String? {
        guard let when = compactText
            ? ResetLabel.compact(w) : ResetLabel.label(w) else { return nil }
        return (w.pct >= 100 ? PopupGlyph.text(theme.revivePrefix) : "") + when
    }

    /// Reset label that goes LIVE inside the revive lead (ten minutes by
    /// default): a per-second m:ss
    /// countdown, then a pulsing "resetting…" until the next snapshot
    /// replaces the data. No numericText roll here: on macOS 26 a
    /// per-second `.contentTransition(.numericText)` grows the CG glyph
    /// cache ~2 MB/min for as long as it ticks (#18, measured
    /// 2026-09-03: with it 2.1 MB/min, without 0). Fine on the pct
    /// texts, which change once a minute at most.
    /// The live path is also gated on the measurement being fresh enough
    /// for its reset to still mean anything: a stale row whose reset has
    /// already gone by is narrating a window it stopped watching, and the
    /// countdown lands on a permanent pulse (#1118). Such a row falls
    /// through to the static text, where `staleAge` beside the plan says
    /// how old the reading is.
    @ViewBuilder func resetLabelView(resetsAt: String?, staticText: String?) -> some View {
        if let date = WeeklyRoll.parse(resetsAt),
           date.timeIntervalSinceNow < model.reviveLead,
           account.resetIsKnowable(resetsAt) {
            let isReviver = model.reviver?.number == account.number
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = date.timeIntervalSince(ctx.date)
                if left <= 0 {
                    Text(theme.plain || theme.resetWord.isEmpty
                         ? "resetting…" : PopupGlyph.text(theme.resetWord))
                        .font(PopupFont.caption).bold().foregroundStyle(.green)
                        .opacity(0.35 + 0.65 * abs(sin(
                            ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                } else if isReviver {
                    // The reviver's row (#227) carries the full countdown in
                    // the theme's flash colour — the same digits as the
                    // floating panel.
                    Text(RecoveryCountdown.label(until: date, now: ctx.date))
                        .font(PopupFont.caption).bold().monospacedDigit()
                        .foregroundStyle(ThemeColor.flash(theme))
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

    /// The spent window a cell stands for: every dead window reads "down"
    /// in its own cell, not only the governing one (user 2026-09-19).
    func ownCause(_ isMine: (AccountVitals.DeadCause) -> Bool) -> AccountVitals.DeadCause? {
        AccountVitals.deadCauses(account.usage).first(where: isMine)
    }

    func repeatsClock(_ cause: AccountVitals.DeadCause) -> Bool {
        AccountVitals.resetRepeatsEarlierCause(cause, in: account.usage)
    }

    /// Whether the weekly cell of THIS row already counts down the clock a
    /// dead model window would repeat — Fable's quota rolls with the 7d one
    /// (user 2026-09-15: "fable has reset time of 7d so when fable is down
    /// no needs to show its reset time"). Only when that cell is really on
    /// screen: compact mode hides an untouched or exhausted weekly, and
    /// then the dead line is the row's only clock. (A weekly with no
    /// parseable reset never echoes — resetEchoesWeekly says so.)
    func weeklyAlreadyShows(_ cause: AccountVitals.DeadCause) -> Bool {
        guard let weekly = account.usage?.sevenDay else { return false }
        return AccountVitals.resetEchoesWeekly(cause, in: account.usage)
            && !hiddenInCompact(weekly.pct)
    }

    /// Every present plan window untouched: keep their gauges even in
    /// compact mode. Extra usage credit does not change plan availability.
    var allFresh: Bool {
        guard let u = account.usage else { return false }
        var pcts: [Double] = []
        if let p = u.fiveHour?.pct { pcts.append(p) }
        if let p = u.sevenDay?.pct { pcts.append(p) }
        for w in u.scoped ?? [] { pcts.append(w.pct) }
        return !pcts.isEmpty && pcts.allSatisfy { $0 <= 0 }
    }

    /// The dead line as a cell of its own (the narrow list's one-liner).
    @ViewBuilder var deadCell: some View {
        deadLine().fixedSize().activeBand(banded && account.active)
    }

    /// One line saying what blocks a dead row, drawn in that window's own
    /// cell while the other gauges stay (user 2026-09-13: "anything is
    /// down, the others are visible"). Plain words, not themed icon soup —
    /// "📦 💊 spent" read as a riddle (user-verified); only the color and
    /// the dead marker carry the theme here.
    ///
    /// `timer: false` drops the reset: a dead per-model window whose
    /// clock the weekly cell already counts down says it twice otherwise
    /// (user 2026-09-15). The tooltip keeps the countdown either way.
    ///
    /// `of:` is the cell's own spent window; the governing cause when
    /// omitted (the narrow list's one-liner).
    @ViewBuilder func deadLine(of own: AccountVitals.DeadCause? = nil,
                               timer: Bool = true) -> some View {
        if let cause = own ?? deadCause {
            HStack(spacing: 4) {
                // Themed label + themed verb ("MP down", "🎬 sold out");
                // the plain theme keeps plain words. The tooltip carries
                // the plain-English translation either way.
                Text(theme.plain
                     ? "\(causeWord(cause)) out"
                     : "\(causeLabel(cause)) \(PopupGlyph.text(theme.deadVerb))")
                    .font(PopupFont.caption).bold()
                    .foregroundStyle(ThemeColor.resolve(causeColor(cause)))
                if timer {
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
            }
            .instantTip("\(plainCause(cause)) is used up (100%) — the "
                        + "account can't serve requests until it resets"
                        + (cause.countdown.map { " in \($0)" } ?? ""))
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
            if showAsDead, let cause = ownCause({ $0.blocks(session: session) }) {
                deadLine(of: cause, timer: !repeatsClock(cause)).fixedSize()
            } else if let w, !hiddenInCompact(w.pct) {
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
                        if !session, w.pct <= 0 {
                            // Untouched accounts still show their weekly slot
                            // when the engine omits it from a zero-usage reply.
                            if let when = ReadyWeeklyCaption.text(
                                pct: w.pct, resetsAt: w.resetsAt,
                                countdown: w.countdown, clock: w.clock,
                                remembered: WeeklyResetMemory.shared.futureReset(email: account.email),
                                compact: compactText) {
                                Text(when).font(PopupFont.caption).foregroundStyle(.secondary)
                            }
                        } else if session, let word = SessionWarmth.caption(account: account) {
                            WarmChip(model: model, number: account.number,
                                     name: account.alias
                                        ?? String(account.email.prefix(while: { $0 != "@" })),
                                     word: word)
                        } else {
                            resetLabelView(resetsAt: w.resetsAt, staticText: resetText(w))
                        }
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
                if showAsDead, let cause = ownCause({ $0.blocks(scoped: w.name) }) {
                    deadLine(of: cause,
                             timer: !weeklyAlreadyShows(cause) && !repeatsClock(cause))
                } else if hiddenInCompact(w.pct) {
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
