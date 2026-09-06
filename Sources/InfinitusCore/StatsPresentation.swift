import Foundation

/// One tile/group catalogue shared by the Mac Stats pane and the phone
/// Stats screen (fix round 1, 2026-09-04): same names, same key paths,
/// same formulas — the two surfaces render this, never their own copy.
/// Everything view-specific (sparkline charts, the hour heatmap, period
/// picker, refresh) stays in each platform's own file.
extension Stats {
    public enum Presentation {
        public struct Tile: Identifiable, Equatable, Sendable {
            public let id: String   // the tile's display name
            public let value: String
            public let delta: String?
            /// Per-day values for the sparkline — empty when `daily` is
            /// (the mirrored `Bundle` drops it to stay small).
            public let series: [Double]
        }

        public struct Group: Identifiable, Equatable, Sendable {
            public let id: String   // the section title
            public let tiles: [Tile]
        }

        public static func groups(_ s: Stats.Summary, theme: RowTheme = .off) -> [Group] {
            [
                Group(id: "Throughput", tiles: [
                    tile("Commits", s, \.commits),
                    tile("Lines +", s, \.linesAdded),
                    tile("Lines −", s, \.linesRemoved),
                    tile("PRs opened", s, \.prsOpened),
                    tile("PRs merged", s, \.prsMerged),
                    tile("Turns", s, \.turns),
                    tile("Tool calls", s, \.totalToolCalls),
                    tile("Output tokens", s, \.outputTokens),
                    tile(theme.rateUnit.map { "Peak \($0)" } ?? "Peak tokens/min", s, \.peakTokensPerMinute),
                    tile("Files touched", s, \.filesTouched),
                    tile("Co-authored by Claude", s, \.coAuthoredByClaude),
                    tile("Reverts", s, \.reverts),
                    tile("Repos", s, \.repoCount),
                ]),
                Group(id: "Messages & sessions", tiles: [
                    tile("Keyboard", s, \.humanMessages),
                    tile("Phone", s, \.phoneMessages),
                    tile("Agents", s, \.agentMessages),
                    tile("Nudges", s, \.nudges),
                    tile("Sessions", s, \.sessionCount),
                    tile("Sub-agents", s, \.subagents),
                ]),
                Group(id: "Autonomy", tiles: [
                    ratio("Messages / commit", s, \.messagesPerCommit),
                    ratio("Tool calls / message", s, \.toolCallsPerHumanMessage),
                    tile("Longest unattended", s, \.longestUnattended, unit: "tool calls"),
                    percent("Human share", s, \.humanShare),
                ]),
                Group(id: "Friction", tiles: [
                    minutes("Waiting on you", s, \.waitingSeconds),
                    tile("Questions", s, \.questions),
                    tile("Denied tools", s, \.denials),
                    tile("Tool errors", s, \.toolErrors),
                    tile("API retries", s, \.retries),
                    tile("Compactions", s, \.compactions),
                ]),
                Group(id: "Limits", tiles: [
                    tile("Switches", s, \.switches),
                    tile("Accounts hit a limit", s, \.limitStops),
                    tile("Revivals", s, \.revivals),
                    tile("Minutes lost, all out", s, \.minutesLostToLimits, format: { Int($0).formatted() }),
                    tile("Ignites", s, \.ignites),
                    tile("Resumes", s, \.resumes),
                ]),
                Group(id: "Cost (API-equivalent estimate)", tiles: [
                    money("Spend", s, \.usd),
                    tile("Input tokens", s, \.inputTokens),
                    tile("Processed tokens", s, \.processedTokens),
                    tile("Cached input", s, \.cacheReadTokens),
                    tile("Uncached input", s, \.uncachedInputTokens),
                    tile("Cache writes", s, \.cacheWriteTokens),
                    money("Cache savings", s, \.cacheSavingsUSD),
                    money("Per commit", s, \.usdPerCommit),
                    money("Per PR", s, \.usdPerPR),
                    ratio("Tokens / line", s, \.tokensPerLine),
                    ratio("Mean hours to merge", s, \.meanMergeHours),
                ]),
            ]
        }

