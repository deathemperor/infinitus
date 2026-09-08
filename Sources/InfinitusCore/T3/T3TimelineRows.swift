import Foundation

/// Port of T3 Code's chat-timeline reducer
/// (`tools/t3ref/upstream/MessagesTimeline.logic.ts`, lines 819–1212 plus the
/// helpers above them), written top-down in the upstream order so the two files
/// diff side by side.
///
/// Not ported (each is view plumbing or JavaScript-identity memoization with no
/// value-type shape): the minimap and follow helpers, `resolveTimelineIsAtEnd`,
/// `shouldPreserveAssistantLineBreaks`, `resolveAssistantMessageCopyState`,
/// `resolveWorkGroupScrollIndex`/`shouldFollowWorkGroupAppend`, and
/// `deriveMessagesTimelineRowsWithState`/`replaceStreamingMessageRows`
/// (`stable(previous:next:)` carries their intent).
public enum T3TimelineRows {
    public static let liveActivityRowId = "live-activity-row"
    private static let workingIndicatorRowId = "working-indicator-row"

    public struct LatestTurn: Sendable, Equatable, Hashable {
        public var turnId: String
        public var state: SessionTimeline.Turn.State
        public var startedAt: Date?
        public var completedAt: Date?
        public init(turnId: String, state: SessionTimeline.Turn.State, startedAt: Date?, completedAt: Date?) {
            self.turnId = turnId; self.state = state; self.startedAt = startedAt; self.completedAt = completedAt
        }
    }

    public struct TurnDiffSummary: Sendable, Equatable, Hashable {
        public var turnId: String
        public var checkpointTurnCount: Int?
        public var assistantMessageId: String?
        public var completedAt: Date
        public var files: [String]
        public init(turnId: String, checkpointTurnCount: Int?, assistantMessageId: String?,
                    completedAt: Date, files: [String]) {
            self.turnId = turnId; self.checkpointTurnCount = checkpointTurnCount
            self.assistantMessageId = assistantMessageId; self.completedAt = completedAt; self.files = files
        }
    }

    public enum Row: Sendable, Equatable, Hashable, Identifiable {
        case work(id: String, createdAt: Date, groupedEntries: [T3WorkLogEntry], isExpandedToolGroup: Bool,
                  displayLabel: String?)
        case workLive(id: String, createdAt: Date, entry: T3WorkLogEntry, groupedEntries: [T3WorkLogEntry],
                      groupId: String, expanded: Bool, active: Bool)
        case workToggle(id: String, createdAt: Date, turnId: String?, groupId: String, hiddenCount: Int,
                        expanded: Bool, summary: String, summaryKind: T3WorkLog.SummaryKind,
                        toolSurface: String?, summaryToolIcon: T3WorkLog.ToolPresentation.Icon?,
                        hasFailure: Bool)
        case turnFold(id: String, createdAt: Date, turnId: String, label: String, expanded: Bool)
        case contextCompaction(id: String, createdAt: Date, label: String)
        case message(id: String, createdAt: Date, message: T3ChatMessage, durationStart: Date,
                     showAssistantMeta: Bool, showAssistantCopyButton: Bool, assistantCopyStreaming: Bool,
                     assistantTurnDiffSummary: TurnDiffSummary?, revertTurnCount: Int?)
        case assistantMeta(id: String, createdAt: Date, message: T3ChatMessage, showAssistantCopyButton: Bool,
                           assistantCopyStreaming: Bool)
        case proposedPlan(id: String, createdAt: Date, T3ProposedPlan)
        case working(id: String, createdAt: Date?)
        case thinking(id: String, createdAt: Date?)

        public var id: String {
            switch self {
            case let .work(id, _, _, _, _), let .workLive(id, _, _, _, _, _, _),
                 let .workToggle(id, _, _, _, _, _, _, _, _, _, _), let .turnFold(id, _, _, _, _),
                 let .contextCompaction(id, _, _), let .message(id, _, _, _, _, _, _, _, _),
                 let .assistantMeta(id, _, _, _, _), let .proposedPlan(id, _, _),
                 let .working(id, _), let .thinking(id, _):
                return id
            }
        }
        /// The upstream row-variant literal.
        public var kind: String {
            switch self {
            case .work: return "work"
            case .workLive: return "work-live"
            case .workToggle: return "work-toggle"
            case .turnFold: return "turn-fold"
            case .contextCompaction: return "context-compaction"
            case .message: return "message"
            case .assistantMeta: return "assistant-meta"
            case .proposedPlan: return "proposed-plan"
            case .working: return "working"
            case .thinking: return "thinking"
            }
        }
        public var createdAt: Date? {
            switch self {
            case let .work(_, at, _, _, _), let .workLive(_, at, _, _, _, _, _),
                 let .workToggle(_, at, _, _, _, _, _, _, _, _, _), let .turnFold(_, at, _, _, _),
                 let .contextCompaction(_, at, _), let .message(_, at, _, _, _, _, _, _, _),
                 let .assistantMeta(_, at, _, _, _), let .proposedPlan(_, at, _):
                return at
            case let .working(_, at), let .thinking(_, at):
                return at
            }
        }
    }

