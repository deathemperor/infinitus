import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// One sidebar row (spec: `Sidebar.tsx`'s `SidebarThreadRow`, simplified to
/// what B's `T3Thread` actually carries — no branch/provider/PR chrome, so
/// this is closer to the row's slim variant than its full card). Row
/// anatomy (fix round 1, `Sidebar.tsx:956-1200`): the LEADING glyph is
/// always the project icon (`ProjectFavicon.tsx`, ported as
/// `T3ProjectGlyph`/`T3ProjectIcon`); status is a TRAILING pill — a text
/// label, coloured per status, with an icon only for working/done
/// (`Sidebar.tsx`'s `topStatus`, :1117-1167, built over
/// `resolveSidebarThreadStatus`, `Sidebar.logic.ts:818-839`) — the pill
/// replaces the relative-time label when present (:1719-1812: `topStatus ?
/// <pill/> : threadTimeLabel(thread)`). Right-click ports
/// `buildThreadActionMenuItems` (`threadActionMenu.logic.ts`), keeping
/// only pin/unpin, settle/unsettle, snooze ▸ presets, wake and Copy ▸
/// Path/Thread ID — `rename`, `regenerate-title`, `mark-unread`,
/// `project-settings`, `archive`, `delete` and `new-thread-on-branch` have
/// no host action on B yet (task brief's own deviation table) and are
/// omitted rather than stubbed.
struct T3ThreadRowView: View {
    let thread: T3Thread
    let selected: Bool
    let now: Date
    let onSelect: () -> Void
    let onAttention: (AttentionStore.Action, Date?) -> Void
    /// Resolved by `T3SidebarView` from `model.state.projects` — `T3Thread`
    /// itself carries no path/name (no `cwd` field yet). Both default to
    /// `""`, which `T3ProjectIcon.select` degrades gracefully over (same as
    /// upstream's own `cwd={props.projectCwd ?? ""}`), and `nil` hides
    /// "Copy > Path".
    var projectName: String? = nil
    var projectCwd: String? = nil

    @Environment(\.t3) private var t3
    @State private var hover = false

    private var status: T3ThreadStatus { T3ThreadStatus(thread) }
    private var style: T3SidebarList.RowStyle { T3SidebarList.rowStyle(isActive: selected, isSelected: false) }
    private var p: T3Theme.WebPalette { t3.web }

