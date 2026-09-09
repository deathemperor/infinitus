import SwiftUI
import InfinitusCore
import InfinitusUI

/// ⌘K's thread switcher: T3's command palette (`CommandPalette.tsx`,
/// `CommandPaletteContent.tsx`, `CommandPaletteResults.tsx`) reduced to the one
/// mode B has producers for — search the threads by title, ↑/↓ to move, ⏎ to
/// open, ⎋ to close.
///
/// Ported: the dialog shell (`ui/command.tsx:62-79`: `max-w-xl max-h-105`), the
/// input row (`:99-112`, `px-[var(--command-shell-inset)] py-1.5`), the results
/// panel (`:148-156`), the "Recent Threads" group label
/// (`CommandPalette.logic.ts:452-458`), a row's title over
/// `project · Current thread` with a relative timestamp
/// (`buildThreadActionItems`, `:205-250`), the highlighted row's
/// `bg-foreground/[0.09]` (`:177-184`), the empty line
/// (`CommandPaletteResults.tsx:92-99`) and the footer's key hints
/// (`CommandPaletteContent.tsx:53-80`).
///
/// Not ported (no producer on B, each named where it would go): the command and
/// project modes and their submenus, the "New thread in…" picker, content-match
/// snippets (`ThreadContentMatch`), the fuzzy ranking over several fields
/// (`rankSearchFieldMatch` — `T3SidebarList.searchByTitle` is the title search
/// this window already uses for its sidebar), and the match highlighting inside
/// a row's title.
struct T3ThreadSwitcher: View {
    @ObservedObject var model: T3WindowModel
    let close: () -> Void
    @Environment(\.t3) private var t3
    @State private var query = ""
    /// The row ⏎ opens. `nil` before the first keystroke means "the first row"
    /// — upstream's `autoHighlight="always"` (`ui/command.tsx:83-95`).
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    /// `max-w-xl` / `max-h-105` on the popup (`ui/command.tsx:69`). The cap
    /// applies to the RESULTS panel: a sheet sizes to its content's ideal
    /// height, so the input row and the footer are always fully drawn and the
    /// list is what scrolls — the shape upstream's popup takes as it grows.
    private static let width: Double = 576
    private static let maxListHeight: Double = 420 - 96

    /// `buildThreadActionItems` sorts with `sortThreads(threads, sortOrder)`
    /// (`CommandPalette.logic.ts:197-200`) — `T3ThreadSort.sortThreads` here, on
    /// the default `updated_at` order. A draft is not a thread the switcher can
    /// open (upstream's items are built over thread shells only), so drafts are
    /// left out.
    private var rows: [T3Thread] {
        let threads = model.state.threads.filter { !T3WorkspaceState.isDraft($0.id) }
        let matched = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? threads
            : T3SidebarList.searchByTitle(threads, query: query)
        return T3ThreadSort.sortThreads(matched, by: .updatedAt)
    }

