import SwiftUI
import InfinitusCore
import InfinitusUI

/// One teammate on the phone (spec §9): period picker, the same stat
/// tiles StatsScreen draws (via Stats.Presentation — the layout is
/// re-typed here, NOT extracted from StatsScreen, which another stream
/// owns), their session index, and a transcript list.
struct TeamMemberScreen: View {
    let model: MirrorModel
    let kid: String
    let name: String
    @State private var period: Stats.Period = .week
    @State private var reply: TeamMirror.MemberReply?
    @State private var error: String?

    /// The member's fleets ride the mirror snapshot (#221): no RPC.
    private var member: TeamSnapshot.Member? { model.team?.members.first { $0.kid == kid } }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = reply?.summary { Text("\(s.from) – \(s.to)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let since = member?.since { LabeledContent("Joined", value: relative(since)) }
            }
            if let s = reply?.summary, s.total != Stats.Day() {
                ForEach(Stats.Presentation.groups(s)) { group in
                    Section(group.id) {
                        ForEach(group.tiles) { tile in
                            LabeledContent(tile.id) {
                                HStack(spacing: 6) {
                                    Text(tile.value).monospacedDigit()
                                    if let delta = tile.delta { Text(delta).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                                }
                            }
                        }
                    }
                }
                effortSection("Where the effort went", Stats.Presentation.activityRows(s))
                effortSection("By model", Stats.Presentation.modelRows(s))
            } else if reply != nil {
                Section { Text("No stats shared for this period.").foregroundStyle(.secondary) }
            }
            if let fleet = member?.fleet { fleetSection(fleet) }
            if let r = reply, !r.sessions.isEmpty {
                let transcriptIds = Set(r.transcripts)
                Section("Sessions") {
                    ForEach(r.sessions, id: \.id) { row in
                        if transcriptIds.contains(row.id) {
                            NavigationLink { TeamTranscriptScreen(kid: kid, session: row) } label: { sessionRow(row) }
                        } else {
                            sessionRow(row)
                        }
                    }
                }
            }
            if let error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await load() }
        .overlay { if reply == nil && error == nil { ProgressView() } }
    }

    private func load() async {
        let want = period
        error = nil
        do {
            let r = try await NetworkFleetMirror.shared.teamMember(kid: kid, period: want)
            guard !Task.isCancelled, want == period else { return }
            reply = r
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: fleet (#221)

    /// Read-only: every account of every fleet as last published, in
    /// the theme's window colours. Static bars — nothing animates.
    private func fleetSection(_ doc: TeamDocs.FleetDoc) -> some View {
        Section {
            ForEach(Array(doc.fleets.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(f.engine).bold()
                        if let a = f.active { Text("· \(a)") }
                        if let n = f.next { Text("→ \(n)").foregroundStyle(.secondary) }
                        Spacer()
                        if let rate = f.tokensPerMinute {
                            Text("⚡ \(compact(rate))/min").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    if let at = f.lastSwitchAt {
                        Text("switched \(relative(at))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(f.accounts.enumerated()), id: \.offset) { _, a in accountRow(a) }
            }
        } header: {
            Text("Fleet")
        } footer: {
            Text("As of \(relative(doc.at)) · seen \(relative(member?.lastPublished))")
        }
    }

    private func accountRow(_ a: TeamDocs.FleetDoc.AccountRow) -> some View {
        let theme = model.rowTheme
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(a.label).fontWeight(a.active ? .bold : .regular)
                if let tier = a.tier { Text(tier).font(.caption).foregroundStyle(.secondary) }
                if a.status != TeamDocs.FleetDoc.ok {
                    Text(statusWord(a.status)).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(statusColor(a.status).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(a.status))
                }
                Spacer()
            }
            ForEach(Array(a.windows.enumerated()), id: \.offset) { _, w in
                HStack(spacing: 6) {
                    Text(w.label == "5h" ? theme.sessionLabel : theme.weeklyLabel)
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    GaugeBar(remaining: Double(max(0, 100 - w.pct)),
                             color: ThemeColor.resolve(w.label == "5h" ? theme.sessionColor : theme.weeklyColor),
                             animated: false)
                        .frame(height: 8)
                    Text("\(max(0, 100 - w.pct))%").font(.caption2).monospacedDigit()
                        .foregroundStyle(w.pct >= 100 ? Color.red : Color.primary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            if !a.models.isEmpty {
                Text(a.models.map { "\(theme.plain ? $0.label : theme.modelName($0.label)) \(max(0, 100 - $0.pct))%" }
                        .joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func statusWord(_ s: String) -> String {
        switch s {
        case TeamDocs.FleetDoc.limited: "limited"
        case TeamDocs.FleetDoc.dead: "dead"
        case TeamDocs.FleetDoc.expiredLogin: "re-login"
        case TeamDocs.FleetDoc.held: "held"
        default: s
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case TeamDocs.FleetDoc.dead: .red
        case TeamDocs.FleetDoc.limited, TeamDocs.FleetDoc.expiredLogin: .orange
        default: .secondary
        }
    }

    private func compact(_ n: Double) -> String {
        n >= 1000 ? String(format: "%.1fk", n / 1000) : String(Int(n.rounded()))
    }

    private func relative(_ at: Int?) -> String {
        guard let at else { return "never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
    }

    private func sessionRow(_ row: TeamDocs.SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name ?? row.project).bold()
            Text("\(row.project) · \(row.engine) · \(row.busyMinutes) min busy · \(row.usd, format: .currency(code: "USD").precision(.fractionLength(2)))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func effortSection(_ title: String, _ rows: [Stats.Presentation.Row]) -> some View {
        Section(title) {
            if rows.isEmpty { Text("Nothing yet this period").font(.caption).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                LabeledContent {
                    Text("\(r.usdText) · \(r.minutesText)").monospacedDigit()
                } label: {
                    Text(r.id)
                    Text("\(r.count) stretches · \(r.tokensText) tokens\(r.cachedSuffixText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A teammate's shared transcript: plain rows (kind + text). Not
/// SessionFeedScreen's chat rows — those belong to another stream's file.
struct TeamTranscriptScreen: View {
    let kid: String
    let session: TeamDocs.SessionRow
    @State private var items: [SessionFeedItem]?
    @State private var error: String?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to show", systemImage: "text.bubble",
                                           description: Text(error ?? "The transcript is empty or not readable by you."))
                } else {
                    List(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                            Text(item.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session.name ?? session.project)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { items = try await NetworkFleetMirror.shared.teamTranscript(kid: kid, session: session.id) }
            catch { self.error = error.localizedDescription; items = [] }
        }
    }
}
