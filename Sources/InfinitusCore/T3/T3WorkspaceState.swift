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

/// `.group` scopes by a `T3ProjectGrouping.Group`'s member ids (B-3 review):
/// grouping is logical (folder-name based) while `.project` is one physical
/// id, so a group with more than one physical checkout of the same name
/// needs every member's threads, not just the representative's.
public enum T3SidebarScope: Sendable, Equatable { case all, project(id: String), group(ids: [String]) }

/// The workspace window's state as a value (spec §4.3): threads, projects,
/// selection, sidebar scope/search, disclosure. `T3WindowModel` owns one
/// and republishes it; everything here is testable without AppKit.
public struct T3WorkspaceState: Sendable, Equatable {
    public var threads: [T3Thread] = []
    public var projects: [T3ProjectGrouping.Project] = []
    public var groups: [T3ProjectGrouping.Group] = []
    public var selectedThreadId: String?
    /// The selected thread's last value after its session exited (#400): it
    /// stays open with "This session has ended." instead of vanishing, so it
    /// has to outlive `threads`, which only ever holds live sessions. Written
    /// by `apply`, cleared by any other `select` or by the session's return.
    public private(set) var endedThread: T3Thread?
    public var scope: T3SidebarScope = .all
    public var search = ""
    public var expandedTurnIds: [String: Set<String>] = [:]
    public var expandedWorkGroupIds: [String: Set<String>] = [:]
    public var lastVisitedAt: [String: Date] = [:]
    public var sidebarCollapsed = false
    public var rightPanelOpen = false
    /// Threads that have no session yet (Task 15): upstream's draft sessions
    /// (`routes/_chat.draft.$draftId.tsx`, `Sidebar.tsx:781-784`'s draft
    /// block), each a pseudo-thread carrying the project its first prompt
    /// will start in. Merged into `threads` so every selector — `select`,
    /// `selectedThread`, `visibleThreads`, the window's own emptiness checks —
    /// needs no draft case, and `pidBySession` deliberately has no entry for
    /// one (a draft has nothing to poll).
    public private(set) var drafts: [T3Thread] = []
    /// `draftId -> the pid its `SessionStart` answered with`, with the instant
    /// it answered: the draft is replaced by the real thread as soon as that
    /// pid arrives in the fleet with its facts — or, if it never does, the
    /// entry expires (below) so a later pid REUSE cannot hijack the draft.
    private struct PendingStart: Sendable, Equatable {
        var pid: Int32
        var startedAt: Date
    }
    private var startedDraftPids: [String: PendingStart] = [:]
    /// How long a started draft waits for its session to show up in the fleet.
    public static let startDeadline: TimeInterval = 30
    /// Drafts whose start never produced a thread; the window model drains
    /// this (`clearDraftStartTimeout`) to release its own guard and to say so
    /// in the composer.
    public private(set) var draftStartTimeouts: Set<String> = []
    public mutating func clearDraftStartTimeout(_ draftId: String) { draftStartTimeouts.remove(draftId) }
    private var pidBySession: [String: Int32] = [:]
    /// The first `createdAt` `apply` ever computed for a thread id (B-1
    /// review #4): the bridge falls back to `now` when a session carries no
    /// birth signal, and without this memory such a thread's createdAt (and
    /// the updatedAt that falls back to it) would drift forward on every
    /// tick, re-sorting and re-diffing the sidebar for no reason.
    private var firstSeenCreatedAt: [String: Date] = [:]

    public init() {}

