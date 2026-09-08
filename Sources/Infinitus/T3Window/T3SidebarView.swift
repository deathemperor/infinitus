import SwiftUI
import InfinitusCore
import InfinitusUI

/// The workspace window's real sidebar (Task 7): brand row, search, the
/// scope/project picker, sectioned thread rows, footer. Replaces Task 6's
/// `T3SidebarPlaceholder`. `Sidebar.tsx` (203k) is one component doing far
/// more than this ports — drag-and-drop reordering, git branches, PR
/// chrome, terminal status, providers — none of which `T3Thread` carries
/// yet; this is the brief's scoped subset: brand, search, scope, sections,
/// rows, a trimmed context menu (see `T3ThreadRowView`).
struct T3SidebarView: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.t3) private var t3
    @FocusState private var searchFocused: Bool
    // `Sidebar.tsx`'s SNOOZED_SHELF_EXPANDED_KEY/SETTLED_SHELF_EXPANDED_KEY
    // default both shelves collapsed ("Fresh keys deliberately reset both
    // shelves to collapsed for existing users") — session-local here, no
    // persistence in B's reducer yet.
    @State private var snoozedExpanded = false
    @State private var settledExpanded = false
    @State private var settledShown = T3ThreadList.settledInitialCount

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            searchRow
            scopeRow
            T3ScrollArea { sectionsList }
            footer
        }
        .background { keyboard }
    }

    // MARK: - Brand

    // AppSidebarLayout's brand slot; height matches Metrics.topbarHeight so
    // the row lines up with the top bar to its right (Task 8). The native
    // traffic lights "sit over the sidebar" while it is expanded (task-8
    // brief), so the row's own content — not just the window chrome —
    // must clear them; 90 pt is the same clearance Task 8's top bar uses
    // for its own left inset when the sidebar is collapsed.
    private var brandRow: some View {
        HStack(spacing: 8) {
            T3ProviderIcon(size: 20)
            T3Wordmark()
            Spacer(minLength: 0)
        }
        .padding(.leading, 90)
        .padding(.trailing, T3Theme.Metrics.sidebarContentInset)
        .frame(height: T3Theme.Metrics.topbarHeight)
    }

    // MARK: - Search

    private var searchRow: some View {
        T3Input(text: Binding(get: { model.state.search }, set: model.setSearch),
                placeholder: "Search", leading: .search, focus: $searchFocused)
            .padding(.horizontal, T3Theme.Metrics.sidebarContentInset)
            .padding(.bottom, 8)
    }

    // MARK: - Scope

    private var scopeRow: some View {
        HStack(spacing: 4) {
            Menu {
                Button("All projects") { model.setScope(.all) }
                ForEach(model.state.groups) { group in
                    Button(group.displayName) { model.setScope(.group(ids: group.members.map(\.id))) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentScopeLabel).font(T3Font.web(.sm, .medium)).lineLimit(1)
                    LucideIcon(.chevronDown, size: 14)
                }
                .foregroundStyle(t3.web.sidebarForeground.color)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            // Task 15 wires `startNewThread` in the current scope; until
            // then the control is a live tooltip over a disabled action.
            T3Tooltip("New thread ⌘N") {
                Button(action: {}) { LucideIcon(.plus, size: 16) }
                    .buttonStyle(.plain)
                    .disabled(true)
            }
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .frame(height: 32)
        .padding(.bottom, 4)
    }

    private var currentScopeLabel: String {
        switch model.state.scope {
        case .all: return "All projects"
        case let .project(id):
            return model.state.groups.first { $0.members.contains { $0.id == id } }?.displayName ?? "All projects"
        case let .group(ids):
            guard let first = ids.first else { return "All projects" }
            return model.state.groups.first { $0.members.contains { $0.id == first } }?.displayName ?? "All projects"
        }
    }

    // MARK: - Sections

    private func projectName(_ id: String) -> String? { model.state.projects.first { $0.id == id }?.name }
    private func projectCwd(_ id: String) -> String? { model.state.projects.first { $0.id == id }?.cwd }

    private var sectionsList: some View {
        let sections = model.state.sidebarSections(now: model.now)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(sections.indices, id: \.self) { i in sectionView(sections[i]) }
        }
    }

    // `Pinned` gets a header only when it has rows — `sidebarSections`
    // already omits an empty section entirely, so any pinned section here
    // has ≥ 1 thread. `Active` never gets a header (upstream has none either).
    @ViewBuilder private func sectionView(_ section: T3WorkspaceState.SidebarSection) -> some View {
        switch section.kind {
        case .pinned:
            T3SidebarGroup(label: "Pinned") { rows(section.threads) }
        case .active:
            VStack(alignment: .leading, spacing: 4) { rows(section.threads) }
                .padding(T3Theme.Metrics.sidebarContentInset)
        case .snoozed:
            shelf(title: "Snoozed", count: section.threads.count, expanded: $snoozedExpanded) {
                rows(section.threads)
            }
        case .settled:
            shelf(title: "Settled", count: section.threads.count, expanded: $settledExpanded) {
                let shown = Array(section.threads.prefix(settledShown))
                rows(shown)
                if section.threads.count > shown.count {
                    // Sidebar.tsx's settled tail: 10 initial, 25 a page
                    // (`T3ThreadList.settledInitialCount`/`settledPageCount`).
                    Button("Show \(min(T3ThreadList.settledPageCount, section.threads.count - shown.count)) more") {
                        settledShown += T3ThreadList.settledPageCount
                    }
                    .buttonStyle(.plain)
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.sidebarMutedForeground.color)
                    .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
                    .frame(height: 28, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func rows(_ threads: [T3Thread]) -> some View {
        ForEach(threads) { thread in
            T3ThreadRowView(thread: thread, selected: thread.id == model.state.selectedThreadId, now: model.now,
                            onSelect: { model.select(thread.id) },
                            onAttention: { action, until in model.attention(action, threadId: thread.id, until: until) },
                            projectName: projectName(thread.projectId), projectCwd: projectCwd(thread.projectId))
        }
    }

    @ViewBuilder private func shelf<Content: View>(title: String, count: Int, expanded: Binding<Bool>,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.wrappedValue.toggle() }) {
                HStack(spacing: 4) {
                    Text(title).font(T3Font.web(.xs, .medium))
                    Text("\(count)").font(T3Font.web(.xs)).foregroundStyle(t3.web.sidebarMutedForeground.color)
                    Spacer(minLength: 0)
                    LucideIcon(expanded.wrappedValue ? .chevronUp : .chevronDown, size: 12)
                }
                .foregroundStyle(t3.web.sidebarForeground.color)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 32)
            if expanded.wrappedValue { content() }
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarContentInset)
    }

    // MARK: - Footer

    // `SidebarChrome.tsx`'s footer: settings gear only — the update pill
    // has no host surface on B yet.
    private var footer: some View {
        HStack {
            Button(action: { app.showSettings?() }) { LucideIcon(.settings, size: 16) }
                .buttonStyle(.plain)
                .foregroundStyle(t3.web.sidebarMutedForeground.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarContentInset)
        .frame(height: 40)
    }

    // ⌘F focuses the search field while the window is key (the ⌘B/⌘J/⌘W
    // pattern in `T3Root`).
    private var keyboard: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// The collapsed sidebar's 48 pt icon column (`ui/sidebar.tsx` icon
/// variant): just the brand glyph, centered — not `T3SidebarRail` (A's
/// kit primitive is the separate 16 pt hover-to-resize strip).
struct T3SidebarIconRail: View {
    var body: some View {
        VStack {
            // The 48 pt column is narrower than the traffic-light cluster,
            // so — unlike the expanded brand row — there is no clearing
            // them horizontally; the glyph sits below the whole reserved
            // band instead (Task 8's top bar picks up the leftover 90 pt
            // inset on its own side while collapsed).
            T3ProviderIcon(size: 20).padding(.top, T3Theme.Metrics.topbarHeight + 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