    public struct Input: Sendable {
        public var entries: [T3TimelineEntry]
        public var latestTurn: LatestTurn?
        public var runningTurnId: String?
        public var expandedTurnIds: Set<String>
        public var expandedWorkGroupIds: Set<String>
        public var isWorking: Bool
        public var activeTurnStartedAt: Date?
        public var turnDiffSummaries: [TurnDiffSummary]
        public var supportsConversationRollback: Bool

        public init(entries: [T3TimelineEntry], latestTurn: LatestTurn? = nil, runningTurnId: String? = nil,
                    expandedTurnIds: Set<String> = [], expandedWorkGroupIds: Set<String> = [],
                    isWorking: Bool, activeTurnStartedAt: Date?, turnDiffSummaries: [TurnDiffSummary] = [],
                    supportsConversationRollback: Bool = false) {
            self.entries = entries; self.latestTurn = latestTurn; self.runningTurnId = runningTurnId
            self.expandedTurnIds = expandedTurnIds; self.expandedWorkGroupIds = expandedWorkGroupIds
            self.isWorking = isWorking; self.activeTurnStartedAt = activeTurnStartedAt
            self.turnDiffSummaries = turnDiffSummaries
            self.supportsConversationRollback = supportsConversationRollback
        }
    }

    // MARK: - Timing helpers

    private static func elapsed(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return Swift.max(0, end.timeIntervalSince(start))
    }

    private static func maxTimestamp(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return b > a ? b : a
    }

    // MARK: - computeMessageDurationStart

    public static func messageDurationStart(_ messages: [T3ChatMessage]) -> [String: Date] {
        var result: [String: Date] = [:]
        var lastBoundary: Date?
        for message in messages {
            if message.role == .user { lastBoundary = message.createdAt }
            result[message.id] = lastBoundary ?? message.createdAt
            if message.role == .assistant && !message.streaming { lastBoundary = message.updatedAt }
        }
        return result
    }

    // MARK: - Work group identity

    private static func workGroupIdentity(_ timelineEntryId: String, _ entry: T3WorkLogEntry) -> String {
        guard let toolCallId = entry.toolCallId else { return timelineEntryId }
        return "tool:\(entry.turnId ?? "no-turn"):\(toolCallId)"
    }

    private static func workGroupId(_ timelineEntryId: String, _ entry: T3WorkLogEntry) -> String {
        "work-group:\(workGroupIdentity(timelineEntryId, entry))"
    }

    private static func expandedWorkGroupRow(_ groupId: String, _ createdAt: Date,
                                             _ groupedEntries: [T3WorkLogEntry]) -> Row {
        .work(id: "\(groupId):details", createdAt: createdAt, groupedEntries: groupedEntries,
              isExpandedToolGroup: true, displayLabel: nil)
    }

    // MARK: - Turn helpers

    private static func terminalAssistantMessageIds(_ entries: [T3TimelineEntry]) -> Set<String> {
        var lastByResponseKey: [String: String] = [:]
        var order: [String] = []
        var nullTurnResponseIndex = 0
        for entry in entries {
            guard case let .message(_, _, message) = entry else { continue }
            if message.role == .user { nullTurnResponseIndex += 1; continue }
            if message.role != .assistant { continue }
            let key = message.turnId.map { "turn:\($0)" } ?? "unkeyed:\(nullTurnResponseIndex)"
            if lastByResponseKey.updateValue(message.id, forKey: key) == nil { order.append(key) }
        }
        return Set(order.compactMap { lastByResponseKey[$0] })
    }

    /// The session's running turn is authoritative when `latestTurn` briefly
    /// lags or regresses behind it. Otherwise the latest turn counts as
    /// unsettled while it is still running (or has not recorded a completion).
    private static func unsettledTurnId(_ latestTurn: LatestTurn?, _ runningTurnId: String?) -> String? {
        if let runningTurnId { return runningTurnId }
        guard let latestTurn else { return nil }
        let isSettled = latestTurn.completedAt != nil && latestTurn.state != .running
        return isSettled ? nil : latestTurn.turnId
    }

    private static func lastUserMessageIndex(_ entries: [T3TimelineEntry]) -> Int {
        entries.lastIndex { entry in
            if case let .message(_, _, message) = entry { return message.role == .user }
            return false
        } ?? -1
    }

