import Foundation

/// The transcript → `SessionTimeline` walk (#223 phase 1). A second pass
/// over the entries `SessionFeedReader.read` already decodes; the legacy
/// `parse` is untouched. Mirrors T3's ProviderRuntimeIngestion +
/// projector rules with the transcript as the source instead of the SDK.
public enum SessionTimelineBuilder {
    public static func build(entries: [[String: Any]], status: String?, statusUpdatedAt: Date? = nil,
                             agents: [String: SessionFeedItem.Agent] = [:], now: Date = Date()) -> SessionTimeline {
        var walk = Walk(agents: agents)
        for entry in entries {
            // Sub-agent traffic is summarized by `task.*` rows; the
            // transcript has no parent_tool_use_id to filter on.
            if (entry["isSidechain"] as? Bool) == true { continue }
            walk.visit(entry)
        }
        return walk.finish(status: status, statusUpdatedAt: statusUpdatedAt)
    }

    static func timestamp(_ entry: [String: Any]) -> Date? {
        (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO)
    }

    /// The mutable state of one walk.
    struct Walk {
        let agents: [String: SessionFeedItem.Agent]
        var turns: [TurnDraft] = []
        var messages: [Message] = []
        var activities: [Activity] = []
        var seq = 0
        /// Index in `messages` of the assistant message still absorbing
        /// streamed blocks, or nil once a non-text entry closed it.
        var openAssistant: Int?
        var lastAt: Date?
        /// Tool calls awaiting their `tool_result`, by tool_use id.
        var openTools: [String: OpenTool] = [:]

        struct OpenTool {
            let name: String
            let command: String?
            let files: [String]
            let input: JSONValue
        }

        /// JSONSerialization's Any → the closed `JSONValue`. A JSON `true`
        /// bridges as NSNumber too, so the boolean check comes first.
        static func json(_ any: Any) -> JSONValue {
            if let n = any as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                return .number(n.doubleValue)
            }
            switch any {
            case let s as String: return .string(s)
            case let a as [Any]: return .array(a.map(json))
            case let o as [String: Any]: return .object(o.mapValues(json))
            default: return .null
            }
        }

        struct TurnDraft {
            let id: String
            let requestedAt: Date
            var startedAt: Date?
            var lastAt: Date?
            var assistantMessageId: String?
            var interrupted = false
            var errored = false
        }

        init(agents: [String: SessionFeedItem.Agent]) { self.agents = agents }

        var currentTurnId: String { turns.last?.id ?? "" }

        mutating func visit(_ entry: [String: Any]) {
            let type = entry["type"] as? String
            let at = SessionTimelineBuilder.timestamp(entry) ?? lastAt ?? Date(timeIntervalSince1970: 0)
            lastAt = at
            switch type {
            case "attachment":
                // A prompt typed while a turn was running is absorbed
                // mid-turn and logged as a `queued_command`, never as a
                // `user` entry (same rule as the legacy feed).
                guard let attachment = entry["attachment"] as? [String: Any],
                      (attachment["type"] as? String) == "queued_command",
                      let prompt = attachment["prompt"] as? String,
                      let user = SessionFeedReader.presentableUser(prompt) else { return }
                let images = SessionFeedReader.attachedImageIds(user.text)
                openTurn(id: entry["uuid"] as? String ?? "q:\(seq)", at: at, text: user.text,
                         images: images, sender: user.sender)
            case "user":
                visitUser(entry, at: at)
            case "assistant":
                visitAssistant(entry, at: at)
            default:
                break
            }
            // After dispatch: a prompt that just opened a turn stamps the
            // new one, never the turn it closed.
            if !turns.isEmpty { turns[turns.count - 1].lastAt = at }
        }

        mutating func openTurn(id: String, at: Date, text: String, images: [String], sender: String?) {
            turns.append(TurnDraft(id: id, requestedAt: at, lastAt: at))
            messages.append(Message(id: id, role: .user, text: String(text.prefix(SessionFeedReader.textCap)),
                                    images: images.isEmpty ? nil : images, sender: sender,
                                    turnId: id, streaming: false, createdAt: at))
            openAssistant = nil
        }

