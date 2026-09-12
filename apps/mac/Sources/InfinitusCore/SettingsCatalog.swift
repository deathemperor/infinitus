import Foundation

/// The Settings pane list as data, shared by the Mac's SwiftUI sidebar
/// and the Windows Win32 one — so the two can never disagree about what
/// a pane is called or what the search box matches on.
public enum SettingsCatalog {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let keywords: [String]
        /// Engines render in their own trailing sidebar section with a
        /// live dot instead of a tinted tile (CodexBar style).
        public let engine: Bool

        public init(id: String, title: String, keywords: [String], engine: Bool) {
            self.id = id
            self.title = title
            self.keywords = keywords
            self.engine = engine
        }
    }

    public static let entries: [Entry] = [
        Entry(id: "display",    title: "Display",
              keywords: ["layout", "popup", "size", "compact", "menu bar", "icon", "title", "tray"], engine: false),
        Entry(id: "accounts",   title: "Accounts",
              keywords: ["account", "login", "relogin", "token", "add", "remove", "delete",
                         "oauth", "order", "reorder", "alias", "rename"], engine: false),
        Entry(id: "themes",     title: "Themes",
              keywords: ["theme", "skin", "gallery", "community", "rpg", "row", "gamification"], engine: false),
        Entry(id: "push",       title: "Push",
              keywords: ["slack", "telegram", "webhook", "notification"], engine: false),
        Entry(id: "usage",      title: "Usage",
              keywords: ["spend", "cost", "tokens", "estimate"], engine: false),
        Entry(id: "utilization", title: "Utilization",
              keywords: ["history", "utilization", "waste", "window", "5h", "7d",
                         "weekly", "chart", "over time"], engine: false),
        Entry(id: "stats",      title: "Stats",
              keywords: ["stats", "metrics", "commits", "prs", "lines", "messages",
                         "sessions", "week", "month", "year"], engine: false),
        Entry(id: "activity",   title: "Activity",
              keywords: ["history", "switches", "log", "events"], engine: false),
        Entry(id: "devices",    title: "Devices",
              keywords: ["sync", "settings", "devices", "phone", "iphone", "lan",
                         "companion", "tailscale", "pair", "qr"], engine: false),
        Entry(id: "about",      title: "About",
              keywords: ["update", "version", "license", "links"], engine: false),
        Entry(id: "cswap",      title: "cswap",
              keywords: ["engine", "auto switch", "interval", "config", "threshold",
                         "rotate", "claude", "provider", "update", "upgrade", "pypi",
                         "nudge", "resume", "wake", "session"], engine: true),
        Entry(id: "cliproxy",   title: "CLIProxyAPI",
              keywords: ["proxy", "cliproxy", "router", "management", "key",
                         "engine", "provider", "claude"], engine: true),
        Entry(id: "9router",    title: "9Router",
              keywords: ["9router", "router", "engine", "provider", "claude", "password"], engine: true),
    ]

    public static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// The Mac's `SettingsRoot.filtered` rule: an empty/blank query
    /// matches everything; otherwise a case-insensitive substring hit on
    /// the title or any keyword.
    public static func matches(_ entry: Entry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if entry.title.range(of: q, options: .caseInsensitive) != nil { return true }
        return entry.keywords.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    public static func filter(_ query: String) -> [Entry] {
        entries.filter { matches($0, query: query) }
    }
}
