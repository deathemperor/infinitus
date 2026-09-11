import Foundation

/// Processes a session spawned that outlived their purpose (#115):
/// a native `tsc` that ignored SIGTERM, a `bun test` at 134 GB, a
/// whole-disk `find`, three release builds at once. Rules by class,
/// attribution by ancestry to a Claude session pid, and a confirmed
/// process-group kill — never automatic.
public enum Runaways {
    public struct Rule: Sendable {
        public let name: String
        public let matches: @Sendable (String) -> Bool
        public let maxRSSMB: Int?
        public let maxSeconds: Int?
        /// More than this many at once trips the rule for each of them.
        public let maxConcurrent: Int?
        public init(name: String, maxRSSMB: Int? = nil, maxSeconds: Int? = nil, maxConcurrent: Int? = nil,
                    matches: @escaping @Sendable (String) -> Bool) {
            self.name = name; self.maxRSSMB = maxRSSMB; self.maxSeconds = maxSeconds
            self.maxConcurrent = maxConcurrent; self.matches = matches
        }
    }

    public static let rules: [Rule] = [
        Rule(name: "tsc", maxSeconds: 30 * 60) { $0.contains("/tsc") || $0.hasPrefix("tsc ") || $0.contains("typescript/lib/tsc") },
        Rule(name: "bun test", maxRSSMB: 8 * 1024, maxSeconds: 30 * 60) { $0.contains("bun test") },
        Rule(name: "find /", maxSeconds: 5 * 60) { $0.hasPrefix("find / ") || $0.hasPrefix("find /Users ") || $0.hasPrefix("find /System") },
        Rule(name: "swift/xcodebuild", maxConcurrent: 2) { $0.contains("swift-build") || $0.contains("xcodebuild ") || $0.hasPrefix("swift build") || $0.hasPrefix("swift test") },
        Rule(name: "any process", maxRSSMB: 16 * 1024) { _ in true },
    ]

    public struct Runaway: Equatable, Sendable, Codable, Identifiable {
        public let pid: Int
        public let command: String
        public let rule: String
        public let why: String
        public let rssMB: Int
        public let elapsedSeconds: Int
        /// The Claude session this descends from, when one does.
        public let sessionPid: Int?
        public var id: Int { pid }
    }

    /// Owner session of each pid: the nearest ancestor that is a session.
    public static func attribution(rows: [ProcessRow], sessionPids: Set<Int>) -> [Int: Int] {
        let parent = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.ppid) })
        var out: [Int: Int] = [:]
        for row in rows {
            var pid = row.pid
            var hops = 0
            while hops < 32, let p = parent[pid], p > 1 {
                if sessionPids.contains(p) { out[row.pid] = p; break }
                pid = p; hops += 1
            }
        }
        return out
    }

    /// The rows breaking a rule. Only session descendants are judged —
    /// the rest of the Mac is not this guardian's business — except
    /// the "any process" RSS ceiling, which names anything.
    public static func flagged(rows: [ProcessRow], sessionPids: Set<Int>, rules: [Rule] = rules) -> [Runaway] {
        let owner = attribution(rows: rows, sessionPids: sessionPids)
        var out: [Runaway] = []
        var seen = Set<Int>()
        for rule in rules {
            let matching = rows.filter { rule.matches($0.command) && (owner[$0.pid] != nil || rule.maxConcurrent == nil && rule.maxRSSMB != nil && rule.maxSeconds == nil) }
            let tooMany = rule.maxConcurrent.map { matching.count > $0 } ?? false
            for row in matching where !seen.contains(row.pid) {
                var why: String?
                if let cap = rule.maxRSSMB, row.rssMB > cap { why = "\(row.rssMB / 1024) GB resident, cap \(cap / 1024) GB" }
                else if let cap = rule.maxSeconds, row.elapsedSeconds > cap { why = "\(row.elapsedSeconds / 60) min running, cap \(cap / 60) min" }
                else if tooMany { why = "\(matching.count) at once, cap \(rule.maxConcurrent ?? 0)" }
                guard let why else { continue }
                seen.insert(row.pid)
                out.append(Runaway(pid: row.pid, command: String(row.command.prefix(200)), rule: rule.name, why: why,
                                   rssMB: row.rssMB, elapsedSeconds: row.elapsedSeconds, sessionPid: owner[row.pid]))
            }
        }
        return out.sorted { $0.rssMB > $1.rssMB }
    }

    #if canImport(Darwin) && !os(iOS)
    /// SIGTERM to the process group, SIGKILL to whatever is left after
    /// `grace`. Returns whether the pid is gone at the end. The group is
    /// only signalled when it is the runaway's own: a tool child usually
    /// shares its Claude session's group (and the app's, when launched
    /// from a shell), and `protectedGroups` keeps those to a single-pid
    /// signal. pid 0/-1 would address our own group or every process.
    public static func kill(pid: Int, protectedGroups: Set<Int> = [], grace: TimeInterval = 3,
                            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        guard pid > 1 else { return false }
        let pgid = getpgid(pid_t(pid))
        let own = Set([Int(getpgid(getpid()))]).union(protectedGroups)
        let target: pid_t = pgid > 1 && !own.contains(Int(pgid)) ? -pgid : pid_t(pid)
        _ = Darwin.kill(target, SIGTERM)
        sleep(grace)
        if Darwin.kill(pid_t(pid), 0) == 0 {
            _ = Darwin.kill(target, SIGKILL)
            sleep(0.2)
        }
        return Darwin.kill(pid_t(pid), 0) != 0
    }

    /// SIGTERM to each pid (never a group), SIGKILL to the survivors
    /// after `grace`. Returns how many are gone. A pid in `never`
    /// (the sessions themselves) is not signalled.
    public static func killAll(pids: [Int], never: Set<Int>, grace: TimeInterval = 3,
                               sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Int {
        let targets = pids.filter { $0 > 1 && !never.contains($0) }
        for pid in targets { _ = Darwin.kill(pid_t(pid), SIGTERM) }
        sleep(grace)
        for pid in targets where Darwin.kill(pid_t(pid), 0) == 0 { _ = Darwin.kill(pid_t(pid), SIGKILL) }
        sleep(0.2)
        return targets.filter { Darwin.kill(pid_t($0), 0) != 0 }.count
    }
    #endif
}
