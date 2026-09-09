import XCTest
@testable import InfinitusCore

/// Upstream's own cases for the file browser's tree, transcribed:
/// `apps/mobile/src/features/files/fileTree.test.ts` for the hierarchy, the
/// flattening and the search, `apps/web/src/components/files/
/// fileTreeExpansion.test.ts` for expand-all / collapse-all.
final class T3FileTreeTests: XCTestCase {

    /// `fileTree.test.ts:6-12`.
    private let entries = [
        T3ProjectFiles.Entry(path: "README.md", kind: .file),
        T3ProjectFiles.Entry(path: "src", kind: .directory),
        T3ProjectFiles.Entry(path: "src/index.ts", kind: .file),
        T3ProjectFiles.Entry(path: "src/components/App.tsx", kind: .file),
        T3ProjectFiles.Entry(path: "package.json", kind: .file),
    ]

    // MARK: - build

    /// `:15-27` "builds a deterministic hierarchy with directories before files".
    func testTheHierarchyPutsDirectoriesBeforeFiles() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(tree.map { "\($0.kind.rawValue):\($0.path)" },
                       ["directory:src", "file:package.json", "file:README.md"])
        XCTAssertEqual(tree[0].children.map { "\($0.kind.rawValue):\($0.path)" },
                       ["directory:src/components", "file:src/index.ts"])
    }

    /// The listing names `src/components` only through a file under it
    /// (`fileTree.ts:105`): the missing ancestor is a directory.
    func testAMissingAncestorBecomesADirectory() {
        let tree = T3FileTree.build([T3ProjectFiles.Entry(path: "a/b/c.txt", kind: .file)])
        XCTAssertEqual(tree.map(\.kind), [.directory])
        XCTAssertEqual(tree[0].children.map(\.kind), [.directory])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["a/b/c.txt"])
    }

    // MARK: - flatten

    /// `:29-45` "flattens expanded directories and hides collapsed descendants".
    func testFlatteningHidesACollapsedDirectorysDescendants() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(T3FileTree.flatten(nodes: tree, expanded: ["src"]).map { "\($0.depth):\($0.node.path)" },
                       ["0:src", "1:src/components", "1:src/index.ts", "0:package.json", "0:README.md"])
        XCTAssertEqual(T3FileTree.flatten(nodes: tree, expanded: []).map(\.node.path),
                       ["src", "package.json", "README.md"])
    }

    /// `:47-57` "includes matching descendants and their ancestors during search".
    func testASearchKeepsAMatchsAncestors() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(T3FileTree.flatten(nodes: tree, expanded: [], searchQuery: "app").map(\.node.path),
                       ["src", "src/components", "src/components/App.tsx"])
    }

    /// `:59-94` "supports fuzzy, whitespace-separated path queries".
    func testAFuzzyMultiTokenQueryMatchesAPath() {
        let tree = T3FileTree.build([
            T3ProjectFiles.Entry(path: "docs/internals/workspace-layout.md", kind: .file),
            T3ProjectFiles.Entry(path: ".repos/alchemy-effect/examples/aws-lambda/src/JobNotifications.ts",
                                 kind: .file),
            T3ProjectFiles.Entry(path: "apps/web/src/components/chat", kind: .directory),
            T3ProjectFiles.Entry(path: "apps/web/src/components/chat/ChatHeader.test.ts", kind: .file),
            T3ProjectFiles.Entry(path: "apps/web/src/components/chat/ChatHeader.tsx", kind: .file),
            T3ProjectFiles.Entry(path: "apps/web/src/components/chat/Composer.tsx", kind: .file),
        ])
        let expected = ["apps", "apps/web", "apps/web/src", "apps/web/src/components",
                        "apps/web/src/components/chat",
                        "apps/web/src/components/chat/ChatHeader.test.ts",
                        "apps/web/src/components/chat/ChatHeader.tsx"]
        for query in ["chat hea", "cht hdr"] {
            XCTAssertEqual(T3FileTree.flatten(nodes: tree, expanded: [], searchQuery: query).map(\.node.path),
                           expected, "query \(query)")
        }
    }

    /// A search walks collapsed directories (`fileTree.ts:165`), and a query of
    /// nothing but separators is no search at all (`:189-190`).
    func testAWhitespaceQueryIsNotASearch() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(T3FileTree.searchTokens("  /  "), [])
        XCTAssertEqual(T3FileTree.flatten(nodes: tree, expanded: [], searchQuery: "   ").map(\.node.path),
                       ["src", "package.json", "README.md"])
    }

    // MARK: - the search terms

    /// `splitSearchWords` (`fileTree.ts:38-45`).
    func testWordsSplitOnCaseBoundariesAndPunctuation() {
        XCTAssertEqual(T3FileTree.searchWords("ChatHeader.test.ts"), ["chat", "header", "test", "ts"])
        XCTAssertEqual(T3FileTree.searchWords("HTTPServer"), ["http", "server"])
        XCTAssertEqual(T3FileTree.searchWords("workspace-layout"), ["workspace", "layout"])
        XCTAssertEqual(T3FileTree.searchWords("v2Model"), ["v2", "model"])
    }

    func testTheSegmentsAreThePathsOwnComponents() {
        let terms = T3FileTree.searchTerms(path: "Apps/Web/ChatHeader.tsx")
        XCTAssertEqual(terms.segments, ["apps", "web", "chatheader.tsx"])
        XCTAssertEqual(terms.words, ["apps", "web", "chat", "header", "tsx"])
    }

    // MARK: - expansion

    /// `:96-100` "expands top-level directories by default".
    func testTheTopLevelsDirectoriesAreExpandedByDefault() {
        XCTAssertEqual(T3FileTree.defaultExpanded(T3FileTree.build(entries)), ["src"])
    }

    func testEveryDirectoryIsListedForTheExpandAllButton() {
        XCTAssertEqual(T3FileTree.directoryPaths(T3FileTree.build(entries)), ["src", "src/components"])
    }

    /// `fileTreeExpansion.test.ts:35-42` "requires at least one directory and
    /// detects whether all are expanded".
    func testAllExpandedNeedsAtLeastOneDirectory() {
        XCTAssertFalse(T3FileTree.allExpanded(directories: [], expanded: ["src", "test"]))
        XCTAssertTrue(T3FileTree.allExpanded(directories: ["src", "test"], expanded: ["src", "test"]))
        XCTAssertFalse(T3FileTree.allExpanded(directories: ["src", "test"], expanded: ["src"]))
    }

    /// `:44-51` "expands and collapses every directory".
    func testSettingAllExpandedOpensAndClosesEveryDirectory() {
        let directories = ["src", "test"]
        let opened = T3FileTree.setAllExpanded(true, directories: directories, in: ["src"])
        XCTAssertEqual(opened, ["src", "test"])
        XCTAssertEqual(T3FileTree.setAllExpanded(false, directories: directories, in: opened), [])
    }

    /// `FileBrowserPanel.tsx:329-335` reveals a file by opening its ancestors.
    func testAncestorsAreTheDirectoriesAboveAFile() {
        XCTAssertEqual(T3FileTree.ancestors(of: "a/b/c.txt"), ["a", "a/b"])
        XCTAssertEqual(T3FileTree.ancestors(of: "README.md"), [])
    }
}
