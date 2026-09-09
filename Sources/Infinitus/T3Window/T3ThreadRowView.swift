import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// One sidebar row (`Sidebar.tsx`'s `SidebarThreadRow`), in both of the
/// variants upstream renders. `Sidebar.tsx:4627`:
/// `const isCard = section === "active" || section === "pinned"` — settling
/// and snoozing are the ONLY things that collapse a row, so pinned/active
/// rows are 78 pt two-line CARDS (`:1723-1815`) and snoozed/settled rows are
/// the 36 pt SLIM row (`:1538-1636`). The B-3 review found this port had
/// only ever built the slim row and used it everywhere.
///
/// Both variants share `rowSurfaceClassName` (`:1359-1379`) and the leading
/// project icon (`ProjectFavicon.tsx`, ported as `T3ProjectGlyph`/
/// `T3ProjectIcon`). What differs: the card carries the project display name
/// and the `topStatus` pill on its own first line (`:1725-1770`) with the
/// thread title below (`:1873-1880`); the slim row is one line whose only
/// trailing content is a time label (`:1628-1637`) — never a pill.
///
/// Right-click ports `buildThreadActionMenuItems`
/// (`threadActionMenu.logic.ts`), keeping only pin/unpin, settle/unsettle,
/// snooze ▸ presets, wake and Copy ▸ Path/Thread ID — `rename`,
/// `regenerate-title`, `mark-unread`, `project-settings`, `archive`,
/// `delete` and `new-thread-on-branch` have no host action on B yet (task
/// brief's own deviation table) and are omitted rather than stubbed.
struct T3ThreadRowView: View {
    /// `Sidebar.tsx:4626-4628`'s `rowVariant`.
    enum Variant { case card, slim }
    /// `Sidebar.tsx:4637-4643`'s `variantAction`: a snoozed row wakes, a
    /// settled row un-settles, a card settles. The slim row reads it to pick
    /// its trailing label (`:1606`, `:1633-1635`).
    enum VariantAction { case settle, unsettle, unsnooze }

    let thread: T3Thread
    /// Only for `cachedBranch`/`gitBranch` — the row reads no published
    /// state off it, so it is a plain reference, not an `@ObservedObject`.
    let model: T3WindowModel
    let variant: Variant
    let variantAction: VariantAction
    let selected: Bool
    let now: Date
    let onSelect: () -> Void
    let onAttention: (AttentionStore.Action, Date?) -> Void
    /// Resolved by `T3SidebarView` from `model.state.projects` — `T3Thread`
    /// itself carries no path/name (no `cwd` field yet). Both default to
    /// `""`, which `T3ProjectIcon.select` degrades gracefully over (same as
    /// upstream's own `cwd={props.projectCwd ?? ""}`), and `nil` hides
    /// "Copy > Path". Upstream splits this into `projectTitle` (what the
    /// icon classifies over) and `projectDisplayName` (the card's first-line
    /// label); B's `ProjectSummary` carries one name, used for both.
    var projectName: String? = nil
    var projectCwd: String? = nil

    @Environment(\.t3) private var t3
    @State private var hover = false
    /// The card's branch line. Filled from `T3WindowModel`'s cache — one git
    /// call per distinct project cwd, on the thread's own `.task`, never a
    /// timer (`T3GitFacts`, B-6).
    @State private var branch: String?

    private var status: T3ThreadStatus { T3ThreadStatus(thread) }
    private var style: T3SidebarList.RowStyle { T3SidebarList.rowStyle(isActive: selected, isSelected: false) }
    private var p: T3Theme.WebPalette { t3.web }
    private var isUnread: Bool { T3SidebarList.hasUnseenCompletion(thread) }

    /// `shouldRecedeSidebarThread` (`Sidebar.logic.ts:798-811`): the open row
    /// never recedes; background work (working/monitoring) always does; a
    /// resting row recedes unless it has an unread completion. B models
    /// neither `monitoring` nor `isWoke` (no `backgroundLiveness`/`wokeAt`
    /// on `T3Thread`), so both read false here.
    private var recede: Bool {
        if selected { return false }
        switch status {
        case .working: return true
        case .ready, .approval, .input: return !isUnread
        case .failed: return false
        }
    }

