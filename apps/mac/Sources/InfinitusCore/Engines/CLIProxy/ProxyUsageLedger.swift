import Foundation

// MARK: - CLIProxyAPI usage-queue records
//
// `GET /v0/management/usage-queue?count=N` pops up to N raw usage records
// from a 60-second, destructive queue (upstream `sdk/cliproxy/usage`
// @ 81e1b53). Records carry other keys too (`latency_ms`, `source`,
// `request_id`, `api_key`, `client_ip`, …) — those are NEVER decoded here
// and therefore never persisted; `api_key`/`client_ip` are sensitive.

/// One popped usage record, trimmed to the fields Infinitus persists.
public struct ProxyUsageRecord: Codable, Sendable {
    /// Raw RFC3339(Nano) timestamp string, kept verbatim for round-tripping;
    /// use `date` for arithmetic.
    public let timestamp: String
    public let authIndex: String
    public let provider: String
    public let model: String
    public let tokenBreakdown: TokenBreakdown

    enum CodingKeys: String, CodingKey {
        case timestamp
        case authIndex = "auth_index"
        case provider
        case model
        case tokenBreakdown = "token_breakdown"
    }

    public init(timestamp: String, authIndex: String, provider: String,
                model: String, tokenBreakdown: TokenBreakdown) {
        self.timestamp = timestamp
        self.authIndex = authIndex
        self.provider = provider
        self.model = model
        self.tokenBreakdown = tokenBreakdown
    }

    public struct TokenBreakdown: Codable, Sendable {
        public let totalTokens: Int
        public let input: InputTokens
        public let output: OutputTokens
        public let unclassifiedTokens: Int

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
            case input
            case output
            case unclassifiedTokens = "unclassified_tokens"
        }

