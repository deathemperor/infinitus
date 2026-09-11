import Foundation
import InfinitusCore

/// Linux-side utilization history (todo 2026-09-01, same shape as the
/// macOS recorder): each Waybar status poll appends fresh samples to
/// `$XDG_STATE_HOME/infinitus/usage-history.<machineID>.jsonl`. The tray
/// is a per-invocation process, so the "last poll written" map lives in
/// a sidecar file instead of memory.
enum TrayHistory {
    static var dir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? NSHomeDirectory() + "/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("infinitus")
    }

    static func machineID() -> String {
        let url = dir.appendingPathComponent("machine-id")
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    static func record(accounts: [Account], enginePath: String) {
        // The demo engine's fabricated fleet must not pollute history
        // (same rule as the macOS playground gate).
        guard !enginePath.hasSuffix("demo-swapd") else { return }
        let histURL = dir.appendingPathComponent(
            "usage-history.\(machineID()).jsonl")
        let stateURL = dir.appendingPathComponent("usage-history.last.json")
        var last = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }
            ?? [:]
        let fresh = UsageHistory.samples(accounts: accounts).filter {
            $0.t > (last[$0.email] ?? 0)
        }
        guard !fresh.isEmpty else { return }
        guard (try? UsageHistory.append(fresh, to: histURL)) != nil else { return }
        for s in fresh { last[s.email] = s.t }
        if let d = try? JSONEncoder().encode(last) { try? d.write(to: stateURL) }
        // Retention sweep at most daily, marker-file clocked.
        let marker = dir.appendingPathComponent("usage-history.pruned")
        let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path)
        let age = attrs?[.modificationDate] as? Date
        if age.map({ Date().timeIntervalSince($0) > 86400 }) ?? true {
            try? UsageHistory.prune(
                url: histURL, cutoff: Date().addingTimeInterval(-90 * 86400))
            try? Data().write(to: marker)
        }
    }
}
