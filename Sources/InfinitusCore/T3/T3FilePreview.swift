import Foundation

/// What the Files tab's preview pane needs before it can draw one file
/// (`apps/web/src/components/files/FilePreviewPanel.tsx`, read-only half): the
/// header's crumb trail, the text cut into numbered lines, and the copy for a
/// read that came back binary, missing or capped.
///
/// Upstream splits the same three jobs across `filePath.ts` (the crumbs),
/// `@pierre/diffs`' `File` (the numbered, highlighted lines — not in the
/// checkout, `FilePreviewPanel.tsx:1300`) and the server's own error messages
/// (`apps/server/src/workspace/WorkspaceFileSystem.ts:53-95`,
/// `packages/contracts/src/project.ts:262`), which the panel renders verbatim
/// (`:1257-1261` `{file.error}`). Foundation only.
public enum T3FilePreview: Sendable {
    // MARK: - Breadcrumbs

    public enum CrumbKind: String, Sendable, Equatable { case project, directory, file }

    public struct Crumb: Sendable, Equatable {
        /// The segment as the header shows it.
        public let label: String
        /// The cwd-relative path this crumb stands for; `""` is the project.
        public let path: String
        public let kind: CrumbKind
        public init(label: String, path: String, kind: CrumbKind) {
            self.label = label; self.path = path; self.kind = kind
        }
    }

    /// `fileBreadcrumbs` (`filePath.ts:20-33`): the project, then one crumb per
    /// segment, the last one the file. Repeated separators collapse.
    ///
    /// Upstream also starts an ABSOLUTE host path at the filesystem root
    /// (`:21-24` — a file outside the workspace, shown but never edited); this
    /// port never has one, because `T3ProjectFiles.read` refuses anything that
    /// is not cwd-relative (`normalized`).
    public static func breadcrumbs(projectName: String, path: String) -> [Crumb] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var crumbs = [Crumb(label: projectName, path: "", kind: .project)]
        for (index, part) in parts.enumerated() {
            crumbs.append(Crumb(label: part, path: parts[0...index].joined(separator: "/"),
                                kind: index == parts.count - 1 ? .file : .directory))
        }
        return crumbs
    }

    // MARK: - Lines

    /// Rows the pane will ever build for one file. `T3ProjectFiles.readCap`
    /// bounds the BYTES (256 KiB), which is still a quarter of a million rows
    /// when every one of them is empty — upstream leans on `@pierre/diffs`'
    /// virtualizer instead of a cap (`FilePreviewPanel.tsx:1283-1305`), the
    /// port's `LazyVStack` gets this.
    public static let lineCap = 20_000

    public struct Slice: Sendable, Equatable {
        /// Line 1 first, without its terminator.
        public let lines: [String]
        /// `lineCap` cut the file short.
        public let trimmed: Bool
        public init(lines: [String], trimmed: Bool) { self.lines = lines; self.trimmed = trimmed }
    }

    /// One file's text as numbered lines. A blank line keeps its number and a
    /// trailing newline ENDS the last line rather than starting another.
    ///
    /// The break is any of the three terminators, not `"\n"` alone: Swift reads
    /// CRLF as ONE Character, so a `split(separator: "\n")` finds no break at
    /// all in a CRLF file and hands the pane the whole thing as line 1.
    public static func split(_ contents: String, lineCap: Int = lineCap) -> Slice {
        guard !contents.isEmpty else { return Slice(lines: [], trimmed: false) }
        var body = Substring(contents)
        if let last = body.last, isBreak(last) { body = body.dropLast() }
        var lines: [String] = []
        var trimmed = false
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: isBreak) {
            if lines.count == lineCap {
                trimmed = true
                break
            }
            lines.append(String(line))
        }
        return Slice(lines: lines, trimmed: trimmed)
    }

    static func isBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    // MARK: - The states' copy

    /// What the pane shows in place of the text, straight from the message
    /// upstream's own read failures carry:
    /// - `binary` → `WorkspaceBinaryFileError` (`WorkspaceFileSystem.ts:93-95`).
    /// - `outsideRoot` → `WorkspaceFilePathEscapeError` (`:67-69`), minus the
    ///   resolved path this port never returns.
    /// - `notFound` → `ProjectReadFileError`'s own fallback
    ///   (`project.ts:262`). Upstream has no missing-file copy of its own: a
    ///   file that is gone fails the `open` and the panel prints that
    ///   operation's raw message (`WorkspaceFileSystem.ts:53-55`), which names
    ///   a syscall and two absolute paths — the fallback is the same failure
    ///   said once.
    /// - `failed` → the route's own message, as `{file.error}` does.
    public static func message(for error: T3ProjectFiles.ReadError,
                               path: String, root: String) -> String {
        switch error {
        case .binary:
            return "Workspace file '\(path)' in '\(root)' is binary and cannot be previewed as text."
        case .outsideRoot:
            return "Workspace file '\(path)' resolves outside workspace root '\(root)'."
        case .notFound:
            return "Failed to read workspace file '\(path)' in '\(root)'."
        case .failed(let message):
            return message
        }
    }

    /// The notice above a file the read could not hand over whole
    /// (`FilePreviewPanel.tsx:1216-1220`: a warning strip over the text, which
    /// still shows) — `nil` when the whole file is on screen. Upstream's cap is
    /// 1 MB and its sentence says so; the number here comes from `cap`, so the
    /// copy follows `T3ProjectFiles.readCap` rather than repeating it.
    ///
    /// A file under the byte cap with more lines than `lineCap` is the port's
    /// own case (upstream virtualizes instead of capping), so its sentence is
    /// the port's too — the byte one's shape with lines in it.
    public static func limitNotice(byteLength: Int, truncated: Bool, trimmed: Bool,
                                   cap: Int = T3ProjectFiles.readCap, lineCap: Int = lineCap,
                                   locale: Locale = .current) -> String? {
        if truncated {
            return "Preview limited to the first \(cap / 1024) KB of a "
                + "\(grouped(byteLength, locale: locale)) byte file."
        }
        if trimmed { return "Preview limited to the first \(grouped(lineCap, locale: locale)) lines." }
        return nil
    }

    /// `Number.prototype.toLocaleString` — grouped for the reader's locale.
    static func grouped(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
