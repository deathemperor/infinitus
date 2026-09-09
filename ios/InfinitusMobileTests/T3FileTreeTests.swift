import XCTest
@testable import InfinitusMobile

/// `fileTree.test.ts` (upstream 6c583620f) case for case.
final class T3FileTreeTests: XCTestCase {
    private let entries: [T3FileTree.Entry] = [
        .init(path: "README.md", kind: .file), .init(path: "src", kind: .directory), .init(path: "src/index.ts", kind: .file),
        .init(path: "src/components/App.tsx", kind: .file), .init(path: "package.json", kind: .file),
    ]

    func testBuildsADeterministicHierarchyWithDirectoriesBeforeFiles() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(tree.map { "\($0.kind.rawValue):\($0.path)" }, ["directory:src", "file:package.json", "file:README.md"])
        XCTAssertEqual(tree[0].children.map { "\($0.kind.rawValue):\($0.path)" }, ["directory:src/components", "file:src/index.ts"])
    }

    func testFlattensExpandedDirectoriesAndHidesCollapsedDescendants() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(T3FileTree.flatten(tree, expanded: ["src"]).map { "\($0.depth):\($0.node.path)" },
                       ["0:src", "1:src/components", "1:src/index.ts", "0:package.json", "0:README.md"])
        XCTAssertEqual(T3FileTree.flatten(tree, expanded: []).map(\.node.path), ["src", "package.json", "README.md"])
    }

    func testSearchIncludesMatchingDescendantsAndTheirAncestors() {
        let tree = T3FileTree.build(entries)
        XCTAssertEqual(T3FileTree.flatten(tree, expanded: [], search: "app").map(\.node.path),
                       ["src", "src/components", "src/components/App.tsx"])
    }

    func testSupportsFuzzyWhitespaceSeparatedPathQueries() {
        let tree = T3FileTree.build([
            .init(path: "docs/internals/workspace-layout.md", kind: .file),
            .init(path: ".repos/alchemy-effect/examples/aws-lambda/src/JobNotifications.ts", kind: .file),
            .init(path: "apps/web/src/components/chat", kind: .directory),
            .init(path: "apps/web/src/components/chat/ChatHeader.test.ts", kind: .file),
            .init(path: "apps/web/src/components/chat/ChatHeader.tsx", kind: .file),
            .init(path: "apps/web/src/components/chat/Composer.tsx", kind: .file),
        ])
        let expected = ["apps", "apps/web", "apps/web/src", "apps/web/src/components", "apps/web/src/components/chat",
                        "apps/web/src/components/chat/ChatHeader.test.ts", "apps/web/src/components/chat/ChatHeader.tsx"]
        for query in ["chat hea", "cht hdr"] {
            XCTAssertEqual(T3FileTree.flatten(tree, expanded: [], search: query).map(\.node.path), expected, query)
        }
    }

    func testExpandsTopLevelDirectoriesByDefault() {
        XCTAssertEqual(T3FileTree.defaultExpanded(T3FileTree.build(entries)), ["src"])
    }

    func testSplitsCamelCaseWords() {
        XCTAssertEqual(T3FileTree.splitWords("ChatHeader.test.ts"), ["chat", "header", "test", "ts"])
        XCTAssertEqual(T3FileTree.splitWords("JSONParser2"), ["json", "parser2"])
    }
}
