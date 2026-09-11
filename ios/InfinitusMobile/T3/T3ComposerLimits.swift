import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's `/usage-limits` (upstream 6c583620f, `usageLimits.ts`
/// USAGE_LIMITS_COMMAND + `ComposerUsageLimits.tsx`): typed alone in the
/// composer it is answered on the phone from the last snapshot — the
/// session's account(s) and their windows, docked above the composer —
/// and never sent as a turn. Drift, on purpose: T3 only owns the name
/// where Limits has data for the provider and otherwise passes it to the
/// agent; Claude Code has no such command, so the phone always keeps it
/// and says when the account reports nothing.
enum T3ComposerLimits {
    static let command = SlashCommand(name: "usage-limits", description: "Show this provider's usage limits",
                                      source: .userCommand)

    /// `isUsageLimitsCommand`: the bare command; anything with arguments is an ordinary prompt.
    static func isCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/usage-limits"
    }

    struct Report: Equatable {
        let provider: Provider
        let members: [T3UsageLimits.Member]
        let notices: [String]
    }

    /// The accounts a session's requests go through (`SessionAccountLookup`):
    /// a swap engine's one active account, or every account behind a proxy fleet.
    /// nil when there is no fleet to attribute the session to.
    static func report(_ summary: SessionAccountSummary?, provider: Provider, now: Date) -> Report? {
        guard let summary else { return nil }
        let accounts: [Account]
        switch summary.kind {
        case .proxy: accounts = summary.proxyAccounts
        case .swap, .unknownFleet: accounts = summary.account.map { [$0] } ?? []
        }
        return Report(provider: provider, members: accounts.map { T3UsageLimits.member($0, now: now) },
                      notices: T3UsageLimits.notices(accounts))
    }
}

/// `ComposerUsageLimits`: the Usage → Limits card one size down — a
/// heading per account (provider mark, name, plan), a bar per window with
/// quota left, the time-left hairline, pace and countdown — with a close
/// control on the first heading; a report with no accounts gets a heading
/// of its own for the close.
struct T3ComposerLimitsCard: View {
    let report: T3ComposerLimits.Report
    let now: Date
    let onClose: () -> Void
    @Environment(\.t3) private var t3

    var body: some View {
        let p = t3.mobile
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(report.members.enumerated()), id: \.element.number) { index, member in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            T3ProviderIcon(size: 16)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(report.provider.displayName).font(T3Font.mobile(.base, .medium)).foregroundStyle(p.foreground.color)
                                Text("· \(member.name)").font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color).lineLimit(1)
                                if let plan = member.plan, !plan.isEmpty {
                                    Text("· \(plan)").font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if index == 0 { close }
                        }
                        if member.windows.isEmpty {
                            Text("No limits reported for this account.").font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(member.windows, id: \.id) { window in windowRow(window) }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(p.borderSubtle.color).frame(height: 1) } }
                }
                if report.members.isEmpty {
                    HStack(spacing: 12) {
                        Text("Usage limits").font(T3Font.mobile(.base)).foregroundStyle(p.foreground.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        close
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                ForEach(report.notices, id: \.self) { notice in
                    Text(notice).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .overlay(alignment: .top) {
                            if !report.members.isEmpty { Rectangle().fill(p.borderSubtle.color).frame(height: 1) }
                        }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
        .fixedSize(horizontal: false, vertical: true)
        .background(p.card.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var close: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t3.mobile.iconMuted.color)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -8)
        .accessibilityLabel("Dismiss usage limits")
    }

    /// `WindowRow`: the fill is quota left, the hairline how much of the
    /// window is left; pace under the left edge, the countdown under the right.
    private func windowRow(_ window: T3UsageLimits.Window) -> some View {
        let p = t3.mobile
        let remaining = window.remainingPct
        let timeLeft = window.elapsedShare(now: now).map { 1 - $0 }
        let pace = T3UsageLimits.pace(window, now: now)
        let resets = T3UsageLimits.resetsIn(window, now: now)
        let fill: Color = remaining <= 10 ? Color(.sRGB, red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255)
            : remaining <= 30 ? Color(.sRGB, red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255)
            : T3UsageColors.bar(report.provider, dark: t3.scheme == .dark)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(window.label).font(T3Font.mobile(.sm)).foregroundStyle(p.foreground.color)
                Spacer(minLength: 0)
                Text("\(remaining)% left").font(T3Font.mobile(.sm, .medium)).monospacedDigit().foregroundStyle(p.foreground.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.subtle.color).frame(height: 6)
                    Capsule().fill(fill).frame(width: geo.size.width * CGFloat(remaining) / 100, height: 6)
                    if let timeLeft {
                        Rectangle().fill(p.foreground.color.opacity(0.6)).frame(width: 1, height: 12)
                            .offset(x: geo.size.width * CGFloat(timeLeft) - 0.5)
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            if pace != nil || resets != nil {
                HStack(spacing: 12) {
                    Text(pace.map(Self.paceLabel) ?? "").font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                    Spacer(minLength: 0)
                    Text(resets ?? "").font(T3Font.mobile(.xs)).monospacedDigit().foregroundStyle(p.foregroundTertiary.color)
                }
            }
        }
    }

    private static func paceLabel(_ pace: T3UsageLimits.Pace) -> String {
        switch pace {
        case .ahead: return "ahead of pace"
        case .on: return "on pace"
        case .under: return "under pace"
        }
    }
}
