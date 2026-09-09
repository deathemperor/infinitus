import XCTest
@testable import InfinitusCore

/// The phone's file browser wire (#223, spec E): a flat listing of the
/// session's workspace and one file's text, with the refusals the routes map
/// to 400 / 404 / 415.
final class T3ProjectFilesTests: XCTestCase {

    /// A throwaway tree; the temp directory is itself a symlink on macOS
    /// (`/var` → `/private/var`), which is exactly what the read's root
    /// canonicalization has to survive.
    private func tree(_ files: [String: Data]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3-files-\(UUID().uuidString)")
        for (file, contents) in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func tree(_ files: [String]) throws -> URL {
        try tree(Dictionary(uniqueKeysWithValues: files.map { ($0, Data("x".utf8)) }))
    }

    // MARK: - list

    func testTheListingIsFlatSortedAndCarriesEveryAncestorDirectoryOnce() throws {
        let root = try tree(["README.md", "Sources/App/Main.swift", "Sources/App/util.swift",
                             ".git/config", "node_modules/pkg/i.js", ".build/debug/x.o"])
        let listing = try T3ProjectFiles.list(root: root.path).get()
        XCTAssertEqual(listing.cwd, root.path)
        XCTAssertFalse(listing.truncated)
        XCTAssertEqual(listing.entries.map(\.path),
                       ["README.md", "Sources", "Sources/App",
                        "Sources/App/Main.swift", "Sources/App/util.swift"])
        XCTAssertEqual(listing.entries.map(\.kind),
                       [.file, .directory, .directory, .file, .file])
        XCTAssertEqual(listing.entries.first?.size, 1)
        XCTAssertNil(listing.entries.first(where: { $0.kind == .directory })?.size)
    }

    /// The walk skips them on its own; `git ls-files` does not, so a repo
    /// that never gitignored its `node_modules` still browses without it.
    func testTheBuildAndVendorTreesAreSkippedWhateverTheSourceWas() {
        XCTAssertTrue(T3ProjectFiles.isSkipped(["node_modules", "pkg"]))
        XCTAssertTrue(T3ProjectFiles.isSkipped([".build", "debug"]))
        XCTAssertTrue(T3ProjectFiles.isSkipped([".git"]))
        XCTAssertFalse(T3ProjectFiles.isSkipped(["Sources", "App"]))
        XCTAssertFalse(T3ProjectFiles.isSkipped([]))
    }

    func testTheListingStopsAtTheCapAndSaysSo() throws {
        let root = try tree(["a.txt", "b.txt", "c.txt"])
        let listing = try T3ProjectFiles.list(root: root.path, cap: 2).get()
        XCTAssertTrue(listing.truncated)
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt", "b.txt"])
    }

    func testAListingOfAGoneCwdFails() {
        XCTAssertEqual(T3ProjectFiles.list(root: "/nope/not/here").failure, .rootGone)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t3-\(UUID().uuidString)")
        try? Data("x".utf8).write(to: file)
        XCTAssertEqual(T3ProjectFiles.list(root: file.path).failure, .rootGone)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - read

    func testASmallTextFileComesBackWholeWithItsMime() throws {
        let root = try tree(["notes.md": Data("hello\n".utf8)])
        let read = try T3ProjectFiles.read(root: root.path, path: "./notes.md").get()
        XCTAssertEqual(read.path, "notes.md")
        XCTAssertEqual(read.contents, "hello\n")
        XCTAssertEqual(read.byteLength, 6)
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.mime, "text/markdown")
    }

    func testAnUnlistedExtensionIsTextPlain() throws {
        let root = try tree(["Makefile": Data("all:\n".utf8)])
        XCTAssertEqual(try T3ProjectFiles.read(root: root.path, path: "Makefile").get().mime, "text/plain")
        XCTAssertEqual(T3ProjectFiles.mime(for: "a/b.swift"), "text/x-swift")
        XCTAssertEqual(T3ProjectFiles.mime(for: "package.json"), "application/json")
    }

    /// The cap lands mid-scalar: the incomplete `é` goes rather than
    /// decoding to a replacement character the phone would render.
    func testTheCapCutsOnAUTF8BoundaryAndReportsTheWholeByteLength() throws {
        let cap = T3ProjectFiles.readCap
        var bytes = Data(repeating: UInt8(ascii: "a"), count: cap - 1)
        bytes.append(contentsOf: Array("é".utf8))
        let root = try tree(["big.txt": bytes])
        let read = try T3ProjectFiles.read(root: root.path, path: "big.txt").get()
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.byteLength, cap + 1)
        XCTAssertEqual(read.contents.count, cap - 1)
        XCTAssertFalse(read.contents.contains("\u{FFFD}"))
        XCTAssertEqual(read.contents.last, "a")
    }

