import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The thread's terminal drawer — upstream's `ThreadTerminalDrawer` in the
/// `mode="drawer"` it defaults to (`:1051`, `:1425-1440` at 6c583620f): a
/// bottom row under the thread, `shrink-0 border-t border-border/80` at a
/// dragged height, holding the SAME surface the right panel's Terminal tab
/// mounts (`T3TerminalSurfaceView`).
///
/// Where it sits: upstream's chat column is a `flex-col` of the top bar, the
/// main content area (the timeline with the composer overlaid on it) and then
/// the drawers (`ChatView.tsx:8129-8131`, the mount at `:8578-8597`) — so the
/// drawer is a sibling row UNDER the composer, not a second overlay over the
/// timeline. Nothing about `T3ComposerFooterLayout` changes with it: the
/// composer's own overlay height is what the timeline's footer reserves, and
/// the drawer takes its band out of the column instead.
///
/// One shell set, two places to see it: both mounts resolve the same
/// `T3TerminalGroup` per (cwd, pid) through `T3TerminalRegistry`, and only the
/// newest-claimed surface draws it (`T3TerminalDrawer.Presenters`).

/// The open flag and the height, per thread, persisted — upstream's
/// `terminalOpen` / `terminalHeight` in `terminalUiStateStore`
/// (`apps/web/src/terminalUiStateStore.ts:20-27`), which is `localStorage`-backed
/// under `t3code:terminal-state:v1` (`:30`). Here: one `[threadId: State]` JSON
/// blob under `workspace.terminalDrawer`, written at most once per burst — the
/// shape `workspace.lastVisitedAt` uses.
///
/// An `ObservableObject` of its own rather than a member of `T3WorkspaceState`:
/// `T3ThreadView` deliberately observes neither `T3WindowModel` nor `AppModel`
/// (T3ThreadView.swift:43-47), so only the drawer's own slot and the top bar's
/// toggle observe this.
@MainActor
final class T3TerminalDrawerModel: ObservableObject {
    @Published private(set) var states: [String: T3TerminalDrawer.State]

    private static let key = "workspace.terminalDrawer"
    private var persist: Task<Void, Never>?

    init() {
        states = T3TerminalDrawer.load(from: UserDefaults.standard.data(forKey: Self.key))
    }

    /// `selectThreadTerminalUiState` (`terminalUiStateStore.ts:487-497`): a
    /// thread with no entry reads as the default state.
    func state(_ threadId: String) -> T3TerminalDrawer.State {
        states[threadId] ?? .none
    }

    func isOpen(_ threadId: String) -> Bool { state(threadId).open }

    /// `toggleTerminalVisibility` (`ChatView.tsx:3623-3665`) minus the open of a
    /// first terminal: `T3TerminalGroup.appear(as:)` already opens (or re-lists)
    /// the session's shells the moment a surface mounts, which is the same thing
    /// upstream's `openTerminal` call does for its zero-terminal case.
    func toggle(_ threadId: String) {
        var next = state(threadId)
        next.open.toggle()
        write(next, for: threadId)
    }

    /// `onHeightChange` (`:1298-1303`, called on pointer-up only): the height a
    /// finished drag leaves, stored raw.
    func setHeight(_ height: Double, for threadId: String) {
        var next = state(threadId)
        guard next.height != height else { return }
        next.height = height
        write(next, for: threadId)
    }

    private func write(_ state: T3TerminalDrawer.State, for threadId: String) {
        if state == .none { states[threadId] = nil } else { states[threadId] = state }
        // One write per burst, `T3WindowModel`'s own debounce for the visits.
        persist?.cancel()
        let snapshot = states
        persist = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(T3TerminalDrawer.save(snapshot), forKey: Self.key)
        }
    }
}

