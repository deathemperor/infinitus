import Foundation

/// Zero-token progress snapshot derived from a transcript tail — "layer 0"
/// from docs/research/session-progress.md: what the transcript already
/// says about a session, without spending a single token to summarize it.
public struct SessionProgress: Sendable, Equatable, Codable {
    /// The most recent `TodoWrite` payload — a structured self-report the
    /// agent already maintains, read for free.
    public struct Todos: Sendable, Equatable, Codable {
        public let done: Int
        public let total: Int
        public let activeForm: String?

        public init(done: Int, total: Int, activeForm: String?) {
            self.done = done
            self.total = total
            self.activeForm = activeForm
        }
    }

    /// Newest entry's own timestamp.
    public let lastActivityAt: Date?
    /// Human line derived from the last signal (tool_use or assistant text).
    public let nowDoing: String?
    /// Latest TodoWrite payload in the tail; nil if none appears.
    public let todos: Todos?
    /// Latest `type:"summary"` entry's `summary` field.
    public let title: String?
    /// What the session was asked to do — the first real user prompt at the
    /// transcript HEAD, not the tail. Nil when the head has no qualifying
    /// entry (or wasn't read). New optional field; absent in old cached
    /// JSON, which still decodes fine.
    public let goal: String?
    /// Layer 1 (docs/research/session-progress.md): "exploring" /
    /// "building" / "verifying" / "wrapping up", inferred from the tool
    /// mix over the tail's last `phaseWindow` classifiable tool calls,
    /// recency-weighted so explore→edit→test drift lands on the latest
    /// phase rather than the tail's plurality. A heuristic — the UI shows
    /// it only when there's no TodoWrite self-report to show instead —
    /// and nil below `phaseMinimumSignals` calls so a fresh session
    /// doesn't read "exploring" off a single Read. New optional field;
    /// absent in old cached JSON, which still decodes fine.
    public let phase: String?
    /// The session's own name from its record (user 2026-09-03: "can
    /// sessions use their names?") — rows show it instead of the repo.
    /// New optional field; absent in old cached JSON.
    public let name: String?
    /// Haiku's title for a session with no name of its own (user
    /// 2026-09-04) — the app's SessionNamer fills it; rows show it after
    /// `name` and before the repo. New optional field.
    public var autoName: String?
    /// Git branch and model from the newest transcript entry that carries
    /// them (user 2026-09-03: "populate other metadata into the session
    /// list"). New optional fields; absent in old cached JSON.
    public let gitBranch: String?
    public let model: String?
    /// Sum of `message.usage.output_tokens` across the tail.
    public let outputTokens: Int
    /// Output tokens in entries stamped within `TokenRate.window` of the
    /// read — the session's share of the tokens/minute gauge. Nil from
    /// Macs that predate it.
    public let recentOutputTokens: Int?
    /// True when the last entry that decides whether work has stopped
    /// (Transcript's notion) is an assistant API-error message.
    public let retrying: Bool
    /// The AWS profile whose sign-in lapsed, read off the newest tool
    /// results (`AwsLogin.profile(in:)`); nil when the tail's recent
    /// results carry no such signature. New optional field.
    public let awsLoginProfile: String?
    /// When that failing tool result was recorded — a login for the
    /// profile started after it clears the need.
    public let awsLoginFailedAt: Date?

    public init(lastActivityAt: Date? = nil, nowDoing: String? = nil, todos: Todos? = nil,
                title: String? = nil, goal: String? = nil, phase: String? = nil,
                name: String? = nil, gitBranch: String? = nil, model: String? = nil,
                outputTokens: Int = 0, recentOutputTokens: Int? = nil, retrying: Bool = false,
                awsLoginProfile: String? = nil, awsLoginFailedAt: Date? = nil) {
        self.lastActivityAt = lastActivityAt
        self.nowDoing = nowDoing
        self.todos = todos
        self.title = title
        self.goal = goal
        self.phase = phase
        self.name = name
        self.gitBranch = gitBranch
        self.model = model
        self.outputTokens = outputTokens
        self.recentOutputTokens = recentOutputTokens
        self.retrying = retrying
        self.awsLoginProfile = awsLoginProfile
        self.awsLoginFailedAt = awsLoginFailedAt
    }

