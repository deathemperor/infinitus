import Foundation

/// What the window model hands the reducer on every fleet tick — the raw
/// Infinitus facts, never a T3 type, so the mapping lives in one place.
public struct T3WorkspaceInputs: Sendable, Equatable {
    public var records: [ClaudeSessionRecord]
    public var facts: [Int32: SessionFacts]
    public var progress: [Int32: SessionProgress]
    public var startedAt: [Int32: Date]
    public var projects: [ProjectSummary]
    public init(records: [ClaudeSessionRecord], facts: [Int32: SessionFacts], progress: [Int32: SessionProgress],
                startedAt: [Int32: Date], projects: [ProjectSummary]) {
        self.records = records; self.facts = facts; self.progress = progress
        self.startedAt = startedAt; self.projects = projects
    }
}

public enum T3SidebarScope: Sendable, Equatable { case all, project(id: String) }

/// The workspace window's state as a value (spec §4.3): threads, projects,
/// selection, sidebar scope/search, disclosure. `T3WindowModel` owns one
/// and republishes it; everything here is testable without AppKit.
public struct T3WorkspaceState: Sendable, Equatable {
    public var threads: [T3Thread] = []
    public var projects: [T3ProjectGrouping.Project] = []
    public var groups: [T3ProjectGrouping.Group] = []
    public var selectedThreadId: String?
    public var scope: T3SidebarScope = .all
    public var search = ""
    public var expandedTurnIds: [String: Set<String>] = [:]
    public var expandedWorkGroupIds: [String: Set<String>] = [:]
    public var lastVisitedAt: [String: Date] = [:]
    public var sidebarCollapsed = false
    public var rightPanelOpen = false
    private var pidBySession: [String: Int32] = [:]
    /// The first `createdAt` `apply` ever computed for a thread id (B-1
    /// review #4): the bridge falls back to `now` when a session carries no
    /// birth signal, and without this memory such a thread's createdAt (and
    /// the updatedAt that falls back to it) would drift forward on every
    /// tick, re-sorting and re-diffing the sidebar for no reason.
    private var firstSeenCreatedAt: [String: Date] = [:]

    public init() {}

    public mutating func apply(_ inputs: T3WorkspaceInputs, now: Date) {
        // ClaudeSessions.list does not dedupe by session id (a resume overlap,
        // or a missing field on either side, can yield two records for the
        // same session under different pids) — keep the one with the newer
        // statusUpdatedAt; nil loses.
        var recordsBySession: [String: ClaudeSessionRecord] = [:]
        for r in inputs.records {
            if let existing = recordsBySession[r.sessionId],
               (existing.statusUpdatedAt ?? .distantPast) >= (r.statusUpdatedAt ?? .distantPast) { continue }
            recordsBySession[r.sessionId] = r
        }
        var next: [T3Thread] = []
        var pids: [String: Int32] = [:]
        for r in recordsBySession.values {
            guard let f = inputs.facts[r.pid] else { continue }
            // The bridge's createdAt chain is startedAt ?? latestTurn.requestedAt ??
            // statusUpdatedAt ?? now; only the `now` fallback (none of those three
            // present) is a non-signal. Passing a frozen clock into the bridge (rather
            // than post-patching its output) freezes that fallback at the thread's
            // first sighting AND lets updatedAt (which maxes against createdAt) move
            // freely on real progress activity, instead of both being pinned to "now"
            // forever. `createdAt` itself then stays frozen at first-seen for every
            // thread, birth signal or not — startedAt is always nil (#223, no birth
            // timestamp yet), so a real `latestTurn.requestedAt`/`statusUpdatedAt` is
            // the newest TURN/status change, not a creation time, and must not be
            // allowed to drag createdAt forward on every prompt.
            let hasBirthSignal = inputs.startedAt[r.pid] != nil || f.latestTurn?.requestedAt != nil || r.statusUpdatedAt != nil
            let effectiveNow = hasBirthSignal ? now : (firstSeenCreatedAt[r.sessionId] ?? now)
            var t = T3Thread(record: r, facts: f, progress: inputs.progress[r.pid], startedAt: inputs.startedAt[r.pid], now: effectiveNow)
            let remembered = firstSeenCreatedAt[t.id] ?? t.createdAt
            firstSeenCreatedAt[t.id] = remembered
            t.createdAt = remembered
            t.lastVisitedAt = lastVisitedAt[t.id]
            next.append(t)
            pids[t.id] = r.pid
        }
        threads = next.sorted { $0.updatedAt > $1.updatedAt }
        pidBySession = pids
        // Drop memory for threads that are gone; a thread that comes back gets
        // a fresh first-seen date, which is correct — its record then carries
        // real timestamps or is a genuinely new session.
        let ids = Set(pids.keys)
        firstSeenCreatedAt = firstSeenCreatedAt.filter { ids.contains($0.key) }
        lastVisitedAt = lastVisitedAt.filter { ids.contains($0.key) }
        projects = inputs.projects.map { T3ProjectGrouping.Project(summary: $0) }
        groups = T3ProjectGrouping.groups(projects: projects, settings: .init(),
                                          primaryEnvironmentId: T3Thread.localEnvironmentId, environmentLabel: { _ in nil })
        if let id = selectedThreadId, pids[id] == nil { selectedThreadId = nil }
    }