    /// A promptless provider restart replaces the native turn without adding a
    /// user message. Keep every provider turn since the latest user message in
    /// one visual response until the replacement turn settles.
    private static func activeVisualResponseTurnIds(entries: [T3TimelineEntry], unsettledTurnId: String?,
                                                    isWorking: Bool) -> Set<String> {
        guard let unsettledTurnId else { return [] }
        var turnIds: Set<String> = [unsettledTurnId]
        guard isWorking else { return turnIds }
        let latestUserMessageIndex = lastUserMessageIndex(entries)
        var index = latestUserMessageIndex + 1
        while index < entries.count {
            if let turnId = entries[index].turnId { turnIds.insert(turnId) }
            index += 1
        }
        return turnIds
    }

    private static func isActiveTurnActivity(_ entry: T3WorkLogEntry) -> Bool {
        entry.toolLifecycleStatus == .inProgress
            || (entry.toolLifecycleStatus == nil
                && (entry.sourceActivityKind == "task.progress" || T3WorkLog.isToolLike(entry)))
    }

    // MARK: - deriveTurnFolds

    private struct TurnFold {
        let turnId: String
        let anchorEntryId: String
        let createdAt: Date
        let hiddenEntryIds: Set<String>
        let label: String
    }

    /// Settled turns fold activity before their terminal assistant message
    /// behind a "Worked for …" row. A single ordinary activity after that
    /// message joins the fold, while larger groups and failures stay visible as
    /// a trailing summary.
    private static func turnFolds(entries: [T3TimelineEntry], terminalAssistantMessageIds: Set<String>,
                                  latestTurn: LatestTurn?, unfoldedTurnIds: Set<String>) -> [String: TurnFold] {
        struct TurnGroup {
            var entries: [T3TimelineEntry] = []
            var terminalEntry: T3TimelineEntry?
            var hasStreamingMessage = false
            /// The user message that kicked the turn off — entry timestamps
            /// alone undercount the duration.
            var startBoundary: Date?
        }
        var groupOrder: [String] = []
        var groupsByTurnId: [String: TurnGroup] = [:]
        var pendingUserBoundary: Date?

        for entry in entries {
            if case let .message(_, _, message) = entry, message.role == .user {
                pendingUserBoundary = message.createdAt
                continue
            }
            let turnId: String?
            switch entry {
            case let .message(_, _, message): turnId = message.role == .assistant ? message.turnId : nil
            case let .work(_, _, work): turnId = work.turnId
            case .proposedPlan: turnId = nil
            }
            guard let turnId, !turnId.isEmpty else { continue }
            if groupsByTurnId[turnId] == nil {
                // Each user boundary starts at most one turn.
                groupsByTurnId[turnId] = TurnGroup(startBoundary: pendingUserBoundary)
                groupOrder.append(turnId)
                pendingUserBoundary = nil
            }
            groupsByTurnId[turnId]?.entries.append(entry)
            if case let .message(_, _, message) = entry {
                if terminalAssistantMessageIds.contains(message.id) {
                    groupsByTurnId[turnId]?.terminalEntry = entry
                }
                if message.streaming { groupsByTurnId[turnId]?.hasStreamingMessage = true }
            }
        }

        var foldsByAnchorEntryId: [String: TurnFold] = [:]
        for turnId in groupOrder {
            guard let group = groupsByTurnId[turnId] else { continue }
            if unfoldedTurnIds.contains(turnId) { continue }
            if group.hasStreamingMessage { continue }

            var hiddenEntryIds = Set<String>()
            let terminalEntryIndex = group.terminalEntry
                .flatMap { terminal in group.entries.firstIndex { $0.id == terminal.id } }
                ?? group.entries.count
            for (index, entry) in group.entries.enumerated() {
                if entry.id == group.terminalEntry?.id { continue }
                var isCompaction = false
                var isTrailingWork = false
                var isAgentSpawn = false
                if case let .work(_, _, work) = entry {
                    isCompaction = work.sourceActivityKind == "context-compaction"
                    isTrailingWork = !T3WorkLog.displayIndicatesFailure(work)
                    isAgentSpawn = work.isAgentSpawn
                }
                let isSingleTrailingActivity = group.entries.count == terminalEntryIndex + 2 && isTrailingWork
                if !isCompaction && index > terminalEntryIndex && !isSingleTrailingActivity { continue }
                // Agent-spawn CTA rows never fold: workflows outlive their
                // launching turn.
                if isAgentSpawn { continue }
                hiddenEntryIds.insert(entry.id)
            }
            if hiddenEntryIds.isEmpty { continue }
            // A lone compaction row stays visible on its own.
            let hidesNonCompactionWork = group.entries.contains { entry in
                guard hiddenEntryIds.contains(entry.id) else { return false }
                if case let .work(_, _, work) = entry { return work.sourceActivityKind != "context-compaction" }
                return true
            }
            if !hidesNonCompactionWork { continue }

            guard let firstEntry = group.entries.first,
                  let firstHiddenEntry = group.entries.first(where: { hiddenEntryIds.contains($0.id) }),
                  let lastEntry = group.entries.last else { continue }

            let isLatestInterruptedTurn = latestTurn?.turnId == turnId && latestTurn?.state == .interrupted
            // A turn cut short by a steer leaves trailing work entries behind
            // its terminal message — take whichever ended last.
            let lastEntryEnd: Date
            if case let .message(_, _, message) = lastEntry { lastEntryEnd = message.updatedAt }
            else { lastEntryEnd = lastEntry.createdAt }
            let terminalUpdatedAt: Date?
            if case let .message(_, _, message)? = group.terminalEntry { terminalUpdatedAt = message.updatedAt }
            else { terminalUpdatedAt = nil }
            let elapsedInterval: TimeInterval?
            if latestTurn?.turnId == turnId, let startedAt = latestTurn?.startedAt,
               let completedAt = latestTurn?.completedAt {
                elapsedInterval = elapsed(startedAt, completedAt)
            } else {
                elapsedInterval = elapsed(group.startBoundary ?? firstEntry.createdAt,
                                          maxTimestamp(terminalUpdatedAt, lastEntryEnd) ?? lastEntryEnd)
            }
            let duration = elapsedInterval.map(T3WorkLog.formatDuration)
            let label: String
            if isLatestInterruptedTurn {
                label = duration.map { "You stopped after \($0)" } ?? "You stopped this response"
            } else {
                label = duration.map { "Worked for \($0)" } ?? "Worked"
            }
            foldsByAnchorEntryId[firstHiddenEntry.id] = TurnFold(
                turnId: turnId, anchorEntryId: firstHiddenEntry.id, createdAt: firstHiddenEntry.createdAt,
                hiddenEntryIds: hiddenEntryIds, label: label)
        }
        return foldsByAnchorEntryId
    }

