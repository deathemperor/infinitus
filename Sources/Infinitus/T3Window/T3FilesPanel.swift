import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The right panel's Files tab (`FileBrowserPanel.tsx`): the selected thread's
/// project as a collapsible tree over a search field, with a refresh button and
/// an expand-all / collapse-all toggle in the panel's own subheader
/// (`:375-413`). Upstream mounts it inside `FilePreviewPanel`, and with no file
/// open the browser IS the whole surface (`FilePreviewPanel.tsx:1331-1338`
/// `min-w-0 flex-1`); a click on a file splits the tab in two
/// (`T3FilesSurface`, and `T3FilePreviewPane` for the preview itself).
///
/// The listing is one `T3ProjectFiles.list` per project cwd, cached on the
/// window model the way the composer's branch and mention lists are
/// (`T3WindowModel.gitBranch`); the tree, the search and the expansion rules are
/// `T3FileTree` (upstream's `fileTree.ts` — its web panel hands the same job to
/// `@pierre/trees`, `FileBrowserPanel.tsx:7`).
///
/// A row's right-click menu, its drag into the composer and the re-list after a
/// turn are `T3FileRow`'s `.contextMenu` / `.onDrag`, `T3MentionDrag`
/// (T3FileDrop.swift) and `T3FilesRefresh` (Core).
///
/// Not ported, each with its upstream line:
/// - incremental path reconciliation (`buildFileTreePathUpdates`,
///   `FileBrowserPanel.tsx:26,273-285`): a listing that lands replaces the tree
///   whole here (`apply`), which is what `model.resetPaths` does on the first
///   one (`:281`) — the diffed `model.batch` exists to keep `@pierre/trees`'
///   per-row DOM state, and this tree has none to keep.
/// - Pierre's colored per-extension sprite set (`pierre-icons.ts:48-64`): the
///   glyphs here are the kit's lucide ones, the phone's own choice for this tree
///   (`PierreEntryIcon.tsx:14-22` uses a folder glyph and a per-extension icon).
struct T3FilesPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    /// The selected thread's project — `nil` is "no project open", which is
    /// what `filesAvailable` gates on (`RightPanelTabs.tsx:339`). Its name is
    /// the first crumb in the preview's header (`projectName`,
    /// `FilePreviewPanel.tsx:1129`).
    private var project: T3ProjectGrouping.Project? {
        guard let thread = model.state.selectedThread else { return nil }
        return model.state.projects.first { $0.id == thread.projectId }
    }

    var body: some View {
        // `key={`${environmentId}:${cwd}`}` (`ChatView.tsx:8078`): a project
        // switch is a new surface — a new browser AND no carried-over
        // selection, never the old one re-filtered.
        Group {
            if let project {
                T3FilesSurface(model: model, cwd: project.cwd, projectName: project.name)
                    .id(project.cwd)
            } else {
                T3FilesUnavailable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
    }
}

/// The unavailable state. Upstream's right panel only offers Files from its
/// launcher, where the card greys out with its hint
/// (`RightPanelTabs.tsx:158,340`, rendered `:560-575` — `opacity-40`, the label
/// over `text-muted-foreground text-xs`); B's tab strip is fixed, so the tab
/// itself carries that copy.
private struct T3FilesUnavailable: View {
    @Environment(\.t3) private var t3
    var body: some View {
        VStack(spacing: 6) {   // "mt-1.5" under the label
            Text("Files")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text("Available when a project is open.")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .opacity(0.4)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tab's two columns (`FilePreviewPanel.tsx:1225-1349`). With nothing
/// selected the browser is the whole surface; a click on a file gives the
/// preview the room and pushes the browser into the aside upstream sizes
/// `w-[min(22rem,46%)] min-w-64 border-l border-border/60` (`:1332-1336`,
/// `shrink-0`), which the header's `folder-tree` toggle can hide. Both panels
/// are the same width (42 vw clamped to [360, 560], `T3Root.rightPanelWidth`),
/// so the aside's 256 pt floor bites at exactly the same window widths it does
/// upstream.
private struct T3FilesSurface: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String
    let projectName: String

    /// The clicked file, `relativePath` in upstream's props (`:86`).
    @State private var selected: String?
    @State private var explorerOpen = T3FilesSurface.storedExplorerOpen
    /// The refresh button's counter: the open file is read again with the
    /// listing (`onRefreshSelectedFile`, `:1345-1347`).
    @State private var revision = 0
    /// `nil` until the first listing lands (`T3FilesBrowser` reports it).
    @State private var available: Bool?

    /// Upstream keeps the toggle in `localStorage` under
    /// `"t3code.fileExplorerOpen"`, default open (`:100`, `:946-953`); the Mac's
    /// equivalent is the workspace's own defaults domain.
    private static let explorerKey = "workspace.filesExplorerOpen"
    private static var storedExplorerOpen: Bool {
        UserDefaults.standard.object(forKey: explorerKey) as? Bool ?? true
    }

    /// `shouldShowFileExplorer` (`filePreviewMode.ts:5-14`): with no file open
    /// the tree is the surface whatever the toggle says.
    private var showExplorer: Bool { selected == nil || explorerOpen }

    var body: some View {
        if available == false {
            T3FilesUnavailable()
        } else {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if let selected {
                        T3FilePreviewPane(model: model, cwd: cwd, projectName: projectName,
                                          path: selected, revision: revision,
                                          explorerOpen: explorerOpen, toggleExplorer: toggleExplorer)
                    }
                    if showExplorer { browser(width: geometry.size.width) }
                }
            }
        }
    }

    @ViewBuilder private func browser(width: Double) -> some View {
        let split = selected != nil
        T3FilesBrowser(model: model, cwd: cwd, selected: $selected,
                       onRefresh: refresh, onAvailability: { available in
                           self.available = available
                           if !available { selected = nil }
                       })
            .frame(width: split ? max(256, min(22 * 16, 0.46 * width)) : nil)
            .overlay(alignment: .leading) {
                if split { Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(width: 1) }
            }
    }

    private func toggleExplorer() {
        explorerOpen.toggle()
        UserDefaults.standard.set(explorerOpen, forKey: Self.explorerKey)
    }

    /// The listing and the open file are one refresh: the reads for this cwd go
    /// first so the pane's re-read cannot land on the cache it just dropped.
    private func refresh() {
        model.invalidateFileReads(cwd: cwd)
        revision += 1
    }
}

private struct T3FilesBrowser: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String
    /// The preview's file: a click on a row writes it (`onOpenFile`,
    /// `FileBrowserPanel.tsx:240-242`).
    @Binding var selected: String?
    let onRefresh: () -> Void
    let onAvailability: (Bool) -> Void

    @State private var nodes: [T3FileTree.Node] = []
    /// Bumped when a listing lands, so the flatten below re-runs without
    /// comparing two 20 000-node trees.
    @State private var revision = 0
    @State private var rows: [T3FileTree.Visible] = []
    @State private var directories: [String] = []
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @State private var failure: String?
    @State private var pending = true
    /// `Listing.truncated`: the walk hit `T3ProjectFiles.entryCap` and this
    /// tree is not the whole workspace.
    @State private var truncated = false
    @FocusState private var searching: Bool

    /// The flatten's inputs — `.task(id:)` cancels the in-flight one when they
    /// change, which is how a stale result is dropped (`T3WindowModel.mentionRows`).
    private struct Flow: Equatable { let query: String; let expanded: Set<String>; let revision: Int }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .task(id: cwd) {
            // The listing this cwd was last seen with paints first — the
            // refresh behind it is the thread switch (`T3WindowModel.gitBranch`).
            if let cached = model.cachedProjectFiles(cwd: cwd) { await apply(cached) }
            await load(reload: true)
        }
        .task(id: Flow(query: query, expanded: expanded, revision: revision)) { await reflow() }
        // `useWorkspaceMutationRefresh` (`FileBrowserPanel.tsx:267-271`): the
        // watcher lives in its own leaf so the turn's ticking never re-renders
        // this tree (see `T3FilesRelist`).
        .background {
            if let store = model.timelineStore {
                T3FilesRelist(store: store, threadId: model.state.selectedThreadId,
                              onRelist: relist)
            }
        }
    }

    /// A re-list is exactly the refresh button's work (`handleRefresh`,
    /// `FileBrowserPanel.tsx:264-266`): the listing and the open file both.
    private func relist() {
        onRefresh()
        Task { await load(reload: true) }
    }

    // MARK: - The subheader

    /// "flex h-10 min-h-10 shrink-0 items-center gap-1 border-b border-border/60
    /// bg-background px-2" (`FileBrowserPanel.tsx:376`).
    private var header: some View {
        HStack(spacing: 4) {
            refreshButton
            searchField
            if !directories.isEmpty { expandAllButton }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(t3.web.background.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }

    /// `<RefreshFilesButton>` (`:46-65`) — a ghost `icon-xs` button, tooltip
    /// "Refreshing…" / "Refresh files". Upstream spins the refresh glyph itself
    /// (`refresh-icon.tsx:16`); the kit's only Core-Animation spinner is
    /// `T3Spinner`'s `loader-circle`, so that is what turns while the listing
    /// loads (never a SwiftUI repeatForever — #18).
    private var refreshButton: some View {
        T3FilesIconButton(help: pending ? "Refreshing…" : "Refresh files") {
            onRefresh()
            Task { await load(reload: true) }
        } content: {
            if pending { T3Spinner(size: 14) } else { LucideIcon(.refreshCw, size: 14) }
        }
    }

    /// `<FileSearchField>` (`:67-93`) in an `InputGroup variant="ghost"
    /// h-7 min-w-0 flex-1` (`:75`): transparent until focus, when it takes the
    /// background (`input-group.tsx:21`). Escape closes the search and drops
    /// focus (`:85-89`), and a query of nothing but blanks closes it too
    /// (`:257-260`).
    private var searchField: some View {
        TextField("", text: $query,
                  prompt: Text("Search files").foregroundStyle(t3.web.placeholder.color))
            .textFieldStyle(.plain)
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.foreground.color)
            .focused($searching)
            .onKeyPress(.escape) {
                query = ""
                searching = false
                return .handled
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(searching ? t3.web.background.color : .clear,
                        in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
    }

    /// `:387-412`: only once the tree has a folder, `chevrons-down-up` when
    /// everything is open and `chevrons-up-down` when it is not, the label and
    /// the tooltip both "Collapse all folders" / "Expand all folders".
    private var expandAllButton: some View {
        let allExpanded = T3FileTree.allExpanded(directories: directories, expanded: expanded)
        return T3FilesIconButton(help: allExpanded ? "Collapse all folders" : "Expand all folders") {
            expanded = T3FileTree.setAllExpanded(!allExpanded, directories: directories, in: expanded)
        } content: {
            LucideIcon(allExpanded ? .chevronsDownUp : .chevronsUpDown, size: 14)
        }
    }

    // MARK: - The tree

    @ViewBuilder private var content: some View {
        if let failure, nodes.isEmpty {
            // "p-4 text-xs leading-relaxed text-destructive" (`:414-415`) —
            // only while there is no listing to show instead.
            Text(failure)
                .font(T3Font.web(.xs))
                .lineSpacing(4)
                .foregroundStyle(t3.web.destructive.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if rows.isEmpty {
            empty
        } else {
            tree
        }
    }

    /// 20 000 rows never all exist at once — the list is lazy
    /// ("min-h-0 flex-1 overflow-hidden", `:420`; the phone's own `FlatList`,
    /// `FileTreeBrowser.tsx:239`).
    private var tree: some View {
        VStack(spacing: 0) {
            T3ScrollArea {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.node.path) { row in
                        T3FileRow(row: row,
                                  expanded: expanded.contains(row.node.path),
                                  selected: selected == row.node.path,
                                  action: { open(row.node) },
                                  onCopyMention: copyMention, onAddToChat: addToChat)
                            // The way out to the file's own app (the header's
                            // editor picker upstream, `FilePreviewPanel.tsx:1140-1148`).
                            .simultaneousGesture(TapGesture(count: 2).onEnded { reveal(row.node) })
                    }
                }
                // "paddingTop: 8, paddingBottom: 8" (`FileTreeBrowser.tsx:255`).
                .padding(.vertical, 8)
            }
            if truncated { truncatedNotice }
        }
    }

    /// The listing hit its cap. Upstream words this once — a disabled entry
    /// under a separator at the BOTTOM of the entry list
    /// (`FileBreadcrumbs.tsx:187-192`; `FileBrowserPanel.tsx` shows no notice of
    /// its own). A disabled `MenuItem` is the foreground at `opacity-64` over
    /// `sm:text-sm px-2 py-1 sm:min-h-7` (`menu.tsx:89`), and the separator is
    /// the same `border-border/60` rule the subheader wears. Outside the scroll
    /// area: inside a lazy list of 20 000 rows it would never be reached.
    private var truncatedNotice: some View {
        Text(T3FilesRefresh.truncatedNotice)
            .font(T3Font.web(.sm))
            .foregroundStyle(t3.web.foreground.color.opacity(0.64))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(alignment: .top) {
                Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
            }
    }

    /// The phone's empty state for this same tree
    /// (`FileTreeBrowser.tsx:258-272`): the spinner while the listing is in
    /// flight, otherwise "No files found" over the reason.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            if pending {
                T3Spinner(size: 16)
            } else {
                Text("No files found")
                    .font(T3Font.web(.sm, .bold))
                    .foregroundStyle(t3.web.foreground.color)
                Text(T3FileTree.searchTokens(query).isEmpty
                     ? "The workspace file index is empty." : "Try a different search.")
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Behaviour

    /// A folder toggles (`FileTreeBrowser.tsx:63-66`), a file is selected and
    /// the preview pane it is embedded in shows it (`FileBrowserPanel.tsx:240-242`,
    /// `FilePreviewPanel.tsx:1347`) — never a jump to another app, which
    /// upstream's click never causes either. A double click hands the file to
    /// whatever app owns it (`NSWorkspace`), which upstream spells as the
    /// header's editor picker.
    private func open(_ node: T3FileTree.Node) {
        guard node.kind == .file else {
            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
            return
        }
        selected = node.path
    }

    private func reveal(_ node: T3FileTree.Node) {
        guard node.kind == .file else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd).appendingPathComponent(node.path))
    }

    /// "Copy mention" (`FileBrowserPanel.tsx:162-174`): the mention text, and
    /// only it, on the pasteboard. Upstream follows the write with a
    /// "Mention copied" toast; B has no toast manager, and its other copy actions
    /// (a timeline row's Copy, T3TimelineRowViews.swift:310) confirm nothing
    /// either — the pasteboard is the confirmation.
    private func copyMention(_ mention: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mention, forType: .string)
    }

    /// "Add to chat" (`:175-192`): the open composer appends the mention to its
    /// draft. Upstream reaches that composer through a ref
    /// (`useComposerHandleContext`, `:106`) and toasts when there is none; here
    /// `T3ComposerInbox` is the ref, and the Files tab only exists while a
    /// thread is selected — which is exactly when a composer is mounted on it.
    private func addToChat(_ mention: String) {
        model.composerInbox.send(.mention(mention))
    }

    private func load(reload: Bool) async {
        pending = true
        defer { pending = false }
        await apply(await model.projectFiles(cwd: cwd, reload: reload))
    }

    /// Folding 20 000 entries is not main-actor work (#18).
    private func apply(_ result: Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>) async {
        switch result {
        case .success(let listing):
            onAvailability(true)
            failure = nil
            truncated = listing.truncated
            let tree = await Task.detached(priority: .userInitiated) {
                T3FileTree.build(listing.entries)
            }.value
            nodes = tree
            directories = T3FileTree.directoryPaths(tree)
            // "if (current.size > 0 …) return current" (`FileTreeBrowser.tsx:147-154`):
            // a refresh leaves the folders the user opened alone.
            if expanded.isEmpty { expanded = T3FileTree.defaultExpanded(tree) }
            revision += 1
        case .failure(let error):
            // A cwd that is gone is not an error to show, it is the tab's
            // unavailable state (`RightPanelTabs.tsx:339`).
            if case .rootGone = error {
                onAvailability(false)
                nodes = []
                rows = []
                directories = []
                truncated = false
            } else {
                onAvailability(true)
                failure = error.message
            }
        }
    }

    /// Filtering scores every one of the project's paths, so it runs off the
    /// main actor exactly like the composer's `@` menu does
    /// (`T3WindowModel.mentionRows`).
    private func reflow() async {
        let nodes = self.nodes, expanded = self.expanded, query = self.query
        guard !nodes.isEmpty else {
            rows = []
            return
        }
        let flattened = await Task.detached(priority: .userInitiated) {
            T3FileTree.flatten(nodes: nodes, expanded: expanded, searchQuery: query)
        }.value
        guard !Task.isCancelled else { return }
        rows = flattened
    }
}

