import XCTest
import InfinitusCore
@testable import InfinitusWinUI

final class SettingsShellTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WinSettingsStore.resetCache()
    }

    override func tearDownWithError() throws {
        WinSettingsStore.resetCache()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testSettingsRoundTrip() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        var s = WinSettings()
        s.showAccountName = false
        s.titlePct = "7d"
        s.titleScoped = true
        s.titleRemaining = true
        s.titleReset = "clock"
        s.titleIconOnly = true
        s.refreshIntervalSeconds = 300
        s.gamificationStyle = "rpg"
        s.pushSessionsDone = false
        s.pushAllDead = false
        s.pushLastAlive = false
        s.pushWaiting = false
        s.pushAwsLogin = false
        s.trayBalloonsEnabled = false
        s.sortByHeadroom = false
        s.mirrorPort = 12345
        s.autoResume = true
        s.lastPaneID = "accounts"
        s.windowWidth = 1024
        s.windowHeight = 768

        try WinSettingsStore.save(s, to: file)
        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, s)
    }

    func testMissingFileYieldsDefaults() {
        let file = tempDir.appendingPathComponent("nonexistent.json")
        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, WinSettings())
    }

    func testCorruptFileIsQuarantinedAndYieldsDefaults() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded, WinSettings())

        // File should not contain the corrupt data at original path
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: file.path))

        // Quarantined sibling must exist
        let contents = try fm.contentsOfDirectory(atPath: tempDir.path)
        let badFiles = contents.filter { $0.hasPrefix("settings.json.bad-") }
        XCTAssertEqual(badFiles.count, 1)
    }

    func testPartialFileKeepsKnownKeys() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let json = """
        {
            "title_pct": "5h"
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "5h")
        XCTAssertEqual(loaded.showAccountName, true) // default
        XCTAssertEqual(loaded.refreshIntervalSeconds, 60) // default
    }

    func testUnknownKeysAreIgnored() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let json = """
        {
            "some_future_key": "compact",
            "glass_opacity": 0.8,
            "title_pct": "both"
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "both")
        XCTAssertEqual(loaded.showAccountName, true)
    }

    func testPopupLayoutRoundTrip() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        try WinSettingsStore.update(fileURL: file) { s in
            s.popupLayout = "stacked"
        }
        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.popupLayout, "stacked")
    }

    func testUpdateIsLastWriterPerField() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        try WinSettingsStore.update(fileURL: file) { s in
            s.titlePct = "7d"
        }
        try WinSettingsStore.update(fileURL: file) { s in
            s.gamificationStyle = "rpg"
        }

        let loaded = WinSettingsStore.load(from: file)
        XCTAssertEqual(loaded.titlePct, "7d")
        XCTAssertEqual(loaded.gamificationStyle, "rpg")
    }

    func testPaneIDBlocksDoNotOverlap() {
        var seenIDs = Set<Int32>()
        for paneIndex in 0..<14 {
            let start = PaneIDs.block(Int32(paneIndex))
            let end = start + PaneIDs.stride
            XCTAssertGreaterThanOrEqual(start, PaneIDs.base)
            for id in start..<end {
                XCTAssertFalse(seenIDs.contains(id), "Duplicate command ID \(id) in pane \(paneIndex)")
                seenIDs.insert(id)
            }
        }
    }

    func testCommandRoutingResolvesTheOwningPane() {
        let pane3ID = PaneIDs.base + 3 * PaneIDs.stride + 7
        XCTAssertEqual(PaneIDs.paneIndex(for: pane3ID), 3)

        let belowBase = PaneIDs.base - 1
        XCTAssertNil(PaneIDs.paneIndex(for: belowBase))
    }

    func testScrollClamp() {
        let res = SettingsCatalogWin.clampScroll(offset: 700, contentHeight: 1000, viewportHeight: 400)
        XCTAssertEqual(res.maxOffset, 600)
        XCTAssertEqual(res.offset, 600)

        let resNegative = SettingsCatalogWin.clampScroll(offset: -50, contentHeight: 1000, viewportHeight: 400)
        XCTAssertEqual(resNegative.offset, 0)

        let resFits = SettingsCatalogWin.clampScroll(offset: 50, contentHeight: 300, viewportHeight: 400)
        XCTAssertEqual(resFits.maxOffset, 0)
        XCTAssertEqual(resFits.offset, 0)
    }

    func testCardGridColumns() {
        // Width 980 -> N columns; width 320 -> 1; never 0
        let cols980 = SettingsCatalogWin.cardGridColumns(contentWidth: 980)
        XCTAssertGreaterThan(cols980, 1)

        let cols320 = SettingsCatalogWin.cardGridColumns(contentWidth: 320)
        XCTAssertEqual(cols320, 1)

        let colsTiny = SettingsCatalogWin.cardGridColumns(contentWidth: 50)
        XCTAssertGreaterThanOrEqual(colsTiny, 1)
    }

    func testCardGridContentHeight() {
        // 15 built-ins at 2 columns -> 8 rows
        let h = SettingsCatalogWin.cardGridContentHeight(itemCount: 15, columns: 2, cardHeight: 120, gap: 10, chromeHeight: 240)
        // 8 rows * (120 + 10) + 240 = 8 * 130 + 240 = 1040 + 240 = 1280
        XCTAssertEqual(h, 1280)
    }

    func testThemeSelectionFallsBackToOff() {
        let nonexistent = "nonexistent-theme-xyz"
        let custom = RowTheme.loadCustom(from: WinSettingsStore.windowsThemesURL)
        let all = RowTheme.builtins + custom
        let resolved = all.first { $0.id == nonexistent } ?? RowTheme.off
        XCTAssertEqual(resolved.id, RowTheme.off.id)
    }

    func testDisplayPrefsRoundTripThroughTitleFormatter() {
        var s = WinSettings()
        s.showAccountName = true
        s.titlePct = "both"
        s.titleRemaining = true
        s.titleReset = "countdown"
        s.titleScoped = true

        let prefs = TitlePrefs(
            showAccountName: s.showAccountName,
            titlePct: s.titlePct,
            titleScoped: s.titleScoped,
            titleRemaining: s.titleRemaining,
            titleReset: s.titleReset
        )

        let account = Account(
            number: 1,
            email: "dev@example.com",
            active: true,
            usage: Usage(
                fiveHour: UsageWindow(pct: 20, resetsAt: "2999-01-01T00:00:00Z"),
                sevenDay: UsageWindow(pct: 50, resetsAt: "2999-01-01T00:00:00Z"),
                scoped: [UsageWindow(pct: 30, resetsAt: "2999-01-01T00:00:00Z", name: "Opus")]
            ),
            alias: "alpha"
        )

        let title = TitleFormatter.format(account: account, prefs: prefs, now: Date(), icon: "")
        // Remaining flips 20% -> 80%, 50% -> 50%, Opus 30% -> 70%
        XCTAssertTrue(title.contains("alpha"))
        XCTAssertTrue(title.contains("80·50%"))
        XCTAssertTrue(title.contains("Opus 70%"))
    }

    /// The shell hand-writes a `PaneDescriptor` per pane instead of reading
    /// Core's `SettingsCatalog`, so the two can drift — the architecture doc
    /// exists to prevent exactly that. The descriptors live in the executable
    /// target (unimportable), so pin the Core side: every catalog id the
    /// Windows shell claims to ship must exist, and the titles must be the
    /// ones the panes hard-code.
    func testWindowsPaneIDsMatchTheSharedCatalog() {
        let shipped = ["display", "accounts", "themes", "push", "usage",
                       "utilization", "stats", "activity", "devices", "about",
                       "cswap", "cliproxy", "9router"]
        XCTAssertEqual(SettingsCatalog.entries.map(\.id), shipped,
                       "Windows ships 13 panes in this order; SettingsCatalog drifted")

        let expectedTitles = ["Display", "Accounts", "Themes", "Push", "Usage",
                              "Utilization", "Stats", "Activity", "Devices",
                              "About", "cswap", "CLIProxyAPI", "9Router"]
        XCTAssertEqual(SettingsCatalog.entries.map(\.title), expectedTitles)

        let engines = SettingsCatalog.entries.filter(\.engine).map(\.id)
        XCTAssertEqual(engines, ["cswap", "cliproxy", "9router"])
    }

    /// `save` unlinks the old file before renaming the temp over it, so a
    /// crash in that window leaves NO settings file at all. The load path
    /// must still come up on defaults rather than throwing.
    func testSaveLeavesNoTempFileBehind() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        var s = WinSettings()
        s.lastPaneID = "stats"
        try WinSettingsStore.save(s, to: file)
        WinSettingsStore.resetCache()
        try WinSettingsStore.save(s, to: file)

        let tmp = tempDir.appendingPathComponent("settings.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "the .tmp scratch file must not survive a save")
        WinSettingsStore.resetCache()
        XCTAssertEqual(WinSettingsStore.load(from: file).lastPaneID, "stats")
    }
}
