import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The workspace window's root: sidebar | main | right panel (spec §4.1,
/// `AppSidebarLayout.tsx`). Tasks 7–9 replace the placeholder slots below
/// with the real sidebar, top bar and thread view.
struct T3Root: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t3 = T3Environment(platform: .web, scheme: scheme)
        HStack(spacing: 0) {
            sidebar(t3)
                .frame(width: model.state.sidebarCollapsed ? T3Theme.Metrics.sidebarWidthIcon : T3Theme.Metrics.sidebarWidth)
                .background(t3.web.sidebar.color)
                .overlay(alignment: .trailing) { Rectangle().fill(t3.web.sidebarBorder.color).frame(width: 1) }
            main(t3)
                .frame(minWidth: 640, maxWidth: .infinity)
            if model.state.rightPanelOpen {
                T3RightPanel(model: model)
                    .frame(minWidth: 360, idealWidth: 360)
                    .overlay(alignment: .leading) { Rectangle().fill(t3.web.border.color).frame(width: 1) }
            }
        }
        .background(t3.web.background.color)
        .frame(minWidth: T3WindowController.minimumSize.width, minHeight: T3WindowController.minimumSize.height)
        // `.fullSizeContentView` insets SwiftUI content by the titlebar's
        // safe area by default; T3's own custom titlebar starts at y = 0
        // (the topbar band reserves the traffic-light inset itself, Task 8).
        .ignoresSafeArea()
        .environment(\.t3, t3)
        .background { keyboard }   // hidden buttons: the ⌘F pattern
    }

    @ViewBuilder private func sidebar(_ t3: T3Environment) -> some View {
        if model.state.sidebarCollapsed { T3SidebarRail() }          // A's rail primitive; Task 7 fills it
        else { T3SidebarPlaceholder(model: model) }                   // Task 7 replaces with T3SidebarView
    }

    @ViewBuilder private func main(_ t3: T3Environment) -> some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragRegion()
                T3TopBarPlaceholder(model: model)                    // Task 8 replaces with T3TopBar
            }
            .frame(height: T3Theme.Metrics.topbarHeight)
            if model.state.projects.isEmpty && model.state.threads.isEmpty {
                T3NoProjectsHero(action: nil)
            } else if model.state.selectedThread == nil {
                T3NoActiveThreadState()
            } else {
                T3ThreadPlaceholder(model: model)                    // Task 9 replaces with T3ThreadView
            }
        }
    }

    // `ui/sidebar.tsx:285` collapses the width column over
    // `--panel-animation-duration` (Tailwind's own `duration-200` elsewhere
    // in the file, `:734`) — one `withAnimation`, never a repeating one.
    private var keyboard: some View {
        Group {
            Button("") { withAnimation(.linear(duration: 0.2)) { model.toggleSidebar() } }
                .keyboardShortcut("b", modifiers: .command)
            Button("") { withAnimation(.linear(duration: 0.2)) { model.toggleRightPanel() } }
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

// MARK: - Task 6 placeholders (Tasks 7–9 delete these)

private struct T3SidebarPlaceholder: View {
    @ObservedObject var model: T3WindowModel
    @Environment(\.t3) private var t3
    var body: some View {
        Text("\(model.state.threads.count) threads")
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.mutedForeground.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
    }
}

private struct T3TopBarPlaceholder: View {
    @ObservedObject var model: T3WindowModel
    @Environment(\.t3) private var t3
    var body: some View {
        Text(model.state.selectedThread?.title ?? "Workspace")
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.mutedForeground.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

private struct T3ThreadPlaceholder: View {
    @ObservedObject var model: T3WindowModel
    @Environment(\.t3) private var t3
    var body: some View {
        Text(model.state.selectedThread?.title ?? "")
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.mutedForeground.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
