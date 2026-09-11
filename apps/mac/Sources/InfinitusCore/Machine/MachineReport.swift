import Foundation

/// One look at the machine (#115): the sample, the hooks with their live
/// instances, the runaways, the residue counts, the sessions, and the
/// warnings the guardian would push. `infinitusctl machine --json`
/// prints it; the Machine tab renders it.
public struct MachineReport: Equatable, Sendable, Codable {
    public struct Hook: Equatable, Sendable, Codable, Identifiable {
        public let registration: HookRegistration
        public let spawnsPerHour: Double
        public let live: HookInventory.Live
        public var id: String { registration.id }
        public init(registration: HookRegistration, spawnsPerHour: Double, live: HookInventory.Live) {
            self.registration = registration; self.spawnsPerHour = spawnsPerHour; self.live = live
        }
        public var risky: Bool { registration.heavy && spawnsPerHour >= 100 }
        public var stuck: Bool { live.instances >= 50 || live.oldestSeconds >= 600 || live.uninterruptible > 0 }
    }
    public struct ResidueCounts: Equatable, Sendable, Codable {
        public var staleSockets = 0
        public var staleSessionEnvs = 0
        public var tempEntries: Int?
        public var tempByOwner: [String: Int]?
        public var transcriptsBytes = 0
        public var pluginCacheBytes = 0
        public var memBytes = 0
        public init() {}
    }

    public var sample: MachineSample
    public var hooks: [Hook]
    public var runaways: [Runaways.Runaway]
    public var residue: ResidueCounts
    public var sessions: [SessionHealth]
    public var warnings: [String]

    public init(sample: MachineSample, hooks: [Hook], runaways: [Runaways.Runaway],
                residue: ResidueCounts, sessions: [SessionHealth], warnings: [String]) {
        self.sample = sample; self.hooks = hooks; self.runaways = runaways
        self.residue = residue; self.sessions = sessions; self.warnings = warnings
    }

    /// The warnings a sample earns, in the order the tab lists them.
    /// New temp entries per hour that read as a bootstrap retrying: one
    /// failed `pip install` leaves ~4 dirs, so 20/h is five attempts.
    public static let retryLoopPerHour = 20.0

    /// - tempGrowthPerHour: new temp entries per hour by owner since the
    ///   previous listing (#115 item 6 — a hook whose install keeps dying
    ///   leaves a pile that grows every session start).
    /// - pipSpawner: the hook owner whose process tree holds a running
    ///   pip, when one is known.
    /// - pipTarget: where the last pip seen was installing (`pipInstallTarget`)
    ///   — the venv names the culprit when the pip was spawned detached
    ///   and no hook tree holds it (security-guidance's SDK bootstrap,
    ///   2026-09-06: "a hook" told the user nothing).
    public static func warnings(sample: MachineSample, hooks: [Hook], newcomers: [HookRegistration],
                                tempGrowthPerHour: [String: Double] = [:], pipSpawner: String? = nil,
                                pipTarget: String? = nil) -> [String] {
        var out: [String] = []
        for hook in newcomers {
            out.append("new hook: \(hook.owner) on \(hook.event) (\(hook.source.label))")
        }
        // One script registered on several events reports the same live
        // instances under each registration: one warning per owner.
        var seenOwners = Set<String>()
        let stuck = hooks.filter(\.stuck).sorted(by: { $0.live.instances > $1.live.instances })
            .filter { seenOwners.insert($0.registration.owner).inserted }
        for hook in stuck.prefix(3) {
            out.append("\(hook.registration.owner) has \(hook.live.instances) instances (oldest \(hook.live.oldestSeconds / 60) min, \(hook.live.uninterruptible) stuck)")
        }
        if sample.swapPct >= 90 { out.append("swap \(Int(sample.swapPct))% full") }
        if sample.uninterruptible >= 50 { out.append("\(sample.uninterruptible) processes in uninterruptible wait") }
        if sample.tempEntries == nil, sample.tempListSeconds > 0 { out.append("temp directory listing timed out") }
        else if let n = sample.tempEntries, n >= 10_000 { out.append("temp directory holds \(n) entries" + tempBreakdown(sample.tempByOwner)) }
        out += fanOut(hooks)
        let pipGrowth = (tempGrowthPerHour["pip"] ?? 0) + (tempGrowthPerHour["python"] ?? 0)
        if pipGrowth >= retryLoopPerHour {
            let who = pipSpawner.map { "\($0)'s hook" } ?? pipTarget.map { "a hook installing into \($0)" } ?? "a hook"
            out.append("\(who) keeps re-running pip install — \(Int(pipGrowth)) new temp dirs per hour; its installs die and get retried")
        }
        return out
    }

