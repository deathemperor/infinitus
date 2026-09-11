import XCTest
@testable import InfinitusCore

/// The Settings search index (critique P1 "the shell": the field matched
/// eight hand-written keywords per tab and never a setting's own label,
/// so "transparency", "keep awake" and "start at login" all returned
/// nothing though every one of them is a real setting).
final class SettingsSearchIndexTests: XCTestCase {
    private let index = SettingsSearchIndex([
        SettingsSearchEntry(pane: "Display", section: "Menu bar",
                            label: "Show only the icon",
                            keywords: ["menu bar", "glyph"]),
        SettingsSearchEntry(pane: "Display", section: "Popup",
                            label: "Transparency",
                            keywords: ["glass", "blur", "opacity"]),
        SettingsSearchEntry(pane: "Display", section: "Popup",
                            label: "Sort rows by headroom",
                            keywords: ["order", "sort"]),
        SettingsSearchEntry(pane: "Display", section: "Startup",
                            label: "Start at login", keywords: ["login item"]),
        SettingsSearchEntry(pane: "Display", section: "Startup",
                            label: "Keep the Mac awake while sessions are working",
                            keywords: ["caffeinate", "sleep"]),
        SettingsSearchEntry(pane: "Display", section: "Sessions",
                            label: "Checkpoint the repository at every prompt",
                            keywords: ["checkpoint", "git", "restore"]),
        SettingsSearchEntry(pane: "Themes", label: "Themes",
                            keywords: ["skin", "gallery"]),
        SettingsSearchEntry(pane: "Push", label: "Push",
                            keywords: ["slack", "telegram", "webhook"]),
    ])

    func testFindsASettingByItsOwnLabel() {
        let hits = index.matches("transparency")
        XCTAssertEqual(hits.first?.pane, "Display")
        XCTAssertEqual(hits.first?.label, "Transparency")
        XCTAssertEqual(hits.first?.anchor, "Display/Popup")
    }

    /// The critique's own examples. "keep awake" is not a substring of
    /// "Keep the Mac awake while sessions are working" — a query whose
    /// words all appear in a row still has to find it.
    func testTheQueriesTheOldFieldCouldNotAnswer() {
        for query in ["keep awake", "start at login", "headroom", "checkpoint"] {
            let hits = index.matches(query)
            XCTAssertEqual(hits.first?.pane, "Display", "\(query) found nothing")
        }
        XCTAssertEqual(index.matches("keep awake").first?.label,
                       "Keep the Mac awake while sessions are working")
    }

    func testRankingPrefersTheLabelOverAKeywordOverThePaneTitle() {
        // "sort" is this row's label word AND another row's keyword.
        let hits = index.matches("sort")
        XCTAssertEqual(hits.first?.label, "Sort rows by headroom")
        // A keyword-only hit still lands, after the label hits.
        XCTAssertTrue(index.matches("blur").contains { $0.label == "Transparency" })
        // The pane title matches every row of that pane, in declared order.
        XCTAssertEqual(index.matches("push").map(\.label), ["Push"])
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertFalse(index.matches("TRANSPARENCY").isEmpty)
        XCTAssertFalse(index.matches("  Keep Awake  ").isEmpty)
    }

    func testABlankQueryMatchesNothing() {
        XCTAssertTrue(index.matches("").isEmpty)
        XCTAssertTrue(index.matches("   \n").isEmpty)
        XCTAssertTrue(index.grouped(" ").isEmpty)
    }

    func testGroupedKeepsPaneOrderAndNeverRepeatsAPane() {
        let groups = index.grouped("s")
        XCTAssertEqual(groups.map(\.pane), NSOrderedSet(array: groups.map(\.pane)).array as! [String])
        XCTAssertEqual(groups.first?.pane, "Display")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.entries.count }, index.matches("s").count)
    }

    func testUnicodeLabelsAreSafe() {
        let themed = SettingsSearchIndex([
            SettingsSearchEntry(pane: "Utilization", section: "Forecast",
                                label: "🎥 session (5h)", keywords: ["window"]),
        ])
        XCTAssertEqual(themed.matches("🎥").count, 1)
        XCTAssertEqual(themed.matches("session").count, 1)
    }

    func testEntryLookupById() {
        let hit = index.matches("transparency")[0]
        XCTAssertEqual(index.entry(id: hit.id)?.label, "Transparency")
        XCTAssertNil(index.entry(id: "Display/Nowhere#Nothing"))
    }
}
