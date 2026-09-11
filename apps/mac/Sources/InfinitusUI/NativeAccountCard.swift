import SwiftUI
import InfinitusCore

/// The account vocabulary, composed for a NATIVE touch list (#9): the
/// phone's Fleet tab draws real `List` rows, but every gauge, label,
/// marker and word inside them is still `AccountCells` — the same
/// builders the Mac's grid and stacked cards use. These wrappers live in
/// InfinitusUI (not ios/) because `AccountCells`, `NextMarker` and the
/// lucky-7s trigger are module-internal; the phone gets a public seam,
/// never a second copy of the rules.
///
/// Layout only: no navigation, no haptics, nothing UIKit — the shell is
/// the app's, the content is shared.

/// Line 1 of a native account row: the next/recovery marker, the themed
/// slot (or the active crown), the name (wearing the lucky fever when
/// the 7s align), the plan tag, and the cash estimate.
public struct AccountHeaderLine<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U
    let account: Account

    public init(model: M, usage: U, account: Account) {
        self.model = model
        self.usage = usage
        self.account = account
    }

    public var body: some View {
        let cells = AccountCells(model: model, usage: usage,
                                 account: account, banded: false)
        HStack(spacing: 6) {
            NextMarker(model: model, number: account.number)
            Text(cells.slotDisplay)
                .font(.subheadline).fontWeight(.bold)
                .foregroundStyle(account.active ? Color.accentColor : Color.secondary)
            name(cells)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle((account.disabled ?? false) || cells.dead
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(.primary))
            if let plan = cells.planText {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 4)
            cells.cashCell
        }
    }

    @ViewBuilder
    private func name(_ cells: AccountCells<M, U>) -> some View {
        if cells.allLucky {
            LuckyName(text: cells.displayName, font: .headline)
        } else {
            Text(cells.displayName)
                .font(.headline)
                .fontWeight(account.active ? .bold : .semibold)
        }
    }
}

/// Lines 2…n: one shared cell per window — the Mac's own branch order
/// (sentinel note, 5h-only death, dead, all-fresh, else every window).
/// `wide` lays them across instead of down, which is exactly the wide
/// grid's cell order on one line.
public struct AccountUsageLines<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U
    let account: Account
    /// Landscape / regular width: the Mac's wide-row order, in a row.
    var wide: Bool

    public init(model: M, usage: U, account: Account, wide: Bool = false) {
        self.model = model
        self.usage = usage
        self.account = account
        self.wide = wide
    }

    public var body: some View {
        let cells = AccountCells(model: model, usage: usage,
                                 account: account, banded: false)
        lay {
            if let note = SentinelNotes.note(for: account.usageStatus) {
                SentinelActionText(model: model, account: account, note: note)
                    .lineLimit(1)
            } else if cells.showAsDead, cells.deadCause?.kind == .session,
                      account.usage?.sevenDay != nil {
                // 5h-only death (user 2026-09-01): the weekly and
                // per-model quotas still carry signal, reset times shown.
                cells.deadCell
                cells.windowCell(account.usage?.sevenDay, session: false)
                cells.spendCell
                cells.scopedCells
            } else if cells.showAsDead {
                cells.deadCell
            } else if cells.allFresh {
                cells.readyCell
            } else {
                cells.windowCell(account.usage?.fiveHour, session: true)
                cells.windowCell(account.usage?.sevenDay, session: false)
                cells.spendCell
                cells.scopedCells
            }
        }
    }

    @ViewBuilder
    private func lay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if wide {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                content()
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) { content() }
        }
    }
}

/// The detail sheet's body: EVERY window in full — themed label, the
/// shared gauge, the percentage and the absolute reset date/time. The
/// row cells hide untouched/exhausted windows in compact mode and shrink
/// their reset words; the detail never does.
public struct AccountWindowDetails<M: FleetModel>: View {
    @ObservedObject var model: M
    let account: Account

    public init(model: M, account: Account) {
        self.model = model
        self.account = account
    }

    private struct Spec: Identifiable {
        let id: String
        let label: String
        let color: String
        let pct: Double
        let expectedPct: Double?
        let dividers: [Double]
        let resetsAt: String?
        let countdown: String?
        let clock: String?
        var footnote: String? = nil
    }

