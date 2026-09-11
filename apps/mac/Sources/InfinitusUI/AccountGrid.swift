import SwiftUI
import InfinitusCore

/// The account rows as a real Grid — the alignment the rumps menubar had to
/// fake with monospaced padding (spec §4). The active row gets a contiguous
/// highlight band: Grid offers no per-row background, so each cell paints one
/// and extends it exactly half the row's spacing in every direction — the
/// segments meet edge-to-edge (an overlap would double the translucent
/// color's alpha and show as darker stripes).
struct AccountGrid<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U

    /// Usage-column count of the WIDEST row: 5h + 7d + spend + each
    /// scoped window. Rows that span (dead/ready/sentinel) must cover
    /// exactly this many columns or the cash column shifts left.
    private var usageColumns: Int {
        3 + (model.accounts.map { ($0.usage?.scoped ?? []).count }.max() ?? 0)
    }

    /// Does any row lay out per-column gauges? If so, the one-line rows
    /// (dead/ready/sentinel) must not size their column — they start in the
    /// 5h column and run across the empty cells beside them. Spanning with
    /// gridCellColumns instead rendered the grid ~(span-1)*spacing wider
    /// than fixedSize measured, so the popup clipped both edges whenever a
    /// themed account was dead (2026-08-30, dev shim fleet).
    private var anyGauged: Bool {
        model.compactRows ? false : model.accounts.contains { a in
            let c = AccountCells(model: model, usage: usage, account: a)
            return SentinelNotes.note(for: a.usageStatus) == nil && !c.dead && !c.allFresh
        }
    }

    /// Empty cells that keep a one-line row on the shared column grid.
    @ViewBuilder private var oneLineFillers: some View {
        ForEach(1..<usageColumns, id: \.self) { _ in Text(verbatim: "") }
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Array(model.displayAccounts.enumerated()),
                    id: \.element.number) { rowIndex, account in
                let cells = AccountCells(model: model, usage: usage, account: account)
                GridRow {
                    // Group, not GridRow, carries the rows-intro: a Group
                    // hands its modifier to each child, so the cells keep
                    // their columns and still enter as one sliding row.
                    Group {
                    HStack(spacing: 2) {
                        NextMarker(model: model, number: account.number)
                        Text(cells.slotDisplay)
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle(account.active ? Color.accentColor : Color.primary)
                            .instantTip(cells.slotTip)
                    }
                    .alignedColumn("slot")
                    .activeBand(account.active)
                    // One cell per row reports its bounds for the death
                    // band — threading a number through every activeBand
                    // site would touch 13 call sites for the same union.
                    .anchorPreference(key: DeadRowBounds.self,
                                      value: .bounds) { [account.number: [$0]] }
                    HStack(spacing: 4) {
                        Button(action: {
                            // disabled rows stay clickable, like rumps; the
                            // popup-level alert asks before committing
                            if !account.active, model.capabilities.contains(.switch) { model.pendingSwitch = account.number }
                        }, label: { cells.nameLabel })
                        .buttonStyle(.plain)
                        .contextMenu { AccountRowMenu(model: model, account: account) }
                        .fontWeight(account.active ? .bold : .regular)
                        .foregroundStyle((account.disabled ?? false) || cells.showAsDead
                                         ? AnyShapeStyle(.secondary)
                                         : account.active
                                         ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.primary))
                        .help(cells.dead ? "Out of at least one limit — unusable until it resets"
                                         : "Switch to this account")
                        .lineLimit(1)
                        AccountResumeButton(model: model, account: account)
                    }
                    // The one deliberately flexible column: emails truncate,
                    // usage numbers and reset times never do.
                    .frame(minWidth: 110, maxWidth: 230, alignment: .leading)
                    .alignedColumn("name")
                    .activeBand(account.active)
                    Text(cells.planText ?? "")
                        .font(PopupFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .instantTip("Subscription: \(account.plan ?? "?")")
                        .alignedColumn("plan")
                        .activeBand(account.active)
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        // Short one-liner like deadCell — the full note
                        // wraps to three rows inside one grid column;
                        // fixedSize overflows across the filler cells
                        // instead, tooltip keeps the whole sentence.
                        // relogin_required is a BUTTON: it starts the
                        // in-app relogin right from the list (user
                        // 2026-08-31) — real engine only, the demo cast
                        // must never launch a real OAuth flow.
                        SentinelActionText(model: model, account: account,
                                           note: note)
                            .fixedSize()
                            .instantTip(account.usageStatus == "relogin_required"
                                        && !model.isPlayground
                                        ? "Re-login now — opens this account's private login window"
                                        : note)
                            .gridCellUnsizedAxes(anyGauged ? .horizontal : [])
                            .activeBand(account.active)
                        oneLineFillers
                    } else if cells.showAsDead,
                              cells.deadCause?.kind == .session,
                              account.usage?.sevenDay != nil {
                        // Dead on the 5h window ONLY (user 2026-09-01):
                        // the weekly and per-model quotas still carry real
                        // signal — gauges shown WITH their reset times
                        // ("all accounts need to show 7d reset time no
                        // matter what status", user 2026-09-03); the 5h
                        // cause line keeps its own countdown.
                        if model.compactRows {
                            HStack(spacing: 12) {
                                cells.deadCell
                                cells.windowCell(account.usage?.sevenDay,
                                                 session: false)
                                cells.spendCell
                                cells.scopedCells
                            }
                            .fixedSize()
                            .alignedColumn("usage")
                            .activeBand(account.active)
                            oneLineFillers
                            cells.cashCell.alignedColumn("cash")
                        } else {
                            cells.deadCell.alignedColumn("5h")
                            cells.windowCell(account.usage?.sevenDay,
                                             session: false)
                                .alignedColumn("7d")
                            cells.spendCell.alignedColumn("spend")
                            cells.scopedCells
                            cells.cashCell.alignedColumn("cash")
                        }
                    } else if cells.showAsDead {
                        // A dead row shows ONLY what blocks it — a full MP
                        // gauge on an unusable account reads as usable.
                        cells.deadCell
                            .gridCellUnsizedAxes(anyGauged ? .horizontal : [])
                        oneLineFillers
                        cells.cashCell.alignedColumn("cash")
                    } else if cells.allFresh {
                        // A fully-available account carries no signal worth
                        // five gauges — one "ready" line in every mode.
                        cells.readyCell
                            .gridCellUnsizedAxes(anyGauged ? .horizontal : [])
                        oneLineFillers
                        cells.cashCell.alignedColumn("cash")
                    } else if model.compactRows {
                        // Compact hides empty/exhausted cells, which makes
                        // per-cell grid columns meaningless — a row whose 5h
                        // cell vanished would show its 7d gauge floating in
                        // the wrong column. Pack the visible cells tight in
                        // ONE cell; only number/name/plan/cash stay columns.
                        // The packed cell sizes the 5h column like the
                        // dead/ready one-liners do and fillers keep the
                        // cash column in place: a spanning cell never fed
                        // its width to the columns, so a wide packed row
                        // ran under the cash figures (#100).
                        HStack(spacing: 12) {
                            cells.windowCell(account.usage?.fiveHour, session: true)
                            cells.windowCell(account.usage?.sevenDay, session: false)
                            cells.spendCell
                            cells.scopedCells
                        }
                        .fixedSize()
                        .alignedColumn("usage")
                        .activeBand(account.active)
                        oneLineFillers
                        cells.cashCell.alignedColumn("cash")
                    } else {
                        cells.windowCell(account.usage?.fiveHour, session: true).alignedColumn("5h")
                        cells.windowCell(account.usage?.sevenDay, session: false).alignedColumn("7d")
                        cells.spendCell.alignedColumn("spend")
                        cells.scopedCells
                        cells.cashCell.alignedColumn("cash")
                    }
                    }
                    .introRow(model, index: rowIndex)
                }
            }
        }
        // Every section's grid at least as wide as the widest sibling, so
        // the full-width bands below end at the same x in every section
        // (a section without a cash column had a shorter band).
        .alignedColumn("grid")
        // One band + one sweep for the whole active row (Grid has no
        // per-row view): union the reported cell bounds, draw full-width.
        // ± half the 8pt verticalSpacing so rows still read separated.
        // All Lucky 7s: the fever's rainbow-neon wash across the FULL
        // row (every row reports into DeadRowBounds, so its dict knows
        // each row's bounds).
        .backgroundPreferenceValue(DeadRowBounds.self) { dict in
            GeometryReader { geo in
                ForEach(Array(dict.keys), id: \.self) { n in
                    if let a = dict[n]?.first,
                       model.rowTheme.id == "rpg",
                       model.accounts.first(where: { $0.number == n })?
                           .allLucky7s == true {
                        let r = geo[a]
                        LuckyRowBackground()
                            .frame(width: geo.size.width, height: r.height + 6)
                            .offset(y: r.minY - 3)
                    }
                }
            }
        }
        .backgroundPreferenceValue(ActiveCellBounds.self) { anchors in
            GeometryReader { geo in
                if let row = Self.union(anchors.map { geo[$0] }) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.30 * model.fillScale))
                        .frame(width: geo.size.width, height: row.height + 8)
                        .offset(y: row.minY - 4)
                }
            }
        }
        .overlayPreferenceValue(ActiveCellBounds.self) { anchors in
            GeometryReader { geo in
                if let row = Self.union(anchors.map { geo[$0] }) {
                    Color.clear
                        .frame(width: geo.size.width, height: row.height + 8)
                        .switchFlash(model.switchFlashTick,
                                     color: ThemeColor.flash(model.rowTheme))
                        .offset(y: row.minY - 4)
                        .allowsHitTesting(false)
                }
            }
        }
        // Dying flash (user 2026-09-01): rows whose binding window is in
        // the 90s breathe red until they either die or recover. Reuses
        // the per-row bounds every slot cell already reports.
        .overlayPreferenceValue(DeadRowBounds.self) { dict in
            criticalOverlay(dict, numbers: criticalNumbers)
        }
        // The reviver (#227): while every account is limited, the row
        // that comes back first breathes in the theme's flash colour.
        .overlayPreferenceValue(DeadRowBounds.self) { dict in
            reviverOverlay(dict, number: model.reviver?.number)
        }
        // Death beats: a red band over each row whose account just went
        // dead (the slot cell reported its bounds; full grid width).
        .overlayPreferenceValue(DeadRowBounds.self) { dict in
            GeometryReader { geo in
                ForEach(Array(dict.keys), id: \.self) { n in
                    // The band exists for EVERY row, tick or none: a
                    // keyframeAnimator born with its trigger already
                    // bumped renders parked and never plays — the view
                    // must predate the bump (first-death silence,
                    // caught on the revive glow 2026-08-31).
                    if let a = dict[n]?.first {
                        let r = geo[a]
                        Color.clear
                            .frame(width: geo.size.width, height: r.height + 10)
                            .deathFlash(model.deathTicks[n] ?? 0)
                            .offset(y: r.minY - 5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // Revival fanfares: EVERY row reports into DeadRowBounds, so
        // the same dict serves the dead -> alive glow (full grid width).
        .overlayPreferenceValue(DeadRowBounds.self) { dict in
            GeometryReader { geo in
                ForEach(Array(dict.keys), id: \.self) { n in
                    if let a = dict[n]?.first {
                        let r = geo[a]
                        Color.clear
                            .frame(width: geo.size.width, height: r.height + 10)
                            .reviveFlash(model.reviveTicks[n] ?? 0)
                            .offset(y: r.minY - 5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

/// Stacked layout: one card per account — narrow and tall instead of wide.
struct AccountStack<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U
    /// Horizontal-cards layout ("hstack"): the same cards, side by side.
    var horizontal = false

    var body: some View {
        if model.compactRows {
            // Compact stacked: a flat roster, one line per account — no
            // cards, no per-window lines, just the BINDING window's pct
            // (full mode and compact "looked the same", user 2026-08-30).
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(model.displayAccounts.enumerated()),
                        id: \.element.number) { i, account in
                    compactLine(account)
                        .introRow(model, index: i)
                }
            }
        } else if horizontal {
            horizontalCards
        } else {
            fullCards
        }
    }

    /// One roster line: marker, number, name, then the tightest limit
    /// (the one that will actually stop the account) or the dead verb.
    @ViewBuilder private func compactLine(_ account: Account) -> some View {
        let cells = AccountCells(model: model, usage: usage, account: account, banded: false)
        HStack(spacing: 4) {
            NextMarker(model: model, number: account.number)
            Text(cells.slotDisplay)
                .fontWeight(.bold)
                .foregroundStyle(account.active ? Color.accentColor : Color.secondary)
                .instantTip(cells.slotTip)
            Button(action: {
                if !account.active, model.capabilities.contains(.switch) { model.pendingSwitch = account.number }
            }, label: { cells.nameLabel })
            .buttonStyle(.plain)
            .contextMenu { AccountRowMenu(model: model, account: account) }
            .fontWeight(account.active ? .bold : .regular)
            .foregroundStyle((account.disabled ?? false) || cells.dead
                             ? .secondary : .primary)
            .lineLimit(1)
            AccountResumeButton(model: model, account: account)
            Spacer(minLength: 8)
            if cells.showAsDead {
                cells.deadCell
            } else if let (label, pct) = bindingWindow(account) {
                Text(label)
                    .font(PopupFont.caption).bold()
                    .foregroundStyle(.secondary)
                Text("\(Int(pct))%")
                    .font(PopupFont.caption).monospacedDigit()
                    .foregroundStyle(pct >= 90 ? .orange : .secondary)
            }
        }
        .padding(.vertical, 1)
        .background {
            if model.rowTheme.id == "rpg", account.allLucky7s {
                LuckyRowBackground(cornerRadius: 4)
                    .padding(.horizontal, -4)
            }
        }
        .background {
            if account.active {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.26 * model.fillScale))
                    .padding(.horizontal, -4)
            }
        }
        .overlay {
            if model.reviver?.number == account.number {
                CriticalPulse(cornerRadius: 4, color: ThemeColor.flashCG(model.rowTheme), period: 1.4)
                    .padding(.horizontal, -4)
            }
        }
    }

    /// The window closest to its limit — the one that will bind first.
    /// Labels come from the theme ("themify all info", 2026-08-30).
    private func bindingWindow(_ account: Account) -> (String, Double)? {
        guard let u = account.usage else { return nil }
        let theme = model.rowTheme
        var all: [(String, Double)] = []
        if let w = u.fiveHour {
            all.append((theme.plain ? "5h" : PopupGlyph.text(theme.sessionLabel), w.pct))
        }
        if let w = u.sevenDay {
            all.append((theme.plain ? "7d" : PopupGlyph.text(theme.weeklyLabel), w.pct))
        }
        for w in u.scoped ?? [] {
            let name = w.name ?? "?"
            all.append((theme.plain ? name : PopupGlyph.text(theme.scopedPrefix) + name, w.pct))
        }
        return all.max { $0.1 < $1.1 }
    }

    private var fullCards: some View {
        VStack(alignment: .leading, spacing: 6) { cardList }
    }

    /// The same cards laid side by side, top-aligned — horizontal mode
    /// keeps every card's natural width instead of stretching.
    private var horizontalCards: some View {
        HStack(alignment: .top, spacing: 6) { cardList }
    }

    private var cardList: some View {
            ForEach(Array(model.displayAccounts.enumerated()),
                    id: \.element.number) { rowIndex, account in
                let cells = AccountCells(model: model, usage: usage, account: account, banded: false)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        NextMarker(model: model, number: account.number)
                        Text(cells.slotDisplay)
                            .fontWeight(.bold)
                            .foregroundStyle(account.active ? Color.accentColor : Color.secondary)
                            .instantTip(cells.slotTip)
                        Button(action: {
                            if !account.active, model.capabilities.contains(.switch) { model.pendingSwitch = account.number }
                        }, label: { cells.nameLabel })
                            .buttonStyle(.plain)
                            .contextMenu { AccountRowMenu(model: model, account: account) }
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle((account.disabled ?? false) || cells.dead
                                             ? .secondary : .primary)
                            .lineLimit(1)
                        AccountResumeButton(model: model, account: account)
                        if let plan = cells.planText {
                            Text(plan).font(PopupFont.caption).foregroundStyle(.secondary)
                                .instantTip("Subscription: \(account.plan ?? "?")")
                        }
                        Spacer(minLength: 0)
                        cells.cashCell
                    }
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        SentinelActionText(model: model, account: account,
                                           note: note)
                            .lineLimit(1)
                            .instantTip(account.usageStatus == "relogin_required"
                                        && !model.isPlayground
                                        ? "Re-login now — opens this account's private login window"
                                        : note)
                    } else if cells.showAsDead,
                              cells.deadCause?.kind == .session,
                              account.usage?.sevenDay != nil {
                        // 5h-only death: weekly + per-model still shown,
                        // with their reset times (user 2026-09-03).
                        cells.deadCell
                        cells.windowCell(account.usage?.sevenDay,
                                         session: false)
                        cells.spendCell
                        cells.scopedCells
                    } else if cells.showAsDead {
                        cells.deadCell
                    } else if cells.allFresh {
                        cells.readyCell
                    } else {
                        // One attribute per line — the whole point of the
                        // stacked layout (user request 2026-08-30).
                        cells.windowCell(account.usage?.fiveHour, session: true)
                        cells.windowCell(account.usage?.sevenDay, session: false)
                        cells.spendCell
                        cells.scopedCells
                    }
                }
                .padding(8)
                // Vertical: equal-width cards, not ragged islands
                // ("stack cards layout need big improvement", 2026-08-30).
                // Horizontal: natural widths with a floor — infinity
                // maxWidth would make HStack siblings fight over it.
                .frame(minWidth: horizontal ? 150 : nil,
                       maxWidth: horizontal ? nil : .infinity,
                       alignment: .leading)
                .background {
                    // Fever first in the chain = between content and
                    // the card fill: the neon washes the whole card.
                    if model.rowTheme.id == "rpg", account.allLucky7s {
                        LuckyRowBackground(cornerRadius: 8)
                    }
                }
                .background {
                    if account.active {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.26 * model.fillScale))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor.opacity(0.7)))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.07 * model.fillScale))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
                .overlay {
                    if model.reviver?.number == account.number {
                        CriticalPulse(cornerRadius: 8, color: ThemeColor.flashCG(model.rowTheme), period: 1.4)
                    }
                }
                .switchFlash(account.active ? model.switchFlashTick : 0,
                             color: ThemeColor.flash(model.rowTheme))
                .deathFlash(model.deathTicks[account.number] ?? 0)
                .reviveFlash(model.reviveTicks[account.number] ?? 0)
                .introRow(model, index: rowIndex)
            }
    }
}

