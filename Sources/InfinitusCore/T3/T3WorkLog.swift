import Foundation

/// Line-for-line port of T3 Code's work-log presentation rules
/// (`tools/t3ref/upstream/work-log-presentation.ts`), plus the label helpers
/// `MessagesTimeline.logic.ts` keeps beside them (`singleToolCallLabel`,
/// `workEntryDisplayLabel`, `liveWorkEntryLabel`, `workEntryIsVisibleInGroup`),
/// `session-logic.ts`'s `workEntryIndicatesToolNeutralStatus` /
/// `truncateInlinePreview` / `summarizeToolTextOutput`,
/// `orchestrationTiming.ts`'s `formatDuration`, `filePathDisplay.ts`'s
/// `formatWorkspaceRelativePath` (POSIX half) and `commandLabel.ts`'s
/// `commandProgramName` (POSIX half).
///
/// Not ported (each reads a raw provider payload or a module the host never
/// forwards): `extractCommandOutputText`, `commandDetailRepeatsCommand`,
/// `workEntryViewedImagePath`, `resolveViewedImageAsset`,
/// `isWorktreeSetupActivity`, `extractWorkLogToolLifecycleStatus` (its job is
/// done by `T3WorkLogEntry(activity:)`).
public enum T3WorkLog {
    public enum GroupAction: String, Sendable, Hashable {
        case read, edit, command, browser
        case codeSearch = "code-search"
        case search, other, update
    }
    public enum SummaryKind: String, Sendable, Hashable {
        case read, edit, command, browser
        case codeSearch = "code-search"
        case search, other, update
        case dynamicTool = "dynamic-tool"
        case agentTool = "agent-tool"
        case toneTool = "tone-tool"
        case mixed
    }
    public struct ToolPresentation: Sendable, Equatable, Hashable {
        public enum Icon: String, Sendable, Hashable { case browser, t3Code = "t3-code" }
        public let displayName: String
        public let icon: Icon
    }

    // MARK: - Labels

    private static let compactSuffix = regex("\\s+(?:complete|completed)\\s*$", caseInsensitive: true)

