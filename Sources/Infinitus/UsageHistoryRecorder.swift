import Foundation
import InfinitusCore

/// Feeds UsageHistory from the snapshot loop: appends new samples to the
/// per-machine JSONL in App Support and, when iCloud settings sync is on,
/// mirrors that file into the same iCloud Drive folder the settings
/// snapshot uses. Off the main actor — it's all file IO.
actor UsageHistoryRecorder {
    static let retention: TimeInterval = 90 * 86400
    private let mirrorInterval: TimeInterval = 300

    /// email -> engine poll instant last written (samples repeat between
    /// engine usage polls; only a fresh poll earns a line).
    private var appended: [String: Double] = [:]
    private var lastMirror: Date = .distantPast
    private var prunedThisLaunch = false
    private var seededWeeklyResetMemory = false

    /// Stable per-machine suffix so machines never write each other's
    /// files (merge happens at read time instead).
    static var machineID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "machine_id"), !id.isEmpty { return id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        d.set(id, forKey: "machine_id")
        return id
    }

    static var localURL: URL {
        AppSupport.root().appendingPathComponent("usage-history.\(machineID).jsonl")
    }

    static func iCloudURL() -> URL? {
        SettingsSyncModel.containerDir()?
            .appendingPathComponent("usage-history.\(machineID).jsonl")
    }

    /// Every history file visible to this machine: its own plus any
    /// machine's mirror in iCloud Drive. The dashboard reads through this.
    static func readableURLs() -> [URL] {
        var urls = [localURL]
        if let dir = SettingsSyncModel.containerDir(),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names.sorted()
            where n.hasPrefix("usage-history.") && n.hasSuffix(".jsonl")
                && n != localURL.lastPathComponent {
                urls.append(dir.appendingPathComponent(n))
            }
        }
        return urls
    }

    func record(accounts: [Account], syncEnabled: Bool) {
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
            return   // full disk etc. — history is best-effort, never fatal
        }
        guard syncEnabled, Date().timeIntervalSince(lastMirror) > mirrorInterval,
              let dest = Self.iCloudURL() else { return }
        lastMirror = Date()
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(dest.lastPathComponent + ".tmp")
        try? fm.removeItem(at: tmp)
        if (try? fm.copyItem(at: Self.localURL, to: tmp)) != nil {
            _ = try? fm.replaceItemAt(dest, withItemAt: tmp)
        }
    }
}
