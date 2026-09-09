import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The bottom slot (Task 12's banners, Task 13's composer) publishes its
/// measured height through this key; the timeline's footer inset is that height
/// plus 16 (`TimelineListFooter`'s `composerInset`,
/// `MessagesTimeline.tsx:616-619`). Until the slot has content its 0 leaves the
/// plain 16.
///
/// Preferences only flow UP, so the publisher has to live INSIDE `T3ThreadView`
/// — the slot is its `.overlay`, not a sibling in `T3Root`, and the reader is
/// attached to that overlay.
struct T3ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The messages wrapper's own box (`ChatView.tsx:7931`, `relative`): what the
/// scroll-to-end pill's `bottom` and the composer overlay's rects are measured
/// in. File scope because the pill lives outside `T3ThreadView`.
private let t3TimelineSpace = "t3-timeline"

/// The scrolling thread (`MessagesTimeline.tsx:822-884`): the row list in a
/// centred `max-w-3xl` column inside a `px-5` scroll area, with the header
/// spacer (`TIMELINE_LIST_HEADER`, `:246`) above and the composer inset below.
///
/// Not ported: `LegendList`'s virtualization knobs (a `LazyVStack` is the
/// platform equivalent), the titlebar scroll fade, the citation pins and
/// "load earlier" header — none has a model on B. (The minimap is ported:
/// `T3TimelineMinimapStrip`.)
///
/// Scroll anchoring is `timelineScrollAnchoring.ts`'s three modes:
/// `following-end` while the end is in view, `anchoring-new-turn` when a user
/// message arrives (its top lands `CHAT_TIMELINE_ANCHOR_OFFSET` = 24 below the
/// viewport top), and `free-scrolling` otherwise — plus the disclosure rule
/// upstream gets from `maintainVisibleContentPosition`: a fold that opens or
/// closes leaves the toggled row exactly where it was.
struct T3ThreadView: View {
    /// Both models are plain references on purpose: `AppModel` republishes on
    /// every fleet tick and `T3WindowModel` on every state change, and observing
    /// either here would re-run this body — and `Row ==` for every row — for
    /// changes the timeline does not read. The one value it needs, `now`, comes
    /// in as a value; the two toggles are calls, not reads.
    let model: T3WindowModel
    let app: AppModel
    @ObservedObject var store: T3TimelineStore
    /// `T3WindowModel.now`, passed down by `T3Root` (never `Date()`).
    let now: Date
    /// Set when the selected thread is a draft (Task 15): there is no
    /// transcript to scroll, so the view is the hero + the composer only.
    var draftTarget: T3ComposerDraftTarget?
    @Environment(\.t3) private var t3

    /// Row geometry, `atEnd` and the pending disclosure pin. A reference type
    /// held in `@State` so the per-scroll writes never republish the view.
    @State private var anchors = T3Anchors()
    @State private var composerHeight: CGFloat = 0
    /// `minimapItems` (`MessagesTimeline.tsx:576`), derived once per rows
    /// publish rather than per body pass — `now` re-renders this view every
    /// second and compacting every turn's text that often would be waste.
    @State private var minimapItems: [T3TimelineMinimap.Item] = []
    /// Task 12's delivery. `@State`, not `@StateObject`: `sending`/`note` flip on
    /// every verdict, and observing them here would re-run this body — and
    /// `Row ==` for every row — for something only the bottom slot draws. The
    /// slot observes it instead (`T3ThreadPendingSlot`).
    @State private var actions = T3ThreadActions()
    /// The draft hero's one-shot fade-in (`draftHeroTransition.ts:2-3`:
    /// 180 ms on `cubic-bezier(0.4, 0, 0.2, 1)`). One `withAnimation` on
    /// appear — never a repeating one.
    @State private var heroShown = false

    /// `max-w-3xl` (48 rem) inside the list's own `sm:px-5`.
    private static let columnMax: Double = 768
    private static let listInset: Double = 20
    private static let endId = "t3-timeline-end"

    var body: some View {
        if let draftTarget {
            draftHero(draftTarget)
        } else {
            timeline
        }
    }

    // MARK: - The draft hero (Task 15)

