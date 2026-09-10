import Foundation

/// The user-facing preferences the app reads from UserDefaults, as a
/// table a client can render without the Mac's Settings panes (#558):
/// key, type, default, the Settings section it lives under (a stable
/// slug plus a display name), whether a change takes effect live or
/// after a relaunch, and the accepted values where the set is closed.
/// `infinitusctl prefs` and the mirror's `GET /prefs` answer
/// `reply(from:)`, the table with each pref's current value folded in
/// the way `AppModel` reads it (a stored value outside the choices is
/// the default; the two legacy seeds are honoured). Read-only: the
/// write side waits for its spec. Secrets (the pair token) and state
/// the app keeps for itself (pinned pop-out, mock mode, debug menu) are
/// not preferences and are not listed. Sections are only ever added.
public enum PrefCatalog {
    public static let path = "/prefs"

    public struct Section: Codable, Sendable, Equatable {
        public let slug: String
        public let name: String
    }

    public enum Kind: String, Codable, Sendable { case bool, int, double, string }
    public enum Effect: String, Codable, Sendable { case live, restart }

    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let type: Kind
        public let `default`: JSONValue
        public let section: String
        public let effect: Effect
        /// Every accepted value when the set is closed; nil when any
        /// value of the type is (a theme id, say).
        public let choices: [JSONValue]?