    public static func normalizeCompactToolLabel(_ value: String) -> String {
        replacing(value, compactSuffix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `T3_MCP_TOOL_LABELS` — (action, running, completed, detail), verbatim.
    private static let mcpToolLabels: [String: (String, String, String, String)] = [
        "orchestrator_capabilities": ("Get", "Getting", "Got", "orchestration capabilities"),
        "delegate_task": ("Delegate", "Delegating", "Delegated", "a child task"),
        "task_status": ("Get", "Getting", "Got", "delegated task status"),
        "task_cancel": ("Cancel", "Canceling", "Canceled", "delegated task"),
        "schedule_task": ("Schedule", "Scheduling", "Scheduled", "a recurring task"),
        "list_scheduled_tasks": ("List", "Listing", "Listed", "scheduled tasks"),
        "update_scheduled_task": ("Update", "Updating", "Updated", "a scheduled task"),
        "delete_scheduled_task": ("Delete", "Deleting", "Deleted", "a scheduled task"),
        "create_threads": ("Create", "Creating", "Created", "T3 threads"),
        "t3_thread_start": ("Start", "Starting", "Started", "a T3 thread"),
        "t3_thread_list": ("List", "Listing", "Listed", "T3 threads"),
        "t3_thread_read": ("Read", "Reading", "Read", "a T3 thread"),
        "t3_thread_send": ("Send", "Sending", "Sent", "to a T3 thread"),
        "t3_thread_wait": ("Wait", "Waiting", "Waited", "for a T3 thread"),
        "t3_thread_interrupt": ("Interrupt", "Interrupting", "Interrupted", "a T3 thread"),
        "t3_worktree_handoff": ("Hand off", "Handing off", "Handed off", "thread to a git worktree"),
        "t3_worktree_status": ("Get", "Getting", "Got", "thread worktree status"),
        "preview_status": ("Get", "Getting", "Got", "preview browser status"),
        "preview_open": ("Open", "Opening", "Opened", "a page in the preview browser"),
        "preview_navigate": ("Navigate", "Navigating", "Navigated", "the preview browser"),
        "preview_snapshot": ("Take a snapshot of", "Taking a snapshot of", "Took a snapshot of", "the preview page"),
        "preview_click": ("Click", "Clicking", "Clicked", "in the preview browser"),
        "preview_press": ("Press", "Pressing", "Pressed", "a key in the preview browser"),
        "preview_type": ("Type", "Typing", "Typed", "in the preview browser"),
        "preview_scroll": ("Scroll", "Scrolling", "Scrolled", "the preview browser"),
        "preview_resize": ("Resize", "Resizing", "Resized", "the preview browser"),
        "preview_evaluate": ("Evaluate", "Evaluating", "Evaluated", "script in the preview browser"),
        "preview_wait_for": ("Wait", "Waiting", "Waited", "for the preview page"),
        "preview_set_appearance": ("Set", "Setting", "Set", "preview browser appearance"),
        "preview_recording_start": ("Start", "Starting", "Started", "recording the preview browser"),
        "preview_recording_stop": ("Stop", "Stopping", "Stopped", "recording the preview browser"),
    ]

    private static let mcpPrefix = regex(
        "^(?:mcp__(?:t3-code|t3_code|t3code)__|(?:t3-code|t3_code|t3code)(?:[.:/]|\\s*·\\s*))",
        caseInsensitive: true)

    private static func t3McpToolPresentation(_ value: String?,
                                              _ status: T3WorkLogEntry.LifecycleStatus?) -> ToolPresentation? {
        guard let value else { return nil }
        let name = replacing(normalizeCompactToolLabel(value), mcpPrefix, with: "")
        guard let (action, running, completed, detail) = mcpToolLabels[name] else { return nil }
        let verb: String
        switch status {
        case .inProgress: verb = running
        case .completed: verb = completed
        case .failed: verb = "Failed to \(action.lowercased())"
        case .declined: verb = "Declined to \(action.lowercased())"
        case .stopped: verb = "Stopped \(running.lowercased())"
        case nil: verb = running
        }
        return ToolPresentation(displayName: "\(verb) \(detail)",
                                icon: name.hasPrefix("preview_") ? .browser : .t3Code)
    }

    /// Latest live activity stays present-tense unless the call itself failed,
    /// declined, or stopped.
    public static func liveActivityToolStatus(_ status: T3WorkLogEntry.LifecycleStatus?,
                                              presentTense: Bool) -> T3WorkLogEntry.LifecycleStatus {
        switch status {
        case .failed, .declined, .stopped: return status ?? .completed
        case .inProgress: return .inProgress
        case .completed, nil: return presentTense ? .inProgress : .completed
        }
    }

    /// `resolveWorkEntryToolPresentation` — resolves tool identity before
    /// choosing labels or icons.
    public static func toolPresentation(_ e: T3WorkLogEntry,
                                        fallback: T3WorkLogEntry.LifecycleStatus? = nil) -> ToolPresentation? {
        let status = e.toolLifecycleStatus ?? fallback
        // upstream: a structured tool identity short-circuits — a foreign
        // server's matching tool name never falls back to the label.
        if let toolName = e.toolName { return t3McpToolPresentation(toolName, status) }
        return t3McpToolPresentation(e.toolTitle, status) ?? t3McpToolPresentation(e.label, status)
    }

    // MARK: - Predicates

    /// `workLogEntryIsToolLike`. Every `ItemType` case is a tool-lifecycle item
    /// type upstream (`TOOL_LIFECYCLE_ITEM_TYPES`), so a set `itemType` is one.
    public static func isToolLike(_ e: T3WorkLogEntry) -> Bool {
        if e.tone == .tool || e.tone == .thinking || e.tone == .error { return true }
        if let c = e.command, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if e.requestKind != nil { return true }
        return e.itemType != nil
    }

    private static let exitedWithCode = regex("<exited with exit code\\s+[1-9]\\d*\\s*>", caseInsensitive: true)
    private static let exitWithCode = regex("exit(?:ed)? with exit code\\s+[1-9]\\d*", caseInsensitive: true)
    private static let exitCode = regex("exit code\\s*[:\\s]\\s*[1-9]\\d*\\b", caseInsensitive: true)

    /// Some providers report completion even when the output describes failure.
    private static func detailLooksLikeFailure(_ text: String) -> Bool {
        let n = text.lowercased()
        return n.contains("file not found")
            || n.contains("no files found")
            || n.contains("enoent")
            || n.contains("no such file or directory")
            || n.contains("no such file")
            || n.contains("commandnotfoundexception")
            || n.contains("command not found")
            || (n.contains("cannot find path") && n.contains("because it does not exist"))
            || (n.contains("is not recognized") && n.contains("the term '"))
            || n.contains("is not recognized as the name of a cmdlet")
            || n.contains("a parameter cannot be found that matches parameter name")
            || matches(text, exitedWithCode) || matches(text, exitWithCode) || matches(text, exitCode)
    }

    private static func indicatesFailure(_ e: T3WorkLogEntry, includeCommand: Bool) -> Bool {
        if e.tone == .error || e.toolLifecycleStatus == .failed || e.toolLifecycleStatus == .declined {
            return true
        }
        if !isToolLike(e) { return false }
        let output = includeCommand
            ? [e.detail, e.command].compactMap { $0 }.joined(separator: "\n")
            : (e.detail ?? "")
        return !output.isEmpty && detailLooksLikeFailure(output)
    }

    /// Includes legacy activities that stored error output in the command field.
    public static func indicatesFailure(_ e: T3WorkLogEntry) -> Bool { indicatesFailure(e, includeCommand: true) }

    /// Checks rendered output without treating the user's command as an error.
    public static func displayIndicatesFailure(_ e: T3WorkLogEntry) -> Bool { indicatesFailure(e, includeCommand: false) }

    /// Decides whether the row can show a success marker.
    public static func indicatesSuccess(_ e: T3WorkLogEntry) -> Bool {
        isToolLike(e) && !indicatesFailure(e) && e.tone != .thinking
            && e.toolLifecycleStatus != .inProgress && e.toolLifecycleStatus != .stopped
    }

    /// `workEntryIndicatesToolNeutralStatus` — tool-like row with neither clear
    /// success nor failure. Spawn CTA rows are never neutral-hidden.
    public static func indicatesNeutralStatus(_ e: T3WorkLogEntry) -> Bool {
        if e.isAgentSpawn { return false }
        if !isToolLike(e) { return false }
        if indicatesFailure(e) { return false }
        if indicatesSuccess(e) { return false }
        return true
    }

    private static let grepWord = regex("\\bgrep\\b", caseInsensitive: true)

    /// Divergence from upstream: the `toolName == "Grep"` disjunct. Upstream
    /// matches the label alone because a T3 grep row's label always carries the
    /// word; an Infinitus row's label is the search *pattern* (the adapter
    /// carries it over from the `tool.started` twin), which need not contain
    /// "grep" — but the structured tool name, which upstream has no equivalent
    /// of, says so exactly.
    private static func isLocalCodeSearch(_ e: T3WorkLogEntry) -> Bool {
        guard e.itemType == .webSearch else { return false }
        return e.toolName == "Grep" || matches(normalizeCompactToolLabel(e.toolTitle ?? e.label), grepWord)
    }

    public static func groupAction(_ e: T3WorkLogEntry) -> GroupAction {
        if e.sourceActivityKind == "approval.requested" || e.sourceActivityKind == "approval.resolved"
            || e.sourceActivityKind == "provider.approval.respond.failed" {
            return .update
        }
        if toolPresentation(e)?.icon == .browser { return .browser }
        if e.requestKind == .fileRead || e.itemType == .imageView || e.viewedImagePath != nil
            || (e.itemType == .dynamicToolCall
                && e.toolTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "read file") {
            return .read
        }
        if e.requestKind == .fileChange || e.itemType == .fileChange || !e.changedFiles.isEmpty { return .edit }
        if e.requestKind == .command || e.itemType == .commandExecution || e.command != nil { return .command }
        if isLocalCodeSearch(e) { return .codeSearch }
        if e.itemType == .webSearch { return .search }
        return isToolLike(e) ? .other : .update
    }

    // MARK: - Group summaries

    private static func actionCount(_ action: GroupAction, _ entries: [T3WorkLogEntry]) -> Int {
        guard action == .edit else { return entries.count }
        var changedFiles = Set<String>()
        var editsWithoutFileDetails = 0
        for entry in entries {
            if entry.changedFiles.isEmpty { editsWithoutFileDetails += 1; continue }
            for file in entry.changedFiles { changedFiles.insert(file) }
        }
        return changedFiles.count + editsWithoutFileDetails
    }

    private static func actionLabel(_ action: GroupAction, _ count: Int) -> String {
        switch action {
        case .read: return "Read \(count) \(count == 1 ? "file" : "files")"
        case .edit: return "Changed \(count) \(count == 1 ? "file" : "files")"
        case .command: return "Ran \(count) \(count == 1 ? "command" : "commands")"
        case .browser: return "Used browser \(count) \(count == 1 ? "time" : "times")"
        case .search: return "Searched the web \(count) \(count == 1 ? "time" : "times")"
        case .codeSearch: return "Searched code \(count) \(count == 1 ? "time" : "times")"
        case .other: return "Used \(count) \(count == 1 ? "tool" : "tools")"
        case .update: return "Received \(count) \(count == 1 ? "update" : "updates")"
        }
    }

    /// `summarizeToolGroup`. `Map` insertion order → parallel key array.
    public static func summarizeGroup(_ entries: [T3WorkLogEntry]) -> String {
        let summaryEntries = omitSupersededLifecycleMarkers(entries) { $0 }
        var sourceKeys: [String] = []
        var sources: [String: T3WorkLogEntry.ToolSource] = [:]
        var actionOrder: [GroupAction] = []
        var grouped: [GroupAction: [T3WorkLogEntry]] = [:]
        for entry in summaryEntries {
            if let source = entry.toolSource {
                if sources.updateValue(source, forKey: source.key) == nil { sourceKeys.append(source.key) }
                continue
            }
            let action = groupAction(entry)
            if grouped[action] == nil { actionOrder.append(action); grouped[action] = [entry] }
            else { grouped[action]?.append(entry) }
        }
        var labels = actionOrder.map { actionLabel($0, actionCount($0, grouped[$0] ?? [])) }
        if !sourceKeys.isEmpty {
            let sourceValues = sourceKeys.compactMap { sources[$0] }
            let names = sourceValues.map(\.name)
            let formattedNames: String
            if names.count < 2 { formattedNames = names[0] }
            else if names.count == 2 { formattedNames = names.joined(separator: " and ") }
            else { formattedNames = "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])" }
            let allIntegrations = sourceValues.allSatisfy { $0.kind == "integration" }
            let suffix = allIntegrations ? " \(sourceValues.count == 1 ? "integration" : "integrations")" : ""
            labels.insert("Used \(formattedNames)\(suffix)", at: 0)
        }
        let sentence = labels.enumerated().map { index, label -> String in
            index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        }
        if sentence.count < 2 { return sentence.first ?? "" }
        if sentence.count == 2 { return sentence.joined(separator: " and ") }
        return "\(sentence.dropLast().joined(separator: ", ")), and \(sentence[sentence.count - 1])"
    }

    /// A statusless, id-less `tool.started`/`tool.updated` marker superseded by
    /// a later terminal call of the same identity is dropped.
    public static func omitSupersededLifecycleMarkers<T>(_ entries: [T],
                                                         entry workEntryFor: (T) -> T3WorkLogEntry) -> [T] {
        var laterTerminalIdentities = Set<String>()
        var reversed: [T] = []
        for element in entries.reversed() {
            let workEntry = workEntryFor(element)
            let normalizedLabel = normalizeCompactToolLabel(workEntry.toolTitle ?? workEntry.label)
            let identity = [workEntry.turnId ?? "no-turn", workEntry.itemType?.rawValue ?? "", normalizedLabel]
                .joined(separator: "\u{001f}")
            let activityKind = workEntry.sourceActivityKind
            let isStatuslessIdlessMarker = workEntry.toolCallId == nil
                && workEntry.toolLifecycleStatus == nil
                && (activityKind == "tool.started" || activityKind == "tool.updated")
            if isStatuslessIdlessMarker && laterTerminalIdentities.contains(identity) { continue }
            reversed.append(element)
            if activityKind == "tool.completed"
                || (workEntry.toolLifecycleStatus != nil && workEntry.toolLifecycleStatus != .inProgress) {
                laterTerminalIdentities.insert(identity)
            }
        }
        return reversed.reversed()
    }

    /// `toolGroupSummaryKind`.
    public static func summaryKind(_ entries: [T3WorkLogEntry]) -> SummaryKind {
        let actions = Set(entries.map(groupAction))
        guard actions.count == 1, let action = actions.first else { return .mixed }
        if action != .other { return SummaryKind(rawValue: action.rawValue) ?? .mixed }
        let fallbackKinds = Set(entries.map { entry -> SummaryKind in
            if entry.itemType == .mcpToolCall { return .other }
            if entry.itemType == .dynamicToolCall { return .dynamicTool }
            if entry.itemType == .collabAgentToolCall || entry.taskId != nil { return .agentTool }
            if entry.tone == .thinking { return .agentTool }
            if entry.tone == .tool { return .toneTool }
            return .other
        })
        return fallbackKinds.count == 1 ? (fallbackKinds.first ?? .mixed) : .mixed
    }

    /// `workEntryIsVisibleInGroup`.
    public static func isVisibleInGroup(_ e: T3WorkLogEntry, expandedToolGroupEntry: Bool = false) -> Bool {
        (expandedToolGroupEntry
            && (e.toolLifecycleStatus == .inProgress || e.sourceActivityKind == "task.progress"))
            || !indicatesNeutralStatus(e)
    }

    // MARK: - Row labels

    private static func capitalizedHeading(_ e: T3WorkLogEntry) -> String {
        let title = e.toolTitle ?? ""
        let heading = normalizeCompactToolLabel(title.isEmpty ? e.label : title)
        return heading.prefix(1).uppercased() + heading.dropFirst()
    }

    public static func singleToolCallLabel(_ e: T3WorkLogEntry) -> String {
        if let presentation = toolPresentation(e, fallback: .completed) { return presentation.displayName }
        if let command = e.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return command
        }
        return capitalizedHeading(e)
    }

    /// `workEntryDisplayLabel`.
    public static func displayLabel(_ e: T3WorkLogEntry, workspaceRoot: String?) -> String {
        if let presentation = toolPresentation(e) { return presentation.displayName }
        if let command = e.command { return command }
        if let detail = e.detail { return detail }
        if let firstPath = e.changedFiles.first {
            let path = formatWorkspaceRelativePath(firstPath, workspaceRoot: workspaceRoot)
            return e.changedFiles.count == 1 ? path : "\(path) +\(e.changedFiles.count - 1) more"
        }
        return capitalizedHeading(e)
    }

    /// `liveWorkEntryLabel`.
    public static func liveLabel(_ e: T3WorkLogEntry, workspaceRoot: String?, active: Bool) -> String {
        let status = liveActivityToolStatus(e.toolLifecycleStatus, presentTense: active)
        var staged = e
        staged.toolLifecycleStatus = status
        if let presentation = toolPresentation(staged) { return presentation.displayName }
        if let command = e.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            let verb: String
            switch status {
            case .inProgress: verb = "Running"
            case .failed: verb = "Failed"
            case .declined: verb = "Declined"
            case .stopped: verb = "Stopped"
            case .completed: verb = "Ran"
            }
            return "\(verb) \(commandProgramName(command) ?? "command")"
        }
        return displayLabel(e, workspaceRoot: workspaceRoot)
    }

