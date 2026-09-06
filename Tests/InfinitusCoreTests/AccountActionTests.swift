import XCTest
@testable import InfinitusCore

final class AccountActionTests: XCTestCase {
    func testRequestAndReplyRoundTrip() throws {
        let request = AccountAction.Request(fleet: "cswap/claude", number: 3, action: "prefer")
        let back = try JSONDecoder().decode(AccountAction.Request.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(back, request)
        let reply = AccountAction.Reply(outcome: "unsupported", detail: "no pick-first")
        XCTAssertEqual(try JSONDecoder().decode(AccountAction.Reply.self, from: JSONEncoder().encode(reply)), reply)
    }

    /// An older Mac's snapshot has no `capabilities` on its fleets — the
    /// phone decodes it and offers nothing; a newer one carries them.
    func testEngineFleetCapabilitiesAreOptional() throws {
        let legacy = """
        {"engineID":"cswap","provider":"claude","accounts":[]}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(EngineFleet.self, from: legacy)
        XCTAssertNil(old.capabilities)
        let stamped = old.with(capabilities: [.hold, .prefer])
        let back = try JSONDecoder().decode(EngineFleet.self, from: JSONEncoder().encode(stamped))
        XCTAssertEqual(back.capabilities, [.hold, .prefer])
        XCTAssertEqual(back.key, "cswap/claude")
    }
}
