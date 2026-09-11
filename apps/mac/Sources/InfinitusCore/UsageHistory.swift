import Foundation

// MARK: - Usage utilization history (todo 2026-09-01)
//
// Append-only JSONL of per-account window utilizations, sampled from the
// same `cswap list --json` snapshots the popup renders — no new engine
// surface. One file per machine (`usage-history.<machineID>.jsonl`), so
// the iCloud copy never conflicts: every machine writes only its own
// file and readers merge all of them.
//
// Accounts are keyed by EMAIL, not slot number — `cswap swap`/`move`
// renumber slots (`cswap reorder`, the Accounts pane drag). The slot rides
// along as display metadata only.

public struct UsageSample: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let pct: Double
        /// Epoch seconds of the window's reset instant, if the API sent one.
        public let resetsAt: Double?
        public init(pct: Double, resetsAt: Double?) {
            self.pct = pct
            self.resetsAt = resetsAt
        }
    }

    /// Epoch seconds the ENGINE fetched the usage (usageFetchedAt), not
    /// the sampling wall clock: the engine serves cached usage between
    /// API polls, and recording the poll instant collapses duplicate
    /// snapshots into one line.
    public let t: Double
    public let email: String
    public let number: Int
    public let fiveHour: Window?
    public let sevenDay: Window?
    /// Per-model weekly windows by display name ("Fable", "Opus", …).
    public let scoped: [String: Window]?
    /// Whether this account was the fleet's active one at sampling time
    /// (#7 layer 2: the replay reads switches off consecutive polls).
    /// Additive — nil on lines written before it existed, and omitted
    /// from the JSON then, so old files decode unchanged.
    public let active: Bool?

    public init(t: Double, email: String, number: Int,
                fiveHour: Window?, sevenDay: Window?,
                scoped: [String: Window]?, active: Bool? = nil) {
        self.t = t
        self.email = email
        self.number = number
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.active = active
    }

    /// Sampling identity: one line per (account, usage poll).
    public var dedupeKey: String { "\(email)|\(t)" }
}

public enum UsageHistory {
    // MARK: sampling

    /// Samples for one snapshot's accounts. Rows without usage (sentinel
    /// rows: expired token, locked keychain) or without a fetch stamp
    /// are skipped — an unreadable account has no utilization to record.
    public static func samples(accounts: [Account], now: Date = Date()) -> [UsageSample] {
        accounts.compactMap { a in
            guard let usage = a.usage else { return nil }
            let t = a.usageFetchedAt.flatMap(parseISO)?.timeIntervalSince1970
                ?? now.timeIntervalSince1970
            var scoped: [String: UsageSample.Window] = [:]
            for w in usage.scoped ?? [] {
                guard let name = w.name else { continue }
                scoped[name] = window(w)
            }
            return UsageSample(
                t: t, email: a.email, number: a.number,
                fiveHour: usage.fiveHour.map(window),
                sevenDay: usage.sevenDay.map(window),
                scoped: scoped.isEmpty ? nil : scoped,
                active: a.active)
        }
    }

    private static func window(_ w: UsageWindow) -> UsageSample.Window {
        .init(pct: w.pct, resetsAt: w.resetsAt.flatMap(parseISO)?.timeIntervalSince1970)
    }

