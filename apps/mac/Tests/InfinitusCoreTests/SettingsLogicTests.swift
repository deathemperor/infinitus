import XCTest
@testable import InfinitusCore

final class SettingDraftTests: XCTestCase {
    private func entry(
        kind: String, lo: Double? = nil, hi: Double? = nil, choices: [String]? = nil
    ) -> SettingEntry {
        SettingEntry(
            key: "autoswitch.x", value: .null, isSet: false, kind: kind,
            help: "", defaultValue: .null, lo: lo, hi: hi, choices: choices)
    }

    func testFloatWithinBoundsPasses() {
        XCTAssertEqual(
            SettingDraft.validate("97.5", for: entry(kind: "float", lo: 50, hi: 99.9)),
            .valid("97.5"))
    }

    func testFloatOutsideBoundsNamesTheRange() {
        guard case .invalid(let why) = SettingDraft.validate(
            "120", for: entry(kind: "float", lo: 50, hi: 99.9)) else { return XCTFail() }
        XCTAssertTrue(why.contains("50"))
        XCTAssertTrue(why.contains("99.9"))
    }

    func testIntRejectsFractions() {
        guard case .invalid = SettingDraft.validate(
            "2.5", for: entry(kind: "int", lo: 1, hi: 100)) else { return XCTFail() }
    }

    func testBoolAcceptsTrueFalseOnly() {
        XCTAssertEqual(SettingDraft.validate("true", for: entry(kind: "bool")), .valid("true"))
        guard case .invalid = SettingDraft.validate("yes", for: entry(kind: "bool")) else {
            return XCTFail()
        }
    }

    func testChoiceMustBeListed() {
        let e = entry(kind: "choice", choices: ["best", "consume-first"])
        XCTAssertEqual(SettingDraft.validate("best", for: e), .valid("best"))
        guard case .invalid = SettingDraft.validate("worst", for: e) else { return XCTFail() }
    }

    func testEmptyStringMeansUnset() {
        XCTAssertEqual(SettingDraft.validate("", for: entry(kind: "string")), .unset)
        XCTAssertEqual(SettingDraft.validate("  ", for: entry(kind: "float", lo: 0, hi: 9)), .unset)
    }
}

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
