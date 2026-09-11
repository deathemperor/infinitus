import XCTest
@testable import InfinitusCore

final class FleetAlarmsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func account(_ n: Int, five: Double, resets: Date?, alias: String? = nil,
                         disabled: Bool? = nil) -> Account {
        let usage = Usage(fiveHour: UsageWindow(pct: five, resetsAt: resets.map(iso)),
                          sevenDay: UsageWindow(pct: 20, resetsAt: resets.map(iso)))
        return Account(number: n, email: "p\(n)@x.com", usage: usage, alias: alias, disabled: disabled)
    }

    func testExhaustedAccountAlarmsTenMinutesBeforeItsReset() {
        let reset = now.addingTimeInterval(3 * 3600)
        let alarms = FleetAlarms.resets(accounts: [account(1, five: 100, resets: reset, alias: "papaya"),
                                                   account(2, five: 40, resets: reset)], now: now)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].id, "reset-1")
        XCTAssertEqual(alarms[0].fireAt, reset.addingTimeInterval(-FleetAlarms.lead))
        XCTAssertEqual(alarms[0].title, "papaya resets in 10 min")
        XCTAssertTrue(alarms[0].body.hasPrefix("the session limit lifts at "))
    }

    func testLeadIsAKnobAndNamesItselfInTheTitle() {
        let reset = now.addingTimeInterval(3 * 3600)
        let alarms = FleetAlarms.resets(accounts: [account(1, five: 100, resets: reset, alias: "papaya")],
                                        now: now, lead: 30 * 60)
        XCTAssertEqual(alarms.map(\.fireAt), [reset.addingTimeInterval(-30 * 60)])
        XCTAssertEqual(alarms[0].title, "papaya resets in 30 min")
        // A reset inside a long lead plans nothing, same as inside the default.
        XCTAssertEqual(FleetAlarms.resets(accounts: [account(1, five: 100, resets: now.addingTimeInterval(20 * 60))],
                                          now: now, lead: 30 * 60), [])
    }

    func testResetInsideTheLeadWindowDisabledAndNoResetInstantPlanNothing() {
        XCTAssertEqual(FleetAlarms.resets(accounts: [
            account(1, five: 100, resets: now.addingTimeInterval(5 * 60)),
            account(2, five: 100, resets: now.addingTimeInterval(3600), disabled: true),
            account(3, five: 100, resets: nil),
        ], now: now), [])
    }

    func testSwapOnlyBetweenTwoLooksOfKnownAccounts() {
        let fleet = [account(1, five: 0, resets: nil, alias: "papaya"), account(2, five: 0, resets: nil)]
        XCTAssertNil(FleetAlarms.swap(from: nil, to: 1, accounts: fleet))
        XCTAssertNil(FleetAlarms.swap(from: 1, to: 1, accounts: fleet))
        XCTAssertNil(FleetAlarms.swap(from: 1, to: 9, accounts: fleet))
        let swap = FleetAlarms.swap(from: 2, to: 1, accounts: fleet)
        XCTAssertEqual(swap?.title, "swapped to papaya")
        XCTAssertNil(swap?.fireAt)
    }
}
