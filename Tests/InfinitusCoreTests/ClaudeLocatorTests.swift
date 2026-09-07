#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// `ClaudeLocator.captureSync` against a script that backgrounds a child
/// holding the inherited stdout (#151 debt: EOF must not wait on it).
final class ClaudeLocatorTests: XCTestCase {
    func testCaptureSyncReturnsAsSoonAsTheScriptExitsEvenWithABackgroundedChildHoldingStdout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-locator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("rc")
        try """
        #!/bin/sh
        echo banner
        sleep 30 &
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let start = Date()
        let out = ClaudeLocator.captureSync(script.path, [])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out, "banner\n")
        XCTAssertLessThan(elapsed, 5, "must not wait on the backgrounded child's stdout copy")
    }
}
#endif
