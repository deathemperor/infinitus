import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// One sidebar row (spec: `Sidebar.tsx`'s `SidebarThreadRow`, simplified to
/// what B's `T3Thread` actually carries — no branch/provider/PR chrome,
/// so this is closer to `ThreadRowLeadingStatus`'s compact row than the
/// desktop card): leading status glyph, title, trailing relative time, an
/// unseen-completion dot. Right-click ports `buildThreadActionMenuItems`
/// (`threadActionMenu.logic.ts`), keeping only pin/unpin, settle/unsettle,
/// snooze ▸ presets, wake and Copy ▸ Path/Thread ID — `rename`,
/// `regenerate-title`, `mark-unread`, `project-settings`, `archive`,
/// `delete` and `new-thread-on-branch` have no host action on B yet (task
/// brief's own deviation table) and are omitted rather than stubbed.
struct T3ThreadRowView: View {
    let thread: T3Thread
    let selected: Bool
    let now: Date
    let onSelect: () -> Void
    let onAttention: (AttentionStore.Action, Date?) -> Void
    /// Resolved by `T3SidebarView` from `model.state.projects` — `T3Thread`
    /// itself carries no path/name (no `cwd` field yet). `nil` degrades
    /// gracefully: the "ready" glyph falls back to the thread title's
    /// initial and "Copy > Path" is hidden.
    var projectName: String? = nil
    var projectCwd: String? = nil

    @Environment(\.t3) private var t3
    @State private var hover = false

    private var status: T3ThreadStatus { T3ThreadStatus(thread) }
    private var style: T3SidebarList.RowStyle { T3SidebarList.rowStyle(isActive: selected, isSelected: false) }
    private var p: T3Theme.WebPalette { t3.web }

    var body: some View {
        HStack(spacing: 8) {
            glyph
            Text(thread.title)
                .font(T3Font.web(.sm, style.medium ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            if T3SidebarList.hasUnseenCompletion(thread) {
                Circle().fill(p.primary.color).frame(width: 6, height: 6)
            }
            Spacer(minLength: 0)
            Text(T3RelativeTime.label(from: thread.latestUserMessageAt ?? thread.updatedAt, now: now))
                .font(T3Font.web(.xs))
                .foregroundStyle(p.sidebarMutedForeground.color)
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .frame(height: 32)
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

    // `resolveThreadListV2Status`/`resolveSidebarThreadStatus`: approval
    // outranks input outranks working outranks failed; ready falls back to
    // the project glyph (`ProjectFavicon`'s slot in the real row).
    @ViewBuilder private var glyph: some View {
        switch status {
        case .approval: LucideIcon(.hand, size: 16).foregroundStyle(p.warningForeground.color)
        case .input: LucideIcon(.messageCircleQuestion, size: 16).foregroundStyle(p.infoForeground.color)
        case .working: T3Spinner(size: 14)
        case .failed: LucideIcon(.xCircle, size: 16).foregroundStyle(p.destructiveForeground.color)
        case .ready: T3ProjectGlyph(name: projectName ?? thread.title)
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

/// `ProjectFavicon.tsx`'s Mac fallback (brief: "no favicons on the Mac —
/// letter only"): the project's first letter, uppercase, on a rounded
/// square. Never an image or an auto-selected lucide icon — that whole
/// `selectProjectIcon`/`PROJECT_ICONS` path is web-only chrome this port skips.
struct T3ProjectGlyph: View {
    let name: String
    @Environment(\.t3) private var t3
    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?").uppercased())
            .font(T3Font.web(.xs, .medium))
            .foregroundStyle(t3.web.sidebarForeground.color)
            .frame(width: 16, height: 16)
            .background(t3.web.sidebarControlSurface.color, in: RoundedRectangle(cornerRadius: 4))
    }
}
