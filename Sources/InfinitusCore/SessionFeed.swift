import Foundation

/// One entry in a session's read-only feed (#17 layer 1): the phone's
/// chat-style view of a live session's transcript, built the same
/// zero-token way as `SessionProgress` — no summarizing, just picking
/// out what already matters.
public struct SessionFeedItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, question, permission, result, limit
        /// A sub-agent this session spawned (the `Agent` tool) — its own
        /// transcript lives under `<session>/subagents/`, summarized here
        /// like Remote Control does (user 2026-09-03, from the phone).
        case agent
    }

    /// Sub-agent summary for `.agent` items. New optional field.
    public struct Agent: Codable, Sendable, Equatable {
        public let id: String
        public let type: String
        public let description: String
        public let toolCalls: Int
        /// "Bash · git commit …" — the newest tool call, if any.
        public let lastTool: String?
        public let running: Bool
        public let lastActivityAt: Date?
        public init(id: String, type: String, description: String, toolCalls: Int,
                    lastTool: String?, running: Bool, lastActivityAt: Date?) {
            self.id = id
            self.type = type
            self.description = description
            self.toolCalls = toolCalls
            self.lastTool = lastTool
            self.running = running
            self.lastActivityAt = lastActivityAt
        }
    }

    public let kind: Kind
    public let text: String
    public let at: Date?
    /// `.user` items only: the other Claude session that sent this
    /// (its from-name), so the phone can show it the way the CLI does —
    /// a "Message from @<sender>" line, not the user's own bubble
    /// (2026-09-04). Nil for the user's own words, phone included.
    public let sender: String?
    /// Set only for `.tool`/`.permission` items.
    public let toolName: String?
    /// Set only for `.question` items — the option labels, read-only.
    public let options: [String]?
    /// Set only for `.agent` items.
    public let agent: Agent?
    /// The `tool_use` id behind a `.tool`/`.agent` item — how a sub-agent's
    /// meta file (`toolUseId`) finds its row. Not on the wire.
    let toolUseId: String?

    /// Images in a user prompt (new optional field): ids for the mirror's
    /// `/sessions/<pid>/images/<id>` route — `t:<uuid>:<block>` for one
    /// pasted in the terminal (a base64 block in the transcript entry),
    /// `a:<file>` for one sent from the phone (saved by SessionInput).
    public let images: [String]?

    public init(kind: Kind, text: String, at: Date? = nil, toolName: String? = nil,
                options: [String]? = nil, agent: Agent? = nil, toolUseId: String? = nil,
                images: [String]? = nil, sender: String? = nil) {
        self.kind = kind
        self.images = images
        self.sender = sender
        self.text = text
        self.at = at
        self.toolName = toolName
        self.options = options
        self.agent = agent
        self.toolUseId = toolUseId
    }

    enum CodingKeys: String, CodingKey { case kind, text, at, toolName, options, agent, images, sender }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Date.self, forKey: .at)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        images = try c.decodeIfPresent([String].self, forKey: .images)
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        toolUseId = nil
    }
}

/// The feed for one live session, as served by `GET /sessions/<pid>/tail`.
public struct SessionFeed: Codable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let status: String?
    public let waiting: Bool
    public let items: [SessionFeedItem]
    /// The session's own name, when it has one (new optional field).
    public let name: String?
    /// Opaque transcript version (size + mtime) — the phone hands it back
    /// as `?since=` so the Mac can hold the reply until something changed
    /// (long-poll). New optional field.
    public let stamp: String?
    /// Whether a message can be delivered to this session at all: a peer
    /// channel is listening (Mac: the unix socket; Windows: the named
    /// pipe). The phone gates its composer on it. Additive optional — an
    /// older host omits it and the phone assumes yes, as it did before.
    public let canMessage: Bool?
    /// Whether the host can type into the session's terminal (the PTY
    /// nudge path). True on the Mac, false on Windows: Windows Terminal
    /// exposes no send-keys, so a session with no peer channel can't be
    /// reached at all there.
    public let keys: Bool?
    /// The session's permission mode as its transcript last reported it
    /// (`default`, `bypass`, …). A `default`-mode session HOLDS an
    /// inbound peer message for its user's approval, so the phone says so
    /// instead of implying the message was delivered.
    public let permissionMode: String?

    public init(pid: Int32, sessionId: String, cwd: String, status: String?,
                waiting: Bool, items: [SessionFeedItem], name: String? = nil,
                stamp: String? = nil, canMessage: Bool? = nil, keys: Bool? = nil,
                permissionMode: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waiting = waiting
        self.items = items
        self.name = name
        self.stamp = stamp
        self.canMessage = canMessage
        self.keys = keys
        self.permissionMode = permissionMode
    }
}