    // MARK: - Formatting

    /// `orchestrationTiming.ts` `formatDuration`, over a `TimeInterval`.
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let ms = interval * 1000
        guard ms.isFinite, ms >= 0 else { return "0ms" }
        if ms < 1_000 { return "\(max(1, Int(ms.rounded())))ms" }
        if ms < 10_000 {
            let tenths = (ms / 100).rounded() / 10
            return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
        }
        if ms < 60_000 { return "\(Int((ms / 1000).rounded()))s" }
        let total = Int((ms / 1000).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil, s > 0 ? "\(s)s" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    private static let whitespaceRun = regex("\\s+", caseInsensitive: false)

    private static func normalizeInlinePreview(_ value: String) -> String {
        replacing(value, whitespaceRun, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func truncateInlinePreview(_ value: String, max maxLength: Int = 84) -> String {
        if value.count <= maxLength { return value }
        let head = String(value.prefix(maxLength - 1))
        return trimmingTrailingWhitespace(head) + "…"
    }

    /// `summarizeToolTextOutput`: the first meaningful non-fence line, else a
    /// line count when more than one line carried content.
    public static func summarizeToolTextOutput(_ value: String) -> String? {
        var lines: [String] = []
        for rawLine in value.components(separatedBy: "\n") {
            let line = normalizeInlinePreview(rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine)
            if !line.isEmpty { lines.append(line) }
        }
        if let first = lines.first(where: { $0 != "```" }) { return truncateInlinePreview(first) }
        return lines.count > 1 ? "\(grouped(lines.count)) lines" : nil
    }

    /// `filePathDisplay.ts` `formatWorkspaceRelativePath`, POSIX half: the
    /// Windows-drive branches are dropped, the `path:line:col` split is kept.
    public static func formatWorkspaceRelativePath(_ pathWithPosition: String, workspaceRoot: String?) -> String {
        let position = splitFilePathPosition(pathWithPosition)
        let normalizedPath = position.path.replacingOccurrences(of: "\\", with: "/")
        var displayPath = normalizedPath
        if let workspaceRoot, !workspaceRoot.isEmpty {
            let normalizedRoot = trimmingTrailingPathSeparators(
                workspaceRoot.replacingOccurrences(of: "\\", with: "/"))
            let label = fileBasename(normalizedRoot)
            if normalizedPath == normalizedRoot {
                displayPath = label
            } else if normalizedPath.hasPrefix(normalizedRoot + "/") {
                displayPath = "\(label)/\(normalizedPath.dropFirst(normalizedRoot.count + 1))"
            } else if !normalizedPath.hasPrefix("/") {
                let relative = stripRelativePrefixes(normalizedPath)
                displayPath = normalizedPath.hasPrefix(label + "/") ? normalizedPath : "\(label)/\(relative)"
            }
        }
        return formatFilePathPosition(path: displayPath, line: position.line, column: position.column)
    }

    private static let positionSuffix = regex(":(\\d+)(?::(\\d+))?$", caseInsensitive: false)

    private static func splitFilePathPosition(_ path: String) -> (path: String, line: Int?, column: Int?) {
        let ns = path as NSString
        guard let m = positionSuffix.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound else { return (path, nil, nil) }
        let line = Int(ns.substring(with: m.range(at: 1)))
        let column = m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)))
        return (ns.substring(to: m.range.location),
                (line ?? 0) > 0 ? line : nil,
                (column ?? 0) > 0 ? column : nil)
    }