    /// `ChatView.tsx:8295-8329`'s draft-hero state: the composer overlay
    /// becomes `absolute inset-0 … flex items-center` — the card CENTRED in the
    /// column rather than docked at its bottom — with the headline pinned
    /// directly above it (`absolute inset-x-0 bottom-full` + `pb-8` = 32) and no
    /// timeline at all.
    private func draftHero(_ target: T3ComposerDraftTarget) -> some View {
        VStack(spacing: 32) {
            T3DraftHeroHeadline(projectName: projectName(target), groups: model.state.groups) { group in
                // The picker retargets the OPEN draft in place
                // (`DraftHeroHeadline.tsx:142-150`); a group's representative
                // member is the physical project it starts in.
                guard let id = group.members.first?.id else { return }
                model.retargetDraft(target.draftId, projectId: id)
            }
            VStack(spacing: 0) {
                T3DraftNoteSlot(draftStart: model.draftStart, draftId: target.draftId)
                T3ComposerView(model: model, app: app, store: store, actions: actions,
                               draftTarget: target, draftStart: model.draftStart)
                branchLine
            }
        }
        // The same column the rows and the docked composer share (`:8309`).
        .frame(maxWidth: Self.columnMax)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.listInset)
        .frame(maxHeight: .infinity)   // `items-center`
        .opacity(heroShown ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { heroShown = true }
        }
    }

    /// `activeProjectGroup?.displayName ?? activeProjectTitle`
    /// (`DraftHeroHeadline.tsx:106`): the logical group's name when the project
    /// belongs to one, else the project's own.
    private func projectName(_ target: T3ComposerDraftTarget) -> String? {
        if let group = model.state.groups.first(where: { $0.members.contains { $0.id == target.projectId } }) {
            return group.displayName
        }
        return model.state.projects.first { $0.id == target.projectId }?.name
    }

    // MARK: - The timeline

    private var timeline: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // `TIMELINE_LIST_FADE_HEADER` (`:247`):
                        // `--workspace-titlebar-scroll-fade-height` (1.5 rem,
                        // index.css:114). `ChatView.tsx:8267` passes
                        // `topFadeEnabled={!hasTimelineTopBanner}`, so this is
                        // the ordinary header — `TIMELINE_LIST_HEADER`'s
                        // `h-3 sm:h-4` (16) belongs to the banner state, which
                        // this window has no timeline slot for. (The fade mask
                        // itself is in the not-ported list above.)
                        Color.clear.frame(height: 24)
                        // Hoisted out of the row closure: `rows.last(where:)`
                        // is O(n) and was running once PER row (O(n^2) over
                        // the timeline) to answer the same question every time.
                        let latestPlanRowId = store.rows.last(where: { $0.kind == "proposed-plan" })?.id
                        ForEach(store.rows) { row in
                            T3TimelineRowView(row: row,
                                              columnWidth: min(Self.columnMax, geo.size.width - 2 * Self.listInset),
                                              now: now,
                                              planIsActionable: planIsActionable && row.id == latestPlanRowId,
                                              onToggleTurn: { turnId in toggle(rowId: row.id) { model.toggleTurn(turnId) } },
                                              onToggleWorkGroup: { groupId in toggle(rowId: row.id) { model.toggleWorkGroup(groupId) } },
                                              onImplementPlan: implementPlan,
                                              onEditPlan: { markdown in model.pendingComposerInsert = markdown })
                                .equatable()
                                .frame(maxWidth: Self.columnMax)
                                .frame(maxWidth: .infinity)   // `mx-auto`
                                .id(row.id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { rect in
                                    anchors.rows[row.id] = rect
                                }
                        }
                        // `ListFooterComponent` (`:883`): the composer inset.
                        Color.clear
                            .frame(height: composerHeight + 16)
                            .id(Self.endId)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { rect in
                                // `resolveTimelineIsAtEnd`'s
                                // `maintainScrollAtEndThreshold` of 1 px, as the
                                // bottom sentinel: the end is in view.
                                anchors.atEnd = rect.maxY <= anchors.viewport.height + 2
                                // `showScrollToBottom` (`ChatView.tsx:8272`).
                                // This fires on every scrolled frame, so the
                                // publish happens on the FLIP only — the pill
                                // is the sole observer and nothing else may
                                // re-render per frame.
                                anchors.setScrolledAway(!anchors.atEnd)
                            }
                    }
                    .padding(.horizontal, Self.listInset)
                    // The minimap's current turn, once per scrolled frame
                    // (upstream's `handleScroll`, `MessagesTimeline.tsx:657`).
                    // NOT on the footer sentinel that `atEnd` rides: a
                    // `LazyVStack` unmounts it once the reader is away from the
                    // end, which is exactly when the minimap has work to do.
                    // The list's own box always exists and its `.scrollView`
                    // minY moves with every frame. Publishing happens on the
                    // FLIP only (`T3Anchors.updateMinimap`).
                    .onGeometryChange(for: Double.self) { $0.frame(in: .scrollView).minY } action: { _ in
                        anchors.scheduleMinimapUpdate()
                    }
                }
                .onChange(of: store.rows) { old, new in anchor(old: old, new: new, proxy: proxy) }
                // The drawer mounting/growing moves the footer sentinel
                // without touching `store.rows` — re-follow the end so the
                // scroll doesn't settle against the drawer's PREVIOUS height.
                .onChange(of: composerHeight) { _, _ in
                    // Never over a pending disclosure pin — `anchor(old:new:)`
                    // owns that restore on the next rows publish.
                    if anchors.atEnd, anchors.pinned == nil { proxy.scrollTo(Self.endId, anchor: .bottom) }
                }
                .onAppear {
                    refreshMinimap(store.rows)
                    guard !store.rows.isEmpty else { return }
                    DispatchQueue.main.async { proxy.scrollTo(Self.endId, anchor: .bottom) }
                }
                .overlay { if store.rows.isEmpty { empty } }
                // `ChatView.tsx:8296-8302`: the composer wrapper is
                // `absolute inset-x-0 bottom-0 z-20` over the messages wrapper
                // (`:8221`, `relative flex min-h-0 flex-1`) — the timeline runs
                // full height and scrolls UNDER it, which is what the footer
                // inset reserves room for. So: an overlay, not a stacked row.
                .overlay(alignment: .bottom) { bottomSlot }
                // `:8271-8291`, `z-30` over the composer overlay's `z-20`, so
                // the second overlay. An empty timeline has no end to scroll
                // to (`:8272`'s own `hideEmptyPlaceholder` state).
                .overlay(alignment: .bottom) {
                    if !store.rows.isEmpty {
                        T3ScrollToEndPill(anchors: anchors) {
                            anchors.atEnd = true
                            anchors.setScrolledAway(false)
                            withAnimation { proxy.scrollTo(Self.endId, anchor: .bottom) }
                        }
                    }
                }
                // `:885-897`, `z-40` — over the composer overlay and the
                // pill, so the last overlay of the three.
                .overlay(alignment: .leading) {
                    T3TimelineMinimapStrip(anchors: anchors, items: minimapItems,
                                           viewport: geo.size) { item in
                        // `onSelect` (`:891-896`): `scrollToIndex` with
                        // `viewOffset: 24`, the anchor offset a new turn gets.
                        // `onManualNavigation()` is the follow mode it clears,
                        // which here is the end-follow flag.
                        anchors.atEnd = false
                        // Twice, for the reason the disclosure pin restores
                        // asynchronously: a `LazyVStack` only estimates a row it
                        // has not mounted, so the first hop lands on that
                        // estimate and mounts the target, and the second puts it
                        // 24 below the viewport top with the measured frames.
                        // (One of the last turns lands as close as the content
                        // allows — the scroll clamps at the end, as upstream's
                        // does. Upstream's `animated: true` is skipped:
                        // animating the pair shows the correction, not the
                        // jump.)
                        scroll(proxy, to: item.id, top: 24)
                        DispatchQueue.main.async { scroll(proxy, to: item.id, top: 24) }
                    }
                }
                // Both overlays measure into this one space: the pill's
                // clearance is a distance between their boxes.
                .coordinateSpace(name: t3TimelineSpace)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { anchors.viewport = $0 }
    }

    /// The composer overlay's slot. Empty until Tasks 12/13 fill it; its height
    /// is what the timeline's footer reserves, published as
    /// `T3ComposerHeightKey` so the children need no plumbing of their own.
    private var bottomSlot: some View {
        VStack(spacing: 0) {
            T3ThreadPendingSlot(app: app, store: store, actions: actions)
                // `[data-composer-banner-surface="attached"]` (`:5327`): the
                // drawers the pill has to clear. This port stacks them in one
                // full-width column, so the group is one box.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(t3TimelineSpace)) } action: {
                    anchors.drawers = $0
                    anchors.updateScrollToEndClearance()
                }
            // The composer under the drawers, sharing this view's `actions` —
            // one sender per thread (`T3ThreadActions`' `sending` guard), so a
            // verdict and a message can never race.
            T3ComposerView(model: model, app: app, store: store, actions: actions,
                           draftStart: model.draftStart)
                // `[data-chat-composer-main-surface="true"]` (`:5313`).
                .onGeometryChange(for: Double.self) { $0.frame(in: .named(t3TimelineSpace)).minY } action: {
                    anchors.composerTop = $0
                    anchors.updateScrollToEndClearance()
                }
            // `ChatView.tsx:8460-8473`: the context strip sits in the same
            // floating column, directly under the card — so it is inside the
            // slot whose height the timeline's footer reserves.
            branchLine
        }
        // `:8307` `sm:ps/pe 1.25rem` (the list's own inset) and `:8309`
        // `mx-auto w-full max-w-3xl` — the slot shares the rows' column so
        // whatever lands in it lines up with them. `pointer-events-auto`
        // there too, so no `allowsHitTesting(false)` here.
        .frame(maxWidth: Self.columnMax)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.listInset)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: T3ComposerHeightKey.self, value: geo.size.height)
            }
        }
        .onPreferenceChange(T3ComposerHeightKey.self) {
            composerHeight = $0
            // `publishComposerOverlayHeight` (`:5290-5330`) feeds the timeline
            // inset AND the pill's clearance from the same measurement.
            anchors.overlayHeight = $0
            anchors.updateScrollToEndClearance()
        }
    }

    /// The strip only exists where there is a folder to name: the selected
    /// thread's project, or the draft's target project.
    @ViewBuilder private var branchLine: some View {
        if let target = draftTarget {
            if let cwd = model.state.projects.first(where: { $0.id == target.projectId })?.cwd {
                T3BranchLine(cwd: cwd, threadId: target.draftId, model: model)
            }
        // `selectedThread`, not `threads`: an ended thread (#400) is off the
        // live list but still open, and its project still names the folder.
        } else if let thread = model.state.selectedThread, thread.id == store.threadId,
                  let cwd = model.state.projects.first(where: { $0.id == thread.projectId })?.cwd {
            T3BranchLine(cwd: cwd, threadId: thread.id, model: model)
        }
    }

    /// `:814-818`: `rows.length === 0 && !isWorking` — a working turn always
    /// contributes its own row, so an empty row list is the whole condition.
    private var empty: some View {
        Text("Send a message to start the conversation.")
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.placeholder.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The proposed plan's actions

    /// A plan can be implemented only while its `ExitPlanMode` is the prompt the
    /// session is parked on: `.key "1"` answers `pending(pid:).first`
    /// (OwnedSessions.swift:445), so a plan behind another approval must not
    /// offer the button — it would approve the wrong tool.
    private var planIsActionable: Bool {
        // An ended session (#400) has no one to answer the parked prompt.
        !store.gone && store.pending.approvals.first?.toolName == "ExitPlanMode"
    }

    /// …and only on ONE card: the parked prompt belongs to the newest plan, so
    /// an older card's Implement would approve someone else's `ExitPlanMode`.
    /// Upstream picks the same single plan — `activeProposedPlan`
    /// (`ChatView.tsx:2782-2790`) is `findLatestProposedPlan`
    /// (`session-logic.ts:352-375`), the latest turn's newest plan — and only
    /// that one drives the composer's Implement. (Which row that is: hoisted
    /// into `body` as `latestPlanRowId`, above the `ForEach`.)

    /// `ProposedPlanCard`'s Approve, upstream's "Implement"
    /// (`ComposerPrimaryActions.tsx:192`): allow the parked `ExitPlanMode` the
    /// way every other approval is allowed (SessionChatWindow.swift:303).
    private func implementPlan() {
        guard planIsActionable else { return }
        actions.send(.init(kind: .key, text: "1"), app: app, pid: store.pid)
    }

    // MARK: - Anchoring

    /// A disclosure toggle: record where the row sits, then let the reducer
    /// re-derive (`onToggleTurnFold`/`onToggleWorkGroup` + `store.rederive()`).
    private func toggle(rowId: String, _ mutate: () -> Void) {
        anchors.pinned = (rowId, Double(anchors.rows[rowId]?.minY ?? 0))
        let idsBefore = store.rows.map(\.id)
        mutate()
        store.rederive()
        // `anchors.pinned` is set above, before the toggle mutates — if
        // `rederive()` yields identical rows there is no `store.rows`
        // change to consume the pin, and the stale pin hijacks the next
        // unrelated rows change instead.
        if store.rows.map(\.id) == idsBefore { anchors.pinned = nil }
    }

    private func anchor(old: [T3TimelineRows.Row], new: [T3TimelineRows.Row], proxy: ScrollViewProxy) {
        // Row frames are written per scrolled frame and never removed on their
        // own: drop the ids this re-derive folded away, or a long thread's
        // dictionary only grows. (`previous` below is the *old* id set — a
        // different question: which rows are new.)
        let ids = Set(new.map(\.id))
        anchors.rows = anchors.rows.filter { ids.contains($0.key) }
        refreshMinimap(new)
        guard !new.isEmpty else { return }
        if let pinned = anchors.pinned {
            anchors.pinned = nil
            // The new row heights are only measured after this layout pass.
            DispatchQueue.main.async { scroll(proxy, to: pinned.0, top: pinned.1) }
            return
        }
        let previous = Set(old.map(\.id))
        if !old.isEmpty, let turn = new.last(where: { isNewUserMessage($0, previous: previous) }) {
            DispatchQueue.main.async { scroll(proxy, to: turn.id, top: 24) }
            return
        }
        if old.isEmpty || anchors.atEnd {
            DispatchQueue.main.async { proxy.scrollTo(Self.endId, anchor: .bottom) }
        }
    }

    /// `deriveTimelineMinimapItems` + the row-index map the per-frame current
    /// turn is resolved against (`T3Anchors.updateMinimap`).
    private func refreshMinimap(_ rows: [T3TimelineRows.Row]) {
        let items = T3TimelineMinimap.items(rows: rows)
        anchors.setMinimapItems(items, rows: rows)
        if minimapItems != items { minimapItems = items }
    }

    private func isNewUserMessage(_ row: T3TimelineRows.Row, previous: Set<String>) -> Bool {
        guard case let .message(id, _, message, _, _, _, _, _, _) = row else { return false }
        return message.role == .user && !previous.contains(id)
    }

    /// Puts the row's top `top` points below the viewport top.
    /// `scrollTo(id, anchor:)` aligns the row's own point at fraction `f` of
    /// its height with the viewport's point at the same fraction, which leaves
    /// the row's top at `f · (viewport − rowHeight)` — so the offset upstream
    /// passes as `viewOffset` is that ratio here. A row taller than the
    /// viewport can only sit at its top.
    private func scroll(_ proxy: ScrollViewProxy, to id: String, top: Double) {
        let height = anchors.rows[id]?.height ?? 0
        let slack = anchors.viewport.height - height
        let fraction = slack > 1 ? min(1, max(0, top / slack)) : 0
        proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: fraction))
    }
}

