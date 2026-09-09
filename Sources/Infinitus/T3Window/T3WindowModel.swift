import SwiftUI
import Combine
import os
import InfinitusCore

/// The workspace window's model (spec §4.3): one `T3WorkspaceState`
/// republished only when a fleet tick actually changes it (E2). Reads ride
/// `SessionProgressModel`'s publishers — no timer of its own; the only
/// clock is the 60 s relative-time tick the controller runs while the
/// window is key.
@MainActor
final class T3WindowModel: ObservableObject {
    @Published private(set) var state = T3WorkspaceState()
    /// The instant labels are computed against; set once at `start()` and
    /// by the key-window tick — never on every fleet tick (E2). Views read
    /// this, never `Date()`.
    @Published private(set) var now = Date()
    @Published var focusedScreen: String?
    /// The selected thread's rows (Task 9's store, Task 11's plumbing): one
    /// store per selected thread, kept across a resume (same session id, new
    /// pid) through `rebind`.
    @Published private(set) var timelineStore: T3TimelineStore?
    private(set) weak var model: AppModel?
    private var sink: AnyCancellable?
    private var refreshing = false
    /// Task 13's composer focuses its field when this flips true, then clears it.
    @Published var composerFocusRequested = false
    /// ⌘K's thread switcher sheet (Task 15). On the model, not in `T3Root`'s
    /// `@State`, so `show workspace switcher` can raise it the way
    /// `show workspace draft` makes a draft.
    @Published var switcherOpen = false
    /// Text a panel wants in the composer's draft — the proposed plan's markdown
    /// when the plan card's Edit is pressed (Task 12). Task 13's composer takes
    /// it and clears it; upstream does the same thing by writing the composer's
    /// own draft (`ComposerPrimaryActions.tsx:166-181`, the "Refine" branch).
    @Published var pendingComposerInsert: String?
    /// The hidden ⌘W button in `T3Root` (E6c); the controller sets this to `close()`.
    var closeRequested: (() -> Void)?

    /// `show workspace <screen>` (Task 5 interface): select the first thread when
    /// nothing is selected; `composer` also asks for field focus. One-shot, but
    /// only consumed once it could act — with no threads yet (first tick, before
    /// `refresh()` has landed anything) and a non-composer screen, there is
    /// nothing to select or focus, so the request stays pending for the next
    /// `apply`/`applyPendingScreen` to pick up.
    private func applyFocusedScreen(_ screen: String) {
        // `draft` needs a project to start in, so it waits for the first
        // `refresh()` that has one (Task 15).
        if screen == "switcher" {
            focusedScreen = nil
            switcherOpen = true
            return
        }
        if screen == "draft" {
            guard !state.projects.isEmpty else { return }
            focusedScreen = nil
            startNewThread()
            return
        }
        let canAct = !state.threads.isEmpty || state.selectedThreadId != nil || screen == "composer"
        guard canAct else { return }
        focusedScreen = nil
        if state.selectedThreadId == nil, let first = state.sidebarSections(now: now).first?.threads.first {
            state.select(first.id, now: now)
        }
        if screen == "composer" { composerFocusRequested = true }
    }

    /// Runs `applyFocusedScreen` immediately against the current state (Task A/E5):
    /// the raise path when the window is already visible gets no fresh `refresh()`,
    /// so a pending `focusedScreen` needs an explicit push. One-shot; harmless to
    /// call again once the request already cleared.
    func applyPendingScreen() {
        guard let screen = focusedScreen else { return }
        applyFocusedScreen(screen)
        syncTimelineStore()
    }

    /// The selected thread ↔ `timelineStore` invariant, run after every
    /// selection change and every state apply: no selection stops and drops the
    /// store, a different thread replaces it, and the same thread on a new pid
    /// (a resume) rebinds the existing one so the rows keep their identity.
    private func syncTimelineStore() {
        guard let model else { return }
        if let id = state.selectedThreadId, T3WorkspaceState.isDraft(id) {
            // A draft has no session to poll, but the composer observes a store
            // (T3ComposerView.swift:40) and `T3Root` keys the thread view's
            // remount on `store.threadId` — so a draft gets an INERT one: never
            // `start()`ed, and its sentinel pid can reach no send path (every
            // `actions.send` in the composer goes through `livePid`, which is
            // nil in draft mode).
            guard timelineStore?.threadId != id else { return }
            timelineStore?.stop()
            timelineStore = T3TimelineStore(threadId: id, pid: Self.draftPid, model: model, window: self)
            return
        }
        guard let id = state.selectedThreadId, let pid = state.pid(of: id) else {
            timelineStore?.stop()
            if timelineStore != nil { timelineStore = nil }
            return
        }
        if let store = timelineStore, store.threadId == id {
            if store.pid != pid { store.rebind(pid: pid) }
            return
        }
        timelineStore?.stop()
        let store = T3TimelineStore(threadId: id, pid: pid, model: model, window: self)
        timelineStore = store
        store.start()
    }