    public mutating func select(_ threadId: String?, now: Date) {
        guard threadId == nil || threads.contains(where: { $0.id == threadId }) else { return }
        selectedThreadId = threadId
        guard let threadId else { return }
        lastVisitedAt[threadId] = now
        if let i = threads.firstIndex(where: { $0.id == threadId }) { threads[i].lastVisitedAt = now }
    }

    public func pid(of threadId: String) -> Int32? { pidBySession[threadId] }
    public var selectedThread: T3Thread? { selectedThreadId.flatMap { id in threads.first { $0.id == id } } }

    /// Scope + search applied; an empty search shows the whole scope
    /// (`T3SidebarList.searchByTitle`'s empty query matches nothing, so it
    /// is only consulted once there is something to search for).
    public func visibleThreads(now: Date) -> [T3Thread] {
        var out = threads
        if case let .project(id) = scope { out = out.filter { $0.projectId == id } }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? out : T3SidebarList.searchByTitle(out, query: search)
    }

    public struct SidebarSection: Sendable, Equatable {
        public let kind: T3SidebarList.Section
        public let threads: [T3Thread]
    }

    public func sidebarSections(now: Date) -> [SidebarSection] {
        let visible = visibleThreads(now: now)
        let pinned = T3ThreadSort.sortPinned(visible.filter { $0.pinnedAt != nil })
        let rest = visible.filter { $0.pinnedAt == nil }
        let snoozed = rest.filter { T3ThreadSettled.effectiveSnoozed($0, now: now) }
            .sorted { T3ThreadList.stamp($0.snoozedUntil) < T3ThreadList.stamp($1.snoozedUntil) }   // soonest wake first
        let unsnoozed = rest.filter { !T3ThreadSettled.effectiveSnoozed($0, now: now) }
        let settled = unsnoozed.filter { Self.isSettled($0) }
            .sorted { T3ThreadList.stamp(T3ThreadSort.settledTimestamp($0)) > T3ThreadList.stamp(T3ThreadSort.settledTimestamp($1)) }
        let active = T3ThreadSort.sortActive(unsnoozed.filter { !Self.isSettled($0) })
        return [SidebarSection(kind: .pinned, threads: pinned), SidebarSection(kind: .active, threads: active),
                SidebarSection(kind: .snoozed, threads: snoozed),
                SidebarSection(kind: .settled, threads: settled)]
            .filter { !$0.threads.isEmpty }
    }

    /// T3's settled predicate: the one rule `T3ThreadList` checks inline
    /// (`orderedSection`/`buildItems`) and `T3SidebarList.applyDrop` reads
    /// back — `settledOverride == .settled`. It exposes no standalone
    /// function to call, so this is that same rule, not a second one; the
    /// bridge always resolves `settledOverride` to `.settled`/`.active`
    /// (never nil) for a live session, so there is no separate "unset" case.
    static func isSettled(_ t: T3Thread) -> Bool { t.settledOverride == .settled }

    public func adjacentThreadId(_ direction: T3SidebarList.Traversal, now: Date) -> String? {
        let ids = sidebarSections(now: now).flatMap { $0.threads.map(\.id) }
        return T3SidebarList.adjacentThreadId(ids, current: selectedThreadId, direction: direction)
    }

    public mutating func toggleTurn(_ turnId: String) {
        guard let id = selectedThreadId else { return }
        var set = expandedTurnIds[id] ?? []
        if !set.insert(turnId).inserted { set.remove(turnId) }
        expandedTurnIds[id] = set
    }

    public mutating func toggleWorkGroup(_ groupId: String) {
        guard let id = selectedThreadId else { return }
        var set = expandedWorkGroupIds[id] ?? []
        if !set.insert(groupId).inserted { set.remove(groupId) }
        expandedWorkGroupIds[id] = set
    }
}
