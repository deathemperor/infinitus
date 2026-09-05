import XCTest
@testable import InfinitusCore
@testable import InfinitusWinUI

final class SyncSnapshotWinTests: XCTestCase {
    func testSyncSnapshotRoundTripWithWinSettings() throws {
        var winSettings = WinSettings()
        winSettings.titlePct = "7d"
        winSettings.showAccountName = false
        winSettings.mirrorPort = 48000
        winSettings.gamificationStyle = "rpg"

        let winData = try JSONEncoder().encode(winSettings)
        let appDict = try JSONDecoder().decode([String: JSONValue].self, from: winData)

        let snapshot = SyncSnapshot(
            app: appDict,
            themes: [RowTheme.rpg, RowTheme.hades],
            engine: ["autoswitch.threshold": "95", "autoswitch.strategy": "best"]
        )

        let snapshotData = try snapshot.encoded()
        guard let decoded = SyncSnapshot.decode(snapshotData) else {
            XCTFail("Failed to decode SyncSnapshot")
            return
        }

        XCTAssertEqual(decoded.engine["autoswitch.threshold"], "95")
        XCTAssertEqual(decoded.themes.count, 2)
        XCTAssertEqual(decoded.themes.map(\.id), ["rpg", "hades"])

        let reencodedAppData = try JSONEncoder().encode(decoded.app)
        let decodedWinSettings = try JSONDecoder().decode(WinSettings.self, from: reencodedAppData)
        XCTAssertEqual(decodedWinSettings.titlePct, "7d")
        XCTAssertEqual(decodedWinSettings.showAccountName, false)
        XCTAssertEqual(decodedWinSettings.mirrorPort, 48000)
        XCTAssertEqual(decodedWinSettings.gamificationStyle, "rpg")
    }

    func testMacExportFixtureImportsWithoutError() throws {
        // Mac export json structure
        let macExportJSON = """
        {
          "app": {
            "title_pct": "5h",
            "show_account_name": true,
            "gamification_style": "movie",
            "unknown_mac_key_should_be_ignored": 12345
          },
          "engine": {
            "autoswitch.threshold": "88"
          },
          "themes": []
        }
        """

        guard let snapshot = SyncSnapshot.decode(Data(macExportJSON.utf8)) else {
            XCTFail("Failed to decode Mac snapshot")
            return
        }

        XCTAssertEqual(snapshot.engine["autoswitch.threshold"], "88")
        let appData = try JSONEncoder().encode(snapshot.app)
        let winSettings = try JSONDecoder().decode(WinSettings.self, from: appData)
        XCTAssertEqual(winSettings.titlePct, "5h")
        XCTAssertEqual(winSettings.showAccountName, true)
        XCTAssertEqual(winSettings.gamificationStyle, "movie")
    }
}
