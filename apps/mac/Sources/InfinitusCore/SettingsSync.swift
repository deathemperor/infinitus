import Foundation

/// The iCloud-Drive settings snapshot: app display prefs, custom themes,
/// the explicitly-set engine settings (autoswitch.*, ui.* — the spec
/// table holds no secrets; notify webhooks live in notify.json and are
/// deliberately absent here) and, since `icloud_sync_names`, the custom
/// account names. Scope picked 2026-08-29: prefs + themes + engine
/// config, never credentials; names joined as an opt-in.
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
    /// Custom account names by `SyncNames.key`, an empty string where an
    /// account wears none — so a clear travels like a name does. The
    /// union of every Mac's accounts: each overlays only its own rows
    /// (`SyncNames.merge`), never replaces the map. Absent from a file an
    /// older Mac wrote, so it decodes as empty rather than failing the
    /// whole snapshot (a nil remote reads as "no file" and gets pushed
    /// over).
    public var names: [String: String]

    public init(app: [String: JSONValue] = [:], themes: [RowTheme] = [],
                engine: [String: String] = [:], names: [String: String] = [:]) {
        self.app = app
        self.themes = themes
        self.engine = engine
        self.names = names
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode([String: JSONValue].self, forKey: .app)
        themes = try c.decode([RowTheme].self, forKey: .themes)
        engine = try c.decode([String: String].self, forKey: .engine)
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
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

/// Account-name sync: an account is the same account on every Mac by
/// its provider and email, never by its slot number, so that is the key
/// the snapshot's `names` carry.
public enum SyncNames {
    public static func key(provider: Provider, email: String) -> String {
        "\(provider.rawValue)/\(email)"
    }

    /// This Mac's rows for one fleet: every account's alias, empty where
    /// it has none. An account with no email has no identity across Macs
    /// and stays out (every such account would share one key).
    public static func rows(provider: Provider, accounts: [Account]) -> [String: String] {
        Dictionary(accounts.filter { !$0.email.isEmpty }
                       .map { (key(provider: provider, email: $0.email), $0.alias ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The file's map with this Mac's rows laid over it: an account only
    /// another Mac holds keeps its entry, so two Macs with different
    /// fleets never take turns erasing each other's names.
    public static func merge(_ base: [String: String], local: [String: String]) -> [String: String] {
        base.merging(local) { _, mine in mine }
    }

    /// The renames one fleet needs so its accounts wear the file's names:
    /// slot number to alias, only where they differ. An account the file
    /// does not know keeps its own name.
    public static func pendingRenames(names: [String: String], provider: Provider,
                                      accounts: [Account]) -> [Int: String] {
        var out: [Int: String] = [:]
        for a in accounts where !a.email.isEmpty {
            guard let wanted = names[key(provider: provider, email: a.email)],
                  wanted != (a.alias ?? "") else { continue }
            out[a.number] = wanted
        }
        return out
    }
}
