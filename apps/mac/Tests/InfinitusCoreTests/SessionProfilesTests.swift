import XCTest
@testable import InfinitusCore

/// Session profiles (#165): the saved list's file round-trip and edits.
final class SessionProfilesTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-profiles-\(UUID().uuidString)/session-profiles.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testMissingFileIsEmptyAndSaveRoundTrips() throws {
        XCTAssertEqual(SessionProfiles.load(from: url), [])
        let review = SessionProfile(name: "Review", cwd: "/Users/x/repo", permissionMode: "acceptEdits",
                                    model: "opus", systemPrompt: "Review only.", prompt: "Review the diff")
        try SessionProfiles.save([review], to: url)
        XCTAssertEqual(SessionProfiles.load(from: url), [review])
    }

    func testUpsertReplacesByNameCaseInsensitivelyAndClearsBlanks() {
        let a = SessionProfile(name: "Review", cwd: "/a", model: "opus")
        let b = SessionProfile(name: "Ship", engine: "codex")
        var list = SessionProfiles.upsert(b, into: SessionProfiles.upsert(a, into: []))
        XCTAssertEqual(list.map(\.name), ["Review", "Ship"])
        list = SessionProfiles.upsert(SessionProfile(name: "review", cwd: "  ", model: "sonnet"), into: list)
        XCTAssertEqual(list.map(\.name), ["review", "Ship"])
        XCTAssertNil(list[0].cwd)
        XCTAssertEqual(list[0].model, "sonnet")
        XCTAssertEqual(SessionProfiles.removing("SHIP", from: list).map(\.name), ["review"])
    }

    func testAllowListParsesCleansAndBecomesRules() {
        XCTAssertEqual(SessionProfiles.parseAllowList(" Edit, Bash  git ,, Edit,Write"), ["Edit", "Bash git", "Write"])
        XCTAssertNil(SessionProfiles.parseAllowList(" , "))
        let p = SessionProfile(name: "R", allowTools: ["Edit", "Bash git", "   "])
        let saved = SessionProfiles.upsert(p, into: [])[0]
        XCTAssertEqual(saved.allowTools, ["Edit", "Bash git"])
        XCTAssertEqual(saved.allowRules, [.init(tool: "Edit"), .init(tool: "Bash", prefix: "git")])
        XCTAssertEqual(saved.summary, "allows 2 tools")
        XCTAssertEqual(SessionProfile(name: "R", allowTools: ["Edit"]).summary, "allows Edit")
        XCTAssertEqual(ToolApproval.Rule.parse("Bash git")?.text, "Bash git")
        XCTAssertEqual(ToolApproval.Rule.parse("Edit anything")?.prefix, nil)
        XCTAssertNil(ToolApproval.Rule.parse(""))
    }

    func testSummaryNamesWhatIsSet() {
        XCTAssertEqual(SessionProfile(name: "Plain").summary, "nothing set — starts like a plain session")
        XCTAssertEqual(SessionProfile(name: "R", cwd: "/Users/x/repo", engine: "codex", permissionMode: "acceptEdits",
                                      model: "opus", systemPrompt: "x").summary,
                       "repo · codex · Auto-accept edits · opus · system prompt")
    }

    func testOlderSnapshotWithoutProfilesDecodes() throws {
        let json = #"{"capturedAt":"2026-09-06T00:00:00Z","machineName":"m","listJSON":"e30=","sessions":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(MirrorSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.profiles)
    }
}
