import Foundation

/// The iCloud-Drive settings snapshot: app display prefs, custom themes,
/// and the explicitly-set engine settings (autoswitch.*, ui.* — the spec
/// table holds no secrets; notify webhooks live in notify.json and are
/// deliberately absent here). Scope picked 2026-08-29: prefs + themes +
/// engine config, never credentials.
///
/// A plain JSON file under ~/Library/Mobile Documents/com~apple~CloudDocs/
/// — the dev-signed bundle has no iCloud entitlement, so the key-value
/// store is off the table; a file in the iCloud Drive folder syncs with
/// no entitlement at all.
public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var app: [String: JSONValue]
    public var themes: [RowTheme]
    /// Engine settings as `cswap config set` text — the CLI re-validates
    /// every value, so this can only ever be too lenient, never corrupting.
    public var engine: [String: String]

    public init(app: [String: JSONValue] = [:], themes: [RowTheme] = [],
                engine: [String: String] = [:]) {
        self.app = app
        self.themes = themes
        self.engine = engine
    }

    public static func decode(_ data: Data) -> SyncSnapshot? {
        try? JSONDecoder().decode(SyncSnapshot.self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