    private static func formatFilePathPosition(path: String, line: Int?, column: Int?) -> String {
        guard let line else { return path }
        return column.map { "\(path):\(line):\($0)" } ?? "\(path):\(line)"
    }

    private static func fileBasename(_ path: String) -> String {
        let trimmed = trimmingTrailingPathSeparators(path)
        if trimmed.isEmpty { return path }
        guard let index = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return trimmed }
        return String(trimmed[trimmed.index(after: index)...])
    }

    private static func trimmingTrailingPathSeparators(_ path: String) -> String {
        var out = Substring(path)
        while let last = out.last, last == "/" || last == "\\" { out = out.dropLast() }
        return String(out)
    }

    private static func stripRelativePrefixes(_ path: String) -> String {
        var out = Substring(path)
        while out.hasPrefix("./") { out = out.dropFirst(2) }
        while out.hasPrefix("/") { out = out.dropFirst() }
        return String(out)
    }

    private static func trimmingTrailingWhitespace(_ value: String) -> String {
        var out = Substring(value)
        while let last = out.last, last.isWhitespace { out = out.dropLast() }
        return String(out)
    }

    /// `Number.toLocaleString()` for the "N lines" preview (en-US grouping).
    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    // MARK: - Regex helpers (NSRegularExpression: Linux has no Regex literals)

    static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        // Patterns are compile-time constants of this file; a throw is a bug.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static func matches(_ value: String, _ pattern: NSRegularExpression) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    static func replacing(_ value: String, _ pattern: NSRegularExpression, with template: String) -> String {
        pattern.stringByReplacingMatches(in: value,
                                         range: NSRange(location: 0, length: (value as NSString).length),
                                         withTemplate: template)
    }
}

// MARK: - commandProgramName (commandLabel.ts, POSIX half)

/// Port of `~/death/t3code/packages/client-runtime/src/work-log/commandLabel.ts`
/// with the Windows/PowerShell halves dropped: no `cmd`/`powershell`/`pwsh`
/// launchers, no PowerShell call operator, assignments or here-strings, no
/// Windows path forms, and no literal command-alias resolution. Everything
/// POSIX — tokenizing, segment splitting, heredocs, comments, redirections,
/// `cd`/setup skipping, `sh -c` unwrapping, wrappers — is the upstream shape.
extension T3WorkLog {
    private static let maxCommandSegments = 64
    private static let maxShellDepth = 8

    private enum ProgramContext { case exec, shell }
    private enum Wrapper: String { case env, sudo }

    private static let shellPrograms: Set<String> = ["sh", "bash", "zsh", "dash", "ash", "ksh", "fish"]
    private static let shellOptionsWithValue: Set<String> = ["-o", "-O", "--rcfile", "--init-file"]
    private static let shellCommandWrappers: Set<String> = ["builtin", "command", "exec"]
    private static let shellPrecommandModifiers: Set<String> = ["nocorrect", "noglob", "time"]
    private static let skippableSudoProbes: Set<String> = ["[", "[[", "test", "true"]
    private static let nonProgramPrefixCharacters: Set<Character> = Set("<>(){}[];|&$`#!%@:")
    private static let nonProgramSuffixCharacters: Set<Character> = Set("){]}`")

    private static let wrapperOptionsWithValue: [Wrapper: Set<String>] = [
        .env: ["-C", "--chdir", "-S", "--split-string", "-u", "--unset"],
        .sudo: ["-C", "--close-from", "-D", "--chdir", "-g", "--group", "-u", "--user"],
    ]
    private static let wrapperFlags: [Wrapper: Set<String>] = [
        .env: ["-0", "--null", "-i", "--ignore-environment", "--debug", "-v"],
        .sudo: ["-A", "--askpass", "-b", "--background", "-E", "-H", "-i", "-n", "-S"],
    ]