        public init(totalTokens: Int = 0, input: InputTokens = InputTokens(),
                    output: OutputTokens = OutputTokens(),
                    unclassifiedTokens: Int = 0) {
            self.totalTokens = totalTokens
            self.input = input
            self.output = output
            self.unclassifiedTokens = unclassifiedTokens
        }
    }

    public struct InputTokens: Codable, Sendable {
        public let totalTokens: Int
        public let uncachedTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
            case uncachedTokens = "uncached_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }

        public init(totalTokens: Int = 0, uncachedTokens: Int = 0,
                    cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
            self.totalTokens = totalTokens
            self.uncachedTokens = uncachedTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
        }
    }

    public struct OutputTokens: Codable, Sendable {
        public let totalTokens: Int
        public let nonReasoningTokens: Int
        public let reasoningTokens: Int

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
            case nonReasoningTokens = "non_reasoning_tokens"
            case reasoningTokens = "reasoning_tokens"
        }

        public init(totalTokens: Int = 0, nonReasoningTokens: Int = 0,
                    reasoningTokens: Int = 0) {
            self.totalTokens = totalTokens
            self.nonReasoningTokens = nonReasoningTokens
            self.reasoningTokens = reasoningTokens
        }
    }

    /// `timestamp` parsed to a `Date`, tolerating Go's RFC3339Nano (variable
    /// fractional-second width, numeric offsets) which `ISO8601DateFormatter`
    /// only handles for exactly 3 fractional digits — strip the fraction by
    /// hand before handing off to the formatter.
    public var date: Date? {
        Self.parseTimestamp(timestamp)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        guard let tIndex = s.firstIndex(of: "T") else { return nil }
        var normalized = s
        if let dotIndex = s[tIndex...].firstIndex(of: ".") {
            var end = s.index(after: dotIndex)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            normalized.removeSubrange(dotIndex..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    /// Decodes the `usage-queue` array leniently: a malformed element (bad
    /// shape, unparseable timestamp) is skipped rather than failing the
    /// whole batch — the queue is destructive, so a partial decode still
    /// beats losing every record to one bad one.
    public static func decodeQueue(_ data: Data) -> [ProxyUsageRecord] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        return array.compactMap { element -> ProxyUsageRecord? in
            guard let dict = element as? [String: Any],
                  let elementData = try? JSONSerialization.data(withJSONObject: dict),
                  let record = try? decoder.decode(ProxyUsageRecord.self, from: elementData),
                  record.date != nil
            else { return nil }
            return record
        }
    }
}

// MARK: - Static price table (mirrors claude_swap/usage_report.py)

/// USD-per-million-token list prices, mirrored from
/// `~/death/claude-swap/src/claude_swap/usage_report.py` so both engines
/// price the same way. Models absent here are counted but reported as
/// unpriced — never guessed.
public enum StaticPriceTable {
    public static let source = "infinitus-static (mirrors claude-swap usage_report.py)"
    public static let date = "2026-09-02"

    struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static let prices: [String: Rate] = [
        "claude-fable-5": Rate(input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-fable-5-1": Rate(input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-opus-5": Rate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-5": Rate(input: 2.0, output: 10.0, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-opus-4-8": Rate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7": Rate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6": Rate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5": Rate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-4-5": Rate(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5": Rate(input: 1.0, output: 5.0, cacheRead: 0.1, cacheWrite: 1.25),
    ]

    /// Rates for a model id, tolerating variant suffixes — mirrors
    /// `_price_for`: `claude-fable-5[1m]` (long-context variant) prices at
    /// base rates, `claude-haiku-4-5-20251001` falls back to
    /// `claude-haiku-4-5`. nil = unpriced, never guessed.
    public static func price(model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)? {
        let base = model.split(separator: "[", maxSplits: 1).first.map(String.init) ?? model
        if let rate = prices[base] {
            return (rate.input, rate.output, rate.cacheRead, rate.cacheWrite)
        }
        if let range = base.range(of: "-\\d{8}$", options: .regularExpression) {
            let trimmed = String(base[base.startIndex..<range.lowerBound])
            if let rate = prices[trimmed] {
                return (rate.input, rate.output, rate.cacheRead, rate.cacheWrite)
            }
        }
        return nil
    }
}

// MARK: - Ledger: JSONL persistence + aggregation

/// Persists popped `usage-queue` records to a JSONL file and turns them
/// into a `UsageReport` — the proxy-engine counterpart to cswap's
/// transcript-scan report (`usage_report.py`).
public actor ProxyUsageLedger {
    private let url: URL
    private let pruneThresholdBytes: Int
    private static let retention: TimeInterval = 90 * 86_400

    public init(url: URL, pruneThresholdBytes: Int = 1_048_576) {
        self.url = url
        self.pruneThresholdBytes = pruneThresholdBytes
    }

    /// Appends one JSON line per record, then prunes lines older than 90
    /// days — cheaply, only when the file has grown past
    /// `pruneThresholdBytes`.
    public func append(_ records: [ProxyUsageRecord]) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let chunk = try Self.encodeLines(records)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
        } else {
            try chunk.write(to: url)
        }
        try pruneIfNeeded()
    }

    public func records(since: Date) throws -> [ProxyUsageRecord] {
        try readAll().filter { record in
            guard let date = record.date else { return false }
            return date >= since
        }
    }

    private func readAll() throws -> [ProxyUsageRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ProxyUsageRecord.self, from: lineData)
        }
    }

    private func pruneIfNeeded() throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > pruneThresholdBytes else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let kept = try readAll().filter { ($0.date ?? .distantPast) >= cutoff }
        try Self.encodeLines(kept).write(to: url, options: .atomic)
    }

    private static func encodeLines(_ records: [ProxyUsageRecord]) throws -> Data {
        let encoder = JSONEncoder()
        var chunk = Data()
        for record in records {
            chunk.append(try encoder.encode(record))
            chunk.append(0x0A)
        }
        return chunk
    }

    /// Aggregates the last `days` days of ledger records into a
    /// `UsageReport`. `numbers`/`emails` map a record's `auth_index` to the
    /// popup's account number/email; an auth_index absent from `numbers`
    /// lands in `unattributed`. A read failure (e.g. no ledger file yet)
    /// is treated as an empty ledger, not a fatal error — there is nothing
    /// to report yet.
    public func report(days: Int, numbers: [String: Int], emails: [String: String],
                        now: Date = Date()) -> UsageReport {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recs = (try? records(since: since)) ?? []

        var byAuthIndex: [String: BucketAccum] = [:]
        var unattributed = BucketAccum()
        var unpricedTokens = 0
        var daily: [DailyKey: DailyAccum] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for record in recs {
            guard let date = record.date else { continue }
            let number = numbers[record.authIndex]
            let rate = StaticPriceTable.price(model: record.model)

            let input = record.tokenBreakdown.input
            let pricedInput: Int
            if input.uncachedTokens == 0 && input.totalTokens > 0 {
                pricedInput = max(0, input.totalTokens - input.cacheReadTokens - input.cacheWriteTokens)
            } else {
                pricedInput = input.uncachedTokens
            }
            let output = record.tokenBreakdown.output.totalTokens
            let cacheRead = input.cacheReadTokens
            let cacheWrite = input.cacheWriteTokens

            let cost: Double
            if let rate {
                cost = (Double(pricedInput) * rate.input
                    + Double(output) * rate.output
                    + Double(cacheRead) * rate.cacheRead
                    + Double(cacheWrite) * rate.cacheWrite) / 1_000_000
            } else {
                cost = 0
                if record.tokenBreakdown.totalTokens > 0 {
                    unpricedTokens += record.tokenBreakdown.totalTokens
                }
            }

            var accum = number != nil ? (byAuthIndex[record.authIndex] ?? BucketAccum()) : unattributed
            accum.estimatedUSD += cost
            accum.messages += 1
            accum.input += pricedInput
            accum.output += output
            accum.cacheRead += cacheRead
            accum.cacheWrite += cacheWrite
            var modelSlice = accum.models[record.model] ?? (usd: 0, messages: 0)
            modelSlice.usd += cost
            modelSlice.messages += 1
            accum.models[record.model] = modelSlice
            if number != nil {
                byAuthIndex[record.authIndex] = accum
            } else {
                unattributed = accum
            }

            let day = dayFormatter.string(from: date)
            let key = DailyKey(day: day, account: number)
            var slot = daily[key] ?? DailyAccum()
            slot.estimatedUSD += cost
            slot.messages += 1
            daily[key] = slot
        }

        func makeModels(_ accum: BucketAccum) -> [UsageReport.ModelSlice] {
            accum.models
                .sorted { $0.value.usd > $1.value.usd }
                .map { UsageReport.ModelSlice(model: $0.key, estimatedUSD: round2($0.value.usd),
                                               messages: $0.value.messages) }
        }

        var buckets: [UsageReport.UsageBucket] = []
        for (authIndex, accum) in byAuthIndex.sorted(by: { (numbers[$0.key] ?? 0) < (numbers[$1.key] ?? 0) }) {
            buckets.append(UsageReport.UsageBucket(
                number: numbers[authIndex], email: emails[authIndex], alias: nil,
                estimatedUSD: round2(accum.estimatedUSD), messages: accum.messages,
                input: accum.input, output: accum.output, cacheRead: accum.cacheRead,
                cacheWrite: accum.cacheWrite, models: makeModels(accum)))
        }

        let unattributedBucket: UsageReport.UsageBucket? = unattributed.messages > 0
            ? UsageReport.UsageBucket(
                number: nil, email: nil, alias: nil, estimatedUSD: round2(unattributed.estimatedUSD),
                messages: unattributed.messages, input: unattributed.input, output: unattributed.output,
                cacheRead: unattributed.cacheRead, cacheWrite: unattributed.cacheWrite,
                models: makeModels(unattributed))
            : nil

        let dailySlices = daily
            .sorted { lhs, rhs in
                if lhs.key.day != rhs.key.day { return lhs.key.day < rhs.key.day }
                if (lhs.key.account == nil) != (rhs.key.account == nil) { return rhs.key.account == nil }
                return (lhs.key.account ?? 0) < (rhs.key.account ?? 0)
            }
            .map { UsageReport.DailySlice(date: $0.key.day, account: $0.key.account,
                                           estimatedUSD: round2($0.value.estimatedUSD),
                                           messages: $0.value.messages) }

        let total = round2(buckets.reduce(0) { $0 + $1.estimatedUSD } + (unattributedBucket?.estimatedUSD ?? 0))

        return UsageReport(
            days: days,
            estimatedTotalUSD: total,
            priceTable: UsageReport.PriceTable(source: StaticPriceTable.source, date: StaticPriceTable.date),
            accounts: buckets,
            unattributed: unattributedBucket,
            unpricedTokens: unpricedTokens > 0 ? unpricedTokens : nil,
            caveats: [
                "Estimates at API list price — not a bill.",
                "Proxy usage records are drained from CLIProxyAPI's 60-second queue; requests made while Infinitus was not running are not counted.",
                "Draining the queue conflicts with other collectors (e.g. the proxy's own web UI).",
            ],
            daily: dailySlices)
    }

    private struct BucketAccum {
        var estimatedUSD: Double = 0
        var messages: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
        var models: [String: (usd: Double, messages: Int)] = [:]
    }

    private struct DailyAccum {
        var estimatedUSD: Double = 0
        var messages: Int = 0
    }

    private struct DailyKey: Hashable {
        let day: String
        let account: Int?
    }
}

private func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}
