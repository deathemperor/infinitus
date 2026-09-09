import Foundation
import InfinitusCore

/// The Files browser's tree (upstream 6c583620f `fileTree.ts`): built on the
/// phone from the Mac's flat entry list, directories before files, natural
/// name order; `flatten` gives the visible rows for an expansion set, and
/// a search shows every match with its ancestors — a token matches a path
/// segment by containment or a camel-case word by subsequence.
enum T3FileTree {
    // The wire's shapes are Core's (`T3ProjectFiles`, shared with the Mac's
    // MirrorServer): named here so the tree reads as one unit.
    typealias Kind = T3ProjectFiles.Kind
    typealias Entry = T3ProjectFiles.Entry
    typealias Listing = T3ProjectFiles.Listing
    typealias FileRead = T3ProjectFiles.FileRead

    final class Node: Equatable {
        let path: String
        let name: String
        fileprivate(set) var kind: Kind
        fileprivate(set) var children: [Node] = []
        /// Lower-cased path segments, and the camel-case words inside them.
        let segments: [String]
        let words: [String]

        fileprivate init(path: String, name: String, kind: Kind) {
            self.path = path
            self.name = name
            self.kind = kind
            let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            segments = parts.map { $0.lowercased() }
            words = parts.flatMap(T3FileTree.splitWords)
        }

        static func == (a: Node, b: Node) -> Bool { a.path == b.path && a.kind == b.kind && a.children == b.children }
    }

    struct Visible: Equatable {
        let node: Node
        let depth: Int
    }

    /// `splitSearchWords`: camel-case and digit boundaries, then anything
    /// non-alphanumeric splits.
    static func splitWords(_ value: String) -> [String] {
        // fileTree.ts's two regexes — "([A-Z]+)([A-Z][a-z])" and
        // "([a-z0-9])([A-Z])" — as one pass (a regex compile per node cost
        // half of a 20 000-entry build): a word ends before an upper-case
        // letter that follows a lower-case letter or digit, or before the
        // last letter of an upper-case run when a lower-case one follows.
        var words: [String] = []
        var current = ""
        let chars = Array(value)
        var prev: Character?
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                prev = nil
                continue
            }
            if let p = prev, c.isUppercase,
               p.isLowercase || p.isNumber || (p.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase) {
                words.append(current.lowercased()); current = ""
            }
            current.append(c)
            prev = c
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    static func build(_ entries: [Entry]) -> [Node] {
        final class Mutable {
            var node: Node
            var children: [String: Mutable] = [:]
            init(_ node: Node) { self.node = node }
        }
        let root = Mutable(Node(path: "", name: "", kind: .directory))
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            var current = root
            for (index, part) in parts.enumerated() {
                let leaf = index == parts.count - 1
                if let child = current.children[part] {
                    if leaf { child.node.kind = entry.kind }
                    current = child
                } else {
                    let child = Mutable(Node(path: parts[0...index].joined(separator: "/"), name: part, kind: leaf ? entry.kind : .directory))
                    current.children[part] = child
                    current = child
                }
            }
        }
        func freeze(_ m: Mutable) -> Node {
            m.node.children = m.children.values.map(freeze).sorted(by: compare)
            return m.node
        }
        return root.children.values.map(freeze).sorted(by: compare)
    }

    /// Directories first, then names in natural, case-insensitive order.
    static func compare(_ a: Node, _ b: Node) -> Bool {
        if a.kind != b.kind { return a.kind == .directory }
        // Finder's order — `localeCompare(numeric, sensitivity: "base")`
        // upstream — and 3.5× the option-set compare's speed.
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// `defaultExpandedTreePaths`: the top-level folders open, the rest shut.
    static func defaultExpanded(_ nodes: [Node]) -> Set<String> {
        Set(nodes.filter { $0.kind == .directory }.map(\.path))
    }

    /// `flattenFileTree`: the rows to draw. Searching opens every folder
    /// and keeps only matches and their ancestors.
    static func flatten(_ nodes: [Node], expanded: Set<String>, search: String = "") -> [Visible] {
        let tokens = search.trimmingCharacters(in: .whitespaces).lowercased()
            .split { $0.isWhitespace || "/\\._-".contains($0) }.map(String.init)
        var out: [Visible] = []
        for node in nodes { _ = visit(node, depth: 0, expanded: expanded, tokens: tokens, into: &out) }
        return out
    }

    @discardableResult
    private static func visit(_ node: Node, depth: Int, expanded: Set<String>, tokens: [String], into out: inout [Visible]) -> Bool {
        let searching = !tokens.isEmpty
        let matches = searching && tokens.allSatisfy { token in
            node.segments.contains { $0.contains(token) } || node.words.contains { subsequence(token, in: $0) }
        }
        var childRows: [Visible] = []
        var descendantMatches = false
        if node.kind == .directory, expanded.contains(node.path) || searching {
            for child in node.children where visit(child, depth: depth + 1, expanded: expanded, tokens: tokens, into: &childRows) {
                descendantMatches = true
            }
        }
        guard !searching || matches || descendantMatches else { return false }
        out.append(Visible(node: node, depth: depth))
        out.append(contentsOf: childRows)
        return matches || descendantMatches
    }

    /// `scoreSubsequenceMatch` reduced to its yes/no: every character of
    /// `query` appears in `value`, in order.
    static func subsequence(_ query: String, in value: String) -> Bool {
        var q = query.makeIterator()
        var next = q.next()
        for c in value where c == next { next = q.next() }
        return next == nil
    }
}
