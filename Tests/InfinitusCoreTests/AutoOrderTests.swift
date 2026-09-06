import XCTest
@testable import InfinitusCore

final class AutoOrderTests: XCTestCase {
    typealias Row = AutoOrder.Row

    func testMostHeadroomFirst() {
        let rows = [Row(number: 1, rank: .alive, bindingPct: 80),
                    Row(number: 2, rank: .alive, bindingPct: 20),
                    Row(number: 3, rank: .alive, bindingPct: 50)]
        XCTAssertEqual(AutoOrder.order(rows), [2, 3, 1])
    }

    func testSmallDifferencesKeepTheIncumbentOrder() {
        // 44 vs 41: within the margin — no write for a flicker.
        let rows = [Row(number: 1, rank: .alive, bindingPct: 44),
                    Row(number: 2, rank: .alive, bindingPct: 41)]
        XCTAssertEqual(AutoOrder.order(rows), [1, 2])
        // At the margin it moves.
        let moved = [Row(number: 1, rank: .alive, bindingPct: 46),
                     Row(number: 2, rank: .alive, bindingPct: 41)]
        XCTAssertEqual(AutoOrder.order(moved), [2, 1])
    }

    func testRanksAliveUnknownDeadDisabled() {
        let soon = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let rows = [Row(number: 1, rank: .disabled),
                    Row(number: 2, rank: .dead, recovery: late),
                    Row(number: 3, rank: .unknown),
                    Row(number: 4, rank: .dead, recovery: soon),
                    Row(number: 5, rank: .alive, bindingPct: 99),
                    Row(number: 6, rank: .dead)]
        XCTAssertEqual(AutoOrder.order(rows), [5, 3, 4, 2, 6, 1])
    }

    func testUnknownRowsStayInPlaceAmongThemselves() {
        let rows = [Row(number: 3, rank: .unknown), Row(number: 1, rank: .unknown)]
        XCTAssertEqual(AutoOrder.order(rows), [3, 1])
    }

    func testRowFromAccountIgnoresSpend() throws {
        // Rested windows, spent credit: alive with plenty of headroom,
        // never dead — the engine had exactly this regression.
        let json = """
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
          {"number":1,"email":"a@x","organizationName":"","organizationUuid":"",
           "isOrganization":false,"active":true,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":0},"sevenDay":{"pct":1},
                    "spend":{"used":50,"limit":50,"pct":100,"currency":"USD"}}},
          {"number":2,"email":"b@x","organizationName":"","organizationUuid":"",
           "isOrganization":false,"active":false,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":30},"sevenDay":{"pct":100,
                    "resetsAt":"2026-09-01T00:00:00Z"},
                    "scoped":[{"pct":100,"resetsAt":"2026-09-03T00:00:00Z","name":"Fable"}]}},
          {"number":3,"email":"c@x","organizationName":"","organizationUuid":"",
           "isOrganization":false,"active":false,"usageStatus":"unavailable",
           "disabled":true}
        ]}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        let rows = list.accounts.map(AutoOrder.row)
        XCTAssertEqual(rows[0], Row(number: 1, rank: .alive, bindingPct: 1))
        XCTAssertEqual(rows[1].rank, .dead)
        // The LAST exhausted window governs recovery.
        XCTAssertEqual(rows[1].recovery, WeeklyRoll.parse("2026-09-03T00:00:00Z"))
        XCTAssertEqual(rows[2].rank, .disabled)
        XCTAssertEqual(AutoOrder.order(list.accounts), [1, 2, 3])
    }
}

final class DisplayOrderTests: XCTestCase {
    private func acct(_ n: Int, five: Double? = nil, disabled: Bool? = nil) -> Account {
        let json = """
        {"number": \(n), "email": "a\(n)@x.com", "active": false,
         "organizationName": "o", "organizationUuid": "u",
         "isOrganization": false,
         "usageStatus": "ok"\(disabled == true ? ", \"disabled\": true" : "")
         \(five != nil ? ", \"usage\": {\"fiveHour\": {\"pct\": \(five!)}}" : "")}
        """
        return try! JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    func testActiveAndNextPinThenHeadroom() {
        let accounts = [acct(1, five: 80), acct(2, five: 10),
                        acct(3, five: 40), acct(4, five: 90),
                        acct(5, disabled: true)]
        let sorted = DisplayOrder.sort(accounts, active: 4, next: 3)
        XCTAssertEqual(sorted.map(\.number), [4, 3, 2, 1, 5])
    }

    func testReviverTakesTheNextSlotWhileAllDead() {
        let accounts = [acct(1, five: 100), acct(2, five: 100), acct(3, five: 100)]
        XCTAssertEqual(DisplayOrder.sort(accounts, active: 1, next: nil, reviver: 3)
                        .map(\.number), [1, 3, 2])
    }

    func testNoPinsFallsBackToHeadroom() {
        let accounts = [acct(1, five: 80), acct(2, five: 10)]
        XCTAssertEqual(DisplayOrder.sort(accounts, active: nil, next: nil)
                        .map(\.number), [2, 1])
    }
}
