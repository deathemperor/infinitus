import SwiftUI
import InfinitusCore
import InfinitusUI

/// One teammate (spec §8.2, §9): period picker, the Stats tiles over
/// what they shared, their session index, and a transcript sheet.
struct TeamMemberPane: View {
    @ObservedObject var team: TeamModel
    let kid: String
    @State private var period: Stats.Period = .week
    @State private var openSession: TeamDocs.SessionRow?
    @State private var items: [SessionFeedItem]?

    private var member: TeamReader.Member? { team.reader?.members[kid] }
    private var summary: Stats.Summary? { team.reader?.summary(kid: kid, period: period) }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = summary {
                    Text("\(s.from) – \(s.to)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let since = team.snapshot?.members.first(where: { $0.kid == kid })?.since {
                    LabeledContent("Joined", value: Self.relative(since))
                }
            }
            if let s = summary, s.total != Stats.Day() {
                StatsTiles(summary: s)
            } else {
                Section { Text("No stats shared for this period.").foregroundStyle(.secondary) }
            }
            if let m = member, let fleet = m.fleet {
                fleetSection(fleet, lastPublished: m.lastPublished)
            }
            let drivable = team.drivableSessions(of: kid)
            if !drivable.isEmpty {
                driveSection(drivable)
            }
            if let m = member, !m.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(m.sessions, id: \.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name ?? row.project).bold()
                                Text("\(row.project) · \(row.engine) · \(row.busyMinutes) min busy · \(row.usd, format: .currency(code: "USD").precision(.fractionLength(2)))")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            if m.transcripts[row.id] != nil {
                                Button("Transcript") {
                                    items = nil
                                    openSession = row
                                    team.clearError()
                                    Task {
                                        let r = await team.transcript(kid: kid, session: row.id)
                                        if openSession?.id == row.id { items = r }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(member?.name ?? kid)
        .sheet(item: $openSession) { row in
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(row.name ?? row.project).font(.headline); Spacer(); Button("Close") { openSession = nil; items = nil } }.padding()
                if let items {
                    if items.isEmpty {
                        Spacer(); Text(team.lastError ?? "Nothing to show").foregroundStyle(team.lastError == nil ? Color.secondary : Color.orange); Spacer()
                    } else {
                        List(Array(items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Text(item.text).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
    }

    // MARK: drive (#220 §7.2)

    /// The sessions they let me drive, each opening the remote chat window.
    private func driveSection(_ sessions: [TeamDocs.LiveSession]) -> some View {
        Section {
            ForEach(sessions, id: \.id) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name ?? s.project).bold()
                        Text("\(s.project) · \(s.status)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Drive…") { TeamSessionChatWindows.shared.open(kid: kid, session: s, team: team) }
                }
            }
        } header: { Text("Drive") } footer: {
            Text("They let you \(team.controls(grantedBy: kid).sorted().joined(separator: ", ")). Commands go over LAN, a tunnel, or the store on their next fetch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: fleet (#221)

    /// The member's fleets as last published, read-only: every account
    /// with its tier, state and windows. Static bars — nothing animates.
    private func fleetSection(_ doc: TeamDocs.FleetDoc, lastPublished: Int?) -> some View {
        Section {
            ForEach(Array(doc.fleets.enumerated()), id: \.offset) { _, fleet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(fleet.engine).bold()
                        if let a = fleet.active { Text("· \(a)") }
                        if let n = fleet.next { Text("→ \(n)").foregroundStyle(.secondary) }
                        Spacer()
                        if let rate = fleet.tokensPerMinute {
                            Text("⚡ \(Self.compact(rate))/min").monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let at = fleet.lastSwitchAt {
                            Text("switched \(Self.relative(at))").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    ForEach(Array(fleet.accounts.enumerated()), id: \.offset) { _, a in accountRow(a) }
                }
            }
        } header: {
            Text("Fleet")
        } footer: {
            Text("As of \(Self.relative(doc.at)) · seen \(Self.relative(lastPublished))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountRow(_ a: TeamDocs.FleetDoc.AccountRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(a.label).fontWeight(a.active ? .bold : .regular)
                    if let tier = a.tier { Text(tier).foregroundStyle(.secondary) }
                    if a.status != TeamDocs.FleetDoc.ok {
                        Text(Self.statusWord(a.status))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Self.statusColor(a.status).opacity(0.15), in: Capsule())
                            .foregroundStyle(Self.statusColor(a.status))
                    }
                }
                .font(.caption)
                if !a.models.isEmpty {
                    Text(a.models.map { "\($0.label) \(100 - $0.pct)%" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 180, alignment: .leading)
            ForEach(Array(a.windows.enumerated()), id: \.offset) { _, w in
                HStack(spacing: 4) {
                    Text(w.label).font(.caption2).foregroundStyle(.secondary)
                    GaugeBar(remaining: Double(max(0, 100 - w.pct)), color: w.label == "5h" ? .blue : .purple,
                             animated: false)
                        .frame(width: 90, height: 8)
                    Text("\(max(0, 100 - w.pct))%").font(.caption2).monospacedDigit()
                        .foregroundStyle(w.pct >= 100 ? Color.red : Color.primary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func statusWord(_ s: String) -> String {
        switch s {
        case TeamDocs.FleetDoc.limited: "limited"
        case TeamDocs.FleetDoc.dead: "dead"
        case TeamDocs.FleetDoc.expiredLogin: "re-login"
        case TeamDocs.FleetDoc.held: "held"
        default: s
        }
    }

    private static func statusColor(_ s: String) -> Color {
        switch s {
        case TeamDocs.FleetDoc.dead: .red
        case TeamDocs.FleetDoc.limited, TeamDocs.FleetDoc.expiredLogin: .orange
        default: .secondary
        }
    }

    private static func compact(_ n: Double) -> String {
        n >= 1000 ? String(format: "%.1fk", n / 1000) : String(Int(n.rounded()))
    }

    private static func relative(_ at: Int?) -> String {
        guard let at else { return "never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
    }
}

/// `.sheet(item:)` needs an `Identifiable` row; `SessionRow.id` is the session id.
extension TeamDocs.SessionRow: Identifiable {}
