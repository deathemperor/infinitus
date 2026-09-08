import Foundation

/// T3 Code's `WorkLogEntry` + `TimelineEntry` (`apps/web/src/session-logic.ts`),
/// trimmed to the fields the timeline reducers read, plus the adapter that maps
/// an Infinitus `SessionTimeline` onto them (spec §2.1).
///
/// Port note: upstream's `toolData` (an untyped provider blob the reducers only
/// ever read `server`/`tool` or `toolName` out of) collapses to one `toolName`
/// string here — `"<server>.<tool>"` or the raw tool name.
public struct T3WorkLogEntry: Sendable, Equatable, Hashable, Identifiable {
    public enum Tone: String, Sendable, Hashable { case thinking, tool, info, error }
    public enum LifecycleStatus: String, Sendable, Hashable {
        case inProgress, completed, failed, declined, stopped
    }
    public enum ItemType: String, Sendable, Hashable, CaseIterable {
        case commandExecution = "command_execution"
        case fileChange = "file_change"
        case mcpToolCall = "mcp_tool_call"
        case dynamicToolCall = "dynamic_tool_call"
        case collabAgentToolCall = "collab_agent_tool_call"
        case webSearch = "web_search"
        case imageView = "image_view"
    }
    public enum RequestKind: String, Sendable, Hashable {
        case command
        case fileRead = "file-read"
        case fileChange = "file-change"
        case userInput = "user-input"
        case other
    }
    public struct ToolSource: Sendable, Equatable, Hashable {
        public let key: String, name: String, kind: String   // browser | computer | integration
        public init(key: String, name: String, kind: String) {
            self.key = key; self.name = name; self.kind = kind
        }
    }

    public var id: String
    public var createdAt: Date
    public var turnId: String?
    public var toolCallId: String?
    public var label: String
    public var detail: String?
    public var viewedImagePath: String?
    public var command: String?
    public var rawCommand: String?
    public var changedFiles: [String] = []
    public var tone: Tone
    public var toolTitle: String?
    public var toolSurface: String?
    public var toolSource: ToolSource?
    public var toolName: String?
    public var itemType: ItemType?
    public var requestKind: RequestKind?
    public var toolLifecycleStatus: LifecycleStatus?
    public var sourceActivityKind: String?
    public var taskId: String?
    public var agentRole: String?
    /// upstream `agentSpawn !== undefined`
    public var isAgentSpawn = false

    public init(id: String, createdAt: Date, label: String, tone: Tone) {
        self.id = id; self.createdAt = createdAt; self.label = label; self.tone = tone
    }

    /// session-logic.ts `toDerivedWorkLogEntry`, over an Infinitus activity.
    public init(activity a: SessionTimeline.Activity) {
        let tone: Tone
        if a.kind == "task.progress" { tone = .thinking }
        else if a.tone == .approval { tone = .info }
        else { tone = Tone(rawValue: a.tone.rawValue) ?? .info }
        self.init(id: a.id, createdAt: a.createdAt, label: a.summary, tone: tone)

        turnId = a.turnId.isEmpty ? nil : a.turnId
        sourceActivityKind = a.kind
        detail = a.detail

        func str(_ key: String) -> String? {
            guard case let .string(s)? = a.payload[key],
                  !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
        command = str("command")
        rawCommand = str("rawCommand") ?? command
        toolCallId = str("toolCallId")
        viewedImagePath = str("imagePath")
        if case let .array(files)? = a.payload["changedFiles"] {
            changedFiles = files.compactMap(\.stringValue)
        } else if let f = str("file_path") {
            changedFiles = [f]
        }
        toolName = str("toolName")
        toolTitle = str("title")

        switch str("status") {
        case "pending", "running", "waiting", "inProgress": toolLifecycleStatus = .inProgress
        case "cancelled", "interrupted", "stopped": toolLifecycleStatus = .stopped
        case "completed": toolLifecycleStatus = .completed
        case "failed": toolLifecycleStatus = .failed
        case "declined": toolLifecycleStatus = .declined
        default: toolLifecycleStatus = a.kind == "tool.completed" ? .completed : nil
        }

        switch toolName {
        case "Bash", "BashOutput": itemType = .commandExecution; requestKind = .command
        case "Edit", "Write", "MultiEdit", "NotebookEdit": itemType = .fileChange; requestKind = .fileChange
        case "Read": requestKind = .fileRead
        case "Grep", "Glob", "WebSearch", "WebFetch": itemType = .webSearch
        case "Agent", "Task": itemType = .collabAgentToolCall
        case let name? where name.hasPrefix("mcp__"): itemType = .mcpToolCall
        case .some: itemType = .dynamicToolCall
        case nil: break
        }
        if a.kind == "user-input.requested" || a.kind == "user-input.resolved" { requestKind = .userInput }
        taskId = str("taskId")
        agentRole = str("role")
    }
}

/// T3 Code's `ChatMessage`, trimmed to what the reducers read.
public struct T3ChatMessage: Sendable, Equatable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable { case user, assistant, system }
    public var id: String
    public var role: Role
    public var text: String
    public var turnId: String?
    public var streaming: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, role: Role, text: String, turnId: String?, streaming: Bool,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.role = role; self.text = text; self.turnId = turnId
        self.streaming = streaming; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Documented divergence: `SessionTimeline.Message` carries no `updatedAt`,
    /// so `updatedAt` is the message's own `createdAt`. A turn fold measured
    /// from timestamps therefore ends at the terminal assistant message's start
    /// rather than its last token.
    public init(message m: SessionTimeline.Message) {
        let turn = m.turnId.isEmpty ? nil : m.turnId
        self.init(id: m.id, role: m.role == .user ? .user : .assistant, text: m.text,
                  turnId: m.role == .user ? nil : turn, streaming: m.streaming,
                  createdAt: m.createdAt, updatedAt: m.createdAt)
    }
}

