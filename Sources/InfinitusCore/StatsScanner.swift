import Foundation

/// Claude Code transcripts → `Stats.Day`s. `ingest` is the pure per-entry
/// step; `scan` (Task 3) walks the files with a byte-offset cache the way
/// `TokenRateScanner` does. Nothing is summarized — every count is a
/// field Claude Code already writes.
public enum StatsScanner {
    public enum UserKind: Equatable {
        case human, phone, agent, nudge, compaction, toolResult, machinery
    }

    /// Carry-over between appended chunks of one transcript.
    public struct ScanState: Codable, Equatable, Sendable {
        public var lastMessageID: String?
        /// Turn end (final assistant text / a question) awaiting the next
        /// human or phone message — the "waiting on you" clock.
        public var turnEndedAt: Double?
        public var toolsSinceHuman = 0
        /// Per day: first and last entry instants, for session seconds.
        public var firstAt: [String: Double] = [:]
        public var lastAt: [String: Double] = [:]
        /// The stretch the assistant is in right now (Stats v2) — nil
        /// before the first person/agent message of the file.
        public var stretch: Stretch?
        /// Codex: the model and effort the last `turn_context` named —
        /// its token counts don't carry them.
        public var codexModel = ""
        public var codexEffort = ""
        public init() {}
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public var size = 0
        public var offset = 0
        public var cwd: String?
        public var days: [String: Stats.Day] = [:]
        public var state = ScanState()
        /// True for `<project>/<session-id>/subagents/agent-*.jsonl` — a
        /// subagent's own transcript. `ingest` gates on this: only
        /// tokens/usd/toolCalls/toolErrors/retries/compactions/subagents
        /// count; everything session/message/turn-shaped is the
        /// PARENT session's business, not this file's (the subagent's
        /// first "user" entry is its prompt FROM the parent, which would
        /// otherwise double as a human message).
        public var subagent = false
        /// Which tool's transcript this is — `parse` picks the reader.
        public var engine = Stats.Engine.claude.rawValue
        public init() {}
    }

    static let waitingCap = 8.0 * 3600

    /// One entry's presence on a day: the session, the hour slot, and
    /// the session's span so far (its length bucket moves with it).
    static func noteSession(_ day: inout Stats.Day, key: String, at t: Double, sessionID: String,
                            into entry: inout FileEntry, calendar: Calendar) {
        day.sessions.insert(sessionID)
        day.hourSlots[Stats.hourSlot(Date(timeIntervalSince1970: t), calendar: calendar)] += 1
        if entry.state.firstAt[key] == nil { entry.state.firstAt[key] = t }
        entry.state.lastAt[key] = t
        day.sessionSeconds = entry.state.lastAt[key]! - entry.state.firstAt[key]!
        day.sessionBuckets = [0, 0, 0, 0]
        day.sessionBuckets[Stats.Day.sessionBucket(seconds: day.sessionSeconds)] = 1
    }

    /// Fold the open stretch into the day it was opened on. `day` is the
    /// caller's working copy of `currentKey` (written back at the end of
    /// `ingest`), so a same-day close must go through it, not through
    /// `entry.days`, or the write-back would overwrite the fold.
    static func closeStretch(into entry: inout FileEntry, current day: inout Stats.Day, currentKey: String) {
        guard let s = entry.state.stretch else { return }
        entry.state.stretch = nil
        if s.dayKey == currentKey {
            day.add(stretch: s)
        } else {
            var other = entry.days[s.dayKey] ?? Stats.Day()
            other.add(stretch: s)
            entry.days[s.dayKey] = other
        }
    }

