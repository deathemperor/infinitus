import Foundation
import InfinitusCore

/// Utilization over time (todo 2026-09-01): the recorded 5h/7d/per-model
/// percentages for the whole fleet or one account, plus waste — the
/// headroom that expired unused at each weekly reset — and the token run
/// rate. Reads the merged local + iCloud history; loading is file IO, so
/// it runs off-main on demand. The pane that charted it left with #654;
/// `infinitusctl utilization --days N` (#747) hands the same figures to
/// the desktop app, which renders them now.
@MainActor
final class UtilizationModel: ObservableObject {
    @Published var samples: [UsageSample] = []
    @Published var generations: [WindowGeneration] = []
    @Published var fiveHourWindows: [FiveHourWindow] = []
    /// #7 layer 2: what the fleet did over the range, and the plan the
    /// planner would propose off the latest samples if a sprint were
    /// running — a dry run for eyeballing, nothing executes.
    @Published var replay: WindowPlanner.ReplayReport?
    @Published var dryRunPlan: WindowPlanner.Plan?
    /// Token/$ run rate from the transcripts (2026-09-03); its own task
    /// because the first pass over a week of transcripts takes a while.
    @Published var rates: TokenRates?
    @Published var ratesScanning = false
    @Published var loading = false
    @Published var rangeDays = 7 { didSet { if rangeDays != oldValue { refresh() } } }
    /// "7d", "5h", or a scoped model name.
    @Published var window = "7d"
    /// nil = every account overlaid.
    @Published var account: String?

    /// Window choices actually present in the data, stable order.
    var windows: [String] { Self.windowNames(samples) }

    var emails: [String] { Self.emails(samples) }

    func loadIfNeeded() { if samples.isEmpty && !loading { refresh() } }

    func refresh() {
        guard !loading else { return }
        loading = true
        let days = rangeDays
        Task.detached(priority: .utility) {
            let snap = Self.compute(days: days, now: Date().timeIntervalSince1970)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.samples = snap.samples
                self.generations = snap.generations
                self.fiveHourWindows = snap.fiveHourWindows
                self.replay = snap.replay
                self.dryRunPlan = snap.dryRunPlan
                self.loading = false
            }
        }
        refreshRates()
    }

    /// What the pane charts, as one value: the `utilization` verb (#747)
    /// answers with the same computation so the desktop app renders the
    /// app's figures instead of redoing them.
    struct Snapshot: Encodable, Sendable {
        let days: Int
        let bucketSeconds: Double
        let samples: [UsageSample]
        let generations: [WindowGeneration]
        let fiveHourWindows: [FiveHourWindow]
        let replay: WindowPlanner.ReplayReport
        let dryRunPlan: WindowPlanner.Plan?
        let windows: [String]
        let emails: [String]
        var rates: TokenRates?
        /// The popup's 5-minute output rate, from the relay (main actor).
        var liveRate: TokenRate?
    }

    nonisolated static func compute(days: Int, now: Double) -> Snapshot {
        let urls = UsageHistoryRecorder.readableURLs()
        let merged = UsageHistory.merge(urls.map { UsageHistory.load(url: $0) })
        // Waste generations and 5h windows need the FULL history (a
        // reset may predate the chart range); the chart gets the
        // trimmed, thinned slice.
        let gens = WasteMath.generations(merged)
        let windows = WindowTelemetry.fiveHourWindows(merged, now: now)
        let cutoff = now - Double(days) * 86400
        let bucket: TimeInterval = days <= 1 ? 300 : days <= 7 ? 1800 : 7200
        let thin = UsageHistory.downsample(merged.filter { $0.t >= cutoff }, bucket: bucket)
        let replay = WindowPlanner.replay(merged, from: cutoff, to: now)
        let plan = Self.dryRunPlan(merged, now: now)
        return Snapshot(days: days, bucketSeconds: bucket, samples: thin, generations: gens,
                        fiveHourWindows: windows, replay: replay, dryRunPlan: plan,
                        windows: windowNames(thin), emails: emails(thin))
    }

    nonisolated static func windowNames(_ samples: [UsageSample]) -> [String] {
        var names: [String] = ["5h", "7d"]
        var seen = Set<String>()
        for s in samples {
            for name in (s.scoped ?? [:]).keys where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    nonisolated static func emails(_ samples: [UsageSample]) -> [String] {
        var seen = Set<String>()
        return samples.compactMap { seen.insert($0.email).inserted ? $0.email : nil }
    }

    nonisolated static let ratesCacheURL: URL = {
        AppSupport.root().appendingPathComponent("token-rates-cache.json")
    }()

    func refreshRates() {
        guard !ratesScanning else { return }
        ratesScanning = true
        Task.detached(priority: .utility) {
            let rates = TokenRateScanner.scan(projectsDir: TokenRateScanner.defaultProjectsDir(),
                                              cacheURL: Self.ratesCacheURL)
            await MainActor.run { [weak self] in
                self?.rates = rates
                self?.ratesScanning = false
            }
        }
    }
}

extension UtilizationModel {
    /// The planner over each account's latest sample (within the last
    /// hour, so a stale file doesn't fake a fleet), assuming one busy
    /// session. Disabled accounts aren't in the history; the live card
    /// (next layer) gets the real snapshot.
    nonisolated static func dryRunPlan(_ samples: [UsageSample], now: Double) -> WindowPlanner.Plan? {
        var latest: [String: UsageSample] = [:]
        for s in samples where s.t >= now - 3600 {
            if let cur = latest[s.email], cur.t >= s.t { continue }
            latest[s.email] = s
        }
        let states = latest.values.map { s in
            let weekly = ([s.sevenDay?.pct] + (s.scoped ?? [:]).values.map { $0.pct })
                .compactMap { $0 }.max() ?? 0
            return WindowPlanner.AccountState(
                number: s.number, email: s.email, active: s.active == true,
                fiveHourPct: s.fiveHour?.pct, fiveHourResetsAt: s.fiveHour?.resetsAt,
                weeklyPct: weekly)
        }
        guard let active = states.first(where: { $0.active }) else { return nil }
        let rate = WindowTelemetry.burnRate(samples, email: active.email, now: now)
        return WindowPlanner.plan(accounts: states, burnPctPerHour: rate,
                                  busySessions: 1, now: now)
    }

}