/// T3 Code's `ProposedPlan`. No Infinitus producer in sub-project A — a parked
/// `ExitPlanMode` reaches the timeline as an `approval.requested` activity —
/// but the row model the Mac window and phone build against carries it.
public struct T3ProposedPlan: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var turnId: String?
    public var planMarkdown: String
    public var implementedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, turnId: String?, planMarkdown: String, implementedAt: Date?,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.turnId = turnId; self.planMarkdown = planMarkdown
        self.implementedAt = implementedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum T3TimelineEntry: Sendable, Equatable, Hashable, Identifiable {
    case message(id: String, createdAt: Date, T3ChatMessage)
    case proposedPlan(id: String, createdAt: Date, T3ProposedPlan)
    case work(id: String, createdAt: Date, T3WorkLogEntry)

    public var id: String {
        switch self {
        case let .message(id, _, _), let .proposedPlan(id, _, _), let .work(id, _, _): return id
        }
    }
    public var createdAt: Date {
        switch self {
        case let .message(_, at, _), let .proposedPlan(_, at, _), let .work(_, at, _): return at
        }
    }
    /// `timelineEntryTurnId`: user messages carry no turn.
    public var turnId: String? {
        switch self {
        case let .message(_, _, m): return m.role == .assistant ? m.turnId : nil
        case let .proposedPlan(_, _, p): return p.turnId
        case let .work(_, _, w): return w.turnId
        }
    }

    /// Every message and activity of an Infinitus timeline, in time order
    /// (`sequence` breaks ties). `pending` is folded in first through
    /// `SessionTimeline.appending(pending:)`, so a parked approval or question
    /// becomes an `approval.requested` / `user-input.requested` activity and
    /// derives its own card. The phone's mirror already folded them — it passes
    /// `pending: []`.
    ///
    /// **Lifecycle pairing (interim, until the builder carries `command` and
    /// `toolCallId` — sub-project B).** `SessionTimelineBuilder` writes one tool
    /// call as two activities: `tool.started` with id `<toolUseId>`
    /// (SessionTimelineBuilder.swift:212) and `tool.completed` with id
    /// `<toolUseId>/completed` (:274). Their summaries are built from different
    /// inputs (SessionFeed.swift:697-710), so they differ in exactly the cases
    /// that matter — a Grep's completed summary is the bare tool name where the
    /// started one is the pattern; a Bash's completed summary is the raw
    /// command where the started one was flattened and truncated to 120. Since
    /// neither marker carries a tool call id, `omitSupersededLifecycleMarkers`
    /// can only collapse them on `(turnId, itemType, normalizedLabel)`, which
    /// differing labels defeat: the statusless started marker survives, still
    /// reads as in-flight, and takes the live activity row — showing the search
    /// pattern as if it were still running long after the call finished.
    ///
    /// So a `tool.started` whose `/completed` twin is present in the same
    /// timeline is dropped here, and its summary — the builder's display form,
    /// the one carrying the pattern or the flattened command — is carried onto
    /// the surviving entry's `label`. Everything else about the completed entry
    /// (status, tone, `createdAt`, `detail`, payload) is untouched. A started
    /// marker with no twin is kept: a call in flight must still show.
    public static func entries(from timeline: SessionTimeline,
                               pending: [PendingRequest] = []) -> [T3TimelineEntry] {
        let source = pending.isEmpty ? timeline : timeline.appending(pending: pending)
        let activityIds = Set(source.activities.map(\.id))
        var labelFromStarted: [String: String] = [:]
        for a in source.activities where a.kind == "tool.started" && activityIds.contains("\(a.id)/completed") {
            labelFromStarted["\(a.id)/completed"] = a.summary
        }

        var out: [(Date, Int, T3TimelineEntry)] = []
        out.reserveCapacity(source.messages.count + source.activities.count)
        for m in source.messages {
            out.append((m.createdAt, 0, .message(id: "message:\(m.id)", createdAt: m.createdAt,
                                                 T3ChatMessage(message: m))))
        }
        for a in source.activities {
            if a.kind == "tool.started", activityIds.contains("\(a.id)/completed") { continue }
            var work = T3WorkLogEntry(activity: a)
            if let started = labelFromStarted[a.id],
               !started.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                work.label = started
            }
            out.append((a.createdAt, a.sequence + 1, .work(id: "activity:\(a.id)", createdAt: a.createdAt, work)))
        }
        return out.enumerated()
            .sorted { l, r in
                if l.element.0 != r.element.0 { return l.element.0 < r.element.0 }
                if l.element.1 != r.element.1 { return l.element.1 < r.element.1 }
                return l.offset < r.offset
            }
            .map(\.element.2)
    }
}
