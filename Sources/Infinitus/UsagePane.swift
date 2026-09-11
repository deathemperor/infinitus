import SwiftUI
import Charts
import InfinitusCore
import InfinitusUI

/// Estimated spend dashboard (backlog item 4). The scan streams gigabytes
/// of transcripts (~seconds), so it runs on demand — first tab open and
/// the Refresh button — never on the snapshot timer.
@MainActor
final class UsageModel: ObservableObject {
    @Published var report: UsageReport?
    @Published var loading = false
    @Published var error: String?
    @Published var days = 7 { didSet { if days != oldValue { refresh() } } }

    private let cli: CswapCLI?
    /// True while `report` is last run's cached scan — the first
    /// loadIfNeeded still refreshes in the background.
    private var cacheOnly = false

    static let cacheURL: URL = {
        return AppSupport.root().appendingPathComponent("usage-cache.json")
    }()

    init(cli: CswapCLI?) {
        self.cli = cli
        // No engine to rescan with: say so instead of showing last run's
        // cached numbers as if they were live.
        guard cli != nil else {
            error = "The cswap engine is off — the spend estimate needs it."
            return
        }
        // Same instant-render treatment as the account snapshot: the
        // cash column otherwise pops in seconds after launch (user
        // 2026-08-30: "cache doesn't seem to have cash data").
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(UsageReport.self, from: data),
           cached.days == days {
            report = cached
            cacheOnly = true
        }
    }

    func loadIfNeeded() {
        if (report == nil || cacheOnly) && !loading { refresh() }
    }

    func refresh() {
        guard let cli, !loading else { return }
        loading = true
        error = nil
        let days = days
        Task {
            do {
                let (r, raw) = try await cli.usageReportRaw(days: days)
                if days == self.days {
                    try? FileManager.default.createDirectory(
                        at: Self.cacheURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? raw.write(to: Self.cacheURL, options: .atomic)
                }
                self.cacheOnly = false
                // Animated: the cash column's width change interpolates
                // (with the panel tracking it) instead of snapping the
                // popup wider in one frame (container-jump bug,
                // user 2026-08-30).
                withAnimation(.easeInOut(duration: 0.3)) { self.report = r }
            } catch {
                Lifecycle.log.error("usage scan failed: \(String(describing: error), privacy: .public)")
                self.error = "Couldn't scan the transcripts. Choose Refresh to try again."
            }
            self.loading = false
        }
    }
}

struct UsagePane: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Window", selection: $model.days) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { model.refresh() }
                    }
                }
                if let err = model.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .accessibilityLabel("Error. \(err)")
                }
            } footer: {
                Text("Choose how far back to look, then choose Refresh to rescan.")
            }
            .settingsAnchor("Usage/Window")
            if let report = model.report {
                if let daily = report.daily, daily.count > 1 {
                    Section("Daily estimated spend") {
                        Chart(dayPoints(report)) { point in
                            BarMark(
                                x: .value("Day", point.day),
                                y: .value("USD", point.usd)
                            )
                            .foregroundStyle(by: .value("Account", point.name))
                        }
                        .chartLegend(.visible)
                        .frame(height: 170)
                        .padding(.vertical, 4)
                    }
                }
                let models = modelPoints(report)
                if models.count > 1 {
                    Section("By model") {
                        Chart(models) { point in
                            BarMark(
                                x: .value("USD", point.usd),
                                y: .value("Model", point.name)
                            )
                            .foregroundStyle(Color.accentColor)
                        }
                        .frame(height: CGFloat(models.count) * 26 + 24)
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    ForEach(Array(report.accounts.enumerated()), id: \.offset) { _, row in
                        bucketRow(row)
                    }
                    if let extra = report.unattributed {
                        bucketRow(extra, fallbackName: "Before the switch log")
                    }
                    LabeledContent("Total") {
                        Text(usd(report.estimatedTotalUSD)).bold().monospacedDigit()
                    }
                } header: {
                    Text("Estimated spend, last \(report.days) days")
                } footer: {
                    // The caveats ARE the feature — they carry the price-table
                    // date and the not-a-bill warning. Always rendered.
                    Text(report.caveats.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .settingsAnchor("Usage/Estimate")
            } else if model.loading {
                Text("Scanning transcripts…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder private func bucketRow(
        _ row: UsageReport.UsageBucket, fallbackName: String = "?"
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let n = row.number {
                    Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text(row.alias ?? row.email ?? fallbackName).lineLimit(1)
                Spacer()
                Text(usd(row.estimatedUSD)).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text("\(row.messages) messages")
                Text("out \(TokenFormat.compact(row.output))")
                Text("cache \(TokenFormat.compact(row.cacheRead + row.cacheWrite))")
                if let top = row.models.first {
                    Text(top.model)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let day: String
        let name: String
        let usd: Double
    }

    /// Daily rows keyed to short day labels, one series per account. The
    /// account's display name comes from the report's own buckets so the
    /// chart legend matches the rows below it.
    private func dayPoints(_ report: UsageReport) -> [ChartPoint] {
        var names: [Int: String] = [:]
        for row in report.accounts {
            if let n = row.number {
                names[n] = row.alias
                    ?? row.email.map { String($0.prefix(while: { $0 != "@" })) }
                    ?? "#\(n)"
            }
        }
        return (report.daily ?? []).map { slice in
            let name = slice.account.map { names[$0] ?? "#\($0)" } ?? "Unattributed"
            return ChartPoint(
                id: "\(slice.date)/\(slice.account.map(String.init) ?? "-")",
                day: String(slice.date.suffix(5)),   // "MM-DD"
                name: name,
                usd: slice.estimatedUSD
            )
        }
    }

    private func modelPoints(_ report: UsageReport) -> [ChartPoint] {
        var byModel: [String: Double] = [:]
        var buckets = report.accounts
        if let extra = report.unattributed { buckets.append(extra) }
        for bucket in buckets {
            for slice in bucket.models {
                byModel[slice.model, default: 0] += slice.estimatedUSD
            }
        }
        return byModel.sorted { $0.value > $1.value }.map {
            ChartPoint(id: $0.key, day: "", name: $0.key, usd: $0.value)
        }
    }
}

/// The cash column in the shared fleet views (#9 phase B) reads the
/// cached report through this.
extension UsageModel: UsageSource {}

extension UsagePane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Usage", section: "Window", label: "Window",
                            keywords: ["7 days", "14 days", "30 days", "window"], anchor: "Usage/Window"),
        SettingsSearchEntry(pane: "Usage", section: "Estimate", label: "Estimated spend",
                            keywords: ["spend", "cost", "dollars", "estimate", "tokens"], anchor: "Usage/Estimate"),
    ]
}
