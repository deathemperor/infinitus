import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The bottom slot (Task 12's banners, Task 13's composer) publishes its
/// measured height through this key; the timeline's footer inset is that height
/// plus 16 (`TimelineListFooter`'s `composerInset`,
/// `MessagesTimeline.tsx:609-612`). Until the slot has content its 0 leaves the
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

/// The scrolling thread (`MessagesTimeline.tsx:803-865`): the row list in a
/// centred `max-w-3xl` column inside a `px-5` scroll area, with the header
/// spacer (`TIMELINE_LIST_HEADER`, `:240`) above and the composer inset below.
///
/// Not ported: `LegendList`'s virtualization knobs (a `LazyVStack` is the
/// platform equivalent), the minimap, the titlebar scroll fade, the citation
/// pins and "load earlier" header — none has a model on B.
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

    /// `ChatView.tsx:8005-8039`'s draft-hero state: the composer overlay
    /// becomes `absolute inset-0 … flex items-center` — the card CENTRED in the
    /// column rather than docked at its bottom — with the headline pinned
    /// directly above it (`absolute inset-x-0 bottom-full` + `pb-8` = 32) and no
    /// timeline at all.
    private func draftHero(_ target: T3ComposerDraftTarget) -> some View {
        VStack(spacing: 32) {
            T3DraftHeroHeadline(projectName: projectName(target), groups: model.state.groups) { group in
                // The picker retargets the OPEN draft in place
                // (`DraftHeroHeadline.tsx:141-149`); a group's representative
                // member is the physical project it starts in.
                guard let id = group.members.first?.id else { return }
                model.retargetDraft(target.draftId, projectId: id)
            }
            VStack(spacing: 0) {
                T3DraftNoteSlot(draftStart: model.draftStart, draftId: target.draftId)
                T3ComposerView(model: model, app: app, store: store, actions: actions,
                               draftTarget: target, draftStart: model.draftStart)
            }
        }
        // The same column the rows and the docked composer share (`:8019`).
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
    /// (`DraftHeroHeadline.tsx:105`): the logical group's name when the project
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
                        // `TIMELINE_LIST_HEADER` (`:240`): `h-3 sm:h-4`.
                        Color.clear.frame(height: 16)
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
                        // `ListFooterComponent` (`:864`): the composer inset.
                        Color.clear
                            .frame(height: composerHeight + 16)
                            .id(Self.endId)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { rect in
                                // `resolveTimelineIsAtEnd`'s
                                // `maintainScrollAtEndThreshold` of 1 px, as the
                                // bottom sentinel: the end is in view.
                                anchors.atEnd = rect.maxY <= anchors.viewport.height + 2
                            }
                    }
                    .padding(.horizontal, Self.listInset)
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
                    guard !store.rows.isEmpty else { return }
                    DispatchQueue.main.async { proxy.scrollTo(Self.endId, anchor: .bottom) }
                }
                .overlay { if store.rows.isEmpty { empty } }
                // `ChatView.tsx:8006-8012`: the composer wrapper is
                // `absolute inset-x-0 bottom-0 z-20` over the messages wrapper
                // (`:7931`, `relative flex min-h-0 flex-1`) — the timeline runs
                // full height and scrolls UNDER it, which is what the footer
                // inset reserves room for. So: an overlay, not a stacked row.
                .overlay(alignment: .bottom) { bottomSlot }
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
            // The composer under the drawers, sharing this view's `actions` —
            // one sender per thread (`T3ThreadActions`' `sending` guard), so a
            // verdict and a message can never race.
            T3ComposerView(model: model, app: app, store: store, actions: actions,
                           draftStart: model.draftStart)
        }
        // `:8017` `sm:ps/pe 1.25rem` (the list's own inset) and `:8019`
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
        .onPreferenceChange(T3ComposerHeightKey.self) { composerHeight = $0 }
    }

    /// `:795-799`: `rows.length === 0 && !isWorking` — a working turn always
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
        store.pending.approvals.first?.toolName == "ExitPlanMode"
    }

    /// …and only on ONE card: the parked prompt belongs to the newest plan, so
    /// an older card's Implement would approve someone else's `ExitPlanMode`.
    /// Upstream picks the same single plan — `activeProposedPlan`
    /// (`ChatView.tsx:2625-2633`) is `findLatestProposedPlan`
    /// (`session-logic.ts:349-372`), the latest turn's newest plan — and only
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
    }
}

/// Scroll bookkeeping outside SwiftUI's invalidation: row frames arrive on
/// every scrolled frame, and republishing them would re-render the list.
@MainActor final class T3Anchors {
    /// Viewport-relative row frames (`.scrollView` coordinate space).
    var rows: [String: CGRect] = [:]
    var viewport: CGSize = .zero
    var atEnd = true
    /// `(rowId, its viewport-relative top)` recorded before a disclosure toggle.
    var pinned: (String, Double)?
}

