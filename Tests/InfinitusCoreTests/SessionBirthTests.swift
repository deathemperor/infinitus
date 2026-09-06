import XCTest
@testable import InfinitusCore

/// Session birth records (#163 / #165): what a started session runs as.
final class SessionBirthTests: XCTestCase {
    func testAHookModeMovesTheChipAndTheStartModeStaysTheFloor() throws {
        let born = SessionBirth(profile: "Review", permissionMode: "acceptEdits")
        let moved = born.moved(to: "bypassPermissions")
        XCTAssertEqual(moved.chip, "Review · Full access")
        XCTAssertTrue(moved.isUnrestricted)
        XCTAssertEqual(moved.permissionMode, "acceptEdits")
        XCTAssertEqual(moved.identified(as: "sid").moved(to: nil).sessionId, "sid")
        XCTAssertEqual(moved.moved(to: nil).chip, "Review · Auto-accept edits")
        XCTAssertLessThan(SessionStart.modeRank(nil), SessionStart.modeRank("acceptEdits"))
        XCTAssertLessThan(SessionStart.modeRank("auto"), SessionStart.modeRank("bypassPermissions"))
        // A record written before hookMode existed still decodes.
        let old = try JSONDecoder().decode(SessionBirth.self, from: Data(#"{"permissionMode":"auto"}"#.utf8))
        XCTAssertEqual(old.effectiveMode, "auto")
    }

    func testBirthComesFromTheStartRequest() {
        XCTAssertNil(SessionBirth(request: .init(cwd: "/r")))
        XCTAssertNil(SessionBirth(request: .init(cwd: "/r", permissionMode: "nonsense")))
        let born = SessionBirth(request: .init(cwd: "/r", permissionMode: "bypassPermissions", profile: "Review"))
        XCTAssertEqual(born?.chip, "Review · Full access")
        XCTAssertEqual(born?.isUnrestricted, true)
        XCTAssertEqual(SessionBirth(request: .init(cwd: "/r", resume: "abc"))?.chip, "resumed")
        XCTAssertEqual(SessionBirth(request: .init(cwd: "/r", resume: "abc", permissionMode: "acceptEdits"))?.chip,
                       "Auto-accept edits")
    }

    func testStoreRoundTripsAndPrunesDeadPids() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-births-\(UUID().uuidString)/session-births.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(SessionBirths.load(from: url), [:])
        let births = [41: SessionBirth(profile: "Ship"), 42: SessionBirth(permissionMode: "auto")]
        try SessionBirths.save(births, to: url)
        XCTAssertEqual(SessionBirths.load(from: url), births)
        XCTAssertEqual(SessionBirths.pruned(births, alive: [42, 43]), [42: SessionBirth(permissionMode: "auto")])
    }

    func testOlderSnapshotWithoutBirthsDecodes() throws {
        let json = #"{"capturedAt":"2026-09-06T00:00:00Z","machineName":"m","listJSON":"e30=","sessions":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(MirrorSnapshot.self, from: Data(json.utf8)).births)
    }
}
