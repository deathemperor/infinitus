import Foundation

/// The file browser's tree: a flat `T3ProjectFiles.Listing` folded into a
/// hierarchy, flattened back to the rows one panel paints, and filtered by the
/// search field.
///
/// Upstream's web panel hands the whole job to a third-party component
/// (`FileBrowserPanel.tsx:7` `useFileTree` from `@pierre/trees`), so the pure
/// logic transcribed here is the phone's — the same listing, the same tree
/// (`apps/mobile/src/features/files/fileTree.ts`), and its `.test.ts` cases are
/// this file's tests. Foundation only: the phone's own surfaces link it too.
///
/// The expand-all / collapse-all pair is upstream's
/// `fileTreeExpansion.ts:31-55` over a `Set` of expanded paths instead of the
/// tree component's mutable item handles.
public enum T3FileTree: Sendable {

    /// One node. `searchSegments` / `searchWords` are the path's own terms,
    /// built once per node (`fileTree.ts:47-63`) so a keystroke only scores.
    public struct Node: Sendable, Equatable {
        public let path: String
        public let name: String
        public let kind: T3ProjectFiles.Kind
        public let children: [Node]
        let searchSegments: [String]
        let searchWords: [String]
    }

    /// A node at its indentation level — what a row renders from
    /// (`fileTree.ts:13-16`).
    public struct Visible: Sendable, Equatable {
        public let node: Node
        public let depth: Int
        public init(node: Node, depth: Int) { self.node = node; self.depth = depth }
    }

    // MARK: - Building

    private final class MutableNode {
        let path: String
        let name: String
        var kind: T3ProjectFiles.Kind
        var children: [MutableNode] = []
        var childrenByName: [String: MutableNode] = [:]
        init(path: String, name: String, kind: T3ProjectFiles.Kind) {
            self.path = path; self.name = name; self.kind = kind
        }
    }

