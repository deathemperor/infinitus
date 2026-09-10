import SwiftUI
import InfinitusCore
import InfinitusUI

/// The right panel's Diff tab (`DiffPanel.tsx` in the `mode="embedded"` the
/// panel mounts it with, `ChatView.tsx:8016-8024`): a scope switcher over the
/// session's changes, the changed files as a diff, and the changed-files tree
/// beside them (`DiffFileTree.tsx`).
///
/// The changes come from the session's checkpoint ladder — `Checkpoints`, one
/// hidden git ref per prompt (#167) — which is what this port has instead of
/// upstream's server-side review environment (spec §9 "E":
/// `GET /sessions/{pid}/diff?scope=turn|worktree|base` is the same three
/// scopes over the same ladder). A checkpoint is recorded when a prompt goes
/// in (`AppModel.handleHookEvent`, on `UserPromptSubmit`), so checkpoint *n*
/// is the tree as it was BEFORE turn *n* — the mapping every scope below
/// derives from. The patch is parsed by `T3DiffModel`; the tree rows are
/// `T3FileTree`, the same as the Files tab's.
///
/// Not ported, each with its upstream line:
/// - the base-ref combobox (`DiffPanel.tsx:615-743`, `vcsEnvironment.listRefs`):
///   upstream's "Branch changes" is a merge-base range against a ref the reader
///   picks. A checkpoint ladder has no ref to pick, so the scope of the same
///   name is the ladder's own base — the first checkpoint against the working
///   tree — and the label is upstream's copy over this port's meaning.
/// - the split (side-by-side) layout (`:798-816`) and the line-wrap toggle
///   (`:817-836`): lines always wrap here, and `overflow: "scroll"` has no
///   equivalent inside a `LazyVStack`.
/// - the ignore-whitespace toggle (`:837-858`): `Checkpoints.diff` takes no
///   `-w`, and the engine-side knob is not this panel's to add.
/// - the copy-path button (`:978-980`) and the click that opens a file in the
///   reader's editor (`:475-502`, `:949-953`) — the Files tab's double click
///   is the one way out to an editor in this port.
/// - the refresh on window focus (`:298-303`) and `useWorkspaceMutationRefresh`
///   (`:305-310`): the refresh button and the thread switch are the only
///   loads, so an idle panel spawns no git at all.
/// - comments and annotations (`AnnotatableCodeView.tsx:1-40`,
///   `DiffCommentAnnotation.tsx`): a surface of their own, out of scope here.
/// - the loading skeleton (`DiffPanelShell.tsx:74-98`): the spinner the rest of
///   this port uses stands in for it.
/// - sticky file headers (`StyledDiffCodeView.tsx:79-92` `position: sticky`).
struct T3DiffPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    /// The thread the ladder is keyed by. A local thread's id IS the Claude
    /// session id the refs live under (`T3ThreadBridge.swift:22`); a thread
    /// mirrored from another machine (`id: "pid:…"`, `:54`) has no ladder here,
    /// which is what `diffAvailable` excludes (`RightPanelTabs.tsx:110`, whose
    /// reason reads "Diff is only available for server threads in Git
    /// repositories.", `:140`).
    private var target: (cwd: String, sessionId: String)? {
        guard let thread = model.state.selectedThread,
              thread.environmentId == T3Thread.localEnvironmentId,
              let cwd = model.state.projects.first(where: { $0.id == thread.projectId })?.cwd
        else { return nil }
        return (cwd, thread.id)
    }

    var body: some View {
        Group {
            if let target {
                T3DiffBrowser(model: model, cwd: target.cwd, sessionId: target.sessionId)
                    .id("\(target.cwd)\u{0}\(target.sessionId)")
            } else if model.state.selectedThread == nil {
                // `DiffPanel.tsx:885-888`.
                T3DiffMessage(text: "Select a thread to inspect turn diffs.")
            } else {
                T3DiffUnavailable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
    }
}

/// Where a scope's patch comes from on the ladder. `to == nil` is the working
/// tree as it is now, untracked files included (`Checkpoints.diff`).
enum T3DiffScope: Hashable, Sendable {
    /// `DiffPanel.tsx:562` "Working tree" — the last checkpoint against the
    /// tree now, i.e. everything since the last prompt.
    case workingTree
    /// `:572` "Branch changes" — the ladder's base: the first checkpoint
    /// against the tree now, i.e. everything this session has changed.
    case branch
    /// `:582` "Latest turn" / `:589-612`'s "Turn" submenu — the two
    /// checkpoints around turn *n*. The latest turn has no checkpoint after it
    /// yet, so it ends at the working tree, which makes it the same patch as
    /// "Working tree" by construction.
    case turn(Int)

    func range(in ladder: [Checkpoint]) -> (from: Int, to: Int?)? {
        switch self {
        case .workingTree:
            guard let last = ladder.last else { return nil }
            return (last.n, nil)
        case .branch:
            guard let first = ladder.first else { return nil }
            return (first.n, nil)
        case .turn(let n):
            guard ladder.contains(where: { $0.n == n }) else { return nil }
            return (n, ladder.first { $0.n > n }?.n)
        }
    }

    /// The switcher's own label (`:216-223`).
    func label(ladder: [Checkpoint]) -> String {
        switch self {
        case .workingTree: return "Working tree"
        case .branch: return "Branch changes"
        case .turn(let n): return n == ladder.last?.n ? "Latest turn" : "Turn \(n)"
        }
    }
}

/// One scope's answer: the ladder it was resolved against and the files the
/// patch holds. Every field is what the panel paints without touching git again.
struct T3DiffLoad: Sendable {
    struct Key: Hashable, Sendable {
        let cwd: String
        let sessionId: String
        let scope: T3DiffScope
    }

    var checkpoints: [Checkpoint] = []
    /// The thread's folder is inside a git repository — the other half of
    /// `diffAvailable` (`RightPanelTabs.tsx:110`).
    var inGit = false
    var files: [T3DiffModel.File] = []
    /// A patch was resolved at all (there was a checkpoint to diff from).
    var resolved = false
    /// `Checkpoints.patchCap` cut the patch (`DiffPanel.tsx:900-905`).
    var truncated = false
    var failure: String?

    /// Three git spawns (`toplevel`, `for-each-ref`, `diff`) and one parse —
    /// called from a detached task, never the main actor.
    static func load(_ key: Key) -> T3DiffLoad {
        guard let root = Checkpoints.toplevel(cwd: key.cwd) else { return T3DiffLoad() }
        var load = T3DiffLoad(inGit: true)
        load.checkpoints = (try? Checkpoints.list(cwd: root, sessionId: key.sessionId)) ?? []
        guard let range = key.scope.range(in: load.checkpoints) else { return load }
        do {
            let diff = try Checkpoints.diff(cwd: root, sessionId: key.sessionId,
                                            from: range.from, to: range.to)
            load.resolved = true
            load.truncated = diff.truncated
            load.files = T3DiffModel.sortedByPath(T3DiffModel.parse(diff.patch))
        } catch {
            load.failure = "\(error)"
        }
        return load
    }
}

/// The unavailable state. Upstream's right panel only offers Diff from its
/// launcher, where the card greys out under its one-line hint
/// (`RightPanelTabs.tsx:163` "Available for Git repositories.", rendered
/// `:560-575`); B's tab strip is fixed, so the tab itself carries that copy —
/// the same shape `T3FilesPanel` gives the Files tab.
private struct T3DiffUnavailable: View {
    @Environment(\.t3) private var t3
    var body: some View {
        VStack(spacing: 6) {
            Text("Diff")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text("Available for Git repositories.")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .opacity(0.4)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's centred one-liners: "flex flex-1 items-center justify-center
/// px-5 text-center text-xs text-muted-foreground/70" (`DiffPanel.tsx:886`).
private struct T3DiffMessage: View {
    @Environment(\.t3) private var t3
    let text: String
    var body: some View {
        Text(text)
            .font(T3Font.web(.xs))
            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct T3DiffBrowser: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String
    let sessionId: String

    /// Upstream opens on the working tree when it has changes and on the branch
    /// range otherwise (`ChatView.tsx:3358-3359`, from a `git status` this port
    /// does not run for the panel); "Working tree" is the useful one of the two
    /// on a ladder, so it is where this opens.
    @State private var scope: T3DiffScope = .workingTree
    @State private var load = T3DiffLoad()
    @State private var pending = true
    /// False until this thread's diff has been read from git once.
    @State private var refreshed = false
    /// The files the reader has collapsed, dropped when the scope changes
    /// (`DiffPanel.tsx:225-232`: the collapsed set is keyed by scope).
    @State private var collapsed: Set<String> = []
    @State private var treeOpen = false
    @State private var expanded: Set<String> = []
    @State private var selected: String?

    private var directories: [String] { T3DiffModel.directoryPaths(load.files.map(\.path)) }

    var body: some View {
        Group {
            if load.inGit || pending {
                VStack(spacing: 0) {
                    header
                    content
                }
            } else {
                T3DiffUnavailable()
            }
        }
        .task(id: scope) {
            if let cached = model.cachedCheckpointDiff(cwd: cwd, sessionId: sessionId, scope: scope) {
                apply(cached)
            }
            // The thread's first look re-reads git behind the cached patch —
            // the browser is re-identified per (cwd, sessionId), so `refreshed`
            // is false again after a thread switch (`T3FilesPanel:118-122`).
            // Later scope switches inside the thread trust the cache; the
            // refresh control is what re-reads them.
            await reload(force: !refreshed)
            refreshed = true
        }
    }

    // MARK: - The subheader

    /// `getDiffPanelHeaderRowClassName("embedded")` (`DiffPanelShell.tsx:10-19`):
    /// "flex items-center justify-between gap-2 px-2" over the non-drag branch's
    /// "h-10 min-h-10 shrink-0 border-b border-border/60 bg-background".
    private var header: some View {
        HStack(spacing: 8) {
            scopeMenu
            Spacer(minLength: 0)
            HStack(spacing: 4) {          // "flex shrink-0 items-center gap-1" (`:745`)
                if !load.files.isEmpty { statLabel }
                refreshButton
                if !load.files.isEmpty {
                    collapseAllButton
                    treeToggle
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(t3.web.background.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }

    /// `<DropdownMenuTrigger>` (`DiffPanel.tsx:547-554`): "h-6 rounded-md
    /// bg-accent px-2 text-xs font-medium text-accent-foreground" with a
    /// `size-3.5` chevron at 70 %. The items are `:556-612` in that order;
    /// the selected one's `bg-foreground/[0.08]` tint (`:559`) has no
    /// equivalent on a native menu row and is skipped.
    private var scopeMenu: some View {
        Menu {
            item("Working tree", selected: scope == .workingTree) { select(.workingTree) }
            item("Branch changes", selected: scope == .branch) { select(.branch) }
            item("Latest turn", selected: scope == .turn(load.checkpoints.last?.n ?? -1)) {
                if let last = load.checkpoints.last { select(.turn(last.n)) }
            }
            Menu("Turn") {
                // "toSorted(… rightTurnCount - leftTurnCount)" (`:178-191`):
                // newest turn first, each row's time after it (`:604-607`,
                // `formatShortTimestamp`).
                ForEach(load.checkpoints.reversed(), id: \.n) { checkpoint in
                    item("Turn \(checkpoint.n)   \(Self.time(checkpoint.at))",
                         selected: scope == .turn(checkpoint.n)) { select(.turn(checkpoint.n)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(scope.label(ladder: load.checkpoints))
                    .font(T3Font.web(.xs, .medium))
                    .lineLimit(1)
                LucideIcon(.chevronDown, size: 14).opacity(0.7)
            }
            .foregroundStyle(t3.web.accentForeground.color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(t3.web.accent.color, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Diff scope: \(scope.label(ladder: load.checkpoints))")
    }

    /// One row of the switcher. Upstream tints the row in force
    /// (`DiffPanel.tsx:556-561` `bg-foreground/[0.08]`); a Mac menu marks it,
    /// the way the composer's mode menu does (`T3ComposerView.swift:374-380`).
    private func item(_ title: String, selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// `<DiffStatLabel layout="inline">` (`DiffPanel.tsx:746-753`,
    /// `DiffStatLabel.tsx:43-48`): a mono `+N` in `success` and `-N` in
    /// `destructive`, at `text-[11px]`.
    private var statLabel: some View {
        let stat = T3DiffModel.stat(load.files)
        return HStack(spacing: 4) {
            Text("+\(T3DiffModel.compactCount(stat.additions))")
                .foregroundStyle(t3.web.success.color)
            Text("-\(T3DiffModel.compactCount(stat.deletions))")
                .foregroundStyle(t3.web.destructive.color)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.trailing, 4)
        .accessibilityLabel("\(stat.additions) additions, \(stat.deletions) deletions")
    }

    /// `:754-773` — the ghost refresh button, spinning while the load is in
    /// flight (`T3Spinner` is this port's only Core-Animation spinner, #18).
    private var refreshButton: some View {
        T3FilesIconButton(help: pending ? "Refreshing diff…" : "Refresh diff") {
            Task { await reload(force: true) }
        } content: {
            if pending { T3Spinner(size: 14) } else { LucideIcon(.refreshCw, size: 14) }
        }
    }

    /// `:774-797`: `chevrons-up-down` once everything is collapsed,
    /// `chevrons-down-up` while anything is open.
    private var collapseAllButton: some View {
        let all = collapsed.count >= load.files.count
        return T3FilesIconButton(help: all ? "Expand all files" : "Collapse all files") {
            collapsed = all ? [] : Set(load.files.map(\.key))
        } content: {
            LucideIcon(all ? .chevronsUpDown : .chevronsDownUp, size: 14)
        }
    }

    /// `:859-878`.
    private var treeToggle: some View {
        T3FilesIconButton(help: treeOpen ? "Hide file tree" : "Show file tree") {
            treeOpen.toggle()
        } content: {
            LucideIcon(.folderTree, size: 14)
                .opacity(treeOpen ? 1 : 0.7)
        }
    }

    // MARK: - The body

    @ViewBuilder private var content: some View {
        if let failure = load.failure, load.files.isEmpty {
            // "mb-2 text-[11px] text-error/80" (`:906-910`).
            Text(failure)
                .font(T3Font.webLiteral(11))
                .foregroundStyle(t3.web.error.color.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if load.files.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if load.truncated {
                    // ":900-905" — the notice above the files.
                    Text("This diff was truncated because it exceeded the preview limit. The changes shown are incomplete.")
                        .font(T3Font.webLiteral(11))
                        .foregroundStyle(t3.web.mutedForeground.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(t3.web.muted.color.opacity(0.4))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(t3.web.border.color.opacity(0.7)).frame(height: 1)
                        }
                }
                split
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if pending {
            T3Spinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if load.checkpoints.isEmpty {
            // Every scope here reads the ladder, so an empty ladder is
            // upstream's "no completed turns" state whichever scope is picked
            // (`DiffPanel.tsx:893-896`).
            T3DiffMessage(text: "No completed turns yet.")
        } else if load.resolved {
            T3DiffMessage(text: "No net changes in this selection.")     // `:926`
        } else {
            T3DiffMessage(text: "No patch available for this selection.")  // `:927`
        }
    }

    /// "flex min-h-0 flex-1 overflow-hidden" with the tree as an `<aside
    /// className="w-[min(16rem,40%)] min-w-40 border-l border-border/60">`
    /// (`:932,1029-1039`).
    private var split: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                files
                if treeOpen {
                    Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(width: 1)
                    tree.frame(width: max(160, min(256, geometry.size.width * 0.4)))
                }
            }
        }
    }

    private var files: some View {
        T3ScrollArea {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(load.files) { file in
                    T3DiffFileView(file: file,
                                   collapsed: collapsed.contains(file.key),
                                   toggle: { toggle(file) })
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(t3.web.codeBackground.color)
    }

    /// `<DiffFileTree>` (`DiffFileTree.tsx:139-207`): the header row is "Files"
    /// with the count on the right and the expand-all pair after it
    /// (`:141-176`), then the tree. Its rows are the Files tab's rows with the
    /// change's colour on the name — the per-extension sprite set upstream
    /// draws them with (`pierre-icons.ts:48-64`) is not ported there either.
    private var tree: some View {
        let entries = T3DiffModel.entries(load.files)
        let nodes = T3FileTree.build(entries.map { T3ProjectFiles.Entry(path: $0.path, kind: .file) })
        let status = Dictionary(entries.map { ($0.path, $0.status) }, uniquingKeysWith: { first, _ in first })
        let allExpanded = T3FileTree.allExpanded(directories: directories, expanded: expanded)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Files")
                    .font(T3Font.web(.xs, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
                Text("\(entries.count)")
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
                if !directories.isEmpty {
                    T3FilesIconButton(help: allExpanded ? "Collapse all folders" : "Expand all folders") {
                        expanded = T3FileTree.setAllExpanded(!allExpanded, directories: directories, in: expanded)
                    } content: {
                        LucideIcon(allExpanded ? .chevronsDownUp : .chevronsUpDown, size: 14)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
            }
            T3ScrollArea {
                LazyVStack(spacing: 0) {
                    ForEach(T3FileTree.flatten(nodes: nodes, expanded: expanded), id: \.node.path) { row in
                        T3DiffTreeRow(row: row,
                                      status: status[row.node.path],
                                      expanded: expanded.contains(row.node.path),
                                      selected: selected == row.node.path) {
                            if row.node.kind == .directory {
                                if expanded.contains(row.node.path) { expanded.remove(row.node.path) }
                                else { expanded.insert(row.node.path) }
                            } else {
                                // "onSelectFile → revealDiffFile" (`:1036`,
                                // `:459-473`): the file's diff is expanded and
                                // scrolled to. There is no scroll target for a
                                // `LazyVStack` row without an outer
                                // ScrollViewReader, so what this does is the
                                // half that matters: it uncollapses the file.
                                selected = row.node.path
                                if let file = load.files.first(where: { $0.path == row.node.path }) {
                                    collapsed.remove(file.key)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(t3.web.background.color)
    }

    // MARK: - Behaviour

    private func select(_ next: T3DiffScope) {
        guard next != scope else { return }
        scope = next
        collapsed = []
        selected = nil
    }

    private func toggle(_ file: T3DiffModel.File) {
        if collapsed.contains(file.key) { collapsed.remove(file.key) } else { collapsed.insert(file.key) }
    }

    private func reload(force: Bool) async {
        pending = true
        defer { pending = false }
        apply(await model.checkpointDiff(cwd: cwd, sessionId: sessionId, scope: scope, reload: force))
    }

    private func apply(_ next: T3DiffLoad) {
        let previous = directories
        load = next
        // A refreshed diff keeps the folders the reader opened, and a folder
        // new to the tree arrives open (`T3DiffModel.carryExpansion`).
        expanded = T3DiffModel.carryExpansion(previous: previous, next: directories, expanded: expanded)
    }

    /// `formatShortTimestamp` (`timestampFormat.ts`): the wall-clock time in
    /// the reader's locale, hour and minute.
    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// One file: the header row and, unless it is collapsed, its hunks.
private struct T3DiffFileView: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let file: T3DiffModel.File
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                if file.isBinary {
                    Text("Binary file not shown")
                        .font(T3Font.webLiteral(11))
                        .foregroundStyle(t3.web.codeForeground.color.opacity(0.52))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                        T3DiffHunkView(hunk: hunk, first: index == 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `[data-diffs-header]` (`StyledDiffCodeView.tsx:79-99`): sans 12 px over
    /// the code background, `min-height: 32px`, `padding: 6px 12px 6px 8px`,
    /// and an inset edge cue on hover (`:94-99`). The chevron carries the
    /// change's colour (`getDiffCollapseIconClassName`,
    /// `diffRendering.ts:237-250`, over `--diffs-*-base`, which this port has
    /// as `success` / `destructive` / `info` — the package's own bases are not
    /// in the checkout).
    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                LucideIcon(collapsed ? .chevronRight : .chevronDown, size: 16)
                    .foregroundStyle(kindColor)
                Text(file.path)
                    .font(T3Font.web(.xs))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(t3.web.codeForeground.color)
                if file.kind == .renamedPure || file.kind == .renamedChanged {
                    Text("← \(file.previousPath)")
                        .font(T3Font.webLiteral(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(t3.web.codeForeground.color.opacity(0.52))
                }
                Spacer(minLength: 8)
                if file.additions > 0 {
                    Text("+\(T3DiffModel.compactCount(file.additions))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t3.web.success.color)
                }
                if file.deletions > 0 {
                    Text("-\(T3DiffModel.compactCount(file.deletions))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t3.web.destructive.color)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t3.web.codeBackground.color)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(t3.web.codeForeground.color.opacity(hover ? 0.24 : 0))
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(collapsed ? "Expand \(file.path)" : "Collapse \(file.path)")
    }

    private var kindColor: Color {
        switch file.kind {
        case .added: return t3.web.success.color
        case .deleted: return t3.web.destructive.color
        case .modified, .renamedPure, .renamedChanged: return t3.web.info.color
        }
    }
}

/// One hunk: the separator row that counts the lines it skipped, then the lines.
private struct T3DiffHunkView: View {
    @Environment(\.t3) private var t3
    let hunk: T3DiffModel.Hunk
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hunk.collapsedBefore > 0 || !hunk.heading.isEmpty || !first { separator }
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                T3DiffLineView(line: line)
            }
        }
    }

    /// `[data-separator="line-info"]` (`StyledDiffCodeView.tsx:101-147`): a
    /// 24 px row over the code background, sans 11 px at `code-foreground 52 %`,
    /// its label between two hairlines. The label's own wording lives in
    /// `@pierre/diffs`, which is not in the checkout: what it counts is
    /// `collapsedBefore` (`diffRendering.ts:209`) and the hunk's context
    /// (`hunkContext`, `:217`), which is what this row says.
    private var separator: some View {
        HStack(spacing: 8) {
            hairline
            if hunk.collapsedBefore > 0 {
                Text(hunk.collapsedBefore == 1 ? "1 unmodified line" : "\(hunk.collapsedBefore) unmodified lines")
                    .fixedSize()
            }
            if !hunk.heading.isEmpty {
                Text(hunk.heading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            hairline
        }
        .font(T3Font.webLiteral(11))
        .foregroundStyle(T3DiffTint.mix(t3.web.codeForeground, t3.web.codeBackground, 0.52))
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 24)
        .background(T3DiffTint.mix(t3.web.codeBackground, t3.web.codeForeground, 0.95))
    }

    private var hairline: some View {
        Rectangle()
            .fill(T3DiffTint.mix(t3.web.codeBackground, t3.web.codeForeground, 0.92))
            .frame(height: 1)
    }
}

/// One line: the two number gutters, then the text in the mono face.
private struct T3DiffLineView: View {
    @Environment(\.t3) private var t3
    let line: T3DiffModel.Line

    /// The row and gutter tints of `DIFF_SURFACE_THEME_UNSAFE_CSS`
    /// (`diffRendering.ts:284-315`), which mixes every one of them from the
    /// code surface: an addition row is `code-background` 70 % with `success`
    /// on dark and 50 % on light, its number column 60 % / 35 %; a deletion the
    /// same over `destructive`; a context row `code-background` 97 % with
    /// `code-foreground` (`:275`).
    private var rowBackground: Color {
        switch line.kind {
        case .addition: return T3DiffTint.mix(t3.web.codeBackground, t3.web.success, dark ? 0.70 : 0.50)
        case .deletion: return T3DiffTint.mix(t3.web.codeBackground, t3.web.destructive, dark ? 0.70 : 0.50)
        case .context: return T3DiffTint.mix(t3.web.codeBackground, t3.web.codeForeground, 0.97)
        }
    }
    private var gutterBackground: Color {
        switch line.kind {
        case .addition: return T3DiffTint.mix(t3.web.codeBackground, t3.web.success, dark ? 0.60 : 0.35)
        case .deletion: return T3DiffTint.mix(t3.web.codeBackground, t3.web.destructive, dark ? 0.60 : 0.35)
        case .context: return T3DiffTint.mix(t3.web.codeBackground, t3.web.codeForeground, 0.90)
        }
    }
    private var dark: Bool { t3.scheme == .dark }

    /// The mono face this port uses for code, at the size its fenced blocks
    /// take (`T3ChatMarkdown`'s `CodeFence`): upstream's diff body is
    /// `--font-mono` at the viewer's own `--diffs-font-size`
    /// (`diffRendering.ts:263`), a number that lives in the package.
    private static let font = Font.system(size: 13, design: .monospaced)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker + line.text)
                .font(Self.font)
                .foregroundStyle(t3.web.codeForeground.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .padding(.vertical, 1)
        }
        .background(rowBackground)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    /// `[data-column-number]`: the line's number on one side, or nothing where
    /// the line does not exist on that side.
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(T3DiffTint.mix(t3.web.codeForeground, t3.web.codeBackground, 0.52))
            .lineLimit(1)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
            .background(gutterBackground)
    }
}

/// `color-mix(in srgb, a P%, b)` — the one operation every diff tint in
/// `DIFF_SURFACE_THEME_UNSAFE_CSS` is written with. Straight component-wise
/// interpolation: the palette's colours are opaque, so there is no
/// premultiplication to undo.
private enum T3DiffTint {
    static func mix(_ a: T3RGBA, _ b: T3RGBA, _ weightOfA: Double) -> Color {
        let w = min(1, max(0, weightOfA))
        return T3RGBA(a.r * w + b.r * (1 - w), a.g * w + b.g * (1 - w),
                      a.b * w + b.b * (1 - w), a.a * w + b.a * (1 - w)).color
    }
}

/// A tree row, the Files tab's row (`T3FileRow`) with the change's colour on
/// the name — upstream's tree paints the same status through
/// `model.setGitStatus` (`DiffFileTree.tsx:102`, `pierre-tree-theme.ts`).
private struct T3DiffTreeRow: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let row: T3FileTree.Visible
    let status: T3DiffModel.Status?
    let expanded: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if row.node.kind == .directory {
                        LucideIcon(expanded ? .chevronDown : .chevronRight, size: 12)
                            .foregroundStyle(t3.web.iconMuted.color)
                    }
                }
                .frame(width: 12)
                Text(row.node.name)
                    .font(T3Font.web(.xs))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(color)
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

    private var color: Color {
        switch status {
        case .added: return t3.web.success.color
        case .deleted: return t3.web.destructive.color
        case .renamed, .modified: return t3.web.info.color
        case nil: return t3.web.foreground.color
        }
    }

    private var background: Color {
        let foreground = t3.web.foreground.color
        if selected { return foreground.opacity(0.12) }
        return hover ? foreground.opacity(0.07) : .clear
    }
}
