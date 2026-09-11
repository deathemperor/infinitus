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
        XCTAssertEqual(reply.sections.map(\.slug), ["display", "themes", "animations", "push", "devices", "engines", "about", "sessions"])
        XCTAssertEqual(reply.prefs.count, PrefCatalog.entries.count)
        for pref in reply.prefs { XCTAssertEqual(pref.value, pref.default, pref.key) }
        let layout = try XCTUnwrap(reply.prefs.first { $0.key == "popup_layout" })
        XCTAssertEqual(layout.section, "display")
        XCTAssertEqual(layout.effect, .live)
        XCTAssertEqual(layout.choices, [.string("wide"), .string("stacked"), .string("hstack")])
        XCTAssertEqual(reply.prefs.first { $0.key == "engine_swapd_enabled" }?.effect, .restart)
    }

    /// The fork server's tunnel (#572) is a Devices pref pair: off, on T3's port.
    func testTheForkTunnelPrefsSitUnderDevicesWithT3sDefaultPort() throws {
        let reply = try PrefCatalog.reply(from: defaults, keys: ["fork_tunnel_enabled", "fork_server_port"])
        XCTAssertEqual(reply.prefs.map(\.section), ["devices", "devices"])
        XCTAssertEqual(reply.prefs.map(\.effect), [.live, .live])
        XCTAssertEqual(reply.prefs.map(\.value), [.bool(false), .number(3773)])
        XCTAssertEqual(try PrefCatalog.write(.number(3774), key: "fork_server_port", to: defaults).value, .number(3774))
        XCTAssertEqual(defaults.object(forKey: "fork_server_port") as? Int, 3774)
        // #650: the stable hostname on the named tunnel, empty = quick tunnel.
        let host = try PrefCatalog.reply(from: defaults, keys: ["fork_tunnel_hostname"]).prefs[0]
        XCTAssertEqual(host.section, "devices")
        XCTAssertEqual(host.effect, .live)
        XCTAssertEqual(host.value, .string(""))
        XCTAssertEqual(try PrefCatalog.write(.string("code.example.com"), key: "fork_tunnel_hostname", to: defaults).value,
                       .string("code.example.com"))
        XCTAssertEqual(defaults.string(forKey: "fork_tunnel_hostname"), "code.example.com")
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
        defaults.set("nightly", forKey: "update_channel")
        let data = try JSONEncoder().encode(try PrefCatalog.reply(from: defaults, keys: ["update_channel"]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""default":"stable""#), text)
        XCTAssertTrue(text.contains(#""value":"nightly""#), text)
        XCTAssertTrue(text.contains(#""choices":["stable","nightly"]"#), text)
        XCTAssertEqual(try JSONDecoder().decode(PrefCatalog.Reply.self, from: data).prefs.first?.value, .string("nightly"))
    }
}
