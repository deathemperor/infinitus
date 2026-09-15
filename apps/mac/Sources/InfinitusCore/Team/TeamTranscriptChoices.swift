import Foundation

/// Spec §7 transcripts: WHICH sessions' chunks this member publishes.
/// `all` (the default) is every session inside the `transcriptDays`
/// window; `chosen` is exactly the session ids listed — a session's
/// sub-agent transcripts ride their session's choice, since they share
/// its id (`TeamPublisher.TranscriptSource.session`). Per team
/// (`<teamDir>/transcript-choices.json`), local, never sent — same shape
/// and lifetime as `TeamShares`.
public struct TeamTranscriptChoices: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case all, chosen }

    public var mode: Mode = .all
    public var chosen: Set<String> = []

    public init() {}

    public func includes(_ sessionID: String) -> Bool {
        switch mode {
        case .all: return true
        case .chosen: return chosen.contains(sessionID)
        }
    }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("transcript-choices.json") }

    public static func load(teamDir: URL) -> TeamTranscriptChoices {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamTranscriptChoices.self, from: $0) }
            ?? TeamTranscriptChoices()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }
}
