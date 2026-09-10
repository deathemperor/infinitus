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
    /// Files a sidebar row's drop staged for a thread, keyed by thread id
    /// (`sidebarPendingFileDropStore.ts`): the composer takes them the moment
    /// it is mounted on that thread and clears the entry. Published because
    /// a drop onto the row of the thread already open has no remount to carry
    /// it — a rare event, like `pendingComposerInsert` above.
    ///
    /// Ours: upstream carries a per-drop id so a FAILED `router.navigate` can
    /// retract just its own drop (`handleThreadFileDrop`,
    /// `Sidebar.tsx:2784-2818`). `select` here is synchronous and cannot land
    /// on another thread, so that id would have no caller; the queue keeps
    /// upstream's other three properties — drops accumulate rather than
    /// replace, other threads' drops survive one thread's consumption, and a
    /// thread that goes away drops its files (`pruneFileDrops`).
    @Published var pendingFileDrops: [String: [URL]] = [:]
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
            // #400: the SAME thread whose session just exited keeps its store.
            // The poll's own "no record for this pid under this session id"
            // branch sets `gone` (the banner, the disconnected composer), and
            // it keeps looking — a session that comes back under a new pid
            // arrives here as a live selection and rebinds below. Only a
            // selection change drops the store.
            if let id = state.selectedThreadId, timelineStore?.threadId == id {
                timelineStore?.markGone()
                return
            }
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
        var draft = draft
        // A draft row that is gone (discarded, or replaced by the session it
        // started) must not come back through the composer's `onDisappear`
        // flush — that flush runs AFTER the row left `state.drafts`, with the
        // field's text still in hand, and would re-persist it under an id no
        // row can ever reach again.
        let row = T3WorkspaceState.isDraft(threadId) ? state.drafts.first { $0.id == threadId } : nil
        let gone = T3WorkspaceState.isDraft(threadId) && row == nil
        // The project the row is in, so `restoreDrafts` can rebuild it after a
        // relaunch; the composer never has to remember to pass it.
        draft.projectId = row?.projectId
        if draft.isEmpty || gone { next.removeValue(forKey: threadId) } else { next[threadId] = draft }
        guard next != drafts else { return }
        drafts = next
        UserDefaults.standard.set(T3ComposerDrafts.save(next), forKey: Key.drafts)
    }

    /// Whether the persisted `draft:` entries have been put back yet. Until
    /// they are, nothing may be pruned: none of them has a row, so `prunable`
    /// would read every one as unreachable and drop the lot.
    private var restoredDrafts = false

    /// The persisted drafts, back as sidebar rows — upstream's drafts survive
    /// a reload because the draft record itself is persisted
    /// (`composerDraftStore.ts`), and here the row is the record. Once, on the
    /// first apply that knows the projects rather than in `init`: which
    /// entries are still reachable is decided by the project list, and that
    /// list only exists after the first `projectSummaries` walk. Restored in
    /// id order so the rows do not shuffle between launches.
    private func restoreDrafts(into state: inout T3WorkspaceState, projects: [ProjectSummary]) {
        guard !restoredDrafts, !projects.isEmpty else { return }
        restoredDrafts = true
        for (id, projectId) in T3ComposerDrafts.restorable(drafts, projects: Set(projects.map(\.id)))
            .sorted(by: { $0.key < $1.key }) {
            state.addDraft(id: id, projectId: projectId, now: now)
        }
    }

    /// The entries no row can reach any more, dropped after every apply
    /// (`T3ComposerDrafts.prunable`): `workspace.drafts` would otherwise keep
    /// a key for every draft ever discarded and every thread ever run.
    private func pruneDrafts() {
        guard restoredDrafts else { return }
        let live = Set(state.threads.map(\.id).filter { state.pid(of: $0) != nil })
        let stale = T3ComposerDrafts.prunable(drafts, liveDraftIds: Set(state.drafts.map(\.id)),
                                              liveThreadIds: live)
        guard !stale.isEmpty else { return }
        var next = drafts
        for id in stale { next.removeValue(forKey: id) }
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

    /// The composer strip's branch (`T3GitFacts.branch` → one HEAD-file read)
    /// per project cwd, on a detached task and cached — the strip asks when it
    /// mounts on a thread, never on a timer. `reload` is the thread switch:
    /// the checkout may have moved since this cwd was last looked at.
    private var branchCache: [String: String?] = [:]
    private var branchLoads: [String: Task<String?, Never>] = [:]

    /// The last answer for `cwd`, to paint before the load lands.
    func cachedBranch(cwd: String) -> String? { branchCache[cwd] ?? nil }

    func gitBranch(cwd: String, reload: Bool = false) async -> String? {
        if reload { branchCache[cwd] = nil }
        if !reload, let cached = branchCache[cwd] { return cached }
        if let existing = branchLoads[cwd] { return await existing.value }
        let task = Task.detached(priority: .utility) { T3GitFacts.branch(cwd: cwd) }
        branchLoads[cwd] = task
        let branch = await task.value
        branchLoads[cwd] = nil
        branchCache[cwd] = branch
        return branch
    }

    /// The right panel's Files tab reads its listing here — one
    /// `T3ProjectFiles.list` (a `git ls-files` spawn with a bounded walk behind
    /// it) per project cwd, on a detached task and cached, exactly like the
    /// branch above. `reload` is the refresh button and the thread switch; no
    /// timer and no file watching watches this cwd.
    private var filesCache: [String: Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>] = [:]
    private var filesLoads: [String: Task<Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>, Never>] = [:]

    /// The last listing for `cwd`, to paint before a fresh one lands.
    func cachedProjectFiles(cwd: String) -> Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>? {
        filesCache[cwd]
    }

    func projectFiles(cwd: String,
                      reload: Bool = false) async -> Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError> {
        if reload {
            filesCache[cwd] = nil
            invalidateFileReads(cwd: cwd)
        }
        if !reload, let cached = filesCache[cwd] { return cached }
        if let existing = filesLoads[cwd] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { T3ProjectFiles.list(root: cwd) }
        filesLoads[cwd] = task
        let listing = await task.value
        filesLoads[cwd] = nil
        filesCache[cwd] = listing
        return listing
    }

    /// The right panel's Diff tab reads one scope's patch here: the session's
    /// checkpoint ladder (`Checkpoints.list`) and the `Checkpoints.diff` the
    /// scope resolves to, parsed into files off the main actor. Cached per
    /// (cwd, session, scope) like the listing above; `reload` is the refresh
    /// button and the thread switch, and nothing else ever asks — no timer and
    /// no watcher.
    private var diffCache: [T3DiffLoad.Key: T3DiffLoad] = [:]
    private var diffLoads: [T3DiffLoad.Key: Task<T3DiffLoad, Never>] = [:]

    /// The last patch for this scope, to paint before a fresh one lands.
    func cachedCheckpointDiff(cwd: String, sessionId: String, scope: T3DiffScope) -> T3DiffLoad? {
        diffCache[T3DiffLoad.Key(cwd: cwd, sessionId: sessionId, scope: scope)]
    }

    func checkpointDiff(cwd: String, sessionId: String, scope: T3DiffScope,
                        reload: Bool = false) async -> T3DiffLoad {
        let key = T3DiffLoad.Key(cwd: cwd, sessionId: sessionId, scope: scope)
        if reload { diffCache[key] = nil }
        if !reload, let cached = diffCache[key] { return cached }
        if let existing = diffLoads[key] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { T3DiffLoad.load(key) }
        diffLoads[key] = task
        let load = await task.value
        diffLoads[key] = nil
        diffCache[key] = load
        // A refresh of one scope invalidates the others: they read the same
        // working tree, and the ladder they list from has just been re-read.
        if reload {
            for other in diffCache.keys where other.cwd == cwd && other.sessionId == sessionId && other != key {
                diffCache[other] = nil
            }
        }
        return load
    }

    /// The Files tab's preview reads one file here — `T3ProjectFiles.read` per
    /// (cwd, path), on a detached task and cached like the listing above.
    /// Nothing watches the file: the tab's refresh button is what asks again
    /// (`invalidateFileReads`, upstream's `onRefreshSelectedFile`,
    /// `FilePreviewPanel.tsx:1345-1347`).
    private struct FileReadKey: Hashable { let cwd: String; let path: String }
    private typealias FileReadResult = Result<T3ProjectFiles.FileRead, T3ProjectFiles.ReadError>
    private var fileReadCache: [FileReadKey: FileReadResult] = [:]
    /// Most recent last. A read holds up to `T3ProjectFiles.readCap` of text,
    /// so browsing a project all afternoon must not keep every file it touched.
    private var fileReadOrder: [FileReadKey] = []
    private var fileReadLoads: [FileReadKey: Task<FileReadResult, Never>] = [:]
    private static let fileReadCacheLimit = 8

    /// The last read of `path`, to paint before a fresh one lands.
    func cachedFileRead(cwd: String, path: String) -> Result<T3ProjectFiles.FileRead, T3ProjectFiles.ReadError>? {
        fileReadCache[FileReadKey(cwd: cwd, path: path)]
    }

    func fileRead(cwd: String, path: String) async -> Result<T3ProjectFiles.FileRead, T3ProjectFiles.ReadError> {
        let key = FileReadKey(cwd: cwd, path: path)
        if let cached = fileReadCache[key] { return cached }
        if let existing = fileReadLoads[key] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { T3ProjectFiles.read(root: cwd, path: path) }
        fileReadLoads[key] = task
        let read = await task.value
        fileReadLoads[key] = nil
        fileReadCache[key] = read
        fileReadOrder.removeAll { $0 == key }
        fileReadOrder.append(key)
        while fileReadOrder.count > Self.fileReadCacheLimit {
            fileReadCache[fileReadOrder.removeFirst()] = nil
        }
        return read
    }

    /// The image sibling of the read above (#223's image contract): the bytes
    /// and mime `T3ProjectFiles.readImage` answers, keyed the same way. Three
    /// slots, not the text read's eight — one image is up to
    /// `T3ProjectFiles.imageCap` (8 MB) of bytes, and the pane holds the
    /// decoded one on top of that.
    private typealias ImageReadResult = Result<T3ProjectFiles.ImageRead, T3ProjectFiles.ReadError>
    private var imageReadCache: [FileReadKey: ImageReadResult] = [:]
    private var imageReadOrder: [FileReadKey] = []
    private var imageReadLoads: [FileReadKey: Task<ImageReadResult, Never>] = [:]
    private static let imageReadCacheLimit = 3

    func cachedImageRead(cwd: String,
                         path: String) -> Result<T3ProjectFiles.ImageRead, T3ProjectFiles.ReadError>? {
        imageReadCache[FileReadKey(cwd: cwd, path: path)]
    }

    func imageRead(cwd: String,
                   path: String) async -> Result<T3ProjectFiles.ImageRead, T3ProjectFiles.ReadError> {
        let key = FileReadKey(cwd: cwd, path: path)
        if let cached = imageReadCache[key] { return cached }
        if let existing = imageReadLoads[key] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { T3ProjectFiles.readImage(root: cwd, path: path) }
        imageReadLoads[key] = task
        let read = await task.value
        imageReadLoads[key] = nil
        imageReadCache[key] = read
        imageReadOrder.removeAll { $0 == key }
        imageReadOrder.append(key)
        while imageReadOrder.count > Self.imageReadCacheLimit {
            imageReadCache[imageReadOrder.removeFirst()] = nil
        }
        return read
    }

    /// Every read under `cwd` forgotten — the listing moved on, so the file
    /// this pane is showing may have too.
    func invalidateFileReads(cwd: String) {
        for key in fileReadCache.keys where key.cwd == cwd { fileReadCache[key] = nil }
        fileReadOrder.removeAll { $0.cwd == cwd }
        for key in imageReadCache.keys where key.cwd == cwd { imageReadCache[key] = nil }
        imageReadOrder.removeAll { $0.cwd == cwd }
    }

    /// The right panel's Pull request tab reads its list here — one
    /// `gh pr list` (plus one `gh pr view` for the checked-out branch's own)
    /// per project cwd, on a detached task and cached exactly like the files
    /// listing above. `reload` is the refresh button and the thread switch;
    /// nothing polls, so an open tab costs nothing while it sits there.
    struct PullRequestLoad: Sendable, Equatable {
        var entries: [T3PullRequests.Entry] = []
        /// The pull request for the checked-out branch, pinned at the top of
        /// the list; nil where the branch has none.
        var current: T3PullRequests.Entry?
        /// Why there is nothing to show — gh missing, no GitHub remote, or
        /// gh's own words (`T3PullRequests.LoadError.message`).
        var failure: String?
        /// The list failed because the tab cannot read pull requests here at
        /// all, which reads as an unavailable surface rather than an error.
        var unavailable = false

        static func load(cwd: String) -> PullRequestLoad {
            var load = PullRequestLoad()
            switch T3PullRequests.list(cwd: cwd) {
            case .success(let entries):
                load.entries = entries
            case .failure(let error):
                load.failure = error.message
                if case .unavailable = error { load.unavailable = true }
                return load
            }
            // Only after the list answered: a failure here is the branch
            // having no pull request, which is not an error to report.
            if case .success(let entry) = T3PullRequests.current(cwd: cwd) { load.current = entry }
            return load
        }
    }

    private var pullRequestCache: [String: PullRequestLoad] = [:]
    private var pullRequestLoads: [String: Task<PullRequestLoad, Never>] = [:]

    /// The last list for `cwd`, to paint before a fresh one lands.
    func cachedPullRequests(cwd: String) -> PullRequestLoad? { pullRequestCache[cwd] }

    func pullRequests(cwd: String, reload: Bool = false) async -> PullRequestLoad {
        if reload {
            pullRequestCache[cwd] = nil
            pullRequestBodies = pullRequestBodies.filter { $0.key.cwd != cwd }
        }
        if !reload, let cached = pullRequestCache[cwd] { return cached }
        if let existing = pullRequestLoads[cwd] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { PullRequestLoad.load(cwd: cwd) }
        pullRequestLoads[cwd] = task
        let load = await task.value
        pullRequestLoads[cwd] = nil
        pullRequestCache[cwd] = load
        return load
    }

    /// One pull request's markdown body, read when the reader opens it — the
    /// list does not carry the bodies (upstream's own detail is a read per
    /// pull request, `PullRequestChecksPopover.tsx:24-27`).
    struct PullRequestBodyKey: Hashable { let cwd: String; let number: Int }
    private var pullRequestBodies: [PullRequestBodyKey: Result<String, T3PullRequests.LoadError>] = [:]
    private var pullRequestBodyLoads: [PullRequestBodyKey: Task<Result<String, T3PullRequests.LoadError>, Never>] = [:]

    func cachedPullRequestBody(cwd: String, number: Int) -> Result<String, T3PullRequests.LoadError>? {
        pullRequestBodies[PullRequestBodyKey(cwd: cwd, number: number)]
    }

    func pullRequestBody(cwd: String, number: Int) async -> Result<String, T3PullRequests.LoadError> {
        let key = PullRequestBodyKey(cwd: cwd, number: number)
        if let cached = pullRequestBodies[key] { return cached }
        if let existing = pullRequestBodyLoads[key] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) {
            T3PullRequests.body(cwd: cwd, number: number)
        }
        pullRequestBodyLoads[key] = task
        let body = await task.value
        pullRequestBodyLoads[key] = nil
        pullRequestBodies[key] = body
        return body
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
        // A menu's load outlives the window otherwise: `T3FileMention.list`
        // spawns `git ls-files` on a monorepo, which must not still be running
        // for a window nobody has open (B-5 review). The caches stay — they are
        // what the next open serves at once.
        for task in commandLoads.values { task.cancel() }
        for task in mentionLoads.values { task.cancel() }
        commandLoads = [:]
        mentionLoads = [:]
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
                // Before the apply, like the visits in `init`: the restored
                // rows are then part of the very first published state, and
                // `apply`'s own `lastVisitedAt` filter keeps their visits.
                self.restoreDrafts(into: &next, projects: inputs.projects)
                // `wallClock` is a real clock for the start deadline only;
                // `now` stays frozen between the window's minute ticks (E2).
                next.apply(inputs, now: self.now, wallClock: Date())
                if next != self.state { self.state = next }
                self.pruneDrafts()
                self.pruneFileDrops()
                self.reconcileDraftStarts()
                if let screen = self.focusedScreen { self.applyFocusedScreen(screen) }
                self.syncTimelineStore()
                self.refreshing = false
            }
        }
    }

    func select(_ threadId: String?) { state.select(threadId, now: now); syncTimelineStore() }

    // MARK: - Sidebar file drops (`bde39d4d7`)

    /// A sidebar row took a drop of files (`handleThreadFileDrop`,
    /// `Sidebar.tsx:2784-2818`): the thread opens and its composer stages the
    /// files. The queue is filled BEFORE the selection, so the composer that
    /// mounts on the new thread already finds them in `onAppear`.
    func dropFiles(_ urls: [URL], onto threadId: String) {
        guard !urls.isEmpty else { return }
        pendingFileDrops[threadId, default: []] += urls
        // `landedBefore` (`:2795-2800`): the row of the open thread needs no
        // navigation, and re-selecting would re-stamp its visit.
        if state.selectedThreadId != threadId { select(threadId) }
    }

    /// The composer's side of it, oldest file first; the entry is gone
    /// afterwards (`consumePendingFileDrop`).
    func takeFileDrops(for threadId: String) -> [URL] {
        pendingFileDrops.removeValue(forKey: threadId) ?? []
    }

    /// `clearPendingFileDropsForThread` (`_chat.$environmentId.$threadId.tsx:66-75`):
    /// a thread that has gone missing can never take its drop, so the files
    /// are released instead of surprising the user in some later composer.
    private func pruneFileDrops() {
        guard !pendingFileDrops.isEmpty else { return }
        let live = Set(state.threads.map(\.id))
        let next = pendingFileDrops.filter { live.contains($0.key) }
        if next.count != pendingFileDrops.count { pendingFileDrops = next }
    }
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
    /// Read once: the environment cannot change under a running process, and
    /// `environment` builds a dictionary on every access.
    private static let noStart = ProcessInfo.processInfo.environment["INFINITUS_WORKSPACE_NO_START"] != nil

    /// The drafts' start state, observed by the composer (fix 1, important #1).
    /// It lives here, not in the view: the composer's `@State` dies whenever
    /// `T3Root` remounts the thread view (a thread switch and back), and a
    /// draft whose `claude` is already starting must stay guarded until the
    /// reducer replaces it — or its start times out.
    let draftStart = T3DraftStart()
    func isStarting(_ draftId: String) -> Bool { draftStart.starting.contains(draftId) }

    /// `startNewThreadFromContext` (`Sidebar.tsx:4251-4270`): a draft in the
    /// project you are in. `projectId` forces one (⌘⇧N, upstream's
    /// `chat.newLocal`); nil resolves the selected thread's project, then the
    /// sidebar's scope, then the top project — the resolution order upstream's
    /// `newThreadContext` uses (`:4247-4250`).
    func startNewThread(projectId: String? = nil) {
        guard let project = projectId ?? currentProjectId else { return }
        // ⌘N twice in the same project reopens the empty draft it already made
        // rather than stacking another "New thread" row — upstream never
        // stacks empty ones either (its rows exist only for drafts that HAVE
        // content, `Sidebar.tsx:781-784`).
        let draft = state.reusableDraftId(projectId: project, isUntouched: { self.draft(for: $0).isEmpty })
            ?? state.addDraft(projectId: project, now: now)
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
        // sidebar (`Sidebar.tsx:4247-4250` over `sortLogicalProjectsForSidebar`)
        // — `state.groups`, which carries that order, not `state.projects`.
        return state.groups.first?.members.first?.id ?? state.projects.first?.id
    }

    func retargetDraft(_ draftId: String, projectId: String) {
        state.retargetDraft(draftId, projectId: projectId)
        // The persisted entry names the project its row is rebuilt in
        // (`commit`), so a retargeted draft that is never typed into again
        // would otherwise come back in the project it left.
        if let draft = drafts[draftId] { commit(draft, for: draftId) }
    }

    /// Upstream's "Discard draft" (`Sidebar.tsx:756`). The typed prompt goes
    /// with it, or `workspace.drafts` keeps an entry no row can reach again.
    func discardDraft(_ draftId: String) {
        state.removeDraft(draftId, now: now)
        releaseStart(draftId)
        commit(T3ComposerDraft(), for: draftId)
        syncTimelineStore()
    }

    /// A draft's first send: the prompt starts the session (upstream's draft
    /// route promotes the draft to a real thread once the server answers,
    /// `_chat.draft.$draftId.tsx:38-65`). A refusal leaves the draft where it
    /// is, with its text, and says why through `draftStart.notes` — nothing
    /// typed is ever lost.
    func sendDraft(_ draftId: String, text: String, permissionMode: String?) {
        guard !isStarting(draftId) else {
            // Never silent: a swallowed call would leave the send button
            // spinning with nothing behind it.
            fail(draftId, "A session is already starting for this draft")
            return
        }
        guard let app = model, let draft = state.drafts.first(where: { $0.id == draftId }),
              let cwd = state.projects.first(where: { $0.id == draft.projectId })?.cwd else {
            fail(draftId, "This draft has no project folder to start in")
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
        if Self.noStart {
            Self.log.debug("workspace: SessionStart suppressed (INFINITUS_WORKSPACE_NO_START) cwd=\(cwd, privacy: .public) engine=claude promptChars=\(prompt.count, privacy: .public) permissionMode=\(permissionMode ?? "default", privacy: .public) headless=host-decided")
            fail(draftId, "Session start disabled in this build")
            return
        }
        draftStart.begin(draftId)
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
            await MainActor.run { self?.draftStarted(draftId, reply: reply, prompt: prompt) }
        }
    }

    private func draftStarted(_ draftId: String, reply: SessionStart.Reply, prompt: String) {
        guard reply.outcome == "started" else {
            fail(draftId, reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            return
        }
        // Only a prompt that actually started a session is worth recalling
        // with ↑ — a refused one is still sitting in the field.
        if !prompt.isEmpty { pushPromptHistory(prompt) }
        // The prompt is inside the session now; the stored draft must not come
        // back the next time this id is selected.
        commit(T3ComposerDraft(), for: draftId)
        guard let pid = reply.pid else {
            // A terminal host whose session has not registered yet
            // (SessionLauncher.swift:48-50). The prompt is gone either way, so
            // keeping the draft would invite starting it twice: drop it, and
            // the thread arrives on a later tick.
            state.removeDraft(draftId, now: now)
            releaseStart(draftId)
            syncTimelineStore()
            return
        }
        // The guard is NOT released here: the child can still die before its
        // record and facts reach the fleet, and a released guard plus a
        // remounted composer would let a second ⏎ start a second `claude`.
        // `reconcileDraftStarts` releases it when the reducer replaces the
        // draft — or when the start times out.
        state.markDraftStarted(draftId, pid: Int32(pid), now: Date())
        // The deadline is only ever evaluated inside `apply`, i.e. on a fleet
        // tick — and a fleet whose sessions are all idle can go a minute and a
        // half without one, leaving the send button spinning long past the 30 s
        // (B-5 review). One wake, no timer: it either finds the draft already
        // handed over (nothing to do) or runs the expiry.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(T3WorkspaceState.startDeadline + 1))
            self?.refresh()
        }
        // Don't wait for the 200 ms fleet debounce to notice the new pid.
        refresh()
    }

    /// Run after every `apply`: the reducer owns both endings — the draft is
    /// replaced by its thread, or its pending pid expires past
    /// `T3WorkspaceState.startDeadline`.
    private func reconcileDraftStarts() {
        for id in state.draftStartTimeouts {
            state.clearDraftStartTimeout(id)
            fail(id, "Session did not appear — try again")
        }
        // A draft that is no longer in the list was handed over or discarded.
        let live = Set(state.drafts.map(\.id))
        for id in draftStart.starting.subtracting(live) { draftStart.end(id) }
    }

    private func fail(_ draftId: String, _ message: String) {
        draftStart.end(draftId)
        draftStart.notes[draftId] = message
    }

    private func releaseStart(_ draftId: String) {
        draftStart.end(draftId)
        draftStart.notes[draftId] = nil
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

/// The drafts' start state (fix 1): which starts are in flight and what the
/// last refusal said, per draft id. Its own `ObservableObject` rather than
/// fields on `T3WindowModel` so the composer can observe it WITHOUT observing
/// the model — this publishes when a start begins or ends, never on a fleet
/// tick (the rule T3ThreadView.swift:37-41 sets for the whole window).
@MainActor
final class T3DraftStart: ObservableObject {
    @Published fileprivate(set) var starting: Set<String> = []
    @Published fileprivate var notes: [String: String] = [:]

    nonisolated init() {}

    fileprivate func begin(_ draftId: String) {
        notes[draftId] = nil
        starting.insert(draftId)
    }
    fileprivate func end(_ draftId: String) { starting.remove(draftId) }

    func isStarting(_ draftId: String) -> Bool { starting.contains(draftId) }
    func note(_ draftId: String) -> String? { notes[draftId] }
    func clearNote(_ draftId: String) { notes[draftId] = nil }
}