    /// Shell syntax or shell-local control flow, not a useful executable name.
    private static let nonDescriptiveShellPrograms: Set<String> = [
        "!", "#", ".", ":", "[", "[[", "alias", "and", "autoload", "begin", "bg", "bind", "bindkey",
        "break", "builtin", "caller", "case", "catch", "cd", "command", "compgen", "complete", "compopt",
        "continue", "coproc", "declare", "dirs", "disown", "do", "done", "elif", "else", "enable", "end",
        "esac", "eval", "exec", "exit", "export", "false", "fc", "fg", "fi", "finally", "for", "foreach",
        "function", "getopts", "history", "if", "in", "jobs", "let", "local", "logout", "mapfile",
        "nocorrect", "noglob", "not", "or", "popd", "pushd", "read", "readarray", "readonly", "repeat",
        "return", "select", "set", "setopt", "shift", "shopt", "source", "switch", "suspend", "test",
        "then", "time", "times", "trap", "try", "true", "type", "typeset", "ulimit", "umask", "unalias",
        "until", "unset", "unsetopt", "wait", "while",
    ]

    /// Unlike setup builtins, these can make later segments part of control flow
    /// or otherwise unreachable.
    private static let terminalShellPrograms: Set<String> = [
        "and", "begin", "break", "case", "catch", "continue", "coproc", "do", "done", "elif", "else",
        "end", "esac", "eval", "exec", "exit", "false", "fi", "finally", "for", "foreach", "function",
        "if", "in", "not", "or", "repeat", "return", "select", "switch", "then", "try", "until", "while",
    ]

    private static let controlFlowHead = regex(
        "^(?:catch|finally|for|foreach|function|if|param|switch|try|while)\\s*[{(]", caseInsensitive: true)
    private static let functionDefinitionHead = regex("^[A-Za-z_][A-Za-z0-9_]*\\s*\\(\\s*\\)\\s*\\{",
                                                      caseInsensitive: false)
    private static let assignmentToken = regex("^[A-Za-z_][A-Za-z0-9_]*\\+?=", caseInsensitive: false)
    private static let quotedWordCharacters = regex("[\\s()=]", caseInsensitive: false)
    private static let pathSeparator = regex("[\\\\/]", caseInsensitive: false)
    private static let shellCommandOption = regex("^-[a-zA-Z]*c[a-zA-Z]*$", caseInsensitive: false)
    private static let redirectionToken = regex(
        "^(?:(?:(?:\\d+|\\*|\\{[A-Za-z_][A-Za-z0-9_]*\\})?(?:<<<|<<-|<<|<>|>>|>\\||<&|>&|<|>))|&>>|&>)(.*)$",
        caseInsensitive: false)
    private static let processSubstitutionToken = regex("^[<>]\\(", caseInsensitive: false)
    private static let shortOptionCluster = regex("^-[A-Za-z].+", caseInsensitive: false)
    private static let execIdentityOption = regex("^-a.+", caseInsensitive: false)
    private static let execShortFlags = regex("^-[cl]+$", caseInsensitive: false)
    private static let scriptFlags = regex("^-[adkpqr]+$", caseInsensitive: false)
    private static let archArchitecture = regex("^-(?:arm64|arm64e|i386|x86_64)$", caseInsensitive: false)
    private static let timeoutDuration = regex("^(?:\\d+(?:\\.\\d*)?|\\.\\d+)[smhd]?$", caseInsensitive: false)
    private static let exeSuffix = regex("\\.exe$", caseInsensitive: true)
    private static let functionNameToken = regex("^[A-Za-z_][A-Za-z0-9_]*\\(\\)\\{$", caseInsensitive: false)
    private static let schemePrefix = regex("^[A-Za-z][A-Za-z0-9+.-]*:(?![\\\\/])", caseInsensitive: false)

    /// `commandProgramName` — the program a shell command runs, or nil when the
    /// command is shell syntax rather than an execution.
    public static func commandProgramName(_ command: String, depth: Int = 0) -> String? {
        programName(command, depth: depth, context: .shell, segmentsRemaining: maxCommandSegments)
    }

    private static func programName(_ command: String, depth: Int, context: ProgramContext,
                                    segmentsRemaining: Int) -> String? {
        guard segmentsRemaining > 0 else { return nil }
        return parseProgramName(command, depth: depth, context: context, segmentsRemaining: segmentsRemaining)
    }

    // MARK: Tokenizer

    private static func tokenize(_ command: String) -> [String]? {
        let input = Array(command.trimmingCharacters(in: .whitespacesAndNewlines))
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var inBackticks = false
        var substitutionDepth = 0
        var parameterExpansionDepth = 0
        var tokenStarted = false

        var index = 0
        while index < input.count {
            let character = input[index]
            defer { index += 1 }
            if escaping { current.append(character); escaping = false; tokenStarted = true; continue }
            if character == "\\" && quote != "'" {
                let next: Character? = index + 1 < input.count ? input[index + 1] : nil
                if quote == "\"", let next, next != "\"", next != "\\", next != "$", next != "`", next != "\n" {
                    current.append(character); tokenStarted = true; continue
                }
                escaping = true; tokenStarted = true; continue
            }
            if inBackticks {
                current.append(character)
                if character == "`" { inBackticks = false }
                tokenStarted = true; continue
            }
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
                tokenStarted = true; continue
            }
            if character == "`" { current.append(character); inBackticks = true; tokenStarted = true; continue }
            if character == "$", index + 1 < input.count, input[index + 1] == "{" {
                current += "${"; parameterExpansionDepth += 1; tokenStarted = true; index += 1; continue
            }
            if character == "{" && parameterExpansionDepth > 0 {
                current.append(character); parameterExpansionDepth += 1; tokenStarted = true; continue
            }
            if character == "}" && parameterExpansionDepth > 0 {
                current.append(character); parameterExpansionDepth -= 1; tokenStarted = true; continue
            }
            if character == "$", index + 1 < input.count, input[index + 1] == "(" {
                current += "$("; substitutionDepth += 1; tokenStarted = true; index += 1; continue
            }
            if character == "(" { current.append(character); substitutionDepth += 1; tokenStarted = true; continue }
            if character == ")" && substitutionDepth > 0 {
                current.append(character); substitutionDepth -= 1; tokenStarted = true; continue
            }
            if character == "\"" || character == "'" { quote = character; tokenStarted = true; continue }
            if character.isWhitespace {
                if substitutionDepth > 0 || parameterExpansionDepth > 0 {
                    current.append(character); tokenStarted = true; continue
                }
                if tokenStarted { tokens.append(current); current = ""; tokenStarted = false }
                continue
            }
            current.append(character)
            tokenStarted = true
        }

