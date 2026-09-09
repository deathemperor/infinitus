import XCTest
@testable import InfinitusCore

final class ResidueTests: XCTestCase {
    /// `size(of:)` sums the regular files under the tree, nested dirs
    /// included; directory entries and symlinks add nothing.
    func testSizeSumsRegularFilesThroughNestedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("residue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: root.appendingPathComponent("top.jsonl"))
        try Data(count: 234).write(to: deep.appendingPathComponent("leaf.jsonl"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("top.jsonl"))
        XCTAssertEqual(Residue.size(of: root.path), 1234)
        XCTAssertEqual(Residue.size(of: root.appendingPathComponent("missing").path), 0)
    }
}