    var body: some View {
        Group {
            switch variant {
            case .card: card
            case .slim: slim
            }
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu { menu }
        // `:1698-1701`: the card's own `<li className="list-none py-0.5">`
        // sits 2 pt clear of its neighbours; the slim `li` (`:1541-1547`)
        // has no such padding.
        .padding(.vertical, variant == .card ? 2 : 0)
    }

    // MARK: - Card (`Sidebar.tsx:1723-1897`)

    // `:1723` `h-[4.875rem] px-[var(--sidebar-row-content-inset)]
    // py-[var(--sidebar-content-inset)]` — 78 pt tall, 10 pt sides, 8 pt
    // top/bottom. The three content rows sum to exactly that height:
    // 8 + 20 (`h-5`) + 4 (`mt-1`) + 20 (`text-sm` line height) + 2
    // (`mt-0.5`) + 16 (`text-xs` line height) + 8 = 78.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTopLine
            // `:1873` `<div className="mt-1 flex min-w-0">{title}</div>`.
            titleText
                .frame(maxWidth: .infinity, minHeight: T3TypeScale.Web.sm.step.lineHeight, alignment: .leading)
                .padding(.top, 4)
            // `:1883-1897`: the branch line, `mt-0.5 flex min-w-0
            // items-center gap-1.5 text-secondary-label text-xs`. With no
            // branch it is upstream's bare `<span className="flex-1" />`
            // (`:1896`), which still occupies its line's height.
            branchLine
                .frame(maxWidth: .infinity, minHeight: T3TypeScale.Web.xs.step.lineHeight)
                .padding(.top, 2)
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .padding(.vertical, T3Theme.Metrics.sidebarContentInset)
        .frame(height: 78)
    }

