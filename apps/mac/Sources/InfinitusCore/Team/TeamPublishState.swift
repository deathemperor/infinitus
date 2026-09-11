import Foundation

/// What this machine has already published for one team
/// (`<teamDir>/publish-state.json`): where each transcript's chunks
/// stand, and the content hash of every whole-object file so an
/// unchanged day or crash list is not re-sealed on every push.
public struct TeamPublishState: Codable, Equatable {
    public struct Cursor: Codable, Equatable {
        /// Last chunk sequence number published (0 = none yet).
        public var seq: Int
        /// Byte offset just past the last line published.
        public var offset: Int
        public init(seq: Int = 0, offset: Int = 0) { self.seq = seq; self.offset = offset }
    }

    /// `TranscriptSource.key` → cursor.
    public var transcripts: [String: Cursor] = [:]
    /// Store-relative path (`days/2026-09-04.json`, `crashes.json`) → hex SHA-256 of the plaintext last published.
    public var hashes: [String: String] = [:]

    public init() {}

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("publish-state.json") }

    public static func load(teamDir: URL) -> TeamPublishState {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamPublishState.self, from: $0) }
            ?? TeamPublishState()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }
}
