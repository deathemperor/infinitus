import Foundation

/// T3's Agents right-panel model (`AgentsPanel.tsx`, whose data is upstream's
/// `AgentPanelModel` / `RuntimeSubagent` in
/// `packages/client-runtime/src/state/subagentRuntime.ts:59-87,698-708`, both at
/// the pinned sha 6c583620f).
///
/// Upstream's roster is a server-side projection over an orchestration event
/// stream. Ours is the same shape read off the only source a Claude Code
/// session leaves behind: `<transcript dir>/<sessionId>/subagents/` —
/// `agent-<id>.jsonl` plus `agent-<id>.meta.json`, one level deeper for a
/// workflow run (`subagents/workflows/<run>/`, `Transcript.agentFiles(under:)`)
/// — joined with the spawn rows the chat already derives
/// (`AgentSpawn.Member`, `ThreadFeedPresentation.swift:115-126`).
///
/// Mapping, ours → upstream (`RuntimeSubagent`):
/// - `title` ← the meta's `description`; `role` ← its `agentType`, hidden by the
///   row when it equals the title case-insensitively (upstream `:147-150`).
/// - `kind` ← `.subagent`, or `.workflowAgent` (upstream `"workflow_agent"`)
///   when the file lives under `workflows/<run>/`.
/// - `status`: the spawn row wins when the agent still has one, so the panel
///   never disagrees with the chat — `failed` → `.failed`, else `running` →
///   `.running`, else `.completed` (`AgentSpawn.Member`, whose `failed` is the
///   parent's `is_error` on the Agent tool_result, `SessionTimelineBuilder.swift:256-262`).
///   Without a spawn row (an agent aged out of the feed's tail window, every
///   workflow member) the fallback is the SAME rule the feed applies today,
///   `SessionFeedReader.attachAgents` (`SessionFeed.swift:325-334`): running =
///   the log does not end in assistant text AND it was touched inside
///   `freshWindow`; anything else is settled. A workflow member also settles on
///   its run's `journal.jsonl` carrying a `result` for its `agentId`.
///   `cancelled` / `interrupted` / `idle` / `waiting` / `pending` are not
///   knowable from a transcript and are omitted rather than faked — so
///   `STATUS_VISUALS`' in-flight row (`AgentsPanel.tsx:39-49`) is only ever
///   reached through `.running`.
/// - `startedAt` ← the log's first `timestamp`; `completedAt` ← its last, only
///   once settled.
/// - `model` ← the last assistant line's `message.model` (upstream's
///   `formatSubagentModelLabel` compacts it).
/// - `usage.totalTokens` ← Σ over the assistant lines of `usage.input_tokens +
///   output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
///   The cache fields are included because Claude Code's real numbers are
///   nearly all cache (`input_tokens: 2, cache_creation_input_tokens: 59103,
///   output_tokens: 7` on a live line): input+output alone would read as a
///   handful of tokens for a megabyte of work.
/// - `usage.toolUses` ← the count of `tool_use` blocks; `lastToolName` ← the
///   last one's bare `name` (upstream renders it as `▸ Name`, `:127`), never
///   the feed's decorated `"Bash · …"` summary.
/// - `result` ← the first line of the final assistant text; `error` ← that same
///   text when the agent failed (a transcript has no separate error channel).
/// - Omitted, because nothing on disk carries them: `progress`, `effort`,
///   `activationCount`, `phases`, `recentActivity`, `outputFile`,
///   `parentAgentId`, `agentIndex`, `phaseIndex`, `attempt`, `workflowName`,
///   `runHandles`, `firstSeenAt`, `updatedAt`. The metadata line therefore
///   reads `model · N tok · N tools` (upstream `:151-156`, whose `run N`
///   segment needs `activationCount`), and `PhaseRail` (`:215-265`) has no
///   input: a real run dir holds only `agent-*.jsonl`, `agent-*.meta.json` and
///   a `journal.jsonl` of `{"type":"started"|"result","key","agentId"}` lines —
///   no phase list, no phase titles.
///
/// Pure below `panel(subagentsDir:spawns:now:)`: the file reads produce `Log`
/// values and everything else folds those, so the tests drive it on canned
/// JSONL strings.
public enum T3Agents {
    // MARK: Model