/// The draft hero's banner slot: `T3ThreadPendingSlot` is the live thread's
/// (it reads the store's pending requests, which a draft has none of), and
/// `T3ThreadView` deliberately observes neither the model nor `actions`
/// (T3ThreadView.swift:56) — so a refused (or timed-out) `SessionStart` gets
/// this small observer of its own, over the model's own start state.
private struct T3DraftNoteSlot: View {
    @ObservedObject var draftStart: T3DraftStart
    let draftId: String

    var body: some View {
        T3BannerStack(items: draftStart.note(draftId).map { note in
            [T3BannerItem.error(id: "session-start", message: note,
                                dismiss: { draftStart.clearNote(draftId) })]
        } ?? [])
        // The hero's drawer column is the same `ComposerBanner.Dock`
        // attachment as the thread's (`ComposerBanner.tsx:111`, `:122`).
        .padding(.horizontal, t3DrawerInset)
    }
}

/// Scroll bookkeeping outside SwiftUI's invalidation: row frames arrive on
/// every scrolled frame, and republishing them would re-render the list.
///
/// It is an `ObservableObject` for the scroll-to-end pill alone, which is the
/// only view that holds it as an `@ObservedObject`; `T3ThreadView` keeps it in
/// plain `@State`, which does NOT observe. Only the two `@Published` members
/// below are ever published, and only when they change — everything else here
/// is written per frame.
@MainActor final class T3Anchors: ObservableObject {
    /// Viewport-relative row frames (`.scrollView` coordinate space).
    var rows: [String: CGRect] = [:]
    var viewport: CGSize = .zero
    var atEnd = true
    /// `(rowId, its viewport-relative top)` recorded before a disclosure toggle.
    var pinned: (String, Double)?