    // MARK: - Drafts, prompt recall and visits (Task 13)

    private enum Key {
        static let drafts = "workspace.drafts"
        static let promptHistory = "workspace.promptHistory"
        static let lastVisitedAt = "workspace.lastVisitedAt"
    }
    /// One draft per thread id (`composerDraftStore.ts`, keyed by its draft
    /// target), persisted through `T3ComposerDrafts.save`.
    /// Not `@Published`: the composer reads a draft once (`onAppear`) and
    /// keeps it in its own `@State`, so a publish here would re-render the
    /// window on every debounced save and buy nothing.
    private(set) var drafts: [String: T3ComposerDraft] =
        T3ComposerDrafts.load(from: UserDefaults.standard.data(forKey: Key.drafts))
    /// Prompts the composer can recall with ↑, newest first.
    /// Read on ↑/↓ only — not `@Published` either, for the same reason.
    private(set) var promptHistory: [String] =
        UserDefaults.standard.stringArray(forKey: Key.promptHistory) ?? []
    /// Keystrokes never publish `drafts` (that would re-render the sidebar and
    /// the top bar): they land here and the debounced sink below commits one
    /// value per typing burst.
    private let draftEdits = PassthroughSubject<(String, T3ComposerDraft), Never>()
    private var persistence: Set<AnyCancellable> = []
    /// The most recently visited threads kept; the whole map would otherwise
    /// grow with every session this Mac ever ran.
    private static let visitLimit = 200

    func draft(for threadId: String) -> T3ComposerDraft { drafts[threadId] ?? T3ComposerDraft() }
    /// Debounced (500 ms): the composer calls this on every keystroke.
    func setDraft(_ draft: T3ComposerDraft, for threadId: String) { draftEdits.send((threadId, draft)) }
    /// Immediate — a thread switch or a window close would otherwise lose the
    /// last keystrokes inside the debounce window.
    func flushDraft(_ draft: T3ComposerDraft, for threadId: String) { commit(draft, for: threadId) }

    private func commit(_ draft: T3ComposerDraft, for threadId: String) {
        var next = drafts
        // A draft row that is gone (discarded, or replaced by the session it
        // started) must not come back through the composer's `onDisappear`
        // flush — that flush runs AFTER the row left `state.drafts`, with the
        // field's text still in hand, and would re-persist it under an id no
        // row can ever reach again.
        let gone = T3WorkspaceState.isDraft(threadId) && !state.drafts.contains { $0.id == threadId }
        if draft.isEmpty || gone { next.removeValue(forKey: threadId) } else { next[threadId] = draft }
        guard next != drafts else { return }
        drafts = next
        UserDefaults.standard.set(T3ComposerDrafts.save(next), forKey: Key.drafts)
    }

    func pushPromptHistory(_ prompt: String) {
        let next = T3ComposerDrafts.pushHistory(promptHistory, prompt: prompt)
        guard next != promptHistory else { return }
        promptHistory = next
        UserDefaults.standard.set(next, forKey: Key.promptHistory)
    }

    // MARK: - The composer's menus (Task 14)

    /// `/` commands and `@` files per project cwd. `SlashCommands.discover`
    /// reads every command and skill file and `T3FileMention.list` spawns
    /// `git ls-files`, so both run on a detached task when a menu OPENS —
    /// once per cwd, cached, refreshed on the next open — and never per
    /// keystroke (B-1 review #11). Not `@Published`: like the drafts above,
    /// the composer holds the result in its own `@State`.
    private var commandCache: [String: [SlashCommand]] = [:]
    private var mentionCache: [String: [T3FileMention.Candidate]] = [:]
    /// One load per cwd in flight; a second opener awaits the same task.
    private var commandLoads: [String: Task<[SlashCommand], Never>] = [:]
    private var mentionLoads: [String: Task<[T3FileMention.Candidate], Never>] = [:]