/// The re-list watcher (`useWorkspaceMutationRefresh`,
/// `FileBrowserPanel.tsx:267-271`), on the edges `T3FilesRefresh.shouldRelist`
/// names. Nothing to draw: it exists to hold the observation.
///
/// Two things pin its shape. The turn's state comes from the TIMELINE STORE,
/// not from `T3WindowModel.state`'s threads: those carry the fleet poll's
/// `SessionFacts`, whose latest turn sits at `.completed` right through a
/// running turn (measured on the fixture — the store's `.running` is what the
/// composer's Stop button reads, T3ComposerView.swift:590). And the store is
/// observed HERE rather than in the browser, because the store republishes on
/// every transcript poll: observing it up there would re-render the whole tree
/// a few times a second for a value only this edge cares about (#18).
private struct T3FilesRelist: View {
    @ObservedObject var store: T3TimelineStore
    let threadId: String?
    let onRelist: () -> Void

    private var signal: T3FilesRefresh.Signal {
        // `gone` is the session having exited (#400) — the turn it left behind
        // is over, whatever the last transcript entry said.
        let turn = store.gone ? nil : store.timeline?.latestTurn?.state
        return T3FilesRefresh.Signal(threadId: threadId,
                                     turnState: turn.map(T3Thread.Turn.State.init))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: signal) { previous, current in
                guard T3FilesRefresh.shouldRelist(from: previous, to: current) else { return }
                onRelist()
            }
    }
}

