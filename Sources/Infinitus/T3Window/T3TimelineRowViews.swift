import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The ten timeline row kinds of `components/chat/MessagesTimeline.tsx`, one
/// `private struct` per upstream function, dispatched by `TimelineRowContent`
/// (`:1175`) — including its bottom-padding table (`:1181-1198`), which is the
/// only vertical rhythm the list has (the `LazyVStack` runs at spacing 0).
///
/// Not ported, with the reason each time: attachments, videos, preview
/// annotations, element/terminal contexts and review-comment cards on the user
/// bubble (`T3ChatMessage` carries no `attachments` and no context parsing —
/// there is nothing on B to render); `AssistantCitationSource` and
/// `AssistantSelectionToolbar` (no citation model on B);
/// `AssistantChangedFilesSection` (`assistantTurnDiffSummary` is always nil —
/// `T3TimelineInput.make` passes `turnDiffSummaries: []`); the revert button
/// (`supportsConversationRollback: false`, so `revertTurnCount` is always
/// nil); `AgentSpawnCtaRow` (no `agentSpawn` on `T3WorkLogEntry`); the viewed
/// image body of a work entry (no thread-scoped asset route here);
/// `TimelineMinimap`. `isCompacting`/`isPreparingWorktree`
/// (`TimelineRowActivityCtx`) have no equivalent on B either, so the working
/// row only ever renders its "Working for …" branch.
struct T3TimelineRowView: View, Equatable {
    let row: T3TimelineRows.Row
    /// The main column's width — the user bubble's `max-w-[80%]` and the work
    /// group's own bounds measure against it (`T3Root` passes `columnWidth`
    /// into `T3TopBar` the same way).
    let columnWidth: Double
    /// The minute tick (`T3WindowModel.now`); only the working row reads it.
    let now: Date
    /// The plan card's Implement button exists only while the parked
    /// `ExitPlanMode` is the prompt a key would answer (Task 12).
    var planIsActionable = false
    let onToggleTurn: (String) -> Void
    let onToggleWorkGroup: (String) -> Void
    var onImplementPlan: () -> Void = {}
    var onEditPlan: (String) -> Void = { _ in }

    /// `memo(TimelineRowContent)` (`:1175`). Rows are values here, so the port
    /// of React's memo is `.equatable()` over the row payload: without it every
    /// `rows` publish re-runs every row body (and re-parses every markdown
    /// message). The closures are identity-free by construction, and `now`
    /// only matters to the row that reads it as a live value: a message row's
    /// day-aware timestamp also formats against `now`, but — as upstream, which
    /// formats it during render — it only refreshes when the row re-renders for
    /// another reason, so it stays out of the equality.
    static func == (l: T3TimelineRowView, r: T3TimelineRowView) -> Bool {
        l.row == r.row && l.columnWidth == r.columnWidth
            && (l.row.kind == "working" ? l.now == r.now : true)
            // Same rule as `now`: only the row that reads it compares it, so a
            // resolved approval hides the plan card's button without touching
            // any other row.
            && (l.row.kind == "proposed-plan" ? l.planIsActionable == r.planIsActionable : true)
    }

    var body: some View {
        content.padding(.bottom, bottomPadding)
    }

    // `:1181-1198`: pb-1 (4) for an expanded tool group's details, pb-0 for the
    // header that opened it, pb-1.5 (6) for turn-fold/working, pb-2 (8) for
    // commentary assistant rows (no meta), work/work-live/work-toggle and
    // thinking, pb-4 (16) for everything else.
    private var bottomPadding: Double {
        switch row {
        case let .work(_, _, _, isExpandedToolGroup, _):
            return isExpandedToolGroup ? 4 : 8
        case let .workToggle(_, _, _, _, _, expanded, _, _, _, _, _):
            return expanded ? 0 : 8
        case let .workLive(_, _, _, _, _, expanded, _):
            return expanded ? 0 : 8
        case .turnFold, .working:
            return 6
        case let .message(_, _, message, _, showAssistantMeta, _, _, _, _):
            return message.role == .assistant && !showAssistantMeta ? 8 : 16
        case .thinking:
            return 8
        case .contextCompaction, .assistantMeta, .proposedPlan:
            return 16
        }
    }

