import Foundation
import InfinitusCore

public enum WinUsageHistoryRecorder {
    public static let retention: TimeInterval = 90 * 86_400

    private static let lock = NSLock()
    private nonisolated(unsafe) static var appended: [String: Double] = [:]
    private nonisolated(unsafe) static var prunedThisLaunch = false
    private nonisolated(unsafe) static var seededWeeklyResetMemory = false

    public static func machineID() -> String {
        let current = WinSettingsStore.load().machineID
        if !current.isEmpty { return current }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        _ = try? WinSettingsStore.update { $0.machineID = id }
        return id
    }

    public static var url: URL {
        localURL(machineID: machineID())
    }

    public static func localURL(machineID: String) -> URL {
        WinSettingsStore.infinitusHome
            .appendingPathComponent("usage-history.\(machineID).jsonl")
    }

    public static func readableURLs() -> [URL] {
        let base = WinSettingsStore.infinitusHome
        let myURL = url
        var urls = [myURL]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for n in names.sorted()
            where n.hasPrefix("usage-history.") && n.hasSuffix(".jsonl")
                && n != myURL.lastPathComponent {
                urls.append(base.appendingPathComponent(n))
            }
        }
        return urls
    }

    public static func record(accounts: [Account], to fileURL: URL = url) {
        lock.lock()
        defer { lock.unlock() }

        if !prunedThisLaunch {
            prunedThisLaunch = true
            try? UsageHistory.prune(url: fileURL, cutoff: Date().addingTimeInterval(-retention))
        }

        if !seededWeeklyResetMemory {
            seededWeeklyResetMemory = true
            WeeklyResetMemory.shared.seed(from: UsageHistory.load(url: fileURL))
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
            try UsageHistory.append(fresh, to: fileURL)
            for s in fresh {
                appended[s.email] = s.t
            }
        } catch {
            return
        }
    }

    /// Reset internal state (for testing).
    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        appended.removeAll()
        prunedThisLaunch = false
        seededWeeklyResetMemory = false
    }
}
