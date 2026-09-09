import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Files wire (#223 proposal), app target only — the share extension
/// compiles NetworkFleetMirror.swift without the T3 tree.
extension NetworkFleetMirror {
    /// The session's workspace files, flat: `GET /sessions/<pid>/files`.
    func files(pid: Int32) async throws -> T3FileTree.Listing {
        try await getJSON("/sessions/\(pid)/files")
    }

    /// One workspace file's text: `GET /sessions/<pid>/file?path=<rel>`.
    /// 400 outside the workspace, 404 gone, 415 binary — surfaced as `.http`.
    func file(pid: Int32, path: String) async throws -> T3FileTree.FileRead {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return try await getJSON("/sessions/\(pid)/file?path=\(encoded)")
    }
}

/// `…/files` (spec §5.1) from the thread header's folder pill.
struct T3FilesRoute: Hashable {
    let session: SessionDetail
    let macId: String?
}

/// `…/files/:path*`: one file.
struct T3SourceFileRoute: Hashable {
    let session: SessionDetail
    let macId: String?
    let path: String
}

/// T3's Files (`ThreadFilesRouteScreen.tsx` + `FileTreeBrowser.tsx` at
/// upstream 6c583620f): the session's workspace as a folder tree from the
/// Mac's flat listing (#223 Files wire), top-level folders open, a search
/// field that shows matches with their ancestors, a tap on a file pushes
/// its source. A Mac without the route says so instead of a tree.
struct T3FilesScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String? = nil
    @Environment(\.t3) private var t3
    @State private var listing: T3FileTree.Listing?
    @State private var tree: [T3FileTree.Node] = []
    @State private var expanded: Set<String> = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    private let fixture: T3FileTree.Listing?

    init(model: MirrorModel, session: SessionDetail, macId: String? = nil) {
        self.model = model; self.session = session; self.macId = macId; fixture = nil
    }

    /// The render harness's listing; nothing is fetched.
    init(model: MirrorModel, session: SessionDetail, fixture: T3FileTree.Listing) {
        self.model = model; self.session = session; self.fixture = fixture
        _listing = State(initialValue: fixture)
        let nodes = T3FileTree.build(fixture.entries)
        _tree = State(initialValue: nodes)
        _expanded = State(initialValue: T3FileTree.defaultExpanded(nodes))
    }

    private var rows: [T3FileTree.Visible] { T3FileTree.flatten(tree, expanded: expanded, search: search) }
    private var project: String { URL(fileURLWithPath: listing?.cwd ?? session.cwd).lastPathComponent }

    var body: some View {
        let p = t3.mobile
        VStack(spacing: 0) {
            searchField.padding(.horizontal, 16).padding(.vertical, 8)
            if let error, listing == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files unavailable").font(T3Font.mobile(.sm, .bold)).foregroundStyle(p.foreground.color)
                    Text(error).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 20)
                Spacer()
            } else if loading && listing == nil {
                Spacer(); ProgressView(); Spacer()
            } else if tree.isEmpty {
                Spacer()
                T3EmptyState(title: "No files", message: "The session's folder has nothing the Mac lists.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.node.path) { row in fileRow(row) }
                        if listing?.truncated == true {
                            Text("The Mac lists the first 20 000 entries; the rest are not shown.")
                                .font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                                .padding(16)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
        }
        .background(p.sheet.color.ignoresSafeArea())
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Files").font(T3Font.mobile(.base, .bold)).foregroundStyle(p.foreground.color)
                    Text(project).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color).lineLimit(1)
                }
            }
        }
        .task { if fixture == nil { await load() } }
    }

    private var searchField: some View {
        let p = t3.mobile
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(p.iconMuted.color)
            TextField("Search files", text: $search)
                .font(T3Font.mobile(.sm)).foregroundStyle(p.foreground.color)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(p.iconMuted.color)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(p.card.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// `FileTreeRow`: 42 pt, 18 pt per depth, chevron for a folder and its
    /// child count at the trailing edge.
    private func fileRow(_ row: T3FileTree.Visible) -> some View {
        let p = t3.mobile
        let node = row.node
        let open = expanded.contains(node.path) || !search.isEmpty
        return Group {
            if node.kind == .directory {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                    }
                } label: { rowLabel(node, depth: row.depth, open: open) }
            } else {
                NavigationLink(value: T3SourceFileRoute(session: session, macId: macId, path: node.path)) {
                    rowLabel(node, depth: row.depth, open: false)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel(node.path)
        .background(Color.clear)
        .foregroundStyle(p.foreground.color)
    }

    private func rowLabel(_ node: T3FileTree.Node, depth: Int, open: Bool) -> some View {
        let p = t3.mobile
        return HStack(spacing: 8) {
            if node.kind == .directory {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.iconMuted.color).frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: node.kind == .directory ? "folder.fill" : Self.glyph(node.name)).font(.system(size: 15))
                .foregroundStyle(node.kind == .directory ? p.icon.color : p.iconMuted.color).frame(width: 17)
            Text(node.name).font(T3Font.mobile(.sm, .medium)).foregroundStyle(p.foregroundSecondary.color).lineLimit(1)
            Spacer(minLength: 0)
            if node.kind == .directory {
                Text("\(node.children.count)").font(T3Font.mobile(.xxs, .medium)).foregroundStyle(p.foregroundTertiary.color)
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * 18).padding(.trailing, 8)
        .frame(minHeight: 42)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// `PierreEntryIcon`'s cheap cousin: one SF Symbol per file family.
    static func glyph(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "mp4", "mov": return "film"
        case "pdf": return "doc.richtext"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "": return "doc"
        default: return "doc.plaintext"
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let reply = try await model.mirror(for: macId).files(pid: Int32(session.pid))
            listing = reply
            tree = T3FileTree.build(reply.entries)
            if expanded.isEmpty { expanded = T3FileTree.defaultExpanded(tree) }
            error = nil
        } catch MirrorTransportError.http(404) {
            error = "This Mac doesn't serve files yet — update Infinitus on the Mac, or the session's folder is gone."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// `SourceFileSurface` / `FileMarkdownPreview`: a file's text with a line
/// gutter in the review's monospace, or markdown rendered; a cut-off file
/// says so, a binary one has no preview. "Add to message" drops `@path`
/// into the thread's composer.
struct T3SourceFileScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String? = nil
    let path: String
    @Environment(\.t3) private var t3
    @Environment(\.dismiss) private var dismiss
    @State private var file: T3FileTree.FileRead?
    @State private var error: String?
    @State private var binary = false
    @State private var copied = false
    private let fixture: T3FileTree.FileRead?

    init(model: MirrorModel, session: SessionDetail, macId: String? = nil, path: String) {
        self.model = model; self.session = session; self.macId = macId; self.path = path; fixture = nil
    }

    init(model: MirrorModel, session: SessionDetail, path: String, fixture: T3FileTree.FileRead) {
        self.model = model; self.session = session; self.path = path; self.fixture = fixture
        _file = State(initialValue: fixture)
    }

    private static let mono = Font.system(size: 12, design: .monospaced)
    private static let rowHeight: CGFloat = 20

    var body: some View {
        let p = t3.mobile
        Group {
            if let file {
                VStack(spacing: 0) {
                    if file.truncated {
                        Text("Showing the first \(Self.kb(file.contents.utf8.count)) of \(Self.kb(file.byteLength)).")
                            .font(T3Font.mobile(.xs)).foregroundStyle(p.warningForeground.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(p.warning.color)
                    }
                    if file.mime == "text/markdown" {
                        ScrollView {
                            MarkdownText(text: file.contents).markdownStyle(.t3(p))
                                .padding(16)
                        }
                    } else {
                        source(file.contents)
                    }
                }
            } else if binary {
                T3EmptyState(title: "No preview", message: "This file is not text; its path can still go into a message.")
            } else if let error {
                T3EmptyState(title: "File unavailable", message: error)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.sheet.color.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text((path as NSString).lastPathComponent).font(T3Font.mobile(.base, .bold)).foregroundStyle(p.foreground.color).lineLimit(1)
                    Text((path as NSString).deletingLastPathComponent).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.requestedComposerInsert = T3FileMention.insertion(for: path)
                        dismiss()
                    } label: { Label("Add to message", systemImage: "text.badge.plus") }
                    Button {
                        UIPasteboard.general.string = path
                        copied = true
                    } label: { Label(copied ? "Path copied" : "Copy path", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(p.icon.color)
                }
                .accessibilityLabel("File actions")
            }
        }
        .task { if fixture == nil { await load() } }
    }

    /// Line rows in a two-axis scroll: the gutter's width from the line count.
    private func source(_ contents: String) -> some View {
        let p = t3.mobile
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let gutter = CGFloat(max(2, String(lines.count).count)) * 7.5 + 16
        return ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 0) {
                        Text("\(index + 1)").font(Self.mono).foregroundStyle(p.foregroundTertiary.color)
                            .frame(width: gutter, alignment: .trailing).padding(.trailing, 12)
                        Text(line.isEmpty ? " " : String(line)).font(Self.mono).foregroundStyle(p.foreground.color)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, 8).padding(.trailing, 16)
        }
    }

    private static func kb(_ bytes: Int) -> String {
        bytes >= 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }

    @MainActor
    private func load() async {
        do {
            file = try await model.mirror(for: macId).file(pid: Int32(session.pid), path: path)
        } catch MirrorTransportError.http(415) {
            binary = true
        } catch MirrorTransportError.http(404) {
            error = "This file is no longer in the session's folder."
        } catch MirrorTransportError.http(400) {
            error = "This path is outside the session's folder."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
