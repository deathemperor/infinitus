import Foundation

/// Where team state lives (spec §4.2): `<base>/<team-id>/{config.json,
/// roster.json, store/}` plus `<base>/secrets/` for `FileSecrets`.
/// `INFINITUS_TEAM_DIR` overrides the base (tests, the e2e gate, a second
/// instance on one machine).
public struct TeamPaths {
    public let base: URL

    public init(base: URL) { self.base = base }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory()) -> TeamPaths {
        if let over = environment["INFINITUS_TEAM_DIR"], !over.isEmpty {
            return TeamPaths(base: URL(fileURLWithPath: over))
        }
        #if os(macOS)
        return TeamPaths(base: URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Infinitus/teams"))
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home + "/.local/share")
        return TeamPaths(base: URL(fileURLWithPath: data).appendingPathComponent("infinitus/teams"))
        #endif
    }

    /// A team id is one path segment: the lowercase UUID `create` mints,
    /// or anything else made of letters, digits and dashes. `--team
    /// ../../x` must not walk out of `base` (#55).
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public var secretsDir: URL { base.appendingPathComponent("secrets") }
    public func teamDir(_ id: String) -> URL { base.appendingPathComponent(id) }
    public func configFile(_ id: String) -> URL { teamDir(id).appendingPathComponent("config.json") }
    public func rosterFile(_ id: String) -> URL { teamDir(id).appendingPathComponent("roster.json") }
    public func storeDir(_ id: String) -> URL { teamDir(id).appendingPathComponent("store") }

    /// Teams this machine has joined or created: directories with a config.
    public func teamIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: configFile($0).path) }.sorted()
    }
}
