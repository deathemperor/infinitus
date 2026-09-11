import Foundation

/// The machine-health guardian (#115): what many concurrent Claude
/// sessions do to a Mac, measured cheaply. One `ps` and three `sysctl`s
/// per sample; nothing here lists a directory without a deadline.
public struct ProcessRow: Equatable, Sendable, Codable {
    public let pid: Int
    public let ppid: Int
    /// `ps` STAT — first letter R running, S sleeping, U uninterruptible, Z zombie.
    public let stat: String
    public let rssKB: Int
    public let elapsedSeconds: Int
    public let cpu: Double
    public let command: String

    public init(pid: Int, ppid: Int, stat: String, rssKB: Int, elapsedSeconds: Int, cpu: Double, command: String) {
        self.pid = pid; self.ppid = ppid; self.stat = stat; self.rssKB = rssKB
        self.elapsedSeconds = elapsedSeconds; self.cpu = cpu; self.command = command
    }

    public var state: Character { stat.first ?? "?" }
    public var rssMB: Int { rssKB / 1024 }
}

public struct MachineSample: Equatable, Sendable, Codable {
    public var at: Date
    public var cores: Int
    public var load1: Double
    public var load5: Double
    public var swapUsedMB: Int
    public var swapTotalMB: Int
    public var processes: Int
    public var running: Int
    public var uninterruptible: Int
    public var zombies: Int
    public var windowServerCPU: Double
    /// nil when the listing hit its deadline — itself a symptom.
    public var tempEntries: Int?
    /// The same listing split by who left the entries (`Residue.tempOwner`:
    /// mktemp / pip / python), the rest under "other" — so the warning
    /// names the tool, not just a number (#115 item 7).
    public var tempByOwner: [String: Int]?
    public var tempListSeconds: Double
    public var claudeRSSMB: Int

    public init(at: Date = Date(), cores: Int = 0, load1: Double = 0, load5: Double = 0,
                swapUsedMB: Int = 0, swapTotalMB: Int = 0, processes: Int = 0, running: Int = 0,
                uninterruptible: Int = 0, zombies: Int = 0, windowServerCPU: Double = 0,
                tempEntries: Int? = nil, tempListSeconds: Double = 0, claudeRSSMB: Int = 0) {
        self.at = at; self.cores = cores; self.load1 = load1; self.load5 = load5
        self.swapUsedMB = swapUsedMB; self.swapTotalMB = swapTotalMB; self.processes = processes
        self.running = running; self.uninterruptible = uninterruptible; self.zombies = zombies
        self.windowServerCPU = windowServerCPU; self.tempEntries = tempEntries
        self.tempListSeconds = tempListSeconds; self.claudeRSSMB = claudeRSSMB
    }

    public var swapPct: Double { swapTotalMB > 0 ? Double(swapUsedMB) / Double(swapTotalMB) * 100 : 0 }
    public var loadPerCore: Double { cores > 0 ? load1 / Double(cores) : 0 }
}

public enum MachineSampler {
    public static let psArguments = ["-axo", "pid=,ppid=,stat=,rss=,etime=,pcpu=,command="]

