import XCTest
@testable import InfinitusMobile

final class LiveActivitiesTests: XCTestCase {
    /// A card is a Mac's by its key when it has one, else by its name
    /// (#144): two Macs sharing a name keep their cards apart once keyed,
    /// and a keyless card from before the key still finds its Mac.
    func testACardBelongsToItsMacByKeyElseByName() {
        let key = NetworkFleetMirror.parkedKey(token: "tok-a"), other = NetworkFleetMirror.parkedKey(token: "tok-b")
        XCTAssertNotEqual(key, other)
        XCTAssertTrue(LiveActivities.owns(cardMacId: key, cardMachine: "Titan", key: key, machine: "Titan"))
        XCTAssertTrue(LiveActivities.owns(cardMacId: key, cardMachine: "Old Name", key: key, machine: "Titan"), "a rename keeps the card")
        XCTAssertFalse(LiveActivities.owns(cardMacId: other, cardMachine: "Titan", key: key, machine: "Titan"), "the other Mac wearing the same name")
        XCTAssertTrue(LiveActivities.owns(cardMacId: nil, cardMachine: "Titan", key: key, machine: "Titan"), "keyless: by name")
        XCTAssertFalse(LiveActivities.owns(cardMacId: nil, cardMachine: "Atlas", key: key, machine: "Titan"))
        XCTAssertFalse(LiveActivities.owns(cardMacId: nil, cardMachine: "Titan", key: key, machine: ""), "forgetting by key alone leaves keyless cards")
    }
}
