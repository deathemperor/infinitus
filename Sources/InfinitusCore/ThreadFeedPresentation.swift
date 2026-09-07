import Foundation

/// The rows a session feed draws (#223 phase 2) — T3's
/// `buildThreadFeed` + `deriveThreadFeedPresentation` ported as one pure
/// reducer over a `SessionTimeline`. Ids are stable across re-derivation
/// so list diffing is cheap; the shimmering row keeps ONE id for as long
/// as anything is live, so the shimmer never restarts.
public struct ThreadFeedRow: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: Equatable, Codable, Sendable {
        case message(SessionTimeline.Message)
        /// Rows shown as they are: the expanded details of a work group,
        /// or a standalone activity (prompt, warning, error, compaction).
        case activityGroup([WorkEntry])
        case workToggle(WorkToggle)
        case turnFold(TurnFold)
        /// Working with nothing live to shimmer.
        case thinking
        case agentSpawn(AgentSpawn)
    }

    public let id: String
    public let turnId: String
    public let createdAt: Date
    public let kind: Kind

    /// The id the one shimmering row carries (T3 `LIVE_ACTIVITY_ROW_ID`).
    public static let liveRowId = "live-activity-row"
}

/// One activity as the feed shows it: a tool's `started`/`completed`
/// pair collapsed into one entry (position of the start, payload of the
/// end), classified for grouping.
public struct WorkEntry: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case inProgress, success, failure, neutral }
    public enum Action: String, Codable, Sendable { case read, edit, command, browser, codeSearch, search, other, update }

    public let id: String
    public let kind: String
    public let tone: SessionTimeline.Activity.Tone
    public let summary: String
    public let detail: String?
    public let status: Status
    public let action: Action
    public let toolLike: Bool
    public let toolCallId: String?
    public let requestId: String?
    public let changedFiles: [String]
    public let payload: [String: JSONValue]
    public let turnId: String
    public let createdAt: Date
}

public struct WorkToggle: Equatable, Codable, Sendable {
    public let groupId: String
    public let summary: String
    public let hiddenCount: Int
    public let expanded: Bool
    public let hasFailure: Bool
    /// The group is the tail of the working turn and its last call is
    /// running or just succeeded — the row shimmers.
    public let live: Bool
}

public struct TurnFold: Equatable, Codable, Sendable {
    public let label: String
    public let expanded: Bool
    public let hiddenCount: Int
}

public struct AgentSpawn: Equatable, Codable, Sendable {
    public struct Member: Equatable, Codable, Sendable {
        public let id: String
        public let title: String
        public let agentType: String
        public let running: Bool
        public let failed: Bool
        public let lastTool: String?
    }
    public let title: String
    public let members: [Member]
}

