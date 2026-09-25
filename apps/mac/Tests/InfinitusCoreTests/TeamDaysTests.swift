import XCTest
@testable import InfinitusCore

final class TeamDaysTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamdays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A `TeamDays` over the fixture scan (s1 in /r/app: 15 input tokens
    /// with its sub-agent, s2 in /r/secret: 10), counting how often the
    /// table is read, folded and asked for.
    func make(entries: [String: StatsScanner.FileEntry]?, generation: Int = 1)
        -> (days: TeamDays, paths: TeamPaths, reads: () -> Int, consumed: () -> [Int], requested: () -> Int) {
        let paths = TeamPaths(base: scratch.appendingPathComponent("team"))
        let days = TeamDays(paths: paths)
        var reads = 0, consumed: [Int] = [], requested = 0
        days.ownsScan = { true }
        days.scanEntries = { reads += 1; return entries }
        days.scanGeneration = { generation }
        days.scanConsumed = { consumed.append($0) }
        days.scanRequested = { requested += 1 }
        return (days, paths, { reads }, { consumed }, { requested })
    }

    func scan() throws -> [String: StatsScanner.FileEntry] {
        let projects = try TeamFixture.write(into: scratch)
        return StatsScanner.scan(projectsDir: projects, cacheURL: nil, calendar: .current, maxAge: 10_000 * 86_400).entries
    }

    /// The fixture's day is 2026-09-04; this is that week.
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    func testFoldDropsAnExcludedProjectAndCompactsTheDays() throws {
        let t = try make(entries: scan())
        try TeamExclusions(projects: ["/r/secret"]).save(paths: t.paths)
        let reply = t.days.reply(days: 30, now: now)
        XCTAssertEqual(reply.generation, 1)
        XCTAssertEqual(reply.exclusions, ["/r/secret"])
        XCTAssertEqual(reply.days["2026-09-04"]?.inputTokens, 15, "the secret project's 10 stay home")
        XCTAssertEqual(reply.days["2026-09-04"]?.minuteTokens, [:], "compacted")
        XCTAssertEqual(t.consumed(), [1], "the table went back once folded")
        XCTAssertFalse(t.days.scanWanted)
    }

    func testTheSecondCallAnswersFromTheMemoAndAChangedExclusionRefolds() throws {
        let t = try make(entries: scan())
        let at = now
        XCTAssertEqual(t.days.reply(days: 30, now: at).days["2026-09-04"]?.inputTokens, 25)
        XCTAssertEqual(t.days.reply(days: 30, now: at).days["2026-09-04"]?.inputTokens, 25)
        XCTAssertEqual(t.reads(), 1, "the memo answered the second call")
        try TeamExclusions(projects: ["/r/app"]).save(paths: t.paths)
        XCTAssertEqual(t.days.reply(days: 30, now: at).days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(t.reads(), 2, "a changed exclusion refolds")
        XCTAssertEqual(t.days.reply(days: 30, now: at.addingTimeInterval(60 * 86_400)).days, [:], "a day outside the window falls off")
    }

    func testNoTableAsksForAScanAndAnswersEmpty() throws {
        let t = make(entries: nil, generation: 0)
        try TeamExclusions(projects: ["/r/secret"]).save(paths: t.paths)
        let reply = t.days.reply(days: 30, now: now)
        XCTAssertEqual(reply, TeamDays.Reply(days: [:], exclusions: ["/r/secret"], generation: 0))
        XCTAssertEqual(t.requested(), 1)
        XCTAssertTrue(t.days.scanWanted)
        XCTAssertEqual(t.consumed(), [])
    }
}