        /// The tokens/min record book as lines (#89): best ever, today,
        /// the trend, records this month — then the record days.
        public static func recordLines(_ r: Stats.TokenRecords, theme: RowTheme = .off) -> [String] {
            var out: [String] = []
            if let best = r.best {
                out.append("Best ever: \(perMinute(best.tokensPerMinute, theme: theme)) on \(best.day)")
            } else {
                return ["No busy minute on record yet."]
            }
            out.append("Today's peak: \(perMinute(r.today, theme: theme))")
            if let trend = r.trend {
                let arrow = trend >= 1.15 ? "↑" : trend <= 0.87 ? "↓" : "→"
                out.append("Trend: \(arrow) \(String(format: "%.2f", trend))× this week's median peak vs the week before")
            } else {
                out.append("Trend: needs busy days in each of the last two weeks")
            }
            out.append("Records this month: \(r.recordsThisMonth) · all time: \(r.records.count)\(r.records.count >= Stats.TokenRecords.keep ? "+" : "")")
            return out
        }

        public static func recordRows(_ r: Stats.TokenRecords) -> [(label: String, count: Int)] {
            r.records.map { (label: $0.day, count: $0.tokensPerMinute) }
        }

        public static func perMinute(_ v: Int, theme: RowTheme = .off) -> String {
            let unit = theme.rateUnit ?? "tok/min"
            return v >= 10_000 ? String(format: "%.1fk \(unit)", Double(v) / 1000) : "\(v.formatted()) \(unit)"
        }

        /// The record book's section title, in the theme's words (#218).
        public static func recordTitle(theme: RowTheme) -> String {
            guard let unit = theme.rateUnit else { return "Tokens/min records" }
            return unit.prefix(1).uppercased() + unit.dropFirst() + " records"
        }

        /// The four session-length buckets, in `Stats.Day.sessionBucket`
        /// order (`< 15 min`, `15–60 min`, `1–4 h`, `> 4 h`).
        public static func sessionLengthRows(_ s: Stats.Summary) -> [(label: String, count: Int)] {
            let labels = ["< 15 min", "15–60 min", "1–4 h", "> 4 h"]
            return Array(zip(labels, s.total.sessionBuckets))
        }

        public static func sessionTimeLine(_ s: Stats.Summary) -> String {
            let total = s.total.sessionSeconds
            let n = max(1, s.total.sessionCount)
            return "\(Int(total / 3600)) h total · \(Int(total / Double(n) / 60)) min per session"
        }

        // MARK: Stats v2 — where the effort went

        /// One table row: an activity or a model. `share` is this row's
        /// $ share of its table (0…1).
        public struct Row: Identifiable, Equatable, Sendable {
            public let id: String
            public let count: Int
            public let minutes: Int
            public let tokens: Int
            public let usd: Double
            public let share: Double
            /// Cache reads' share of this row's input (read + write +
            /// fresh), nil when this table doesn't track cache reads/
            /// writes at all (per-activity tallies, #139) rather than
            /// tracking zero of them.
            public let cachedShare: Double?

            public init(id: String, tally: Stats.ActivityTally, share: Double) {
                self.id = id
                count = tally.stretches
                minutes = Int(tally.seconds / 60)
                tokens = tally.inputTokens + tally.outputTokens
                usd = tally.usd
                self.share = share
                let cache = tally.cacheReadTokens + tally.cacheWriteTokens
                let inputTotal = tally.inputTokens + cache
                cachedShare = cache > 0 ? Double(tally.cacheReadTokens) / Double(inputTotal) : nil
            }

            public var minutesText: String {
                minutes >= 120 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) min"
            }
            /// For the phone's inline "N stretches · M tokens…" line —
            /// appends " · cached NN%", or nothing when untracked.
            public var cachedSuffixText: String {
                cachedShare.map { " · cached \(Int(($0 * 100).rounded()))%" } ?? ""
            }
            /// For the Mac table, which already has a "Cached" column header.
            public var cachedPercentText: String {
                cachedShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            }
            public var tokensText: String {
                if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
                if tokens >= 10_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
                return tokens.formatted()
            }
            public var usdText: String { "$" + String(format: usd >= 100 ? "%.0f" : "%.2f", usd) }
        }

