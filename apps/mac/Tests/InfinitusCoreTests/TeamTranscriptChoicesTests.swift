import XCTest
@testable import InfinitusCore

final class TeamTranscriptChoicesTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamchoices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testTheDefaultIsEverySessionAndChosenIsExactlyWhatWasPicked() {
        var c = TeamTranscriptChoices()
        XCTAssertEqual(c.mode, .all)
        XCTAssertTrue(c.includes("anything"))
        c.mode = .chosen
        XCTAssertFalse(c.includes("s1"))
        c.chosen.insert("s1")
        XCTAssertTrue(c.includes("s1"))
        XCTAssertFalse(c.includes("s2"))
    }

    func testRoundTripsOnDisk() throws {
        let teamDir = scratch.appendingPathComponent("team-1")
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), TeamTranscriptChoices())
        var c = TeamTranscriptChoices()
        c.mode = .chosen
        c.chosen = ["s1", "s2"]
        try c.save(teamDir: teamDir)
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), c)
        XCTAssertEqual(TeamTranscriptChoices.file(teamDir: teamDir).lastPathComponent, "transcript-choices.json")
        // Garbage on disk falls back to the default rather than throwing.
        try Data("not json".utf8).write(to: TeamTranscriptChoices.file(teamDir: teamDir))
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), TeamTranscriptChoices())
    }
}