    /// Parses a tail of JSONL lines (oldest→newest). Tolerant of a torn
    /// first line — the tail may start mid-object — lines that don't parse
    /// as a JSON object are skipped, never an error, same convention as
    /// Transcript/UsageHistory.
    public static func parse(lines: [String], now: Date = Date()) -> SessionProgress {
        let entries = jsonEntries(lines)

        var lastActivityAt: Date?
        for entry in entries.reversed() {
            if let ts = entry["timestamp"] as? String, let date = UsageHistory.parseISO(ts) {
                lastActivityAt = date
                break
            }
        }

        var nowDoing: String?
        for entry in entries.reversed() {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            if let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }) {
                nowDoing = describe(toolUse)
                break
            }
            if let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String,
               let firstLine = text.split(separator: "\n", maxSplits: 1).first,
               !firstLine.isEmpty {
                nowDoing = String(firstLine.prefix(80))
                break
            }
        }

        var todos: Todos?
        search: for entry in entries.reversed() {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_use"
                && (block["name"] as? String) == "TodoWrite" {
                guard let input = block["input"] as? [String: Any],
                      let items = input["todos"] as? [[String: Any]] else { continue }
                let done = items.filter { ($0["status"] as? String) == "completed" }.count
                let activeForm = items.first { ($0["status"] as? String) == "in_progress" }?["activeForm"] as? String
                todos = Todos(done: done, total: items.count, activeForm: activeForm)
                break search
            }
        }

        var title: String?
        for entry in entries.reversed() where (entry["type"] as? String) == "summary" {
            title = entry["summary"] as? String
            break
        }

        var outputTokens = 0
        var recentOutputTokens = 0
        let recentSince = now.addingTimeInterval(-TokenRate.window)
        for entry in entries {
            if let message = entry["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let tokens = usage["output_tokens"] as? Int {
                outputTokens += tokens
                if let ts = entry["timestamp"] as? String, let at = UsageHistory.parseISO(ts),
                   at >= recentSince {
                    recentOutputTokens += tokens
                }
            }
        }

        var lastDecisive: [String: Any]?
        for entry in entries.reversed() where Transcript.decidesTheTurn(entry) {
            lastDecisive = entry
            break
        }
        let retrying = (lastDecisive?["type"] as? String) == "assistant"
            && (lastDecisive?["isApiErrorMessage"] as? Bool) == true

        var gitBranch: String?
        var model: String?
        for entry in entries.reversed() {
            if gitBranch == nil, let branch = entry["gitBranch"] as? String, !branch.isEmpty {
                gitBranch = branch
            }
            if model == nil, let message = entry["message"] as? [String: Any],
               let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                model = m
            }
            if gitBranch != nil, model != nil { break }
        }

        let awsNeed = awsLoginNeed(entries: entries)

        return SessionProgress(lastActivityAt: lastActivityAt, nowDoing: nowDoing, todos: todos,
                                title: title, goal: goal(lines: lines), phase: phase(entries: entries),
                                gitBranch: gitBranch, model: model,
                                outputTokens: outputTokens, recentOutputTokens: recentOutputTokens,
                                retrying: retrying, awsLoginProfile: awsNeed?.profile,
                                awsLoginFailedAt: awsNeed?.failedAt)
    }

    /// The AWS profile whose sign-in lapsed, off the newest tool results
    /// in `entries` — a session's own tail, or one sub-agent's (#149) —
    /// and when the failing result was recorded. Only the newest tool
    /// results count: once the transcript moves on the signature scrolls
    /// out and the need clears. The session need not call `aws login` in
    /// any particular way: any aws command that fails with the CLI's
    /// expired-session error (or the cred broker's "Fix:" line) is the
    /// signal. When the error names no profile, the failed command's own
    /// --profile / AWS_PROFILE does (found by tool_use_id).
    static func awsLoginNeed(entries: [[String: Any]]) -> (profile: String, failedAt: Date?)? {
        // Tool calls only: attachments, hook summaries, turn stats and
        // thinking/text turns pad a transcript by ~8 lines per call, so
        // a raw-line window lost the failed call as soon as the session
        // reported it, and a message window within a minute of a session
        // that kept working (the aws-login sim, 2026-09-03). A tool_use
        // and its result are two entries.
        let recent = Array(entries.filter { entry in
            guard let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { ($0["type"] as? String) == "tool_use" || ($0["type"] as? String) == "tool_result" }
        }.suffix(awsLoginScanEntries * 2))
        func command(forToolUse id: String) -> String? {
            for entry in recent {
                guard let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_use" && (block["id"] as? String) == id {
                    return (block["input"] as? [String: Any])?["command"] as? String
                }
            }
            return nil
        }
        for entry in recent.reversed() {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_result" {
                let text: String
                if let s = block["content"] as? String {
                    text = s
                } else if let parts = block["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else { continue }
                guard let profile = AwsLogin.profile(in: text) else { continue }
                let failedAt = (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO)
                if profile == "default", let id = block["tool_use_id"] as? String,
                   let cmd = command(forToolUse: id), let named = AwsLogin.profile(inCommand: cmd) {
                    return (named, failedAt)
                }
                return (profile, failedAt)
            }
        }
        return nil
    }

    /// A sub-agent's lapsed sign-in, attributed to the PARENT (#149): the
    /// parent reads the error off the sub-agent's result and never runs
    /// the aws command itself, so its own tail carries no signature.
    /// Agent transcripts untouched for `window` are skipped without a
    /// read (some sessions accumulate hundreds; see findSubagentLimits);
    /// among the rest the newest failure wins.
    static let subagentAwsLoginWindow: TimeInterval = 30 * 60
    static func subagentAwsLoginNeed(transcript: URL, now: Date = Date(),
                                     window: TimeInterval = subagentAwsLoginWindow) -> (profile: String, failedAt: Date?)? {
        let subagentsDir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        var newest: (profile: String, failedAt: Date?)?
        for file in Transcript.agentFiles(under: subagentsDir) {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate), now.timeIntervalSince(mtime) <= window else { continue }
            guard let lines = tailLines(of: file, maxBytes: 128 * 1024),
                  let need = awsLoginNeed(entries: jsonEntries(lines)) else { continue }
            if newest == nil || (need.failedAt ?? .distantPast) > (newest?.failedAt ?? .distantPast) {
                newest = need
            }
        }
        return newest
    }

    static func jsonEntries(_ lines: [String]) -> [[String: Any]] {
        lines.compactMap { line in
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    /// The last `maxBytes` of a transcript as lines; nil when unreadable.
    static func tailLines(of url: URL, maxBytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return nil }
        return blob.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
    }

    static let phaseWindow = 24
    static let phaseMinimumSignals = 4

    /// Later phases win ties, and "wrapping up" is decisive on its own:
    /// commits and pushes are sparse, so one in the last three calls
    /// outranks the weighted mix.
    private enum Phase: Int, Comparable {
        case exploring, building, verifying, wrappingUp
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .exploring: return "exploring"
            case .building: return "building"
            case .verifying: return "verifying"
            case .wrappingUp: return "wrapping up"
            }
        }
    }

    private static func phase(entries: [[String: Any]]) -> String? {
        var calls: [Phase] = []
        for entry in entries {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_use" {
                if let phase = classify(block) { calls.append(phase) }
            }
        }
        let recent = Array(calls.suffix(phaseWindow))
        guard recent.count >= phaseMinimumSignals else { return nil }
        if recent.suffix(3).contains(.wrappingUp) { return Phase.wrappingUp.label }
        // Half-life of three calls: a lone Read mid-edit doesn't flip the
        // word, three test runs after a run of edits does.
        var score: [Phase: Double] = [:]
        for (i, phase) in recent.enumerated() where phase != .wrappingUp {
            score[phase, default: 0] += pow(2, Double(i + 1 - recent.count) / 3)
        }
        return score.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key.label
    }

    /// Neutral tools (TodoWrite, AskUserQuestion, messaging, unknown Bash)
    /// are uncounted. A compound Bash command takes the latest phase of any
    /// of its `&&` segments — "git add … && git commit" is the universal
    /// commit idiom. Read-only shell (cat/sed/grep/git log…) counts as
    /// exploring because bypass-mode sessions do all their reading through
    /// Bash; edits made through sed/heredocs still read as nothing —
    /// accepted, detecting shell edits isn't worth the false positives.
    private static func classify(_ toolUse: [String: Any]) -> Phase? {
        let name = toolUse["name"] as? String ?? ""
        switch name {
        case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "Agent", "Task":
            return .exploring
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return .building
        case "Bash":
            let input = toolUse["input"] as? [String: Any] ?? [:]
            let command = input["command"] as? String ?? ""
            return command.split(separator: "&&")
                .compactMap { classify(shell: $0.split(separator: " ").map(String.init)) }
                .max()
        default:
            return nil
        }
    }

    private static func classify(shell words: [String]) -> Phase? {
        guard let head = words.first else { return nil }
        let sub = words.dropFirst().first ?? ""
        if head == "git", ["commit", "push"].contains(sub) { return .wrappingUp }
        if head == "gh", sub == "pr", ["create", "ready", "merge"].contains(words.dropFirst(2).first ?? "") { return .wrappingUp }
        let runners: Set<String> = ["pytest", "xcodebuild", "make", "ctest", "tsc", "jest", "vitest", "eslint", "swiftlint"]
        if runners.contains(head) { return .verifying }
        let verbs: Set<String> = ["test", "build", "check", "lint", "typecheck"]
        if words.prefix(3).contains(where: verbs.contains) { return .verifying }
        let readers: Set<String> = ["cat", "head", "tail", "sed", "grep", "rg", "ls", "find", "stat"]
        if readers.contains(head) { return .exploring }
        if head == "git", ["log", "diff", "show", "status", "blame"].contains(sub) { return .exploring }
        return nil
    }

    /// The first real user prompt at the HEAD of the transcript (oldest→
    /// newest), skipping tool_result entries and system-injected payloads
    /// (`<command-name>`, `<system-reminder>`, etc. — anything starting
    /// with `<`). First line only, leading whitespace stripped, truncated
    /// to 100 chars.
    public static func goal(lines: [String]) -> String? {
        let entries: [[String: Any]] = lines.compactMap { line in
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        for entry in entries where (entry["type"] as? String) == "user" {
            guard let message = entry["message"] as? [String: Any] else { continue }
            let text: String?
            if let plain = message["content"] as? String {
                text = plain
            } else if let content = message["content"] as? [[String: Any]], let first = content.first {
                text = (first["type"] as? String) == "tool_result" ? nil : first["text"] as? String
            } else {
                text = nil
            }
            guard let text, let rawFirstLine = text.split(separator: "\n", maxSplits: 1).first else { continue }
            var firstLine = Substring(rawFirstLine)
            while let head = firstLine.first, head.isWhitespace { firstLine.removeFirst() }
            guard !firstLine.isEmpty, firstLine.first != "<" else { continue }
            return String(firstLine.prefix(100))
        }
        return nil
    }

    /// Reads the tail of `<claudeDir>/projects/<slug>/<sessionId>.jsonl`
    /// (same path and tail-read approach as `Transcript.lastTurnEntry`)
    /// and parses it.
    /// How many of the session's latest tool calls the AWS sign-in
    /// signature is looked for in.
    static let awsLoginScanEntries = 12

    public static func read(sessionId: String, cwd: String, claudeDir: URL,
                             name: String? = nil, maxBytes: Int = 512 * 1024) -> SessionProgress {
        let url = Transcript.locate(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        let headGoal = readGoal(sessionId: sessionId, cwd: cwd, claudeDir: claudeDir)
        let progress = parse(lines: tailLines(of: url, maxBytes: maxBytes) ?? [])
        // The session's own tail wins; a sub-agent's lapsed sign-in (#149)
        // fills in only when the parent shows none.
        let aws = progress.awsLoginProfile.map { ($0, progress.awsLoginFailedAt) }
            ?? subagentAwsLoginNeed(transcript: url)
        return SessionProgress(lastActivityAt: progress.lastActivityAt, nowDoing: progress.nowDoing,
                               todos: progress.todos, title: progress.title,
                               goal: headGoal ?? progress.goal, phase: progress.phase, name: name,
                               gitBranch: progress.gitBranch, model: progress.model,
                               outputTokens: progress.outputTokens,
                               recentOutputTokens: progress.recentOutputTokens, retrying: progress.retrying,
                               awsLoginProfile: aws?.0, awsLoginFailedAt: aws?.1)
    }

    /// Reads only the FIRST `maxBytes` of the transcript — the goal lives at
    /// the HEAD, the opposite end from everything else `read` extracts.
    public static func readGoal(sessionId: String, cwd: String, claudeDir: URL,
                                 maxBytes: Int = 64 * 1024) -> String? {
        let url = Transcript.locate(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let blob = try? handle.read(upToCount: maxBytes) else { return nil }
        let lines = blob.split(separator: UInt8(ascii: "\n"))
            .map { String(decoding: $0, as: UTF8.self) }
        return goal(lines: lines)
    }

    /// Pairs each engine-reported session with its Claude Code session
    /// record by pid; a session with no matching record is dropped — the
    /// popover row falls back to its current single-line rendering.
    public static func match(sessions: [SessionDetail], records: [ClaudeSessionRecord])
        -> [(session: SessionDetail, record: ClaudeSessionRecord)] {
        let byPid = Dictionary(records.map { (Int($0.pid), $0) }, uniquingKeysWith: { a, _ in a })
        return sessions.compactMap { s in byPid[s.pid].map { (s, $0) } }
    }

    /// Words of the first `&&` segment that isn't a cd/env preamble —
    /// compound commands open with plumbing ("cd x && swift build").
    private static func leadWords(_ command: String) -> [String] {
        let plumbing: Set<String> = ["cd", "export", "source", "set"]
        let segments = command.split(separator: "&&")
            .map { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
        return segments.first { !plumbing.contains($0[0]) } ?? segments.first ?? []
    }

    private static func describe(_ toolUse: [String: Any]) -> String {
        let name = toolUse["name"] as? String ?? ""
        let input = toolUse["input"] as? [String: Any] ?? [:]
        switch name {
        case "Read", "Edit", "Write":
            let verb = name == "Read" ? "Reading" : name == "Edit" ? "Editing" : "Writing"
            let path = input["file_path"] as? String ?? ""
            return "\(verb) \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Bash":
            let command = input["command"] as? String ?? ""
            return "Running \(leadWords(command).first ?? command)"
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            return "Searching \(pattern.prefix(40))"
        default:
            return name
        }
    }
}

/// Compact per-session row for a fleet panel (the Linux Quickshell panel,
/// issue #13 step 4) — repo name, status, and a one-line progress
/// summary. Pure mapping from a live session record + its
/// transcript-derived progress, so it's testable without touching disk.
public struct SessionPanelRow: Sendable, Equatable, Codable {
    public let repo: String
    public let status: String
    public let nowDoing: String?
    public let todosDone: Int?
    public let todosTotal: Int?
    public let activeForm: String?
    public let retrying: Bool
    public let quietMinutes: Int?
    public let goal: String?
    public let phase: String?
    /// The AWS profile whose session expired under this session (the
    /// Mac popup's key badge; the tray's "needs AWS login" line). New
    /// optional field.
    public let awsLoginProfile: String?

    public init(repo: String, status: String, nowDoing: String? = nil, todosDone: Int? = nil,
                todosTotal: Int? = nil, activeForm: String? = nil, retrying: Bool = false,
                quietMinutes: Int? = nil, goal: String? = nil, phase: String? = nil,
                awsLoginProfile: String? = nil) {
        self.repo = repo
        self.status = status
        self.nowDoing = nowDoing
        self.todosDone = todosDone
        self.todosTotal = todosTotal
        self.activeForm = activeForm
        self.retrying = retrying
        self.quietMinutes = quietMinutes
        self.goal = goal
        self.phase = phase
        self.awsLoginProfile = awsLoginProfile
    }

    /// `repo` is the last path component of the record's cwd. `quietMinutes`
    /// is present only once the transcript has been silent over 120s — same
    /// threshold as the macOS popover's SessionProgressLine.
    public static func make(record: ClaudeSessionRecord, progress: SessionProgress,
                             now: Date = Date()) -> SessionPanelRow {
        let quietMinutes: Int? = progress.lastActivityAt.flatMap { last in
            let idle = now.timeIntervalSince(last)
            return idle > 120 ? Int(idle / 60) : nil
        }
        return SessionPanelRow(
            repo: URL(fileURLWithPath: record.cwd).lastPathComponent,
            status: record.status ?? "",
            nowDoing: progress.nowDoing,
            todosDone: progress.todos?.done,
            todosTotal: progress.todos?.total,
            activeForm: progress.todos?.activeForm,
            retrying: progress.retrying,
            quietMinutes: quietMinutes,
            goal: progress.goal,
            phase: progress.phase,
            awsLoginProfile: progress.awsLoginProfile)
    }
}

/// The fleet-wide output-token rate (user 2026-09-03 "display
/// tokens/minute gauge on live activities, popup"): every live session's
/// output tokens over the last `window`, per minute, plus the peak the
/// host has seen lately so a gauge has a scale.
public struct TokenRate: Codable, Sendable, Equatable {
    /// How far back a session's transcript counts.
    public static let window: TimeInterval = 5 * 60
    public let perMinute: Int
    public let peakPerMinute: Int

    public init(perMinute: Int, peakPerMinute: Int) {
        self.perMinute = perMinute
        self.peakPerMinute = max(peakPerMinute, perMinute)
    }

    /// Sum of every session's recent tokens, per minute. A session whose
    /// last entry is older than the window contributes nothing — its
    /// cached count is from a read that was inside the window.
    public static func perMinute(_ byPid: [Int: SessionProgress], now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-window)
        let total = byPid.values.reduce(0) { sum, p in
            guard let at = p.lastActivityAt, at >= since else { return sum }
            return sum + (p.recentOutputTokens ?? 0)
        }
        return Int((Double(total) / (window / 60)).rounded())
    }

    /// The peak decays a little every tick, so a burst an hour ago stops
    /// dwarfing the gauge — ~halved after 100 ticks.
    public static func nextPeak(_ peak: Int, seeing perMinute: Int) -> Int {
        max(perMinute, Int(Double(peak) * 0.993))
    }

    /// 0…1 of peak for the gauge; a quiet fleet reads empty, not full.
    public var fraction: Double {
        peakPerMinute > 0 ? min(1, Double(perMinute) / Double(peakPerMinute)) : 0
    }

    /// "1.2k/min", "340/min".
    public var label: String { count + "/min" }

    /// The chip under a theme (#218): "1.2k mana/min", "340 baud".
    public func label(theme: RowTheme) -> String {
        theme.rateUnit.map { count + " " + $0 } ?? label
    }

    private var count: String {
        perMinute >= 1000 ? String(format: "%.1fk", Double(perMinute) / 1000) : "\(perMinute)"
    }
}
