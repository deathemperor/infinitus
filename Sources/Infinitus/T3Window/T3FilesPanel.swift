import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The right panel's Files tab (`FileBrowserPanel.tsx`): the selected thread's
/// project as a collapsible tree over a search field, with a refresh button and
/// an expand-all / collapse-all toggle in the panel's own subheader
/// (`:375-413`). Upstream mounts it inside `FilePreviewPanel`, and with no file
/// open the browser IS the whole surface (`FilePreviewPanel.tsx:1331-1338`
/// `min-w-0 flex-1`) — which is this tab.
///
/// The listing is one `T3ProjectFiles.list` per project cwd, cached on the
/// window model the way the composer's branch and mention lists are
/// (`T3WindowModel.gitBranch`); the tree, the search and the expansion rules are
/// `T3FileTree` (upstream's `fileTree.ts` — its web panel hands the same job to
/// `@pierre/trees`, `FileBrowserPanel.tsx:7`).
///
/// Not ported, each with its upstream line:
/// - the file PREVIEW a click opens (`FilePreviewPanel.tsx:1340-1352`
///   `onOpenFile` → an editor with a save coordinator): a surface of its own, so
///   a click selects the row; a double click hands the file to the user's
///   editor through `NSWorkspace`.
/// - drag-to-mention (`fileTreeDragMention.ts:83`'s `COMPOSER_MENTION_DRAG_TYPE`):
///   B's composer takes dropped file URLs as attachments (`T3ComposerView.swift:191`),
///   it has no mention drop type to tag a drag with.
/// - the row context menu's "Copy mention" / "Add to chat" (`:154-192`).
/// - Pierre's colored per-extension sprite set (`pierre-icons.ts:48-64`): the
///   glyphs here are the kit's lucide ones, the phone's own choice for this tree
///   (`PierreEntryIcon.tsx:14-22` uses a folder glyph and a per-extension icon).
struct T3FilesPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    /// The selected thread's project cwd — `nil` is "no project open", which is
    /// what `filesAvailable` gates on (`RightPanelTabs.tsx:339`).
    private var cwd: String? {
        guard let thread = model.state.selectedThread else { return nil }
        return model.state.projects.first { $0.id == thread.projectId }?.cwd
    }

    var body: some View {
        // `key={`${environmentId}:${cwd}`}` (`FilePreviewPanel.tsx:1341`): a
        // project switch is a new browser, not the old one re-filtered.
        Group {
            if let cwd {
                T3FilesBrowser(model: model, cwd: cwd).id(cwd)
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

private struct T3FilesBrowser: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String

    @State private var nodes: [T3FileTree.Node] = []
    /// Bumped when a listing lands, so the flatten below re-runs without
    /// comparing two 20 000-node trees.
    @State private var revision = 0
    @State private var rows: [T3FileTree.Visible] = []
    @State private var directories: [String] = []
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @State private var selected: String?
    @State private var failure: String?
    /// `nil` until the first listing lands: the cwd's existence is what
    /// `filesAvailable` means, and `T3ProjectFiles.list` is what checks it.
    @State private var available: Bool?
    @State private var pending = true
    @FocusState private var searching: Bool

    /// The flatten's inputs — `.task(id:)` cancels the in-flight one when they
    /// change, which is how a stale result is dropped (`T3WindowModel.mentionRows`).
    private struct Flow: Equatable { let query: String; let expanded: Set<String>; let revision: Int }

    var body: some View {
        Group {
            // No surface at all when the project is gone: upstream never shows
            // the browser's chrome over that state (`RightPanelTabs.tsx:560-575`).
            if available == false {
                T3FilesUnavailable()
            } else {
                VStack(spacing: 0) {
                    header
                    content
                }
            }
        }
        .task(id: cwd) {
            // The listing this cwd was last seen with paints first — the
            // refresh behind it is the thread switch (`T3WindowModel.gitBranch`).
            if let cached = model.cachedProjectFiles(cwd: cwd) { await apply(cached) }
            await load(reload: true)
        }
        .task(id: Flow(query: query, expanded: expanded, revision: revision)) { await reflow() }
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
        T3ScrollArea {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.node.path) { row in
                    T3FileRow(row: row,
                              expanded: expanded.contains(row.node.path),
                              selected: selected == row.node.path,
                              action: { open(row.node) })
                        // The way out to an editor until the preview pane lands.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { reveal(row.node) })
                }
            }
            // "paddingTop: 8, paddingBottom: 8" (`FileTreeBrowser.tsx:255`).
            .padding(.vertical, 8)
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

    /// A folder toggles (`FileTreeBrowser.tsx:63-66`), a file is selected —
    /// upstream then opens it in the preview pane it is embedded in
    /// (`FileBrowserPanel.tsx:240-242`, `FilePreviewPanel.tsx:1347`). That
    /// surface is not ported, so a click only selects the row — never a jump
    /// to another app, which upstream's click never causes either. A double
    /// click hands the file to whatever app owns it (`NSWorkspace`), the one
    /// deliberate way out until the preview lands.
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

    private func load(reload: Bool) async {
        pending = true
        defer { pending = false }
        await apply(await model.projectFiles(cwd: cwd, reload: reload))
    }

    /// Folding 20 000 entries is not main-actor work (#18).
    private func apply(_ result: Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>) async {
        switch result {
        case .success(let listing):
            available = true
            failure = nil
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
                available = false
                nodes = []
                rows = []
                directories = []
            } else {
                available = true
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
        .padding(.horizontal, 4)
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
/// variant, the tooltip as the native help tag.
private struct T3FilesIconButton<Content: View>: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let help: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(hover ? t3.web.accentForeground.color : t3.web.foreground.color)
                .frame(width: 24, height: 24)
                .background(hover ? t3.web.accent.color : .clear,
                            in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
