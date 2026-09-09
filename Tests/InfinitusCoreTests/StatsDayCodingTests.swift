import XCTest
@testable import InfinitusCore

/// `Stats.Day`'s hand-written encoder (#499): defaults left out, sparse
/// hours, and nothing lost on the way round.
final class StatsDayCodingTests: XCTestCase {
    private func roundTrip(_ day: Stats.Day) throws -> Stats.Day {
        try JSONDecoder().decode(Stats.Day.self, from: JSONEncoder().encode(day))
    }
    private func keys(_ day: Stats.Day) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(day)) as? [String: Any]
        return Set(object?.keys ?? [:].keys)
    }

    func testADefaultDayEncodesToNothing() throws {
        XCTAssertEqual(try keys(Stats.Day()), [])
        XCTAssertEqual(try roundTrip(Stats.Day()), Stats.Day())
    }

    /// Every stored field, set away from its default, survives the round
    /// trip — and every stored field has a coding key: a property added
    /// without one would silently never reach the cache.
    func testEveryFieldSurvivesTheRoundTrip() throws {
        var d = Stats.Day()
        d.humanMessages = 1; d.phoneMessages = 2; d.agentMessages = 3; d.nudges = 4; d.turns = 5
        d.toolCalls = ["Bash": 6]; d.toolErrors = 7; d.questions = 8; d.denials = 9; d.waitingSeconds = 10
        d.subagents = 11; d.compactions = 12; d.retries = 13; d.longestUnattended = 14
        d.inputTokens = 15; d.outputTokens = 16; d.usd = 17; d.cacheReadTokens = 18; d.cacheWriteTokens = 19; d.cacheSavingsUSD = 20
        d.minuteTokens = [21: 22]; d.peakTokensPerMinute = 23; d.peakMinute = 24
        func tally(_ n: Int) -> Stats.ActivityTally { var t = Stats.ActivityTally(); t.stretches = n; return t }
        d.activities = ["a": tally(25)]; d.byModel = ["m": tally(26)]; d.byEngine = ["e": tally(27)]; d.byEffort = ["f": tally(28)]
        d.sessions = ["s"]; d.sessionTally = 29; d.sessionSeconds = 30; d.sessionBuckets = [31, 0, 0, 0]
        d.hours[32] = 33
        d.commits = 34; d.linesAdded = 35; d.linesRemoved = 36; d.filesTouched = 37; d.coAuthoredByClaude = 38; d.reverts = 39
        d.repos = ["r"]; d.repoTally = 40; d.prsOpened = 41; d.prsMerged = 42; d.mergeHoursTotal = 43; d.mergeCount = 44
        d.switches = 45; d.limitStops = 46; d.revivals = 47; d.ignites = 48; d.resumes = 49; d.minutesLostToLimits = 50
        let back = try roundTrip(d)
        XCTAssertEqual(back, d)
        let stored = Mirror(reflecting: d).children.compactMap(\.label)
        for name in stored where name != "hours" {
            XCTAssertTrue(try keys(d).contains(name), "\(name) is encoded")
        }
        let coded = Set(Stats.Day.CodingKeys.allCases.map(\.stringValue))
        XCTAssertEqual(coded, Set(stored + ["hourSlots"]), "every stored property has a coding key")
        // A field left at its default in a mostly-filled day is still left out.
        var partial = d
        partial.usd = 0
        XCTAssertFalse(try keys(partial).contains("usd"))
    }

    func testHoursTravelSparseWhenFewAreSetAndDenseOtherwise() throws {
        var few = Stats.Day()
        few.hours[3] = 2; few.hours[100] = 1
        XCTAssertEqual(try keys(few), ["hourSlots"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(few)) as? [String: Any]
        XCTAssertEqual(object?["hourSlots"] as? [Int], [3, 2, 100, 1], "slot, count pairs in slot order")
        XCTAssertEqual(try roundTrip(few), few)

        var many = Stats.Day()
        for i in 0..<25 { many.hours[i] = 1 }
        XCTAssertEqual(try keys(many), ["hours"])
        XCTAssertEqual(try roundTrip(many), many)

        var emptied = Stats.Day()
        emptied.hours = []
        XCTAssertEqual(try keys(emptied), ["hours"], "compacted() empties it; the emptiness is kept")
        XCTAssertEqual(try roundTrip(emptied).hours, [])
    }

    func testLegacyDenseHoursStillDecode() throws {
        var dense = Array(repeating: 0, count: 168)
        dense[5] = 4
        let json = try JSONSerialization.data(withJSONObject: ["hours": dense, "turns": 2])
        let day = try JSONDecoder().decode(Stats.Day.self, from: json)
        XCTAssertEqual(day.hours[5], 4)
        XCTAssertEqual(day.turns, 2)
        // A slot outside the histogram is ignored, not a crash.
        let odd = try JSONSerialization.data(withJSONObject: ["hourSlots": [400, 1, 7, 3]])
        XCTAssertEqual(try JSONDecoder().decode(Stats.Day.self, from: odd).hours[7], 3)
    }
}