    /// Only the states a transcript can prove (see the header).
    public enum Status: String, Sendable, Equatable, Codable {
        case running, completed, failed

        /// Upstream's in-flight/settled split (`isTerminalSubagentStatus`,
        /// `subagentRuntime.ts:90-99`).
        public var isSettled: Bool { self != .running }
    }

    /// Upstream's `RuntimeSubagent["kind"]`, minus the two an on-disk agent is
    /// never seen as (`subagent_batch`, `workflow`).
    public enum Kind: String, Sendable, Equatable, Codable {
        case subagent, workflowAgent
    }

    /// `SubagentUsage` (`subagentRuntime.ts:32-40`), the two fields the
    /// metadata line reads.
    public struct Usage: Sendable, Equatable, Codable {
        public let totalTokens: Int
        public let toolUses: Int
        public init(totalTokens: Int, toolUses: Int) {
            self.totalTokens = totalTokens
            self.toolUses = toolUses
        }
    }

    public struct Agent: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let kind: Kind
        public let title: String
        public let role: String?
        public let model: String?
        public let status: Status
        /// `nil` when the log carried no assistant line at all — the row then
        /// prints "— tok" (upstream `:153`).
        public let usage: Usage?
        public let lastToolName: String?
        public let result: String?
        public let error: String?
        public let startedAt: Date?
        public let completedAt: Date?