    @ViewBuilder private var content: some View {
        switch row {
        case let .work(id, _, groupedEntries, isExpandedToolGroup, displayLabel):
            T3WorkGroupSection(anchorKey: id, groupedEntries: groupedEntries,
                               isExpandedToolGroup: isExpandedToolGroup, displayLabel: displayLabel)
        case let .workLive(_, _, entry, _, groupId, expanded, active):
            T3LiveWorkEntryRow(entry: entry, groupId: groupId, expanded: expanded, active: active,
                               onToggle: onToggleWorkGroup)
        case let .workToggle(_, _, _, groupId, _, expanded, summary, summaryKind, toolSurface,
                             summaryToolIcon, hasFailure):
            T3WorkGroupToggleRow(groupId: groupId, expanded: expanded, summary: summary,
                                 summaryKind: summaryKind, toolSurface: toolSurface,
                                 summaryToolIcon: summaryToolIcon, hasFailure: hasFailure,
                                 onToggle: onToggleWorkGroup)
        case let .turnFold(_, _, turnId, label, expanded):
            T3TurnFoldRow(turnId: turnId, label: label, expanded: expanded, onToggle: onToggleTurn)
        case let .contextCompaction(_, _, label):
            T3ContextCompactionRow(label: label)
        case let .message(_, _, message, _, showAssistantMeta, showAssistantCopyButton,
                          assistantCopyStreaming, _, _):
            if message.role == .user {
                T3UserTimelineRow(message: message, columnWidth: columnWidth, now: now)
            } else {
                T3AssistantTimelineRow(message: message, showMeta: showAssistantMeta,
                                       showCopyButton: showAssistantCopyButton,
                                       copyStreaming: assistantCopyStreaming, now: now)
            }
        case let .assistantMeta(_, _, message, showAssistantCopyButton, assistantCopyStreaming):
            // `AssistantMetaTimelineRow` (`:1603`): px-1, mt-0.5, always visible.
            T3AssistantMessageMeta(message: message, showCopyButton: showAssistantCopyButton,
                                   copyStreaming: assistantCopyStreaming, alwaysVisible: true,
                                   now: now)
                .padding(.top, 2)
                .padding(.horizontal, 4)
        case let .proposedPlan(_, _, plan):
            T3ProposedPlanCard(plan: plan, isActionable: planIsActionable,
                               onImplement: onImplementPlan, onEdit: onEditPlan)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        case let .working(_, createdAt):
            T3WorkingRow(createdAt: createdAt, now: now)
        case .thinking:
            T3ThinkingRow()
        }
    }
}

// MARK: - Messages

/// `UserTimelineRow` (`:1296`) with `CollapsibleUserMessageBody` (`:2358`) and
/// `UserMessageBody` (`:2426`) — the bubble plus its hover footer.
private struct T3UserTimelineRow: View {
    let message: T3ChatMessage
    let columnWidth: Double
    /// The minute tick, for the footer's day-aware timestamp — never `Date()`.
    let now: Date
    @Environment(\.t3) private var t3
    @State private var hover = false
    @State private var expanded = false

    /// `MAX_COLLAPSED_USER_MESSAGE_LINES`/`_LENGTH` + `shouldCollapseUserMessage`
    /// (`:2342-2356`).
    private var canCollapse: Bool {
        let text = message.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }
    private var collapsed: Bool { canCollapse && !expanded }