    /// The minimap's published position: which turn the reader is on and which
    /// turns are on screen (`minimapCurrentIndex`, `MessagesTimeline.tsx:598`,
    /// and the strips' `data-in-view`, `:684`). ONE value so a scroll that
    /// changes both publishes once.
    struct MinimapPosition: Equatable {
        var currentIndex: Int?
        var inView: Set<Int> = []
    }
    @Published private(set) var minimap = MinimapPosition()

    /// `deriveTimelineMinimapItems`' result and `id → row index` for every row,
    /// both refreshed per rows publish so the per-frame work stays O(items).
    private var minimapItems: [T3TimelineMinimap.Item] = []
    private var rowIndexById: [String: Int] = [:]
    private var minimapUpdatePending = false

    /// `showScrollToBottom` (`ChatView.tsx:1593`). Upstream debounces the SHOW
    /// by 150 ms to ride out a thread switch (`:4714-4716`); here the flip is
    /// driven by the footer sentinel's own geometry, which never reports a
    /// settling list, so there is no timer.
    @Published private(set) var scrolledAway = false
    /// `scrollToEndClearance` (`:1682`).
    @Published private(set) var scrollToEndClearance: Double = 0

    /// The clearance's inputs, in the timeline's own coordinate space.
    var overlayHeight: Double = 0
    var composerTop: Double = 0
    var drawers: CGRect = .zero
    /// `nil` until the pill has been laid out once. The drawers report their
    /// boxes first, and a pill span of `0...0` would read as "no drawer is
    /// under it" — the subtraction would fire and the first frame would land a
    /// drawer's height too low, then jump. Unbounded means every drawer counts
    /// as under it, which is the settled answer here anyway.
    var pill: ClosedRange<Double>?