/// One row. The tree's own theme overrides are the numbers here: 12 px text,
/// a 5 px corner, the selected background `currentColor 12%` and the hover one
/// `7%` (`pierre-tree-theme.ts:6-13`). Row height and indent live inside
/// `@pierre/trees` (`density: "compact"`, `FileBrowserPanel.tsx:224`), which is
/// not in the checkout — the indent step is the phone's for this same tree
/// (`8 + depth * 18`, `FileTreeBrowser.tsx:74`).
private struct T3FileRow: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let row: T3FileTree.Visible
    let expanded: Bool
    let selected: Bool
    let action: () -> Void
    let onCopyMention: (String) -> Void
    let onAddToChat: (String) -> Void

    /// `composerMentionFromTreePath` over this row's path (Core).
    private var mention: String? { T3FileMention.mention(forTreePath: row.node.path) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // A file keeps the chevron's width so its name lines up with a
                // folder's (`FileTreeBrowser.tsx:84` `<View className="w-3" />`).
                Group {
                    if row.node.kind == .directory {
                        LucideIcon(expanded ? .chevronDown : .chevronRight, size: 12)
                            .foregroundStyle(t3.web.iconMuted.color)
                    }
                }
                .frame(width: 12)
                LucideIcon(Self.icon(for: row.node), size: 14)
                    .foregroundStyle(t3.web.iconMuted.color)
                Text(row.node.name)
                    .font(T3Font.web(.xs))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t3.web.foreground.color)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + Double(row.depth) * 18)
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        // "Rows only need to be draggable so entries can be dropped into the
        // chat composer; rearranging files inside the tree stays off"
        // (`FileBrowserPanel.tsx:220-222`, `canDrop: () => false`) — so the row
        // is a drag SOURCE only, and the tree takes no drops at all.
        //
        // Upstream also has to undo the selection its own tree applies to a
        // dragged row (`fileTreeDragMention.ts:41-45, 85-93`); a SwiftUI drag
        // never fires the Button's action, so there is nothing to undo.
        .onDrag { T3MentionDrag.provider(mention: mention ?? "") }
        // `contextMenu: { triggerMode: "right-click" }` (`:213-218`).
        .contextMenu { menu }
        .padding(.horizontal, 4)
    }

    /// `:155-160`: two items, and the same two for a file and a folder alike —
    /// upstream drops the tree path's trailing `/` (`:145`) and offers nothing
    /// kind-specific at these lines.
    @ViewBuilder private var menu: some View {
        if let mention {
            Button("Copy mention") { onCopyMention(mention) }
            Button("Add to chat") { onAddToChat(mention) }
        }
    }

    private var background: Color {
        let foreground = t3.web.foreground.color
        if selected { return foreground.opacity(0.12) }
        return hover ? foreground.opacity(0.07) : .clear
    }

    /// Pierre's sprite set is per extension and colored
    /// (`pierre-icons.ts:48-64`); these are the kit's lucide glyphs standing in
    /// for it, one per family the phone's icons also distinguish.
    static func icon(for node: T3FileTree.Node) -> Lucide {
        guard node.kind == .file else { return .folder }
        switch node.name.split(separator: ".").count > 1
            ? String(node.name.split(separator: ".").last!).lowercased() : "" {
        case "md", "markdown", "mdx", "txt": return .fileText
        case "json", "yml", "yaml", "toml", "xml", "plist": return .braces
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns": return .image
        case "mp4", "mov", "m4v", "mkv", "webm", "avi": return .video
        case "mp3", "wav", "m4a", "flac", "aac": return .music
        case "sh", "bash", "zsh", "fish": return .terminal
        case "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "rs", "go", "java",
             "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "html", "css", "scss":
            return .code2
        default: return .file
        }
    }
}

/// A ghost `icon-xs` button: `size-6` on the Mac's `sm:` breakpoint with a
/// `size-3.5` glyph (`button.tsx:29-30`), `hover:bg-accent` from the ghost
/// variant, the tooltip as the native help tag. The Diff tab's subheader
/// (`T3DiffPanel`) is the same row of the same buttons, so this one is shared
/// rather than transcribed twice. `pressed` is the `<Toggle>` variant of the
/// same button (`toggle.tsx`, `data-pressed:bg-accent`), which is how the
/// preview's header shows the explorer is up (`FilePreviewPanel.tsx:1199-1207`).
struct T3FilesIconButton<Content: View>: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let help: String
    var pressed = false
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(hover || pressed ? t3.web.accentForeground.color : t3.web.foreground.color)
                .frame(width: 24, height: 24)
                .background(hover || pressed ? t3.web.accent.color : .clear,
                            in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
