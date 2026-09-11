import XCTest
@testable import InfinitusCore

final class PairedPhoneTests: XCTestCase {
    private func client(_ id: String, name: String = "iPhone", route: String = "Wi-Fi", at seconds: TimeInterval) -> MirrorClient {
        MirrorClient(id: id, name: name, route: route, lastSeen: Date(timeIntervalSince1970: seconds))
    }

    func testAPhoneIsRecordedOnceAndOnlyMaterialChangesPersist() {
        let first = PairedPhones.merge(client("a", at: 100), into: [])
        XCTAssertTrue(first.changed, "a new phone is written")
        XCTAssertEqual(first.list.map(\.id), ["a"])
        XCTAssertEqual(first.list[0].firstSeen, Date(timeIntervalSince1970: 100))
        // A poll 5 s later moves lastSeen in memory but is not worth a write.
        let soon = PairedPhones.merge(client("a", at: 105), into: first.list)
        XCTAssertFalse(soon.changed)
        XCTAssertEqual(soon.list[0].lastSeen, Date(timeIntervalSince1970: 105))
        XCTAssertEqual(soon.list[0].firstSeen, Date(timeIntervalSince1970: 100), "firstSeen never moves")
        // A minute on, or a new name or route, is.
        XCTAssertTrue(PairedPhones.merge(client("a", at: 165), into: first.list).changed)
        XCTAssertTrue(PairedPhones.merge(client("a", name: "Loc's iPhone", at: 101), into: first.list).changed)
        XCTAssertTrue(PairedPhones.merge(client("a", route: "Tailscale", at: 101), into: first.list).changed)
        XCTAssertEqual(PairedPhones.merge(client("a", name: "Loc's iPhone", at: 101), into: first.list).list[0].name, "Loc's iPhone")
    }

    func testSeveralPhonesNewestFirstAndForgetDropsOne() {
        var list = PairedPhones.merge(client("a", at: 100), into: []).list
        list = PairedPhones.merge(client("b", name: "iPad", at: 200), into: list).list
        XCTAssertEqual(list.map(\.id), ["b", "a"])
        list = PairedPhones.merge(client("a", at: 300), into: list).list
        XCTAssertEqual(list.map(\.id), ["a", "b"], "the phone heard from last comes first")
        XCTAssertEqual(PairedPhones.forget(id: "b", in: list).map(\.id), ["a"])
        XCTAssertEqual(PairedPhones.forget(id: "zzz", in: list).count, 2)
    }

    func testARecordRoundTripsAndIsActiveInsideTheWindow() throws {
        let phone = PairedPhone(id: "a", name: "iPhone", route: "Wi-Fi",
                                firstSeen: Date(timeIntervalSince1970: 1), lastSeen: Date(timeIntervalSince1970: 100))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([PairedPhone].self, from: try encoder.encode([phone])), [phone])
        XCTAssertTrue(phone.isActive(now: Date(timeIntervalSince1970: 100 + MirrorClient.activeWindow - 1)))
        XCTAssertFalse(phone.isActive(now: Date(timeIntervalSince1970: 100 + MirrorClient.activeWindow)))
    }

    func testPushSummaryNamesWhatThePhoneHolds() {
        XCTAssertEqual(PairedPhones.pushSummary([.working, .workingStart, .revivalStart, .alert]), "lock-screen cards + alerts")
        XCTAssertEqual(PairedPhones.pushSummary([.revivalStart]), "lock-screen cards")
        XCTAssertEqual(PairedPhones.pushSummary([.alert]), "alerts")
        XCTAssertEqual(PairedPhones.pushSummary([]), "no push tokens")
    }
}