    func setScrolledAway(_ value: Bool) {
        if scrolledAway != value { scrolledAway = value }
    }

    func setMinimapItems(_ items: [T3TimelineMinimap.Item], rows: [T3TimelineRows.Row]) {
        minimapItems = items
        rowIndexById = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        if items.isEmpty, minimap != MinimapPosition() { minimap = MinimapPosition() }
        scheduleMinimapUpdate()
    }

    /// The row frames of a layout pass are written by the rows themselves, and
    /// the list's own geometry action can run before them — reading straight
    /// through would answer with the PREVIOUS pass's frames, and at rest
    /// (a thread that just opened at its end) nothing would ever ask again.
    /// So the answer is deferred by one runloop turn, coalesced to at most one
    /// per turn: upstream's `requestAnimationFrame(handleScroll)`
    /// (`MessagesTimeline.tsx:704-707`), which exists for the same reason.
    func scheduleMinimapUpdate() {
        guard !minimapUpdatePending else { return }
        minimapUpdatePending = true
        DispatchQueue.main.async { [self] in
            minimapUpdatePending = false
            updateMinimap()
        }
    }

    /// `handleScroll`'s minimap half (`MessagesTimeline.tsx:663-700`), run once
    /// per scrolled frame and published only on a change.
    ///
    /// Upstream asks `LegendList` for any row's position; a `LazyVStack` only
    /// mounts what is near the screen, so an off-screen turn has no live frame —
    /// its last one is from when it left the viewport and goes stale after a
    /// jump. So a frame is trusted only while it intersects the viewport (which
    /// is `inView` itself); every other turn is placed above or below by its row
    /// index against the topmost mounted row, which is what upstream's
    /// `positionAtIndex` would have said in sign.
    private func updateMinimap() {
        guard !minimapItems.isEmpty else { return }
        let height = viewport.height
        guard height > 0 else { return }
        var topMounted = Int.max
        for (id, rect) in rows where rect.minY < height && rect.maxY > 0 {
            if let index = rowIndexById[id], index < topMounted { topMounted = index }
        }
        // Before the first layout nothing is mounted; leave the last answer be
        // rather than reading every turn as above the viewport.
        guard topMounted != Int.max else { return }
        var bounds: [T3TimelineMinimap.ItemBounds] = []
        var inView: Set<Int> = []
        bounds.reserveCapacity(minimapItems.count)
        for (index, item) in minimapItems.enumerated() {
            if let rect = rows[item.id], rect.minY < height, rect.maxY > 0 {
                bounds.append(.init(top: rect.minY, height: rect.height))
                inView.insert(index)
            } else {
                bounds.append(.init(top: item.rowIndex < topMounted ? -1 : height + 1, height: 1))
            }
        }
        let next = MinimapPosition(currentIndex: T3TimelineMinimap.currentIndex(scrollTop: 0,
                                                                               scrollBottom: height,
                                                                               itemBounds: bounds),
                                   inView: inView)
        if minimap != next { minimap = next }
    }