        init(_ key: String, _ type: Kind, _ `default`: JSONValue, _ section: Section,
             effect: Effect = .live, choices: [JSONValue]? = nil) {
            self.key = key; self.type = type; self.default = `default`
            self.section = section.slug; self.effect = effect; self.choices = choices
        }
    }

    /// An entry with its current value.
    public struct Pref: Codable, Sendable, Equatable {
        public let key: String
        public let type: Kind
        public let `default`: JSONValue
        public let value: JSONValue
        public let section: String
        public let effect: Effect
        public let choices: [JSONValue]?
    }

    public struct Reply: Codable, Sendable, Equatable {
        public let sections: [Section]
        public let prefs: [Pref]
    }

    public static let display = Section(slug: "display", name: "Display")
    public static let themes = Section(slug: "themes", name: "Themes")
    public static let push = Section(slug: "push", name: "Push")
    public static let devices = Section(slug: "devices", name: "Devices")
    public static let engines = Section(slug: "engines", name: "Engines")
    public static let about = Section(slug: "about", name: "About")
    public static let sections: [Section] = [display, themes, push, devices, engines, about]

    private static func strings(_ values: [String]) -> [JSONValue] { values.map(JSONValue.string) }
    private static func ints(_ values: [Int]) -> [JSONValue] { values.map { .number(Double($0)) } }

    /// Defaults are `AppModel.init`'s fallbacks; keep the two in step.
    public static let entries: [Entry] = [
        // Display: the menu bar title.
        Entry("show_account_name", .bool, .bool(true), display),
        Entry("title_pct", .string, .string("both"), display, choices: strings(TitlePrefs.pctChoices)),
        Entry("title_scoped", .bool, .bool(false), display),
        Entry("title_remaining", .bool, .bool(false), display),
        Entry("title_reset", .string, .string("countdown"), display, choices: strings(TitlePrefs.resetChoices)),
        Entry("title_icon_only", .bool, .bool(false), display),
        Entry("refresh_interval", .int, .number(60), display, choices: ints(TitlePrefs.refreshChoices)),
        Entry("menubar_themed", .bool, .bool(true), display),
        Entry("menubar_effects", .bool, .bool(true), display),
        // Display: the popup.
        Entry("popup_layout", .string, .string("wide"), display, choices: strings(["wide", "stacked", "hstack"])),
        Entry("popup_text_size", .string, .string("default"), display,
              choices: strings(["default", "large", "xlarge", "huge"])),
        Entry("popup_sort", .string, .string(PopupSort.headroom.rawValue), display,
              choices: strings(PopupSort.allCases.map(\.rawValue))),
        Entry("compact_rows", .bool, .bool(false), display),
        Entry("footer_actions_hidden", .bool, .bool(false), display),
        Entry("glass_focused", .double, .number(0.7), display),
        Entry("chat_header", .string, .string("compact"), display, choices: strings(["compact", "strip", "hud"])),
        Entry("revival_panel", .bool, .bool(true), display),
        // Display: sessions.
        Entry("session_auto_names", .bool, .bool(true), display),
        Entry("session_host", .string, .string("auto"), display,
              choices: strings(["auto", "cmux", "terminal", "owned"])),
        Entry("checkpoints_enabled", .bool, .bool(true), display),
        Entry("keep_awake", .bool, .bool(false), display),
        Entry("keep_awake_display", .bool, .bool(true), display),
        // Themes: any theme id, built-in or custom.
        Entry("gamification_style", .string, .string("off"), themes),
        // Push.
        Entry("push_sessions_done", .bool, .bool(true), push),
        Entry("push_all_dead", .bool, .bool(true), push),
        Entry("push_last_alive", .bool, .bool(true), push),
        Entry("push_waiting", .bool, .bool(true), push),
        Entry("push_aws_login", .bool, .bool(true), push),
        Entry("push_revived", .bool, .bool(true), push),
        Entry("revive_lead_minutes", .int, .number(10), push),
        // Devices: the phone mirror.
        Entry("mirror_lan_enabled", .bool, .bool(false), devices),
        Entry("mirror_tunnel_enabled", .bool, .bool(false), devices),
        Entry("mirror_rendezvous_enabled", .bool, .bool(true), devices),
        Entry("live_activity_rate_seconds", .int, .number(5), devices),
        // Devices: the tunnel fronting the T3 Code fork server's port (#572).
        Entry("fork_tunnel_enabled", .bool, .bool(false), devices),
        Entry("fork_server_port", .int, .number(Double(ForkTunnelStatus.defaultPort)), devices),
        // Engines: the `engine` command relaunches the app for these.
        Entry("engine_cswap_enabled", .bool, .bool(true), engines, effect: .restart),
        Entry("engine_swapd_enabled", .bool, .bool(false), engines, effect: .restart),
        Entry("engine_cliproxy_enabled", .bool, .bool(false), engines, effect: .restart),
        Entry("engine_9router_enabled", .bool, .bool(false), engines, effect: .restart),
        // About: updates.
        Entry("update_auto_check", .bool, .bool(true), about),
        Entry("update_auto_install", .bool, .bool(false), about),
        Entry("update_channel", .string, .string("stable"), about, choices: strings(["stable", "nightly"])),
    ]

    public static func entry(_ key: String) -> Entry? { entries.first { $0.key == key } }

    /// The value the app runs with: the stored one when it is of the
    /// pref's type and among its choices, else the default. Two prefs
    /// carry a legacy seed the app still honours: an unset
    /// `gamification_style` reads "rpg" when the pre-theme `gamified_rows`
    /// was on, and an unset `popup_sort` follows the pre-#542
    /// `sort_headroom` Bool.
    public static func value(_ entry: Entry, in defaults: UserDefaults) -> JSONValue {
        let stored: JSONValue?
        switch entry.type {
        case .bool: stored = (defaults.object(forKey: entry.key) as? Bool).map(JSONValue.bool)
        case .int: stored = (defaults.object(forKey: entry.key) as? Int).map { .number(Double($0)) }
        case .double: stored = (defaults.object(forKey: entry.key) as? Double).map(JSONValue.number)
        case .string: stored = defaults.string(forKey: entry.key).map(JSONValue.string)
        }
        guard let stored else { return legacySeed(entry, in: defaults) ?? entry.default }
        if let choices = entry.choices, !choices.contains(stored) { return entry.default }
        return stored
    }

    private static func legacySeed(_ entry: Entry, in defaults: UserDefaults) -> JSONValue? {
        switch entry.key {
        case "gamification_style":
            return (defaults.object(forKey: "gamified_rows") as? Bool ?? false) ? .string("rpg") : nil
        case "popup_sort":
            guard let headroom = defaults.object(forKey: "sort_headroom") as? Bool else { return nil }
            return .string(PopupSort(legacyHeadroom: headroom).rawValue)
        default:
            return nil
        }
    }

    public struct UnknownKey: Error, Equatable { public let key: String }

    public static func pref(_ entry: Entry, in defaults: UserDefaults) -> Pref {
        Pref(key: entry.key, type: entry.type, default: entry.default, value: value(entry, in: defaults),
             section: entry.section, effect: entry.effect, choices: entry.choices)
    }

    /// The table with values, every entry or only `keys` (in table
    /// order); a key the table does not list is an error, not a silent
    /// omission, so a client typo shows.
    public static func reply(from defaults: UserDefaults, keys: [String]? = nil) throws -> Reply {
        if let keys, let unknown = keys.first(where: { entry($0) == nil }) { throw UnknownKey(key: unknown) }
        let wanted = keys.map(Set.init)
        return Reply(sections: sections, prefs: entries.filter { wanted?.contains($0.key) ?? true }.map { pref($0, in: defaults) })
    }

    /// A value refused by `validate`: the wrong type, or off a closed set.
    public struct Violation: Error, Equatable {
        public let key: String
        public let message: String
        public init(key: String, message: String) { self.key = key; self.message = message }
    }

    /// The entry `key` names when `value` is of its type and among its
    /// choices; `UnknownKey` or a `Violation` otherwise. An int must be
    /// whole (`60`, not `60.5`); a bool is never coerced from a string.
    public static func validate(key: String, value: JSONValue) throws -> Entry {
        guard let entry = entry(key) else { throw UnknownKey(key: key) }
        switch (entry.type, value) {
        case (.bool, .bool), (.double, .number), (.string, .string): break
        case (.int, .number(let n)) where n == n.rounded(): break
        default: throw Violation(key: key, message: "\(key) takes a \(entry.type.rawValue), not \(describe(value))")
        }
        if let choices = entry.choices, !choices.contains(value) {
            let listed = choices.map(describe).joined(separator: ", ")
            throw Violation(key: key, message: "\(key) must be one of \(listed), not \(describe(value))")
        }
        return entry
    }

    /// `validate`, then the typed write; the updated pref as the caller
    /// should show it. The write-side spec (#558): this does not decide
    /// how the app takes the change live — the caller reloads or
    /// relaunches by the entry's `effect`.
    @discardableResult
    public static func write(_ value: JSONValue, key: String, to defaults: UserDefaults) throws -> Pref {
        let entry = try validate(key: key, value: value)
        switch (entry.type, value) {
        case (.bool, .bool(let b)): defaults.set(b, forKey: key)
        case (.int, .number(let n)): defaults.set(Int(n), forKey: key)
        case (.double, .number(let n)): defaults.set(n, forKey: key)
        case (.string, .string(let s)): defaults.set(s, forKey: key)
        default: break   // validate() admits nothing else
        }
        return pref(entry, in: defaults)
    }

    /// A value typed on a command line: JSON when it parses (`true`,
    /// `60`, `"wide"`), else the bare word as a string, so
    /// `prefs set popup_layout wide` needs no quoting.
    public static func parseValue(_ text: String) -> JSONValue {
        if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { return parsed }
        return .string(text)
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return "\"\(s)\""
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    /// `POST /prefs` body (#558 write side): one key, one value.
    public struct Write: Codable, Sendable, Equatable {
        public let key: String
        public let value: JSONValue
        public init(key: String, value: JSONValue) { self.key = key; self.value = value }
    }
}
