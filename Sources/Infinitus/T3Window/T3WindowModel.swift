import SwiftUI
import Combine
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
        if draft.isEmpty { next.removeValue(forKey: threadId) } else { next[threadId] = draft }
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
