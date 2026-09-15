import Foundation

/// Spec §7: the audience per data kind, chosen by the member; new
/// envelopes use it, `TeamPublisher.reshare` re-wraps history to it.
/// Per team (`<teamDir>/shares.json`); unset kinds go to the leaders.
public struct TeamShares: Codable, Equatable, Sendable {
    public var byKind: [String: TeamRoster.ShareTarget] = [:]

    public init() {}

    public func target(for kind: String) -> TeamRoster.ShareTarget { byKind[kind] ?? .leaders }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("shares.json") }

    public static func load(teamDir: URL) -> TeamShares {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamShares.self, from: $0) }
            ?? TeamShares()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }

    /// The CLI / UI spelling: `off` (or `nobody`), `leaders`, `team`, or kids
    /// separated by commas, or as separate arguments.
    public static func parseTarget(_ words: [String]) -> TeamRoster.ShareTarget? {
        let kids = words.flatMap { $0.split(separator: ",") }.map(String.init).filter { !$0.isEmpty }
        guard !kids.isEmpty else { return nil }
        if kids == ["off"] || kids == ["nobody"] { return .off }
        if kids == ["leaders"] { return .leaders }
        if kids == ["team"] { return .team }
        return .members(kids)
    }
}