    // MARK: - attachTrailingToolGroupsToAssistant

    /// When a settled turn ends with tool calls after its terminal text, treat
    /// the text and tools as one visual response: the message metadata becomes
    /// the footer for the whole block.
    private static func attachTrailingToolGroupsToAssistant(_ rows: [Row]) -> [Row] {
        var messageRowsWithoutMeta = Set<String>()
        var metaRowsAfterIndex: [Int: Row] = [:]

        for (messageIndex, row) in rows.enumerated() {
            guard case let .message(_, _, message, _, showAssistantMeta, showCopy, copyStreaming, _, _) = row,
                  message.role == .assistant, showAssistantMeta, let turnId = message.turnId else { continue }

            var lastTrailingWorkIndex = -1
            var hasTrailingToolGroup = false
            var index = messageIndex + 1
            while index < rows.count {
                let candidate = rows[index]
                if case .message = candidate { break }
                if case let .workToggle(_, _, candidateTurnId, _, _, _, _, _, _, _, _) = candidate,
                   candidateTurnId == turnId {
                    hasTrailingToolGroup = true
                    lastTrailingWorkIndex = index
                    index += 1
                    continue
                }
                if case let .work(_, _, groupedEntries, isExpandedToolGroup, _) = candidate,
                   groupedEntries.contains(where: { $0.turnId == turnId }) {
                    if !isExpandedToolGroup && groupedEntries.contains(where: T3WorkLog.isToolLike) {
                        hasTrailingToolGroup = true
                    }
                    if hasTrailingToolGroup { lastTrailingWorkIndex = index }
                }
                index += 1
            }
            if lastTrailingWorkIndex < 0 { continue }

            messageRowsWithoutMeta.insert(row.id)
            metaRowsAfterIndex[lastTrailingWorkIndex] = .assistantMeta(
                id: "assistant-meta:\(message.id)",
                createdAt: rows[lastTrailingWorkIndex].createdAt ?? message.updatedAt,
                message: message, showAssistantCopyButton: showCopy, assistantCopyStreaming: copyStreaming)
        }

        var result: [Row] = []
        for (index, row) in rows.enumerated() {
            if case let .message(id, createdAt, message, durationStart, _, _, copyStreaming, diff, revert) = row,
               messageRowsWithoutMeta.contains(row.id) {
                result.append(.message(id: id, createdAt: createdAt, message: message,
                                       durationStart: durationStart, showAssistantMeta: false,
                                       showAssistantCopyButton: false, assistantCopyStreaming: copyStreaming,
                                       assistantTurnDiffSummary: diff, revertTurnCount: revert))
            } else {
                result.append(row)
            }
            if let metaRow = metaRowsAfterIndex[index] { result.append(metaRow) }
        }
        return result
    }

