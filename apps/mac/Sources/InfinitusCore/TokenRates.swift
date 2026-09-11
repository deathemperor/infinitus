import Foundation

/// Token and dollar run rate from Claude Code's own transcripts
/// (`~/.claude/projects/*/*.jsonl` — Claude Code's files, never an
/// engine internal; user ask 2026-09-03: "$ and token min/hour/day/
/// week"). Each assistant line carries `message.usage`; a multi-block
/// turn repeats the same message id with identical usage on consecutive
/// lines, so a turn is counted once. Dollars come from the static price
/// table (estimates, never billing truth); an unknown model's tokens
/// still count and the model is named in `unpricedModels`.
public struct TokenRates: Codable, Sendable, Equatable {
    public struct Totals: Codable, Sendable, Equatable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cacheWrite = 0
        public var usd: Double = 0
        public var messages = 0
        public var tokens: Int { input + output + cacheRead + cacheWrite }
        public init() {}
        public static func + (a: Totals, b: Totals) -> Totals {
            var t = Totals()
            t.input = a.input + b.input
            t.output = a.output + b.output
            t.cacheRead = a.cacheRead + b.cacheRead
            t.cacheWrite = a.cacheWrite + b.cacheWrite
            t.usd = a.usd + b.usd
            t.messages = a.messages + b.messages
            return t
        }
    }

    public let computedAt: Double
    public let lastHour: Totals
    public let lastDay: Totals
    public let lastWeek: Totals
    /// Transcripts that contributed (touched inside the week).
    public let files: Int
    public let unpricedModels: [String]

    public init(computedAt: Double, lastHour: Totals, lastDay: Totals, lastWeek: Totals,
                files: Int, unpricedModels: [String]) {
        self.computedAt = computedAt
        self.lastHour = lastHour
        self.lastDay = lastDay
        self.lastWeek = lastWeek
        self.files = files
        self.unpricedModels = unpricedModels
    }
}

/// The scan behind `TokenRates`. Incremental: a cache file remembers,
/// per transcript, how far it was read and its five-minute usage
/// buckets, so a refresh only parses bytes appended since (transcripts
/// are append-only) — the first pass over a week of transcripts is the
/// only expensive one. Runs wherever the caller puts it (the pane's
/// detached task); never on the snapshot loop.
public enum TokenRateScanner {
    public static let lookback: Double = 7 * 86_400
    static let bucket: Double = 300

    struct FileEntry: Codable {
        var size: Int
        var offset: Int
        var lastMessageID: String?
        /// Bucket start (epoch seconds / 300) → totals. String keys so the
        /// JSON stays a dictionary.
        var buckets: [String: TokenRates.Totals]
        var unpriced: [String]
    }
    struct Cache: Codable {
        var version = 1
        var files: [String: FileEntry] = [:]
    }

    public static func defaultProjectsDir() -> URL {
        ClaudeSessions.configHome().appendingPathComponent("projects")
    }