    static func feedStretch(_ s: inout Stretch, tool name: String, input: [String: Any]) {
        if s.label == nil, let vote = ActivitySignals.label(tool: name, input: input) { s.label = vote.rawValue }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            s.edits += 1
            if ActivitySignals.isTestPath(input["file_path"] as? String ?? input["notebook_path"] as? String ?? "") { s.testEdits += 1 }
        case "Bash": s.bash += 1
        default: break
        }
    }

    /// The person's words in a user entry (a peer message unwrapped),
    /// nil for tool results and machinery.
    public static func userText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return wrappedBody(s) }
        guard let blocks = message["content"] as? [[String: Any]],
              !blocks.contains(where: { ($0["type"] as? String) == "tool_result" }),
              let t = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else { return nil }
        return wrappedBody(t)
    }

    public static func classifyUser(_ obj: [String: Any]) -> UserKind {
        if (obj["isCompactSummary"] as? Bool) == true { return .compaction }
        guard let message = obj["message"] as? [String: Any] else { return .machinery }
        var text: String?
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return .toolResult }
            if let t = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                text = t
            } else if blocks.contains(where: { ($0["type"] as? String) == "image" }) {
                text = "[image]"
            }
        }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .machinery }
        if machineryPrefixes.contains(where: { raw.hasPrefix($0) }) { return .machinery }
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String {
            switch kind {
            case "human": return .human
            case "peer":
                let from = origin["from"] as? String ?? ""
                // `origin.body` is the sender's own text, already
                // unwrapped — `raw` is Claude Code's rendering of it
                // ("Another Claude session sent a message:\n<wrapper>…"),
                // so a prefix test against the wrapper never matched and
                // every nudge fell through to `.phone`.
                let body = (origin["body"] as? String) ?? wrappedBody(raw)
                return peerKind(fromApp: from.contains("/tmp/infinitus-"), body: body)
            default: return .machinery   // task-notification, auto-continuation, …
            }
        }
        // Older transcripts: no origin. The text decides — and the
        // wrapper sits INSIDE Claude Code's preamble, never at the very
        // front, so this has to look for it before judging the first
        // character.
        if raw.contains(crossSessionTag) {
            let fromApp: Bool = {
                guard let r = raw.range(of: "from-name=\""), let q = raw[r.upperBound...].firstIndex(of: "\"") else { return false }
                let name = raw[r.upperBound..<q]
                return name == "Infinitus" || name == PeerSocket.senderName
            }()
            return peerKind(fromApp: fromApp, body: wrappedBody(raw))
        }
        // The same preamble also carries teammate envelopes
        // (`<teammate-message teammate_id=…>`): never the app, never the
        // phone — another agent (46 of 46 in a 60-file probe, 2026-09-04).
        if raw.hasPrefix(peerPreamble) { return .agent }
        guard raw.first == "<" else { return .human }
        return .machinery
    }

    /// A `type=user` text the CLI wrote for the machine, not something
    /// the person typed: interrupts, hook feedback, the resumed-session
    /// caveat banner, the autonomous-loop preamble (spec defect, ruled
    /// 2026-09-04). `[Image:` and pasted skill bodies deliberately stay
    /// `.human` — the user pasted them / typed the slash command.
    static let machineryPrefixes = [
        "[Request interrupted",
        "Stop hook feedback:",
        "Caveat:",
        "# Autonomous loop tick",
        "[1 prior /loop",
        "(Re-invocation of /",
    ]

    private static let crossSessionTag = "<cross-session-message"
    private static let peerPreamble = "Another Claude session sent a message"

    /// The socket preface's first 48 characters — enough to tell a phone
    /// message from the app's own "[Infinitus] …" nudge text without
    /// retyping the whole preface.
    private static let phoneMarker = String(PeerSocket.phonePreface.prefix(48))

    private static func peerKind(fromApp: Bool, body: String) -> UserKind {
        guard fromApp else { return .agent }
        if body.hasPrefix(phoneMarker) { return .phone }
        if body.hasPrefix("[Infinitus]") { return .nudge }
        return .phone
    }

    /// The text inside a `<cross-session-message …>` wrapper (or the
    /// text itself). The wrapper is not at the front: Claude Code
    /// prefixes "Another Claude session sent a message:\n" and appends
    /// its own guidance after the closing tag.
    static func wrappedBody(_ raw: String) -> String {
        guard let open = raw.range(of: crossSessionTag),
              let end = raw[open.upperBound...].firstIndex(of: ">") else { return raw }
        var body = String(raw[raw.index(after: end)...])
        if let close = body.range(of: "</cross-session-message>") { body = String(body[..<close.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sessionID`: the parent session id for a subagent file (the
    /// `<session-id>` directory name it lives under) — unused when
    /// `entry.subagent` is true, kept for an honest signature.
    public static func ingest(_ obj: [String: Any], sessionID: String, into entry: inout FileEntry,
                              calendar: Calendar = .current) {
        guard let type = obj["type"] as? String, type == "user" || type == "assistant",
              let stamp = obj["timestamp"] as? String, let t = TokenRateScanner.parseStamp(stamp) else { return }
        if entry.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { entry.cwd = cwd }
        let isSubagent = entry.subagent
        let date = Date(timeIntervalSince1970: t)
        let key = Stats.dayKey(date, calendar: calendar)
        // Take the day OUT of the dictionary while it is worked on: a copy
        // left behind would make every mutation below copy the Day's
        // dictionaries (Swift copy-on-write), ~250 µs per entry. Written
        // back at the end.
        var day = entry.days.removeValue(forKey: key) ?? Stats.Day()
        // A subagent transcript is the parent session's own work under
        // another name — it doesn't add a session, an hour-of-day entry,
        // or its own session-length bucket; only the token/cost/tool
        // facts below are its contribution.
        if !isSubagent {
            noteSession(&day, key: key, at: t, sessionID: sessionID, into: &entry, calendar: calendar)
        }
        let effort = obj["effort"] as? String ?? "unset"

        if type == "user" {
            if !isSubagent, obj["toolDenialKind"] != nil { day.denials += 1 }
            let kind = classifyUser(obj)
            if !isSubagent, [.human, .phone, .agent, .nudge].contains(kind) {
                closeStretch(into: &entry, current: &day, currentKey: key)
                var stretch = Stretch(dayKey: key, at: t)
                if kind == .human || kind == .phone, let text = userText(obj) {
                    stretch.promptLabel = ActivitySignals.label(prompt: text)?.rawValue
                }
                entry.state.stretch = stretch
            }
            switch kind {
            case .human, .phone:
                // The trap: a subagent's first "user" entry is its prompt
                // FROM the parent, not a human typing — never a message.
                guard !isSubagent else { break }
                if kind == .human { day.humanMessages += 1 } else { day.phoneMessages += 1 }
                if let ended = entry.state.turnEndedAt {
                    day.waitingSeconds += min(waitingCap, max(0, t - ended))
                    entry.state.turnEndedAt = nil
                }
                day.longestUnattended = max(day.longestUnattended, entry.state.toolsSinceHuman)
                entry.state.toolsSinceHuman = 0
            case .agent: if !isSubagent { day.agentMessages += 1 }
            case .nudge: if !isSubagent { day.nudges += 1 }
            case .compaction: day.compactions += 1
            case .toolResult:
                if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    day.toolErrors += blocks.filter { ($0["is_error"] as? Bool) == true }.count
                }
            case .machinery: break
            }
        } else {
            if (obj["isApiErrorMessage"] as? Bool) == true { day.retries += 1 }
            if let message = obj["message"] as? [String: Any] {
                let id = message["id"] as? String
                let model = message["model"] as? String ?? ""
                if let usage = message["usage"] as? [String: Any], !model.hasPrefix("<"),
                   id == nil || id != entry.state.lastMessageID {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let output = usage["output_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                    var cost = 0.0
                    var savings = 0.0
                    if let p = StaticPriceTable.price(model: model) {
                        cost = (Double(input) * p.input + Double(output) * p.output
                            + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
                        savings = Double(cacheRead) * max(0, p.input - p.cacheRead) / 1_000_000
                    }
                    day.inputTokens += input
                    day.outputTokens += output
                    day.usd += cost
                    day.cacheReadTokens += cacheRead
                    day.cacheWriteTokens += cacheWrite
                    day.cacheSavingsUSD += savings
                    if output > 0 { day.minuteTokens[Stats.minuteOfDay(t, calendar: calendar), default: 0] += output }
                    // Per model / engine / effort, per entry — exact, and
                    // the only route a sub-agent file's spend takes into
                    // v2. An empty model name has nothing to key under;
                    // the day totals above still count it.
                    day.charge(model: model, engine: entry.engine, effort: effort,
                               input: input, output: output, usd: cost,
                               cacheRead: cacheRead, cacheWrite: cacheWrite, savings: savings)
                    if entry.state.stretch != nil {
                        entry.state.stretch!.model = model
                        entry.state.stretch!.effort = effort
                        entry.state.stretch!.inputTokens += input
                        entry.state.stretch!.outputTokens += output
                        entry.state.stretch!.usd += cost
                    }
                }
                if let id { entry.state.lastMessageID = id }
                if !isSubagent, entry.state.stretch != nil, !model.hasPrefix("<") {
                    entry.state.stretch!.entries += 1
                    entry.state.stretch!.lastAt = max(entry.state.stretch!.lastAt, t)
                }
                if let blocks = message["content"] as? [[String: Any]] {
                    var sawText = false, sawTool = false
                    for block in blocks {
                        switch block["type"] as? String {
                        case "tool_use":
                            sawTool = true
                            let name = block["name"] as? String ?? "?"
                            let input = block["input"] as? [String: Any] ?? [:]
                            day.toolCalls[name, default: 0] += 1
                            if !isSubagent { entry.state.toolsSinceHuman += 1 }
                            if name == "Agent" { day.subagents += 1 }
                            if name == "AskUserQuestion", !isSubagent {
                                day.questions += 1
                                if entry.state.turnEndedAt == nil { day.turns += 1 }
                                entry.state.turnEndedAt = t
                            }
                            if !isSubagent, entry.state.stretch != nil {
                                feedStretch(&entry.state.stretch!, tool: name, input: input)
                            }
                        case "text": sawText = true
                        default: break
                        }
                    }
                    if !isSubagent, entry.state.stretch != nil, !model.hasPrefix("<") {
                        entry.state.stretch!.endedInProse = sawText && !sawTool
                    }
                    // A text block with no tool call beside it ends the turn:
                    // the next thing the transcript needs is a person.
                    // (Never for a subagent file — it has no turns of its own.)
                    if !isSubagent, sawText, !sawTool, !model.hasPrefix("<") {
                        if entry.state.turnEndedAt == nil { day.turns += 1 }
                        entry.state.turnEndedAt = t
                    }
                }
            }
        }
        entry.days[key] = day
    }

    public struct Result: Sendable {
        public var days: [String: Stats.Day] = [:]
        public var cwds: Set<String> = []
        public var files = 0
        /// Files that still need a parse after this call (size changed,
        /// budget exhausted before catching them up) — 0 means the corpus
        /// is fully caught up as of this call.
        public var remaining = 0
        /// Bytes still owed across every file counted in `remaining` — 0
        /// once `remaining` is 0.
        public var bytesRemaining = 0
        /// Bytes owed across every dirty file as of the START of this
        /// call, before this call's budget spent any of it — the
        /// denominator for a "scanned X of Y" readout.
        public var bytesTotal = 0
        /// Every file the scan folded, keyed by path — cwd, engine, the
        /// per-day tallies and the session span — so a caller can fold
        /// its own subset (the team publisher drops excluded projects).
        public var entries: [String: FileEntry] = [:]
    }

    struct Cache: Codable {
        /// 9 (2026-09-06): cache reads/writes and cache savings (#139)
        /// need every file re-read once to backfill them; 8 (2026-09-05)
        /// the Day decoder finally keeps the minute buckets and workflow
        /// sub-agent transcripts are walked, so every file is re-read
        /// once; 7 added per-minute output tokens for the tokens/min
        /// record book (#89); 6 was `byEngine`/`byEffort` and the Codex
        /// source; 5 was Stats v2's activities/models.
        var version = 9
        var files: [String: FileEntry] = [:]
    }

    /// Codex CLI's transcripts: `$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl`
    /// (`~/.codex` by default) — see `StatsCodex`.
    public static func defaultCodexDir(home: String = NSHomeDirectory(),
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".codex")
        return root.appendingPathComponent("sessions")
    }

    /// One caller's decoded cache, carried between the passes of a
    /// chunked backfill so each pass doesn't decode and re-encode the
    /// whole corpus's JSON (15 MB, ~2.7 s per pass, 150 passes for a
    /// rebuild — 2026-09-05). Disk gets a checkpoint every
    /// `checkpointInterval` and the final state when the pass finishes
    /// the corpus; an interrupted backfill loses at most that interval.
    public final class CacheHandle: @unchecked Sendable {
        var cache: Cache?
        /// Starts "now": the first checkpoint follows a full interval, so
        /// a one-pass refresh writes once, at the end.
        var lastWrite = Date()
        /// The last pass found the corpus caught up. The first settled
        /// pass writes the finished corpus; later ones write on the
        /// settled cadence.
        var caughtUp = false
        /// The held cache moved since it last reached disk.
        var dirty = false
        /// The last pass's `Result.days` (#499): a pass touches a handful
        /// of files, so only the days those files cover are summed again;
        /// every other day is this, as it was.
        var sums: [String: Stats.Day]?
        public init() {}
    }
    public static let checkpointInterval: TimeInterval = 30
    /// A handle held across refreshes (the app's `StatsModel` keeps one
    /// for its lifetime, #346) rewrites a caught-up corpus at most this
    /// often: the cache is ~24 MB of JSON on a year of transcripts, and
    /// encoding it after every 5-minute pass — because some live session
    /// always moved — cost more than the pass itself. A quit in between
    /// loses only the watermarks since the last write; the next launch
    /// re-reads those bytes.
    public static let settledWriteInterval: TimeInterval = 600

    /// One cache per Claude config home: an instance pointed at another
    /// `CLAUDE_CONFIG_DIR` (a fixture, a dev run) gets its own file,
    /// named the way Claude names its project dirs, and never touches
    /// the real corpus's — a nine-file fixture cache once replaced a
    /// year's 20 MB one, and the next bundle launch re-read every
    /// transcript (2026-09-10).
    public static func defaultCacheURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dir = AppSupport.root(environment: environment).appendingPathComponent("stats")
        if let home = environment["CLAUDE_CONFIG_DIR"], !home.isEmpty {
            let tag = home.map { $0 == "/" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            return dir.appendingPathComponent("transcripts-\(tag).json")
        }
        return dir.appendingPathComponent("transcripts.json")
    }

    private static func writeCache(_ cache: Cache, to cacheURL: URL, fm: FileManager) {
        guard let data = try? encodeCache(cache) else { return }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// The cache's bytes, one file entry at a time (#499). `JSONEncoder`
    /// builds the whole value tree before it serializes: on 11k files
    /// that peaked +127 MB over the decoded cache for a 14 MB output and
    /// left ~45 MB behind, on every checkpoint and every settled rewrite
    /// (measured 2026-09-11). Entry by entry the peak is +16 MB, the time
    /// the same, and the bytes decode to an equal cache — the same
    /// `{"version":…,"files":{…}}` the synthesized encoder wrote, so no
    /// version bump. Every key sorted (the file keys here, the nested ones
    /// by the encoder), so two writes of one cache are the same bytes.
    static func encodeCache(_ cache: Cache) throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[Stats.Day.leanEncoding] = true   // #499: defaults out, hours sparse
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        out.append(Data("{\"version\":\(cache.version),\"files\":{".utf8))
        for (i, key) in cache.files.keys.sorted().enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(try encoder.encode([key]).dropFirst().dropLast())   // the quoted, escaped key
            out.append(UInt8(ascii: ":"))
            out.append(try encoder.encode(cache.files[key]!))
        }
        out.append(Data("}}".utf8))
        return out
    }

    /// Bytes a file still owes given its cached read watermark. A file
    /// that shrank below where we'd already read owes its FULL size (the
    /// scan below resets and re-reads it from zero), not `size - offset`
    /// (which would go negative and clamp to 0 — silently reporting a
    /// file that needs a full re-read as needing nothing at all).
    private static func owed(size: Int, offset: Int) -> Int {
        offset > size ? size : size - offset
    }

    /// Every `*.jsonl` under `projectsDir` (one directory per project),
    /// parsed from each file's byte watermark in bounded windows
    /// (`parse`), newest-modified first. Files untouched for `maxAge`
    /// are skipped. The cache keeps only files that still exist.
    ///
    /// `byteBudget` caps how many bytes get actually READ this call
    /// (nil = unbounded) — files whose size is unchanged cost nothing
    /// and don't count against it. A file only latches its cached `size`
    /// (marking it caught up) once it's been read all the way to the end
    /// — a file the budget ran out partway through stays "dirty" for the
    /// next call, however much of it this call got through. That's what
    /// keeps one huge (654 MB seen in practice) transcript from either
    /// blocking every chunk until it's fully read or getting silently
    /// marked done half-read. `Result.remaining`/`bytesRemaining` say
    /// what's still owed; callers backfilling a large corpus call
    /// repeatedly (newest data first) until `remaining` hits 0. The
    /// cache is written atomically every 200 files touched inside a pass
    /// and once more at the end, so an interrupted backfill loses at
    /// most one checkpoint's worth of work.
    ///
    /// `windowBytes` (default `Self.windowBytes`, 8 MB) exists as a
    /// parameter only so tests can shrink it to exercise multi-window
    /// files deterministically without a multi-MB fixture; every real
    /// caller uses the default.
    public static func scan(projectsDir: URL, codexDir: URL? = nil, cacheURL: URL?, calendar: Calendar = .current,
                            maxAge: TimeInterval = 400 * 86_400, now: Date = Date(),
                            byteBudget: Int? = nil, windowBytes: Int = StatsScanner.windowBytes,
                            handle: CacheHandle? = nil) -> Result {
        var cache = handle?.cache
            ?? cacheURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        if cache.version != Cache().version { cache = Cache() }
        // Without a handle the checkpoint cadence is the old one (every
        // 200 files touched); with one it is wall-clock, tracked there.
        func checkpointDue(_ filesTouched: Int) -> Bool {
            guard let handle else { return filesTouched % 200 == 0 }
            return Date().timeIntervalSince(handle.lastWrite) >= checkpointInterval
        }
        func write(_ c: Cache, to url: URL) {
            writeCache(c, to: url, fm: fm)
            handle?.lastWrite = Date()
            handle?.dirty = false
        }
        let fm = FileManager.default

        // `subagent`: true for `<project>/<session-id>/subagents/*.jsonl`
        // and `…/subagents/workflows/<run>/*.jsonl` (fixed depths below a
        // session dir, not a recursive walk).
        // `sessionID`: the file's own transcript id normally, or the
        // PARENT session dir's name for a subagent file.
        struct Candidate {
            let url: URL; let size: Int; let mtime: Date; let subagent: Bool; let sessionID: String
            var engine = Stats.Engine.claude
        }
        var candidates: [Candidate] = []
        func addCandidate(_ url: URL, subagent: Bool, sessionID: String, engine: Stats.Engine = .claude) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return }
            let mtime = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) > maxAge { return }
            candidates.append(Candidate(url: url, size: size, mtime: mtime, subagent: subagent, sessionID: sessionID,
                                        engine: engine))
        }
        for project in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            // The app's own Haiku session-namer runs `claude -p` in
            // Infinitus/namer — its transcripts are not your work.
            if project.lastPathComponent.hasSuffix("-Infinitus-namer") { continue }
            for url in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])) ?? [] {
                if url.pathExtension == "jsonl" {
                    addCandidate(url, subagent: false, sessionID: url.deletingPathExtension().lastPathComponent)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let sessionID = url.lastPathComponent
                    let subagentsDir = url.appendingPathComponent("subagents")
                    for sub in (try? fm.contentsOfDirectory(at: subagentsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                    where sub.pathExtension == "jsonl" {
                        addCandidate(sub, subagent: true, sessionID: sessionID)
                    }
                    // Workflow runs keep their agents one level deeper:
                    // `subagents/workflows/<run>/agent-*.jsonl` — a day of
                    // three parallel streams was invisible to every stat
                    // and the tokens/min peak read a tenth of the truth
                    // (2026-09-05).
                    let workflowsDir = subagentsDir.appendingPathComponent("workflows")
                    for run in (try? fm.contentsOfDirectory(at: workflowsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                        for sub in (try? fm.contentsOfDirectory(at: run, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                        where sub.pathExtension == "jsonl" {
                            addCandidate(sub, subagent: true, sessionID: sessionID)
                        }
                    }
                }
            }
        }
        // Codex CLI: `sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`,
        // the file name doubling as the session id.
        if let codexDir, let walk = fm.enumerator(at: codexDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in walk where url.pathExtension == "jsonl" {
                addCandidate(url, subagent: false, sessionID: url.deletingPathExtension().lastPathComponent, engine: .codex)
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // Bytes still owed across every dirty file, before this call spends any budget.
        var bytesTotal = 0
        for c in candidates {
            let cached = cache.files[c.url.path]
            if cached == nil || cached!.size != c.size {
                bytesTotal += owed(size: c.size, offset: cached?.offset ?? 0)
            }
        }

        var live: [String: FileEntry] = [:]
        var result = Result()
        result.bytesTotal = bytesTotal
        var budgetLeft = byteBudget
        var budgetSpent = false
        var filesTouched = 0
        // Paths whose entry differs from the last pass's — parsed, new,
        // or gone — the only ones whose days need summing again.
        var changed: Set<String> = []

        for (i, c) in candidates.enumerated() {
            let cached = cache.files[c.url.path]
            let dirty = cached == nil || cached!.size != c.size

            if budgetSpent {
                // The pass is over — carry the cached state forward
                // untouched (a brand-new never-cached file is simply left
                // out; it's picked up fresh next call) and count every
                // still-dirty one toward what's owed.
                if let cached { live[c.url.path] = cached }
                result.files += 1
                if let cwd = cached?.cwd { result.cwds.insert(cwd) }
                if dirty {
                    result.remaining += 1
                    result.bytesRemaining += owed(size: c.size, offset: cached?.offset ?? 0)
                }
                continue
            }

            var entry = cached ?? FileEntry()
            entry.subagent = c.subagent
            entry.engine = c.engine.rawValue
            if dirty {
                if c.size < entry.offset { entry = FileEntry(); entry.subagent = c.subagent; entry.engine = c.engine.rawValue }   // shrink: start over
                while entry.offset < c.size {
                    if let left = budgetLeft, left <= 0 { budgetSpent = true; break }
                    let consumed = parse(url: c.url, sessionID: c.sessionID,
                                        into: &entry, calendar: calendar, windowBytes: windowBytes)
                    if consumed <= 0 {
                        // Nothing more to read right now: an unreadable
                        // file, or a trailing line that hasn't been
                        // newline-terminated yet. Retrying this call
                        // can't help either way, so latch `size` now —
                        // leaving it dirty forever would spin the caller
                        // (StatsModel's chunk loop) with no way out. The
                        // file becomes dirty again on its own once it
                        // actually grows (e.g. that last line finally
                        // gets its newline), picking up right where
                        // `offset` was left.
                        entry.size = c.size
                        break
                    }
                    if budgetLeft != nil { budgetLeft! -= consumed }
                }
                if entry.offset >= c.size { entry.size = c.size }   // caught up — only now does size==entry.size latch
                filesTouched += 1
                if let cacheURL, checkpointDue(filesTouched) {
                    var checkpoint = live
                    checkpoint[c.url.path] = entry
                    for other in candidates[(i + 1)...] where cache.files[other.url.path] != nil {
                        checkpoint[other.url.path] = cache.files[other.url.path]
                    }
                    var cp = cache
                    cp.files = checkpoint
                    write(cp, to: cacheURL)
                }
            }
            live[c.url.path] = entry
            if dirty { changed.insert(c.url.path) }
            result.files += 1
            if let cwd = entry.cwd { result.cwds.insert(cwd) }
            if entry.size != c.size {
                result.remaining += 1
                result.bytesRemaining += owed(size: c.size, offset: entry.offset)
            }
        }
        // Nothing parsed and nothing vanished: what's on disk already
        // says exactly this, and rewriting the whole corpus's JSON on
        // every 5-minute refresh is pure IO. The checkpoint writes
        // inside a backfill above are untouched.
        for path in cache.files.keys where live[path] == nil { changed.insert(path) }
        // Every file's share of a day is in before the day's peak is
        // taken: the peak minute is the sum across sessions, not any one
        // file's. With a handle, the last pass's sums stand for every day
        // no changed file covers (#499: a five-minute pass re-summed
        // 24,000 file-days for one live session's few); a first pass, or
        // one without a handle, sums everything.
        var affected: Set<String>
        if let previous = handle?.sums, handle?.cache != nil {
            affected = []
            for path in changed {
                if let e = cache.files[path] { affected.formUnion(e.daysWithOpenStretch().keys) }
                if let e = live[path] { affected.formUnion(e.daysWithOpenStretch().keys) }
            }
            result.days = previous
            for key in affected { result.days[key] = nil }
        } else {
            affected = Set(live.values.flatMap { $0.daysWithOpenStretch().keys })
        }
        if !affected.isEmpty {
            for entry in live.values {
                for (key, day) in entry.daysWithOpenStretch() where affected.contains(key) {
                    result.days[key] = (result.days[key] ?? Stats.Day()) + day
                }
            }
            for key in affected where result.days[key] != nil { result.days[key]!.finalizePeak() }
        }
        handle?.sums = result.days
        let unchanged = filesTouched == 0 && live.count == cache.files.count && handle?.dirty != true
        cache.files = live
        handle?.cache = cache
        if !unchanged { handle?.dirty = true }
        // A held cache reaches disk when a checkpoint is due mid-backfill,
        // once when the corpus catches up, then on the settled cadence;
        // otherwise the next pass carries it.
        let due: Bool
        if let handle {
            let settled = result.remaining == 0
            due = settled
                ? !handle.caughtUp || Date().timeIntervalSince(handle.lastWrite) >= settledWriteInterval
                : checkpointDue(1)
            handle.caughtUp = settled
        } else {
            due = true
        }
        if let cacheURL, !unchanged, due { write(cache, to: cacheURL) }
        result.entries = live
        return result
    }

    private static let userMarker = ByteScan.Needle("\"type\":\"user\"")
    private static let assistantMarker = ByteScan.Needle("\"type\":\"assistant\"")
    private static let toolResultMarker = ByteScan.Needle("\"tool_result\"")
    private static let timestampKey = ByteScan.Needle("\"timestamp\":\"")
    private static let isErrorTrueMarker = ByteScan.Needle("\"is_error\":true")
    private static let toolDenialKindMarker = ByteScan.Needle("\"toolDenialKind\"")

    static func fastParseToolResult(_ line: Data) -> [String: Any]? {
        line.withUnsafeBytes { fastParseToolResult($0) }
    }

    /// A tool-result entry needs three facts — its timestamp, how many
    /// of its blocks errored, whether it was a denial — and the line can
    /// be megabytes of tool output. Byte searches only: no String, no
    /// regex (NSRegularExpression over 2 MB lines was the hot spot).
    static func fastParseToolResult(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        // The LAST match, not the first: the entry's own timestamp field
        // follows `message` in the JSON, and a tool result's content can
        // itself contain an embedded `"timestamp":"…"` (e.g. echoed API
        // output) that would otherwise be picked up instead.
        guard let key = ByteScan.lastIndex(of: timestampKey, in: line) else { return nil }
        let valueStart = key + timestampKey.count
        guard valueStart < line.count,
              let quote = ByteScan.firstIndex(of: UInt8(ascii: "\""), in: line, from: valueStart),
              quote > valueStart else { return nil }
        let stamp = String(decoding: UnsafeRawBufferPointer(rebasing: line[valueStart..<quote]), as: UTF8.self)
        var obj: [String: Any] = ["type": "user", "timestamp": stamp]
        if ByteScan.contains(toolDenialKindMarker, in: line) { obj["toolDenialKind"] = true }
        let errorCount = ByteScan.count(isErrorTrueMarker, in: line)
        let blocks = (0..<errorCount).map { _ in ["type": "tool_result", "is_error": true] as [String: Any] }
        obj["message"] = ["content": blocks]
        return obj
    }

    public static let windowBytes = 8 * 1024 * 1024

    /// Reads at most one bounded window starting at `entry.offset`,
    /// ingests every complete line in it, advances `entry.offset` past
    /// what it consumed, and returns the number of bytes consumed (0 if
    /// nothing could be — an unreadable file, or a trailing line that
    /// isn't newline-terminated yet).
    ///
    /// A window that comes back with no newline at all is ambiguous: it
    /// might be a single line bigger than the window (more data follows
    /// — double the window and re-read from the same offset; a line can
    /// never wedge the scan this way), or it might be the genuine end of
    /// the file with an in-progress last line (a short read: fewer bytes
    /// came back than asked for). Only the second case waits — same as
    /// the old unbounded `parse`, which held any line without a trailing
    /// newline for the next call.
    static func parse(url: URL, sessionID: String, into entry: inout FileEntry, calendar: Calendar,
                      windowBytes: Int = StatsScanner.windowBytes) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let newline = UInt8(ascii: "\n")
        var windowSize = windowBytes
        var data = Data()
        while true {
            guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
                  let chunk = try? handle.read(upToCount: windowSize), !chunk.isEmpty else { return 0 }
            data = chunk
            if data.lastIndex(of: newline) != nil { break }
            if chunk.count < windowSize { return 0 }   // real EOF, partial trailing line — wait
            windowSize *= 2
        }
        guard let lastNewline = data.lastIndex(of: newline) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        let codex = entry.engine == Stats.Engine.codex.rawValue
        // One pass over the raw bytes: lines split by memchr, the type
        // pre-filter a first-byte/memcmp search. `Data.range(of:)` on a
        // slice per line ran the whole corpus at ~15 MB/s (2026-09-05).
        complete.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var lineStart = 0
            while lineStart < buf.count {
                let lineEnd: Int
                if let hit = memchr(base + lineStart, Int32(newline), buf.count - lineStart) {
                    lineEnd = UnsafeRawPointer(hit) - base
                } else {
                    lineEnd = buf.count
                }
                let line = UnsafeRawBufferPointer(rebasing: buf[lineStart..<lineEnd])
                lineStart = lineEnd + 1
                if codex {
                    let bytes = Data(bytes: line.baseAddress!, count: line.count)
                    if StatsCodex.worthParsing(bytes), let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                        StatsCodex.ingest(obj, sessionID: sessionID, into: &entry, calendar: calendar)
                    }
                    continue
                }
                // Cheap pre-filter: only user/assistant entries matter.
                let isUser = ByteScan.contains(userMarker, in: line)
                guard isUser || ByteScan.contains(assistantMarker, in: line) else { continue }
                var obj: [String: Any]?
                if isUser, ByteScan.contains(toolResultMarker, in: line) {
                    obj = fastParseToolResult(line)
                }
                if obj == nil {
                    obj = try? JSONSerialization.jsonObject(with: Data(bytes: line.baseAddress!, count: line.count)) as? [String: Any]
                }
                guard let obj else { continue }
                ingest(obj, sessionID: sessionID, into: &entry, calendar: calendar)
            }
        }
        entry.offset += complete.count
        return complete.count
    }
}


/// Needle searches over raw transcript bytes: memchr to the needle's
/// first byte, memcmp for the rest. Foundation carries memchr/memcmp on
/// every platform InfinitusCore builds for.
enum ByteScan {
    /// A search pattern with its memchr anchor chosen once.
    struct Needle {
        let bytes: [UInt8]
        let anchor: Int
        init(_ s: String) {
            bytes = Array(s.utf8)
            anchor = ByteScan.anchor(bytes)
        }
        var count: Int { bytes.count }
    }

    static func firstIndex(of byte: UInt8, in buf: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        guard from < buf.count, let base = buf.baseAddress,
              let hit = memchr(base + from, Int32(byte), buf.count - from) else { return nil }
        return UnsafeRawPointer(hit) - base
    }

    /// First occurrence at or after `from`; nil when absent. memchr
    /// runs on the needle's rarest byte (a quote or a colon hits every
    /// few bytes of JSON; a `y` or `p` hits every few hundred), then
    /// memcmp confirms the whole needle around it.
    static func firstIndex(of needle: Needle, in buf: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        let n = needle.count
        guard n > 0, n <= buf.count, let base = buf.baseAddress else { return nil }
        return needle.bytes.withUnsafeBufferPointer { nb -> Int? in
            let k = needle.anchor
            let want = Int32(nb[k])
            let lastStart = buf.count - n
            var at = max(from, 0) + k
            let end = lastStart + k
            while at <= end, let hit = memchr(base + at, want, end - at + 1) {
                let i = UnsafeRawPointer(hit) - base - k
                if memcmp(base + i, nb.baseAddress!, n) == 0 { return i }
                at = i + k + 1
            }
            return nil
        }
    }

    /// Rarest-first order of bytes as transcripts use them; anything
    /// else (quotes, braces, digits, colons) is common.
    private static let rarity: [UInt8: Int] = {
        var r: [UInt8: Int] = [:]
        for (i, c) in "qzjxkvwybgpfmhdulcnrostaei".utf8.enumerated() { r[c] = i }
        return r
    }()

    /// Index of the needle byte to memchr for.
    static func anchor(_ needle: [UInt8]) -> Int {
        var best = 0
        var bestRank = Int.max
        for (i, b) in needle.enumerated() {
            let rank = rarity[b] ?? 100
            if rank < bestRank { bestRank = rank; best = i }
        }
        return best
    }

    static func contains(_ needle: Needle, in buf: UnsafeRawBufferPointer) -> Bool {
        firstIndex(of: needle, in: buf) != nil
    }

    static func lastIndex(of needle: Needle, in buf: UnsafeRawBufferPointer) -> Int? {
        var last: Int?
        var from = 0
        while let i = firstIndex(of: needle, in: buf, from: from) {
            last = i
            from = i + 1
        }
        return last
    }

    /// Non-overlapping occurrences (what `components(separatedBy:).count - 1` gave).
    static func count(_ needle: Needle, in buf: UnsafeRawBufferPointer) -> Int {
        var n = 0
        var from = 0
        while let i = firstIndex(of: needle, in: buf, from: from) {
            n += 1
            from = i + needle.count
        }
        return n
    }
}