        public static let activityFootnote = "Heuristic: each stretch between two of your messages is labeled by its strongest signal — a review skill or reviewer sub-agent, a plan skill, a debugging skill, browser tools, simulator commands; then test-file edits; then prose-only replies. A stretch counts on the day it started; sub-agent spend shows under models, engines and effort only. Claude Code and Codex CLI transcripts are read; models without a price count tokens at $0."

        /// Catalogue order; activities with no stretches are left out.
        public static func activityRows(_ s: Stats.Summary) -> [Row] {
            let total = s.total.activities.values.reduce(0) { $0 + $1.usd }
            let tokenTotal = s.total.activities.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            return Stats.Activity.allCases.compactMap { a in
                guard let t = s.total.activities[a.rawValue], t.stretches > 0 || t.usd > 0 else { return nil }
                return Row(id: a.title, tally: t, share: share(t, total: total, tokenTotal: tokenTotal))
            }
        }

        /// By $ descending; the compacted "other" fold sits last. Aliases
        /// of the same model (`claude-opus-5` vs `claude-opus-5[1m]`)
        /// share a title, so they're merged by title before the Mac's
        /// uncompacted table gets the same 6-named-rows-plus-"Other
        /// models" cap the phone's compacted bundle already has.
        public static func modelRows(_ s: Stats.Summary) -> [Row] {
            var titled: [String: Stats.ActivityTally] = [:]
            for (key, t) in s.total.byModel {
                let mapKey = key == "other" ? "other" : modelTitle(key)
                titled[mapKey, default: Stats.ActivityTally()] = titled[mapKey, default: Stats.ActivityTally()] + t
            }
            let capped = Stats.Day.topModels(titled, keep: 6)
            let total = capped.values.reduce(0) { $0 + $1.usd }
            let tokenTotal = capped.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            let sorted = capped.sorted { a, b in
                if a.key == "other" { return false }
                if b.key == "other" { return true }
                return a.value.usd == b.value.usd ? a.key < b.key : a.value.usd > b.value.usd
            }
            return sorted.map { key, tally in
                Row(id: key == "other" ? "Other models" : key, tally: tally, share: share(tally, total: total, tokenTotal: tokenTotal))
            }
        }

        /// By $ descending. An engine whose models carry no price (Codex
        /// CLI's OpenAI models today) is marked unpriced: its tokens are
        /// real, its $0 is not a saving.
        public static func engineRows(_ s: Stats.Summary) -> [Row] {
            keyedRows(s.total.byEngine) { key, tally in
                let title = Stats.Engine(rawValue: key)?.title ?? key
                return tally.usd == 0 && tally.inputTokens + tally.outputTokens > 0 ? title + " · unpriced" : title
            }
        }

        /// By $ descending; "Unset" is an entry with no effort recorded.
        public static func effortRows(_ s: Stats.Summary) -> [Row] {
            keyedRows(s.total.byEffort) { key, _ in key == "unset" ? "Unset" : key.prefix(1).uppercased() + key.dropFirst() }
        }

        private static func keyedRows(_ table: [String: Stats.ActivityTally],
                                      title: (String, Stats.ActivityTally) -> String) -> [Row] {
            let total = table.values.reduce(0) { $0 + $1.usd }
            let tokenTotal = table.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            let sorted = table.sorted { a, b in
                a.value.usd == b.value.usd ? a.key < b.key : a.value.usd > b.value.usd
            }
            return sorted.map { key, tally in
                Row(id: title(key, tally), tally: tally, share: share(tally, total: total, tokenTotal: tokenTotal))
            }
        }

        /// A table's $ share, falling back to a token share when nothing
        /// in the table has a price (e.g. an unrecognized model id).
        private static func share(_ t: Stats.ActivityTally, total: Double, tokenTotal: Int) -> Double {
            if total > 0 { return t.usd / total }
            if tokenTotal > 0 { return Double(t.inputTokens + t.outputTokens) / Double(tokenTotal) }
            return 0
        }