    public static func scan(projectsDir: URL, cacheURL: URL?,
                            now: Double = Date().timeIntervalSince1970) -> TokenRates {
        var cache = cacheURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        let cutoff = now - lookback
        let fm = FileManager.default
        var live: [String: FileEntry] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if let it = fm.enumerator(at: projectsDir, includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in it where url.pathExtension == "jsonl" {
                guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                      rv.isRegularFile == true,
                      let size = rv.fileSize,
                      let mtime = rv.contentModificationDate?.timeIntervalSince1970,
                      mtime >= cutoff else { continue }
                let path = url.path
                var entry = cache.files[path]
                    ?? FileEntry(size: 0, offset: 0, lastMessageID: nil, buckets: [:], unpriced: [])
                if entry.size != size {
                    if size < entry.size {
                        entry = FileEntry(size: 0, offset: 0, lastMessageID: nil, buckets: [:], unpriced: [])
                    }
                    parse(url: url, into: &entry, cutoff: cutoff)
                    entry.size = size
                }
                live[path] = entry
            }
        }
        cache.files = live
        if let cacheURL, let data = try? JSONEncoder().encode(cache) {
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return totals(live, now: now)
    }

    static func totals(_ files: [String: FileEntry], now: Double) -> TokenRates {
        var hour = TokenRates.Totals(), day = TokenRates.Totals(), week = TokenRates.Totals()
        var unpriced = Set<String>()
        for entry in files.values {
            unpriced.formUnion(entry.unpriced)
            for (key, t) in entry.buckets {
                guard let k = Double(key) else { continue }
                let start = k * bucket
                if start >= now - lookback { week = week + t }
                if start >= now - 86_400 { day = day + t }
                if start >= now - 3600 { hour = hour + t }
            }
        }
        return TokenRates(computedAt: now, lastHour: hour, lastDay: day, lastWeek: week,
                          files: files.count, unpricedModels: unpriced.sorted())
    }

    static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    static let usageMarker = Data("\"usage\"".utf8)
    static let newline = UInt8(ascii: "\n")

    /// Parse complete lines from `entry.offset` on; a trailing partial
    /// line (Claude Code mid-write) waits for the next pass.
    static func parse(url: URL, into entry: inout FileEntry, cutoff: Double) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        guard let lastNewline = data.lastIndex(of: newline) else { return }
        let complete = data[data.startIndex...lastNewline]
        var lineStart = complete.startIndex
        while lineStart < complete.endIndex {
            let lineEnd = complete[lineStart...].firstIndex(of: newline) ?? complete.endIndex
            let line = complete[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard line.range(of: assistantMarker) != nil, line.range(of: usageMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let id = message["id"] as? String
            if let id, id == entry.lastMessageID { continue }
            entry.lastMessageID = id
            guard let stamp = obj["timestamp"] as? String,
                  let t = parseStamp(stamp), t >= cutoff else { continue }
            // "<synthetic>" is Claude Code's own placeholder turn — no tokens, no model.
            let model = message["model"] as? String ?? ""
            if model.hasPrefix("<") { continue }
            var tot = TokenRates.Totals()
            tot.input = usage["input_tokens"] as? Int ?? 0
            tot.output = usage["output_tokens"] as? Int ?? 0
            tot.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            tot.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            tot.messages = 1
            if let p = StaticPriceTable.price(model: model) {
                tot.usd = (Double(tot.input) * p.input + Double(tot.output) * p.output
                    + Double(tot.cacheRead) * p.cacheRead + Double(tot.cacheWrite) * p.cacheWrite) / 1_000_000
            } else if !model.isEmpty, !entry.unpriced.contains(model) {
                entry.unpriced.append(model)
            }
            let key = String(Int(t / bucket))
            entry.buckets[key] = (entry.buckets[key] ?? TokenRates.Totals()) + tot
        }
        entry.offset += complete.count
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    public static func parseStamp(_ s: String) -> Double? {
        if let t = fastStamp(s) { return t }
        return (fractional.date(from: s) ?? plain.date(from: s))?.timeIntervalSince1970
    }

    /// `2026-09-05T04:02:47Z` / `…47.463Z` without a formatter (which
    /// cost ~10 µs per entry across millions of transcript lines). Any
    /// other shape — an offset, a missing Z — falls back to the
    /// formatters above, which is also what validates a real date.
    static func fastStamp(_ s: String) -> Double? {
        var u = Array(s.utf8)
        guard u.count >= 20, u.last == UInt8(ascii: "Z"), u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
              u[10] == UInt8(ascii: "T"), u[13] == UInt8(ascii: ":"), u[16] == UInt8(ascii: ":") else { return nil }
        u.removeLast()
        func digits(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                let d = Int(u[i]) - 48
                guard (0...9).contains(d) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let y = digits(0..<4), let m = digits(5..<7), let d = digits(8..<10),
              let hh = digits(11..<13), let mm = digits(14..<16), let ss = digits(17..<19),
              (1...12).contains(m), (1...31).contains(d), hh < 24, mm < 60, ss < 60 else { return nil }
        var frac = 0.0
        if u.count > 19 {
            guard u[19] == UInt8(ascii: "."), u.count > 20, u.count <= 29, let f = digits(20..<u.count) else { return nil }
            frac = Double(f) / pow(10, Double(u.count - 20))
        }
        // Days since 1970-01-01 for a proleptic Gregorian civil date.
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + hh * 3600 + mm * 60 + ss) + frac
    }
}