    /// New entries per hour by owner between two listings.
    public static func tempGrowthPerHour(previous: [String: Int]?, previousAt: Date?, current: [String: Int]?, now: Date) -> [String: Double] {
        guard let previous, let previousAt, let current else { return [:] }
        let hours = now.timeIntervalSince(previousAt) / 3600
        guard hours > 0 else { return [:] }
        var out: [String: Double] = [:]
        for (owner, n) in current {
            let delta = n - (previous[owner] ?? 0)
            if delta > 0 { out[owner] = Double(delta) / hours }
        }
        return out
    }

    /// Which mute a pushed warning answers to (Settings › Machine: the
    /// hook and temp-directory notifications can be silenced separately;
    /// the pane keeps showing every warning).
    public enum WarningKind: Equatable, Sendable { case hooks, temp, other }
    public static func warningKind(_ warning: String) -> WarningKind {
        if warning.hasPrefix("new hook:") || warning.contains(" instances (") || warning.contains(" commands on every ")
            || warning.contains("keeps re-running pip install") { return .hooks }
        if warning.hasPrefix("temp directory") { return .temp }
        return .other
    }

    /// " (pip 9600, python 12814, other 1500)" — owners with a share worth naming.
    public static func tempBreakdown(_ by: [String: Int]?) -> String {
        guard let by else { return "" }
        let parts = by.filter { $0.value >= 100 }.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// Where a running pip is installing: `--target <dir>`, else the venv
    /// its interpreter lives in (`<venv>/bin/python -m pip install …`);
    /// `home` is abbreviated to `~`. Nil when no row runs a pip install.
    public static func pipInstallTarget(rows: [ProcessRow], home: String = NSHomeDirectory()) -> String? {
        for row in rows where row.command.contains("pip install") {
            let words = row.command.split(separator: " ").map(String.init)
            var target: String?
            if let i = words.firstIndex(of: "--target"), i + 1 < words.count { target = words[i + 1] }
            else if let first = words.first, let range = first.range(of: "/bin/python") { target = String(first[..<range.lowerBound]) }
            guard let target, !target.isEmpty else { continue }
            return target.hasPrefix(home + "/") ? "~" + target.dropFirst(home.count) : target
        }
        return nil
    }

    /// One owner registering several commands under the same event and
    /// matcher spawns all of them on every matching call — Claude Code
    /// evaluates each command's own guard only after spawning it (#115
    /// item 8: five `if: Bash(git …)` entries = five bash+python per
    /// Bash call). Reported as effective spawns per event.
    static func fanOut(_ hooks: [Hook]) -> [String] {
        var counts: [String: (owner: String, event: String, matcher: String, n: Int)] = [:]
        for hook in hooks {
            let r = hook.registration
            let key = "\(r.owner)|\(r.event)|\(r.matcher ?? "")"
            counts[key, default: (r.owner, r.event, r.matcher ?? "", 0)].n += 1
        }
        return counts.values.filter { $0.n >= 3 }.sorted { $0.n > $1.n }.prefix(3).map {
            "\($0.owner) runs \($0.n) commands on every \($0.event)\($0.matcher.isEmpty ? "" : " \($0.matcher)") call"
        }
    }
}
