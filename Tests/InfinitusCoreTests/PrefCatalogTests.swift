import XCTest
@testable import InfinitusCore

final class PrefCatalogTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "run.infinitus.prefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The table stays honest as it grows: every entry sits in a listed
    /// section, its default is of its type, and a closed set contains it.
    func testEveryEntryIsWellFormed() {
        let slugs = Set(PrefCatalog.sections.map(\.slug))
        XCTAssertEqual(slugs.count, PrefCatalog.sections.count, "section slugs are unique")
        XCTAssertEqual(Set(PrefCatalog.entries.map(\.key)).count, PrefCatalog.entries.count, "keys are unique")
        for entry in PrefCatalog.entries {
            XCTAssertTrue(slugs.contains(entry.section), "\(entry.key) sits in an unlisted section \(entry.section)")
            switch (entry.type, entry.default) {
            case (.bool, .bool), (.int, .number), (.double, .number), (.string, .string): break
            default: XCTFail("\(entry.key): default \(entry.default) is not a \(entry.type)")
            }
            if let choices = entry.choices {
                XCTAssertTrue(choices.contains(entry.default), "\(entry.key): the default is not among its choices")
            }
        }
    }

    func testAnUnsetSuiteReadsTheDefaults() throws {
        let reply = try PrefCatalog.reply(from: defaults)
        XCTAssertEqual(reply.sections.map(\.slug), ["display", "themes", "push", "devices", "engines", "about"])
        XCTAssertEqual(reply.prefs.count, PrefCatalog.entries.count)
        for pref in reply.prefs { XCTAssertEqual(pref.value, pref.default, pref.key) }
        let layout = try XCTUnwrap(reply.prefs.first { $0.key == "popup_layout" })
        XCTAssertEqual(layout.section, "display")
        XCTAssertEqual(layout.effect, .live)
        XCTAssertEqual(layout.choices, [.string("wide"), .string("stacked"), .string("hstack")])
        XCTAssertEqual(reply.prefs.first { $0.key == "engine_swapd_enabled" }?.effect, .restart)
    }

    func testStoredValuesReadBackTypedAndAnInvalidChoiceIsTheDefault() throws {
        defaults.set(false, forKey: "show_account_name")
        defaults.set(300, forKey: "refresh_interval")
        defaults.set(0.4, forKey: "glass_focused")
        defaults.set("stacked", forKey: "popup_layout")
        defaults.set("sideways", forKey: "title_pct")      // not a choice
        defaults.set(45, forKey: "refresh_interval")       // not a choice either
        defaults.set("dragon", forKey: "gamification_style") // open set: any theme id
        let reply = try PrefCatalog.reply(from: defaults)
        func value(_ key: String) -> JSONValue? { reply.prefs.first { $0.key == key }?.value }
        XCTAssertEqual(value("show_account_name"), .bool(false))
        XCTAssertEqual(value("refresh_interval"), .number(60))
        XCTAssertEqual(value("glass_focused"), .number(0.4))
        XCTAssertEqual(value("popup_layout"), .string("stacked"))
        XCTAssertEqual(value("title_pct"), .string("both"))
        XCTAssertEqual(value("gamification_style"), .string("dragon"))
    }

    /// The seeds `AppModel` still honours for a pre-theme / pre-#542 install.
    func testTheLegacySeedsAreHonouredWhenTheKeyIsUnset() throws {
        defaults.set(true, forKey: "gamified_rows")
        defaults.set(false, forKey: "sort_headroom")
        XCTAssertEqual(try PrefCatalog.reply(from: defaults, keys: ["gamification_style"]).prefs.first?.value, .string("rpg"))
        XCTAssertEqual(try PrefCatalog.reply(from: defaults, keys: ["popup_sort"]).prefs.first?.value, .string("engine"))
        defaults.set("off", forKey: "gamification_style")
        XCTAssertEqual(try PrefCatalog.reply(from: defaults, keys: ["gamification_style"]).prefs.first?.value, .string("off"))
    }

    func testGetKeepsTableOrderAndRejectsAnUnknownKey() throws {
        let reply = try PrefCatalog.reply(from: defaults, keys: ["title_pct", "show_account_name"])
        XCTAssertEqual(reply.prefs.map(\.key), ["show_account_name", "title_pct"])
        XCTAssertThrowsError(try PrefCatalog.reply(from: defaults, keys: ["show_account_name", "mirror_pair_token"])) {
            XCTAssertEqual($0 as? PrefCatalog.UnknownKey, PrefCatalog.UnknownKey(key: "mirror_pair_token"))
        }
    }

    func testTheReplyEncodesDefaultAndValueAsPlainJSON() throws {
        defaults.set("nightly", forKey: "update_channel")
        let data = try JSONEncoder().encode(try PrefCatalog.reply(from: defaults, keys: ["update_channel"]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""default":"stable""#), text)
        XCTAssertTrue(text.contains(#""value":"nightly""#), text)
        XCTAssertTrue(text.contains(#""choices":["stable","nightly"]"#), text)
        XCTAssertEqual(try JSONDecoder().decode(PrefCatalog.Reply.self, from: data).prefs.first?.value, .string("nightly"))
    }
}