    var body: some View {
        // `flex flex-col items-end gap-1` (`:1327`).
        VStack(alignment: .trailing, spacing: 4) {
            // The bubble is `max-w-[80%]` on a shrink-to-fit block. SwiftUI's
            // `.frame(maxWidth:)` always takes the clamped proposal (a short
            // "Hi" would paint a full-width bubble), so the cap is the leading
            // spacer's `minLength` instead.
            HStack(spacing: 0) {
                Spacer(minLength: columnWidth * 0.2)
                bubble
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hover = $0 }
    }

    private var bubble: some View {
        // `max-w-[80%] rounded-2xl bg-message p-3 text-message-foreground` (`:1329`).
        VStack(alignment: .leading, spacing: 6) {
            body_
            if canCollapse { showMoreButton }
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
        .background(t3.web.messageSurface.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var body_: some View {
        let text = message.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if collapsed {
            // `max-h-44 overflow-hidden` (176) under the
            // `COLLAPSED_USER_MESSAGE_FADE_MASK` — black to transparent over
            // the last 1.75 rem (28) (`:2345-2346`).
            T3ChatMarkdown(text: text)
                .frame(maxHeight: 176, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: 1 - 28 / 176),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        } else {
            T3ChatMarkdown(text: text)
        }
    }

    // `:2404-2415`: an `xs` ghost button, `h-6 rounded-md px-1.5 text-xs`, in
    // `secondary-label`, under an `mt-1.5` (6, the stack's spacing above).
    private var showMoreButton: some View {
        Button { expanded.toggle() } label: {
            Text(expanded ? "Show less" : "Show full message")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.secondaryLabel.color)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(t3.web.muted.color.opacity(0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.leading, -4)   // "-ml-1"
    }

    // `:1487-1508`: `max-w-[80%] pe-1 text-xs tabular-nums`, hidden until
    // hover (`opacity-0 … group-hover:opacity-100`, 200 ms).
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(T3ChatTimestamp.dayAware(message.createdAt, now: now))
                .font(T3Font.web(.xs))
                .monospacedDigit()
                .foregroundStyle(t3.web.mutedForeground.color)
            T3MessageCopyButton(text: message.text)
        }
        .padding(.trailing, 4)
        .frame(maxWidth: columnWidth * 0.8)
        .opacity(hover ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hover)
    }
}

/// `AssistantTimelineRow` (`:1559`).
private struct T3AssistantTimelineRow: View {
    let message: T3ChatMessage
    let showMeta: Bool
    let showCopyButton: Bool
    let copyStreaming: Bool
    let now: Date
    @State private var hover = false

    var body: some View {
        // `relative min-w-0 px-1 py-0.5` (`:1564`).
        VStack(alignment: .leading, spacing: 0) {
            // `:1571-1577`: an empty settled reply still shows something.
            T3ChatMarkdown(text: message.text.isEmpty && !message.streaming
                ? "(empty response)" : message.text)
            if showMeta {
                // `className="mt-1.5"` (`:1590`).
                T3AssistantMessageMeta(message: message, showCopyButton: showCopyButton,
                                       copyStreaming: copyStreaming, alwaysVisible: false, now: now)
                    .padding(.top, 6)
                    .opacity(hover ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: hover)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // `group/assistant` (`:1200-1203`): the meta row reveals on hover of
        // the whole message row.
        .onHover { hover = $0 }
    }
}

/// `AssistantMessageMeta` (`:1621`) + `AssistantCopyButton` (`:1665`). The diff
/// stat slot upstream sits in `AssistantChangedFilesSection`, which B has no
/// summaries for, so this is copy + timestamp only.
private struct T3AssistantMessageMeta: View {
    let message: T3ChatMessage
    let showCopyButton: Bool
    let copyStreaming: Bool
    let alwaysVisible: Bool
    /// The minute tick, not `Date()` (`T3WindowModel.now`).
    let now: Date
    @Environment(\.t3) private var t3

    var body: some View {
        // `flex items-center gap-2 text-xs tabular-nums` (`:1634`).
        HStack(spacing: 8) {
            // `resolveAssistantMessageCopyState`: nothing to copy while the
            // reply is still streaming unless the row says otherwise.
            if showCopyButton && !copyStreaming && !message.text.isEmpty {
                T3MessageCopyButton(text: message.text)
            }
            if !message.streaming {
                Text(T3ChatTimestamp.dayAware(message.updatedAt, now: now))
                    .font(T3Font.web(.xs))
                    .monospacedDigit()
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `MessageCopyButton` in the `ghost` variant — the same `icon-xs` ghost square
/// `T3ChatMarkdown`'s "Copy code" button uses, with the check-mark swap.
private struct T3MessageCopyButton: View {
    let text: String
    @Environment(\.t3) private var t3
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            // `size="icon-xs"` = `size-6` with a `size-3` glyph.
            LucideIcon(copied ? .check : .copy, size: 12)
                .foregroundStyle(t3.web.mutedForeground.color)
                .frame(width: 24, height: 24)
                .background(hover ? t3.web.accent.color : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Copy message")
    }
}

// MARK: - Folds and separators

/// `TurnFoldTimelineRow` (`:1539`). The label is the reducer's
/// ("Worked for 2m 14s").
private struct T3TurnFoldRow: View {
    let turnId: String
    let label: String
    let expanded: Bool
    let onToggle: (String) -> Void
    @Environment(\.t3) private var t3
    @State private var hover = false

    var body: some View {
        // `border-b border-border/60 pb-2 pt-1` (`:1544`).
        VStack(spacing: 0) {
            Button { onToggle(turnId) } label: {
                // `flex items-center gap-1 rounded-md px-1 text-sm leading-relaxed
                // text-muted-foreground tabular-nums` (`:1551`).
                HStack(spacing: 4) {
                    Text(label)
                    LucideIcon(expanded ? .chevronDown : .chevronRight, size: 14)   // size-3.5
                }
                .font(T3Font.web(.sm))
                .monospacedDigit()
                .foregroundStyle(hover ? t3.web.foreground.color : t3.web.mutedForeground.color)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .padding(.top, 4)
            .padding(.bottom, 8)
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }
}

/// `ContextCompactionTimelineRow` (`:1236`).
private struct T3ContextCompactionRow: View {
    let label: String
    @Environment(\.t3) private var t3

    var body: some View {
        // `flex w-full max-w-3xl items-center gap-3 py-1 text-muted-foreground
        // text-xs` with `h-px bg-border/70` rules either side (`:1245-1252`).
        HStack(spacing: 12) {
            rule
            HStack(spacing: 6) {
                LucideIcon(.minimize2, size: 12)   // size-3
                Text(label)
            }
            .font(T3Font.web(.xs))
            rule
        }
        .foregroundStyle(t3.web.mutedForeground.color)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }

    private var rule: some View {
        Rectangle().fill(t3.web.border.color.opacity(0.7)).frame(height: 1)
    }
}

// MARK: - Live rows

/// `WorkingTimelineRow` (`:1707`).
///
/// **The timer.** Upstream's `WorkingTimer` (`:1769`) rewrites its own text
/// node every second. This port deliberately does not tick: the label is
/// formatted off `T3WindowModel.now`, the 60 s key-window tick, exactly the way
/// `formatWorkingTimer` (`:2677`) formats it — a per-second SwiftUI update
/// would commit a CA transaction per second for as long as a turn runs, which
/// is the one thing the workspace window may not do (#18).
private struct T3WorkingRow: View {
    let createdAt: Date?
    let now: Date
    @Environment(\.t3) private var t3

    var body: some View {
        // `border-b border-border/60 pb-2 pt-1` over an `h-6 px-1 text-sm
        // leading-relaxed text-muted-foreground tabular-nums` line (`:1710-1713`).
        VStack(spacing: 0) {
            Text(label)
                .font(T3Font.web(.sm))
                .monospacedDigit()
                .foregroundStyle(t3.web.mutedForeground.color)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 24, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }

    private var label: String {
        guard let createdAt else { return "Working..." }
        return "Working for \(T3WorkingTimer.label(from: createdAt, to: now))"
    }
}

/// `formatWorkingTimer` (`:2677`): whole seconds under a minute, then
/// `formatDuration` (ported as `T3WorkLog.formatDuration`, which takes seconds
/// where upstream passes milliseconds).
enum T3WorkingTimer {
    static func label(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        return T3WorkLog.formatDuration(Double(seconds))
    }
}

/// `ThinkingTimelineRow` (`:1742`): a `min-h-7` slot holding the shimmering
/// "Thinking" activity row. B has no `isPreparingWorktree`/`isCompacting`, so
/// the slot is never reserved-empty.
private struct T3ThinkingRow: View {
    var body: some View {
        T3LiveActivityRow(label: "Thinking", icon: T3WorkEntryIcon.thinking, failed: false,
                          active: true, shimmer: true)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
}

/// `LiveActivityRow` (`:2014`) + `LiveActivityContent` (`:2050`).
private struct T3LiveActivityRow: View {
    let label: String
    let icon: Lucide?
    let failed: Bool
    let active: Bool
    let shimmer: Bool
    @Environment(\.t3) private var t3

    /// `toolIconAcceptsTint` (`:1996`): B resolves every icon to a stroked
    /// lucide glyph (no favicons, no gradient computer mark), so every icon
    /// takes the tint and the trailing failure ✕ never shows here.
    private var animated: Bool { active && !failed }

    var body: some View {
        // `relative min-h-6 w-fit max-w-full min-w-0 overflow-hidden rounded-md
        // text-sm leading-relaxed` (`:2035`).
        HStack(spacing: 6) {   // gap-1.5
            if let icon {
                // `flex size-6 shrink-0 items-center justify-center` with a
                // `size-4 stroke-[1.8]` glyph (`:2081-2095`).
                LucideIcon(icon, size: 16, strokeWidth: 1.8)
                    .foregroundStyle(failed ? t3.web.toolErrorIcon.color.opacity(0.4)
                                            : t3.web.iconMuted.color)
                    .frame(width: 24, height: 24)
            }
            text
        }
        .padding(.horizontal, icon == nil ? 4 : 2)   // px-1 / px-0.5
        .padding(.vertical, 2)                       // py-0.5
        .frame(minHeight: 24, alignment: .leading)
    }

    @ViewBuilder private var text: some View {
        let base = Text(label).font(T3Font.web(.sm)).lineLimit(1).truncationMode(.tail)
        if animated && shimmer {
            // `ActivityShimmerOverlay` (`:1979`) / `live-tool-shine` (`:2098`):
            // the SwiftUI text lays the row out, `T3ShimmerLabel` draws it.
            base.hidden()
                // `.equatable()`: `LayerEffect.updateNSView` reinstalls its
                // layers, which restarts the sweep from phase 0, so an update
                // with unchanged inputs must not reach it. SwiftUI happens to
                // elide it here already (measured), but only through its own
                // structural comparison of the view value — this states it.
                .overlay(T3ShimmerLabel(text: label, fontSize: T3TypeScale.Web.sm.step.size,
                                        base: t3.web.secondaryLabel,
                                        highlight: t3.web.foreground).equatable())
        } else {
            base.foregroundStyle(t3.web.secondaryLabel.color)
        }
    }
}

/// `LiveWorkEntryTimelineRow` (`:2106`): the group's newest in-flight entry,
/// as a button that expands the group.
private struct T3LiveWorkEntryRow: View {
    let entry: T3WorkLogEntry
    let groupId: String
    let expanded: Bool
    let active: Bool
    let onToggle: (String) -> Void

    var body: some View {
        Button { onToggle(groupId) } label: {
            T3LiveActivityRow(label: T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: active),
                              icon: T3WorkEntryIcon.icon(entry),
                              failed: T3WorkLog.displayIndicatesFailure(entry),
                              // `active={row.active}` with no `shimmer` prop
                              // (`:2124`): the label carries `live-tool-shine`.
                              active: active, shimmer: active)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Work groups

/// `WorkGroupToggleTimelineRow` (`:2160`): the collapsed group header — tool
/// icon plus summary, nothing else. Upstream renders neither a chevron nor
/// `hiddenCount` (the reducer sets it, no view reads it), so neither is drawn
/// here; the task brief's "chevron, hidden count" is the plan's prose losing to
/// the source. `hasFailure` upstream only reaches the accessibility label —
/// the brief asks for the icon tint as well, so the icon takes
/// `failedToolIconClassName` (`text-tool-error-icon/40`, `:1992`).
private struct T3WorkGroupToggleRow: View {
    let groupId: String
    let expanded: Bool
    let summary: String
    let summaryKind: T3WorkLog.SummaryKind
    let toolSurface: String?
    let summaryToolIcon: T3WorkLog.ToolPresentation.Icon?
    let hasFailure: Bool
    let onToggle: (String) -> Void
    @Environment(\.t3) private var t3
    @State private var hover = false

    var body: some View {
        Button { onToggle(groupId) } label: {
            // `min-h-6 items-center gap-1.5 rounded-md px-0.5 py-0.5 text-sm
            // leading-relaxed … hover:bg-accent/20` (`:2170`).
            HStack(spacing: 6) {
                LucideIcon(icon, size: 16, strokeWidth: 1.8)
                    .foregroundStyle(hasFailure ? t3.web.toolErrorIcon.color.opacity(0.4)
                                                : t3.web.iconMuted.color)
                    .frame(width: 24, height: 24)
                Text(summary)
                    .font(T3Font.web(.sm))
                    .foregroundStyle(t3.web.secondaryLabel.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(2)
            .frame(minHeight: 24)
            .background(hover ? t3.web.accent.color.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(hasFailure ? "\(summary), tool call failed" : summary)
    }

    /// `fallbackName={row.summaryToolIcon ?? row.toolSurface ??
    /// toolGroupSummaryIconName(row.summaryKind)}` (`:2178`).
    private var icon: Lucide {
        if let summaryToolIcon { return T3WorkEntryIcon.icon(summaryToolIcon) }
        if let toolSurface, let surface = T3WorkEntryIcon.surface(toolSurface) { return surface }
        return T3WorkEntryIcon.summary(summaryKind)
    }
}

/// `WorkGroupSection` (`:1797`) and, for an expanded group,
/// `ExpandedWorkGroupEntries` (`:1848`) — a bounded, scrolling list.
/// Upstream's virtualization, scroll-position memory and edge fades are
/// `LegendList` plumbing with no value-type shape; the bound
/// (`max-h-[min(18rem,50dvh)]`) and the entry padding are what show.
private struct T3WorkGroupSection: View {
    let anchorKey: String
    let groupedEntries: [T3WorkLogEntry]
    let isExpandedToolGroup: Bool
    let displayLabel: String?

    private var entries: [T3WorkLogEntry] {
        groupedEntries.filter { T3WorkLog.isVisibleInGroup($0, expandedToolGroupEntry: isExpandedToolGroup) }
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else if isExpandedToolGroup {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        T3WorkEntryRow(entry: entry, displayLabel: nil, inExpandedGroup: true)
                    }
                }
            }
            .frame(maxHeight: 288)       // 18rem; the 50dvh half of the min() needs no port
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            // `-mx-1 space-y-0.5 px-1 py-0.5` over `space-y-px` rows
            // (`:1830-1843`): the negative margin and the padding cancel, so
            // only the 1 pt row gap and the 2 pt band remain.
            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    T3WorkEntryRow(entry: entry, displayLabel: displayLabel, inExpandedGroup: false)
                }
            }
            .padding(.vertical, 2)
            .accessibilityLabel("Activity")
        }
    }
}

/// `SimpleWorkEntryRow`/`PlainWorkEntryRow` (`:3148`, `:3171`): icon, label,
/// and — when there is more than the label to show — a chevron that opens
/// `buildToolCallExpandedBody` (`:2989`). `workEntrySignalsSevereFailure` has
/// no Core port, so the destructive row style falls back to its other disjunct
/// (a failing row that is not tool-like).
private struct T3WorkEntryRow: View {
    let entry: T3WorkLogEntry
    let displayLabel: String?
    let inExpandedGroup: Bool
    @Environment(\.t3) private var t3
    @State private var expanded = false
    @State private var hover = false

    private var warning: Bool { entry.sourceActivityKind == "runtime.warning" }
    private var failed: Bool { T3WorkLog.displayIndicatesFailure(entry) }
    private var destructive: Bool { failed && !T3WorkLog.isToolLike(entry) }
    private var previewText: String { displayLabel ?? T3WorkLog.displayLabel(entry, workspaceRoot: nil) }
    private var commandMatchesLabel: Bool {
        entry.command?.trimmingCharacters(in: .whitespacesAndNewlines) == previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var expandedBody: String? {
        T3ToolCallBody.build(entry, visibleLabel: previewText)
    }
    private var canExpand: Bool {
        if failed && !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return expandedBody != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `flex select-none items-center gap-1.5` (`:3277`).
            HStack(spacing: 6) {
                LucideIcon(warning || destructive ? .circleAlert : T3WorkEntryIcon.icon(entry),
                           size: 16, strokeWidth: 1.8)
                    .foregroundStyle(iconColour)
                    .frame(width: 24, height: 24)
                Text(previewText)
                    .font(T3Font.web(.sm))
                    .fontWeight(warning || destructive ? .medium : .regular)
                    .foregroundStyle(headingColour)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    // Upstream's expanded label is `select-text`; selectable
                    // text swallows the click that collapses the row again, so
                    // only the expanded body below is selectable here.
                    .frame(maxWidth: .infinity, alignment: .leading)
                // `size-4` slot, `invisible` when the row cannot expand (`:3319`).
                LucideIcon(.chevronRight, size: 12)
                    .foregroundStyle(t3.web.iconMuted.color.opacity(0.7))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .opacity(canExpand ? 1 : 0)
            }
            if expanded, canExpand, let expandedBody {
                // `mt-1 ms-7 rounded-md bg-muted/40 px-3 py-2` around a
                // `max-h-64 font-mono text-[11px] text-secondary-label` pre
                // (`:3037-3038`, `:3355-3361`).
                ScrollView {
                    Text(expandedBody)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t3.web.secondaryLabel.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 256)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(t3.web.muted.color.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 4)
                .padding(.leading, 28)
            }
        }
        // `rounded-md px-0.5` with `py-0` inside an expanded group, else `py-0.5`.
        .padding(.horizontal, 2)
        .padding(.vertical, inExpandedGroup ? 0 : 2)
        .background(canExpand && hover ? t3.web.accent.color.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .accessibilityLabel(failed ? "\(previewText), tool call failed" : previewText)
        .accessibilityAddTraits(canExpand ? .isButton : [])
        .onTapGesture { if canExpand { expanded.toggle() } }
    }

    // `iconWrapperClass` (`:3235-3246`) over `workToneIcon` (`:2951`).
    private var iconColour: Color {
        if warning { return t3.web.warning.color }
        if destructive { return t3.web.destructive.color }
        if failed { return t3.web.toolErrorIcon.color.opacity(0.4) }
        if entry.tone == .tool { return t3.web.iconMuted.color }
        return entry.tone == .info ? t3.web.iconMuted.color : t3.web.foreground.color
    }

    // `headingClass` (`:3247-3253`).
    private var headingColour: Color {
        if warning { return t3.web.warning.color }
        if destructive { return t3.web.destructive.color }
        return T3WorkLog.isToolLike(entry) ? t3.web.secondaryLabel.color
                                           : t3.web.foreground.color.opacity(0.8)
    }
}

/// `buildToolCallExpandedBody` (`:2989`), minus the MCP `toolData` blob (no
/// such field on B's entry) and the viewed-image path (no asset route).
enum T3ToolCallBody {
    static func build(_ entry: T3WorkLogEntry, visibleLabel: String) -> String? {
        var blocks: [String] = []
        var seen = Set([visibleLabel.trimmingCharacters(in: .whitespacesAndNewlines)])
        func add(_ value: String?) {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            blocks.append(text)
        }
        let command = entry.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == visibleLabel.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let command { seen.insert(command) }
        } else {
            add(entry.rawCommand ?? command)
        }
        add(entry.detail)
        var changed: [String] = []
        for path in entry.changedFiles {
            let formatted = T3WorkLog.formatWorkspaceRelativePath(path, workspaceRoot: nil)
            guard formatted != entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !changed.contains(formatted) else { continue }
            changed.append(formatted)
        }
        if !changed.isEmpty { add(changed.joined(separator: "\n")) }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}

// MARK: - Proposed plan

/// `ProposedPlanTimelineRow` (`:1687`) + `ProposedPlanCard.tsx`. B has no
/// producer for a proposed plan yet (a parked `ExitPlanMode` arrives as an
/// `approval.requested` activity), so the card is the shape without the
/// download/save actions — neither has a host action here; "Copy to clipboard"
/// does.
private struct T3ProposedPlanCard: View {
    let plan: T3ProposedPlan
    /// The parked `ExitPlanMode` is the prompt on top, so a verdict reaches it.
    let isActionable: Bool
    let onImplement: () -> Void
    let onEdit: (String) -> Void
    @Environment(\.t3) private var t3
    @State private var expanded = false

    // `proposedPlanTitle` (`proposedPlan.ts:1`): the first markdown heading.
    private var title: String {
        for line in plan.planMarkdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return "Proposed plan"
    }
    // `canCollapse` (`ProposedPlanCard.tsx:69`).
    private var canCollapse: Bool {
        plan.planMarkdown.count > 900
            || plan.planMarkdown.split(separator: "\n", omittingEmptySubsequences: false).count > 20
    }

    var body: some View {
        // `rounded-[24px] border border-border/80 bg-card/70 p-4 sm:p-5`.
        VStack(alignment: .leading, spacing: 16) {   // the body's own `mt-4`
            HStack(spacing: 8) {
                T3Badge("Plan", variant: .secondary)
                Text(title)
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Menu {
                    Button("Copy to clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.planMarkdown, forType: .string)
                    }
                } label: {
                    LucideIcon(.ellipsis, size: 16)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .accessibilityLabel("Plan actions")
            }
            VStack(spacing: 16) {
                body_
                if canCollapse {
                    T3Button(expanded ? "Collapse plan" : "Expand plan", variant: .outline, size: .sm) {
                        expanded.toggle()
                    }
                }
                if isActionable { actions }
            }
        }
        .padding(20)
        .background(t3.web.card.color.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(t3.web.border.color.opacity(0.8), lineWidth: 1))
    }

    /// Upstream answers a plan from the composer, not from the card: "Implement"
    /// is the composer's primary action while the plan is the follow-up prompt
    /// (`ComposerPrimaryActions.tsx:165-218`) and refining it means typing over
    /// the plan there ("Refine", `:179`). B has no such composer yet (Task 13),
    /// so the two live on the card: Implement allows the parked `ExitPlanMode`,
    /// and Edit puts the plan's markdown in the composer's draft
    /// (`T3WindowModel.pendingComposerInsert`) for the user to change first.
    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            T3Button("Edit", variant: .outline, size: .sm) { onEdit(plan.planMarkdown) }
            T3Button("Implement", size: .sm, action: onImplement)
        }
    }

    @ViewBuilder private var body_: some View {
        let markdown = T3ChatMarkdown(text: plan.planMarkdown)
            .frame(maxWidth: .infinity, alignment: .leading)
        if canCollapse && !expanded {
            // `max-h-104` (416) with the `h-24` card fade over it.
            markdown
                .frame(maxHeight: 416, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [t3.web.card.color.opacity(0), t3.web.card.color.opacity(0.8),
                                            t3.web.card.color.opacity(0.95)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                        .allowsHitTesting(false)
                }
        } else {
            markdown
        }
    }
}

// MARK: - Icons and timestamps

/// `WorkEntryIconName` (`:2697`) → the vendored `Lucide` set, plus
/// `workEntryIconName` (`:3040`), `toolGroupSummaryIconName` (`:2130`) and
/// `workToneIcon` (`:2951`).
///
/// `Lucide.generated.swift`'s case set is generated from T3's own imports, and
/// four of the names this switch needs are not among them: `brain`,
/// `square-pen`, `wrench`/`hammer` and the custom `browser`/`computer`/
/// `t3-code` marks. Each falls back to the nearest vendored glyph below rather
/// than an SF Symbol (which would break the stroked-lucide look of the column).
enum T3WorkEntryIcon {
    /// `brain` is not vendored — the sparkle is the nearest "thinking" glyph.
    static let thinking = Lucide.sparkles

    static func icon(_ entry: T3WorkLogEntry) -> Lucide {
        if entry.sourceActivityKind == "user-input.requested"
            || entry.sourceActivityKind == "user-input.resolved" {
            return .messageCircle
        }
        if let name = entry.toolSurface, let icon = surface(name) { return icon }
        if let presentation = T3WorkLog.toolPresentation(entry) { return icon(presentation.icon) }
        let action = T3WorkLog.groupAction(entry)
        // Every `GroupAction` raw value is a `SummaryKind` raw value by
        // construction (both mirror `toolGroupSummaryIconName`'s cases), so the
        // fallback is unreachable, not a second behaviour.
        if action != .other { return summary(T3WorkLog.SummaryKind(rawValue: action.rawValue) ?? .other) }
        switch entry.itemType {
        case .mcpToolCall: return tool          // "wrench"
        case .dynamicToolCall: return tool      // "hammer"
        case .collabAgentToolCall: return .bot
        default: break
        }
        if entry.taskId != nil { return .bot }
        // `workToneIcon` (`:2951`).
        switch entry.tone {
        case .error: return .circleAlert
        case .thinking: return thinking
        case .info: return .check
        case .tool: return .zap
        }
    }

    /// `toolGroupSummaryIconName` (`:2130`).
    static func summary(_ kind: T3WorkLog.SummaryKind) -> Lucide {
        switch kind {
        case .read: return .eye
        case .edit: return pen
        case .command: return .terminal
        case .browser: return browser
        case .search: return .globe
        case .codeSearch: return .search
        case .other: return tool
        case .dynamicTool: return tool
        case .agentTool: return .bot
        case .toneTool: return .zap
        case .update, .mixed: return tool
        }
    }

    /// `ToolActivityIconView`'s structured icon (`:2759`).
    static func icon(_ icon: T3WorkLog.ToolPresentation.Icon) -> Lucide {
        switch icon {
        case .browser: return browser
        case .t3Code: return .code2   // the T3 mark is not a lucide glyph
        }
    }

    /// A `toolSurface` upstream names a `WorkEntryIconName` directly.
    static func surface(_ name: String) -> Lucide? {
        switch name {
        case "browser": return browser
        case "computer": return .laptop        // the gradient computer mark is not vendored
        case "terminal": return .terminal
        case "eye": return .eye
        case "globe": return .globe
        case "search": return .search
        case "bot": return .bot
        case "zap": return .zap
        case "check": return .check
        case "x": return .x
        case "circle-alert": return .circleAlert
        case "message-circle": return .messageCircle
        case "square-pen": return pen
        case "wrench", "hammer": return tool
        case "brain": return thinking
        case "t3-code": return .code2
        default: return nil
        }
    }

    /// `wrench`/`hammer` are not vendored; the gear is the nearest tool mark.
    private static let tool = Lucide.settings
    /// `square-pen` is not vendored.
    private static let pen = Lucide.penLine
    /// The custom `BrowserAppIcon` (`:2704`) is a window frame; the display is
    /// the nearest vendored mark.
    private static let browser = Lucide.monitor
}

/// `formatDayAwareTimestamp` (`timestampFormat.ts:140`): today the wall clock,
/// yesterday "yesterday at …", older the numeric date first — local calendar
/// days, and the year once it differs.
enum T3ChatTimestamp {
    static func dayAware(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return "yesterday at \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = calendar.component(.day, from: date), month = calendar.component(.month, from: date)
        return sameYear ? "\(month)/\(day) \(time)"
                        : "\(month)/\(day)/\(calendar.component(.year, from: date)) \(time)"
    }
}
