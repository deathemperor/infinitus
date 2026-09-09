import Foundation
import InfinitusCore

/// The Usage tab's arithmetic (T3 `usageFormat.ts` and the merge behind
/// `UsageRouteScreen.tsx` at upstream 6c583620f) over the engines'
/// `UsageReport` instead of T3's transcript scan. The wire differs, and
/// the tab says so rather than papering over it: the period is the
/// engine's fixed `days`, a day carries cost and messages but no tokens
/// (so the chart is cost only), and the price table names its source
/// without rates (so there is no cache-savings figure).
enum T3UsageCost {
    /// One report as the merge sees it: whose Mac and fleet it came from.
    struct Source {
        let macId: String?
        let macName: String
        let provider: Provider
        let report: UsageReport
    }

    struct AccountRow: Equatable {
        let id: String
        let name: String
        let macName: String
        /// Index into `Merged.seriesNames`: the source this account came from.
        let series: Int
        let costUsd: Double
        let messages: Int
        let tokens: Int
        var share: Double = 0
    }

    struct ModelRow: Equatable {
        let model: String
        let costUsd: Double
        let messages: Int
        var share: Double = 0
    }

    struct SeriesDay: Equatable {
        let day: String
        /// One value per source, in source order — the stack bottom first.
        let values: [Double]
        var total: Double { values.reduce(0, +) }
    }

    /// Every shown report folded into one view, as T3 merges environments.
    struct Merged: Equatable {
        let days: Int
        let costUsd: Double
        let messages: Int
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let unpricedTokens: Int?
        let accounts: [AccountRow]
        let models: [ModelRow]
        /// nil when no report carries daily rows (an older CLI).
        let daily: [SeriesDay]?
        let seriesNames: [String]
        let caveats: [String]

        var tokens: Int { input + output + cacheRead + cacheWrite }
        var observedInput: Int { input + cacheRead }
        var activeDays: Int { daily?.filter { $0.total > 0 }.count ?? 0 }
        var hasActivity: Bool { daily?.contains { $0.total > 0 } ?? false }
    }

    static func merge(_ sources: [Source], today: Date = Date(), calendar: Calendar = .current) -> Merged? {
        guard !sources.isEmpty else { return nil }
        let several = Set(sources.map { $0.macId ?? "" }).count > 1
        var cost = 0.0, messages = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var unpriced: Int? = nil
        var accounts: [AccountRow] = []
        var models: [String: ModelRow] = [:]
        var caveats: [String] = []
        for (index, s) in sources.enumerated() {
            let r = s.report
            cost += r.estimatedTotalUSD
            if let u = r.unpricedTokens { unpriced = (unpriced ?? 0) + u }
            for c in r.caveats where !caveats.contains(c) { caveats.append(c) }
            for b in r.accounts + (r.unattributed.map { [$0] } ?? []) {
                messages += b.messages; input += b.input; output += b.output
                cacheRead += b.cacheRead; cacheWrite += b.cacheWrite
                let name = b.number == nil ? "Unattributed" : T3UsageLimits.name(alias: b.alias, email: b.email ?? "")
                accounts.append(AccountRow(id: "\(s.macId ?? "")/\(s.provider.rawValue)/\(b.number.map(String.init) ?? "-")",
                                           name: several ? "\(name) · \(s.macName)" : name, macName: s.macName, series: index,
                                           costUsd: b.estimatedUSD, messages: b.messages,
                                           tokens: b.input + b.output + b.cacheRead + b.cacheWrite))
                for m in b.models {
                    let prior = models[m.model]
                    models[m.model] = ModelRow(model: m.model, costUsd: (prior?.costUsd ?? 0) + m.estimatedUSD,
                                               messages: (prior?.messages ?? 0) + m.messages)
                }
            }
        }
        let days = sources.map(\.report.days).max() ?? 0
        let dailies = sources.map(\.report.daily)
        let daily: [SeriesDay]? = dailies.allSatisfy({ $0 == nil }) ? nil : dayFill(
            days: days, today: today, calendar: calendar,
            perSource: dailies.map { rows in
                var byDay: [String: Double] = [:]
                for row in rows ?? [] { byDay[row.date, default: 0] += row.estimatedUSD }
                return byDay
            })
        let total = cost
        func shared<T>(_ rows: [T], _ costOf: (T) -> Double, _ set: (inout T, Double) -> Void) -> [T] {
            rows.sorted { costOf($0) > costOf($1) }.map { row in
                var r = row; set(&r, total > 0 ? costOf(row) / total : 0); return r
            }
        }
        return Merged(days: days, costUsd: cost, messages: messages, input: input, output: output,
                      cacheRead: cacheRead, cacheWrite: cacheWrite, unpricedTokens: unpriced,
                      accounts: shared(accounts, \.costUsd) { $0.share = $1 },
                      models: shared(Array(models.values), \.costUsd) { $0.share = $1 },
                      daily: daily, seriesNames: sources.map { several ? "\($0.provider.displayName) · \($0.macName)" : $0.provider.displayName },
                      caveats: caveats)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The last `days` local days ending today, zero-filled where nothing
    /// happened (`buildChartDays`).
    static func dayFill(days: Int, today: Date, calendar: Calendar, perSource: [[String: Double]]) -> [SeriesDay] {
        guard days > 0 else { return [] }
        let f = dayFormatter
        f.timeZone = calendar.timeZone
        let start = calendar.startOfDay(for: today)
        return (0..<days).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: start) else { return nil }
            let key = f.string(from: d)
            return SeriesDay(day: key, values: perSource.map { $0[key] ?? 0 })
        }
    }

    /// `$1,234.56`.
    static func formatUsd(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: value as NSNumber) ?? String(format: "$%.2f", value)
    }

    static func formatCount(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }

    /// Three significant figures with a unit: `19.9B`, `76.7M`, `804K`, `950`.
    static func formatTokens(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 1e12 { return trim(value / 1e12) + "T" }
        if abs >= 1e9 { return trim(value / 1e9) + "B" }
        if abs >= 1e6 { return trim(value / 1e6) + "M" }
        if abs >= 1e3 { return trim(value / 1e3) + "K" }
        return formatCount(Int(value.rounded()))
    }

    private static func trim(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let digits = abs >= 100 ? 0 : abs >= 10 ? 1 : 2
        var s = String(format: "%.\(digits)f", value)
        if s.contains("."), s.drop { $0 != "." }.dropFirst().allSatisfy({ $0 == "0" }) {
            s = String(s.prefix { $0 != "." })
        }
        return s
    }

    /// `12.3%`.
    static func formatPercent(_ share: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f%%", share * 100)
    }

    /// `2026-08-07` → `Aug 7`.
    static func formatDayShort(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[parts[1] - 1]) \(parts[2])"
    }
}