    /// `ps -axo pid=,ppid=,stat=,rss=,etime=,pcpu=,command=` → rows.
    public static func parsePS(_ text: String) -> [ProcessRow] {
        var rows: [ProcessRow] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard parts.count >= 7, let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let rss = Int(parts[3]), let cpu = Double(parts[5]) else { continue }
            rows.append(ProcessRow(pid: pid, ppid: ppid, stat: String(parts[2]), rssKB: rss,
                                   elapsedSeconds: parseElapsed(String(parts[4])), cpu: cpu,
                                   command: String(parts[6])))
        }
        return rows
    }

    /// `[[dd-]hh:]mm:ss` → seconds.
    public static func parseElapsed(_ text: String) -> Int {
        var days = 0
        var rest = text
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        let hms: Int
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        case 1: hms = parts[0]
        default: hms = 0
        }
        return days * 86400 + hms
    }

    /// `{ 17.44 11.66 12.34 }` → (1 min, 5 min).
    public static func parseLoad(_ text: String) -> (Double, Double) {
        let numbers = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .split(separator: " ").compactMap { Double($0) }
        return (numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0)
    }

    /// `total = 5120.00M  used = 4126.19M  free = 993.81M  (encrypted)` → (used MB, total MB).
    public static func parseSwap(_ text: String) -> (used: Int, total: Int) {
        func value(_ key: String) -> Int {
            guard let range = text.range(of: key + " = ") else { return 0 }
            let tail = text[range.upperBound...]
            let token = tail.prefix { !$0.isWhitespace }
            let unit = token.last ?? "M"
            let number = Double(token.dropLast()) ?? 0
            switch unit {
            case "G": return Int(number * 1024)
            case "K": return Int(number / 1024)
            default: return Int(number)
            }
        }
        return (value("used"), value("total"))
    }

    /// Everything a sample derives from the rows alone.
    public static func summarize(rows: [ProcessRow], sessionPids: Set<Int>) -> (running: Int, uninterruptible: Int, zombies: Int, windowServerCPU: Double, claudeRSSMB: Int) {
        var running = 0, uninterruptible = 0, zombies = 0
        var ws = 0.0
        var claude = 0
        for row in rows {
            switch row.state {
            case "R": running += 1
            case "U": uninterruptible += 1
            case "Z": zombies += 1
            default: break
            }
            if row.command.split(separator: " ").first?.hasSuffix("WindowServer") == true { ws = row.cpu }
            if sessionPids.contains(row.pid) { claude += row.rssMB }
        }
        return (running, uninterruptible, zombies, ws, claude)
    }

    /// Runs `body` with a deadline; nil when it did not finish in time
    /// (the work keeps running on its thread — a wedged directory
    /// listing cannot be cancelled, only abandoned).
    public static func timed<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> T) -> (T?, TimeInterval) {
        let started = Date()
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let value = body()
            box.set(value)
            done.signal()
        }
        let result = done.wait(timeout: .now() + seconds) == .success ? box.get() : nil
        return (result, Date().timeIntervalSince(started))
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Entries in a directory, counted with a deadline.
    public static func countEntries(_ dir: String, timeout: TimeInterval) -> (Int?, TimeInterval) {
        let (by, seconds) = countByOwner(dir, timeout: timeout)
        return (by.map { $0.values.reduce(0, +) }, seconds)
    }

    /// Entries by owner (`Residue.tempOwner`, "other" for the rest); nil
    /// when the listing did not finish in time.
    public static func countByOwner(_ dir: String, timeout: TimeInterval) -> ([String: Int]?, TimeInterval) {
        let (by, seconds) = timed(timeout) { () -> [String: Int]? in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
            var out: [String: Int] = [:]
            for name in names { out[Residue.tempOwner(of: name) ?? "other", default: 0] += 1 }
            return out
        }
        return (by ?? nil, seconds)
    }

    #if canImport(Darwin) && !os(iOS)
    /// One sample from the live machine.
    public static func collect(sessionPids: Set<Int>, tempDir: String, tempTimeout: TimeInterval = 10,
                               countTemp: Bool = true) -> (MachineSample, [ProcessRow]) {
        let ps = (try? Subprocess.run("/bin/ps", psArguments, timeout: 20)) ?? ""
        let rows = parsePS(ps)
        let cores = Int(((try? Subprocess.run("/usr/sbin/sysctl", ["-n", "hw.ncpu"], timeout: 5)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let load = parseLoad((try? Subprocess.run("/usr/sbin/sysctl", ["-n", "vm.loadavg"], timeout: 5)) ?? "")
        let swap = parseSwap((try? Subprocess.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 5)) ?? "")
        let summary = summarize(rows: rows, sessionPids: sessionPids)
        var sample = MachineSample(cores: cores, load1: load.0, load5: load.1,
                                   swapUsedMB: swap.used, swapTotalMB: swap.total,
                                   processes: rows.count, running: summary.running,
                                   uninterruptible: summary.uninterruptible, zombies: summary.zombies,
                                   windowServerCPU: summary.windowServerCPU, claudeRSSMB: summary.claudeRSSMB)
        if countTemp {
            let (by, seconds) = countByOwner(tempDir, timeout: tempTimeout)
            sample.tempByOwner = by
            sample.tempEntries = by.map { $0.values.reduce(0, +) }
            sample.tempListSeconds = seconds
        }
        return (sample, rows)
    }
    #endif
}