    // MARK: - Checkpoints and revert counts

    /// `session-logic.ts` `inferCheckpointTurnCountByTurnId`.
    private static func inferCheckpointTurnCountByTurnId(_ summaries: [TurnDiffSummary]) -> [String: Int] {
        let sorted = summaries.enumerated()
            .sorted { l, r in
                l.element.completedAt == r.element.completedAt
                    ? l.offset < r.offset
                    : l.element.completedAt < r.element.completedAt
            }
            .map(\.element)
        var result: [String: Int] = [:]
        for (index, summary) in sorted.enumerated() { result[summary.turnId] = index + 1 }
        return result
    }

    /// Match each user message to the next assistant checkpoint.
    private static func revertTurnCountByUserMessageId(
        supportsConversationRollback: Bool, entries: [T3TimelineEntry],
        turnDiffSummaryByAssistantMessageId: [String: TurnDiffSummary],
        inferredCheckpointTurnCountByTurnId: [String: Int]) -> [String: Int] {
        var byUserMessageId: [String: Int] = [:]
        let entryCount = supportsConversationRollback ? entries.count : 0
        var index = 0
        while index < entryCount {
            guard case let .message(_, _, message) = entries[index], message.role == .user else {
                index += 1
                continue
            }
            var nextIndex = index + 1
            while nextIndex < entries.count {
                guard case let .message(_, _, next) = entries[nextIndex] else { nextIndex += 1; continue }
                if next.role == .user { break }
                guard let summary = turnDiffSummaryByAssistantMessageId[next.id] else { nextIndex += 1; continue }
                guard let turnCount = summary.checkpointTurnCount
                        ?? inferredCheckpointTurnCountByTurnId[summary.turnId] else { break }
                byUserMessageId[message.id] = Swift.max(0, turnCount - 1)
                break
            }
            index += 1
        }
        return byUserMessageId
    }

    // MARK: - deriveMessagesTimelineRows

