import SwiftUI
import Combine
import InfinitusCore

/// The workspace window's model (spec §4.3): one `T3WorkspaceState`
/// republished on every fleet tick. Reads ride `SessionProgressModel`'s
/// publishers — no timer of its own; the only clock is the 60 s
/// relative-time tick the controller runs while the window is key.
@MainActor
final class T3WindowModel: ObservableObject {
    @Published private(set) var state = T3WorkspaceState()
    /// The instant labels are computed against; refreshed on publish and
    /// by the key-window tick. Views read this, never `Date()`.
    @Published private(set) var now = Date()
    @Published var focusedScreen: String?
    private(set) weak var model: AppModel?
    private var sink: AnyCancellable?
    private var refreshing = false
    /// Task 13's composer focuses its field when this flips true, then clears it.
    @Published var composerFocusRequested = false

    /// `show workspace <screen>` (Task 5 interface): select the first thread when
    /// nothing is selected; `composer` also asks for field focus. One-shot.
    private func applyFocusedScreen(_ screen: String) {
        focusedScreen = nil
        if state.selectedThreadId == nil, let first = state.sidebarSections(now: now).first?.threads.first {
            state.select(first.id, now: now)
        }
        if screen == "composer" { composerFocusRequested = true }
    }

    init(model: AppModel) { self.model = model }

    func start() {
        guard sink == nil, let model else { return }
        sink = model.sessionProgress.$facts.combineLatest(model.sessionProgress.$byPid)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refresh() }
        refresh()
    }

    func stop() { sink = nil }

    func tick() { now = Date() }

    private func refresh() {
        guard let model, !refreshing else { return }
        refreshing = true
        let facts = model.sessionProgress.facts, progress = model.sessionProgress.byPid
        let profiles = model.sessionProfiles.profiles
        // `projectSummaries(profiles:)` memoizes its PastSessions walk itself
        // (#369: 60 s, keyed on the live session set) — call it, never wrap
        // it in a second cache (that doubles the cost the memo removed).
        Task.detached(priority: .utility) { [weak self] in
            let records = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
            let projects = model.projectSummaries(profiles: profiles)
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
                let now = Date()
                self.now = now
                self.state.apply(inputs, now: now)
                if let screen = self.focusedScreen { self.applyFocusedScreen(screen) }
                self.refreshing = false
            }
        }
    }

    func select(_ threadId: String?) { state.select(threadId, now: now) }
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
        let request = SessionAttention.Request(action: action, until: until, commandId: UUID().uuidString)
        let timelineCache = model.timelineCache, attentionStore = model.attentionStore, ownedBox = model.ownedBox
        Task.detached(priority: .userInitiated) {
            _ = AppModel.applyAttention(pid: pid, request, timelineCache: timelineCache,
                                        attentionStore: attentionStore, ownedBox: ownedBox)
        }
    }
}