public enum SessionFeedReader {
    /// Same tail-read convention as `Transcript`/`SessionProgress`, sized
    /// for how far back "recent important messages" needs to look rather
    /// than a full limit-stop check.
    static let tailBytes = 256 * 1024
    /// One pasted screenshot is a 400-600 KB line (its base64 tool
    /// result), wider than the whole tail: the window quadruples until
    /// it holds `limit` items or reaches this (user 2026-09-04 "session
    /// msgs are getting trimmed I cant read anything").
    static let tailBytesMax = 4 * 1024 * 1024
    /// Assistant AND user text items are capped here — the sessions this
    /// serves are dispatch-driven, so user prompts run multi-KB too, and
    /// this feed is polled every 5s from the phone.
    /// Per-item text cap. 400 trimmed real answers (user 2026-09-03:
    /// "messages got trimmed too"); a long reply is what the phone is for.
    static let textCap = 12_000

    /// Reads `~/.claude/projects/<slug>/<sessionId>.jsonl` for the given
    /// record and parses its tail. `nil` only when the record carries no
    /// session id at all (nothing to read) — a transcript that's missing
    /// or unreadable still yields a `SessionFeed` with empty `items`,
    /// same "degrade, never throw" convention as `Transcript`.
    public static func read(record: ClaudeSessionRecord, claudeDir: URL,
                             limit: Int = 30) -> SessionFeed? {
        guard !record.sessionId.isEmpty else { return nil }
        let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        var window = tailBytes
        var lines = tail(of: url, maxBytes: window)
        var parsed = parse(lines: lines, limit: limit)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        while parsed.count < limit, window < size, window < tailBytesMax {
            window *= 4
            lines = tail(of: url, maxBytes: window)
            parsed = parse(lines: lines, limit: limit)
        }
        let raw = attachAgents(parsed, transcript: url)
        let (items, waiting) = finalize(items: raw, status: record.status,
                                        statusUpdatedAt: record.statusUpdatedAt)
        return SessionFeed(pid: record.pid, sessionId: record.sessionId, cwd: record.cwd,
                           status: record.status, waiting: waiting, items: items,
                           name: record.name, stamp: stamp(record: record, claudeDir: claudeDir),
                           permissionMode: permissionMode(lines: lines))
    }

    /// The newest `permission-mode` entry's mode in the transcript tail —
    /// Claude Code writes one whenever the mode changes. Nil when the tail
    /// holds none (the session never changed mode since it aged out).
    public static func permissionMode(lines: [String]) -> String? {
        for line in lines.reversed() where line.contains("\"permission-mode\"") {
            guard let entry = decodeLine(line),
                  (entry["subtype"] as? String) == "permission-mode" ||
                  (entry["type"] as? String) == "permission-mode"
            else { continue }
            if let mode = entry["permissionMode"] as? String, !mode.isEmpty { return mode }
        }
        return nil
    }

