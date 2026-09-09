import Foundation

/// The Diff tab's model: one unified patch (a `Checkpoints.Diff.patch`) read
/// into the files, hunks and lines a diff view paints, plus the changed-files
/// tree's own pure rules.
///
/// Upstream renders through a third-party viewer — `DiffPanel.tsx:969`'s
/// `AnnotatableCodeView` wraps `@pierre/diffs`'s `CodeView`
/// (`StyledDiffCodeView.tsx:2-8`), and `parsePatchFiles`
/// (`diffRendering.ts:1`) is that package's parser, not the app's. The package
/// is not in the checkout, so what is transcribed here is the RENDERED result
/// the app's own code reasons over: the `FileDiffMetadata` fields
/// `diffRendering.ts` reads (`type`, `name`/`prevName`, `hunks` with
/// `additionLines`/`deletionLines`/`collapsedBefore`, `:187-232`) and the
/// per-file / per-line shape its CSS styles (`StyledDiffCodeView.tsx:101-147`
/// separators, `:73-99` file headers).
///
/// Foundation only — the phone's review surface (spec §9 "E") reads the same
/// patch over the mirror.
///
/// Not ported, with upstream's lines:
/// - the batch tree operations `buildDiffFileTreeUpdates`
///   (`diffFileTree.logic.ts:62-93`): they exist to mutate `@pierre/trees`'s
///   own model in place so a refreshed diff keeps the folders the reader
///   opened (`:54-60`). A Swift tree is rebuilt from its paths with expansion
///   held in a `Set`, so what is ported is that BEHAVIOUR — `carryExpansion`
///   below — not the add/remove list nothing here consumes.
/// - `buildFileDiffContentVersion` / `buildFileDiffRenderKey`
///   (`diffRendering.ts:170-235`): reconciliation keys for the viewer's
///   incremental repaint. SwiftUI diffs on `File.key` alone.
/// - syntax highlighting (`PREFERRED_HIGHLIGHTER`, `DiffPanel.tsx:1022`) and
///   the intra-line word diff (`lineDiffType: "none"` is already off, `:1019`).
public enum T3DiffModel: Sendable {

    /// `FileDiffMetadata["type"]` as `diffFileTree.logic.ts:12-24` switches
    /// over it, and `getDiffCollapseIconClassName` colours by
    /// (`diffRendering.ts:237-250`).
    public enum Kind: String, Sendable, Equatable {
        case added, deleted, renamedPure, renamedChanged, modified
    }

