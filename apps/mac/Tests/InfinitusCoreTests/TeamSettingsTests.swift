import XCTest
@testable import InfinitusCore

final class TeamSettingsTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamsettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testExclusionsMatchCwdBelowAndSlug() {
        var ex = TeamExclusions(projects: ["/r/secret/"])
        XCTAssertEqual(ex.projects, ["/r/secret"])
        XCTAssertTrue(ex.excludes(cwd: "/r/secret", projectDir: nil))
        XCTAssertTrue(ex.excludes(cwd: "/r/secret/sub", projectDir: nil))
        XCTAssertFalse(ex.excludes(cwd: "/r/secretive", projectDir: nil))
        XCTAssertFalse(ex.excludes(cwd: "/r/app", projectDir: nil))
        XCTAssertTrue(ex.excludes(cwd: nil, projectDir: "-r-secret"))
        XCTAssertFalse(ex.excludes(cwd: nil, projectDir: "-r-app"))
        XCTAssertFalse(ex.excludes(cwd: nil, projectDir: nil))
        XCTAssertEqual(TeamExclusions.slug("/Users/loc/death/limitless"), "-Users-loc-death-limitless")
        ex.set("/r/app", excluded: true)
        ex.set("/r/app", excluded: true)
        XCTAssertEqual(ex.projects, ["/r/secret", "/r/app"])
        ex.set("/r/secret", excluded: false)
        XCTAssertEqual(ex.projects, ["/r/app"])
        XCTAssertFalse(TeamExclusions().excludes(cwd: "/r/app", projectDir: "-r-app"))
        ex.set("", excluded: true)
        XCTAssertEqual(ex.projects, ["/r/app"])
        XCTAssertFalse(ex.excludes(cwd: "/anything", projectDir: nil))
    }

    func testExclusionsRoundTripOnDisk() throws {
        let paths = TeamPaths(base: scratch)
        XCTAssertEqual(TeamExclusions.load(paths: paths), TeamExclusions())
        var ex = TeamExclusions()
        ex.set("/r/secret", excluded: true)
        try ex.save(paths: paths)
        XCTAssertEqual(TeamExclusions.load(paths: paths), ex)
        XCTAssertEqual(TeamExclusions.file(paths: paths).lastPathComponent, "exclusions.json")

        try Data("{\"projects\":[\"/r/secret/\"]}".utf8).write(to: TeamExclusions.file(paths: paths))
        let decoded = TeamExclusions.load(paths: paths)
        XCTAssertEqual(decoded.projects, ["/r/secret"])
        XCTAssertTrue(decoded.excludes(cwd: "/r/secret/sub", projectDir: nil))
    }

    func testSharesDefaultToLeadersAndRoundTrip() throws {
        let teamDir = scratch.appendingPathComponent("team-1")
        var shares = TeamShares.load(teamDir: teamDir)
        XCTAssertEqual(shares.target(for: "stats"), .leaders)
        shares.byKind["stats"] = .team
        shares.byKind["sessions"] = .members(["k1", "k2"])
        try shares.save(teamDir: teamDir)
        let back = TeamShares.load(teamDir: teamDir)
        XCTAssertEqual(back, shares)
        XCTAssertEqual(back.target(for: "sessions"), .members(["k1", "k2"]))
        XCTAssertEqual(back.target(for: "transcripts"), .leaders)
    }

    func testParseTarget() {
        XCTAssertEqual(TeamShares.parseTarget(["leaders"]), .leaders)
        XCTAssertEqual(TeamShares.parseTarget(["team"]), .team)
        XCTAssertEqual(TeamShares.parseTarget(["k1,k2", "k3"]), .members(["k1", "k2", "k3"]))
        XCTAssertNil(TeamShares.parseTarget([]))
        XCTAssertNil(TeamShares.parseTarget([""]))
    }
}