    private var specs: [Spec] {
        let theme = model.rowTheme
        var out: [Spec] = []
        if let w = account.usage?.fiveHour {
            out.append(Spec(id: "5h",
                            label: label(theme.sessionLabel, plain: "5h session"),
                            color: theme.sessionColor, pct: w.pct,
                            expectedPct: w.expectedPct,
                            dividers: (1..<5).map { Double($0) * 20 },
                            resetsAt: w.resetsAt, countdown: w.countdown,
                            clock: w.clock))
        }
        if let w = account.usage?.sevenDay {
            out.append(Spec(id: "7d",
                            label: label(theme.weeklyLabel, plain: "7d weekly"),
                            color: theme.weeklyColor, pct: w.pct,
                            expectedPct: w.expectedPct,
                            dividers: (1..<7).map { Double($0) * 100 / 7 },
                            resetsAt: w.resetsAt, countdown: w.countdown,
                            clock: w.clock))
        }
        for w in account.usage?.scoped ?? [] {
            let name = theme.modelName(w.name)
            out.append(Spec(id: "scoped-\(w.name ?? "?")",
                            label: theme.plain
                                ? "\(name) weekly"
                                : PopupGlyph.text(theme.scopedPrefix) + name,
                            color: theme.scopedColor, pct: w.pct,
                            expectedPct: w.expectedPct,
                            dividers: (1..<7).map { Double($0) * 100 / 7 },
                            resetsAt: w.resetsAt, countdown: w.countdown,
                            clock: w.clock))
        }
        if let s = account.usage?.spend {
            out.append(Spec(id: "spend",
                            label: label(theme.creditLabel, plain: "usage credit"),
                            color: theme.creditColor, pct: s.pct,
                            expectedPct: nil, dividers: [],
                            resetsAt: s.resetsAt, countdown: s.countdown,
                            clock: s.clock,
                            footnote: String(format: "%.2f of %.0f %@ spent",
                                             s.used, s.limit, s.currency)))
        }
        return out
    }

    private func label(_ themed: String, plain: String) -> String {
        model.rowTheme.plain ? plain : PopupGlyph.text(themed)
    }

    public var body: some View {
        ForEach(specs) { spec in
            let color = ThemeColor.resolve(spec.color)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(spec.label)
                        .font(.subheadline).bold()
                        .foregroundStyle(color)
                    Spacer()
                    Text("\(Int(spec.pct))% used")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(spec.pct >= 100 ? .red : .primary)
                }
                // The gauge carries its own remaining-% label — a second
                // "N% left" beside it just said the same number twice.
                GaugeBar(remaining: GaugeMath.remaining(usedPct: spec.pct),
                         color: color,
                         paceRemaining: spec.expectedPct.map { 100 - $0 },
                         dividers: spec.dividers)
                if let reset = Self.resetLine(spec) {
                    Text(reset).font(.caption).foregroundStyle(.secondary)
                }
                if let footnote = spec.footnote {
                    Text(footnote).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Absolute reset moment, spelled out — the row's compact "2h" is a
    /// glance, the sheet is where the real time belongs.
    private static func resetLine(_ spec: Spec) -> String? {
        if let date = WeeklyRoll.parse(spec.resetsAt) {
            return "resets " + date.formatted(date: .abbreviated, time: .shortened)
        }
        if let countdown = spec.countdown { return "resets in \(countdown)" }
        if let clock = spec.clock { return "resets \(clock)" }
        return nil
    }
}

/// Row-state predicates the native shell needs but can't compute — the
/// lucky-7s trigger is a module-internal extension, and dead/critical
/// should read from one place with it.
public enum AccountRowVitals {
    public static func isDead(_ account: Account) -> Bool {
        AccountVitals.isDead(account.usage)
    }

    /// The dying set: alive, but its binding window is in the 90s —
    /// what the Mac's grid paints `CriticalPulse` over.
    public static func isCritical(_ account: Account) -> Bool {
        !isDead(account) && (PushTriggers.worstPlanPct(account.usage) ?? 0) >= 90
    }

    /// All Lucky 7s, RPG only — the fever background's trigger.
    public static func isLucky(_ account: Account, theme: RowTheme) -> Bool {
        theme.id == "rpg" && account.allLucky7s
    }
}