        if quote != nil || escaping || inBackticks || substitutionDepth > 0 || parameterExpansionDepth > 0 {
            return nil
        }
        if tokenStarted { tokens.append(current) }
        return tokens
    }

    // MARK: Segment splitting

    private struct CommandSplit {
        let firstCommand: String
        let remainingCommand: String?
        let separator: String?
    }
    private struct Heredoc { let delimiter: String; let stripTabs: Bool }

    private static func withoutComments(_ command: [Character], end: Int,
                                        comments: [(start: Int, end: Int)]) -> String {
        var result = ""
        var cursor = 0
        for comment in comments {
            if comment.start >= end { break }
            result += String(command[cursor..<comment.start])
            cursor = Swift.min(comment.end, end)
        }
        return result + String(command[cursor..<end])
    }

    private static func readHeredocDelimiter(_ command: [Character], start: Int,
                                             stripTabs: Bool) -> (heredoc: Heredoc, end: Int)? {
        var index = start
        while index < command.count, command[index] == " " || command[index] == "\t" { index += 1 }
        var delimiter = ""
        var quote: Character?
        var escaping = false
        while index < command.count {
            let character = command[index]
            if escaping { delimiter.append(character); escaping = false; index += 1; continue }
            if character == "\\" && quote != "'" { escaping = true; index += 1; continue }
            if let q = quote {
                if character == q { quote = nil } else { delimiter.append(character) }
                index += 1; continue
            }
            if character == "\"" || character == "'" { quote = character; index += 1; continue }
            if character.isWhitespace || ";&|<>()".contains(character) { break }
            delimiter.append(character)
            index += 1
        }
        if delimiter.isEmpty || quote != nil || escaping { return nil }
        return (Heredoc(delimiter: delimiter, stripTabs: stripTabs), index)
    }

    private static func commandAfterHeredocs(_ command: [Character], start: Int,
                                             heredocs: [Heredoc]) -> String? {
        var cursor = start
        for heredoc in heredocs {
            var foundDelimiter = false
            while cursor <= command.count {
                let newlineIndex = command[Swift.min(cursor, command.count)...].firstIndex(of: "\n")
                let lineEnd = newlineIndex ?? command.count
                var line = String(command[Swift.min(cursor, command.count)..<lineEnd])
                if line.hasSuffix("\r") { line.removeLast() }
                let comparable = heredoc.stripTabs ? String(line.drop(while: { $0 == "\t" })) : line
                cursor = newlineIndex == nil ? command.count : lineEnd + 1
                if comparable == heredoc.delimiter { foundDelimiter = true; break }
                if newlineIndex == nil { break }
            }
            if !foundDelimiter { return nil }
        }
        let rest = String(command[Swift.min(cursor, command.count)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    private static func splitFirstShellCommand(_ raw: String) -> CommandSplit {
        let command = Array(raw)
        var quote: Character?
        var escaping = false
        var inBackticks = false
        var inComment = false
        var substitutionDepth = 0
        var parameterExpansionDepth = 0
        var heredocs: [Heredoc] = []
        var comments: [(start: Int, end: Int)] = []
        var commentStart = 0
        var separatorBeforeHeredocs: (index: Int, length: Int)?

        var index = 0
        while index < command.count {
            let character = command[index]
            var advance = 1
            defer { index += advance }

            if inComment {
                if character != "\n" { continue }
                inComment = false
                comments.append((commentStart, index))
            }
            if escaping { escaping = false; continue }
            if character == "\\" && quote != "'" { escaping = true; continue }
            if inBackticks { if character == "`" { inBackticks = false }; continue }
            if let q = quote { if character == q { quote = nil }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "`" { inBackticks = true; continue }
            if character == "#",
               index == 0 || command[index - 1].isWhitespace || ";&|(".contains(command[index - 1]) {
                inComment = true; commentStart = index; continue
            }
            if character == "$", index + 1 < command.count, command[index + 1] == "{" {
                parameterExpansionDepth += 1; advance = 2; continue
            }
            if character == "{" && parameterExpansionDepth > 0 { parameterExpansionDepth += 1; continue }
            if character == "}" && parameterExpansionDepth > 0 { parameterExpansionDepth -= 1; continue }
            if character == "(" { substitutionDepth += 1; continue }
            if character == ")" && substitutionDepth > 0 { substitutionDepth -= 1; continue }
            if substitutionDepth > 0 || parameterExpansionDepth > 0 { continue }

            if character == "<", index + 1 < command.count, command[index + 1] == "<",
               !(index + 2 < command.count && command[index + 2] == "<") {
                let stripTabs = index + 2 < command.count && command[index + 2] == "-"
                guard let delimiter = readHeredocDelimiter(command, start: index + (stripTabs ? 3 : 2),
                                                           stripTabs: stripTabs) else {
                    return CommandSplit(firstCommand: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                        remainingCommand: nil, separator: nil)
                }
                heredocs.append(delimiter.heredoc)
                advance = Swift.max(1, delimiter.end - index)
                continue
            }

            let next: Character? = index + 1 < command.count ? command[index + 1] : nil
            let previous: Character? = index > 0 ? command[index - 1] : nil
            let isDoubleOperator = (character == "&" && next == "&")
                || (character == "|" && (next == "|" || next == "&"))
            let isRedirectionAmpersand = character == "&"
                && (previous == ">" || previous == "<" || next == ">")
            if (!isDoubleOperator && !";&|\n".contains(character)) || isRedirectionAmpersand { continue }

            if character == "\n" && !heredocs.isEmpty {
                let separator = separatorBeforeHeredocs
                let firstCommand = trimmingLeadingWhitespace(
                    withoutComments(command, end: separator?.index ?? index, comments: comments))
                let beforeHeredocs = separator.map {
                    String(command[($0.index + $0.length)..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
                let followingHeredocs = commandAfterHeredocs(command, start: index + 1, heredocs: heredocs)
                let remaining = [beforeHeredocs, followingHeredocs ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                return CommandSplit(firstCommand: firstCommand,
                                    remainingCommand: remaining.isEmpty ? nil : remaining,
                                    separator: separator.map { String(command[$0.index..<($0.index + $0.length)]) }
                                        ?? "\n")
            }
            if !heredocs.isEmpty {
                if separatorBeforeHeredocs == nil {
                    separatorBeforeHeredocs = (index, isDoubleOperator ? 2 : 1)
                }
                if isDoubleOperator { advance = 2 }
                continue
            }

            let firstCommand = trimmingLeadingWhitespace(
                withoutComments(command, end: index, comments: comments))
            var nextCommandIndex = index + (isDoubleOperator ? 2 : 1)
            while nextCommandIndex < command.count, command[nextCommandIndex].isWhitespace {
                nextCommandIndex += 1
            }
            let nextCommand = String(command[Swift.min(nextCommandIndex, command.count)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandSplit(firstCommand: firstCommand,
                                remainingCommand: nextCommand.isEmpty ? nil : nextCommand,
                                separator: isDoubleOperator
                                    ? String(command[index..<(index + 2)]) : String(character))
        }

        if inComment { comments.append((commentStart, command.count)) }
        return CommandSplit(
            firstCommand: withoutComments(command, end: command.count, comments: comments)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            remainingCommand: nil, separator: nil)
    }

    private static func trimmingLeadingWhitespace(_ value: String) -> String {
        String(value.drop(while: { $0.isWhitespace }))
    }

    private static func withoutLeadingShellComments(_ command: String) -> String? {
        var remaining = trimmingLeadingWhitespace(command)
        while remaining.hasPrefix("#") {
            guard let newline = remaining.firstIndex(of: "\n") else { return nil }
            remaining = trimmingLeadingWhitespace(String(remaining[remaining.index(after: newline)...]))
        }
        return remaining.isEmpty ? nil : remaining
    }

    private static func withoutShellLineContinuations(_ raw: String) -> String {
        let command = Array(raw)
        var out = ""
        var quote: Character?
        var escaping = false
        var index = 0
        while index < command.count {
            let character = command[index]
            var advance = 1
            defer { index += advance }
            if escaping { out.append(character); escaping = false; continue }
            if character == "\\" && quote != "'" {
                if index + 1 < command.count, command[index + 1] == "\n" { advance = 2; continue }
                if index + 2 < command.count, command[index + 1] == "\r", command[index + 2] == "\n" {
                    advance = 3; continue
                }
                out.append(character); escaping = true; continue
            }
            if let q = quote { if character == q { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            out.append(character)
        }
        return out
    }

    // MARK: Token helpers

    private static func indexAfterRedirection(_ tokens: [String], _ index: Int) -> Int? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        if token.isEmpty || matches(token, processSubstitutionToken) { return nil }
        let ns = token as NSString
        guard let m = redirectionToken.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if m.range(at: 1).location != NSNotFound, m.range(at: 1).length > 0 { return index + 1 }
        return index + 1 >= tokens.count ? tokens.count + 1 : index + 2
    }

    private static func serialize(_ tokens: ArraySlice<String>) -> String {
        tokens.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
    }

    private static func shellCommandArgumentIndex(_ tokens: [String], from start: Int) -> Int? {
        var index = start
        while index < tokens.count {
            let option = tokens[index]
            if option == "--" || !option.hasPrefix("-") { return nil }
            if shellOptionsWithValue.contains(option) { index += 2; continue }
            if option == "--command" || matches(option, shellCommandOption) { return index + 1 }
            index += 1
        }
        return nil
    }

    private static func transparentWrapperCommandIndex(_ wrapper: String, _ tokens: [String],
                                                       _ index: Int) -> Int? {
        func token(_ i: Int) -> String? { i < tokens.count ? tokens[i] : nil }
        switch wrapper {
        case "bundle":
            return token(index + 1) == "exec" && token(index + 2) != nil ? index + 2 : nil
        case "nohup":
            var target = index + 1
            if token(target) == "--" { target += 1 }
            guard let value = token(target), !value.hasPrefix("-") else { return nil }
            return target
        case "script":
            // BSD `script` takes an output file before the optional command.
            return matches(token(index + 1) ?? "", scriptFlags) && token(index + 3) != nil ? index + 3 : nil
        case "arch":
            if matches(token(index + 1) ?? "", archArchitecture) {
                return token(index + 2) != nil ? index + 2 : nil
            }
            return token(index + 1) == "-arch" && token(index + 3) != nil ? index + 3 : nil
        case "timeout", "gtimeout":
            return matches(token(index + 1) ?? "", timeoutDuration) && token(index + 2) != nil
                ? index + 2 : nil
        default:
            return nil
        }
    }

    private static func staticProgramName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || matches(trimmed, schemePrefix) { return nil }
        guard let program = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init),
              !program.isEmpty else { return nil }
        if program.contains(where: { $0.isWhitespace }) && !matches(trimmed, pathSeparator) { return nil }
        if let first = program.first, nonProgramPrefixCharacters.contains(first) { return nil }
        if let last = program.last, nonProgramSuffixCharacters.contains(last) { return nil }
        return program
    }

    private static func wrappedShellCommandProgramName(_ wrapper: String, _ tokens: [String], from start: Int,
                                                       depth: Int, remainingCommand: String?,
                                                       segmentsRemaining: Int) -> String? {
        var index = start
        switch wrapper {
        case "command":
            while index < tokens.count {
                let option = tokens[index]
                if option == "--" { index += 1; break }
                if !option.hasPrefix("-") || option == "-" { break }
                if option != "-p" { return nil }
                index += 1
            }
        case "builtin":
            if index < tokens.count, tokens[index] == "--" { index += 1 }
            else if index < tokens.count, tokens[index].hasPrefix("-") { return nil }
        case "exec":
            while index < tokens.count {
                let option = tokens[index]
                if option == "--" { index += 1; break }
                if option == "-a" {
                    if index + 1 >= tokens.count { return nil }
                    index += 2; continue
                }
                if matches(option, execIdentityOption) || matches(option, execShortFlags) {
                    index += 1; continue
                }
                if option.hasPrefix("-") && option != "-" { return nil }
                break
            }
        default: break
        }

        let wrapped = tokens[Swift.min(index, tokens.count)...]
        if wrapped.isEmpty { return nil }
        let wrappedTokens = Array(wrapped)
        var targetIndex = 0
        while targetIndex < wrappedTokens.count {
            guard let after = indexAfterRedirection(wrappedTokens, targetIndex),
                  after <= wrappedTokens.count else { break }
            targetIndex = after
        }
        let target: String? = targetIndex < wrappedTokens.count ? wrappedTokens[targetIndex] : nil
        if let target, matches(target, assignmentToken) { return nil }

        if let wrappedProgram = programName(serialize(wrappedTokens[...]), depth: depth + 1,
                                            context: wrapper == "exec" ? .exec : .shell,
                                            segmentsRemaining: segmentsRemaining) {
            return wrappedProgram
        }
        if wrapper != "exec", let target, target == target.lowercased(),
           nonDescriptiveShellPrograms.contains(target), !terminalShellPrograms.contains(target),
           let remainingCommand {
            return programName(remainingCommand, depth: depth, context: .shell,
                               segmentsRemaining: segmentsRemaining - 1)
        }
        return nil
    }

    // MARK: The parser

    private static func parseProgramName(_ command: String, depth: Int, context: ProgramContext,
                                         segmentsRemaining: Int) -> String? {
        if depth >= maxShellDepth || segmentsRemaining <= 0 { return nil }
        guard let withoutComments = withoutLeadingShellComments(command) else { return nil }
        if matches(withoutComments, controlFlowHead) { return nil }
        if matches(withoutComments, functionDefinitionHead) { return nil }
        // `&&`/`||` inside `[[ ... ]]` are not top-level separators.
        if withoutComments.hasPrefix("[[") { return nil }

        let split = splitFirstShellCommand(withoutComments)
        guard let tokens = tokenize(withoutShellLineContinuations(split.firstCommand)) else { return nil }
        let firstCharacter = trimmingLeadingWhitespace(split.firstCommand).first
        if tokens.count == 1, firstCharacter == "\"" || firstCharacter == "'",
           matches(tokens[0], quotedWordCharacters), !matches(tokens[0], pathSeparator) {
            guard let remaining = split.remainingCommand else { return nil }
            return programName(remaining, depth: depth, context: context,
                               segmentsRemaining: segmentsRemaining - 1)
        }

        var index = 0
        var wrapper: Wrapper?
        var executionContext = context
        var sawAssignment = false
        var sawRedirection = false

        while index < tokens.count {
            let token = tokens[index]
            if token.isEmpty { return nil }
            if let after = indexAfterRedirection(tokens, index) {
                if after > tokens.count { return nil }
                sawRedirection = true
                index = after
                continue
            }
            if matches(token, assignmentToken) { sawAssignment = true; index += 1; continue }
            if executionContext == .shell && token == ":" {
                guard let remaining = split.remainingCommand else { return nil }
                return programName(remaining, depth: depth, context: executionContext,
                                   segmentsRemaining: segmentsRemaining - 1)
            }
            if let first = token.first, nonProgramPrefixCharacters.contains(first),
               !(token.hasPrefix("$") && token.contains("/")) {
                if executionContext == .shell, token.hasPrefix("["), let remaining = split.remainingCommand {
                    return programName(remaining, depth: depth, context: executionContext,
                                       segmentsRemaining: segmentsRemaining - 1)
                }
                return nil
            }

            let tokenProgram = token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
                ?? (token.isEmpty ? nil : "")
            let isUnqualifiedToken = token == tokenProgram
            if tokenProgram == "env" || tokenProgram == "sudo" {
                wrapper = Wrapper(rawValue: tokenProgram ?? "")
                executionContext = .exec
                index += 1
                continue
            }
            if wrapper != nil && token == "--" { wrapper = nil; index += 1; continue }
            if let currentWrapper = wrapper, token.hasPrefix("-") {
                if currentWrapper == .env && (token == "-S" || token == "--split-string") {
                    guard index + 1 < tokens.count else { return nil }
                    return programName(tokens[index + 1], depth: depth + 1, context: executionContext,
                                       segmentsRemaining: segmentsRemaining)
                }
                if currentWrapper == .env && token.hasPrefix("--split-string=") {
                    return programName(String(token.dropFirst("--split-string=".count)), depth: depth + 1,
                                       context: executionContext, segmentsRemaining: segmentsRemaining)
                }
                if wrapperOptionsWithValue[currentWrapper]?.contains(token) == true {
                    if index + 1 >= tokens.count { return nil }
                    index += 2; continue
                }
                if wrapperFlags[currentWrapper]?.contains(token) == true { index += 1; continue }
                if token.hasPrefix("--"), let equals = token.firstIndex(of: "="),
                   token.distance(from: token.startIndex, to: equals) > 2 {
                    if wrapperOptionsWithValue[currentWrapper]?.contains(String(token[..<equals])) != true {
                        return nil
                    }
                    index += 1; continue
                }
                if matches(token, shortOptionCluster) && !token.hasPrefix("--") {
                    var consumesNextToken = false
                    let letters = Array(token.dropFirst())
                    for (optionIndex, option) in letters.enumerated() {
                        let shortOption = "-\(option)"
                        if wrapperOptionsWithValue[currentWrapper]?.contains(shortOption) == true {
                            consumesNextToken = optionIndex == token.count - 2
                            break
                        }
                        if wrapperFlags[currentWrapper]?.contains(shortOption) != true { return nil }
                    }
                    if consumesNextToken && index + 1 >= tokens.count { return nil }
                    index += consumesNextToken ? 2 : 1
                    continue
                }
                return nil
            }

            if let tokenProgram,
               shellPrograms.contains(replacing(tokenProgram, exeSuffix, with: "").lowercased()),
               let scriptIndex = shellCommandArgumentIndex(tokens, from: index + 1) {
                guard scriptIndex < tokens.count else { return nil }
                return programName(tokens[scriptIndex], depth: depth + 1, context: .shell,
                                   segmentsRemaining: segmentsRemaining)
            }
            if executionContext == .shell, isUnqualifiedToken, let tokenProgram,
               shellPrecommandModifiers.contains(tokenProgram) {
                index += 1
                if tokenProgram == "time", index < tokens.count, tokens[index] == "-p" { index += 1 }
                if index < tokens.count, tokens[index].hasPrefix("-") { return nil }
                continue
            }
            if isUnqualifiedToken, let tokenProgram,
               let targetIndex = transparentWrapperCommandIndex(tokenProgram, tokens, index),
               let wrappedProgram = programName(serialize(tokens[targetIndex...]), depth: depth + 1,
                                                context: .exec, segmentsRemaining: segmentsRemaining) {
                return wrappedProgram
            }
            if isUnqualifiedToken, let tokenProgram, shellCommandWrappers.contains(tokenProgram) {
                return wrappedShellCommandProgramName(tokenProgram, tokens, from: index + 1, depth: depth,
                                                      remainingCommand: split.remainingCommand,
                                                      segmentsRemaining: segmentsRemaining)
            }
            if executionContext == .shell || (wrapper == .sudo && skippableSudoProbes.contains(tokenProgram ?? "")),
               isUnqualifiedToken, let tokenProgram, nonDescriptiveShellPrograms.contains(tokenProgram),
               !terminalShellPrograms.contains(tokenProgram)
                   || (tokenProgram == "false" && split.separator != "&&"),
               let remaining = split.remainingCommand {
                return programName(remaining, depth: depth, context: .shell,
                                   segmentsRemaining: segmentsRemaining - 1)
            }
            guard let tokenProgram, !tokenProgram.isEmpty else { return nil }
            if isUnqualifiedToken && nonDescriptiveShellPrograms.contains(tokenProgram) { return nil }
            if let first = tokenProgram.first, nonProgramPrefixCharacters.contains(first) { return nil }
            if let last = tokenProgram.last, nonProgramSuffixCharacters.contains(last) { return nil }
            if tokenProgram.hasSuffix("()") || matches(tokenProgram, functionNameToken) { return nil }
            return tokenProgram
        }

        if (sawAssignment || sawRedirection), wrapper == nil, let remaining = split.remainingCommand {
            return programName(remaining, depth: depth, context: executionContext,
                               segmentsRemaining: segmentsRemaining - 1)
        }
        return nil
    }
}
