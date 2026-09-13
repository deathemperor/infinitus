import Foundation

/// The tail of a Claude Code transcript, read only to tell a terminal
/// limit stop from a retryable 429. Not a public API — versioned by
/// `peerProtocol` in the session record; everything here degrades to
/// "not a stop" rather than throwing.
public enum Transcript {
    /// Transcripts reach hundreds of MB; one entry with a large tool result
    /// can be a few hundred KB, so this holds the last handful with margin.
    static let tailBytes = 512 * 1024

    /// `~/.claude/projects/<slug>/<sessionId>.jsonl` — the slug is the cwd
    /// with every non-alphanumeric character replaced by `-`.
    public static func path(cwd: String, sessionId: String, claudeDir: URL) -> URL {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return claudeDir.appendingPathComponent("projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// The session's transcript: the cwd slug's file when it exists, else
    /// the same file under any other project dir — a session started in a
    /// repo root and moved into a worktree keeps writing under the root's
    /// slug (peon, 2026-09-04: empty feed). Hits are remembered per
    /// session id; a miss is looked up again so a fresh session's
    /// transcript is found the moment it appears.
    public static func locate(cwd: String, sessionId: String, claudeDir: URL) -> URL {
        let direct = path(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        let fm = FileManager.default
        if fm.fileExists(atPath: direct.path) { return direct }
        located.lock.lock(); defer { located.lock.unlock() }
        if let hit = located.byId[sessionId], fm.fileExists(atPath: hit.path) { return hit }
        let projects = claudeDir.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return direct }
        for dir in dirs {
            let candidate = projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                located.byId[sessionId] = candidate
                return candidate
            }
        }
        return direct
    }

    private final class LocateCache: @unchecked Sendable {
        let lock = NSLock()
        var byId: [String: URL] = [:]
    }
    private static let located = LocateCache()

    /// Only conversation turns and a retryable mid-turn 429 say anything
    /// about whether work has stopped; bookkeeping entries are skipped.
    static func decidesTheTurn(_ entry: [String: Any]) -> Bool {
        let type = entry["type"] as? String
        if type == "user" || type == "assistant" { return true }
        return type == "system" && (entry["subtype"] as? String) == "api_error"
    }

    /// The transcript's last `maxBytes` (default `tailBytes`), newest line
    /// first; partial first/last lines are skipped by the callers, never
    /// an error.
    static func tailLines(at url: URL, maxBytes: Int = tailBytes) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return [] }
        return blob.split(separator: UInt8(ascii: "\n")).reversed()
    }

    /// The first probe for `lastTurnEntry`: the deciding entry is nearly
    /// always within the last few KB, and the resume tick asks for every
    /// session's and every recent agent's (#346) — the full `tailBytes`
    /// is read only when the short probe finds nothing.
    static let probeBytes = 64 * 1024

    /// The last entry that decides whether work has stopped. Reads only
    /// the tail.
    public static func lastTurnEntry(at url: URL) -> [String: Any]? {
        if let entry = lastTurnEntry(in: tailLines(at: url, maxBytes: probeBytes)) { return entry }
        return lastTurnEntry(in: tailLines(at: url))
    }

    private static func lastTurnEntry(in lines: [Data.SubSequence]) -> [String: Any]? {
        for line in lines {
            guard line.first == UInt8(ascii: "{"),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if decidesTheTurn(entry) { return entry }
        }
        return nil
    }

    /// The session's permission-mode class as Claude Code's peer inbox
    /// (2.1.263+) computes it for the gate that holds mismatched peer
    /// messages (#213): `"bypass"` for bypassPermissions, or for plan mode
    /// when bypass was available (the tail shows an earlier
    /// bypassPermissions turn); `"prompting"` for every other mode; nil
    /// when no user entry in the tail records a mode. Typed prompts, peer
    /// messages and notifications carry the mode at write time; tool
    /// results do NOT (2.1.263), so a long autonomous run pushes the last
    /// marker out of the tail — callers fall back to
    /// `ProcessFacts.peerModeClass(pid:)` (a held AWS nudge, 2026-09-08).
    public static func peerModeClass(at url: URL) -> String? {
        var newest: String?
        for line in tailLines(at: url) {
            guard line.first == UInt8(ascii: "{"),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (entry["type"] as? String) == "user",
                  let mode = entry["permissionMode"] as? String
            else { continue }
            if newest == nil {
                newest = mode
                if mode != "plan" { break }
            } else if mode == "bypassPermissions" {
                return "bypass"
            }
        }
        guard let newest else { return nil }
        return newest == "bypassPermissions" ? "bypass" : "prompting"
    }

    /// The terminal plan-limit turn: a synthetic assistant message with
    /// `isApiErrorMessage` and `error == "rate_limit"` and no retry
    /// bookkeeping. Retryable 429s are `system`/`api_error` entries Claude
    /// Code is still working on — nudging those would interrupt a turn.
    public static func isLimitStop(_ entry: [String: Any]?) -> Bool {
        guard let entry, (entry["type"] as? String) == "assistant",
              let flag = entry["isApiErrorMessage"] as? Bool, flag,
              (entry["error"] as? String) == "rate_limit"
        else { return false }
        return entry["retryAttempt"] == nil
    }

    public static func limitText(_ entry: [String: Any]) -> String {
        if let message = entry["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String { return text }
            }
        }
        return "usage limit reached"
    }

    /// Every `agent-*.jsonl` under a session's `subagents/` dir, plus one
    /// level deeper for workflow runs (`subagents/workflows/<run>/`) —
    /// fixed depths, not a recursive walk (matches StatsScanner). The
    /// listing prefetches each file's mtime, so every caller's
    /// `resourceValues(forKeys: [.contentModificationDateKey])` is answered
    /// from the URL instead of one stat per file: a walk over 1,900 agent
    /// files went 33 → 19 ms (#346).
    static func agentFiles(under subagentsDir: URL) -> [URL] {
        let fm = FileManager.default
        func agents(in dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { let name = $0.lastPathComponent; return name.hasPrefix("agent-") && name.hasSuffix(".jsonl") }
                ?? []
        }
        var files = agents(in: subagentsDir)
        let workflowsDir = subagentsDir.appendingPathComponent("workflows")
        for run in (try? fm.contentsOfDirectory(atPath: workflowsDir.path)) ?? [] {
            files += agents(in: workflowsDir.appendingPathComponent(run))
        }
        return files
    }
}