        public init(id: String, kind: Kind, title: String, role: String?, model: String?,
                    status: Status, usage: Usage?, lastToolName: String?, result: String?,
                    error: String?, startedAt: Date?, completedAt: Date?) {
            self.id = id
            self.kind = kind
            self.title = title
            self.role = role
            self.model = model
            self.status = status
            self.usage = usage
            self.lastToolName = lastToolName
            self.result = result
            self.error = error
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    /// One `subagents/workflows/<run>/` directory. Upstream's
    /// `AgentPanelWorkflowGroup` carries a coordinator `RuntimeSubagent` plus
    /// phased and unphased members; a run dir has no coordinator agent and no
    /// phases, so this is the `unphasedMembers` case with the run's own id as
    /// the title (`CollapsedWorkflowSection` renders `workflowName ?? title`,
    /// `:487-489`).
    public struct Workflow: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let title: String
        public let members: [Agent]

        public init(id: String, title: String, members: [Agent]) {
            self.id = id
            self.title = title
            self.members = members
        }

        /// `CollapsedWorkflowSection`'s summary numbers (`:466-473`).
        public var failedCount: Int { members.filter { $0.status == .failed }.count }
        public var totalTokens: Int { members.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) } }
        /// A run is live while any member is (upstream's `workflowIsLive`
        /// reads the coordinator's status, `:195-203`; we have no coordinator).
        public var isLive: Bool { members.contains { $0.status == .running } }
        /// The run's own span: its earliest start to its latest finish, and
        /// only once every member has settled (upstream shows the elapsed on a
        /// collapsed run only when the coordinator has both stamps, `:474-477`).
        public var startedAt: Date? { members.compactMap(\.startedAt).min() }
        public var completedAt: Date? {
            guard !isLive, members.allSatisfy({ $0.completedAt != nil }) else { return nil }
            return members.compactMap(\.completedAt).max()
        }
    }

    /// `AgentPanelModel` (`subagentRuntime.ts:698-708`), minus the counters
    /// whose statuses we never produce (`waitingCount`, `idleCount`) — the
    /// footer's "N working" reads `liveCount`.
    public struct Panel: Sendable, Equatable, Codable {
        public let directAgents: [Agent]
        public let workflows: [Workflow]
        public let liveCount: Int
        public let settledCount: Int
        public let totalTokens: Int
        public let hasAgents: Bool
        /// When the elapsed strings were computed. Every row's "now" — a
        /// running agent's elapsed is frozen at this instant and only moves
        /// when the next feed pump derives a new `Panel`, so no row needs a
        /// ticker (upstream's `AgentElapsed` runs a `setInterval(1000)`,
        /// `:92-104`; we refuse one, #18's CPU rule).
        public let derivedAt: Date

        public init(directAgents: [Agent], workflows: [Workflow], liveCount: Int,
                    settledCount: Int, totalTokens: Int, hasAgents: Bool, derivedAt: Date) {
            self.directAgents = directAgents
            self.workflows = workflows
            self.liveCount = liveCount
            self.settledCount = settledCount
            self.totalTokens = totalTokens
            self.hasAgents = hasAgents
            self.derivedAt = derivedAt
        }

        public static func empty(derivedAt: Date = Date()) -> Panel {
            Panel(directAgents: [], workflows: [], liveCount: 0, settledCount: 0,
                  totalTokens: 0, hasAgents: false, derivedAt: derivedAt)
        }
    }

    // MARK: Formatters (ported verbatim)

    /// `formatElapsedSeconds` (`AgentsPanel.tsx:61-72`): "5s", "3m 05s", "1h 02m".
    public static func formatElapsedSeconds(_ totalSeconds: Double) -> String {
        let seconds = Int(max(0, totalSeconds.rounded(.down)))
        let minutes = seconds / 60
        if minutes == 0 { return "\(seconds)s" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m \(pad2(seconds % 60))s" }
        return "\(hours)h \(pad2(minutes % 60))m"
    }

    /// `elapsedBetween` (`:74-81`) — `end` is the panel's `derivedAt` for a
    /// running agent, its `completedAt` once settled. "" when either is absent
    /// (upstream's `Number.isNaN` guard on an unparsable ISO stamp).
    public static func elapsed(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "" }
        return formatElapsedSeconds(end.timeIntervalSince(start))
    }

    /// The row's elapsed: live rows measure to the panel's instant, settled
    /// rows freeze at `completedAt` (`AgentElapsed`, `:111`).
    public static func elapsed(of agent: Agent, panel: Panel) -> String {
        elapsed(from: agent.startedAt, to: agent.status == .running ? panel.derivedAt : agent.completedAt)
    }

    /// `formatSubagentModelLabel` (`subagentRuntime.ts:869-881`) without the
    /// `effort` argument, which nothing on disk carries: strips a leading
    /// `claude-`, a trailing 8-digit date and a trailing `-latest`.
    public static func modelLabel(_ model: String?) -> String? {
        guard var compact = model, !compact.isEmpty else { return nil }
        if compact.hasPrefix("claude-") { compact.removeFirst("claude-".count) }
        if compact.hasSuffix("-latest") {
            compact.removeLast("-latest".count)
        } else if compact.count > 9, compact[compact.index(compact.endIndex, offsetBy: -9)] == "-",
                  compact.suffix(8).allSatisfy(\.isNumber) {
            compact.removeLast(9)
        }
        return compact
    }

    /// `formatSubagentTokenCount` (`subagentRuntime.ts:883-892`).
    public static func tokenCount(_ totalTokens: Int) -> String {
        if totalTokens < 1000 { return "\(totalTokens)" }
        if totalTokens < 1_000_000 {
            let value = Double(totalTokens) / 1000
            return value >= 100 ? "\(Int(value.rounded()))k" : String(format: "%.1fk", value)
        }
        return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
    }

    /// `STATUS_VISUALS[status].label` (`AgentsPanel.tsx:39-49`).
    public static func statusLabel(_ status: Status) -> String {
        switch status {
        case .running: return "Working"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    /// `agentActivityText` (`:121-138`): live rows lead with what is happening,
    /// settled rows with the outcome. `progress` is omitted from both chains.
    public static func activityText(_ agent: Agent) -> String? {
        if agent.status == .running {
            return agent.lastToolName.map { "▸ \($0)" } ?? agent.result ?? agent.error
        }
        return agent.error ?? agent.result ?? agent.lastToolName.map { "▸ \($0)" }
    }

    /// `AgentRow`'s metadata line (`:151-156`), joined with " · ".
    public static func metadataLine(_ agent: Agent) -> String {
        var parts: [String] = []
        if let label = modelLabel(agent.model) { parts.append(label) }
        parts.append(agent.usage.map { "\(tokenCount($0.totalTokens)) tok" } ?? "— tok")
        if let usage = agent.usage { parts.append("\(usage.toolUses) tools") }
        return parts.joined(separator: " · ")
    }

    /// `role` hidden when it says nothing the title does not (`:147-150`).
    public static func visibleRole(_ agent: Agent) -> String? {
        guard let role = agent.role else { return nil }
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != agent.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        return role
    }

    private static func pad2(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    // MARK: Reading one agent log

    /// Everything one `agent-<id>.jsonl` says, and the only impure input to the
    /// model. `endsWithAssistantText` and `freshAt` are `attachAgents`' two
    /// signals (`SessionFeed.swift:325-334`).
    public struct Log: Sendable, Equatable {
        public let id: String
        public let agentType: String?
        public let description: String?
        /// The parent's `tool_use` id, present only on a directly spawned
        /// agent's meta — a workflow member's meta has neither this nor
        /// `description` (2,259 real run metas carry only `agentType`,
        /// `spawnDepth` and sometimes `model`).
        public let toolUseId: String?
        public let model: String?
        public let firstAt: Date?
        public let lastAt: Date?
        public let totalTokens: Int
        public let toolUses: Int
        public let lastToolName: String?
        public let assistantLines: Int
        public let finalText: String?
        public let endsWithAssistantText: Bool
        public let modifiedAt: Date?

        public init(id: String, agentType: String? = nil, description: String? = nil,
                    toolUseId: String? = nil, model: String? = nil, firstAt: Date? = nil,
                    lastAt: Date? = nil, totalTokens: Int = 0, toolUses: Int = 0,
                    lastToolName: String? = nil, assistantLines: Int = 0, finalText: String? = nil,
                    endsWithAssistantText: Bool = false, modifiedAt: Date? = nil) {
            self.id = id
            self.agentType = agentType
            self.description = description
            self.toolUseId = toolUseId
            self.model = model
            self.firstAt = firstAt
            self.lastAt = lastAt
            self.totalTokens = totalTokens
            self.toolUses = toolUses
            self.lastToolName = lastToolName
            self.assistantLines = assistantLines
            self.finalText = finalText
            self.endsWithAssistantText = endsWithAssistantText
            self.modifiedAt = modifiedAt
        }
    }

    /// The `agent-<id>.meta.json` fields this surface reads. Decoded here
    /// rather than through `SessionFeedReader.metas`: that cache's `AgentMeta`
    /// requires a `toolUseId`, which a workflow member's meta never has.
    public struct Meta: Sendable, Equatable {
        public let agentType: String?
        public let description: String?
        public let toolUseId: String?
        public init(agentType: String?, description: String?, toolUseId: String?) {
            self.agentType = agentType
            self.description = description
            self.toolUseId = toolUseId
        }
    }

    /// The running fold over a log's lines. Separate from `Log` so the cache
    /// can resume it: a JSONL transcript is append-only, so a log that grew
    /// since the last pump absorbs only its new bytes instead of re-parsing
    /// megabytes (a live agent's log reaches 11 MB in this repo's own sessions).
    struct Accum: Sendable, Equatable {
        var firstAt: Date?
        var lastAt: Date?
        var model: String?
        var totalTokens = 0
        var toolUses = 0
        var assistantLines = 0
        var lastToolName: String?
        var finalText: String?
        var endsWithAssistantText = false

        mutating func absorb(lines: [String]) {
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let stamp = (entry["timestamp"] as? String).flatMap(UsageHistory.parseISO) {
                    if firstAt == nil { firstAt = stamp }
                    lastAt = stamp
                }
                guard (entry["type"] as? String) == "assistant",
                      let message = entry["message"] as? [String: Any] else { continue }
                assistantLines += 1
                if let m = message["model"] as? String, !m.isEmpty { model = m }
                if let usage = message["usage"] as? [String: Any] {
                    for key in ["input_tokens", "output_tokens",
                                "cache_creation_input_tokens", "cache_read_input_tokens"] {
                        totalTokens += (usage[key] as? NSNumber)?.intValue ?? 0
                    }
                }
                guard let content = message["content"] as? [[String: Any]] else { continue }
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        toolUses += 1
                        if let name = block["name"] as? String, !name.isEmpty { lastToolName = name }
                        endsWithAssistantText = false
                    case "text":
                        guard let text = block["text"] as? String,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        finalText = text
                        endsWithAssistantText = true
                    default: break
                    }
                }
            }
        }
    }

    /// Fold one agent's JSONL lines (already split) plus its meta into a `Log`.
    public static func log(id: String, lines: [String], meta: Meta? = nil,
                           modifiedAt: Date? = nil) -> Log {
        var accum = Accum()
        accum.absorb(lines: lines)
        return log(id: id, accum: accum, meta: meta, modifiedAt: modifiedAt)
    }

    static func log(id: String, accum: Accum, meta: Meta?, modifiedAt: Date?) -> Log {
        Log(id: id, agentType: meta?.agentType, description: meta?.description,
            toolUseId: meta?.toolUseId, model: accum.model, firstAt: accum.firstAt,
            lastAt: accum.lastAt, totalTokens: accum.totalTokens, toolUses: accum.toolUses,
            lastToolName: accum.lastToolName, assistantLines: accum.assistantLines,
            finalText: accum.finalText, endsWithAssistantText: accum.endsWithAssistantText,
            modifiedAt: modifiedAt)
    }

    // MARK: Folding logs into the panel

    /// A run's `journal.jsonl` (`{"type":"started"|"result","key","agentId"}`):
    /// the agent ids it has already recorded a `result` for, and that result's
    /// text. The only settle signal a workflow member has — no parent
    /// tool_result exists for it.
    public struct Journal: Sendable, Equatable {
        public let results: [String: String]
        public init(results: [String: String]) { self.results = results }
        public static let none = Journal(results: [:])

        public static func parse(lines: [String]) -> Journal {
            var results: [String: String] = [:]
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (entry["type"] as? String) == "result",
                      let agentId = entry["agentId"] as? String else { continue }
                results[agentId] = entry["result"] as? String ?? ""
            }
            return Journal(results: results)
        }
    }

    /// One workflow run's logs, with the run's journal.
    public struct Run: Sendable, Equatable {
        public let id: String
        public let logs: [Log]
        public let journal: Journal
        public init(id: String, logs: [Log], journal: Journal = .none) {
            self.id = id
            self.logs = logs
            self.journal = journal
        }
    }

    /// How long after its last write a log with no final assistant text still
    /// reads as running — `attachAgents`' 120 s (`SessionFeed.swift:333`).
    public static let freshWindow: TimeInterval = 120

    /// Build one `Agent`. `spawn` is the chat's row for it when it still has
    /// one; `settledByJournal` is the run journal's verdict for a workflow
    /// member.
    public static func agent(_ log: Log, kind: Kind,
                             spawn: AgentSpawn.Member? = nil,
                             journalResult: String? = nil, now: Date) -> Agent {
        let status: Status
        if let spawn {
            status = spawn.failed ? .failed : (spawn.running ? .running : .completed)
        } else if journalResult != nil {
            status = .completed
        } else {
            let fresh = log.modifiedAt.map { now.timeIntervalSince($0) < freshWindow } ?? false
            status = (!log.endsWithAssistantText && fresh) ? .running : .completed
        }
        let title = log.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? spawn?.title.nilIfEmpty
            ?? log.agentType?.nilIfEmpty
            ?? "sub-agent"
        let text = (log.finalText ?? journalResult)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { String($0).trimmingCharacters(in: .whitespaces) }?.nilIfEmpty
        return Agent(
            id: log.id, kind: kind, title: title,
            role: log.agentType ?? spawn?.agentType, model: log.model, status: status,
            usage: log.assistantLines > 0 ? Usage(totalTokens: log.totalTokens, toolUses: log.toolUses) : nil,
            lastToolName: log.lastToolName, result: status == .failed ? nil : text,
            error: status == .failed ? text : nil,
            startedAt: log.firstAt, completedAt: status.isSettled ? log.lastAt : nil)
    }

    /// Fold the direct logs and the workflow runs into the panel. `spawns` are
    /// the chat's rows, keyed on the meta's `toolUseId` the way
    /// `attachAgents` keys them (`SessionFeed.swift:344-348`); a run's members
    /// never have one. Spawn order is stable — upstream orders by
    /// `firstSeenAt`, we by the log's first timestamp, then by id so a log
    /// without one keeps a fixed place.
    public static func panel(direct: [Log], runs: [Run] = [],
                             spawns: [AgentSpawn.Member] = [],
                             now: Date = Date()) -> Panel {
        var byToolUse: [String: AgentSpawn.Member] = [:]
        // A member's id is `e.toolCallId ?? e.id`
        // (`ThreadFeedPresentation.swift:367`): normally the bare tool_use id,
        // which `WorkEntry` already peels out of the `task:<id>[/completed]`
        // activity id (`:478-483`) — the same key an agent's meta names
        // (`SessionFeed.swift:344-348`). `spawnToolUseId` peels the fallback
        // shape too, so both join. A settled member arrives after its spawn
        // and wins the key, which is the state the chat shows.
        for member in spawns { byToolUse[spawnToolUseId(member)] = member }
        let directAgents = sorted(direct).map { log in
            agent(log, kind: .subagent, spawn: log.toolUseId.flatMap { byToolUse[$0] }, now: now)
        }
        let workflows = runs.sorted { $0.id < $1.id }.map { run in
            Workflow(id: run.id, title: run.id, members: sorted(run.logs).map { log in
                agent(log, kind: .workflowAgent, journalResult: run.journal.results[log.id], now: now)
            })
        }
        let all = directAgents + workflows.flatMap(\.members)
        return Panel(directAgents: directAgents, workflows: workflows,
                     liveCount: all.filter { $0.status == .running }.count,
                     settledCount: all.filter { $0.status.isSettled }.count,
                     totalTokens: all.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) },
                     hasAgents: !all.isEmpty, derivedAt: now)
    }

    // MARK: Reading the directory

    /// Upstream's `ROSTER_LIMIT` (`subagentRuntime.ts:109`): only the newest
    /// this many agent files are read. A long session accumulates hundreds
    /// (735 under one worktree, 2026-09-05, `SessionFeed.swift:293-296`).
    public static let rosterLimit = 100

    /// How many bytes of agent log one scan will parse. Past it a log still
    /// gets its row — from its meta, its mtime and its spawn — but with no
    /// usage, which the metadata line already renders honestly as "— tok"
    /// (`AgentsPanel.tsx:153`) rather than reporting a partial sum as the
    /// total. It is not cached, so the next pump picks it up: the frontier
    /// walks newest-first through the roster over a few pumps instead of
    /// parsing gigabytes in one.
    public static let scanByteBudget = 64 * 1024 * 1024

    static let logs = LogCache()

    /// One parsed log per path, resumed while the file only grows. Keyed on
    /// (size, mtime) the way `AgentMetaCache` is keyed on the path
    /// (`SessionFeed.swift:365-395`): a settled log parses once per process.
    final class LogCache: @unchecked Sendable {
        private struct Entry { var size: UInt64; var mtime: Date?; var offset: UInt64; var accum: Accum }
        private let lock = NSLock()
        private var stored: [String: Entry] = [:]

        /// `nil` when the file could not be read, or when `budget` (decremented
        /// by whatever this call reads) had nothing left for it.
        func log(at url: URL, id: String, meta: Meta?, budget: inout Int) -> Log? {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate
            guard let byteCount = values?.fileSize else { return nil }
            let size = UInt64(byteCount)

            lock.lock()
            let cached = stored[url.path]
            lock.unlock()
            if let cached, cached.size == size, cached.mtime == mtime {
                return T3Agents.log(id: id, accum: cached.accum, meta: meta, modifiedAt: mtime)
            }
            // A shrunk file was rewritten, not appended to — start over.
            var entry = (cached?.offset ?? 0) <= size && (cached?.size ?? 0) <= size
                ? (cached ?? Entry(size: 0, mtime: nil, offset: 0, accum: Accum()))
                : Entry(size: 0, mtime: nil, offset: 0, accum: Accum())
            // Nothing new to read (the mtime moved but the bytes did not — a
            // touch, or a rewrite to the same length): keep the fold, restamp
            // it. Never a read here: `readToEnd()` answers nil at EOF, and
            // treating that as a failure threw the whole parse away.
            if entry.offset < size {
                let pending = Int(size - entry.offset)
                guard pending <= budget else { return nil }
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: entry.offset)) != nil else { return nil }
                let blob = (try? handle.readToEnd()) ?? Data()
                budget -= blob.count
                // Only whole lines are absorbed: a half-written tail line is
                // left for the next pump by leaving the offset before it.
                var consumed = blob.count
                if let lastNewline = blob.lastIndex(of: 0x0A) {
                    consumed = blob.distance(from: blob.startIndex, to: lastNewline) + 1
                } else if !blob.isEmpty {
                    consumed = 0
                }
                entry.accum.absorb(lines: SessionFeedReader.lines(of: blob.prefix(consumed)))
                entry.offset += UInt64(consumed)
            }
            entry.size = size
            entry.mtime = mtime
            lock.lock(); stored[url.path] = entry; lock.unlock()
            return T3Agents.log(id: id, accum: entry.accum, meta: meta, modifiedAt: mtime)
        }

        /// Drops THIS session's entries whose file is gone (its agent dir
        /// cleaned up), so the cache follows the disk. Scoped by prefix the
        /// way `AgentMetaCache.keep` is (`SessionFeed.swift:387-394`): a
        /// global filter would evict every other thread's parsed logs the
        /// moment one scans, and a switch back would re-parse its whole
        /// roster.
        func keep(dir: URL, paths: Set<String>) {
            let prefix = dir.standardizedFileURL.path + "/"
            lock.lock()
            stored = stored.filter { !$0.key.hasPrefix(prefix) || paths.contains($0.key) }
            lock.unlock()
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    /// The panel for one session's `subagents/` dir. Reads files — call it off
    /// the main actor. `spawns` come from the chat's own rows
    /// (`ThreadFeedPresentation.deriveExpanded`), so a direct agent's status
    /// matches its CTA row in the timeline.
    public static func panel(subagentsDir: URL,
                             spawns: [AgentSpawn.Member] = [],
                             now: Date = Date()) -> Panel {
        let files = Transcript.agentFiles(under: subagentsDir)
        guard !files.isEmpty else { return .empty(derivedAt: now) }
        logs.keep(dir: subagentsDir, paths: Set(files.map(\.path)))
        // Newest first, so the byte budget always spends itself on the agents
        // the user is watching.
        let newest = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }.prefix(rosterLimit)

        var budget = scanByteBudget
        var direct: [Log] = []
        var runLogs: [String: [Log]] = [:]
        for file in newest {
            let name = file.lastPathComponent
            let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let dir = file.deletingLastPathComponent()
            let meta = self.meta(at: dir.appendingPathComponent("agent-\(id).meta.json"))
            let log = logs.log(at: file, id: id, meta: meta, budget: &budget)
                ?? Log(id: id, agentType: meta?.agentType, description: meta?.description,
                       toolUseId: meta?.toolUseId,
                       modifiedAt: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            if dir.standardizedFileURL.path == subagentsDir.standardizedFileURL.path {
                direct.append(log)
            } else {
                runLogs[dir.lastPathComponent, default: []].append(log)
            }
        }
        let runs = runLogs.map { runId, logs in
            Run(id: runId, logs: logs, journal: journal(at: subagentsDir
                .appendingPathComponent("workflows/\(runId)/journal.jsonl")))
        }
        return panel(direct: direct, runs: runs, spawns: spawns, now: now)
    }

    static func meta(at url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Meta(agentType: object["agentType"] as? String,
                    description: object["description"] as? String,
                    toolUseId: object["toolUseId"] as? String)
    }

    static func journal(at url: URL) -> Journal {
        guard let data = try? Data(contentsOf: url) else { return .none }
        return Journal.parse(lines: SessionFeedReader.lines(of: data))
    }

    /// The parent `tool_use` id a spawn member stands for. Already bare when
    /// the member came from a `WorkEntry.toolCallId`; peeled here for the
    /// `?? e.id` fallback, whose shape is `task:<toolUseId>[/completed]`
    /// (`SessionTimelineBuilder.swift:205,262`).
    static func spawnToolUseId(_ member: AgentSpawn.Member) -> String {
        var id = member.id
        if id.hasPrefix("task:") { id.removeFirst("task:".count) }
        if id.hasSuffix("/completed") { id.removeLast("/completed".count) }
        return id
    }

    private static func sorted(_ logs: [Log]) -> [Log] {
        logs.sorted { a, b in
            switch (a.firstAt, b.firstAt) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id < b.id
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
