import XCTest
@testable import InfinitusCore

final class PrefCatalogTests: XCTestCase {
    /// One suite for the whole process, not one per test. `removePersistentDomain`
    /// empties a domain but leaves its plist in ~/Library/Preferences, and
    /// cfprefsd owns that file: it flushes its cached copy back seconds after
    /// the test process exits, so unlinking in `tearDown` cannot win either
    /// (`defaults delete` is no help — an empty domain reads as "does not
    /// exist"). A fresh UUID per test therefore left a file per test behind,
    /// 1133 of them on one dev Mac. Keyed by pid, the leftovers are a bounded
    /// set instead, and concurrent `swift test` runs in sibling worktrees still
    /// get a suite each.
    private static let suite = "run.infinitus.prefs-test-\(ProcessInfo.processInfo.processIdentifier)"
    private var suite: String { Self.suite }
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
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
        XCTAssertEqual(reply.sections.map(\.slug), ["display", "themes", "animations", "push", "devices", "engines", "about", "priority"])
        XCTAssertEqual(reply.prefs.count, PrefCatalog.entries.count)
        for pref in reply.prefs { XCTAssertEqual(pref.value, pref.default, pref.key) }
        let layout = try XCTUnwrap(reply.prefs.first { $0.key == "popup_layout" })
        XCTAssertEqual(layout.section, "display")
        XCTAssertEqual(layout.effect, .live)
        XCTAssertEqual(layout.choices, [.string("wide"), .string("stacked"), .string("hstack")])
        XCTAssertEqual(reply.prefs.first { $0.key == "engine_swapd_enabled" }?.effect, .restart)
        // #1177: the demo fleet is a restart-effect pref of the engines section.
        let mock = reply.prefs.first { $0.key == "mock_mode" }
        XCTAssertEqual(mock?.effect, .restart)
        XCTAssertEqual(mock?.section, "engines")
    }

    /// Where the desktop server bound is a Devices pref, defaulting to T3's
    /// port; the tunnel prefs beside it left with the Cloudflare tunnels.
    func testTheForkServerPortSitsUnderDevicesWithT3sDefaultPort() throws {
        let reply = try PrefCatalog.reply(from: defaults, keys: ["fork_server_port"])
        XCTAssertEqual(reply.prefs.map(\.section), ["devices"])
        XCTAssertEqual(reply.prefs.map(\.effect), [.live])
        XCTAssertEqual(reply.prefs.map(\.value), [.number(3773)])
        XCTAssertEqual(try PrefCatalog.write(.number(3774), key: "fork_server_port", to: defaults).value, .number(3774))
        XCTAssertEqual(defaults.object(forKey: "fork_server_port") as? Int, 3774)
        XCTAssertNil(PrefCatalog.entry("fork_tunnel_enabled"))
        XCTAssertNil(PrefCatalog.entry("fork_tunnel_hostname"))
    }

    func testTheDevicesPagePrefsSitUnderDevices() throws {
        // #1178: this Mac's name and the desktop's settings-sync switch (the
        // APNs ids left with #1375).
        let keys = ["machine_name", "sync_settings"]
        let reply = try PrefCatalog.reply(from: defaults, keys: keys)
        XCTAssertEqual(reply.prefs.map(\.section), Array(repeating: "devices", count: 2))
        XCTAssertEqual(reply.prefs.map(\.effect), Array(repeating: .live, count: 2))
        XCTAssertEqual(reply.prefs.map(\.value), [.string(""), .bool(false)])
        XCTAssertEqual(try PrefCatalog.write(.string("Studio"), key: "machine_name", to: defaults).value, .string("Studio"))
        XCTAssertEqual(defaults.string(forKey: "machine_name"), "Studio")
        XCTAssertEqual(try PrefCatalog.write(.bool(true), key: "sync_settings", to: defaults).value, .bool(true))
        XCTAssertThrowsError(try PrefCatalog.write(.number(1), key: "machine_name", to: defaults))
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

    /// The table's order is the order the desktop app draws the Menu bar page
    /// in (#1184), so the master switch leads its section: every other Display
    /// pref only matters while the status item is there.
    func testTheStatusItemSwitchLeadsTheDisplaySection() {
        let display = PrefCatalog.entries.filter { $0.section == "display" }.map(\.key)
        XCTAssertEqual(display.first, "menu_bar_enabled")
    }

    func testGetKeepsTableOrderAndRejectsAnUnknownKey() throws {
        let reply = try PrefCatalog.reply(from: defaults, keys: ["title_pct", "show_account_name"])
        XCTAssertEqual(reply.prefs.map(\.key), ["show_account_name", "title_pct"])
        XCTAssertThrowsError(try PrefCatalog.reply(from: defaults, keys: ["show_account_name", "mirror_pair_token"])) {
            XCTAssertEqual($0 as? PrefCatalog.UnknownKey, PrefCatalog.UnknownKey(key: "mirror_pair_token"))
        }
    }

    func testAWriteStoresTheTypedValueAndAnswersTheUpdatedPref() throws {
        let pref = try PrefCatalog.write(.string("stacked"), key: "popup_layout", to: defaults)
        XCTAssertEqual(pref.value, .string("stacked"))
        XCTAssertEqual(defaults.string(forKey: "popup_layout"), "stacked")
        XCTAssertEqual(try PrefCatalog.write(.number(300), key: "refresh_interval", to: defaults).value, .number(300))
        XCTAssertEqual(defaults.object(forKey: "refresh_interval") as? Int, 300)
        XCTAssertEqual(try PrefCatalog.write(.bool(false), key: "show_account_name", to: defaults).value, .bool(false))
        XCTAssertEqual(defaults.object(forKey: "show_account_name") as? Bool, false)
        XCTAssertEqual(try PrefCatalog.write(.number(0.25), key: "glass_focused", to: defaults).value, .number(0.25))
        XCTAssertEqual(try PrefCatalog.write(.string("dragon"), key: "gamification_style", to: defaults).value, .string("dragon"))
    }

    /// Every refusal names the key and what would do, and writes nothing.
    func testAWriteIsRefusedForTheWrongTypeOrAnUnlistedChoice() {
        func refused(_ value: JSONValue, _ key: String) -> String? {
            do { try PrefCatalog.write(value, key: key, to: defaults) } catch let v as PrefCatalog.Violation { return v.message } catch { return "\(error)" }
            return nil
        }
        XCTAssertEqual(refused(.string("true"), "show_account_name"), "show_account_name takes a bool, not \"true\"")
        XCTAssertEqual(refused(.number(60.5), "refresh_interval"), "refresh_interval takes a int, not 60.5")
        XCTAssertEqual(refused(.number(45), "refresh_interval"), "refresh_interval must be one of 30, 60, 300, not 45")
        XCTAssertEqual(refused(.string("sideways"), "title_pct"), "title_pct must be one of \"off\", \"5h\", \"7d\", \"both\", not \"sideways\"")
        XCTAssertEqual(refused(.bool(true), "gamification_style"), "gamification_style takes a string, not true")
        XCTAssertThrowsError(try PrefCatalog.write(.bool(true), key: "mirror_pair_token", to: defaults)) {
            XCTAssertEqual($0 as? PrefCatalog.UnknownKey, PrefCatalog.UnknownKey(key: "mirror_pair_token"))
        }
        XCTAssertNil(defaults.object(forKey: "show_account_name"))
        XCTAssertNil(defaults.object(forKey: "refresh_interval"))
        XCTAssertNil(defaults.object(forKey: "title_pct"))
    }

    func testACommandLineValueIsJSONOrABareString() {
        XCTAssertEqual(PrefCatalog.parseValue("true"), .bool(true))
        XCTAssertEqual(PrefCatalog.parseValue("60"), .number(60))
        XCTAssertEqual(PrefCatalog.parseValue("0.5"), .number(0.5))
        XCTAssertEqual(PrefCatalog.parseValue("\"wide\""), .string("wide"))
        XCTAssertEqual(PrefCatalog.parseValue("wide"), .string("wide"))
        XCTAssertEqual(PrefCatalog.parseValue("5h"), .string("5h"))
    }

    func testThePostBodyRoundTrips() throws {
        let data = Data(#"{"key":"popup_layout","value":"stacked"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PrefCatalog.Write.self, from: data),
                       PrefCatalog.Write(key: "popup_layout", value: .string("stacked")))
    }

    /// #747: the popup intro and burn prefs sit under `animations`; the
    /// speed carries its range and a write outside it is refused.
    func testTheAnimationPrefsCarryTheirRangeAndRefuseAValueOutsideIt() throws {
        let reply = try PrefCatalog.reply(from: defaults, keys: ["intro_style", "intro_speed"])
        XCTAssertEqual(reply.prefs.map(\.section), ["animations", "animations"])
        XCTAssertEqual(reply.prefs[0].choices, [.string("top"), .string("bottom"), .string("fade"), .string("rows")])
        XCTAssertEqual(reply.prefs[1].min, 0.4)
        XCTAssertEqual(reply.prefs[1].max, 2)
        XCTAssertNil(reply.prefs[0].min)
        XCTAssertEqual(try PrefCatalog.write(.number(1.5), key: "intro_speed", to: defaults).value, .number(1.5))
        XCTAssertThrowsError(try PrefCatalog.write(.number(3), key: "intro_speed", to: defaults)) { error in
            XCTAssertEqual((error as? PrefCatalog.Violation)?.message, "intro_speed must be between 0.4 and 2, not 3")
        }
        XCTAssertThrowsError(try PrefCatalog.write(.number(0.1), key: "intro_speed", to: defaults))
        XCTAssertEqual(defaults.double(forKey: "intro_speed"), 1.5, "the refused writes left the stored value alone")
        let text = String(decoding: try JSONEncoder().encode(try PrefCatalog.reply(from: defaults, keys: ["intro_style"])), as: UTF8.self)
        XCTAssertFalse(text.contains("\"min\""), "an unbounded pref carries no min/max keys: \(text)")
    }

    /// The theme id set is open (custom `themes.json` ids), so the reply
    /// takes run-time choices by key while validation stays the entry's.
    func testRunTimeChoicesReplaceTheEntrysInTheReplyOnly() throws {
        defaults.set("my-skin", forKey: "gamification_style")
        let rows: [JSONValue] = [.object(["id": .string("off"), "name": .string("Off")]),
                                 .object(["id": .string("my-skin"), "name": .string("My skin")])]
        let reply = try PrefCatalog.reply(from: defaults, keys: ["gamification_style", "popup_layout"],
                                          choices: ["gamification_style": rows])
        let theme = try XCTUnwrap(reply.prefs.first { $0.key == "gamification_style" })
        XCTAssertEqual(theme.choices, rows)
        XCTAssertEqual(theme.value, .string("my-skin"))
        XCTAssertEqual(reply.prefs.first { $0.key == "popup_layout" }?.choices, [.string("wide"), .string("stacked"), .string("hstack")])
        XCTAssertNoThrow(try PrefCatalog.write(.string("another"), key: "gamification_style", to: defaults))
    }

    func testTheReplyEncodesDefaultAndValueAsPlainJSON() throws {
        defaults.set("hold", forKey: "priority_mode")
        let data = try JSONEncoder().encode(try PrefCatalog.reply(from: defaults, keys: ["priority_mode"]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""default":"off""#), text)
        XCTAssertTrue(text.contains(#""value":"hold""#), text)
        XCTAssertTrue(text.contains(#""choices":["off","hold","interrupt"]"#), text)
        XCTAssertEqual(try JSONDecoder().decode(PrefCatalog.Reply.self, from: data).prefs.first?.value, .string("hold"))
    }
}