    public static func derive(_ input: Input) -> [Row] {
        var turnDiffSummaryByAssistantMessageId: [String: TurnDiffSummary] = [:]
        for summary in input.turnDiffSummaries {
            if let id = summary.assistantMessageId { turnDiffSummaryByAssistantMessageId[id] = summary }
        }
        let revertTurnCounts = revertTurnCountByUserMessageId(
            supportsConversationRollback: input.supportsConversationRollback,
            entries: input.entries,
            turnDiffSummaryByAssistantMessageId: turnDiffSummaryByAssistantMessageId,
            inferredCheckpointTurnCountByTurnId: input.supportsConversationRollback
                ? inferCheckpointTurnCountByTurnId(input.turnDiffSummaries) : [:])

        var nextRows: [Row] = []
        let durationStartByMessageId = messageDurationStart(input.entries.compactMap { entry in
            if case let .message(_, _, message) = entry { return message } else { return nil }
        })
        let terminalIds = terminalAssistantMessageIds(input.entries)
        let unsettled = unsettledTurnId(input.latestTurn, input.runningTurnId)
        let activeVisualTurnIds = activeVisualResponseTurnIds(entries: input.entries, unsettledTurnId: unsettled,
                                                              isWorking: input.isWorking)
        let foldsByAnchorEntryId = turnFolds(entries: input.entries, terminalAssistantMessageIds: terminalIds,
                                             latestTurn: input.latestTurn, unfoldedTurnIds: activeVisualTurnIds)
        var collapsedEntryIds = Set<String>()
        for fold in foldsByAnchorEntryId.values where !input.expandedTurnIds.contains(fold.turnId) {
            collapsedEntryIds.formUnion(fold.hiddenEntryIds)
        }

        var activeTurnHeaderIndex = input.entries.count
        if input.isWorking { activeTurnHeaderIndex = lastUserMessageIndex(input.entries) + 1 }

        func entryBelongsToActiveTurn(_ entry: T3TimelineEntry, _ index: Int) -> Bool {
            input.isWorking && index >= activeTurnHeaderIndex
                && (unsettled == nil || entry.turnId == unsettled)
        }
        func workEntryIsInActiveRun(_ entry: T3WorkLogEntry) -> Bool {
            input.isWorking && unsettled != nil && entry.toolLifecycleStatus == .inProgress
                && entry.turnId == unsettled
        }

        typealias WorkRef = (id: String, createdAt: Date, entry: T3WorkLogEntry)
        var activeToolEntries: [WorkRef] = []
        var scan = input.entries.count - 1
        while scan >= activeTurnHeaderIndex {
            let entry = input.entries[scan]
            guard entryBelongsToActiveTurn(entry, scan), case let .work(id, createdAt, work) = entry,
                  !work.isAgentSpawn, work.sourceActivityKind != "context-compaction", work.tone != .error
            else { break }
            activeToolEntries.insert((id, createdAt, work), at: 0)
            scan -= 1
        }

        let visibleActiveToolEntries = T3WorkLog.omitSupersededLifecycleMarkers(
            activeToolEntries.filter { T3WorkLog.isVisibleInGroup($0.entry, expandedToolGroupEntry: true) }
        ) { $0.entry }
        let activeWorkAnchor = activeToolEntries.first
        let latestVisibleToolEntry = visibleActiveToolEntries.last
        let latestRunningToolEntry = visibleActiveToolEntries.last { isActiveTurnActivity($0.entry) }
        let latestToolFailed = latestRunningToolEntry == nil
            && latestVisibleToolEntry.map { latest in
                latest.entry.toolLifecycleStatus != .declined
                    && T3WorkLog.displayIndicatesFailure(latest.entry)
            } ?? false
        let latestToolKeepsActivityLive = latestRunningToolEntry != nil
            || (latestVisibleToolEntry.map { T3WorkLog.indicatesSuccess($0.entry) } ?? false)
        let activeWorkPlacementEntryId = latestVisibleToolEntry?.id

        var activeWorkRow: Row?
        var activeWorkRowGroupId: String?
        var activeWorkRowExpanded = false
        var activeWorkRowActive = false
        var activeWorkRowCreatedAt: Date?
        var activeWorkRowGroupedEntries: [T3WorkLogEntry] = []
        if let anchor = activeWorkAnchor, let latest = latestVisibleToolEntry, !latestToolFailed {
            let groupId = workGroupId(anchor.id, anchor.entry)
            let expanded = input.expandedWorkGroupIds.contains(groupId)
            let grouped = visibleActiveToolEntries.map(\.entry)
            activeWorkRow = .workLive(
                id: latestToolKeepsActivityLive
                    ? liveActivityRowId
                    : "work-live:\(workGroupIdentity(anchor.id, anchor.entry))",
                createdAt: anchor.createdAt,
                entry: (latestRunningToolEntry ?? latest).entry,
                groupedEntries: grouped, groupId: groupId, expanded: expanded,
                active: latestToolKeepsActivityLive)
            activeWorkRowGroupId = groupId
            activeWorkRowExpanded = expanded
            activeWorkRowActive = latestToolKeepsActivityLive
            activeWorkRowCreatedAt = anchor.createdAt
            activeWorkRowGroupedEntries = grouped
        }
        let activeWorkEntryIds = Set(activeWorkRow != nil || latestToolFailed
                                     ? activeToolEntries.map(\.id) : [])

        var hasActivityRow = false
        func appendWorkingRow() {
            let latestUserIndex = lastUserMessageIndex(input.entries)
            var visualResponseStartedAt = input.activeTurnStartedAt
            if activeVisualTurnIds.count > 1, latestUserIndex >= 0,
               case let .message(_, _, message) = input.entries[latestUserIndex], message.role == .user {
                visualResponseStartedAt = message.createdAt
            }
            nextRows.append(.working(id: workingIndicatorRowId, createdAt: visualResponseStartedAt))
        }
        func appendActiveWorkRows() {
            guard let row = activeWorkRow else { return }
            nextRows.append(row)
            hasActivityRow = hasActivityRow || activeWorkRowActive
            guard activeWorkRowExpanded, let groupId = activeWorkRowGroupId,
                  let createdAt = activeWorkRowCreatedAt else { return }
            nextRows.append(expandedWorkGroupRow(groupId, createdAt, activeWorkRowGroupedEntries))
        }

        var index = 0
        while index < input.entries.count {
            var nextIndex = index + 1
            defer { index = nextIndex }
            let timelineEntry = input.entries[index]

            if input.isWorking && index == activeTurnHeaderIndex { appendWorkingRow() }
            if timelineEntry.id == activeWorkPlacementEntryId { appendActiveWorkRows() }

            if let fold = foldsByAnchorEntryId[timelineEntry.id] {
                nextRows.append(.turnFold(id: "turn-fold:\(fold.turnId)", createdAt: fold.createdAt,
                                          turnId: fold.turnId, label: fold.label,
                                          expanded: input.expandedTurnIds.contains(fold.turnId)))
            }
            if collapsedEntryIds.contains(timelineEntry.id) { continue }
            if activeWorkEntryIds.contains(timelineEntry.id) { continue }

            if case let .work(entryId, createdAt, work) = timelineEntry,
               work.sourceActivityKind == "context-compaction" {
                nextRows.append(.contextCompaction(id: entryId, createdAt: createdAt, label: work.label))
                continue
            }

            if case let .work(entryId, createdAt, work) = timelineEntry {
                if work.isAgentSpawn || work.tone == .error {
                    nextRows.append(.work(id: entryId, createdAt: createdAt, groupedEntries: [work],
                                          isExpandedToolGroup: false, displayLabel: nil))
                    continue
                }
                var groupedEntries = [work]
                var cursor = index + 1
                while cursor < input.entries.count {
                    guard case let .work(nextId, _, nextWork) = input.entries[cursor],
                          !nextWork.isAgentSpawn, nextWork.sourceActivityKind != "context-compaction",
                          nextWork.tone != .error, !activeWorkEntryIds.contains(nextId),
                          !collapsedEntryIds.contains(nextId), foldsByAnchorEntryId[nextId] == nil
                    else { break }
                    groupedEntries.append(nextWork)
                    cursor += 1
                }
                let visibleGroupedEntries = T3WorkLog.omitSupersededLifecycleMarkers(
                    groupedEntries.filter {
                        T3WorkLog.isVisibleInGroup($0, expandedToolGroupEntry: workEntryIsInActiveRun($0))
                    }) { $0 }
                if !visibleGroupedEntries.isEmpty {
                    let activeInProgress = visibleGroupedEntries.filter(workEntryIsInActiveRun)
                    if let latestActive = activeInProgress.last {
                        let groupId = workGroupId(entryId, work)
                        let expanded = input.expandedWorkGroupIds.contains(groupId)
                        nextRows.append(.workLive(id: "work-live:\(workGroupIdentity(entryId, work))",
                                                  createdAt: createdAt, entry: latestActive,
                                                  groupedEntries: visibleGroupedEntries, groupId: groupId,
                                                  expanded: expanded, active: true))
                        hasActivityRow = true
                        if expanded {
                            nextRows.append(expandedWorkGroupRow(groupId, createdAt, visibleGroupedEntries))
                        }
                    } else if visibleGroupedEntries.count == 1,
                              let singleEntry = visibleGroupedEntries.first,
                              T3WorkLog.isToolLike(singleEntry) {
                        nextRows.append(.work(
                            id: entryId, createdAt: createdAt, groupedEntries: visibleGroupedEntries,
                            isExpandedToolGroup: false,
                            displayLabel: T3WorkLog.groupAction(singleEntry) == .edit
                                ? T3WorkLog.summarizeGroup(visibleGroupedEntries)
                                : T3WorkLog.singleToolCallLabel(singleEntry)))
                    } else {
                        let groupId = workGroupId(entryId, work)
                        let expanded = input.expandedWorkGroupIds.contains(groupId)
                        let summaryKind = T3WorkLog.summaryKind(visibleGroupedEntries)
                        let primarySourceEntry = visibleGroupedEntries.first { $0.toolSource != nil }
                        let groupToolSurface = primarySourceEntry?.toolSurface
                            ?? visibleGroupedEntries.last { $0.toolSurface != nil }?.toolSurface
                        let latestToolEntry = visibleGroupedEntries.last(where: T3WorkLog.isToolLike)
                        let singleEntry = visibleGroupedEntries.count == 1 ? visibleGroupedEntries.first : nil
                        let usesSingleToolCallLabel = singleEntry.map {
                            T3WorkLog.isToolLike($0) && T3WorkLog.groupAction($0) != .edit
                        } ?? false
                        let summaryToolIcon = usesSingleToolCallLabel
                            ? singleEntry.flatMap { T3WorkLog.toolPresentation($0, fallback: .completed)?.icon }
                            : nil
                        let summary: String
                        if usesSingleToolCallLabel, let singleEntry {
                            summary = T3WorkLog.singleToolCallLabel(singleEntry)
                        } else if let singleEntry, !T3WorkLog.isToolLike(singleEntry) {
                            summary = singleEntry.label
                        } else {
                            summary = T3WorkLog.summarizeGroup(visibleGroupedEntries)
                        }
                        nextRows.append(.workToggle(
                            id: "work-toggle:\(entryId)", createdAt: createdAt, turnId: work.turnId,
                            groupId: groupId, hiddenCount: visibleGroupedEntries.count, expanded: expanded,
                            summary: summary, summaryKind: summaryKind, toolSurface: groupToolSurface,
                            summaryToolIcon: summaryToolIcon,
                            hasFailure: latestToolEntry.map(T3WorkLog.displayIndicatesFailure) ?? false))
                        if expanded {
                            nextRows.append(expandedWorkGroupRow(groupId, createdAt, visibleGroupedEntries))
                        }
                    }
                }
                nextIndex = cursor
                continue
            }

            if case let .proposedPlan(entryId, createdAt, plan) = timelineEntry {
                nextRows.append(.proposedPlan(id: entryId, createdAt: createdAt, plan))
                continue
            }

            guard case let .message(entryId, createdAt, message) = timelineEntry else { continue }
            let assistantResponseStillInProgress = message.role == .assistant
                && message.turnId.map(activeVisualTurnIds.contains) ?? false
            let durationStart = durationStartByMessageId[message.id] ?? message.createdAt
            // While the turn is still running, the latest assistant message is
            // only provisionally terminal — withhold the metadata row.
            let showAssistantMeta = message.role == .assistant && terminalIds.contains(message.id)
                && !assistantResponseStillInProgress
            nextRows.append(.message(
                id: entryId, createdAt: createdAt, message: message, durationStart: durationStart,
                showAssistantMeta: showAssistantMeta, showAssistantCopyButton: showAssistantMeta,
                assistantCopyStreaming: message.streaming || assistantResponseStillInProgress,
                assistantTurnDiffSummary: message.role == .assistant
                    ? turnDiffSummaryByAssistantMessageId[message.id] : nil,
                revertTurnCount: message.role == .user ? revertTurnCounts[message.id] : nil))
        }

        if input.isWorking && activeTurnHeaderIndex == input.entries.count { appendWorkingRow() }
        if input.isWorking && (!hasActivityRow || latestToolFailed) {
            nextRows.append(.thinking(id: liveActivityRowId, createdAt: input.activeTurnStartedAt))
        }
        return attachTrailingToolGroupsToAssistant(nextRows)
    }

