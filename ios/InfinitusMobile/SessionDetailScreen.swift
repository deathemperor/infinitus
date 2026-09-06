import SwiftUI
import InfinitusCore
import InfinitusUI

/// Value pushed by tapping a session's header (feed screen) — a distinct
/// type from `SessionDetail` so the row tap (→ feed) and the header tap
/// (→ detail, one level deeper) stack cleanly on the same `NavigationPath`.
struct SessionDetailRoute: Hashable {
    let session: SessionDetail
}

/// The Mac's session vocabulary in the user's words — one word system
/// across the list, the feed header and the detail screen.
enum SessionWords {
    /// The theme's word for a status ("Questing" for busy under RPG);
    /// the Off theme keeps the plain ones (user 2026-09-04: "theme the
    /// listing and its words too").
    static func status(_ raw: String, theme: RowTheme) -> String {
        theme.sessionWord(raw)
    }

    /// Same colors the Mac's sessions card uses for each status.
    static func color(_ raw: String) -> Color {
        switch raw {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        default: return .gray
        }
    }

    static func kind(_ raw: String) -> String {
        switch raw {
        case "interactive": return "Interactive"
        case "headless", "print": return "Headless"
        case "": return "Unknown"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Fresh sessions say "now", not "0m".
    static func age(since epochMs: Double) -> String {
        let s = Int(-Date(timeIntervalSince1970: epochMs / 1000).timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

/// One-line + full-section formatting for `SessionAccountSummary` —
/// shared by the feed header (compact) and this screen (full section).
/// Pure string/color-name building, no view state.
enum AccountSummaryFormat {
    static func headerLine(_ summary: SessionAccountSummary?) -> (text: String, colorName: String)? {
        guard let summary else { return nil }
        switch summary.kind {
        case .cswap, .unknownFleet:
            guard let account = summary.account else { return ("no active account", "secondary") }
            let suffix = summary.kind == .unknownFleet ? " (fleet's active account)" : ""
            return (accountCaption(account) + suffix,
                    AccountHeadroom.colorName(forPct: AccountHeadroom.worstPct(account)))
        case .proxy:
            let lowest = summary.proxyLowestHeadroom.map { " · lowest \(accountShortName($0))" } ?? ""
            return ("CLIProxyAPI · per-request routing · \(summary.proxyAliveCount) alive\(lowest)",
                    "secondary")
        }
    }

    static func accountCaption(_ account: Account) -> String {
        var parts = [accountShortName(account)]
        if let five = account.usage?.fiveHour { parts.append("5h \(Int(five.pct))%") }
        if let seven = account.usage?.sevenDay { parts.append("7d \(Int(seven.pct))%") }
        if let reset = ResetLabel.compact(account.usage?.fiveHour) { parts.append("resets \(reset)") }
        return parts.joined(separator: " · ")
    }

    static func accountShortName(_ account: Account) -> String {
        [account.icon, account.alias ?? account.email].compactMap { $0 }.joined(separator: " ")
    }
}

/// The detail screen behind a session's header tap (user 2026-09-03):
/// every field the feed's header line has no room for, plus which
/// account(s) are actually serving the session's requests.
struct SessionDetailScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var progress: MobileSessionProgress
    let session: SessionDetail

    private var p: SessionProgress? { progress.byPid[session.pid] }
    private var summary: SessionAccountSummary? { model.accountSummary(forSessionPid: session.pid) }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Name", value: SessionNaming.displayName(name: p?.name, autoName: p?.autoName, cwd: session.cwd))
                Text(session.cwd)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = session.cwd
                        } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    }
                if let branch = p?.gitBranch { LabeledContent("Branch", value: branch) }
                if let model = p?.model { LabeledContent("Model", value: model) }
                LabeledContent("Kind", value: SessionWords.kind(session.kind))
                LabeledContent("Status", value: SessionWords.status(session.status, theme: model.rowTheme))
                LabeledContent("Started", value: date(session.startedAt).formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
                if let last = p?.lastActivityAt {
                    LabeledContent("Last activity", value: last.formatted(.relative(presentation: .numeric)))
                }
                if let phase = p?.phase { LabeledContent("Phase", value: phase) }
                if let title = p?.title { LabeledContent("Title", value: title) }
                if let goal = p?.goal {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Goal").font(.caption).foregroundStyle(.secondary)
                        Text(goal)
                    }
                }
                if let tokens = p?.outputTokens, tokens > 0 {
                    LabeledContent("Output tokens", value: TokenFormat.compact(tokens)).monospacedDigit()
                }
                if p?.retrying == true {
                    Label("Retrying after an API error", systemImage: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
            }

            if let todos = p?.todos {
                Section("Todos") {
                    LabeledContent("Done", value: "\(todos.done)/\(todos.total)").monospacedDigit()
                    if let activeForm = todos.activeForm {
                        Text(activeForm).foregroundStyle(.secondary)
                    }
                }
            }

            accountSection

            Section {
                NavigationLink(value: CheckpointsRoute(session: session)) {
                    Label("Checkpoints", systemImage: "clock.arrow.2.circlepath")
                }
            } footer: {
                Text("The repository as it was at each prompt, with Restore.")
            }

            Section {
                Text(model.transportStatus.isEmpty ? model.rowTheme.loadingWord("searching") : model.transportStatus)
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            } footer: {
                // The process id is for the terminal, not the eye.
                Text("Process \(session.pid) on the Mac.").monospacedDigit()
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = String(session.pid)
                        } label: { Label("Copy process id", systemImage: "doc.on.doc") }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Session detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var accountSection: some View {
        if let summary {
            switch summary.kind {
            case .cswap, .unknownFleet:
                Section("Account") {
                    if let account = summary.account {
                        accountRow(account)
                        if summary.kind == .unknownFleet {
                            Text("Fleet's active account — this session's own fleet couldn't be identified.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("No active account on this fleet.").foregroundStyle(.secondary)
                    }
                }
            case .proxy:
                Section {
                    ForEach(summary.proxyAccounts, id: \.number) { accountRow($0) }
                } header: {
                    Text("Account — CLIProxyAPI")
                } footer: {
                    Text("The proxy routes each request to whichever credential is free "
                         + "(per-request routing) — \(summary.proxyAliveCount) of "
                         + "\(summary.proxyAccounts.count) are alive right now.")
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle()
                    .fill(ThemeColor.resolve(AccountHeadroom.colorName(forPct: AccountHeadroom.worstPct(account))))
                    .frame(width: 8, height: 8)
                Text(AccountSummaryFormat.accountShortName(account)).font(.subheadline.weight(.medium))
                if let plan = account.plan {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if account.active { Text("active").font(.caption2).foregroundStyle(.green) }
            }
            HStack(spacing: 10) {
                if let five = account.usage?.fiveHour {
                    Text("5h \(Int(five.pct))%").font(.caption).foregroundStyle(.secondary)
                }
                if let seven = account.usage?.sevenDay {
                    Text("7d \(Int(seven.pct))%").font(.caption).foregroundStyle(.secondary)
                }
                if let reset = ResetLabel.compact(account.usage?.fiveHour) {
                    Text("resets \(reset)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func date(_ epochMs: Double) -> Date {
        Date(timeIntervalSince1970: epochMs / 1000)
    }
}