    /// What the menu can show at once, before its load lands.
    func cachedSlashCommands(cwd: String) -> [SlashCommand] { commandCache[cwd] ?? [] }

    /// `claudeDir` is `ClaudeSessions.configHome()` — `CLAUDE_CONFIG_DIR` when
    /// it is set, so a fixture instance sees the fixture's commands and the
    /// real app sees `~/.claude`'s, exactly like every other read of Claude
    /// Code's own files here (T3WindowModel.refresh, :201).
    func slashCommands(cwd: String) async -> [SlashCommand] {
        if let existing = commandLoads[cwd] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) {
            SlashCommands.discover(cwd: cwd, claudeDir: ClaudeSessions.configHome())
        }
        commandLoads[cwd] = task
        let commands = await task.value
        commandLoads[cwd] = nil
        commandCache[cwd] = commands
        return commands
    }

    /// The project's paths, prepared for ranking once (`T3FileMention.Candidate`).
    func fileMentions(cwd: String) async -> [T3FileMention.Candidate] {
        if let existing = mentionLoads[cwd] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) {
            T3FileMention.candidates(T3FileMention.list(cwd: cwd))
        }
        mentionLoads[cwd] = task
        let candidates = await task.value
        mentionLoads[cwd] = nil
        mentionCache[cwd] = candidates
        return candidates
    }

    /// The `@` menu's rows for one query. Ranking a monorepo's 20 000 paths is
    /// tens of milliseconds of scanning, so it happens off the main actor
    /// too — the caller drops a result whose query has moved on.
    func mentionRows(cwd: String, query: String) async -> [String] {
        let candidates: [T3FileMention.Candidate]
        if let cached = mentionCache[cwd] { candidates = cached } else { candidates = await fileMentions(cwd: cwd) }
        return await Task.detached(priority: .userInitiated) {
            T3FileMention.rank(candidates, query: query, limit: T3FileMention.limit)
        }.value
    }

    /// `[String: Date]` under one key. Loaded in `init`, before the first
    /// `apply`: without it every ready thread reads as unseen after a relaunch
    /// (`T3ThreadSettled`'s unseen rule over `T3Thread.lastVisitedAt`).
    private static func loadVisits() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: Key.lastVisitedAt),
              let visits = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return capped(visits)
    }

    private static func saveVisits(_ visits: [String: Date]) {
        guard let data = try? JSONEncoder().encode(capped(visits)) else { return }
        UserDefaults.standard.set(data, forKey: Key.lastVisitedAt)
    }

    private static func capped(_ visits: [String: Date]) -> [String: Date] {
        guard visits.count > visitLimit else { return visits }
        let newest = visits.sorted { $0.value > $1.value }.prefix(visitLimit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    init(model: AppModel) {
        self.model = model
        state.lastVisitedAt = Self.loadVisits()
        draftEdits
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] threadId, draft in self?.commit(draft, for: threadId) }
            .store(in: &persistence)
        // Same mechanism for the visits: one write per burst of selections.
        $state.map(\.lastVisitedAt).removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { Self.saveVisits($0) }
            .store(in: &persistence)
    }

    func start() {
        guard sink == nil, let model else { return }
        now = Date()
        // The controller reuses this model across close/open, and `stop()`
        // dropped the store while `state` kept its selection: rebuild it here,
        // or a reopen shows the no-thread state until `refresh()`'s detached
        // walk lands. A pid that moved meanwhile is what `rebind` is for, and a
        // thread that vanished gets stop+nil on the first apply.
        syncTimelineStore()
        sink = model.sessionProgress.$facts.combineLatest(model.sessionProgress.$byPid)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refresh() }
        refresh()
    }

    /// Drops the store rather than leaving it stopped: a stopped-but-present
    /// store looks unchanged to `syncTimelineStore` and would never poll again.
    func stop() {
        sink = nil
        refreshing = false
        timelineStore?.stop()
        timelineStore = nil
    }

    func tick() { now = Date() }

    private func refresh() {
        guard let model, !refreshing else { return }
        refreshing = true
        let facts = model.sessionProgress.facts, progress = model.sessionProgress.byPid
        let profiles = model.sessionProfiles.profiles
        // `projectSummaries(profiles:live:)` memoizes its PastSessions walk
        // and its git branch lookups itself (#369, #384: 60 s each) — call
        // it with the list already taken, never wrap it in a second cache
        // (that doubles the cost the memo removed).
        Task.detached(priority: .utility) { [weak self, model, profiles] in
            let records = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
            let projects = model.projectSummaries(profiles: profiles, live: records)
            let inputs = T3WorkspaceInputs(
                records: records,
                facts: Dictionary(uniqueKeysWithValues: facts.map { (Int32($0.key), $0.value) }),
                progress: Dictionary(uniqueKeysWithValues: progress.map { (Int32($0.key), $0.value) }),
                // SessionBirth carries no startedAt (#223): the bridge falls
                // back to the latest turn's requestedAt / status time.
                startedAt: [:],
                projects: projects)
            await MainActor.run {
                guard let self else { return }
                // `now` moves only on the key-window minute tick (`tick()`) and
                // once at `start()` — not on every fleet tick, so a republish
                // below reflects a real state change, not the clock.
                var next = self.state
                next.apply(inputs, now: self.now)
                if next != self.state { self.state = next }
                if let screen = self.focusedScreen { self.applyFocusedScreen(screen) }
                self.syncTimelineStore()
                self.refreshing = false
            }
        }
    }

    func select(_ threadId: String?) { state.select(threadId, now: now); syncTimelineStore() }
    func toggleSidebar() { state.sidebarCollapsed.toggle() }
    func toggleRightPanel() { state.rightPanelOpen.toggle() }
    func setScope(_ s: T3SidebarScope) { state.scope = s }
    func setSearch(_ q: String) { state.search = q }
    func toggleTurn(_ id: String) { state.toggleTurn(id) }
    func toggleWorkGroup(_ id: String) { state.toggleWorkGroup(id) }
    func selectAdjacent(_ d: T3SidebarList.Traversal) { if let id = state.adjacentThreadId(d, now: now) { select(id) } }

    // MARK: - New-thread drafts (Task 15)

    private static let log = Logger(subsystem: "run.infinitus", category: "workspace")
    /// The inert store's pid. Never 0 or negative — `kill(0, …)` signals the
    /// whole process group — and never a pid the fleet can hold.
    static let draftPid = Int32.max

    /// `startNewThreadFromContext` (`Sidebar.tsx:4210-4229`): a draft in the
    /// project you are in. `projectId` forces one (⌘⇧N, upstream's
    /// `chat.newLocal`); nil resolves the selected thread's project, then the
    /// sidebar's scope, then the first project — the resolution order
    /// upstream's `newThreadContext` uses (`:4206-4209`).
    /// Drafts whose `SessionStart` is in flight or already answered with a pid
    /// (Task 15 review): the composer's own `starting` flag is `@State` and
    /// dies with the view, so a thread switch and back — or the window between
    /// `markDraftStarted` and the fleet tick that replaces the draft — would
    /// otherwise let a second ⏎ start a second `claude`.
    private var startingDrafts: Set<String> = []
    func isStarting(_ draftId: String) -> Bool { startingDrafts.contains(draftId) }

    func startNewThread(projectId: String? = nil) {
        guard let project = projectId ?? currentProjectId else { return }
        let draft = state.addDraft(projectId: project, now: now)
        select(draft)
        composerFocusRequested = true
    }

    var currentProjectId: String? {
        if let thread = state.selectedThread { return thread.projectId }
        switch state.scope {
        case let .project(id): return id
        case let .group(ids): if let first = ids.first { return first }
        case .all: break
        }
        // `defaultProjectRef` upstream is the project at the TOP of the
        // sidebar (`Sidebar.tsx:4206-4209` over `sortLogicalProjectsForSidebar`)
        // — `state.groups`, which carries that order, not `state.projects`.
        return state.groups.first?.members.first?.id ?? state.projects.first?.id
    }

    func retargetDraft(_ draftId: String, projectId: String) { state.retargetDraft(draftId, projectId: projectId) }

    /// Upstream's "Discard draft" (`Sidebar.tsx:772`). The typed prompt goes
    /// with it, or `workspace.drafts` keeps an entry no row can reach again.
    func discardDraft(_ draftId: String) {
        state.removeDraft(draftId)
        startingDrafts.remove(draftId)
        commit(T3ComposerDraft(), for: draftId)
        syncTimelineStore()
    }

    /// A draft's first send: the prompt starts the session (upstream's draft
    /// route promotes the draft to a real thread once the server answers,
    /// `_chat.draft.$draftId.tsx:38-65`). `onFailure` puts the reason in the
    /// composer's own banner (`T3ThreadActions.note`) and leaves the draft
    /// where it is, with its text — nothing typed is ever lost.
    func sendDraft(_ draftId: String, text: String, permissionMode: String?,
                   onFailure: @escaping (String) -> Void) {
        guard !startingDrafts.contains(draftId) else { return }
        guard let app = model, let draft = state.drafts.first(where: { $0.id == draftId }),
              let cwd = state.projects.first(where: { $0.id == draft.projectId })?.cwd else {
            onFailure("This draft has no project folder to start in")
            return
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `engine: "claude"` explicitly (the wire's own default) — this window
        // reads Claude Code's sessions and nothing else. No `resume`/`fork`
        // (a new thread), no `model`/`systemPrompt` (B has no picker — the
        // composer's model label is read-only), no `headless` (the host
        // decides it below, exactly as the popup's own start path does).
        let request = SessionStart.Request(cwd: cwd, engine: "claude",
                                           prompt: prompt.isEmpty ? nil : prompt,
                                           permissionMode: permissionMode,
                                           commandId: UUID().uuidString)
        // The safety gate: a fixture or a smoke instance must never start a
        // real Claude session — `AppModel.startSession` resolves the real
        // binary through `ClaudeLocator` however throwaway the config dir is
        // (`tools/t3ref/fixture.sh` exports this).
        if ProcessInfo.processInfo.environment["INFINITUS_WORKSPACE_NO_START"] != nil {
            Self.log.debug("workspace: SessionStart suppressed (INFINITUS_WORKSPACE_NO_START) cwd=\(cwd, privacy: .public) engine=claude promptChars=\(prompt.count, privacy: .public) permissionMode=\(permissionMode ?? "default", privacy: .public) headless=host-decided")
            onFailure("Session start disabled in this build")
            return
        }
        startingDrafts.insert(draftId)
        Task.detached(priority: .userInitiated) { [weak self] in
            // "owned" when this Mac can own sessions at all — a capability,
            // never an engine identity: `AppModel.startSession` turns it into
            // `headless`, else `SessionLauncher` opens a terminal. Locating
            // `claude` can block on a login shell, so never on the cooperative
            // pool (AppModel.swift:2977-2981 makes the same hop).
            let owned = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: app.ownedSessions() != nil) }
            }
            let reply = await app.startSession(request, preferredHost: owned ? "owned" : "terminal")
            await MainActor.run { self?.draftStarted(draftId, reply: reply, onFailure: onFailure) }
        }
    }

    private func draftStarted(_ draftId: String, reply: SessionStart.Reply, onFailure: (String) -> Void) {
        guard reply.outcome == "started" else {
            startingDrafts.remove(draftId)
            onFailure(reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            return
        }
        // The prompt is inside the session now; the stored draft must not come
        // back the next time this id is selected.
        commit(T3ComposerDraft(), for: draftId)
        guard let pid = reply.pid else {
            // A terminal host whose session has not registered yet
            // (SessionLauncher.swift:48-50). The prompt is gone either way, so
            // keeping the draft would invite starting it twice: drop it, and
            // the thread arrives on a later tick.
            state.removeDraft(draftId)
            startingDrafts.remove(draftId)
            syncTimelineStore()
            return
        }
        state.markDraftStarted(draftId, pid: Int32(pid))
        // The reducer drops the draft on the tick that sees the pid, and this
        // model never hears about it — so the start guard is released here,
        // where the session is already under way and a second ⏎ would land in
        // the real thread's composer, not in this draft's.
        startingDrafts.remove(draftId)
        // Don't wait for the 200 ms fleet debounce to notice the new pid.
        refresh()
    }

    /// Attention on any thread; the fleet tick republishes the result.
    /// `AppModel.applyAttention` is a static func (`timelineCache` is a
    /// main-actor-isolated `lazy var`): capture the pieces here, on the
    /// actor, before detaching.
    func attention(_ action: AttentionStore.Action, threadId: String, until: Date? = nil) {
        guard let model, let pid = state.pid(of: threadId) else { return }
        let request = SessionAttention.Request(action: action, until: until, commandId: UUID().uuidString, sessionId: threadId)
        let timelineCache = model.timelineCache, attentionStore = model.attentionStore, ownedBox = model.ownedBox
        Task.detached(priority: .userInitiated) {
            _ = AppModel.applyAttention(pid: pid, request, timelineCache: timelineCache,
                                        attentionStore: attentionStore, ownedBox: ownedBox)
        }
    }
}