    /// `wallClock` is the clock the start deadline is measured against; `now`
    /// is deliberately frozen between the window's minute ticks (E2), which
    /// would stretch the deadline to the next tick. Defaults to `now` so every
    /// existing caller and test is unchanged.
    public mutating func apply(_ inputs: T3WorkspaceInputs, now: Date, wallClock: Date? = nil) {
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
        // A started draft hands over the moment its pid is a REAL thread here
        // — not merely a record: `apply` skips a pid whose facts have not
        // landed yet (above), and handing over then would select an id that is
        // not in `threads`, which the guard at the end of this method would
        // immediately clear.
        let clock = wallClock ?? now
        for (draftId, pending) in startedDraftPids {
            guard let i = next.firstIndex(where: { pids[$0.id] == pending.pid }) else {
                // Never arrived: expire the entry (so a pid reuse cannot be
                // mistaken for this start) and tell the model, which releases
                // its own guard and puts the reason in the composer.
                if clock.timeIntervalSince(pending.startedAt) >= Self.startDeadline {
                    startedDraftPids[draftId] = nil
                    draftStartTimeouts.insert(draftId)
                }
                continue
            }
            drafts.removeAll { $0.id == draftId }
            startedDraftPids[draftId] = nil
            draftStartTimeouts.remove(draftId)
            guard selectedThreadId == draftId else { continue }
            selectedThreadId = next[i].id
            lastVisitedAt[next[i].id] = now
            next[i].lastVisitedAt = now
        }
        // Drafts first: `Sidebar.tsx:781-784` keeps the draft block above the
        // list so an interrupted "new thread" stays one click away.
        let previousThreads = threads
        threads = drafts + next.sorted { $0.updatedAt > $1.updatedAt }
        pidBySession = pids
        // Drop memory for threads that are gone; a thread that comes back gets
        // a fresh first-seen date, which is correct — its record then carries
        // real timestamps or is a genuinely new session.
        let ids = Set(pids.keys)
        firstSeenCreatedAt = firstSeenCreatedAt.filter { ids.contains($0.key) }
        let draftIds = Set(drafts.map(\.id))
        lastVisitedAt = lastVisitedAt.filter { ids.contains($0.key) || draftIds.contains($0.key) }
        projects = inputs.projects.map { T3ProjectGrouping.Project(summary: $0) }
        groups = T3ProjectGrouping.groups(projects: projects, settings: .init(),
                                          primaryEnvironmentId: T3Thread.localEnvironmentId, environmentLabel: { _ in nil })
        // #400: the selected thread's session exited — keep it SELECTED. The
        // window then holds its rows, shows "This session has ended." and
        // refuses sends, which is the phone's rule (`T3ThreadScreen`). The
        // value is stashed here rather than left in `threads` because that
        // list is the live sessions the sidebar shows, and an ended thread is
        // no longer one. A session that comes back (same id, new pid) lands in
        // `pids` again and clears the stash; `select` drops it for good.
        if let id = selectedThreadId, pids[id] == nil, !drafts.contains(where: { $0.id == id }) {
            if endedThread?.id != id {
                // Not a thread this state ever carried (a selection restored
                // for a session this launch never saw): nothing to keep open.
                guard let last = previousThreads.first(where: { $0.id == id }) else {
                    selectedThreadId = nil
                    endedThread = nil
                    return
                }
                endedThread = last
            }
        } else {
            endedThread = nil
        }
    }

    public mutating func select(_ threadId: String?, now: Date) {
        guard threadId == nil || threads.contains(where: { $0.id == threadId }) else { return }
        // Any other selection — a live thread, a draft, or nothing — drops the
        // ended thread for good (#400). The ended id itself is not in
        // `threads`, so it cannot be re-selected through here.
        endedThread = nil
        selectedThreadId = threadId
        guard let threadId else { return }
        lastVisitedAt[threadId] = now
        if let i = threads.firstIndex(where: { $0.id == threadId }) { threads[i].lastVisitedAt = now }
    }

    // MARK: - Drafts (Task 15)

    /// `DraftId` upstream (`composerDraftStore.ts`) is its own opaque id; here
    /// a draft rides the same `T3Thread` list as everything else, so the id
    /// carries the marker.
    public static let draftIdPrefix = "draft:"
    public static func isDraft(_ threadId: String) -> Bool { threadId.hasPrefix(draftIdPrefix) }
    /// Upstream's draft row shows the project name over the typed prompt and
    /// has no title of its own (`Sidebar.tsx:681-770`); this is ours, for the
    /// places a thread must have a title (the top bar, the ⌘K switcher).
    public static let draftTitle = "New thread"
    /// A draft row's title: the first line of its text, trimmed, or
    /// `draftTitle` when there is none (`ThreadRow` for drafts).
    public static func draftRowTitle(_ preview: String) -> String {
        let line = preview.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? draftTitle : trimmed
    }

    /// A new draft in `projectId`, newest first. Returns its id.
    @discardableResult
    public mutating func addDraft(projectId: String, now: Date) -> String {
        addDraft(id: Self.draftIdPrefix + UUID().uuidString, projectId: projectId, now: now)
    }

    /// The same row under an id the caller already has: a draft persisted in
    /// `workspace.drafts` put back at launch (B-5 review), which only works if
    /// the row keeps the id its text is stored under.
    @discardableResult
    public mutating func addDraft(id: String, projectId: String, now: Date) -> String {
        guard !drafts.contains(where: { $0.id == id }) else { return id }
        let draft = T3Thread(id: id, environmentId: T3Thread.localEnvironmentId, projectId: projectId,
                             title: Self.draftTitle, createdAt: now, updatedAt: now)
        drafts.insert(draft, at: 0)
        threads.insert(draft, at: 0)
        return draft.id
    }

    /// A draft with nothing in it yet, in this project: ⌘N reuses it rather
    /// than stacking a second "New thread" row (upstream's draft rows only
    /// exist for drafts that HAVE content, `Sidebar.tsx:781-784`, so it never
    /// stacks empty ones either). `isUntouched` answers for the composer draft
    /// the model holds — the reducer knows nothing about typed text.
    public func reusableDraftId(projectId: String, isUntouched: (String) -> Bool) -> String? {
        drafts.first { $0.projectId == projectId && startedDraftPids[$0.id] == nil && isUntouched($0.id) }?.id
    }

