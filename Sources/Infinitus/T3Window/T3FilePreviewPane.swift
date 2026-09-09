import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The Files tab's preview pane (`FilePreviewPanel.tsx`, read-only half): the
/// clicked file's crumb trail over its text, numbered line by line.
///
/// Upstream's panel IS the whole Files surface — the browser is mounted inside
/// it (`:1330-1349`), so with no file open the tree fills the tab and a click
/// splits it: the preview takes the room, the tree becomes the right-hand aside
/// (`w-[min(22rem,46%)] min-w-64 border-l`) and the header's `folder-tree`
/// toggle hides it (`:1196-1213`). `T3FilesSurface` lays that out; this view is
/// the left column plus the header above both.
///
/// Not ported, each with its upstream line:
/// - EDITING (`EditableFileSurface`, `:1307-1320`, with `useFileSaveCoordinator`
///   and the dirty/pending plumbing): a later round. The text here is read-only,
///   selectable, and no `T3ProjectFiles` write path exists to save it through.
/// - syntax highlighting (`:1300` `preferredHighlighter: PREFERRED_HIGHLIGHTER`,
///   applied by `@pierre/diffs`' `File`): the highlighter is a package, not
///   source in the checkout — there is nothing to mirror, so the lines are plain
///   text in `codeForeground`.
/// - the rendered-markdown / rendered-HTML toggle (`:1147-1175`, `Eye` ↔ `Code2`
///   over `renderMarkdown` / `renderBrowserFile`): a second renderer per file
///   type, and the markdown one would want `T3ChatMarkdown` inside a scroller.
/// - the image, video, PDF and browser previews (`:1220-1250`): `T3ProjectFiles.read`
///   answers `.binary` for those extensions by design (it is the phone's text
///   route), so they land in the binary state.
/// - "open in preview browser" (`:1177-1194`) — no in-app browser here — and
///   `OpenInPicker`'s editor list (`:1140-1148`): the Mac hands the file to
///   whatever app owns it, one button.
/// - the per-crumb folder menu (`FileBreadcrumbs.tsx:69-195`: each directory
///   crumb opens a listing of its children to walk sideways): navigation, not
///   preview — the crumbs here are labels with their full path as the help tag.
struct T3FilePreviewPane: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String
    let projectName: String
    let path: String
    /// Bumped by the browser's refresh button, so the open file is read again
    /// (upstream's `onRefreshSelectedFile`, `FilePreviewPanel.tsx:1345-1347`).
    let revision: Int
    let explorerOpen: Bool
    let toggleExplorer: () -> Void

    /// `nil` is upstream's `file.data === null` — the load has not landed
    /// (`:1268-1270`, a centred spinner).
    @State private var read: Result<T3ProjectFiles.FileRead, T3ProjectFiles.ReadError>?
    @State private var slice = T3FilePreview.Slice(lines: [], trimmed: false)

    private struct Load: Equatable { let path: String; let revision: Int }

    var body: some View {
        VStack(spacing: 0) {
            header
            notice
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
        .task(id: Load(path: path, revision: revision)) { await load() }
    }

    // MARK: - The header

    /// "flex h-10 min-h-10 shrink-0 items-center gap-2 border-b border-border/60
    /// bg-background px-3" (`:1104`).
    private var header: some View {
        HStack(spacing: 8) {
            crumbs
            openButton
            explorerToggle
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(t3.web.background.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }

    /// The trail in a horizontal `ScrollArea` that keeps the current file in
    /// view (`:1120-1136`; `scrollIntoView` at `:1056-1061` — a scroller that
    /// starts at the end shows the file name, which is the part that matters).
    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(T3FilePreview.breadcrumbs(projectName: projectName, path: path).enumerated()),
                        id: \.offset) { index, crumb in
                    if index > 0 {
                        LucideIcon(.chevronRight, size: 14)
                            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.6))
                            .padding(.horizontal, 4)
                    }
                    // "block max-w-40 truncate rounded-sm px-0.5" with the file
                    // crumb in `font-medium text-foreground` and the rest in
                    // `text-muted-foreground` (`BreadcrumbLabel`, `:48-65`).
                    Text(crumb.label)
                        .font(T3Font.web(.xs, crumb.kind == .file ? .medium : .regular))
                        .foregroundStyle(crumb.kind == .file
                                         ? t3.web.foreground.color : t3.web.mutedForeground.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 2)
                        .help(crumb.path.isEmpty ? projectName : crumb.path)
                }
            }
            .frame(minWidth: 0, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `OpenInPicker` compact (`:1140-1148`, `aria-label="Open file in preferred
    /// editor"`): upstream sends the path to the editor the user picked from its
    /// list, which this port has no equivalent of — the file goes to whatever
    /// app owns it, so the label says that instead of promising an editor.
    private var openButton: some View {
        T3FilesIconButton(help: "Open file in its default app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd).appendingPathComponent(path))
        } content: {
            LucideIcon(.externalLink, size: 14)
        }
    }

    /// `:1196-1213`: a `folder-tree` ghost toggle, pressed while the tree is up,
    /// labelled "Hide file explorer" / "Show file explorer".
    private var explorerToggle: some View {
        T3FilesIconButton(help: explorerOpen ? "Hide file explorer" : "Show file explorer",
                          pressed: explorerOpen, action: toggleExplorer) {
            LucideIcon(.folderTree, size: 14)
        }
    }

    // MARK: - The states

    /// The capped-read strip (`:1216-1220`): "shrink-0 border-b border-warning/20
    /// bg-warning-surface px-3 py-1.5 text-[11px] text-warning-foreground",
    /// above text that still shows.
    @ViewBuilder private var notice: some View {
        if case .success(let file) = read,
           let text = T3FilePreview.limitNotice(byteLength: file.byteLength,
                                                truncated: file.truncated, trimmed: slice.trimmed) {
            Text(text)
                .font(T3Font.webLiteral(11))
                .foregroundStyle(t3.web.warningForeground.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(t3.web.warningSurface.color)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(t3.web.warning.color.opacity(0.2)).frame(height: 1)
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch read {
        case nil:
            // "flex min-h-0 flex-1 items-center justify-center text-muted-foreground"
            // with a `size-5` spinner (`:1268-1270`).
            T3Spinner(size: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let error):
            // "flex min-h-0 flex-1 items-center justify-center px-6 text-center
            // text-xs leading-relaxed text-destructive" (`:1257-1261`).
            Text(T3FilePreview.message(for: error, path: path, root: cwd))
                .font(T3Font.web(.xs))
                .lineSpacing(T3TypeScale.lineSpacing(T3TypeScale.Web.xs.step))
                .multilineTextAlignment(.center)
                .foregroundStyle(t3.web.destructive.color)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .success:
            T3FileLines(lines: slice.lines)
        }
    }

    // MARK: - Behaviour

    private func load() async {
        // The lines go first: they belong to the file that WAS open, and the
        // header above them has already moved on to this one.
        slice = T3FilePreview.Slice(lines: [], trimmed: false)
        // The read this (cwd, path) was last seen with paints first; behind it
        // the model's own cache decides whether anything is read at all.
        read = model.cachedFileRead(cwd: cwd, path: path)
        let result = await model.fileRead(cwd: cwd, path: path)
        guard !Task.isCancelled else { return }
        // Cutting 256 KB into lines is not main-actor work (#18).
        if case .success(let file) = result {
            let contents = file.contents
            let split = await Task.detached(priority: .userInitiated) {
                T3FilePreview.split(contents)
            }.value
            guard !Task.isCancelled else { return }
            slice = split
        }
        read = result
    }
}

/// The text. Upstream hands it to `@pierre/diffs`' `File` inside a `Virtualizer`
/// (`FilePreviewPanel.tsx:1284-1305`) — numbered lines on `--code-background`
/// that soft-wrap, since `wordWrap` defaults on (`packages/contracts/src/
/// settings.ts:448`; its toggle is a client setting this port has no surface
/// for, so the lines always wrap and there is no wrap button).
///
/// A `LazyVStack` of rows is the virtualizer: a 256 KB file is thousands of
/// lines and only the visible ones are ever built (one `Text` for the whole
/// file would also lose the gutter).
private struct T3FileLines: View {
    @Environment(\.t3) private var t3
    let lines: [String]

    /// The gutter is as wide as the last line's number, plus a point of slack:
    /// SF Mono's advance is 0.6 em and a frame of exactly that rounds the wrong
    /// way, which wraps "10" into a 1 over a 0.
    private var gutterWidth: Double {
        (Double(String(max(1, lines.count)).count) * T3ChatMarkdown.codeFontSize * 0.6).rounded(.up) + 2
    }

    var body: some View {
        T3ScrollArea {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    row(number: index + 1, line: line)
                }
            }
            // `pre`'s own box (`index.css:1822-1829`: `padding: 0.8rem 0.9rem`).
            .padding(.vertical, 0.8 * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.codeBackground.color)
    }

    private func row(number: Int, line: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(T3ChatMarkdown.codeFont)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(t3.web.codeForeground.color.opacity(0.4))
                .frame(width: gutterWidth, alignment: .trailing)
            // An empty line still needs its box, or its number sits on the next
            // line's text.
            Text(line.isEmpty ? " " : line)
                .font(T3ChatMarkdown.codeFont)
                .foregroundStyle(t3.web.codeForeground.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 0.9 * 16)
    }
}
