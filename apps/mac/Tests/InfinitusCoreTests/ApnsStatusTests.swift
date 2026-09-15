import XCTest
@testable import InfinitusCore

final class ApnsStatusTests: XCTestCase {
    private func registration(_ name: String, id: String, kind: ActivityPushRegistration.Kind, token: String) -> ActivityPushRegistration {
        ActivityPushRegistration(kind: kind, token: token, deviceId: id, deviceName: name,
                                 environment: "production", themeID: nil,
                                 registeredAt: Date(timeIntervalSince1970: 1_757_000_000))
    }

    func testTheReplyNamesEveryPhoneAndKindAndNeverAToken() throws {
        let fields = ApnsStatus.fields(
            keyPresent: true, teamId: "TEAM123456", keyId: "KEY1234567",
            registrations: [
                registration("Zed's phone", id: "dev-z", kind: .alert, token: "deadbeef01"),
                registration("Ada's phone", id: "dev-a", kind: .agentActivity, token: "deadbeef02"),
                registration("Ada's phone", id: "dev-a", kind: .alert, token: "deadbeef03"),
            ])
        XCTAssertEqual(fields["keyPresent"], .bool(true))
        XCTAssertEqual(fields["teamId"], .string("TEAM123456"))
        XCTAssertEqual(fields["keyId"], .string("KEY1234567"))
        guard case .array(let rows)? = fields["registrations"] else { return XCTFail("registrations") }
        XCTAssertEqual(rows.count, 3)
        // Sorted by phone, then kind: a page lists one phone's kinds together.
        XCTAssertEqual(rows.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let name)? = o["deviceName"], case .string(let kind)? = o["kind"] else { return nil }
            return "\(name)/\(kind)"
        }, ["Ada's phone/agent-activity", "Ada's phone/alert", "Zed's phone/alert"])
        guard case .object(let first) = rows[0] else { return XCTFail("row") }
        XCTAssertEqual(first["deviceId"], .string("dev-a"))
        XCTAssertEqual(first["environment"], .string("production"))
        XCTAssertEqual(first["registeredAt"], .string("2025-09-04T15:33:20Z"))
        XCTAssertNil(first["token"])
        let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("deadbeef"))
    }

    /// #1272 follow-up: the last push's outcome rides the row it was for.
    func testTheLastPushRidesItsRowAndOthersCarryNone() throws {
        let ada = registration("Ada's phone", id: "dev-a", kind: .agentActivityStart, token: "deadbeef04")
        let alert = registration("Ada's phone", id: "dev-a", kind: .alert, token: "deadbeef05")
        let fields = ApnsStatus.fields(
            keyPresent: true, teamId: "T", keyId: "K", registrations: [ada, alert],
            lastPushes: [
                ada.slot: .init(at: Date(timeIntervalSince1970: 1_757_000_060), outcome: .landed),
                "dev-gone/alert": .init(at: Date(timeIntervalSince1970: 1_757_000_061), outcome: .failed,
                                        detail: "HTTP 410 Unregistered"),
            ])
        guard case .array(let rows)? = fields["registrations"], rows.count == 2,
              case .object(let start) = rows[0], case .object(let alertRow) = rows[1]
        else { return XCTFail("rows") }
        XCTAssertEqual(start["lastPush"], .object([
            "at": .string("2025-09-04T15:34:20Z"), "kind": .string("agent-activity-start"), "outcome": .string("landed"),
        ]))
        XCTAssertNil(alertRow["lastPush"])
        let failed = ApnsStatus.fields(
            keyPresent: true, teamId: "T", keyId: "K", registrations: [alert],
            lastPushes: [alert.slot: .init(at: Date(timeIntervalSince1970: 1_757_000_061), outcome: .failed,
                                           detail: "HTTP 410 Unregistered")])
        guard case .array(let failedRows)? = failed["registrations"], case .object(let row) = failedRows[0],
              case .object(let push)? = row["lastPush"]
        else { return XCTFail("failed row") }
        XCTAssertEqual(push["outcome"], .string("failed"))
        XCTAssertEqual(push["detail"], .string("HTTP 410 Unregistered"))
        let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(failed)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("deadbeef"))
    }

    func testAnUnconfiguredMacReadsEmpty() {
        let fields = ApnsStatus.fields(keyPresent: false, teamId: "", keyId: "", registrations: [])
        XCTAssertEqual(fields["keyPresent"], .bool(false))
        XCTAssertEqual(fields["registrations"], .array([]))
    }
}