    /// The engine emits fractional-second offsets ("…T15:00:00.053961+00:00")
    /// and bare Zulu stamps ("…T03:19:14Z") — try fractional first.
    public static func parseISO(_ s: String) -> Date? {
        enum F {
            static let frac: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f
            }()
            static let plain = ISO8601DateFormatter()
        }
        return F.frac.date(from: s) ?? F.plain.date(from: s)
    }

    // MARK: JSONL file

    public static func append(_ samples: [UsageSample], to url: URL) throws {
        guard !samples.isEmpty else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // stable lines, diffable files
        var blob = Data()
        for s in samples {
            blob.append(try enc.encode(s))
            blob.append(0x0A)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: blob)
        } else {
            try blob.write(to: url)
        }
    }

    /// Tolerant load: a torn tail line (crash mid-append) or foreign
    /// garbage is skipped, never fatal.
    public static func load(url: URL) -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? dec.decode(UsageSample.self, from: $0)
        }
    }

    /// Rewrite the file keeping only samples newer than `cutoff`.
    /// Returns the surviving count.
    @discardableResult
    public static func prune(url: URL, cutoff: Date) throws -> Int {
        let kept = load(url: url).filter { $0.t >= cutoff.timeIntervalSince1970 }
        guard !kept.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return 0
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        try append(kept, to: tmp)
        // remove+move, not replaceItemAt — this file compiles for the
        // Linux tray too, where corelibs' replacement is unreliable.
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
        return kept.count
    }

    /// Merge machines' files: sort by time, drop duplicate
    /// (email, poll-instant) pairs — the same engine poll seen from two
    /// machines is one observation.
    public static func merge(_ files: [[UsageSample]]) -> [UsageSample] {
        var seen = Set<String>()
        return files.flatMap { $0 }
            .sorted { $0.t < $1.t }
            .filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Chart thinning: keep each account's LAST sample per bucket.
    /// Order is preserved (input must be time-sorted, as `merge` returns).
    public static func downsample(_ samples: [UsageSample],
                                  bucket: TimeInterval) -> [UsageSample] {
        guard bucket > 0 else { return samples }
        var last: [String: UsageSample] = [:]   // email|bucket -> sample
        var order: [String] = []
        for s in samples {
            let key = "\(s.email)|\(Int(s.t / bucket))"
            if last[key] == nil { order.append(key) }
            last[key] = s
        }
        return order.compactMap { last[$0] }
    }
}

// MARK: - Waste: quota that perished unused at a weekly reset

/// One closed window generation: the account's utilization when the
/// window rolled over. `wastePct` is the headroom that expired with it.
/// Only WEEKLY windows (7d + per-model) count — a 5h window recycles
/// ~34× a week and "waste" there is meaningless idle time, not lost
/// quota worth charting.
public struct WindowGeneration: Sendable, Equatable {
    public let email: String
    /// "7d" or the scoped model name ("Fable").
    public let window: String
    public let resetAt: Double
    /// Last observed pct before the rollover.
    public let finalPct: Double
    /// Seconds between the last observation and the reset — honesty
    /// metric: a gap of days means finalPct undercounts real use.
    public let observationGap: Double
    public var wastePct: Double { max(0, 100 - finalPct) }
}

public enum WasteMath {
    /// resetsAt jitters sub-second between engine polls (each poll
    /// recomputes it from a countdown); anything within this slack is
    /// the same window generation.
    public static let resetSlack: Double = 120

    /// Closed generations across the history, oldest first. A generation
    /// closes when its account's window resetsAt jumps LATER by more
    /// than the slack, disappears, or (at the end of history) lies in
    /// the past of `now`.
    public static func generations(_ samples: [UsageSample],
                                   now: Date = Date()) -> [WindowGeneration] {
        struct Open { var resetAt: Double; var pct: Double; var lastSeen: Double }
        var open: [String: Open] = [:]      // "email|window" -> state
        var closed: [WindowGeneration] = []

        func track(email: String, window: String, w: UsageSample.Window?, t: Double) {
            let key = "\(email)|\(window)"
            let cur = open[key]
            guard let w, let reset = w.resetsAt else {
                // Window vanished: the reset elapsed between samples.
                if let cur {
                    closed.append(gen(key: key, cur))
                    open[key] = nil
                }
                return
            }
            if let cur, abs(reset - cur.resetAt) <= resetSlack {
                open[key] = Open(resetAt: cur.resetAt, pct: w.pct, lastSeen: t)
            } else {
                if let cur { closed.append(gen(key: key, cur)) }
                open[key] = Open(resetAt: reset, pct: w.pct, lastSeen: t)
            }
        }

        func gen(key: String, _ o: Open) -> WindowGeneration {
            let sep = key.firstIndex(of: "|")!
            return WindowGeneration(
                email: String(key[..<sep]),
                window: String(key[key.index(after: sep)...]),
                resetAt: o.resetAt,
                finalPct: o.pct,
                observationGap: max(0, o.resetAt - o.lastSeen))
        }

        for s in samples.sorted(by: { $0.t < $1.t }) {
            track(email: s.email, window: "7d", w: s.sevenDay, t: s.t)
            for (name, w) in s.scoped ?? [:] {
                track(email: s.email, window: name, w: w, t: s.t)
            }
        }
        // History ended: anything whose reset is already behind `now`
        // closed in the real world even though no sample says so yet.
        for (key, o) in open where o.resetAt < now.timeIntervalSince1970 {
            closed.append(gen(key: key, o))
        }
        return closed.sorted { $0.resetAt < $1.resetAt }
    }
}