    /// `GitStatus` as the tree shows it (`diffFileTree.logic.ts:9`).
    public enum Status: String, Sendable, Equatable {
        case added, deleted, renamed, modified
    }

    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case addition, deletion, context }
        public let kind: Kind
        /// The line's number on each side — nil on the side it is missing from,
        /// which is what leaves that gutter column blank.
        public let oldNumber: Int?
        public let newNumber: Int?
        /// The text without its leading `+`/`-`/space marker.
        public let text: String
        /// `\ No newline at end of file` followed this line (`[data-no-newline]`,
        /// `StyledDiffCodeView.tsx:20`).
        public let noNewlineAtEnd: Bool

        public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String,
                    noNewlineAtEnd: Bool = false) {
            self.kind = kind; self.oldNumber = oldNumber; self.newNumber = newNumber
            self.text = text; self.noNewlineAtEnd = noNewlineAtEnd
        }
    }

    public struct Hunk: Sendable, Equatable {
        public let oldStart: Int, oldCount: Int
        public let newStart: Int, newCount: Int
        /// Whatever git wrote after the closing `@@` — the enclosing function,
        /// usually. Upstream's `hunkContext`.
        public let heading: String
        /// Unmodified lines skipped before this hunk — `collapsedBefore`
        /// (`diffRendering.ts:209`), which the separator row counts out
        /// ("N unmodified lines", `[data-unmodified-lines]`,
        /// `StyledDiffCodeView.tsx:124-131`).
        public let collapsedBefore: Int
        public let lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                    heading: String, collapsedBefore: Int, lines: [Line]) {
            self.oldStart = oldStart; self.oldCount = oldCount
            self.newStart = newStart; self.newCount = newCount
            self.heading = heading; self.collapsedBefore = collapsedBefore; self.lines = lines
        }

        public var additions: Int { lines.reduce(0) { $0 + ($1.kind == .addition ? 1 : 0) } }
        public var deletions: Int { lines.reduce(0) { $0 + ($1.kind == .deletion ? 1 : 0) } }
    }

    public struct File: Sendable, Equatable, Identifiable {
        /// `resolveFileDiffPath` (`diffRendering.ts:146-152`): the current path,
        /// with git's `a/`/`b/` prefix off.
        public let path: String
        /// `resolveFileDiffPreviousPath` (`:158-164`) — the same path unless
        /// this is a rename.
        public let previousPath: String
        public let kind: Kind
        public let hunks: [Hunk]
        /// git said the file is binary, so there are no lines to show.
        public let isBinary: Bool

        public init(path: String, previousPath: String, kind: Kind,
                    hunks: [Hunk], isBinary: Bool = false) {
            self.path = path; self.previousPath = previousPath; self.kind = kind
            self.hunks = hunks; self.isBinary = isBinary
        }

        /// `buildFileDiffIdentityKey` (`diffRendering.ts:166-168`): the pair of
        /// names, so a rename is not the same row as the file it replaced.
        public var key: String { "\(previousPath)\u{0}\(path)" }
        public var id: String { key }
        public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
        public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
        public var status: Status {
            switch kind {
            case .added: return .added
            case .deleted: return .deleted
            case .renamedPure, .renamedChanged: return .renamed
            case .modified: return .modified
            }
        }
    }

    // MARK: - Parsing

    /// A unified patch read into files, in the order the patch lists them.
    ///
    /// Nothing is validated: a patch cut mid-line at `Checkpoints.patchCap`
    /// still yields every file before the cut, and the counts come from
    /// counting the lines, never from the `@@` header's claim.
    public static func parse(_ patch: String) -> [File] {
        // `getRenderablePatch` trims the patch before parsing it
        // (`diffRendering.ts:115`) — which is also what keeps the empty string
        // after the final newline from reading as one more context line.
        let patch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        var files: [File] = []
        var draft: Draft?
        var hunk: HunkDraft?

        // A finished hunk lands on its file, which remembers where it ended so
        // the next one knows how many lines it skipped.
        func closeHunk() {
            guard let current = hunk else { return }
            hunk = nil
            draft?.hunks.append(current.frozen())
            draft?.lastOldEnd = current.oldStart + current.oldConsumed
        }
        func closeFile() {
            closeHunk()
            if let open = draft { files.append(open.frozen()) }
            draft = nil
        }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                draft = Draft(header: String(line.dropFirst("diff --git ".count)))
                continue
            }
            guard draft != nil else { continue }
            if line.hasPrefix("@@") {
                closeHunk()
                guard let range = Ranges(line) else { continue }
                // The old side's gap since the previous hunk ended — the
                // "N unmodified lines" the separator row counts out.
                let previousEnd = draft?.lastOldEnd ?? 1
                hunk = HunkDraft(oldStart: range.oldStart, oldCount: range.oldCount,
                                 newStart: range.newStart, newCount: range.newCount,
                                 heading: range.heading,
                                 collapsedBefore: max(0, range.oldStart - previousEnd))
                continue
            }
            if hunk != nil {
                if line.hasPrefix("\\") {          // "\ No newline at end of file"
                    hunk?.markNoNewline()
                    continue
                }
                if let first = line.first, first == "+" || first == "-" || first == " " {
                    hunk?.append(marker: first, text: String(line.dropFirst()))
                    continue
                }
                // An empty line inside a hunk is a context line whose leading
                // space was stripped (git writes it, some producers do not).
                if line.isEmpty {
                    hunk?.append(marker: " ", text: "")
                    continue
                }
                closeHunk()
            }
            // The extended header lines, before the first hunk.
            if line.hasPrefix("new file mode") { draft?.kind = .added }
            else if line.hasPrefix("deleted file mode") { draft?.kind = .deleted }
            else if line.hasPrefix("rename from ") { draft?.renameFrom = String(line.dropFirst("rename from ".count)) }
            else if line.hasPrefix("rename to ") { draft?.renameTo = String(line.dropFirst("rename to ".count)) }
            else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { draft?.isBinary = true }
            else if line.hasPrefix("--- ") { draft?.oldSide = side(String(line.dropFirst(4))) }
            else if line.hasPrefix("+++ ") { draft?.newSide = side(String(line.dropFirst(4))) }
        }
        closeFile()
        return files
    }

    /// `DiffPanel.tsx:412-417`: the files are shown path-sorted, digits read as
    /// numbers and case/diacritics ignored (`localeCompare(…, { numeric: true,
    /// sensitivity: "base" })`) — the comparison `T3FileTree.precedes` makes
    /// for the browser's rows, with the same ordinal tie-break.
    public static func sortedByPath(_ files: [File]) -> [File] {
        files.sorted { left, right in
            switch left.path.compare(right.path, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.path < right.path
            }
        }
    }

    public struct Stat: Sendable, Equatable {
        public let additions: Int, deletions: Int
        public init(additions: Int, deletions: Int) {
            self.additions = additions; self.deletions = deletions
        }
    }

    /// `getDiffLineStat` (`diffRendering.ts:60-72`).
    public static func stat(_ files: [File]) -> Stat {
        Stat(additions: files.reduce(0) { $0 + $1.additions },
             deletions: files.reduce(0) { $0 + $1.deletions })
    }

    /// `formatCompactDiffCount` (`DiffStatLabel.tsx:8-20`): plain under a
    /// thousand, then one decimal place up to ten of the next unit.
    public static func compactCount(_ value: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let unit = Double(value) / divisor
            if unit < 10 {
                // `toFixed(1)` picks the LARGER of two equally close results
                // (ECMA-262 Number.prototype.toFixed), where `%.1f` rounds a
                // half to even: 1.25k is "1.3k" upstream, never "1.2k".
                let tenths = (unit * 10).rounded(.toNearestOrAwayFromZero)
                if tenths.truncatingRemainder(dividingBy: 10) == 0 {
                    return "\(Int(tenths / 10))\(suffix)"       // ".0" is dropped (`:12`)
                }
                return "\(Int(tenths) / 10).\(Int(tenths) % 10)\(suffix)"
            }
            return "\(Int(unit.rounded(.toNearestOrAwayFromZero)))\(suffix)"
        }
        if value < 1_000 { return String(value) }
        if value < 1_000_000 { return scaled(1_000, "k") }
        if value < 1_000_000_000 { return scaled(1_000_000, "m") }
        return scaled(1_000_000_000, "b")
    }

    // MARK: - The changed-files tree

    /// One changed file as the tree shows it (`diffFileTree.logic.ts:7-10`).
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let status: Status
        public init(path: String, status: Status) { self.path = path; self.status = status }
    }

    /// `diffFileTreeEntries` (`diffFileTree.logic.ts:27-31`), keeping the
    /// files' own order.
    public static func entries(_ files: [File]) -> [Entry] {
        files.map { Entry(path: $0.path, status: $0.status) }
    }

    /// `collectDirectoryPaths` (`diffFileTree.logic.ts:37-48`): every ancestor
    /// of every path, once, parents before children. Upstream's trailing slash
    /// is `@pierre/trees`'s id for a directory; `T3FileTree`'s nodes carry the
    /// bare path, so the slash is dropped here.
    public static func directoryPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count > 1 else { continue }
            for end in 1..<parts.count {
                let directory = parts[..<end].joined(separator: "/")
                if seen.insert(directory).inserted { ordered.append(directory) }
            }
        }
        return ordered
    }

    /// What `buildDiffFileTreeUpdates` (`diffFileTree.logic.ts:62-93`) is FOR,
    /// as a set operation: a diff that changes under the reader — a refresh
    /// after an agent edit, another scope — keeps the folders they opened or
    /// closed, while a folder that is new to the tree starts open (upstream's
    /// `initialExpansion: "open"`, `DiffFileTree.tsx:77`: "a diff is a short
    /// list compared to a workspace, and the reader came for the files, not
    /// the folders", `:41-43`). A folder that left and came back is new again,
    /// exactly as upstream's remove/add pair makes it.
    public static func carryExpansion(previous: [String], next: [String],
                                      expanded: Set<String>) -> Set<String> {
        let previous = Set(previous)
        var carried: Set<String> = []
        for directory in next where !previous.contains(directory) || expanded.contains(directory) {
            carried.insert(directory)
        }
        return carried
    }

    // MARK: - Parser internals

    /// `--- a/x` / `+++ /dev/null` → the path, prefix off. Only `a/` and `b/`
    /// are stripped (`resolveFileDiffPath`, `diffRendering.ts:148-151`); a
    /// repository with `diff.noprefix` set writes bare paths, which is what
    /// this then keeps.
    private static func side(_ raw: String) -> String? {
        // git quotes and tab-pads the name when it has to; the tab and
        // anything after it are metadata, not the path.
        var value = raw
        if let tab = value.firstIndex(of: "\t") { value = String(value[value.startIndex..<tab]) }
        if value == "/dev/null" { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
        return value
    }

    private struct Ranges {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String

        /// `@@ -12,7 +12,9 @@ func body()` — a count of 1 may be left out.
        init?(_ line: String) {
            guard let open = line.range(of: "@@ "), let close = line.range(of: " @@", range: open.upperBound..<line.endIndex)
            else { return nil }
            let spec = line[open.upperBound..<close.lowerBound]
            let sides = spec.split(separator: " ")
            guard sides.count >= 2, sides[0].hasPrefix("-"), sides[1].hasPrefix("+") else { return nil }
            func numbers(_ side: Substring) -> (Int, Int)? {
                let parts = side.dropFirst().split(separator: ",")
                guard let start = Int(parts[0]) else { return nil }
                return (start, parts.count > 1 ? (Int(parts[1]) ?? 1) : 1)
            }
            guard let old = numbers(sides[0]), let new = numbers(sides[1]) else { return nil }
            oldStart = old.0; oldCount = old.1; newStart = new.0; newCount = new.1
            heading = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    private struct HunkDraft {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        let heading: String, collapsedBefore: Int
        private var pending: [Line] = []
        private var oldNext: Int
        private var newNext: Int
        /// Old-side lines consumed so far, for the next hunk's gap.
        var oldConsumed = 0

        init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
             heading: String, collapsedBefore: Int) {
            self.oldStart = oldStart; self.oldCount = oldCount
            self.newStart = newStart; self.newCount = newCount
            self.heading = heading; self.collapsedBefore = collapsedBefore
            oldNext = oldStart; newNext = newStart
        }

        mutating func append(marker: Character, text: String) {
            switch marker {
            case "+":
                pending.append(Line(kind: .addition, oldNumber: nil, newNumber: newNext, text: text))
                newNext += 1
            case "-":
                pending.append(Line(kind: .deletion, oldNumber: oldNext, newNumber: nil, text: text))
                oldNext += 1
                oldConsumed += 1
            default:
                pending.append(Line(kind: .context, oldNumber: oldNext, newNumber: newNext, text: text))
                oldNext += 1
                newNext += 1
                oldConsumed += 1
            }
        }

        mutating func markNoNewline() {
            guard let last = pending.popLast() else { return }
            pending.append(Line(kind: last.kind, oldNumber: last.oldNumber, newNumber: last.newNumber,
                                text: last.text, noNewlineAtEnd: true))
        }

        func frozen() -> Hunk {
            Hunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                 heading: heading, collapsedBefore: collapsedBefore, lines: pending)
        }
    }

    private struct Draft {
        let header: String
        var kind: Kind?
        var oldSide: String?
        var newSide: String?
        var renameFrom: String?
        var renameTo: String?
        var isBinary = false
        var hunks: [Hunk] = []
        /// Where the last hunk ended on the old side, for `collapsedBefore`.
        var lastOldEnd: Int?

        init(header: String) { self.header = header }

        func frozen() -> File {
            let path = renameTo ?? newSide ?? oldSide ?? headerPaths().new ?? headerPaths().old ?? ""
            let previous = renameFrom ?? oldSide ?? newSide ?? headerPaths().old ?? path
            let resolved: Kind
            if let kind { resolved = kind }
            else if renameFrom != nil || renameTo != nil { resolved = hunks.isEmpty ? .renamedPure : .renamedChanged }
            else { resolved = .modified }
            return File(path: path, previousPath: resolved == .added ? path : previous,
                        kind: resolved, hunks: hunks, isBinary: isBinary)
        }

        /// `diff --git a/x b/y` as a last resort — the `---`/`+++` pair is
        /// absent from a pure rename and from a mode-only change. A name with
        /// a space in it makes this ambiguous; the ` b/` split is the same
        /// guess git's own tooling makes.
        private func headerPaths() -> (old: String?, new: String?) {
            if header.hasPrefix("a/"), let split = header.range(of: " b/") {
                return (String(header[header.index(header.startIndex, offsetBy: 2)..<split.lowerBound]),
                        String(header[header.index(split.lowerBound, offsetBy: 3)...]))
            }
            let parts = header.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return (nil, nil) }
            return (T3DiffModel.side(String(parts[0])), T3DiffModel.side(String(parts[1])))
        }
    }
}