    /// The listing folded into a hierarchy (`fileTree.ts:87-118`): a path's
    /// missing ancestors are created as directories, a later entry for a path
    /// already created sets its kind, and every level is sorted directories
    /// first.
    public static func build(_ entries: [T3ProjectFiles.Entry]) -> [Node] {
        let root = MutableNode(path: "", name: "", kind: .directory)
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var current = root
            for index in parts.indices {
                let part = parts[index]
                let isLeaf = index == parts.count - 1
                if let child = current.childrenByName[part] {
                    if isLeaf { child.kind = entry.kind }
                    current = child
                    continue
                }
                let child = MutableNode(path: parts[...index].joined(separator: "/"),
                                        name: part, kind: isLeaf ? entry.kind : .directory)
                current.childrenByName[part] = child
                current.children.append(child)
                current = child
            }
        }
        return sortedFreeze(root.children)
    }

    private static func sortedFreeze(_ nodes: [MutableNode]) -> [Node] {
        nodes.sorted(by: precedes).map { node in
            let terms = searchTerms(path: node.path)
            return Node(path: node.path, name: node.name, kind: node.kind,
                        children: sortedFreeze(node.children),
                        searchSegments: terms.segments, searchWords: terms.words)
        }
    }

    /// `compareNodes` (`fileTree.ts:77-85`): directories first, then the name
    /// case- and diacritic-insensitively with digit runs read as numbers
    /// (`localeCompare(…, { numeric: true, sensitivity: "base" })`), with no
    /// locale so the order is the same on every platform. JS's sort is stable
    /// over the insertion order, which for this listing is the path order
    /// (`T3ProjectFiles.list` sorts) — the ordinal tie-break is that, and it
    /// keeps two names that differ only in case in a defined order.
    private static func precedes(_ left: MutableNode, _ right: MutableNode) -> Bool {
        if left.kind != right.kind { return left.kind == .directory }
        switch left.name.compare(right.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return left.name < right.name
        }
    }

    // MARK: - Search terms

    /// Every path component lowercased, plus the words inside each of them
    /// (`fileTree.ts:47-63`).
    static func searchTerms(path: String) -> (segments: [String], words: [String]) {
        var segments: [String] = []
        var words: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            segments.append(segment.lowercased())
            words.append(contentsOf: searchWords(String(segment)))
        }
        return (segments, words)
    }

    /// `splitSearchWords` (`fileTree.ts:38-45`): a word break before every
    /// capital that starts one — after a lower-case letter or a digit, or at
    /// the end of a run of capitals (`FOOBar` → `FOO`, `Bar`) — then a split on
    /// everything that is not an ASCII letter or digit, lowercased. The regexes
    /// upstream runs are ASCII classes, so a non-ASCII letter is a separator
    /// here exactly as it is there.
    static func searchWords(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        let units = Array(value.unicodeScalars)
        func isUpper(_ s: Unicode.Scalar) -> Bool { s >= "A" && s <= "Z" }
        func isLower(_ s: Unicode.Scalar) -> Bool { s >= "a" && s <= "z" }
        func isDigit(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }
        for index in units.indices {
            let scalar = units[index]
            guard isUpper(scalar) || isLower(scalar) || isDigit(scalar) else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                continue
            }
            if isUpper(scalar), index > 0 {
                let previous = units[index - 1]
                let nextIsLower = index + 1 < units.count && isLower(units[index + 1])
                if isLower(previous) || isDigit(previous) || (isUpper(previous) && nextIsLower) {
                    if !current.isEmpty { words.append(current.lowercased()); current = "" }
                }
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// `nodeMatchesSearch` (`fileTree.ts:145-151`): every token has to match,
    /// a segment exactly-to-contains or a word fuzzily as well
    /// (`valueMatchesSearchToken`, `:130-143`).
    static func matches(_ node: Node, tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            node.searchSegments.contains { matches(value: $0, token: token, fuzzy: false) }
                || node.searchWords.contains { matches(value: $0, token: token, fuzzy: true) }
        }
    }

    private static func matches(value: String, token: String, fuzzy: Bool) -> Bool {
        T3FileMention.scoreQueryMatch(value: value, query: token, exactBase: 0, prefixBase: 2,
                                     boundaryBase: 4, includesBase: 6,
                                     fuzzyBase: fuzzy ? 100 : nil,
                                     boundaryMarkers: ["/", "-", "_", "."]) != nil
    }

    /// The query's tokens (`fileTree.ts:189-190`): trimmed, lowercased, split
    /// on whitespace and path punctuation. Empty means "not searching".
    public static func searchTokens(_ query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return normalized.split(whereSeparator: { separators.contains($0) }).map(String.init)
    }

    private static let separators: Set<Character> = [" ", "\t", "\n", "\r", "/", "\\", ".", "_", "-"]

    // MARK: - Flattening

    /// The visible rows, top to bottom (`fileTree.ts:183-195`). A collapsed
    /// directory hides its descendants; while a search runs every directory is
    /// walked and only the matches and their ancestors survive
    /// (`fileTreeSearchMode: "hide-non-matches"`, `FileBrowserPanel.tsx:223`).
    public static func flatten(nodes: [Node], expanded: Set<String>,
                              searchQuery: String = "") -> [Visible] {
        let tokens = searchTokens(searchQuery)
        var output: [Visible] = []
        for node in nodes {
            _ = append(node, depth: 0, expanded: expanded, tokens: tokens, into: &output)
        }
        return output
    }

    /// `flattenNode` (`:153-181`) — returns whether the node or a descendant
    /// matched, which is what keeps an ancestor of a match visible.
    private static func append(_ node: Node, depth: Int, expanded: Set<String>,
                               tokens: [String], into output: inout [Visible]) -> Bool {
        let isSearching = !tokens.isEmpty
        let matched = isSearching && matches(node, tokens: tokens)
        var descendantMatched = false
        var children: [Visible] = []
        if node.kind == .directory, expanded.contains(node.path) || isSearching {
            for child in node.children {
                if append(child, depth: depth + 1, expanded: expanded, tokens: tokens, into: &children) {
                    descendantMatched = true
                }
            }
        }
        guard !isSearching || matched || descendantMatched else { return false }
        output.append(Visible(node: node, depth: depth))
        output.append(contentsOf: children)
        return matched || descendantMatched
    }

    // MARK: - Expansion

    /// The top level's directories, expanded before the user touches anything
    /// (`fileTree.ts:120-128`; upstream's tree opens one level too,
    /// `FileBrowserPanel.tsx:225` `initialExpansion: 1`).
    public static func defaultExpanded(_ nodes: [Node]) -> Set<String> {
        Set(nodes.filter { $0.kind == .directory }.map(\.path))
    }

    /// Every directory in the tree, for the expand-all / collapse-all button
    /// (`FileBrowserPanel.tsx:115-118` builds the same list off the listing).
    public static func directoryPaths(_ nodes: [Node]) -> [String] {
        var paths: [String] = []
        func walk(_ nodes: [Node]) {
            for node in nodes where node.kind == .directory {
                paths.append(node.path)
                walk(node.children)
            }
        }
        walk(nodes)
        return paths
    }

    /// `areAllDirectoriesExpanded` (`fileTreeExpansion.ts:31-42`): false when
    /// there is no directory at all, so the button reads "Expand all folders"
    /// on an empty tree rather than claiming everything is open.
    public static func allExpanded(directories: [String], expanded: Set<String>) -> Bool {
        !directories.isEmpty && directories.allSatisfy { expanded.contains($0) }
    }

    /// `setAllDirectoriesExpanded` (`:44-55`) as a set operation — the "skip a
    /// directory already at the requested state" guard it needs for the tree's
    /// mutable handles has nothing to skip here.
    public static func setAllExpanded(_ expanded: Bool, directories: [String],
                                      in current: Set<String>) -> Set<String> {
        expanded ? current.union(directories) : current.subtracting(directories)
    }

    /// A path's ancestor directories, nearest last — the panel opens them when
    /// a file is revealed from outside the tree (`FileBrowserPanel.tsx:329-335`,
    /// the phone's `ancestorPaths`, `FileTreeBrowser.tsx:35-42`).
    public static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[..<$0].joined(separator: "/") }
    }
}
