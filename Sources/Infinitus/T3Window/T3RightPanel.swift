import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's right panel (`RightPanelTabs.tsx:990-1035`): a tab strip over Diff,
/// Files, Pull request, Terminal and Agents — each a "coming later" empty
/// state until the matching surface ships (a later release). The width
/// (42% of the window, clamped to [360, 560]) comes from the shell that
/// wraps this component (`DiffPanelShell.tsx:33` `w-[42vw] min-w-[360px]
/// max-w-[560px] border-l border-border`, applied by `T3Root`).
struct T3RightPanel: View {
    let model: T3WindowModel
    @Environment(\.t3) private var t3
    @State private var tab = "diff"

    private static let tabs: [(id: String, title: String)] = [
        ("diff", "Diff"), ("files", "Files"), ("pr", "Pull request"),
        ("terminal", "Terminal"), ("agents", "Agents"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            content
        }
        .frame(maxHeight: .infinity)
        .background(t3.web.background.color)
    }

    // "flex h-[--workspace-topbar-height] items-center gap-1 pl-2 pr-3"
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(Self.tabs, id: \.id) { entry in
                T3RightPanelTabButton(title: entry.title, selected: tab == entry.id) { tab = entry.id }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: T3Theme.Metrics.topbarHeight)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case "diff": T3WebEmpty(title: "Diff arrives with a later release", message: "")
        case "files": T3WebEmpty(title: "Files arrives with a later release", message: "")
        case "pr": T3WebEmpty(title: "Pull request arrives with a later release", message: "")
        case "terminal": T3WebEmpty(title: "Terminal arrives with a later release", message: "")
        default: T3WebEmpty(title: "Agents arrives with a later release", message: "")
        }
    }
}

/// One tab: "h-6 max-w-36 rounded-md pl-1.5 pr-2 text-xs", active
/// `bg-accent text-foreground`, inactive `text-muted-foreground
/// hover:bg-accent/60 hover:text-foreground` (`RightPanelTabs.tsx:1026-1034`).
/// `rounded-md` has no kit token (`controlRadius` is 8, this is Tailwind's 6).
private struct T3RightPanelTabButton: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let title: String, selected: Bool, action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(T3Font.web(.xs))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
    private var foreground: Color {
        if selected { return t3.web.foreground.color }
        return hover ? t3.web.foreground.color : t3.web.mutedForeground.color
    }
    private var background: Color {
        if selected { return t3.web.accent.color }
        return hover ? t3.web.accent.color.opacity(0.6) : .clear
    }
}
