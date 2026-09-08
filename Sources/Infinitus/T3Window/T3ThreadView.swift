import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// Task 13's composer publishes its measured height through this key; the
/// timeline's footer inset is that height plus 16 (`TimelineListFooter`'s
/// `composerInset`, `MessagesTimeline.tsx:609-612`). Until the composer lands
/// the default 0 leaves the plain 16.
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
    @ObservedObject var model: T3WindowModel
    /// Held as a plain reference on purpose: `AppModel` republishes on every
    /// fleet tick, and observing it here would re-render every row.
    let app: AppModel
    @ObservedObject var store: T3TimelineStore
    @Environment(\.t3) private var t3

    /// Row geometry, `atEnd` and the pending disclosure pin. A reference type
    /// held in `@State` so the per-scroll writes never republish the view.
    @State private var anchors = T3Anchors()
    @State private var composerHeight: CGFloat = 0

    /// `max-w-3xl` (48 rem) inside the list's own `sm:px-5`.
    private static let columnMax: Double = 768
    private static let listInset: Double = 20
    private static let endId = "t3-timeline-end"

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // `TIMELINE_LIST_HEADER` (`:240`): `h-3 sm:h-4`.
                        Color.clear.frame(height: 16)
                        ForEach(store.rows) { row in
                            T3TimelineRowView(row: row,
                                              columnWidth: min(Self.columnMax, geo.size.width - 2 * Self.listInset),
                                              now: model.now,
                                              onToggleTurn: { turnId in toggle(rowId: row.id) { model.toggleTurn(turnId) } },
                                              onToggleWorkGroup: { groupId in toggle(rowId: row.id) { model.toggleWorkGroup(groupId) } })
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
                .onAppear {
                    guard !store.rows.isEmpty else { return }
                    DispatchQueue.main.async { proxy.scrollTo(Self.endId, anchor: .bottom) }
                }
                .overlay { if store.rows.isEmpty { empty } }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { anchors.viewport = $0 }
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

    // MARK: - Anchoring

    /// A disclosure toggle: record where the row sits, then let the reducer
    /// re-derive (`onToggleTurnFold`/`onToggleWorkGroup` + `store.rederive()`).
    private func toggle(rowId: String, _ mutate: () -> Void) {
        anchors.pinned = (rowId, Double(anchors.rows[rowId]?.minY ?? 0))
        mutate()
        store.rederive()
    }

    private func anchor(old: [T3TimelineRows.Row], new: [T3TimelineRows.Row], proxy: ScrollViewProxy) {
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