        /// `claude-opus-4-5-20250805` → "Opus 4.5"; `claude-fable-5[1m]`
        /// → "Fable 5". Anything that isn't a Claude id is shown as-is.
        public static func modelTitle(_ id: String) -> String {
            if id == "other" { return "Other models" }
            guard id.hasPrefix("claude-") else { return id }
            let bare = id.split(separator: "[").first.map(String.init) ?? id
            let parts = bare.dropFirst("claude-".count).split(separator: "-").map(String.init)
            guard let family = parts.first else { return id }
            let version = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        }

        /// A year's series is 365 marks per tile — ~25k Charts marks
        /// across the catalogue, which is what a year sparkline row
        /// actually costs. Anything past ~two months collapses to
        /// weekly buckets (≤ 53 points for a full year): sums for
        /// counts, means for money and ratios — a week's worth of
        /// "tool calls / message" added together means nothing.
        static func bucketed(_ series: [Double], mean: Bool) -> [Double] {
            guard series.count > 62 else { return series }
            var out: [Double] = []
            out.reserveCapacity(series.count / 7 + 1)
            var i = 0
            while i < series.count {
                let j = min(i + 7, series.count)
                let week = series[i..<j].reduce(0, +)
                out.append(mean ? week / Double(j - i) : week)
                i = j
            }
            return out
        }

        // MARK: tile builders (verbatim from the Mac pane, 2026-09-04)

        private static func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Int>,
                                 unit: String? = nil) -> Tile {
            let v = s.total[keyPath: key], p = s.previous[keyPath: key]
            return Tile(id: name, value: v.formatted() + (unit.map { " \($0)" } ?? ""),
                       delta: deltaText(Double(v), Double(p)),
                       series: bucketed(s.daily.map { Double($0.day[keyPath: key]) }, mean: false))
        }

        private static func tile(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>,
                                 mean: Bool = false, format: @escaping (Double) -> String) -> Tile {
            let v = s.total[keyPath: key], p = s.previous[keyPath: key]
            return Tile(id: name, value: format(v), delta: deltaText(v, p),
                        series: bucketed(s.daily.map { $0.day[keyPath: key] }, mean: mean))
        }

        private static func ratio(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { String(format: "%.1f", $0) } ?? "—",
                delta: zip2(s.total[keyPath: key], s.previous[keyPath: key]).map { deltaText($0, $1) } ?? nil,
                series: bucketed(s.daily.map { $0.day[keyPath: key] ?? 0 }, mean: true))
        }

        private static func percent(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { "\(Int($0 * 100))%" } ?? "—", delta: nil,
                series: bucketed(s.daily.map { ($0.day[keyPath: key] ?? 0) * 100 }, mean: true))
        }

        private static func minutes(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
            tile(name, s, key) { secs in
                let m = Int(secs / 60)
                return m >= 120 ? "\(m / 60) h \(m % 60) m" : "\(m) min"
            }
        }

        private static func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double>) -> Tile {
            tile(name, s, key, mean: true) { "$" + String(format: $0 >= 100 ? "%.0f" : "%.2f", $0) }
        }

        private static func money(_ name: String, _ s: Stats.Summary, _ key: KeyPath<Stats.Day, Double?>) -> Tile {
            Tile(id: name, value: s.total[keyPath: key].map { "$" + String(format: "%.2f", $0) } ?? "—", delta: nil,
                series: bucketed(s.daily.map { $0.day[keyPath: key] ?? 0 }, mean: true))
        }

        private static func deltaText(_ v: Double, _ p: Double) -> String? {
            guard p != 0 else { return v == 0 ? nil : "new" }
            let pct = Int(((v - p) / p * 100).rounded())
            return pct == 0 ? "±0%" : pct > 0 ? "+\(pct)%" : "−\(-pct)%"
        }

        private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
            guard let a, let b else { return nil }
            return (a, b)
        }
    }
}