    /// `publishComposerOverlayHeight`'s clearance branch (`:5312-5329`).
    func updateScrollToEndClearance() {
        // One box, not one per banner: this port stacks every attached drawer
        // in a single full-width column (`T3ThreadPendingSlot`), so the group
        // always spans the pill and the clearance always resolves to the whole
        // overlay height. The call stays honest about that rather than
        // hard-coding it — a drawer docked beside the composer, which upstream
        // has and this port does not, is the case the subtraction exists for.
        let attachments = drawers.height > 0
            ? [T3ComposerFooterLayout.Attachment(top: drawers.minY, left: drawers.minX, right: drawers.maxX)]
            : []
        let next = T3ComposerFooterLayout.scrollToEndClearance(overlayHeight: overlayHeight,
                                                              mainSurfaceTop: composerTop,
                                                              buttonLeft: pill?.lowerBound ?? -.infinity,
                                                              buttonRight: pill?.upperBound ?? .infinity,
                                                              attachments: attachments)
        if scrollToEndClearance != next { scrollToEndClearance = next }
    }
}

/// The scroll-to-end pill (`ChatView.tsx:8271-8291`): an `xs` glass button,
/// `rounded-full px-3 gap-1.5` with a `size-3.5` chevron, `text-muted-foreground
/// hover:text-foreground`, in a `py-1.5` wrapper the clearance lifts to
/// `bottom: clearance + 4` — the rule the upstream fix is about, so the pill
/// stays against the composer instead of drifting with the overlay's box.
///
/// Shown only while the reader is away from the live edge, so a thread at its
/// end — every capture the harness takes — draws nothing.
private struct T3ScrollToEndPill: View {
    @ObservedObject var anchors: T3Anchors
    let onTap: () -> Void
    @Environment(\.t3) private var t3
    @State private var hover = false