public enum ThreadFeedPresentation {
    /// Derive the rows. `expandedTurnIds` / `expandedWorkGroupIds` are the
    /// viewer's toggles keyed by `TurnFold` turn id and `WorkToggle.groupId`;
    /// `now` stamps the thinking row.
    public static func derive(_ timeline: SessionTimeline, expandedTurnIds: Set<String> = [],
                              expandedWorkGroupIds: Set<String> = [], now: Date = Date()) -> [ThreadFeedRow] {
        let turns = Dictionary(timeline.turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let latest = timeline.latestTurn
        let isWorking = latest?.state == .running
        let unsettledTurnId = isWorking ? latest?.id : nil

        // A call still open in a settled turn is a neutral marker (the
        // turn was interrupted or the result aged out) — dropped, as T3 does.
        let entries = collapse(timeline.activities).filter {
            !($0.toolLike && $0.status == .inProgress && $0.turnId != unsettledTurnId)
        }
        let items = merge(messages: timeline.messages, entries: entries)
        let groups = group(items)

        // Rows per turn, in order; the fold decides what a settled turn shows.
        var rows: [ThreadFeedRow] = []
        var liveRowPresent = false
        var byTurn: [(turnId: String, items: [Group])] = []
        for g in groups {
            if let last = byTurn.last, last.turnId == g.turnId { byTurn[byTurn.count - 1].items.append(g) }
            else { byTurn.append((g.turnId, [g])) }
        }

        for (turnId, groupsOfTurn) in byTurn {
            let turn = turns[turnId]
            let settled = turnId != unsettledTurnId
            let streaming = groupsOfTurn.contains { if case .message(let m) = $0, m.streaming { return true }; return false }
            let foldable = settled && !streaming && turn != nil

            // Which groups are hidden behind the fold: work, agents and
            // every assistant message but the first and the last.
            let assistantIdx = groupsOfTurn.indices.filter {
                if case .message(let m) = groupsOfTurn[$0], m.role == .assistant { return true }; return false
            }
            var hidden = Set<Int>()
            if foldable {
                for (i, g) in groupsOfTurn.enumerated() {
                    switch g {
                    case .tools, .agents: hidden.insert(i)
                    case .message:
                        if assistantIdx.count > 2, let f = assistantIdx.first, let l = assistantIdx.last, i != f, i != l { hidden.insert(i) }
                    case .standalone: break
                    }
                }
            }
            let foldRow = foldable && (!hidden.isEmpty || turn?.state == .interrupted)
            let turnExpanded = expandedTurnIds.contains(turnId)
            var foldInserted = false

            for (i, g) in groupsOfTurn.enumerated() {
                let isTail = isWorking && !settled && i == groupsOfTurn.count - 1
                if foldRow, !foldInserted, !isUserMessage(g) {
                    rows.append(foldRowFor(turn!, hidden: hidden.count, expanded: turnExpanded))
                    foldInserted = true
                }
                if hidden.contains(i), !turnExpanded { continue }
                switch g {
                case .message(let m):
                    rows.append(ThreadFeedRow(id: "message:\(m.id)", turnId: turnId, createdAt: m.createdAt, kind: .message(m)))
                case .standalone(let e):
                    rows.append(ThreadFeedRow(id: "activity:\(e.id)", turnId: turnId, createdAt: e.createdAt, kind: .activityGroup([e])))
                case .agents(let members):
                    rows.append(agentRow(members, turnId: turnId))
                case .tools(let entries):
                    let (toggle, details) = toolRows(entries, turnId: turnId, activeTail: isTail, expanded: expandedWorkGroupIds)
                    if toggle.id == ThreadFeedRow.liveRowId { liveRowPresent = true }
                    rows.append(toggle)
                    if let details { rows.append(details) }
                }
            }
            if foldRow, !foldInserted { rows.append(foldRowFor(turn!, hidden: 0, expanded: turnExpanded)) }
        }

        if isWorking, !liveRowPresent {
            rows.append(ThreadFeedRow(id: ThreadFeedRow.liveRowId, turnId: unsettledTurnId ?? "", createdAt: now, kind: .thinking))
        }
        return rows
    }

    // MARK: Stage 1 — entries

    /// Activities as `WorkEntry`s, each tool's started/completed pair (and
    /// each sub-agent's) collapsed onto the start's position.
    static func collapse(_ activities: [SessionTimeline.Activity]) -> [WorkEntry] {
        var out: [WorkEntry] = []
        var openIndex: [String: Int] = [:]   // "<turnId>\u{0}<toolCallId>" → index in out
        for a in activities {
            let entry = WorkEntry(a)
            if let call = entry.toolCallId {
                let key = a.turnId + "\u{0}" + call
                if a.kind == "tool.completed" || a.kind == "task.completed", let i = openIndex[key] {
                    out[i] = entry.replacing(id: out[i].id, createdAt: out[i].createdAt)
                    continue
                }
                openIndex[key] = out.count
            }
            out.append(entry)
        }
        return out
    }

    enum Item {
        case message(SessionTimeline.Message)
        case entry(WorkEntry)
        var createdAt: Date { switch self { case .message(let m): return m.createdAt; case .entry(let e): return e.createdAt } }
        var turnId: String { switch self { case .message(let m): return m.turnId; case .entry(let e): return e.turnId } }
    }

    /// Messages and entries interleaved by time; a message wins a tie so
    /// the prompt that opened a turn leads it.
    static func merge(messages: [SessionTimeline.Message], entries: [WorkEntry]) -> [Item] {
        let items = messages.map(Item.message) + entries.map(Item.entry)
        return items.enumerated().sorted { a, b in
            if a.element.createdAt != b.element.createdAt { return a.element.createdAt < b.element.createdAt }
            switch (a.element, b.element) {
            case (.message, .entry): return true
            case (.entry, .message): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Stage 2 — groups

    enum Group {
        case message(SessionTimeline.Message)
        /// Adjacent tool calls (and plan updates) of one turn: one toggle.
        case tools([WorkEntry])
        /// Adjacent sub-agent spawns of one turn: one card.
        case agents([WorkEntry])
        /// Shown as is, never summarized: prompts, warnings, errors, compaction.
        case standalone(WorkEntry)

        var turnId: String {
            switch self {
            case .message(let m): return m.turnId
            case .tools(let e), .agents(let e): return e.first?.turnId ?? ""
            case .standalone(let e): return e.turnId
            }
        }
    }

    static let standaloneKinds: Set<String> = ["context-compaction", "approval.requested", "user-input.requested",
                                                "user-input.resolved", "runtime.warning", "runtime.error"]

    static func group(_ items: [Item]) -> [Group] {
        var out: [Group] = []
        for item in items {
            switch item {
            case .message(let m):
                out.append(.message(m))
            case .entry(let e):
                if standaloneKinds.contains(e.kind) { out.append(.standalone(e)); continue }
                let isAgent = e.kind.hasPrefix("task.")
                if let last = out.last {
                    switch last {
                    case .tools(let run) where !isAgent && run.last?.turnId == e.turnId:
                        out[out.count - 1] = .tools(run + [e]); continue
                    case .agents(let run) where isAgent && run.last?.turnId == e.turnId:
                        out[out.count - 1] = .agents(run + [e]); continue
                    default: break
                    }
                }
                out.append(isAgent ? .agents([e]) : .tools([e]))
            }
        }
        return out
    }

    static func isUserMessage(_ g: Group) -> Bool {
        if case .message(let m) = g, m.role == .user { return true }
        return false
    }

    // MARK: Rows

    static func foldRowFor(_ turn: SessionTimeline.Turn, hidden: Int, expanded: Bool) -> ThreadFeedRow {
        let elapsed = turn.completedAt.map { $0.timeIntervalSince(turn.startedAt ?? turn.requestedAt) }
        let dur = elapsed.flatMap { $0 >= 1 ? formatDuration($0) : nil }
        let label: String
        if turn.state == .interrupted { label = dur.map { "You stopped after \($0)" } ?? "You stopped this response" }
        else { label = dur.map { "Worked for \($0)" } ?? "Worked" }
        return ThreadFeedRow(id: "turn-fold:\(turn.id)", turnId: turn.id, createdAt: turn.requestedAt,
                             kind: .turnFold(TurnFold(label: label, expanded: expanded, hiddenCount: hidden)))
    }

    static func toolRows(_ entries: [WorkEntry], turnId: String, activeTail: Bool,
                         expanded: Set<String>) -> (ThreadFeedRow, ThreadFeedRow?) {
        let first = entries[0], last = entries[entries.count - 1]
        let groupId = "work-group:tool:\(turnId):\(first.toolCallId ?? first.id)"
        let live = activeTail && (last.status == .inProgress || last.status == .success)
        let summary: String
        if live { summary = liveSummary(last) }
        else if entries.count == 1 { summary = first.summary }
        else { summary = summarizeGroup(entries) }
        let isExpanded = expanded.contains(groupId)
        let toggle = ThreadFeedRow(id: live ? ThreadFeedRow.liveRowId : "work-toggle:\(groupId)", turnId: turnId,
                                   createdAt: first.createdAt,
                                   kind: .workToggle(WorkToggle(groupId: groupId, summary: summary, hiddenCount: entries.count,
                                                                expanded: isExpanded,
                                                                hasFailure: entries.contains { $0.status == .failure }, live: live)))
        let details = isExpanded
            ? ThreadFeedRow(id: "work-details:\(groupId)", turnId: turnId, createdAt: first.createdAt, kind: .activityGroup(entries))
            : nil
        return (toggle, details)
    }

    static func agentRow(_ entries: [WorkEntry], turnId: String) -> ThreadFeedRow {
        let members = entries.map { e -> AgentSpawn.Member in
            var running = e.kind == "task.started"
            if case .bool(let r)? = e.payload["running"] { running = r }
            return AgentSpawn.Member(id: e.toolCallId ?? e.id, title: e.summary,
                                     agentType: e.payload["agentType"]?.stringValue ?? "agent",
                                     running: running, failed: e.tone == .error, lastTool: e.payload["lastTool"]?.stringValue)
        }
        let running = members.filter(\.running).count, failed = members.filter(\.failed).count
        let noun = members.count == 1 ? "subagent" : "subagents"
        var title = running > 0 ? "Kicked off \(members.count) \(noun)" : "Ran \(members.count) \(noun)"
        if running > 0, running < members.count { title += " · \(running) working" }
        if failed > 0 { title += " · \(failed) failed" }
        return ThreadFeedRow(id: "agent-spawn:\(turnId):\(members[0].id)", turnId: turnId, createdAt: entries[0].createdAt,
                             kind: .agentSpawn(AgentSpawn(title: title, members: members)))
    }

    // MARK: Labels (T3 work-log/presentation.ts)

    /// "Running git" while a command runs, "Ran git" once it returned;
    /// files and searches get the same tense, other tools keep their label.
    static func liveSummary(_ e: WorkEntry) -> String {
        let running = e.status == .inProgress
        switch e.action {
        case .command:
            guard let program = commandProgram(e.summary) else { return e.summary }
            return (running ? "Running " : "Ran ") + program
        case .read: return (running ? "Reading " : "Read ") + e.summary
        case .edit: return (running ? "Editing " : "Changed ") + e.summary
        case .codeSearch, .search: return (running ? "Searching " : "Searched ") + e.summary
        default: return e.summary
        }
    }

    /// The program a shell line runs, past `cd …&&`, env assignments and sudo.
    static func commandProgram(_ command: String) -> String? {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if let amp = words.firstIndex(of: "&&"), words.first == "cd" { words.removeFirst(amp + 1) }
        while let w = words.first, w == "sudo" || w == "env" || w.contains("=") && !w.hasPrefix("-") { words.removeFirst() }
        guard let program = words.first, !program.isEmpty else { return nil }
        return URL(fileURLWithPath: program).lastPathComponent
    }

    /// "Read 2 files, changed 1 file, and ran 3 commands" — actions in the
    /// order they first appear, edits counted by distinct file.
    static func summarizeGroup(_ entries: [WorkEntry]) -> String {
        var order: [WorkEntry.Action] = []
        var counts: [WorkEntry.Action: Int] = [:]
        var editedFiles = Set<String>()
        for e in entries {
            if counts[e.action] == nil { order.append(e.action) }
            if e.action == .edit {
                if e.changedFiles.isEmpty { editedFiles.insert(e.id) } else { editedFiles.formUnion(e.changedFiles) }
                counts[.edit] = editedFiles.count
            } else {
                counts[e.action, default: 0] += 1
            }
        }
        let parts = order.map { actionLabel($0, counts[$0] ?? 0) }
        let joined: String
        switch parts.count {
        case 0: joined = ""
        case 1: joined = parts[0]
        case 2: joined = parts[0] + " and " + parts[1]
        default: joined = parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func actionLabel(_ action: WorkEntry.Action, _ n: Int) -> String {
        func plural(_ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        switch action {
        case .read: return "read " + plural("file", "files")
        case .edit: return "changed " + plural("file", "files")
        case .command: return "ran " + plural("command", "commands")
        case .browser: return "browsed " + plural("page", "pages")
        case .codeSearch: return "searched code " + plural("time", "times")
        case .search: return "searched " + plural("time", "times")
        case .other: return "used " + plural("tool", "tools")
        case .update: return "received " + plural("update", "updates")
        }
    }

    /// "8s", "2m 14s", "1h 2m" — the fold's elapsed time.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }
}

extension WorkEntry {
    /// Classify one activity (T3 `toolGroupAction` / `workEntryStatus`).
    init(_ a: SessionTimeline.Activity) {
        let toolLike = a.kind.hasPrefix("tool.")
        let toolName = a.payload["toolName"]?.stringValue ?? ""
        let itemType = a.payload["itemType"]?.stringValue ?? ""
        let changed = a.payload["changedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let action: Action
        if !toolLike { action = .update }
        else if itemType == "file_read" { action = .read }
        else if itemType == "file_change" || !changed.isEmpty { action = .edit }
        else if itemType == "command_execution" { action = .command }
        else if toolName == "WebFetch" || toolName.hasPrefix("mcp__claude-in-chrome") { action = .browser }
        else if toolName == "Grep" || toolName == "Glob" { action = .codeSearch }
        else if itemType == "search" { action = .search }
        else { action = .other }
        let status: Status
        switch a.kind {
        case "tool.started": status = .inProgress
        case "tool.completed": status = a.payload["status"]?.stringValue == "failed" ? .failure : .success
        default: status = a.tone == .error ? .failure : .neutral
        }
        var toolCallId: String? = nil
        if toolLike { toolCallId = a.id.hasSuffix("/completed") ? String(a.id.dropLast(10)) : a.id }
        else if a.kind.hasPrefix("task."), a.id.hasPrefix("task:") {
            let stripped = a.id.hasSuffix("/completed") ? String(a.id.dropLast(10)) : a.id
            toolCallId = String(stripped.dropFirst(5))
        }
        self.init(id: a.id, kind: a.kind, tone: a.tone, summary: a.summary, detail: a.detail, status: status, action: action,
                  toolLike: toolLike, toolCallId: toolCallId, requestId: a.payload["requestId"]?.stringValue,
                  changedFiles: changed, payload: a.payload, turnId: a.turnId, createdAt: a.createdAt)
    }

    func replacing(id: String, createdAt: Date) -> WorkEntry {
        WorkEntry(id: id, kind: kind, tone: tone, summary: summary, detail: detail, status: status, action: action,
                  toolLike: toolLike, toolCallId: toolCallId, requestId: requestId, changedFiles: changedFiles,
                  payload: payload, turnId: turnId, createdAt: createdAt)
    }
}
