import XCTest
@testable import InfinitusCore

final class SlashCommandsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ body: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDiscoversCommandsAndSkillsWithNamespacesAndDescriptions() throws {
        try write("home/.claude/commands/review.md", "---\ndescription: Review the diff\n---\nDo a review.")
        try write("home/.claude/commands/frontend/design.md", "Design something.\n\nMore.")
        try write("proj/.claude/commands/ship.md", "---\ndescription: Ship it\nargument-hint: <pr>\n---\n")
        try write("home/.claude/skills/writing-plans/SKILL.md", "---\nname: something-else\ndescription: Write a plan\n---\n")
        try write("proj/.claude/skills/deploy/SKILL.md", "Deploy steps.")
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path,
                                           claudeDir: root.appendingPathComponent("home/.claude"))
        XCTAssertEqual(found.map(\.name), ["deploy", "frontend:design", "review", "ship", "writing-plans"])
        XCTAssertEqual(found.first { $0.name == "review" }?.description, "Review the diff")
        XCTAssertEqual(found.first { $0.name == "frontend:design" }?.description, "Design something.")
        XCTAssertEqual(found.first { $0.name == "ship" }?.source, .projectCommand)
        XCTAssertEqual(found.first { $0.name == "writing-plans" }?.source, .userSkill)
        XCTAssertEqual(found.first { $0.name == "deploy" }?.source, .projectSkill)
        XCTAssertEqual(found.first { $0.name == "deploy" }?.description, "Deploy steps.")
        XCTAssertEqual(found.first { $0.name == "ship" }?.insertion, "/ship ")
    }

    func testProjectCommandShadowsUserCommandOfTheSameName() throws {
        try write("home/.claude/commands/review.md", "---\ndescription: user\n---\n")
        try write("proj/.claude/commands/review.md", "---\ndescription: project\n---\n")
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path, claudeDir: root.appendingPathComponent("home/.claude"))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].source, .projectCommand)
    }

    func testMissingDirectoriesYieldNothing() {
        XCTAssertEqual(SlashCommands.discover(cwd: root.appendingPathComponent("nope").path, claudeDir: root.appendingPathComponent("nohome/.claude")), [])
    }

    func testCrlfFrontmatterTrimsCarriageReturns() throws {
        try write("proj/.claude/commands/crlf.md", "---\r\ndescription: Crlf one\r\n---\r\nBody.\r\n")
        try write("proj/.claude/commands/crlf-nofm.md", "First line.\r\nSecond.\r\n")
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path,
                                           claudeDir: root.appendingPathComponent("home/.claude"))
        XCTAssertEqual(found.first { $0.name == "crlf" }?.description, "Crlf one")
        XCTAssertEqual(found.first { $0.name == "crlf-nofm" }?.description, "First line.")
    }

    func testDanglingSymlinkIsNotACommand() throws {
        try write("proj/.claude/commands/keep.md", "---\ndescription: Kept\n---\n")
        let commandsDir = root.appendingPathComponent("proj/.claude/commands")
        try FileManager.default.createSymbolicLink(at: commandsDir.appendingPathComponent("gone.md"),
                                                    withDestinationURL: root.appendingPathComponent("nowhere.md"))
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path,
                                           claudeDir: root.appendingPathComponent("home/.claude"))
        XCTAssertNil(found.first { $0.name == "gone" })
        XCTAssertNotNil(found.first { $0.name == "keep" })
    }

    func testFilterRanksPrefixThenNameSubstringThenDescription() {
        let all = [
            SlashCommand(name: "review", description: "Review the diff", source: .userCommand),
            SlashCommand(name: "preview", description: "Open a preview", source: .userCommand),
            SlashCommand(name: "ship", description: "Create a PR and review it", source: .projectCommand),
            SlashCommand(name: "deploy", description: "Deploy", source: .projectSkill),
        ]
        XCTAssertEqual(SlashCommands.filter(all, query: "").map(\.name), ["review", "preview", "ship", "deploy"])
        XCTAssertEqual(SlashCommands.filter(all, query: "re").map(\.name), ["review", "preview", "ship"])
        XCTAssertEqual(SlashCommands.filter(all, query: "REV").map(\.name), ["review", "preview", "ship"])
        XCTAssertEqual(SlashCommands.filter(all, query: "zzz"), [])
    }
}