/// Cells of the active row report their bounds; AccountGrid draws ONE
/// full-width band over their union. Per-cell backgrounds sized to each
/// cell's own height read as mismatched patches with seams — gauge cells
/// are taller than text cells (user screenshot 2026-08-30).
/// One anchor per row, keyed by account number — the death band's
/// geometry feed (the beat needs to know WHICH row, unlike the single
/// active band).
/// Sentinel note cell: plain text, except relogin_required on a real
/// engine — that one is a button starting the in-app relogin flow for
/// the account, straight from the list (user 2026-08-31).
struct SentinelActionText<M: FleetModel>: View {
    @ObservedObject var model: M
    let account: Account
    let note: String

    private var label: String {
        SentinelNotes.short(for: account.usageStatus) ?? note
    }
    private var actionable: Bool {
        account.usageStatus == "relogin_required" && !model.isPlayground
            && !model.capabilities.isDisjoint(with: [.addToken, .addOAuth])
    }

    var body: some View {
        if actionable {
            Button {
                model.startRelogin(account)
            } label: {
                HStack(spacing: 3) {
                    Text(label)
                    Image(systemName: "arrow.right.circle")
                }
                .font(PopupFont.caption)
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        } else {
            Text(label)
                .font(PopupFont.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension AccountGrid {
    /// Accounts alive but with a binding window at 90%+ — the dying set.
    var criticalNumbers: [Int] {
        model.displayAccounts.filter { a in
            !AccountVitals.isDead(a.usage)
                && (PushTriggers.worstPlanPct(a.usage) ?? 0) >= 90
        }.map(\.number)
    }

    /// `numbers` is computed by the caller, outside the GeometryReader:
    /// inside it, the headroom sort ran again on every geometry update
    /// (each pulse frame).
    @ViewBuilder
    func reviverOverlay(_ dict: [Int: [Anchor<CGRect>]], number: Int?) -> some View {
        if let number {
            GeometryReader { geo in
                if let a = dict[number]?.first {
                    let r = geo[a]
                    CriticalPulse(cornerRadius: 4, color: ThemeColor.flashCG(model.rowTheme), period: 1.4)
                        .frame(width: geo.size.width, height: r.height + 8)
                        .offset(y: r.minY - 4)
                }
            }
        }
    }

    func criticalOverlay(_ dict: [Int: [Anchor<CGRect>]], numbers: [Int]) -> some View {
        GeometryReader { geo in
            ForEach(numbers, id: \.self) { n in
                if let a = dict[n]?.first {
                    let r = geo[a]
                    CriticalPulse()
                        .frame(width: geo.size.width, height: r.height + 8)
                        .offset(y: r.minY - 4)
                }
            }
        }
    }
}

struct DeadRowBounds: PreferenceKey {
    static let defaultValue: [Int: [Anchor<CGRect>]] = [:]
    static func reduce(value: inout [Int: [Anchor<CGRect>]],
                       nextValue: () -> [Int: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

struct ActiveCellBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>],
                       nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ActiveBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.anchorPreference(key: ActiveCellBounds.self, value: .bounds) {
            active ? [$0] : []
        }
    }
}

extension View {
    func activeBand(_ on: Bool) -> some View { modifier(ActiveBand(active: on)) }
}

/// Right-click on an account's name: star it (the engine lands on it
/// first, and switches to it now) or pause/resume its rotation — the
/// Settings › Accounts buttons without leaving the popup. #201 put both
/// on the row as buttons; that read as clutter (user 2026-09-06:
/// "pause/resume, star on UI looks clunky -> make it right click action
/// except for paused account -> press to resume"), so the row keeps only
/// `AccountResumeButton`. Each item shows only when the engine has the
/// knob (nil `preferred` = no pick-first setting in this build).
struct AccountRowMenu<M: FleetModel>: View {
    let model: M
    let account: Account

    var body: some View {
        if model.capabilities.contains(.prefer), let starred = account.preferred {
            Button {
                model.setPreferred(account.number, !starred)
            } label: {
                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
            }
        }
        if model.capabilities.contains(.hold) {
            let paused = account.disabled ?? false
            Button {
                model.setRotation(account.number, enabled: paused)
            } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.circle" : "pause.circle")
            }
        }
    }
}

/// The one row-level control that survives: a paused account shows a
/// play button, one press puts it back into rotation. Starred state
/// needs no button — the name label already leads with ★.
struct AccountResumeButton<M: FleetModel>: View {
    let model: M
    let account: Account

    var body: some View {
        if model.capabilities.contains(.hold), account.disabled == true {
            Button {
                model.setRotation(account.number, enabled: true)
            } label: {
                Image(systemName: "play.circle")
                    .font(PopupFont.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .instantTip("Resume — back into rotation")
        }
    }
}