        mutating func visitUser(_ entry: [String: Any], at: Date) {
            guard let message = entry["message"] as? [String: Any] else { return }
            let raw: String?
            if let plain = message["content"] as? String {
                raw = plain
            } else if let content = message["content"] as? [[String: Any]] {
                raw = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            } else {
                raw = nil
            }
            if let raw, let user = SessionFeedReader.presentableUser(raw) {
                let images = SessionFeedReader.imageIds(entry: entry, text: user.text)
                openTurn(id: entry["uuid"] as? String ?? "u:\(seq)", at: at,
                         text: SessionFeedReader.bubbleText(user.text, images: images),
                         images: images, sender: user.sender)
                return
            }
            if let content = message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_result" {
                    visitToolResult(block, entry: entry, at: at)
                }
            }
        }

        mutating func visitToolUse(name: String, id: String, input: [String: Any], at: Date) {
            let title = SessionFeedReader.describeTool(name: name, input: input)
            let command = name == "Bash" ? (input["command"] as? String) : nil
            let files = (input["file_path"] as? String).map { [$0] } ?? []
            openTools[id] = OpenTool(name: name, command: command, files: files, input: Walk.json(input))
            var payload: [String: JSONValue] = ["toolName": .string(name), "itemType": .string(Slim.itemType(for: name))]
            if !title.isEmpty { payload["title"] = .string(title) }
            append("tool.started", id: id, tone: .tool, summary: title.isEmpty ? name : title, payload: payload, at: at)
        }

        /// The result closes the pair as one `tool.completed` row whose
        /// payload IS the result — no tool_result entity (T3).
        mutating func visitToolResult(_ block: [String: Any], entry: [String: Any], at: Date) {
            guard let toolUseId = block["tool_use_id"] as? String else { return }
            let isError = (block["is_error"] as? Bool) == true
            let open = openTools.removeValue(forKey: toolUseId)
            let name = open?.name ?? ""
            let text: String
            if let s = block["content"] as? String {
                text = s
            } else if let parts = block["content"] as? [[String: Any]] {
                text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            } else {
                text = ""
            }
            var payload: [String: JSONValue] = ["toolName": .string(name), "itemType": .string(Slim.itemType(for: name)),
                                                "status": .string(isError ? "failed" : "completed")]
            let line = Slim.output(text)
            if !line.isEmpty { payload["output"] = .string(line) }
            var files = open?.files ?? []
            if let r = entry["toolUseResult"] as? [String: Any], let fp = r["filePath"] as? String, !files.contains(fp) {
                files.append(fp)
            }
            if !files.isEmpty, Slim.itemType(for: name) == "file_change" {
                payload["changedFiles"] = .array(Slim.files(files).map(JSONValue.string))
            }
            let summary = open.map {
                $0.command ?? SessionFeedReader.describeTool(name: name, input: ["file_path": $0.files.first ?? ""])
            } ?? name
            append("tool.completed", id: toolUseId + "/completed", tone: isError ? .error : .tool,
                   summary: summary.isEmpty ? name : summary,
                   detail: Slim.outputDetail(text, command: open?.command), payload: payload, at: at)
        }

        mutating func visitAssistant(_ entry: [String: Any], at: Date) {
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            if !turns.isEmpty, turns[turns.count - 1].startedAt == nil { turns[turns.count - 1].startedAt = at }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    appendAssistantText(trimmed, id: entry["uuid"] as? String ?? "a:\(seq)", at: at)
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let id = block["id"] as? String ?? "tool:\(seq)"
                    visitToolUse(name: name, id: id, input: block["input"] as? [String: Any] ?? [:], at: at)
                default:
                    // Thinking never enters the timeline (T3 ingestion :1567).
                    continue
                }
            }
        }

        /// Streamed blocks merge into one message (id = the first
        /// entry's uuid), the way the legacy feed merges bubbles.
        mutating func appendAssistantText(_ text: String, id: String, at: Date) {
            if let i = openAssistant {
                let m = messages[i]
                let joined = String((m.text + "\n\n" + text).prefix(SessionFeedReader.textCap))
                messages[i] = Message(id: m.id, role: .assistant, text: joined, images: nil, sender: nil,
                                      turnId: m.turnId, streaming: false, createdAt: m.createdAt)
                return
            }
            messages.append(Message(id: id, role: .assistant, text: String(text.prefix(SessionFeedReader.textCap)),
                                    images: nil, sender: nil, turnId: currentTurnId, streaming: false, createdAt: at))
            openAssistant = messages.count - 1
            if !turns.isEmpty { turns[turns.count - 1].assistantMessageId = id }
        }

        mutating func append(_ kind: String, id: String, tone: Activity.Tone, summary: String,
                             detail: String? = nil, payload: [String: JSONValue] = [:], at: Date) {
            activities.append(Activity(id: id, tone: tone, kind: kind, summary: summary,
                                       detail: detail.map(Slim.detail), payload: payload,
                                       turnId: currentTurnId, sequence: seq, createdAt: at))
            seq += 1
            openAssistant = nil
        }

        /// An approval or user-input request nothing has resolved yet.
        var hasOpenPrompt: Bool { false }

        /// Turn state follows the session status, as T3's projector does
        /// (`projector.ts:78-93`): the last turn is running while the
        /// record is busy; every earlier turn is closed by the next prompt.
        func finish(status: String?, statusUpdatedAt: Date?) -> SessionTimeline {
            var out: [Turn] = []
            var messages = self.messages
            for (i, d) in turns.enumerated() {
                let isLast = i == turns.count - 1
                let state: Turn.State
                if d.interrupted { state = .interrupted }
                else if d.errored { state = .error }
                else if isLast, status == "busy" { state = .running }
                else if isLast, status == "waiting", hasOpenPrompt { state = .running }
                else { state = .completed }
                out.append(Turn(id: d.id, state: state, requestedAt: d.requestedAt, startedAt: d.startedAt,
                                completedAt: state == .running ? nil : d.lastAt,
                                userMessageId: d.id, assistantMessageId: d.assistantMessageId))
                if state == .running, let aid = d.assistantMessageId,
                   let mi = messages.firstIndex(where: { $0.id == aid }) {
                    let m = messages[mi]
                    messages[mi] = Message(id: m.id, role: m.role, text: m.text, images: m.images, sender: m.sender,
                                           turnId: m.turnId, streaming: true, createdAt: m.createdAt)
                }
            }
            return SessionTimeline(turns: out, messages: messages, activities: activities)
        }
    }

    /// T3's slimming rules, applied once at build time
    /// (`ActivityPayloadProjection.ts`, ingestion 180-char detail cap).
    enum Slim {
        static func detail(_ s: String) -> String { String(s.prefix(180)) }

        /// First meaningful line when it fits, else "N lines" — T3's
        /// `summarizeToolTextOutput`.
        static func output(_ text: String) -> String {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let meaningful = lines.filter { !$0.isEmpty }
            guard let first = meaningful.first else { return "" }
            if first.count <= 84 { return first }
            return "\(meaningful.count) line\(meaningful.count == 1 ? "" : "s")"
        }

        /// The detail line for a completed tool, or nil when it merely
        /// echoes the command (T3 `threadActivity.ts` suppression).
        static func outputDetail(_ text: String, command: String?) -> String? {
            let line = output(text)
            guard !line.isEmpty, line != command else { return nil }
            return line
        }

        /// Paths trimmed to their last four components, at most twelve.
        static func files(_ paths: [String]) -> [String] {
            paths.prefix(12).map { path in
                path.split(separator: "/").suffix(4).joined(separator: "/")
            }
        }

        /// T3's item types for the tools Claude Code ships.
        static func itemType(for tool: String) -> String {
            switch tool {
            case "Bash": return "command_execution"
            case "Edit", "Write", "NotebookEdit", "MultiEdit": return "file_change"
            case "Read": return "file_read"
            case "Grep", "Glob", "WebSearch": return "search"
            default: return "dynamic_tool_call"
            }
        }
    }
}
