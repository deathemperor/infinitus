import XCTest
@testable import InfinitusCore

final class RevivalProbeTests: XCTestCase {
    private func account(_ n: Int, fiveHour: (Double, String)?, sevenDay: (Double, String)?, disabled: Bool = false) -> Account {
        var json = "{\"number\": \(n), \"email\": \"a\(n)@x.com\", \"organizationName\": \"\", \"organizationUuid\": \"\", \"isOrganization\": false, \"active\": false, \"usageStatus\": \"ok\""
        if disabled { json += ", \"disabled\": true" }
        var usage: [String] = []
        if let (pct, reset) = fiveHour { usage.append("\"fiveHour\": {\"pct\": \(pct), \"resetsAt\": \"\(reset)\"}") }
        if let (pct, reset) = sevenDay { usage.append("\"sevenDay\": {\"pct\": \(pct), \"resetsAt\": \"\(reset)\"}") }
        json += ", \"usage\": {\(usage.joined(separator: ", "))}}"
        return try! JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    func testNextResetIsTheSoonestDeadAccountsLastMaxedWindow() {
        let a = account(1, fiveHour: (100, iso(600)), sevenDay: (100, iso(7200)))   // back at +7200
        let b = account(2, fiveHour: (100, iso(900)), sevenDay: (40, iso(50_000)))  // back at +900
        let c = account(3, fiveHour: (20, iso(300)), sevenDay: (30, iso(50_000)))   // alive
        let d = account(4, fiveHour: (100, iso(100)), sevenDay: nil, disabled: true)
        XCTAssertEqual(RevivalProbe.nextReset(accounts: [a, b, c, d], now: now)?.timeIntervalSince(now) ?? -1, 900, accuracy: 1)
        XCTAssertNil(RevivalProbe.nextReset(accounts: [c], now: now))
    }

    func testScheduleStartsPastTheEngineSlackAndRetries() {
        let reset = now.addingTimeInterval(600)
        let probes = RevivalProbe.schedule(reset: reset, now: now)
        XCTAssertEqual(probes.count, 3)
        XCTAssertEqual(probes[0].timeIntervalSince(now), 665, accuracy: 0.1)
        XCTAssertEqual(probes[1].timeIntervalSince(probes[0]), 65, accuracy: 0.1)
        // A reset that already passed probes from now on.
        let late = RevivalProbe.schedule(reset: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(late[0].timeIntervalSince(now), 5, accuracy: 0.1)
    }

    func testEarlyRevivalMeansTheDueTimeWasStillWellAhead() {
        let dueLater = account(1, fiveHour: (100, iso(3600)), sevenDay: nil)
        let dueNow = account(2, fiveHour: (100, iso(30)), sevenDay: nil)
        XCTAssertTrue(RevivalProbe.wasEarly(previous: dueLater, now: now))
        XCTAssertFalse(RevivalProbe.wasEarly(previous: dueNow, now: now))
        XCTAssertFalse(RevivalProbe.wasEarly(previous: nil, now: now))
    }
}
