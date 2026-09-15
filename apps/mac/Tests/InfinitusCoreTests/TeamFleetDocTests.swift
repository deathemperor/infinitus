import XCTest
@testable import InfinitusCore

final class TeamFleetDocTests: XCTestCase {
    // The fold, snapshot and headroom cases return with TeamReader (slice 2); the control paths with slice 6.
    func account(_ n: Int, alias: String? = nil, email: String = "secret@example.com", status: String = "ok",
                 five: Double? = nil, seven: Double? = nil, scoped: [(String, Double)] = [],
                 plan: String? = "Max 20x", disabled: Bool? = nil) -> Account {
        let usage = (five == nil && seven == nil && scoped.isEmpty) ? nil : Usage(
            fiveHour: five.map { UsageWindow(pct: $0, resetsAt: "2026-09-06T13:00:00.254457+00:00") },
            sevenDay: seven.map { UsageWindow(pct: $0, resetsAt: "2026-09-08T11:00:00+00:00") },
            scoped: scoped.map { UsageWindow(pct: $0.1, resetsAt: "2026-09-08T11:00:00+00:00", name: $0.0) })
        return Account(number: n, email: email, active: false, usageStatus: status, usage: usage,
                       alias: alias, plan: plan, disabled: disabled)
    }

    func testRowLabelsStatusesAndWindowsAndNeverCarriesTheEmail() throws {
        let fleet = EngineFleet(engineID: "swapd", provider: .claude, accounts: [
            account(1, alias: "ann", five: 42, seven: 10, scoped: [("Fable", 95)]),
            account(2, five: 100, seven: 30),
            account(3, alias: "lee", status: "relogin_required"),
            account(4, alias: "pat", five: 12, disabled: true),
            account(5, alias: "sam", status: "api_key"),
        ], activeNumber: 1, nextCandidate: 5)
        let row = TeamDocs.FleetDoc.row(fleet, tokensPerMinute: 1234.5, lastSwitchAt: 77)
        XCTAssertEqual(row.engine, "swapd")
        XCTAssertEqual(row.active, "ann")
        XCTAssertEqual(row.next, "sam")
        XCTAssertEqual(row.tokensPerMinute, 1234.5)
        XCTAssertEqual(row.lastSwitchAt, 77)
        XCTAssertEqual(row.accounts.map(\.label), ["ann", "#2", "lee", "pat", "sam"])
        XCTAssertEqual(row.accounts.map(\.status), ["limited", "dead", "expiredLogin", "held", "ok"])
        XCTAssertEqual(row.accounts.map(\.active), [true, false, false, false, false])
        XCTAssertEqual(row.accounts[0].windows.map { "\($0.label):\($0.pct)" }, ["5h:42", "7d:10"])
        XCTAssertEqual(row.accounts[0].models.map { "\($0.label):\($0.pct)" }, ["Fable:95"])
        XCTAssertEqual(row.accounts[0].windows[0].resetsAt, 1788699600)
        XCTAssertEqual(row.accounts[0].tier, "Max 20x")
        XCTAssertEqual(row.accounts[4].windows, [])
        let json = String(decoding: try CanonicalJSON.encode(TeamDocs.FleetDoc(at: 1, fleets: [row])), as: UTF8.self)
        XCTAssertFalse(json.contains("example.com"), "the email never travels")
        XCTAssertFalse(json.contains("secret"))
    }

    func testFleetPathShapeNamesTheKindAndItsSender() {
        XCTAssertEqual(TeamKinds.expected(at: "m/k/fleet.json")?.kind, "fleet")
    }

}