    /// "size-mtime" of the transcript plus the record's status, so a
    /// status flip (busy → waiting) counts as a change too. Nil when the
    /// transcript isn't there yet.
    public static func stamp(record: ClaudeSessionRecord, claudeDir: URL) -> String? {
        let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mtime * 1000))-\(record.status ?? "")"
    }

    /// Long-poll half of `GET …/tail?since=&wait=` (#17, "streaming to
    /// mobile seems laggy"): blocks the calling thread — never the main
    /// actor or a network queue — until the session's stamp differs from
    /// `since` or `wait` seconds (capped at `MirrorTransport.tailWaitMax`)
    /// pass, re-resolving the record each poll so a status flip counts.
    /// Returns at once when there is nothing to wait for.
    public static func waitForChange(pid: Int32, claudeDir: URL, since: String?,
                                     wait: TimeInterval, poll: TimeInterval = 0.3) {
        guard let since, wait > 0 else { return }
        let deadline = Date().addingTimeInterval(min(wait, MirrorTransport.tailWaitMax))
        while Date() < deadline {
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
                  stamp(record: record, claudeDir: claudeDir) == since else { return }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    /// Fills each `.agent` row from `<transcript dir>/<sessionId>/subagents/`:
    /// `agent-<id>.meta.json` names the spawning `toolUseId`, `agent-<id>.jsonl`
    /// is the sub-agent's own transcript (tail-read, 64 KiB). Running =
    /// the transcript's newest entry is not a final assistant text and it
    /// was touched in the last two minutes. Only the agents the window's
    /// rows point at are read: a long session accumulates hundreds
    /// (735 under one worktree, 2026-09-05), and tailing every log on
    /// every request took the route past the phone's 3 s ("couldn't
    /// reach the Mac: the Mac didn't answer").
    static func attachAgents(_ items: [SessionFeedItem], transcript: URL,
                             now: Date = Date()) -> [SessionFeedItem] {
        let wanted = Set(items.compactMap { $0.kind == .agent ? $0.toolUseId : nil })
        guard !wanted.isEmpty else { return items }
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return items }
        var byToolUse: [String: SessionFeedItem.Agent] = [:]
        for name in names where name.hasSuffix(".meta.json") {
            let id = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolUseId = meta["toolUseId"] as? String, wanted.contains(toolUseId) else { continue }
            let log = dir.appendingPathComponent("agent-\(id).jsonl")
            let entries = tail(of: log, maxBytes: 64 * 1024).compactMap(decodeLine)
            var toolCalls = 0
            var lastTool: String?
            var lastAt: Date?
            var endsWithText = false
            for entry in entries {
                lastAt = (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO) ?? lastAt
                guard (entry["type"] as? String) == "assistant",
                      let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        toolCalls += 1
                        let tool = block["name"] as? String ?? ""
                        lastTool = tool + " · " + describeTool(name: tool, input: block["input"] as? [String: Any] ?? [:])
                        endsWithText = false
                    case "text":
                        if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                            endsWithText = true
                        }
                    default: break
                    }
                }
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date
            let fresh = mtime.map { now.timeIntervalSince($0) < 120 } ?? false
            byToolUse[toolUseId] = SessionFeedItem.Agent(
                id: id, type: meta["agentType"] as? String ?? "agent",
                description: meta["description"] as? String ?? "sub-agent",
                toolCalls: toolCalls, lastTool: lastTool, running: !endsWithText && fresh,
                lastActivityAt: lastAt ?? mtime)
        }
        return items.map { item in
            guard item.kind == .agent, let id = item.toolUseId, let agent = byToolUse[id] else { return item }
            return SessionFeedItem(kind: .agent, text: agent.description, at: item.at,
                                   toolName: agent.type, agent: agent, toolUseId: id)
        }
    }

    private static func tail(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let blob = try? handle.readToEnd() else { return [] }
        return blob.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The record-level finishing touch `read` applies after `parse`,
    /// factored out so it's testable without touching disk: a tool call
    /// still open when the record says "waiting" is a permission prompt,
    /// not just a tool in flight — unless the "waiting" predates the
    /// newest item: a turn started by a peer message runs under the
    /// previous turn's "waiting" (Claude Code doesn't flip the record
    /// back), and that made every tool call a permission card on the
    /// phone in a bypass-permissions session (2026-09-04).
    public static func finalize(items: [SessionFeedItem], status: String?,
                                statusUpdatedAt: Date? = nil)
        -> (items: [SessionFeedItem], waiting: Bool) {
        var items = items
        var recordWaiting = status == "waiting"
        if recordWaiting, let flipped = statusUpdatedAt, let at = items.last?.at, flipped < at {
            recordWaiting = false
        }
        if recordWaiting, let last = items.last, last.kind == .tool {
            items[items.count - 1] = SessionFeedItem(kind: .permission, text: last.text,
                                                      at: last.at, toolName: last.toolName)
        }
        let waiting = recordWaiting
            || (items.last.map { $0.kind == .question || $0.kind == .permission } ?? false)
        return (items, waiting)
    }

    /// Parses a tail of JSONL lines (oldest→newest) into feed items,
    /// tolerant of a torn first line — same convention as
    /// `SessionProgress.parse`. Returns at most `limit` items, newest
    /// last.
    static func decodeLine(_ line: String) -> [String: Any]? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func parse(lines: [String], limit: Int) -> [SessionFeedItem] {
        let entries: [[String: Any]] = lines.compactMap(decodeLine)

        /// A run of consecutive `.tool` items — any tools (user 2026-09-03:
        /// "all the tool uses should be combined into one") — collapsed
        /// into one chip showing the latest call, the count and the mix of
        /// tool names. Error results ride in the run too (user 2026-09-03
        /// from the phone, "group tool uses": every error split the run
        /// into a stack of chips); the chip counts them, and the latest
        /// item's text — an error's included — is what it shows.
        struct Run {
            var item: SessionFeedItem
            var count: Int
            var errors: Int
            /// Distinct tool names in first-seen order.
            var names: [String] = []
        }
        var runs: [Run] = []
        var toolNames: [String: String] = [:]   // tool_use id -> name

        func timestamp(_ entry: [String: Any]) -> Date? {
            (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO)
        }

        func append(_ item: SessionFeedItem, isError: Bool = false) {
            // Streamed text arrives one block per entry; adjacent assistant
            // blocks are one answer, so they share a bubble (user
            // 2026-09-03: "sometimes I got part of message"). The turn-end
            // block carries `.result`, which the merged bubble adopts.
            if item.kind == .assistant || item.kind == .result,
               let last = runs.last, last.item.kind == .assistant {
                let merged = SessionFeedItem(kind: item.kind, text: last.item.text + "\n\n" + item.text,
                                             at: item.at)
                runs[runs.count - 1] = Run(item: merged, count: 1, errors: 0)
                return
            }
            if item.kind == .tool, let last = runs.last, last.item.kind == .tool {
                var names = last.names
                if let name = item.toolName, !names.contains(name) { names.append(name) }
                runs[runs.count - 1] = Run(item: item, count: last.count + 1,
                                           errors: last.errors + (isError ? 1 : 0), names: names)
            } else {
                runs.append(Run(item: item, count: 1, errors: isError ? 1 : 0,
                                names: item.toolName.map { [$0] } ?? []))
            }
        }

        /// Trimmed first-line-or-whole text of a "real" user prompt
        /// entry — nil for a tool_result-only entry or a system-injected
        /// payload (`<command-name>`, `<system-reminder>`, …).
        func realUserText(_ entry: [String: Any]) -> (sender: String?, text: String)? {
            guard (entry["type"] as? String) == "user",
                  let message = entry["message"] as? [String: Any] else { return nil }
            let text: String?
            if let plain = message["content"] as? String {
                text = plain
            } else if let content = message["content"] as? [[String: Any]] {
                text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            } else {
                text = nil
            }
            return text.flatMap(presentableUser)
        }

        /// Whether an assistant text block at `index` is the final answer
        /// of its turn: the next `user`/`assistant` entry (bookkeeping
        /// entries like `turn_duration` skipped) is either absent or a
        /// real user prompt. Anything else (another assistant entry, or a
        /// user entry that's only a tool_result) means more of the same
        /// turn is still coming.
        func isTurnEnd(_ index: Int) -> Bool {
            var i = index + 1
            while i < entries.count {
                let type = entries[i]["type"] as? String
                if type == "assistant" { return false }
                if type == "user" { return realUserText(entries[i]) != nil }
                i += 1
            }
            return true
        }

        for (index, entry) in entries.enumerated() {
            let type = entry["type"] as? String
            // A prompt typed while a turn was running is absorbed mid-turn
            // and logged as a `queued_command` attachment, never as a
            // `user` entry (user 2026-09-03: "messages I chat from here
            // doesn't appear on iOS").
            if type == "attachment",
               let attachment = entry["attachment"] as? [String: Any],
               (attachment["type"] as? String) == "queued_command",
               let prompt = attachment["prompt"] as? String {
                if let user = presentableUser(prompt) {
                    let images = attachedImageIds(user.text)
                    append(SessionFeedItem(kind: .user, text: String(user.text.prefix(textCap)),
                                           at: timestamp(entry), images: images.isEmpty ? nil : images,
                                           sender: user.sender))
                }
                continue
            }
            if type == "user" {
                if let user = realUserText(entry) {
                    let images = imageIds(entry: entry, text: user.text)
                    append(SessionFeedItem(kind: .user,
                                           text: String(bubbleText(user.text, images: images).prefix(textCap)),
                                           at: timestamp(entry), images: images.isEmpty ? nil : images,
                                           sender: user.sender))
                    continue
                }
                guard let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_result" {
                    guard (block["is_error"] as? Bool) == true else { continue }
                    let name = toolNames[block["tool_use_id"] as? String ?? ""]
                    append(SessionFeedItem(kind: .tool, text: "error: \(errorSummary(block))",
                                           at: timestamp(entry), toolName: name), isError: true)
                }
                continue
            }
            guard type == "assistant" else { continue }
            if Transcript.isLimitStop(entry) {
                append(SessionFeedItem(kind: .limit, text: Transcript.limitText(entry),
                                       at: timestamp(entry)))
                continue
            }
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textCap))
                    guard !trimmed.isEmpty else { continue }
                    let kind: SessionFeedItem.Kind = isTurnEnd(index) ? .result : .assistant
                    append(SessionFeedItem(kind: kind, text: trimmed, at: timestamp(entry)))
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if let id = block["id"] as? String { toolNames[id] = name }
                    if name == "AskUserQuestion" {
                        let (question, options) = describeQuestion(block)
                        append(SessionFeedItem(kind: .question, text: question,
                                               at: timestamp(entry), options: options))
                    } else if name == "Agent" {
                        // Its own row, never collapsed into a tool run —
                        // `attachAgents` fills in the sub-agent's progress.
                        let input = block["input"] as? [String: Any] ?? [:]
                        let description = input["description"] as? String ?? "sub-agent"
                        let type = input["subagent_type"] as? String ?? "agent"
                        append(SessionFeedItem(kind: .agent, text: description,
                                               at: timestamp(entry), toolName: type,
                                               toolUseId: block["id"] as? String))
                    } else {
                        let summary = describeTool(name: name, input: block["input"] as? [String: Any] ?? [:])
                        append(SessionFeedItem(kind: .tool, text: summary,
                                               at: timestamp(entry), toolName: name))
                    }
                default:
                    continue
                }
            }
        }

        let items = runs.map { run -> SessionFeedItem in
            guard run.count > 1 else { return run.item }
            // A mixed run names every tool it covers, latest call as the text.
            let toolName = run.names.count > 1 ? run.names.joined(separator: ", ") : run.item.toolName
            let errors = run.errors > 0 ? " · \(run.errors) error\(run.errors == 1 ? "" : "s")" : ""
            return SessionFeedItem(kind: run.item.kind, text: "\(run.item.text) (\u{00d7}\(run.count)\(errors))",
                                   at: run.item.at, toolName: toolName, options: run.item.options)
        }
        return Array(items.suffix(max(0, limit)))
    }

    // MARK: - Images in a prompt (phone thumbnails, 2026-09-04)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]

    static func fileExtension(_ name: String) -> String {
        guard name.contains(".") else { return "" }
        return String(name.split(separator: ".").last ?? "").lowercased()
    }

    static func mime(forExtension ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Ids for the images of a real user entry: every base64 image block
    /// (a terminal paste), then the image files in its `[attached: …]`
    /// line (a phone send).
    static func imageIds(entry: [String: Any], text: String) -> [String] {
        var ids: [String] = []
        if let uuid = entry["uuid"] as? String,
           let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            for (i, block) in content.enumerated() where (block["type"] as? String) == "image" {
                ids.append("t:\(uuid):\(i)")
            }
        }
        return ids + attachedImageIds(text)
    }

    /// `a:<file>` for each image path in the text's `[attached: a, b]`
    /// line — the file name only; the route resolves it in the
    /// attachments folder and nowhere else.
    static func attachedImageIds(_ text: String) -> [String] {
        guard let range = text.range(of: "[attached: ", options: .backwards),
              let close = text[range.upperBound...].firstIndex(of: "]") else { return [] }
        return text[range.upperBound..<close].split(separator: ", ").compactMap { path in
            // Both separators: a Windows attachment path is
            // `C:\Users\…\Infinitus\attachments\<uuid>-<name>.png`.
            let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last.map(String.init) ?? String(path)
            return imageExtensions.contains(fileExtension(name)) ? "a:\(name)" : nil
        }
    }

    /// The bubble's text once its images are shown as thumbnails: Claude
    /// Code's "[Image #N]" placeholders go.
    static func bubbleText(_ text: String, images: [String]) -> String {
        guard !images.isEmpty else { return text }
        return text.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enough of the transcript's tail to hold a few pasted screenshots
    /// (~200 KB of base64 each); the feed's own 512 KiB holds two.
    static let imageTailBytes = 16 * 1024 * 1024

    /// The bytes behind a feed image id, for the mirror's image route: a
    /// saved attachment by file name (a name with a separator or `..` is
    /// refused, so nothing outside the attachments folder is ever served)
    /// or the base64 block out of the transcript entry with that uuid.
    /// Nil when it's gone — the entry aged out of the tail, the file was
    /// cleaned up.
    public static func imageData(record: ClaudeSessionRecord, id: String, claudeDir: URL,
                                 attachmentsDir: URL) -> (data: Data, mime: String)? {
        if id.hasPrefix("a:") {
            let name = String(id.dropFirst(2))
            let ext = fileExtension(name)
            // `\` and `:` join the refusal list so a Windows id can never
            // escape the attachments folder (`..\x`, `C:\…`).
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(":"),
                  !name.contains(".."), imageExtensions.contains(ext),
                  let data = try? Data(contentsOf: attachmentsDir.appendingPathComponent(name)) else { return nil }
            return (data, mime(forExtension: ext))
        }
        guard id.hasPrefix("t:") else { return nil }
        let parts = id.dropFirst(2).split(separator: ":")
        guard parts.count == 2, let index = Int(parts[1]), index >= 0 else { return nil }
        let uuid = String(parts[0])
        guard !uuid.isEmpty, uuid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        let needle = "\"uuid\":\"\(uuid)\""
        for line in tail(of: url, maxBytes: imageTailBytes).reversed() where line.contains(needle) {
            guard let entry = decodeLine(line), (entry["uuid"] as? String) == uuid,
                  let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  index < content.count, let source = content[index]["source"] as? [String: Any],
                  let b64 = source["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
            return (data, source["media_type"] as? String ?? "image/png")
        }
        return nil
    }

    /// A user prompt worth a bubble: plain text as is; a cross-session
    /// message as its body, with `sender` set for another Claude session
    /// and nil for the phone (the user's own words, via the peer socket);
    /// any other tagged payload (system reminders, hook output) is
    /// machinery, not a message — nil.
    static func presentableUser(_ raw: String) -> (sender: String?, text: String)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Claude Code's own note after an image is read ("[Image: original
        // 947x2048, displayed at …]") arrives as a user turn; it is not
        // something anyone typed (user 2026-09-05 screenshot).
        if trimmed.hasPrefix("[Image: original "), trimmed.hasSuffix("]") { return nil }
        // Claude Code delivers a peer message as "Another Claude session
        // sent a message:\n<cross-session-message …>…</…>" plus its own
        // guidance after the closing tag; the bubble showed all of it
        // (user 2026-09-04 screenshot). Same unwrap as StatsScanner.
        if trimmed.hasPrefix("Another Claude session sent a message"),
           let open = trimmed.range(of: "<cross-session-message") {
            trimmed = String(trimmed[open.lowerBound...])
        }
        guard trimmed.first == "<" else { return (nil, trimmed) }
        guard trimmed.hasPrefix("<cross-session-message"),
              let headEnd = trimmed.firstIndex(of: ">") else { return nil }
        let head = trimmed[..<headEnd]
        var body = String(trimmed[trimmed.index(after: headEnd)...])
        if let close = body.range(of: "</cross-session-message>") { body = String(body[..<close.lowerBound]) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromPhone = body.hasPrefix(PeerSocket.phonePreface)
        if fromPhone { body = String(body.dropFirst(PeerSocket.phonePreface.count)) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if fromPhone { return (nil, body) }
        var sender = "peer"
        if let r = head.range(of: "from-name=\"") {
            let rest = head[r.upperBound...]
            if let q = rest.firstIndex(of: "\"") { sender = String(rest[..<q]) }
        }
        return (sender, body)
    }

    private static func errorSummary(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return String(text.prefix(200)) }
        if let parts = block["content"] as? [[String: Any]],
           let text = parts.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
            return String(text.prefix(200))
        }
        return "tool error"
    }

    private static func describeQuestion(_ block: [String: Any]) -> (String, [String]) {
        guard let input = block["input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], !questions.isEmpty
        else { return ("", []) }
        let text = questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
        let options = questions.flatMap { question -> [String] in
            (question["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
        }
        return (text, options)
    }

    /// One-line summary of a tool call's input — the Bash command or the
    /// file path, same signals `SessionProgress.describe` reads, just
    /// without the verb prefix (the tool name carries that on the phone).
    private static func describeTool(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let command = (input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return String(command.prefix(120))
        case "Read", "Edit", "Write":
            let path = input["file_path"] as? String ?? ""
            return URL(fileURLWithPath: path).lastPathComponent
        case "Grep":
            return String((input["pattern"] as? String ?? "").prefix(60))
        default:
            return ""
        }
    }
}