    // `:1885-1896`'s branch span — `min-w-0 flex-1 truncate whitespace-nowrap
    // text-muted-foreground/40`, with no leading glyph (the `size-3`
    // `FolderGit2Icon` before it is `ThreadWorktreeIndicator`
    // (`ThreadStatusIndicators.tsx:188-196`), which renders null without a
    // worktree — B has none) — and `:1906-1934`'s `ml-auto` trailing span,
    // whose `ProviderInstanceIcon` is `size-3.5 opacity-60`. `showBadge` and
    // the remote-machine glyph beside it have no B counterpart; the driver
    // kind always resolves (every thread here runs Claude Code), which is
    // data, not an ungated glyph.
    private var branchLine: some View {
        HStack(spacing: 6) {
            if let branch {
                Text(branch)
                    .font(T3Font.web(.xs))
                    .foregroundStyle(p.mutedForeground.color.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            T3ProviderIcon(size: 14).opacity(0.6)
        }
        .task(id: thread.id) {
            guard let cwd = projectCwd, !cwd.isEmpty else { return }
            branch = model.cachedBranch(cwd: cwd)
            // Cache-first and de-duplicated per cwd inside the model, so N
            // rows on one project are still ONE `git rev-parse`.
            branch = await model.gitBranch(cwd: cwd)
        }
    }

    // `:1725` `flex h-5 min-w-0 items-center gap-1.5`.
    private var cardTopLine: some View {
        HStack(spacing: 6) {
            // `:1735` `className="size-4 shrink-0"` — the row's override of
            // ProjectFavicon's own default 14 pt.
            T3ProjectGlyph(projectName: projectName ?? "", projectCwd: projectCwd ?? "", size: 16)
            // `:1737-1747`: `min-w-0 flex-1 truncate text-secondary-label
            // text-xs`, `font-medium` unless the row recedes.
            Text(projectName ?? "")
                .font(T3Font.web(.xs, recede ? .regular : .medium))
                .foregroundStyle(p.secondaryLabel.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // `:1755-1758`'s status slot: `ml-auto flex h-5 min-w-8 shrink-0
            // items-stretch justify-end text-xs` — the `topStatus` pill when
            // there is one, otherwise `threadTimeLabel(thread)` (`:1811`).
            cardStatusSlot
                .frame(minWidth: 32, alignment: .trailing)
        }
        .frame(height: 20)
    }

    @ViewBuilder private var cardStatusSlot: some View {
        if let pillLabel {
            // `:1789-1806`: `inline-flex items-center gap-1 font-medium` +
            // `topStatus.className`.
            HStack(spacing: 4) {
                // `topStatus.icon`: "working" → CircleDashed (spinning in
                // this brief's own instruction, so T3Spinner/LayerEffect
                // rather than upstream's static glyph — see #18's idle-CPU
                // rule); "done" → CircleCheck; every other status has none.
                // Both render at 16 pt (`:1796`/`:1798`'s "size-4 shrink-0").
                // T3Spinner's stroke is the kit's fixed muted colour, not
                // re-tinted to the pill's sky hue (not modifying A's shared
                // component for one B row) — the label text still carries it.
                if status == .working { T3Spinner(size: 16) }
                else if pillLabel == "Done" { LucideIcon(.circleCheck, size: 16) }
                Text(pillLabel).font(T3Font.web(.xs, .medium))
            }
            .foregroundStyle(pillColor)
            // working's `className` is `cn("text-sky-600 dark:text-sky-400",
            // !props.isActive && "opacity-75")` (`:1127`) — working recedes
            // to 75% when its row isn't the open thread; every other status
            // stays full strength.
            .opacity(status == .working && !selected ? 0.75 : 1)
        } else {
            Text(T3RelativeTime.label(from: thread.latestUserMessageAt ?? thread.updatedAt, now: now))
                .font(T3Font.web(.xs))
                .foregroundStyle(p.secondaryLabel.color)   // `:1751` "text-secondary-label"
        }
    }

    // MARK: - Slim (`Sidebar.tsx:1538-1636`)

    // `:1561` `flex h-9 items-center gap-2.5 px-2.5` on top of the shared
    // row surface.
    private var slim: some View {
        HStack(spacing: 10) {
            // `:1566-1583`: settled history recedes — the favicon is dimmed
            // and desaturated at rest, restored on hover.
            T3ProjectGlyph(projectName: projectName ?? "", projectCwd: projectCwd ?? "", size: 16)
                .opacity(!selected && !hover ? 0.4 : 1)
                .grayscale(!selected && !hover ? 1 : 0)
            titleText
            Spacer(minLength: 0)
            // `:1596-1637`: `relative ml-auto flex h-6 min-w-8 shrink-0
            // items-center justify-end`, holding a time label and nothing
            // else — the slim row never renders `topStatus`.
            slimTimeLabel
                .frame(minWidth: 32, alignment: .trailing)
                .frame(height: 24)
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .frame(height: 36)
        .foregroundStyle(style.foreground == .foreground ? p.sidebarForeground.color : p.sidebarMutedForeground.color.opacity(0.8))
    }

    @ViewBuilder private var slimTimeLabel: some View {
        // `:1606-1611`: a snoozed row shows when it comes BACK, not when it
        // was last touched — `snoozeWakeLabel` in `text-blue-600
        // dark:text-blue-400` (`T3ThreadSettled.snoozeWakeLabel` is that
        // formatter's port).
        if variantAction == .unsnooze, let until = thread.snoozedUntil {
            Text(T3ThreadSettled.snoozeWakeLabel(until: until, now: now))
                .font(T3Font.web(.xs))
                .foregroundStyle((t3.scheme == .dark ? T3Tailwind.blue400 : T3Tailwind.blue600).color)
        } else {
            // `:1633-1635`: settled rows read "how long ago did this wrap
            // up" through `settledTimeLabel` (`:252-255`,
            // `resolveSettledThreadTimestamp` → `T3ThreadSort.settledTimestamp`,
            // empty when there is no timestamp), every other slim row
            // through `threadTimeLabel`.
            Text(slimTimeText)
                .font(T3Font.web(.xs))
                .foregroundStyle(p.secondaryLabel.color)
        }
    }

    private var slimTimeText: String {
        if variantAction == .unsettle {
            guard let settled = T3ThreadSort.settledTimestamp(thread) else { return "" }
            return T3RelativeTime.label(from: settled, now: now)
        }
        return T3RelativeTime.label(from: thread.latestUserMessageAt ?? thread.updatedAt, now: now)
    }

    // MARK: - Shared pieces

    // `:1421-1447`'s title span: `min-w-0 flex-1 truncate text-sm`,
    // `font-medium` unless the row recedes, with a per-variant colour ramp.
    private var titleText: some View {
        Text(thread.title)
            .font(T3Font.web(.sm, recede ? .regular : .medium))
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var titleColor: Color {
        switch variant {
        // `:1425-1433`: recede → text-secondary-label; unread → text-foreground;
        // failed → text-foreground/95; otherwise text-foreground/90.
        case .card:
            if recede { return p.secondaryLabel.color }
            if isUnread { return p.foreground.color }
            return p.foreground.color.opacity(status == .failed ? 0.95 : 0.90)
        // `:1435-1443`: `group-hover:text-foreground`, then recede →
        // text-secondary-label/70; the open row → text-foreground; unread →
        // text-muted-foreground; otherwise text-secondary-label/70.
        case .slim:
            if hover { return p.foreground.color }
            if recede { return p.secondaryLabel.color.opacity(0.7) }
            if selected { return p.foreground.color }
            if isUnread { return p.mutedForeground.color }
            return p.secondaryLabel.color.opacity(0.7)
        }
    }

    // `rowSurfaceClassName` (`:1359-1372`), shared by both variants.
    private var rowBackground: Color {
        switch style.background {
        case .active: return p.sidebarRowActive.color
        case .selected: return p.sidebarRowSelected.color
        case .none: return hover ? p.sidebarRowHover.color : .clear
        }
    }

    // MARK: - The card's status pill

    // `Sidebar.tsx`'s `topStatus` (:1117-1167) for the four statuses B's
    // `T3ThreadStatus` actually carries, plus the unread-completion "Done"
    // pill (:1161-1166's `isUnread` branch) — "Monitoring" and "Woke" have no
    // B equivalent (no `backgroundLiveness`/`wokeAt` field on `T3Thread`) and
    // are omitted, not stubbed.
    private var pillLabel: String? {
        switch status {
        case .working: return "Working"
        case .approval: return "Approval"
        case .input: return "Input"
        case .failed: return "Failed"
        case .ready: return isUnread ? "Done" : nil
        }
    }

    // The `text-{hue}-{600|700}` / `dark:text-{hue}-{400|300}` pair from each
    // `topStatus.className` (`:1127`, `:1141`, `:1147`, `:1153`, `:1165`),
    // read from the generated tailwindcss@4.3.3 stops — never hand-typed,
    // and NOT v3's hex (see `T3TailwindPalette.generated.swift`).
    private var pillColor: Color {
        let (light, dark): (T3ProjectIcon.RGB, T3ProjectIcon.RGB)
        switch status {
        case .working: (light, dark) = (T3Tailwind.sky600, T3Tailwind.sky400)
        case .approval: (light, dark) = (T3Tailwind.amber700, T3Tailwind.amber300)
        case .input: (light, dark) = (T3Tailwind.indigo600, T3Tailwind.indigo300)
        case .failed: (light, dark) = (T3Tailwind.red700, T3Tailwind.red300)
        case .ready: (light, dark) = (T3Tailwind.emerald700, T3Tailwind.emerald300)   // "Done"
        }
        return (t3.scheme == .dark ? dark : light).color
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

/// Core carries its colours as plain 0-255 components (`T3ProjectIcon.RGB`)
/// because `InfinitusCore` may not depend on `InfinitusUI` — this is the one
/// place they become SwiftUI colours.
extension T3ProjectIcon.RGB {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}

/// `ProjectFavicon.tsx`'s automatic-icon path (`selectProjectIcon` +
/// `PROJECT_ICONS`, fix round 1 R2): a bare coloured Lucide glyph — no
/// background box, no radius, no letter fallback (upstream has none of those
/// for the automatic path; the favicon-image and emoji-override branches have
/// no B equivalent, see `T3ProjectIcon`'s header comment). `size` is the
/// caller's own class: 16 in the sidebar rows (`Sidebar.tsx:1735`/`:1580`'s
/// `size-4`), 14 in the breadcrumb (`ChatHeader.tsx:351`'s `size-3.5`).
struct T3ProjectGlyph: View {
    let projectName: String
    let projectCwd: String
    var size: Double = 16
    @Environment(\.t3) private var t3

    var body: some View {
        // One `select` per body: it tokenises and scores the project name,
        // and a row re-evaluates its body on every hover (#18's idle-CPU
        // rule is about work per frame, not just about timers).
        let icon = T3ProjectIcon.select(name: projectName, cwd: projectCwd)
        let pair = T3ProjectIcon.color(for: icon)
        LucideIcon(Self.lucide(icon), size: size)
            .foregroundStyle((t3.scheme == .dark ? pair.dark : pair.light).color)
    }

    // `PROJECT_ICONS` (`ProjectFavicon.tsx:44-65`): each `ProjectIconName` →
    // its Lucide component, transcribed to this kit's vendored names.
    private static func lucide(_ icon: T3ProjectIcon.Name) -> Lucide {
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
}
