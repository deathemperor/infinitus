import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's right panel (`RightPanelTabs.tsx:990-1035`): a tab strip over Diff,
/// Files, Pull request, Terminal and Agents — Diff (`T3DiffPanel`), Files
/// (`T3FilesPanel`), Pull request (`T3PullRequestPanel`), Terminal
/// (`T3TerminalPanel`) and Agents (`T3AgentsPanel`) are all real now. The width
/// (42% of the window, clamped to [360, 560]) comes from the shell that
/// wraps this component (`DiffPanelShell.tsx:33` `w-[42vw] min-w-[360px]
/// max-w-[560px] border-l border-border`, applied by `T3Root`).
struct T3RightPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
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
                // The Agents tab's badge counts LIVE sub-agents, which live on
                // the timeline store — so that one tab observes the store
                // itself; `model` only publishes when the store is swapped.
                if entry.id == "agents", let store = model.timelineStore {
                    T3RightPanelAgentsTab(store: store, selected: tab == entry.id) { tab = entry.id }
                } else {
                    T3RightPanelTabButton(title: entry.title, selected: tab == entry.id, badge: 0) { tab = entry.id }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: T3Theme.Metrics.topbarHeight)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case "diff": T3DiffPanel(model: model)
        case "files": T3FilesPanel(model: model)
        case "pr": T3PullRequestPanel(model: model)
        case "terminal": T3TerminalPanel(model: model)
        default: T3AgentsPanel(model: model)
        }
    }
}

/// The Agents tab, whose `badgeCount` is `liveAgentCount`
/// (`RightPanelTabs.tsx:365-373`).
private struct T3RightPanelAgentsTab: View {
    @ObservedObject var store: T3TimelineStore
    let selected: Bool
    let action: () -> Void
    var body: some View {
        T3RightPanelTabButton(title: "Agents", selected: selected,
                              badge: store.agents.liveCount, action: action)
    }
}

/// One tab: "h-6 max-w-36 rounded-md pl-1.5 pr-2 text-xs" (`max-w-36` =
/// 9rem = 144 pt, so a long tab title truncates rather than pushing its
/// neighbours off the strip — `RightPanelTabs.tsx:1030`), active
/// `bg-accent text-foreground`, inactive `text-muted-foreground
/// hover:bg-accent/60 hover:text-foreground` (`RightPanelTabs.tsx:1026-1034`).
/// `rounded-md` has no kit token, but it is NOT Tailwind's default 6:
/// `web-index.css:146,204`'s `@theme inline { --radius-md: calc(var(--radius) -
/// 2px) }` redefines it globally over `:968`'s `--radius: 0.625rem`, so it is
/// 8 — the same number as `controlRadius` (`--control-radius: 0.5rem`,
/// `:91`) by coincidence, not by derivation, hence the literal.
private struct T3RightPanelTabButton: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let title: String, selected: Bool
    /// Live sub-agents on the Agents tab, 0 (hidden) on every other
    /// (`RightPanelTabs.tsx:322-373`).
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // `max-w-36` is a CAP on content-sized width, not a width:
            // a bare `.frame(maxWidth: 144)` is flexible and would let each
            // tab fill to 144 and push the strip past the panel — the trap
            // `CapToContent` (T3TopBar.swift) exists for.
            CapToContent(maxWidth: 144) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(T3Font.web(.xs))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(foreground)
                    if badge > 0 { badgeBubble }
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 24)
            }
            .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
    /// Upstream hangs the count off the surface launcher's card icon —
    /// "h-3.5 min-w-3.5 rounded-full bg-info px-1 text-[9px] font-semibold
    /// tabular-nums text-white" (`RightPanelTabs.tsx:442-457`). B has no
    /// launcher, so it rides the tab's own label.
    private var badgeBubble: some View {
        Text("\(badge)")
            .font(T3Font.webLiteral(9, .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 14)
            .background(t3.web.info.color, in: Capsule())
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