    var body: some View {
        if anchors.scrolledAway {
            Button(action: onTap) {
                HStack(spacing: 6) {   // `gap-1.5`
                    LucideIcon(.chevronDown, size: 14)   // `size-3.5`
                    // `xs`'s `sm:text-xs` over the base's `font-medium`.
                    Text("Scroll to end").font(T3Font.web(.xs, .medium))
                }
                // `text-muted-foreground hover:text-foreground`.
                .foregroundStyle(hover ? t3.web.foreground.color : t3.web.mutedForeground.color)
                .padding(.horizontal, 12)   // `px-3`, over `xs`'s own padding
                .frame(height: T3ButtonMetrics.height(.xs))
                // `variant="glass"`: `surface-glass` is `--background` at
                // `--glass-opacity` behind a backdrop blur (index.css:260-264),
                // and this window has no CABackdropLayer host — a flat fill,
                // the same call `T3ComposerView` makes for its own surface
                // (T3ComposerView.swift:149-152).
                .background(t3.web.background.color, in: Capsule())
                // `border-border/60 [:hover]:border-border`.
                .overlay(Capsule().stroke(t3.web.border.color.opacity(hover ? 1 : 0.6), lineWidth: 1))
                // `shadow-sm`: `0 1px 3px 0 rgb(0 0 0 / 0.1)`.
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityLabel("Scroll to end")
            // The pill's own span, which decides whether a drawer is in its
            // way. Horizontal only: reading its `y` here would feed the
            // clearance back into the padding that sets it.
            .onGeometryChange(for: ClosedRange<Double>.self) { proxy in
                let frame = proxy.frame(in: .named(t3TimelineSpace))
                return frame.minX...max(frame.minX, frame.maxX)
            } action: {
                anchors.pill = $0
                anchors.updateScrollToEndClearance()
            }
            .padding(.vertical, 6)   // `py-1.5`
            .padding(.bottom, anchors.scrollToEndClearance + 4)
        }
    }
}