    var body: some View {
        HStack(spacing: 10) {   // `Sidebar.tsx:1557` "gap-2.5"
            T3ProjectGlyph(projectName: projectName ?? "", projectCwd: projectCwd ?? "")
            Text(thread.title)
                .font(T3Font.web(.sm, style.medium ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        // `Sidebar.tsx:1557`'s slim-row surface (the variant this compact
        // row is closest to — no branch/PR/multi-line card content):
        // "flex h-9 items-center" = 36 pt (fix round 1 R4 found this was
        // 32 pt, mistakenly traced to the project-select trigger's h-8
        // instead of the thread row's own class).
        .frame(height: 36)
        .foregroundStyle(style.foreground == .foreground ? p.sidebarForeground.color : p.sidebarMutedForeground.color.opacity(0.8))
        .background(rowBackground, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu { menu }
    }

    private var rowBackground: Color {
        switch style.background {
        case .active: return p.sidebarRowActive.color
        case .selected: return p.sidebarRowSelected.color
        case .none: return hover ? p.sidebarRowHover.color : .clear
        }
    }

    // MARK: - Trailing: status pill, or the relative time when there is none

    // `Sidebar.tsx`'s `topStatus` (:1117-1160) only for the four statuses
    // B's `T3ThreadStatus` actually carries, plus the unread-completion
    // "Done" pill (:1153-1160's `isUnread` branch) — "Monitoring" and
    // "Woke" have no B equivalent (no `backgroundLiveness`/`wokeAt` field
    // on `T3Thread`) and are omitted, not stubbed.
    private var pillLabel: String? {
        switch status {
        case .working: return "Working"
        case .approval: return "Approval"
        case .input: return "Input"
        case .failed: return "Failed"
        case .ready: return T3SidebarList.hasUnseenCompletion(thread) ? "Done" : nil
        }
    }

    // Tailwind text-{colour}-{600|700}/{300|400} pair from `topStatus`'s
    // `className` per status, resolved to sRGB via the pinned
    // tailwindcss@4.3.3 palette (`theme.css`'s oklch stops render to the
    // same values as v3's `colors.js` at these shades — the literal figures
    // below are decimal RGB from that file, not eyeballed).
    private var pillColor: Color {
        let (light, dark): (T3RGBA, T3RGBA)
        switch status {
        case .working: (light, dark) = (T3RGBA(2, 132, 199, 1), T3RGBA(56, 189, 248, 1))     // sky-600/400
        case .approval: (light, dark) = (T3RGBA(180, 83, 9, 1), T3RGBA(252, 211, 77, 1))     // amber-700/300
        case .input: (light, dark) = (T3RGBA(79, 70, 229, 1), T3RGBA(165, 180, 252, 1))      // indigo-600/300
        case .failed: (light, dark) = (T3RGBA(185, 28, 28, 1), T3RGBA(252, 165, 165, 1))     // red-700/300
        case .ready: (light, dark) = (T3RGBA(4, 120, 87, 1), T3RGBA(110, 231, 183, 1))       // emerald-700/300 ("Done")
        }
        return (t3.scheme == .dark ? dark : light).color
    }

    @ViewBuilder private var trailing: some View {
        if let pillLabel {
            HStack(spacing: 4) {
                // `topStatus.icon`: "working" → CircleDashed (spinning in
                // this brief's own instruction, so T3Spinner/LayerEffect
                // rather than upstream's static glyph — see #18's idle-CPU
                // rule); "done" → CircleCheck; every other status has none.
                // Both render at 16 pt (`Sidebar.tsx:1796`/`:1798`'s
                // `className="size-4 shrink-0"`). T3Spinner's stroke is the
                // kit's fixed muted colour, not re-tinted to the pill's sky
                // hue (not modifying A's shared component for one B row) —
                // the label text still carries it.
                if status == .working { T3Spinner(size: 16) }
                else if pillLabel == "Done" { LucideIcon(.circleCheck, size: 16) }
                Text(pillLabel).font(T3Font.web(.xs, .medium))
            }
            .foregroundStyle(pillColor)
            // `topStatus.className` for working: "text-sky-600
            // dark:text-sky-400" + `!props.isActive && "opacity-75"`
            // (`Sidebar.tsx:1127`) — working recedes to 75% when its row
            // isn't the open thread; every other status stays full strength.
            .opacity(status == .working && !selected ? 0.75 : 1)
        } else {
            Text(T3RelativeTime.label(from: thread.latestUserMessageAt ?? thread.updatedAt, now: now))
                .font(T3Font.web(.xs))
                .foregroundStyle(p.sidebarMutedForeground.color)
        }
    }

    @ViewBuilder private var menu: some View {
        let isPinned = thread.pinnedAt != nil
        let isSettled = thread.settledOverride == .settled
        let isSnoozed = T3ThreadSettled.effectiveSnoozed(thread, now: now)
        Button(isPinned ? "Unpin thread" : "Pin thread") { onAttention(isPinned ? .unpin : .pin, nil) }
        Button(isSettled ? "Un-settle thread" : "Settle thread") { onAttention(isSettled ? .unsettle : .settle, nil) }
        if isSnoozed {
            Button("Wake thread") { onAttention(.unsnooze, nil) }
        } else {
            Menu("Snooze") {
                ForEach(T3ThreadSettled.snoozePresets(now: now), id: \.id) { preset in
                    Button(preset.label) { onAttention(.snooze, preset.snoozedUntil) }
                }
            }
            .disabled(!T3ThreadSettled.canSnooze(thread, now: now))
        }
        Divider()
        Menu("Copy") {
            if let projectCwd { Button("Path") { copyToPasteboard(projectCwd) } }
            Button("Thread ID") { copyToPasteboard(thread.id) }
        }
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// `ProjectFavicon.tsx`'s automatic-icon path (`selectProjectIcon` +
/// `PROJECT_ICONS`, fix round 1 R2): a bare coloured Lucide glyph at 16 pt
/// (`size-4`, the row's override of the component's own default `size-3.5`
/// — `Sidebar.tsx:1732`) — no background box, no radius, no letter
/// fallback (upstream has none of those for the automatic path; the
/// favicon-image and emoji-override branches have no B equivalent, see
/// `T3ProjectIcon`'s header comment).
struct T3ProjectGlyph: View {
    let projectName: String
    let projectCwd: String
    @Environment(\.t3) private var t3

    private var icon: T3ProjectIcon.Name { T3ProjectIcon.select(name: projectName, cwd: projectCwd) }

    // `PROJECT_ICONS` (`ProjectFavicon.tsx:44-65`): each `ProjectIconName` →
    // its Lucide component, transcribed to this kit's vendored names.
    private var lucide: Lucide {
        switch icon {
        case .ai: return .bot
        case .book: return .bookOpen
        case .braces: return .braces
        case .circuit: return .circuitBoard
        case .cloud: return .cloudCog
        case .code: return .code2
        case .database: return .database
        case .desktop: return .monitor
        case .folderCode: return .folderCode
        case .game: return .gamepad2
        case .image: return .image
        case .layers: return .layers3
        case .mobile: return .smartphone
        case .music: return .music
        case .package: return .package
        case .security: return .shieldCheck
        case .server: return .server
        case .shopping: return .shoppingBag
        case .terminal: return .terminal
        case .test: return .flaskConical
        case .video: return .video
        case .web: return .globe2
        }
    }

    private var color: Color {
        let pair = T3ProjectIcon.color(for: icon)
        let rgb = t3.scheme == .dark ? pair.dark : pair.light
        return Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }

    var body: some View {
        LucideIcon(lucide, size: 16).foregroundStyle(color)
    }
}
