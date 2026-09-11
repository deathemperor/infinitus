import XCTest
@testable import InfinitusCore

final class TeamNearbyManifestTests: XCTestCase {
    func testTeamDiscoverableIsInTheManifest() {
        let command = ControlCommand.named("team-discoverable")
        XCTAssertEqual(command?.args, ["on|off"])
        XCTAssertEqual(command?.effect, .write)
        XCTAssertEqual(command?.replyShape, "{discoverable}")
    }
}
