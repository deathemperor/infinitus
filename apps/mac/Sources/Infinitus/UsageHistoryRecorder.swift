import Foundation
import InfinitusCore

/// Feeds UsageHistory from the snapshot loop: appends new samples to the
/// per-machine JSONL in App Support. Off the main actor — it's all file IO.
actor UsageHistoryRecorder {
    static let retention: TimeInterval = 90 * 86400

    /// email -> engine poll instant last written (samples repeat between
    /// engine usage polls; only a fresh poll earns a line).
    private var appended: [String: Double] = [:]
    private var prunedThisLaunch = false
    private var seededWeeklyResetMemory = false

    /// Stable per-machine suffix, kept from when the file was mirrored
    /// to iCloud Drive beside other machines' copies: the existing history
    /// lives under it, so a rename would orphan a year of samples.
    static var machineID: String {
        let d = AppDefaults.standard
        if let id = d.string(forKey: "machine_id"), !id.isEmpty { return id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        d.set(id, forKey: "machine_id")
        return id
    }

    static var localURL: URL {
        AppSupport.root().appendingPathComponent("usage-history.\(machineID).jsonl")
    }

    func record(accounts: [Account]) {
        if !prunedThisLaunch {
            prunedThisLaunch = true
            try? UsageHistory.prune(url: Self.localURL,
                                    cutoff: Date().addingTimeInterval(-Self.retention))
        }
        // Issue #16: seed the ready-cell's weekly-reset memory from
        // what a prior launch already saw, once per launch.
        if !seededWeeklyResetMemory {
            seededWeeklyResetMemory = true
            WeeklyResetMemory.shared.seed(from: UsageHistory.load(url: Self.localURL))
        }
        for a in accounts {
            guard let iso = a.usage?.sevenDay?.resetsAt,
                  let date = UsageHistory.parseISO(iso) else { continue }
            WeeklyResetMemory.shared.note(email: a.email, resetsAt: date)
        }
        let fresh = UsageHistory.samples(accounts: accounts).filter {
            $0.t > (appended[$0.email] ?? 0)
        }
        guard !fresh.isEmpty else { return }
        do {
            try UsageHistory.append(fresh, to: Self.localURL)
            for s in fresh { appended[s.email] = s.t }
        } catch {
            // full disk etc. — history is best-effort, never fatal
        }
    }
}
