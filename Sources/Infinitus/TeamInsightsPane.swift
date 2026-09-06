import SwiftUI
import InfinitusCore

/// Settings › Team, leaders (spec §8.3): the per-member comparison, the
/// leaderboard the leader picks, repo coverage, the blockers board, cost
/// and the team's hours — all folded from the reader `TeamModel.load()`
/// already built, and the aggregates push that lets members see the same
/// picture without reading each other's detail. Static: nothing here
/// animates or ticks.
struct TeamInsightsSection: View {
    @ObservedObject var team: TeamModel

    @State private var period: Stats.Period = .week
    @State private var metric: TeamInsights.Metric = .usd

    var body: some View {
        // A Group inside a Form hands each Section straight to the Form.
        Group {
            if let ins = team.insights(period: period) {
                comparison(ins)
                leaderboard(ins)
                repos(ins)
                blockers(ins)
                headroom(ins)
                cost(ins)
                hours(ins)
                picture
            }
        }
    }

    // MARK: comparison

    private func comparison(_ ins: TeamModel.Insights) -> some View {
        Section("Insights") {
            Picker("Period", selection: $period) {
                ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(ins.rows, id: \.kid) { r in
                HStack(spacing: 6) {
                    Circle().fill(r.online ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                    Text(r.name).bold()
                    Text(r.role).font(.caption).foregroundStyle(.secondary)
                    if let at = r.removedAt { Text(removedLabel(at)).font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    Text("\(teamUSD(r.summary.total.usd)) · \(r.summary.total.commits) commits · \(r.summary.total.humanMessages) messages · \(r.summary.total.sessionCount) sessions")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if ins.rows.isEmpty { Text("Nobody has published yet.").foregroundStyle(.secondary) }
            Text(ins.onNow.isEmpty ? "On now: nobody" : "On now: \(ins.onNow.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: leaderboard

    private func leaderboard(_ ins: TeamModel.Insights) -> some View {
        Section("Leaderboard") {
            Picker("Metric", selection: $metric) {
                ForEach(TeamInsights.Metric.allCases, id: \.self) { m in Text(m.title).tag(m) }
            }
            ForEach(TeamInsights.leaderboard(ins.rows, metric: metric), id: \.kid) { row in
                LabeledContent(row.name) {
                    Text(row.value.formatted(.number.precision(.fractionLength(metric == .usd ? 2 : 0))))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: repos

    private func repos(_ ins: TeamModel.Insights) -> some View {
        Section("Repos") {
            ForEach(ins.repos.prefix(12), id: \.project) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.project).lineLimit(1).truncationMode(.middle)
                    Text("\(teamUSD(r.usd)) · \(r.minutes) min · \(r.members.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if ins.repos.isEmpty { Text("No sessions in this period.").foregroundStyle(.secondary) }
        }
    }

    // MARK: blockers

    private func blockers(_ ins: TeamModel.Insights) -> some View {
        Section("Blockers") {
            // Two members can carry the same text ("2 crashes today"), so
            // the row identity is the position, not the line.
            ForEach(Array(ins.blockers.enumerated()), id: \.offset) { _, b in
                Text("⚠︎ \(b.name): \(b.text)").font(.caption).foregroundStyle(.orange)
            }
            if ins.blockers.isEmpty { Text("None").foregroundStyle(.secondary) }
        }
    }

    // MARK: headroom

    /// Who is about to run dry and who has accounts to spare (#221):
    /// every fresh member's fleets, nearest dry first. Shows only what a
    /// member shares — nothing here until a fleet is published.
    private func headroom(_ ins: TeamModel.Insights) -> some View {
        Section("Headroom") {
            ForEach(Array(ins.headroom.enumerated()), id: \.offset) { _, h in
                HStack(spacing: 6) {
                    Text(h.name).bold()
                    Text(h.engine).foregroundStyle(.secondary)
                    if let a = h.active { Text("· \(a)").foregroundStyle(.secondary) }
                    Spacer()
                    if let left = h.headroom {
                        Text("\(left)% left").monospacedDigit()
                            .foregroundStyle(left <= 10 ? Color.red : left <= 25 ? Color.orange : Color.primary)
                    } else {
                        Text("no windows").foregroundStyle(.secondary)
                    }
                    Text("· \(h.spare) spare").foregroundStyle(.secondary).monospacedDigit()
                    if h.dead > 0 { Text("· \(h.dead) dead").foregroundStyle(.red).monospacedDigit() }
                }
                .font(.caption)
            }
            if ins.headroom.isEmpty { Text("No fleets shared").foregroundStyle(.secondary) }
        }
    }

    // MARK: cost

    private func cost(_ ins: TeamModel.Insights) -> some View {
        Section("Cost") {
            LabeledContent("Total (est.)", value: teamUSD(ins.cost.total))
            ForEach(ins.cost.byMember, id: \.kid) { m in
                LabeledContent(m.name) { Text(teamUSD(m.usd)).font(.caption).monospacedDigit() }
            }
            ForEach(ins.cost.byModel.sorted { $0.value > $1.value }, id: \.key) { pair in
                LabeledContent(pair.key) { Text(teamUSD(pair.value)).font(.caption).monospacedDigit() }
            }
            ForEach(ins.cost.byRepo.sorted { $0.value > $1.value }.prefix(5), id: \.key) { pair in
                LabeledContent(pair.key) { Text(teamUSD(pair.value)).font(.caption).monospacedDigit() }
            }
            Text("Estimates from what teammates share, never billing truth.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: hours

    private func hours(_ ins: TeamModel.Insights) -> some View {
        // `TeamInsights.hours` is the 168-slot weekday × hour histogram;
        // the team's day shape is the seven weekdays summed per hour.
        let raw = ins.hours.count == 168 ? ins.hours : Array(repeating: 0, count: 168)
        let byHour = (0..<24).map { h in (0..<7).reduce(0) { $0 + raw[$1 * 24 + h] } }
        let peak = max(1, byHour.max() ?? 1)
        return Section("Hours") {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.15 + 0.85 * Double(byHour[h]) / Double(peak)))
                            .frame(width: 10, height: 18)
                            .help("\(h):00 — \(byHour[h]) entries")
                    }
                }
                HStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)h" : " ")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize().frame(width: 10, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: aggregates

    private var picture: some View {
        Section("Team picture") {
            LabeledContent("Published", value: teamRelative(team.reader?.aggregates[period.rawValue]?.at))
            Button("Publish now") { Task { await team.publishAggregatesNow() } }
            Text("Published hourly for the whole team: totals, repos and who's on — never a teammate's detail.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Team, members (spec §8.4): the leaders' aggregates for the
/// period, and what each teammate shares *to you*.
struct TeamMembersViewSection: View {
    @ObservedObject var team: TeamModel

    @State private var period: Stats.Period = .week

    var body: some View {
        Group {
            picture
            shared
        }
    }

    private var picture: some View {
        Section("Team picture") {
            Picker("Period", selection: $period) {
                ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let agg = team.reader?.aggregates[period.rawValue] {
                aggregates(agg)
            } else {
                Text("The leaders haven't published a team picture for this period.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func aggregates(_ agg: TeamDocs.Aggregates) -> some View {
        LabeledContent("Members", value: "\(agg.members)")
        LabeledContent("Spend (est.)", value: teamUSD(agg.total.usd))
        LabeledContent("Commits", value: "\(agg.total.commits)")
        LabeledContent("Messages", value: "\(agg.total.messages)")
        LabeledContent("Published", value: teamRelative(agg.at))
        Text(agg.onNow.isEmpty ? "On now: nobody" : "On now: \(agg.onNow.joined(separator: ", "))")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(agg.repos.prefix(5), id: \.project) { r in
            LabeledContent(r.project) {
                Text("\(teamUSD(r.usd)) · \(r.minutes) min").font(.caption).monospacedDigit()
            }
        }
        if let per = agg.perMember {
            ForEach(per, id: \.kid) { m in
                HStack(spacing: 6) {
                    Circle().fill(m.online ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                    Text(m.name)
                    Text(m.role).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(teamUSD(m.usd)) · \(m.commits) commits").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var shared: some View {
        let rows = team.sharedWithMe()
        return Section("Shared with you") {
            ForEach(rows, id: \.kid) { r in
                LabeledContent(r.name) {
                    Text(r.kinds.isEmpty ? "nothing readable yet" : r.kinds.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty { Text("Nobody shares with you directly yet.").foregroundStyle(.secondary) }
        }
    }
}

// MARK: helpers

/// `TeamPane.relative` stays private to that view; the two sections here
/// need the same wording without widening it.
fileprivate func teamRelative(_ at: Int?) -> String {
    guard let at else { return "never" }
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
    return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
}

/// "removed 3 wk. ago", the panes' own relative style.
fileprivate func removedLabel(_ at: Int) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
    return "removed " + f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
}

fileprivate func teamUSD(_ usd: Double) -> String {
    usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
}
