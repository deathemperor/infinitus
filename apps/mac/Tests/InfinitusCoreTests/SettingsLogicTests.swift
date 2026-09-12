import XCTest
@testable import InfinitusCore

final class ClaudeCodeConfigTests: XCTestCase {
    private var dir: URL!
    private var userFile: URL!
    private var managedFile: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        userFile = dir.appendingPathComponent("settings.json")
        managedFile = dir.appendingPathComponent("managed-settings.json")
    }

    private func config() -> ClaudeCodeConfig {
        ClaudeCodeConfig(userSettingsURL: userFile, managedSettingsURL: managedFile)
    }

    func testUnsetKeysReadAsNil() throws {
        try #"{"other": 1}"#.write(to: userFile, atomically: true, encoding: .utf8)
        XCTAssertNil(try config().effectiveValue("crossSessionInbound"))
    }

    func testUserValueReads() throws {
        try #"{"crossSessionInbound": "accept"}"#
            .write(to: userFile, atomically: true, encoding: .utf8)
        let v = try config().effectiveValue("crossSessionInbound")
        XCTAssertEqual(v?.value, .string("accept"))
        XCTAssertEqual(v?.source, .user)
    }

    func testManagedOverridesUserAndSaysSo() throws {
        try #"{"crossSessionInbound": "accept"}"#
            .write(to: userFile, atomically: true, encoding: .utf8)
        try #"{"crossSessionInbound": "hold"}"#
            .write(to: managedFile, atomically: true, encoding: .utf8)
        let v = try config().effectiveValue("crossSessionInbound")
        XCTAssertEqual(v?.value, .string("hold"))
        XCTAssertEqual(v?.source, .managed)
    }

    func testWritePreservesUnrelatedKeysAndBacksUp() throws {
        try #"{"keep": true, "statusLine": {"type": "command"}}"#
            .write(to: userFile, atomically: true, encoding: .utf8)
        try config().writeUserValue("autoContinueAtUsageLimit", .bool(true))
        let after = try JSONSerialization.jsonObject(
            with: Data(contentsOf: userFile)) as! [String: Any]
        XCTAssertEqual(after["keep"] as? Bool, true)
        XCTAssertNotNil(after["statusLine"])
        XCTAssertEqual(after["autoContinueAtUsageLimit"] as? Bool, true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("settings.json.bak") }
        XCTAssertEqual(backups.count, 1)
    }

    func testWriteIntoAMissingFileCreatesIt() throws {
        try config().writeUserValue("autoContinueAtUsageLimit", .bool(true))
        let after = try JSONSerialization.jsonObject(
            with: Data(contentsOf: userFile)) as! [String: Any]
        XCTAssertEqual(after["autoContinueAtUsageLimit"] as? Bool, true)
    }
}