    /// The other side of the same branch: a scalar that ends exactly on the
    /// cap stays whole.
    func testAScalarEndingOnTheCapIsKept() throws {
        let cap = T3ProjectFiles.readCap
        let bytes = Data(String(repeating: "é", count: cap / 2 + 1).utf8)
        let root = try tree(["big.txt": bytes])
        let read = try T3ProjectFiles.read(root: root.path, path: "big.txt").get()
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.byteLength, cap + 2)
        XCTAssertEqual(read.contents.count, cap / 2)
        XCTAssertFalse(read.contents.contains("\u{FFFD}"))
    }

    func testANulByteInTheHeadIsBinary() throws {
        let root = try tree(["blob.dat": Data([0x68, 0x00, 0x69])])
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "blob.dat").failure, .binary)
    }

    func testAnImageExtensionIsBinaryWhateverItHolds() throws {
        let root = try tree(["logo.png": Data("not really a png".utf8)])
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "logo.png").failure, .binary)
    }

    func testAPathLeavingTheWorkspaceIsRefused() throws {
        let root = try tree(["a.txt": Data("x".utf8)])
        for path in ["", "/etc/hosts", "../a.txt", "sub/../../a.txt", ".."] {
            XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: path).failure, .outsideRoot, path)
        }
    }

    func testASymlinkOutOfTheWorkspaceIsRefused() throws {
        let outside = try tree(["secret.txt": Data("s".utf8)])
        let root = try tree(["a.txt": Data("x".utf8)])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                                  withDestinationURL: outside.appendingPathComponent("secret.txt"))
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "link.txt").failure, .outsideRoot)
        // A symlink that stays inside is served, so the check is a boundary
        // and not a blanket refusal of symlinks.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside.txt"),
                                                  withDestinationURL: root.appendingPathComponent("a.txt"))
        XCTAssertEqual(try T3ProjectFiles.read(root: root.path, path: "inside.txt").get().contents, "x")
    }

    func testAMissingFileADanglingSymlinkAndADirectoryAreNotFound() throws {
        let root = try tree(["Sources/a.swift": Data("x".utf8)])
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "gone.txt").failure, .notFound)
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "Sources").failure, .notFound)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling.txt"),
                                                  withDestinationURL: root.appendingPathComponent("gone.txt"))
        XCTAssertEqual(T3ProjectFiles.read(root: root.path, path: "dangling.txt").failure, .notFound)
    }

    // MARK: - the wire

    func testTheRoutesAndTheJSONFieldNamesAreWhatThePhoneAsksFor() throws {
        XCTAssertEqual(T3ProjectFiles.filesPath(pid: 7), "/sessions/7/files")
        XCTAssertEqual(T3ProjectFiles.filePath(pid: 7), "/sessions/7/file")
        XCTAssertEqual(T3ProjectFiles.pathQueryName, "path")
        let listing = T3ProjectFiles.Listing(cwd: "/p", entries: [
            T3ProjectFiles.Entry(path: "Sources/App/Main.swift", kind: .file, size: 2048),
            T3ProjectFiles.Entry(path: "Sources/App", kind: .directory),
        ], truncated: false)
        let listed = String(decoding: try JSONEncoder().encode(listing), as: UTF8.self)
        XCTAssertTrue(listed.contains(#""cwd""#), listed)
        XCTAssertTrue(listed.contains(#""kind":"file""#), listed)
        XCTAssertTrue(listed.contains(#""size":2048"#), listed)
        XCTAssertTrue(listed.contains(#""truncated":false"#), listed)
        // A directory carries no size at all, as the spec's example shows.
        XCTAssertEqual(listed.components(separatedBy: #""size""#).count - 1, 1)
        XCTAssertEqual(try JSONDecoder().decode(T3ProjectFiles.Listing.self,
                                                from: JSONEncoder().encode(listing)), listing)
        let read = T3ProjectFiles.FileRead(path: "a.swift", contents: "import Foundation",
                                           byteLength: 17, truncated: false, mime: "text/x-swift")
        let readJSON = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        for key in [#""path""#, #""contents""#, #""byteLength""#, #""truncated""#, #""mime""#] {
            XCTAssertTrue(readJSON.contains(key), readJSON)
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(T3ProjectFiles.Failure(error: "cwd gone")),
                              as: UTF8.self), #"{"error":"cwd gone"}"#)
    }

    func testEveryRefusalCarriesTheStatusAndMessageTheRouteAnswers() {
        XCTAssertEqual(T3ProjectFiles.ListError.rootGone.status, 404)
        XCTAssertEqual(T3ProjectFiles.ListError.rootGone.message, "cwd gone")
        XCTAssertEqual(T3ProjectFiles.ListError.failed("boom").status, 500)
        XCTAssertEqual(T3ProjectFiles.ListError.failed("boom").message, "boom")
        XCTAssertEqual(T3ProjectFiles.ReadError.outsideRoot.status, 400)
        XCTAssertEqual(T3ProjectFiles.ReadError.outsideRoot.message, "path outside workspace")
        XCTAssertEqual(T3ProjectFiles.ReadError.notFound.status, 404)
        XCTAssertEqual(T3ProjectFiles.ReadError.notFound.message, "no such file")
        XCTAssertEqual(T3ProjectFiles.ReadError.binary.status, 415)
        XCTAssertEqual(T3ProjectFiles.ReadError.binary.message, "binary file")
        XCTAssertEqual(T3ProjectFiles.ReadError.failed("io").status, 500)
    }
}

private extension Result {
    /// The failure of a `Result`, for the refusal assertions.
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