    /// Discarded (upstream's "Discard draft", `Sidebar.tsx:756`), or replaced
    /// by the session it started. A discarded draft that WAS selected hands the
    /// selection to its neighbour rather than leaving the window with nothing
    /// selected — `Sidebar.tsx`'s discard leaves the route on a thread.
    public mutating func removeDraft(_ draftId: String, now: Date) {
        let fallback = selectedThreadId == draftId
            ? (adjacentThreadId(.next, now: now) ?? adjacentThreadId(.previous, now: now))
            : nil
        drafts.removeAll { $0.id == draftId }
        threads.removeAll { $0.id == draftId }
        startedDraftPids[draftId] = nil
        draftStartTimeouts.remove(draftId)
        lastVisitedAt[draftId] = nil
        guard selectedThreadId == draftId else { return }
        selectedThreadId = nil
        if let fallback, fallback != draftId { select(fallback, now: now) }
    }

    /// The hero's project picker moves the open draft to another project in
    /// place (`DraftHeroHeadline.tsx:142-150`).
    public mutating func retargetDraft(_ draftId: String, projectId: String) {
        guard let i = drafts.firstIndex(where: { $0.id == draftId }) else { return }
        drafts[i].projectId = projectId
        if let j = threads.firstIndex(where: { $0.id == draftId }) { threads[j].projectId = projectId }
    }

    /// The draft's `SessionStart` came back with this pid; the next `apply`
    /// that sees it as a thread replaces the draft.
    public mutating func markDraftStarted(_ draftId: String, pid: Int32, now: Date) {
        guard drafts.contains(where: { $0.id == draftId }) else { return }
        startedDraftPids[draftId] = PendingStart(pid: pid, startedAt: now)
    }

    /// The draft is still waiting for its session (the window model's guard
    /// mirrors this; it is what keeps a second ⏎ from starting a second child).
    public func isDraftStarting(_ draftId: String) -> Bool { startedDraftPids[draftId] != nil }

    public func pid(of threadId: String) -> Int32? { pidBySession[threadId] }
    /// The ended thread (#400) resolves through here too — everything that
    /// draws the open thread (the top bar's title, the branch line's project)
    /// reads this, so it keeps working after the session exits.
    public var selectedThread: T3Thread? {
        guard let id = selectedThreadId else { return nil }
        if let live = threads.first(where: { $0.id == id }) { return live }
        return endedThread?.id == id ? endedThread : nil
    }

    /// Scope + search applied; an empty search shows the whole scope
    /// (`T3SidebarList.searchByTitle`'s empty query matches nothing, so it
    /// is only consulted once there is something to search for).
    public func visibleThreads(now: Date) -> [T3Thread] {
        var out = threads
        switch scope {
        case .all: break
        case let .project(id): out = out.filter { $0.projectId == id }
        case let .group(ids): let set = Set(ids); out = out.filter { set.contains($0.projectId) }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? out : T3SidebarList.searchByTitle(out, query: search)
    }

    public struct SidebarSection: Sendable, Equatable {
        public let kind: T3SidebarList.Section
        public let threads: [T3Thread]
    }

    public func sidebarSections(now: Date) -> [SidebarSection] {
        let all = visibleThreads(now: now)
        // A draft has no session, so every lifecycle predicate below reads
        // "active" for it anyway; it is lifted out so it sits ABOVE the sorted
        // active rows rather than being ordered among them, and so the
        // keyboard traversal order matches what the sidebar draws.
        let visible = all.filter { !Self.isDraft($0.id) }
        let draftRows = all.filter { Self.isDraft($0.id) }
        let pinned = T3ThreadSort.sortPinned(visible.filter { $0.pinnedAt != nil })
        let rest = visible.filter { $0.pinnedAt == nil }
        let snoozed = rest.filter { T3ThreadSettled.effectiveSnoozed($0, now: now) }
            .sorted { T3ThreadList.stamp($0.snoozedUntil) < T3ThreadList.stamp($1.snoozedUntil) }   // soonest wake first
        let unsnoozed = rest.filter { !T3ThreadSettled.effectiveSnoozed($0, now: now) }
        let settled = unsnoozed.filter { Self.isSettled($0) }
            .sorted { T3ThreadList.stamp(T3ThreadSort.settledTimestamp($0)) > T3ThreadList.stamp(T3ThreadSort.settledTimestamp($1)) }
        let active = draftRows + T3ThreadSort.sortActive(unsnoozed.filter { !Self.isSettled($0) })
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
