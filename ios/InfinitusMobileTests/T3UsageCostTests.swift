import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// `usageFormat.ts` figures and the environment merge behind the Usage tab.
final class T3UsageCostTests: XCTestCase {
    func testTokensCompactToThreeSignificantFigures() {
        XCTAssertEqual(T3UsageCost.formatTokens(19_900_000_000), "19.9B")
        XCTAssertEqual(T3UsageCost.formatTokens(76_700_000), "76.7M")
        XCTAssertEqual(T3UsageCost.formatTokens(804_000), "804K")
        XCTAssertEqual(T3UsageCost.formatTokens(950), "950")
        XCTAssertEqual(T3UsageCost.formatTokens(2000), "2K")
        XCTAssertEqual(T3UsageCost.formatTokens(1500), "1.50K")
        XCTAssertEqual(T3UsageCost.formatTokens(1_234_567), "1.23M")
    }

    func testMoneyPercentAndDayLabels() {
        XCTAssertEqual(T3UsageCost.formatUsd(1234.5), "$1,234.50")
        XCTAssertEqual(T3UsageCost.formatUsd(0), "$0.00")
        XCTAssertEqual(T3UsageCost.formatPercent(0.1234), "12.3%")
        XCTAssertEqual(T3UsageCost.formatDayShort("2026-08-07"), "Aug 7")
        XCTAssertEqual(T3UsageCost.formatDayShort("garbage"), "garbage")
    }

    private func report(days: Int, accounts: [UsageReport.UsageBucket], daily: [UsageReport.DailySlice]?, unpriced: Int? = nil) -> UsageReport {
        UsageReport(days: days, estimatedTotalUSD: accounts.map(\.estimatedUSD).reduce(0, +),
                    priceTable: .init(source: "test", date: "2026-09-01"), accounts: accounts,
                    unpricedTokens: unpriced, caveats: ["estimate"], daily: daily)
    }

    private func bucket(_ number: Int, alias: String, usd: Double, model: String) -> UsageReport.UsageBucket {
        .init(number: number, email: "\(alias.lowercased())@x.com", alias: alias, estimatedUSD: usd, messages: 10,
              input: 1000, output: 100, cacheRead: 4000, cacheWrite: 500,
              models: [.init(model: model, estimatedUSD: usd, messages: 10)])
    }

    func testMergeFoldsMacsKeepsAccountsApartAndZeroFillsDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
        let a = report(days: 3, accounts: [bucket(1, alias: "Work", usd: 6, model: "claude-opus-4-1")],
                       daily: [.init(date: "2026-09-09", account: 1, estimatedUSD: 6, messages: 10)], unpriced: 5)
        let b = report(days: 3, accounts: [bucket(1, alias: "Home", usd: 3, model: "claude-opus-4-1"),
                                           bucket(2, alias: "Side", usd: 1, model: "claude-sonnet-4")],
                       daily: [.init(date: "2026-09-08", account: 1, estimatedUSD: 3, messages: 10),
                               .init(date: "2026-09-08", account: 2, estimatedUSD: 1, messages: 10)], unpriced: 7)
        let merged = T3UsageCost.merge([
            .init(macId: nil, macName: "Studio", provider: .claude, report: a),
            .init(macId: "m2", macName: "Air", provider: .claude, report: b),
        ], today: today, calendar: cal)!
        XCTAssertEqual(merged.costUsd, 10)
        XCTAssertEqual(merged.unpricedTokens, 12)
        XCTAssertEqual(merged.tokens, 3 * 5600)
        XCTAssertEqual(merged.accounts.map(\.name), ["Work · Studio", "Home · Air", "Side · Air"])
        XCTAssertEqual(merged.accounts.map(\.share), [0.6, 0.3, 0.1])
        XCTAssertEqual(merged.models.map(\.model), ["claude-opus-4-1", "claude-sonnet-4"])
        XCTAssertEqual(merged.models[0].costUsd, 9)
        XCTAssertEqual(merged.daily?.map(\.day), ["2026-09-07", "2026-09-08", "2026-09-09"])
        XCTAssertEqual(merged.daily?.map(\.values), [[0, 0], [0, 4], [6, 0]])
        XCTAssertEqual(merged.activeDays, 2)
        XCTAssertEqual(merged.seriesNames, ["Claude · Studio", "Claude · Air"])
    }

    func testAReportWithoutDailyRowsHasNoChart() {
        let r = report(days: 7, accounts: [bucket(1, alias: "Work", usd: 1, model: "m")], daily: nil)
        let merged = T3UsageCost.merge([.init(macId: nil, macName: "Studio", provider: .claude, report: r)])!
        XCTAssertNil(merged.daily)
        XCTAssertEqual(merged.accounts.map(\.name), ["Work"])
        XCTAssertEqual(merged.seriesNames, ["Claude"])
    }
}