    // MARK: - computeStableMessagesTimelineRows

    /// Reuse the previous `Row` value when nothing the view reads changed, so a
    /// SwiftUI `List`/`ForEach` diff stays quiet across polls.
    public static func stable(previous: [Row], next: [Row]) -> [Row] {
        guard !previous.isEmpty else { return next }
        var byId: [String: Row] = [:]
        byId.reserveCapacity(previous.count)
        for row in previous { byId[row.id] = row }
        return next.map { row in
            if let prev = byId[row.id], isRowUnchanged(prev, row) { return prev }
            return row
        }
    }

    /// Shallow field comparison per row variant. Fields a row derives from
    /// another field it already compares are skipped so an equivalent
    /// re-derivation still hits the cache: `createdAt` on `work`, `message` and
    /// `proposed-plan`, `turnId` on `turn-fold` (both live in the row id or in
    /// the compared payload), and `summaryToolIcon` on `work-toggle`.
    private static func isRowUnchanged(_ a: Row, _ b: Row) -> Bool {
        guard a.kind == b.kind, a.id == b.id else { return false }
        switch (a, b) {
        case let (.working(_, x), .working(_, y)), let (.thinking(_, x), .thinking(_, y)):
            return x == y
        case let (.assistantMeta(_, xAt, xM, xCopy, xStream), .assistantMeta(_, yAt, yM, yCopy, yStream)):
            return xAt == yAt && xM == yM && xCopy == yCopy && xStream == yStream
        case let (.turnFold(_, xAt, _, xLabel, xExpanded), .turnFold(_, yAt, _, yLabel, yExpanded)):
            return xAt == yAt && xLabel == yLabel && xExpanded == yExpanded
        case let (.contextCompaction(_, xAt, xLabel), .contextCompaction(_, yAt, yLabel)):
            return xAt == yAt && xLabel == yLabel
        case let (.proposedPlan(_, _, x), .proposedPlan(_, _, y)):
            return x == y
        case let (.work(_, _, xEntries, xExpanded, xLabel), .work(_, _, yEntries, yExpanded, yLabel)):
            return xExpanded == yExpanded && xLabel == yLabel && xEntries == yEntries
        case let (.workLive(_, xAt, xEntry, xEntries, xGroup, xExpanded, xActive),
                  .workLive(_, yAt, yEntry, yEntries, yGroup, yExpanded, yActive)):
            return xAt == yAt && xGroup == yGroup && xExpanded == yExpanded && xActive == yActive
                && xEntry == yEntry && xEntries == yEntries
        case let (.workToggle(_, xAt, xTurn, xGroup, xHidden, xExpanded, xSummary, xKind, xSurface, _, xFailure),
                  .workToggle(_, yAt, yTurn, yGroup, yHidden, yExpanded, ySummary, yKind, ySurface, _, yFailure)):
            return xAt == yAt && xTurn == yTurn && xGroup == yGroup && xHidden == yHidden
                && xExpanded == yExpanded && xSummary == ySummary && xKind == yKind && xSurface == ySurface
                && xFailure == yFailure
        case let (.message(_, _, xM, xStart, xMeta, xCopy, xStream, xDiff, xRevert),
                  .message(_, _, yM, yStart, yMeta, yCopy, yStream, yDiff, yRevert)):
            return xM == yM && xStart == yStart && xMeta == yMeta && xCopy == yCopy && xStream == yStream
                && xDiff == yDiff && xRevert == yRevert
        default:
            return false
        }
    }
}