    private var activeId: String? { highlighted ?? rows.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            input
            Divider().overlay(t3.web.border.color)
            results
            footer
        }
        .frame(width: Self.width)
        .background(t3.web.popover.color)
        .overlay { keyboard }
    }

    // `CommandInput`'s row (`ui/command.tsx:99-112`): the shell inset (8) and
    // `py-1.5` (6) around the field itself.
    private var input: some View {
        T3Input(text: $query, placeholder: "Search threads...", leading: .search, focus: $focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .onSubmit(open)
            .onAppear { focused = true }
            // A keystroke re-ranks the list; the old highlight can be gone.
            .onChange(of: query) { _, _ in highlighted = nil }
    }

    @ViewBuilder private var results: some View {
        if rows.isEmpty {
            // `CommandPaletteResults.tsx:92-99`: `py-10 text-center text-sm
            // text-muted-foreground`. The copy is the thread-only form of
            // upstream's sentence (this palette searches nothing else).
            Text("No matching threads.")
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.mutedForeground.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            // A plain `ScrollView`, not `T3ScrollArea`: the kit's version
            // wraps its content in a `GeometryReader`, whose ideal height is
            // ~10 pt — inside a sheet (which sizes to the ideal) the list
            // collapsed to nothing (seen on the fixture).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // `CommandGroupLabel` at `ps-[9px]`
                    // (`CommandPaletteResults.tsx:106`), the group's own label
                    // "Recent Threads" (`CommandPalette.logic.ts:456`).
                    Text("Recent Threads")
                        .font(T3Font.web(.xs, .medium))
                        .foregroundStyle(t3.web.mutedForeground.color)
                        .padding(.leading, 9)
                        .padding(.vertical, 6)
                    ForEach(rows) { thread in
                        row(thread)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: Self.maxListHeight)
        }
    }

    private func row(_ thread: T3Thread) -> some View {
        let active = thread.id == activeId
        return HStack(spacing: 8) {
            LucideIcon(.messageSquare, size: 16)
                .foregroundStyle(t3.web.mutedForeground.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                    .lineLimit(1)
                if let description = description(thread) {
                    Text(description)
                        .font(T3Font.web(.xs))
                        .foregroundStyle(t3.web.mutedForeground.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // `timestamp: formatRelativeTimeLabel(latestUserMessageAt ??
            // updatedAt ?? createdAt)` (`CommandPalette.logic.ts:238-240`).
            Text(T3RelativeTime.label(from: thread.latestUserMessageAt ?? thread.updatedAt, now: model.now))
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        // `CommandItem`'s `py-1.5` (`ui/command.tsx:181`) over the row's own
        // two lines, `data-highlighted:bg-foreground/[0.09]`.
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? t3.web.foreground.color.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: T3Theme.Metrics.radius))
        .contentShape(Rectangle())
        .onTapGesture { select(thread.id) }
        // Upstream's rows highlight under the pointer (`ui/command.tsx`'s
        // autocomplete items do it themselves).
        .onHover { if $0 { highlighted = thread.id } }
    }

    /// `descriptionParts.join(" · ")` (`CommandPalette.logic.ts:206-217`): the
    /// project, then "Current thread" for the one already open. B has no branch
    /// on a thread, so that part has nothing to join.
    private func description(_ thread: T3Thread) -> String? {
        var parts: [String] = []
        if let project = model.state.projects.first(where: { $0.id == thread.projectId })?.name {
            parts.append(project)
        }
        if thread.id == model.state.selectedThreadId { parts.append("Current thread") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // `CommandFooter` (`ui/command.tsx:216-223`): `px-[var(--command-content-inset)]
    // py-2.5 bg-foreground/[0.025] text-sm text-muted-foreground`, the hint
    // groups from `CommandPaletteContent.tsx:53-80`.
    private var footer: some View {
        HStack(spacing: 12) {
            hint(["\u{2191}", "\u{2193}"], "Navigate")
            hint(["\u{21A9}"], "Open")
            hint(["esc"], "Close")
            Spacer(minLength: 0)
        }
        .font(T3Font.web(.sm, .medium))
        .foregroundStyle(t3.web.mutedForeground.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(t3.web.foreground.color.opacity(0.025))
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {   // `gap-1.5` inside a `KbdGroup`
            ForEach(keys, id: \.self) { T3Kbd($0) }
            Text(label)
        }
    }

    /// The hidden-button pattern the window uses everywhere (`T3Root.keyboard`):
    /// `performKeyEquivalent:` runs before the focused field's own `keyDown`, so
    /// ↑/↓ move the highlight instead of the caret.
    private var keyboard: some View {
        Group {
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { close() }.keyboardShortcut(.cancelAction)
            // `commandPalette.toggle` (`keybindings.ts:38`) — ⌘K closes the
            // palette as well as opens it. `T3Root`'s own ⌘K cannot do it
            // while this sheet is up (the sheet's window is key, and
            // `performKeyEquivalent:` never reaches the presenter), so the
            // shortcut is repeated here.
            Button("") { close() }.keyboardShortcut("k", modifiers: .command)
        }
        .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    /// `nudge`'s wrap (the same rule as the composer menu's, ported in Task 14).
    private func move(_ delta: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = activeId, let i = ids.firstIndex(of: current) else {
            highlighted = delta > 0 ? ids.first : ids.last
            return
        }
        highlighted = ids[(i + delta + ids.count) % ids.count]
    }

    private func open() {
        guard let id = activeId else { return }
        select(id)
    }

    private func select(_ id: String) {
        model.select(id)
        close()
    }
}
