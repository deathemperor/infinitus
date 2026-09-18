import XCTest
import InfinitusCore

final class NineRouterUsageTests: XCTestCase {
    private let now = WeeklyRoll.parse("2026-09-18T03:00:00Z")!

    private func usage(used: Double, reset: String) throws -> Usage {
        let json = """
        {"quotas": {
          "session (5h)": {"used": \(used), "resetAt": "\(reset)"},
          "weekly (7d)": {"used": 0, "resetAt": "\(reset)"},
          "weekly fable (7d)": {"used": 0, "resetAt": "\(reset)"}
        }}
        """
        guard case .ok(let usage, _) = NineRouterUsage.parse(Data(json.utf8), now: now) else {
            XCTFail("expected quotas")
            return Usage()
        }
        return try XCTUnwrap(usage)
    }

    func testExpiredEmptySessionHasNoResetLabel() throws {
        for reset in ["2026-09-18T01:50:00.151Z", "2026-09-18T03:00:00Z"] {
            let parsed = try usage(used: 0, reset: reset)
            let session = try XCTUnwrap(parsed.fiveHour)
            XCTAssertEqual(session.pct, 0)
            XCTAssertNil(session.resetsAt)
            XCTAssertNil(session.countdown)
            XCTAssertNil(session.clock)
            XCTAssertNil(ResetLabel.label(session, now: now))
            // Weekly/model resets are fixed slots, not idle session timers.
            XCTAssertEqual(parsed.sevenDay?.resetsAt, reset)
            XCTAssertEqual(parsed.scoped?.first?.resetsAt, reset)
        }
    }

    func testEmptySessionKeepsAResetStillAhead() throws {
        let reset = "2026-09-18T04:00:00Z"
        let session = try XCTUnwrap(usage(used: 0, reset: reset).fiveHour)
        XCTAssertEqual(session.resetsAt, reset)
        XCTAssertEqual(session.countdown, "1h 0m")
        XCTAssertNotNil(ResetLabel.label(session, now: now))
    }

    func testUsedSessionKeepsItsResetWhileAwaitingNewUsage() throws {
        let reset = "2026-09-18T01:50:00.151Z"
        for used in [1.0, 100.0] {
            let session = try XCTUnwrap(usage(used: used, reset: reset).fiveHour)
            XCTAssertEqual(session.pct, used)
            XCTAssertEqual(session.resetsAt, reset)
            XCTAssertNotNil(session.clock)
        }
    }
}