/// The drawer row itself. Draws nothing at all while it is closed — a closed
/// drawer has no view, no attachment and no cost.
struct T3TerminalDrawerSlot: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    @ObservedObject var drawer: T3TerminalDrawerModel
    let threadId: String
    /// The thread column's own height, which is what the clamp's three-quarter
    /// cap is measured against (`maxDrawerHeight`, `:96-99`, reads
    /// `window.innerHeight`). Never the timeline's: the drawer shrinks THAT, and
    /// feeding it back would make the drawer cap itself smaller as it grows.
    let viewport: Double
    /// Called as the drawer's band is about to change, in the update pass
    /// before the layout it causes — the timeline snapshots whether the reader
    /// was at the end while that is still answerable (`T3ThreadView`).
    var onWillResize: () -> Void = {}

    /// The height while a drag is in flight. Upstream keeps the same thing in
    /// component state and only tells the store on pointer-up (`:1086-1091`,
    /// `:1339-1355`).
    @State private var dragging: Double?
    @State private var dragStart: Double?

    private var height: Double {
        T3TerminalDrawer.clamp(dragging ?? drawer.state(threadId).height, viewport: viewport)
    }

    /// The band this row takes out of the thread column: the height while
    /// open, nothing while closed. `height` on its own is the stored 280 in
    /// both states, so the toggle would not read as a change.
    private var band: Double { drawer.isOpen(threadId) ? height : 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Zero-height and always mounted: the `onChange` has to fire on
            // the pass that OPENS the drawer, which a view that exists only
            // while it is open cannot do.
            Color.clear
                .frame(height: 0)
                .onChange(of: band) { _, _ in onWillResize() }
            if drawer.isOpen(threadId) {
                surface
                    // `shrink-0` at a fixed height (`:1398-1400`).
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(t3.web.background.color)
                    // `border-t border-border/80` (`:1398`).
                    .overlay(alignment: .top) {
                        Rectangle().fill(t3.web.border.color.opacity(0.8)).frame(height: 1)
                    }
                    // `absolute inset-x-0 top-0 z-20 h-1.5 cursor-row-resize`
                    // (`:1432-1439`) — over the border, above the content.
                    .overlay(alignment: .top) { handle }
            }
        }
    }

    /// The shared surface, mounted as the drawer. Without a live session pid
    /// there is no shell of ours to show — the tab's own gate
    /// (`T3TerminalPanel.target`), and the toggle is unavailable then too, so
    /// this only happens if a session ends while the drawer is open.
    @ViewBuilder private var surface: some View {
        if let target = T3TerminalPanel.target(in: model.state) {
            T3TerminalSurfaceView(model: model, target: target, owner: .drawer)
                .id(target.key)
        } else {
            T3TerminalMessage(text: "Available while this thread's session is running.")
        }
    }

    /// `handleResizePointerDown/Move/End` (`:1309-1355`): the drag moves the
    /// TOP edge, so a pointer that goes up makes the drawer taller
    /// (`startHeight + (startY - clientY)`), clamped every move, and the store
    /// hears the result once, at the end. No timer, no per-frame publish beyond
    /// the one `@State` the height reads.
    private var handle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)   // `h-1.5`
            .contentShape(Rectangle())
            .onHover { inside in
                // `cursor-row-resize`.
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // `.global`, and load-bearing: the handle MOVES with the edge
                // it drags, so a translation measured in its own space is
                // taken against a frame that has already shifted by the same
                // amount — every drag came out at half its travel. Upstream's
                // `event.clientY` (`:1327`) is the viewport's space for the
                // same reason.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        if dragStart == nil { dragStart = start }
                        dragging = T3TerminalDrawer.clamp(start - value.translation.height,
                                                          viewport: viewport)
                    }
                    .onEnded { _ in
                        if let dragging { drawer.setHeight(dragging, for: threadId) }
                        dragStart = nil
                        dragging = nil
                    }
            )
    }
}

/// `PanelLayoutControls.tsx:39-61`'s terminal toggle, in the top bar's own
/// control group: `PanelBottomIcon`, pressed while the drawer is open, and
/// `disabled` — the ghost variant's `disabled:text-muted-foreground`
/// (`ui/toggle.tsx:29`), never dimmed — without a session to open a shell for.
/// Upstream's copy verbatim: "Toggle terminal drawer" with the shortcut in the
/// tooltip (`:58`), "Terminal drawer is unavailable" without one (`:59`).
///
/// A view of its own so the top bar's band does not have to observe the drawer
/// model, the way the Agents tab observes the timeline store.
struct T3TerminalDrawerToggle: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var drawer: T3TerminalDrawerModel

    var body: some View {
        let threadId = model.state.selectedThread?.id
        // `terminalAvailable={activeProject !== null}` (`ChatView.tsx:7939`),
        // plus this host's own need of a live pid (`T3TerminalPanel.target`).
        let available = threadId != nil && T3TerminalPanel.target(in: model.state) != nil
        T3TopBarToggle(icon: .panelBottom,
                       pressed: available && threadId.map { drawer.isOpen($0) } == true,
                       tooltip: available ? "Toggle terminal drawer (\u{2318}J)"
                                          : "Terminal drawer is unavailable",
                       enabled: available) {
            guard let threadId else { return }
            withAnimation(.easeOut(duration: 0.2)) { drawer.toggle(threadId) }
        }
    }
}
