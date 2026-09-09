import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The workspace window's root: sidebar | main | right panel (spec §4.1,
/// `AppSidebarLayout.tsx`).
struct T3Root: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t3 = T3Environment(platform: .web, scheme: scheme)
        GeometryReader { geo in
            let sidebarW = model.state.sidebarCollapsed ? 0 : Self.sidebarWidth(windowWidth: geo.size.width)
            let panelW = model.state.rightPanelOpen ? Self.rightPanelWidth(windowWidth: geo.size.width) : 0
            HStack(spacing: 0) {
                T3SidebarView(model: model, app: app)
                    .frame(width: sidebarW)
                    .background(t3.web.sidebar.color)
                    .overlay(alignment: .trailing) { Rectangle().fill(t3.web.sidebarBorder.color).frame(width: 1) }
                    // `ui/sidebar.tsx:288,299` slide the whole container off
                    // the left edge at width 0 — nothing of it, border
                    // included, may bleed into the main column.
                    .clipped()
                main(t3, columnWidth: max(0, geo.size.width - sidebarW - panelW))
                    .frame(maxWidth: .infinity)
                if model.state.rightPanelOpen {
                    T3RightPanel()
                        .frame(width: panelW)
                        .overlay(alignment: .leading) { Rectangle().fill(t3.web.border.color).frame(width: 1) }
                }
            }
            .background(t3.web.background.color)
            .overlay(alignment: .topLeading) { sidebarToggle }
        }
        .frame(minWidth: T3WindowController.minimumSize.width, minHeight: T3WindowController.minimumSize.height)
        // `.fullSizeContentView` insets SwiftUI content by the titlebar's
        // safe area by default; T3's own custom titlebar starts at y = 0
        // (the topbar band reserves the traffic-light inset itself, Task 8).
        .ignoresSafeArea()
        .environment(\.t3, t3)
        .overlay { keyboard }   // hidden buttons: the ⌘F pattern
    }

    // `threadSidebarWidth.ts`: expanded width clamps between
    // THREAD_SIDEBAR_MIN_WIDTH (208) and Metrics.sidebarWidth (256),
    // yielding to the main content's own THREAD_MAIN_CONTENT_MIN_WIDTH
    // (640) floor as the window narrows (B-3 review).
    private static func sidebarWidth(windowWidth: Double) -> Double {
        min(T3Theme.Metrics.sidebarWidth, max(208, windowWidth - 640))
    }

    // `DiffPanelShell.tsx:33`: `w-[42vw] min-w-[360px] max-w-[560px]
    // shrink-0` — 42% of the window width, clamped.
    private static func rightPanelWidth(windowWidth: Double) -> Double {
        min(max(0.42 * windowWidth, 360), 560)
    }

    // `AppSidebarLayout.tsx:227` makes the sidebar `collapsible="offcanvas"`:
    // collapsed is width 0 (`ui/sidebar.tsx:285`'s
    // `group-data-[collapsible=offcanvas]:w-0`) with the container translated
    // off-screen (`:298`), never an icon rail — B-3 review. The top bar's own
    // 130 pt collapsed inset then leaves 12 pt of air after this toggle, which
    // ends at 118.
    //
    // `AppSidebarLayout.tsx:72-137`'s `SidebarControl`: fixed at
    // `left: var(--workspace-controls-left)` (90 pt) regardless of sidebar
    // state — a sibling of `{children}` (`:258`), not part of either
    // column, so it renders here rather than inside `T3TopBar`. Icon swaps
    // `ui/sidebar.tsx:344`: `PanelLeftIcon` collapsed, `PanelLeftCloseIcon`
    // expanded (`isSidebarVisible`).
    private var sidebarToggle: some View {
        T3TopBarToggle(icon: model.state.sidebarCollapsed ? .panelLeft : .panelLeftClose, pressed: false,
                        tooltip: "Toggle main sidebar (\u{2318}B)") {
            withAnimation(.easeOut(duration: 0.2)) { model.toggleSidebar() }
        }
        .padding(.leading, 90)
        .frame(height: T3Theme.Metrics.topbarHeight)
    }

    // `columnWidth` is the main column's own width — what
    // `ChatHeader.tsx:318-320`'s `@container/header-actions` measures, since
    // the header content div fills the column. `T3TopBar` can't read it with
    // its own `GeometryReader` (its children's widths depend on the answer),
    // so it is proposed from here.
    @ViewBuilder private func main(_ t3: T3Environment, columnWidth: Double) -> some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragRegion()
                T3TopBar(model: model, app: app, columnWidth: columnWidth)
            }
            .frame(height: T3Theme.Metrics.topbarHeight)
            if model.state.projects.isEmpty && model.state.threads.isEmpty {
                T3NoProjectsHero(action: nil)
            } else if let store = model.timelineStore, model.state.selectedThread != nil {
                // `.id` per upstream's `key={activeThread.id}` on
                // `<MessagesTimeline>` (`ChatView.tsx:7939`): a thread switch
                // remounts the list, which is also what drops the outgoing
                // thread's row geometry. A rebind (same thread, new pid) keeps
                // the same store id and so keeps the scroll position.
                T3ThreadView(model: model, app: app, store: store, now: model.now)
                    .id(store.threadId)
            } else {
                T3NoActiveThreadState()
            }
        }
    }

    // `ui/sidebar.tsx:285,297,607` collapse the width column over
    // `--panel-animation-duration` with `ease-out` — one `withAnimation`,
    // never a repeating one.
    private var keyboard: some View {
        Group {
            Button("") { withAnimation(.easeOut(duration: 0.2)) { model.toggleSidebar() } }
                .keyboardShortcut("b", modifiers: .command)
            Button("") { withAnimation(.easeOut(duration: 0.2)) { model.toggleRightPanel() } }
                .keyboardShortcut("j", modifiers: .command)
            // ⌘W closes the workspace window — an accessory app has no menu
            // bar to route the standard close item, so this is the only way
            // in (the ⌘⇧T pattern in PinnedRoot).
            Button("") { model.closeRequested?() }.keyboardShortcut("w", modifiers: .command)
        }
        .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// The title band doubles as the drag region under `.fullSizeContentView`.
struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
