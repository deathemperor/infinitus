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
        // `Sidebar.tsx`'s settled tail is paged per list, not per session:
        // changing scope or search rebuilds the list, so the "show 25 more"
        // count starts over instead of leaving an unrelated page size behind.
        .onChange(of: model.state.scope) { settledShown = T3ThreadList.settledInitialCount }
        .onChange(of: model.state.search) { settledShown = T3ThreadList.settledInitialCount }
        .overlay { keyboard }
    }

    // MARK: - Brand

    // AppSidebarLayout's brand slot; height matches Metrics.topbarHeight so
    // the row lines up with the top bar to its right (Task 8). The native
    // traffic lights "sit over the sidebar" while it is expanded, so the
    // row's own content — not just the window chrome — must clear them.
    // `--workspace-titlebar-content-left` (`ui/sidebar.tsx:169-170`) =
    // `--workspace-controls-left` + `--workspace-titlebar-control-size` +
    // `--workspace-titlebar-control-gap`: 90 pt (macOS traffic-light inset,
    // `AppSidebarLayout.tsx:49`'s `MACOS_TRAFFIC_LIGHTS_LEFT_INSET`,
    // applied at `:180`) + 28 pt (1.75rem control size) + 12 pt (0.75rem
    // gap, both `src/index.css:112-113`) = 130 pt — the brand slot's own
    // `ml-[var(--workspace-titlebar-content-left)]`
    // (`components/sidebar/SidebarChrome.tsx:89`).
    private var brandRow: some View {
        HStack(spacing: 8) {
            T3ProviderIcon(size: 20)
            T3Wordmark()
            Spacer(minLength: 0)
        }
        .padding(.leading, 130)
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
            // `Sidebar.tsx:4300-4338`'s new-thread button (its `SquarePenIcon`
            // sits in the search row upstream; Task 7 put this port's control in
            // the scope row and it stays there). Upstream's multi-project setup
            // routes ⌘N through the palette's "New thread in…" picker
            // (`:4210-4229`); B resolves the project directly
            // (`T3WindowModel.currentProjectId`), so the button and ⌘N do the
            // same thing here. Disabled with no project — a draft has nowhere
            // to start.
            T3Tooltip("New thread ⌘N") {
                Button(action: { model.startNewThread() }) { LucideIcon(.plus, size: 16) }
                    .buttonStyle(.plain)
                    .disabled(model.state.projects.isEmpty)
            }
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        // `Sidebar.tsx:4451`'s project-select trigger: "h-8 min-h-8" = 32 pt.
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
        // Lazy inside `T3ScrollArea`'s own `ScrollView`, so an off-screen
        // section's rows are never built (`sidebarSections` returns at most
        // four sections, each already ordered).
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(sections, id: \.kind) { sectionView($0) }
        }
    }

    // `Pinned` gets a header only when it has rows — `sidebarSections`
    // already omits an empty section entirely, so any pinned section here
    // has ≥ 1 thread. `Active` never gets a header (upstream has none either).
    @ViewBuilder private func sectionView(_ section: T3WorkspaceState.SidebarSection) -> some View {
        switch section.kind {
        case .pinned:
            T3SidebarGroup(label: "Pinned") { rows(section.threads, .pinned) }
        case .active:
            VStack(alignment: .leading, spacing: 4) { rows(section.threads, .active) }
                .padding(T3Theme.Metrics.sidebarContentInset)
        case .snoozed:
            shelf(title: "Snoozed", count: section.threads.count, expanded: $snoozedExpanded) {
                rows(section.threads, .snoozed)
            }
        case .settled:
            shelf(title: "Settled", count: section.threads.count, expanded: $settledExpanded) {
                let shown = Array(section.threads.prefix(settledShown))
                rows(shown, .settled)
                if section.threads.count > shown.count {
                    // Sidebar.tsx's settled tail: 10 initial, 25 a page
                    // (`T3ThreadList.settledInitialCount`/`settledPageCount`).
                    // `Sidebar.tsx:4877`'s button: "flex h-9 w-full … gap-2.5
                    // px-2.5 text-left text-sm text-sidebar-muted-foreground/55"
                    // — h-9 = 36 pt (fix round 1 R4; was 28), text-sm not -xs,
                    // leading `PlusIcon` "size-4 shrink-0" (16 pt).
                    Button(action: { settledShown += T3ThreadList.settledPageCount }) {
                        HStack(spacing: 10) {
                            LucideIcon(.plus, size: 16)
                            Text("Show \(min(T3ThreadList.settledPageCount, section.threads.count - shown.count)) more")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(T3Font.web(.sm))
                    .foregroundStyle(t3.web.sidebarMutedForeground.color.opacity(0.55))
                    .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
                    .frame(height: 36, alignment: .leading)
                }
            }
        }
    }

    // `Sidebar.tsx:4627-4643`'s `renderThreadRowInner`: `isCard = section ===
    // "active" || section === "pinned"`, and `variantAction` is "unsnooze" in
    // the snoozed shelf, "unsettle" in the settled tail, "settle" elsewhere.
    @ViewBuilder private func rows(_ threads: [T3Thread], _ kind: T3SidebarList.Section) -> some View {
        let variant: T3ThreadRowView.Variant = (kind == .active || kind == .pinned) ? .card : .slim
        let variantAction: T3ThreadRowView.VariantAction = kind == .snoozed ? .unsnooze : (kind == .settled ? .unsettle : .settle)
        ForEach(threads) { thread in
            if T3WorkspaceState.isDraft(thread.id) {
                T3SidebarDraftRow(draftId: thread.id,
                                  projectName: projectName(thread.projectId),
                                  preview: model.draft(for: thread.id).text,
                                  selected: thread.id == model.state.selectedThreadId,
                                  onSelect: { model.select(thread.id) },
                                  onDiscard: { model.discardDraft(thread.id) })
            } else {
            T3ThreadRowView(thread: thread, variant: variant, variantAction: variantAction,
                            selected: thread.id == model.state.selectedThreadId, now: model.now,
                            onSelect: { model.select(thread.id) },
                            onAttention: { action, until in model.attention(action, threadId: thread.id, until: until) },
                            projectName: projectName(thread.projectId), projectCwd: projectCwd(thread.projectId))
            }
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
            // Shelf toggle row: no upstream 1:1 found (this compact port's
            // own shelf header markup, not traced to a `Sidebar.tsx`
            // element) — 32 pt matches the scope row's own h-8
            // (`Sidebar.tsx:4451`), kept as this sidebar's own rhythm for
            // its non-thread control rows.
            .frame(height: 32)
            if expanded.wrappedValue { content() }
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarContentInset)
    }

    // MARK: - Footer

    // `SidebarChrome.tsx`'s footer: settings gear only — the update pill
    // has no host surface on B yet. `<SidebarFooter className="p-[var(
    // --sidebar-content-inset)]">` (`:226`) has no fixed height class —
    // content-driven padding on all sides, not the `.frame(height: 40)`
    // literal this held before fix round 1's R4.
    private var footer: some View {
        HStack {
            Button(action: { app.showSettings?() }) { LucideIcon(.settings, size: 16) }
                .buttonStyle(.plain)
                .foregroundStyle(t3.web.sidebarMutedForeground.color)
            Spacer(minLength: 0)
        }
        .padding(T3Theme.Metrics.sidebarContentInset)
    }

    // ⌘F focuses the search field while the window is key (the ⌘B/⌘J/⌘W
    // pattern in `T3Root`).
    private var keyboard: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// `SidebarDraftRow` (`Sidebar.tsx:689-786`): one unsent draft, two lines —
/// the pen, the project name, a hover-only discard, then the typed prompt.
///
/// Two deliberate differences from upstream, both in the dispatch's scope:
/// upstream surfaces a draft row only once the draft HAS content
/// (`:797-800`, "Draft sessions with user content") and shows an attachment
/// count when the prompt is empty — here every draft has a row from the moment
/// ⌘N makes one, and an empty one reads `T3WorkspaceState.draftTitle`
/// ("New thread"). And the preview is a snapshot, not a live mirror of the
/// composer: `T3WindowModel.drafts` is not `@Published` (Task 13's rule), which
/// is exactly the freeze upstream applies to the OPEN draft's row anyway
/// (`:686-688`, `:814`).
///
/// The vendored Lucide set has no `square-pen` (Lucide.generated.swift) —
/// `pencil` is its nearest glyph for the same "unsent work" mark.
private struct T3SidebarDraftRow: View {
    @Environment(\.t3) private var t3
    let draftId: String
    let projectName: String?
    let preview: String
    let selected: Bool
    let onSelect: () -> Void
    let onDiscard: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {   // `mt-0.5` between the lines
            HStack(spacing: 6) {   // `gap-1.5` on the `h-5` head row
                LucideIcon(.pencil, size: 14)
                    .foregroundStyle(t3.web.sidebarMutedForeground.color)
                Text(projectName ?? "No project")
                    .font(T3Font.web(.xs, .medium))
                    .foregroundStyle(t3.web.secondaryLabel.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // `:769-781`: the discard button is `opacity-0` until the row
                // is hovered or the button focused.
                Button(action: onDiscard) { LucideIcon(.x, size: 12) }
                    .buttonStyle(.plain)
                    .foregroundStyle(t3.web.mutedForeground.color)
                    .opacity(hover ? 1 : 0)
                    .accessibilityLabel("Discard draft")
                    .help("Discard draft")
            }
            .frame(height: 20)
            Text(firstLine)
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .padding(.vertical, T3Theme.Metrics.sidebarContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `:747`: the open draft's row takes `bg-sidebar-row-active`, an idle
        // one the draft surface (`draftSurfaceClassName`, `:519-521` — the same
        // look unsent work shares with a thread's unsent draft).
        .background(selected ? t3.web.sidebarRowActive.color : (hover ? t3.web.sidebarRowHover.color : .clear),
                    in: RoundedRectangle(cornerRadius: T3Theme.Metrics.radius))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .accessibilityLabel("Draft in \(projectName ?? "no project")")
    }

    private var firstLine: String {
        let line = preview.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? T3WorkspaceState.draftTitle : trimmed
    }
}
