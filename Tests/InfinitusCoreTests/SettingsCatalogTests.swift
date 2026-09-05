import XCTest
@testable import InfinitusCore

final class SettingsCatalogTests: XCTestCase {
    func testEveryEntryHasUniqueID() {
        let ids = SettingsCatalog.entries.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count)
    }

    func testEmptyQueryMatchesEverything() {
        for entry in SettingsCatalog.entries {
            XCTAssertTrue(SettingsCatalog.matches(entry, query: ""))
            XCTAssertTrue(SettingsCatalog.matches(entry, query: "   "))
        }
        XCTAssertEqual(SettingsCatalog.filter("").count, SettingsCatalog.entries.count)
        XCTAssertEqual(SettingsCatalog.filter("   ").count, SettingsCatalog.entries.count)
    }

    func testTitleMatchIsCaseInsensitive() {
        guard let accounts = SettingsCatalog.entry(id: "accounts") else {
            XCTFail("Accounts entry missing")
            return
        }
        XCTAssertTrue(SettingsCatalog.matches(accounts, query: "acc"))
        XCTAssertTrue(SettingsCatalog.matches(accounts, query: "ACCOUNTS"))
        XCTAssertTrue(SettingsCatalog.matches(accounts, query: "Accounts"))
    }

    func testKeywordMatch() {
        let tailscaleMatches = SettingsCatalog.filter("tailscale")
        XCTAssertEqual(tailscaleMatches.map(\.id), ["devices"])

        let pypiMatches = SettingsCatalog.filter("pypi")
        XCTAssertEqual(pypiMatches.map(\.id), ["cswap"])
    }

    func testEngineSectionIsExactlyThree() {
        let engines = SettingsCatalog.entries.filter(\.engine)
        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engines.map(\.id), ["cswap", "cliproxy", "9router"])
    }

    func testOrderMatchesTheMacSidebar() {
        let expectedIDs = [
            "display",
            "accounts",
            "themes",
            "push",
            "usage",
            "utilization",
            "stats",
            "activity",
            "devices",
            "about",
            "cswap",
            "cliproxy",
            "9router"
        ]
        XCTAssertEqual(SettingsCatalog.entries.map(\.id), expectedIDs)
    }
}
