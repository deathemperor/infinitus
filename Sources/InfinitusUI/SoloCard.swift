import SwiftUI
import InfinitusCore

/// The one-account popup (user 2026-09-03: "invest efforts for users
/// with 1 & 2 accounts (majority of users)"). A single grid row is a
/// fleet vocabulary with nothing to compare against — a thin strip of
/// small gauges. Alone, the account IS the popup: one card, the name
/// up top, every window on its own line with a gauge three times the
/// grid's and the full reset text beside it. The same AccountCells
/// builders as the rows, so themes, effects and tooltips carry over.
struct SoloCard<M: FleetModel, U: UsageSource>: View {
    @ObservedObject var model: M
    @ObservedObject var usage: U
    let account: Account

    var body: some View {
        let cells = AccountCells(model: model, usage: usage, account: account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(cells.slotDisplay)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                    .instantTip(cells.slotTip)
                cells.nameLabel
                    .font(PopupFont.body.weight(.bold))
                    .foregroundStyle(cells.showAsDead ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(Color.accentColor))
                    .lineLimit(1)
                if let plan = cells.planText {
                    Text(plan).font(PopupFont.caption).foregroundStyle(.secondary)
                        .instantTip("Subscription: \(account.plan ?? "?")")
                }
                Spacer(minLength: 12)
                cells.cashCell
            }
            if let note = SentinelNotes.note(for: account.usageStatus) {
                SentinelActionText(model: model, account: account, note: note)
                    .lineLimit(1)
                    .instantTip(account.usageStatus == "relogin_required" && !model.isPlayground
                                ? "Re-login now — opens this account's private login window"
                                : note)
            } else if cells.allFresh {
                cells.readyCell
            } else {
                // Dead rows keep their windows: the reset time is the
                // whole point when there is no other account to use.
                if cells.showAsDead { cells.deadCell }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow { cells.windowCell(account.usage?.fiveHour, session: true) }
                    GridRow { cells.windowCell(account.usage?.sevenDay, session: false) }
                    GridRow { cells.spendCell }
                    GridRow { cells.scopedCells }
                }
                .environment(\.gaugeScale, 3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if model.rowTheme.id == "rpg", account.allLucky7s {
                LuckyRowBackground(cornerRadius: 8)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.26 * model.fillScale))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.7)))
        }
        .overlay {
            if model.reviver?.number == account.number {
                CriticalPulse(cornerRadius: 8, color: ThemeColor.flashCG(model.rowTheme), period: 1.4)
            }
        }
        .switchFlash(model.switchFlashTick, color: ThemeColor.flash(model.rowTheme))
        .deathFlash(model.deathTicks[account.number] ?? 0)
        .reviveFlash(model.reviveTicks[account.number] ?? 0)
        .introRow(model, index: 0)
        .onAppear { if !model.rowTheme.plain { usage.loadIfNeeded() } }
    }
}

/// Under the solo card: why a second account is worth having, with the
/// sign-in one click away. Nothing when the host can't add one.
struct SecondAccountNudge<M: FleetModel>: View {
    @ObservedObject var model: M

    var body: some View {
        if model.canAddAccount {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                Text("One account: when a window fills you wait for the reset. "
                     + "A second one keeps you working — auto-switch does the rest.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Add account…") { model.addAccount() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .font(PopupFont.caption)
            .padding(.horizontal, 6)
        }
    }
}
