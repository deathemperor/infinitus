import XCTest
@testable import InfinitusCore

final class StatsTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        c.firstWeekday = 2
        return c
    }()
    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    func testDayAddsCountsUnionsSetsAndKeepsMaxima() {
        var a = Stats.Day(); a.commits = 2; a.humanMessages = 3; a.toolCalls = ["Bash": 4]
        a.sessions = ["s1"]; a.repos = ["r1"]; a.longestUnattended = 5; a.hours[3] = 1
        var b = Stats.Day(); b.commits = 1; b.toolCalls = ["Bash": 1, "Edit": 2]
        b.sessions = ["s1", "s2"]; b.longestUnattended = 9; b.hours[3] = 2
        let c = a + b
        XCTAssertEqual(c.commits, 3)
        XCTAssertEqual(c.humanMessages, 3)
        XCTAssertEqual(c.toolCalls, ["Bash": 5, "Edit": 2])
        XCTAssertEqual(c.sessions, ["s1", "s2"])
        XCTAssertEqual(c.repos, ["r1"])
        XCTAssertEqual(c.longestUnattended, 9)
        XCTAssertEqual(c.hours[3], 3)
    }

    func testDayAddsSessionBuckets() {
        var a = Stats.Day(); a.sessionBuckets = [1, 0, 0, 0]
        var b = Stats.Day(); b.sessionBuckets = [0, 1, 1, 0]
        let c = a + b
        XCTAssertEqual(c.sessionBuckets, [1, 1, 1, 0])
    }

    func testSessionBucketBoundaries() {
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 899), 0)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 900), 1)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 3599), 1)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 3600), 2)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 14399), 2)
        XCTAssertEqual(Stats.Day.sessionBucket(seconds: 14400), 3)
    }

    func testDerivedRatiosAreNilOnZero() {
        var d = Stats.Day()
        XCTAssertNil(d.messagesPerCommit)
        XCTAssertNil(d.usdPerCommit)
        XCTAssertNil(d.toolCallsPerHumanMessage)
        XCTAssertNil(d.meanMergeHours)
        d.commits = 2; d.humanMessages = 4; d.phoneMessages = 2; d.usd = 10
        d.toolCalls = ["Bash": 30]; d.mergeHoursTotal = 5; d.mergeCount = 2
        XCTAssertEqual(d.messagesPerCommit, 3)
        XCTAssertEqual(d.usdPerCommit, 5)
        XCTAssertEqual(d.toolCallsPerHumanMessage, 5)
        XCTAssertEqual(d.meanMergeHours, 2.5)
        XCTAssertEqual(d.totalToolCalls, 30)
        XCTAssertEqual(d.messages, 6)
    }

    func testDayKeyAndHourSlotUseTheCalendar() {
        let t = date("2026-09-03T17:30:00Z")   // 00:30 Sep 4 in Ho Chi Minh, a Friday
        XCTAssertEqual(Stats.dayKey(t, calendar: cal), "2026-09-04")
        XCTAssertEqual(Stats.hourSlot(t, calendar: cal), 4 * 24 + 0)   // Mon=0 … Fri=4
        XCTAssertEqual(Stats.date(fromDayKey: "2026-09-04", calendar: cal), date("2026-09-03T17:00:00Z"))
        // A Buddhist-calendar Mac keys the same day the same way (#409).
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = cal.timeZone
        XCTAssertEqual(Stats.dayKey(t, calendar: buddhist), "2026-09-04")
        XCTAssertEqual(Stats.date(fromDayKey: "2026-09-04", calendar: buddhist), date("2026-09-03T17:00:00Z"))
    }

    func testFoldWeekSumsCurrentWeekAndPreviousAndStreak() {
        func day(_ commits: Int, _ msgs: Int) -> Stats.Day {
            var d = Stats.Day(); d.commits = commits; d.humanMessages = msgs; return d
        }
        let days: [String: Stats.Day] = [
            "2026-08-26": day(4, 1),   // previous week (Wed)
            "2026-08-31": day(1, 0),   // Mon, this week
            "2026-09-02": day(2, 3),
            "2026-09-03": day(0, 1),
            "2026-09-04": day(3, 0),   // today (Fri)
        ]
        let now = date("2026-09-04T03:00:00Z")   // 10:00 local Fri Sep 4
        let s = Stats.fold(days: days, period: .week, now: now, calendar: cal)
        XCTAssertEqual(s.period, .week)
        XCTAssertEqual(s.total.commits, 6)
        XCTAssertEqual(s.previous.commits, 4)
        XCTAssertEqual(s.from, "2026-08-31")
        XCTAssertEqual(s.to, "2026-09-06")
        XCTAssertEqual(s.daily.count, 7)                     // every day of the week, empty ones included
        XCTAssertEqual(s.daily.map(\.key).first, "2026-08-31")
        XCTAssertEqual(s.streak, 3)                          // Sep 2, 3, 4 each had a commit or a message
    }

    func testFoldDayMonthYearRanges() {
        let now = date("2026-09-04T03:00:00Z")
        XCTAssertEqual(Stats.fold(days: [:], period: .day, now: now, calendar: cal).from, "2026-09-04")
        XCTAssertEqual(Stats.fold(days: [:], period: .month, now: now, calendar: cal).from, "2026-09-01")
        XCTAssertEqual(Stats.fold(days: [:], period: .month, now: now, calendar: cal).to, "2026-09-30")
        XCTAssertEqual(Stats.fold(days: [:], period: .year, now: now, calendar: cal).from, "2026-01-01")
        XCTAssertEqual(Stats.fold(days: [:], period: .year, now: now, calendar: cal).previous, Stats.Day())
    }

    func testBundleDropsDailySeries() {
        var d = Stats.Day(); d.commits = 1
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(b.periods.count, 4)
        XCTAssertTrue(b.periods.allSatisfy { $0.daily.isEmpty })
        XCTAssertEqual(b.periods.first { $0.period == .day }?.total.commits, 1)
        let data = try! JSONEncoder().encode(b)
        XCTAssertLessThan(data.count, 12_000)
    }

    func testBundleCompactsSessionAndRepoSetsIntoTallies() {
        var d = Stats.Day(); d.sessions = ["s1", "s2", "s3"]; d.repos = ["r1"]
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let day = b.summary(.day)!
        XCTAssertTrue(day.total.sessions.isEmpty)
        XCTAssertEqual(day.total.sessionCount, 3)
        XCTAssertTrue(day.total.repos.isEmpty)
        XCTAssertEqual(day.total.repoCount, 1)
        let data = try! JSONEncoder().encode(b)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("s1"))
        XCTAssertFalse(json.contains("s2"))
        XCTAssertFalse(json.contains("s3"))
    }

    func testPresentationGroupsFormatTilesDeltasAndSeries() {
        var total = Stats.Day(); total.commits = 10
        var previous = Stats.Day(); previous.commits = 5
        let s = Stats.Summary(period: .week, from: "2026-09-01", to: "2026-09-07",
                              total: total, previous: previous, daily: [], streak: 0)
        let groups = Stats.Presentation.groups(s)
        let throughput = groups.first { $0.id == "Throughput" }!
        let commits = throughput.tiles.first { $0.id == "Commits" }!
        XCTAssertEqual(commits.value, "10")
        XCTAssertEqual(commits.delta, "+100%")
        XCTAssertTrue(commits.series.isEmpty)   // daily empty (the mirrored bundle's shape)

        let autonomy = groups.first { $0.id == "Autonomy" }!
        let ratioTile = autonomy.tiles.first { $0.id == "Tool calls / message" }!
        XCTAssertEqual(ratioTile.value, "—")   // messages == 0, zero-denominator ratio
        XCTAssertNil(ratioTile.delta)
    }

    func testFoldMonthPreviousIsTheCalendarMonth() {
        func day(_ commits: Int) -> Stats.Day {
            var d = Stats.Day(); d.commits = commits; return d
        }
        let days: [String: Stats.Day] = [
            "2026-01-31": day(5),   // Jan 31, should be excluded from Feb's previous
            "2026-02-01": day(1),   // Feb 1, should be in Feb's previous
        ]
        let now = date("2026-03-04T03:00:00Z")   // 10:00 local Mar 4
        let s = Stats.fold(days: days, period: .month, now: now, calendar: cal)
        XCTAssertEqual(s.period, .month)
        XCTAssertEqual(s.from, "2026-03-01")
        XCTAssertEqual(s.previous.commits, 1)  // Only Feb 1, not Jan 31
    }

    func entry(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testClassifyUserEntries() {
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"hi"}}"#)), .human)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-123.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-123.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nfix it\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-123.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-123.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\n[Infinitus] Continue where you left off\n</cross-session-message>"}}"#)), .nudge)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/cc-socks/1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nmerge e2\n</cross-session-message>"}}"#)), .agent)
        // No origin (older Claude Code): the wrapper decides.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-9.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nhello\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#)), .compaction)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#)), .toolResult)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"done"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","promptSource":"queued","message":{"role":"user","content":[{"type":"text","text":"also this"}]}}"#)), .human)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"image","source":{}}]}}"#)), .human)
        // Phone messages now carry the socket preface (PeerSocket.phonePreface);
        // sender is "Infinitus app". Bare "[Infinitus] ..." stays a nudge.
        let phoneBody = PeerSocket.phonePreface.replacingOccurrences(of: "\n", with: "\\n") + "fix it"
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\#(phoneBody)</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-9.sock\" from-name=\"Infinitus app\" from-mode=\"bypass\">\nhello\n</cross-session-message>"}}"#)), .phone)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/2.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\n[Infinitus] x\n</cross-session-message>"}}"#)), .agent)
    }

    func testIngestCountsAConversation() {
        var e = StatsScanner.FileEntry()
        let lines = [
            #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"do it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:06.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"streamed twin"},{"type":"tool_use","id":"t1b","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:08.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":5,"output_tokens":5},"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{}},{"type":"tool_use","id":"t3","name":"AskUserQuestion","input":{"questions":[]}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:00:09.000Z","toolDenialKind":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"denied"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:10.000Z","isApiErrorMessage":true,"message":{"id":"m3","model":"<synthetic>","content":[{"type":"text","text":"retry"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:11.000Z","message":{"id":"m4","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"user","isCompactSummary":true,"timestamp":"2026-09-04T01:30:00.000Z","message":{"role":"user","content":"This session is being continued"}}"#,
            #"{"type":"user","timestamp":"2026-09-04T02:00:11.000Z","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nthanks\n</cross-session-message>"}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        let d = e.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 1)
        XCTAssertEqual(d.phoneMessages, 1)
        XCTAssertEqual(d.toolCalls, ["Bash": 2, "Agent": 1, "AskUserQuestion": 1])
        XCTAssertEqual(d.toolErrors, 1)
        XCTAssertEqual(d.subagents, 1)
        XCTAssertEqual(d.questions, 1)
        XCTAssertEqual(d.denials, 1)
        XCTAssertEqual(d.retries, 1)
        XCTAssertEqual(d.compactions, 1)
        XCTAssertEqual(d.turns, 1)                          // "done" is the turn end; the twin of m1 is mid-turn
        XCTAssertEqual(d.inputTokens, 16)                   // m1 counted once (same message id twice)
        XCTAssertEqual(d.outputTokens, 26)
        XCTAssertGreaterThan(d.usd, 0)
        XCTAssertEqual(d.sessions, ["s1"])
        XCTAssertEqual(d.sessionSeconds, 3611, accuracy: 0.5) // 01:00:00 → 02:00:11
        XCTAssertEqual(d.sessionBuckets, [0, 0, 1, 0])        // 3611s falls in the 1-4h bucket
        XCTAssertEqual(d.waitingSeconds, 3600, accuracy: 0.5) // turn end 01:00:11 → phone message 02:00:11
        XCTAssertEqual(d.longestUnattended, 4)              // Bash, Bash, Agent, AskUserQuestion between the two human messages
        XCTAssertEqual(d.hours.reduce(0, +), 10)            // every entry lands in a slot
        XCTAssertEqual(e.cwd, "/r/a")
    }

    func testIngestChargesCacheReadsWritesAndSavings() {
        var e = StatsScanner.FileEntry()
        let line = #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens":10}}}"#
        StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal)
        let d = e.days["2026-09-04"]!
        // claude-sonnet-5: input $2, output $10, cacheRead $0.2, cacheWrite $2.5 per million.
        XCTAssertEqual(d.cacheReadTokens, 900)
        XCTAssertEqual(d.cacheWriteTokens, 50)
        XCTAssertEqual(d.processedTokens, 1060)                          // 100 + 900 + 50 + 10
        XCTAssertEqual(d.uncachedInputTokens, 150)                       // 100 + 50
        // cost = (100*2 + 10*10 + 900*0.2 + 50*2.5) / 1e6 = 0.000605
        XCTAssertEqual(d.usd, 0.000605, accuracy: 1e-9)
        // savings = 900 * (2.0 - 0.2) / 1e6 = 0.00162
        XCTAssertEqual(d.cacheSavingsUSD, 0.00162, accuracy: 1e-9)
        XCTAssertEqual(d.byModel["claude-sonnet-5"]?.cacheReadTokens, 900)
        XCTAssertEqual(d.byModel["claude-sonnet-5"]?.cacheWriteTokens, 50)
        XCTAssertEqual(d.byModel["claude-sonnet-5"]?.cacheSavingsUSD ?? 0, 0.00162, accuracy: 1e-9)
    }

    func testIngestSessionBucketMovesAsTheSpanCrossesFifteenMinutes() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"start"}}"#), sessionID: "s1", into: &e, calendar: cal)
        var d = e.days["2026-09-04"]!
        XCTAssertEqual(d.sessionSeconds, 0)
        XCTAssertEqual(d.sessionBuckets, [1, 0, 0, 0])        // a single entry is a 0s span: <15m
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:20:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"continue"}}"#), sessionID: "s1", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.sessionSeconds, 1200, accuracy: 0.5) // 20 minutes
        XCTAssertEqual(d.sessionBuckets, [0, 1, 0, 0])        // moved to 15-60m, exactly one 1
    }

    func testIngestGatesSessionAndMessageFieldsForSubagentFiles() {
        var e = StatsScanner.FileEntry()
        e.subagent = true
        // (a) the subagent's first "user" entry is its prompt FROM the
        // parent — must never count as a human message, session, or hour.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"do the subtask"}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        var d = e.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 0)
        XCTAssertTrue(d.sessions.isEmpty)
        XCTAssertEqual(d.hours.reduce(0, +), 0)
        XCTAssertEqual(d.sessionSeconds, 0)

        // (b) an assistant usage entry: tokens/usd counted, no turn.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"working"}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.inputTokens, 10)
        XCTAssertEqual(d.outputTokens, 20)
        XCTAssertGreaterThan(d.usd, 0)
        XCTAssertEqual(d.turns, 0)

        // (c) a tool_use block: toolCalls counted, still no turn.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:06.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.toolCalls, ["Bash": 1])
        XCTAssertEqual(d.turns, 0)

        // (d) a tool_result is_error: toolErrors counted.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#), sessionID: "parent-session", into: &e, calendar: cal)
        d = e.days["2026-09-04"]!
        XCTAssertEqual(d.toolErrors, 1)
    }

    func testIngestSplitsStretchesAndChargesModels() {
        var e = StatsScanner.FileEntry()
        let lines = [
            // stretch 1: human → plan skill, one edit, prose end
            #"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"plan it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:10.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10},"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"superpowers:writing-plans"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:20.000Z","message":{"id":"a2","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10},"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/r/Sources/A.swift"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:01:00.000Z","message":{"id":"a3","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10},"content":[{"type":"text","text":"planned"}]}}"#,
            // stretch 2 (phone): only test edits, on Sonnet
            #"{"type":"user","timestamp":"2026-09-04T01:05:00.000Z","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nadd tests\n</cross-session-message>"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:05:30.000Z","message":{"id":"b1","model":"claude-sonnet-5","usage":{"input_tokens":50,"output_tokens":5},"content":[{"type":"tool_use","id":"t3","name":"Write","input":{"file_path":"/r/Tests/ATests.swift"}}]}}"#,
            // stretch 3 (still open): prose only
            #"{"type":"user","timestamp":"2026-09-04T01:10:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"why?"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:10:05.000Z","message":{"id":"c1","model":"claude-opus-5","usage":{"input_tokens":20,"output_tokens":2},"content":[{"type":"text","text":"because"}]}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        let d = e.days["2026-09-04"]!
        XCTAssertEqual(d.activities["plan"]?.stretches, 1)
        XCTAssertEqual(d.activities["plan"]?.seconds ?? 0, 60, accuracy: 0.5)     // 01:00:00 → 01:01:00
        XCTAssertEqual(d.activities["plan"]?.inputTokens, 300)
        XCTAssertEqual(d.activities["tests"]?.stretches, 1)
        XCTAssertEqual(d.activities["tests"]?.inputTokens, 50)
        XCTAssertNil(d.activities["explanation"])                                    // still open → not in the cache form
        XCTAssertEqual(d.byModel["claude-opus-5"]?.inputTokens, 320)                 // per entry, open stretch included
        XCTAssertEqual(d.byModel["claude-opus-5"]?.stretches, 1)                     // closed stretches only
        XCTAssertEqual(d.byModel["claude-sonnet-5"]?.stretches, 1)
        XCTAssertGreaterThan(d.byModel["claude-sonnet-5"]?.usd ?? 0, 0)
        // The provisional view charges the open tail too.
        let open = e.daysWithOpenStretch()["2026-09-04"]!
        XCTAssertEqual(open.activities["explanation"]?.stretches, 1)
        XCTAssertEqual(open.activities["explanation"]?.inputTokens, 20)
        XCTAssertEqual(open.byModel["claude-opus-5"]?.stretches, 2)
        XCTAssertEqual(open.byModel["claude-opus-5"]?.inputTokens, 320)             // not double-charged
        // Everything v1 counted still counts the same.
        XCTAssertEqual(d.humanMessages, 2); XCTAssertEqual(d.phoneMessages, 1); XCTAssertEqual(d.turns, 2)
        XCTAssertEqual(d.inputTokens, 370)
    }

    func testIngestStretchIsChargedToItsOpeningDayAndOpenedByAgentsAndNudges() {
        // The test calendar is Asia/Ho_Chi_Minh (UTC+7): 16:59Z is 23:59 on the 4th, 17:01Z is 00:01 on the 5th.
        var e = StatsScanner.FileEntry()
        let lines = [
            #"{"type":"user","timestamp":"2026-09-04T16:59:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T17:01:00.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            // a nudge from the app closes it and opens the next
            #"{"type":"user","timestamp":"2026-09-04T17:02:00.000Z","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\n[Infinitus] Continue where you left off\n</cross-session-message>"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T17:02:30.000Z","message":{"id":"a2","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"tool_use","id":"t2","name":"mcp__claude-in-chrome__navigate","input":{"url":"x"}}]}}"#,
            // another session's message closes it too
            #"{"type":"user","timestamp":"2026-09-04T17:03:00.000Z","origin":{"kind":"peer","from":"uds:/tmp/cc-socks/1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nmerge e2\n</cross-session-message>"}}"#,
            // …and a second one right behind it: the agent stretch had no assistant entry — not effort
            #"{"type":"user","timestamp":"2026-09-04T17:03:10.000Z","origin":{"kind":"peer","from":"uds:/tmp/cc-socks/1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nand this\n</cross-session-message>"}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        XCTAssertEqual(e.days["2026-09-04"]?.activities["code"]?.stretches, 1)       // opened 23:59 local on the 4th
        XCTAssertEqual(e.days["2026-09-04"]?.activities["code"]?.seconds ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(e.days["2026-09-05"]?.activities["browser"]?.stretches, 1)    // the nudge opened this one
        XCTAssertNotNil(e.state.stretch)                                              // the last agent message opened one
        XCTAssertNil(e.days["2026-09-05"]?.activities["other"])                       // the empty one between them folded nothing
        XCTAssertEqual(e.daysWithOpenStretch(), e.days)                               // and the open empty one adds nothing either
        XCTAssertEqual(e.days["2026-09-05"]?.nudges, 1)                                 // the nudge itself lands on the 5th
        XCTAssertNil(e.days["2026-09-05"]?.activities["code"])
    }

    func testIngestSubagentFilesChargeModelsButNeverStretches() {
        var e = StatsScanner.FileEntry()
        e.subagent = true
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"sub task"}}"#), sessionID: "p", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/r/Tests/X.swift"}}]}}"#), sessionID: "p", into: &e, calendar: cal)
        let d = e.days["2026-09-04"]!
        XCTAssertNil(e.state.stretch)
        XCTAssertTrue(d.activities.isEmpty)
        XCTAssertEqual(d.byModel["claude-haiku-4-5-20251001"]?.inputTokens, 10)
        XCTAssertEqual(d.byModel["claude-haiku-4-5-20251001"]?.stretches, 0)
        XCTAssertEqual(e.daysWithOpenStretch(), e.days)
    }

    func testIngestAnAPIErrorRetryIsNotEffort() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#), sessionID: "s1", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","isApiErrorMessage":true,"message":{"id":"x","model":"<synthetic>","content":[{"type":"text","text":"retry"}]}}"#), sessionID: "s1", into: &e, calendar: cal)
        // The retry alone must not make the open stretch look like effort.
        XCTAssertEqual(e.daysWithOpenStretch()["2026-09-04"]?.activities, [:])
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:00:10.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"again"}}"#), sessionID: "s1", into: &e, calendar: cal)
        // Closed: the retry-only stretch had 0 entries, so it adds nothing.
        XCTAssertEqual(e.days["2026-09-04"]?.activities, [:])
    }

    func testScanResultIncludesTheOpenStretch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stats-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-r-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        try [
            #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"explain"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let cacheURL = root.appendingPathComponent("cache.json")
        let now = date("2026-09-04T02:00:00Z")
        let first = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now)
        XCTAssertEqual(first.days["2026-09-04"]?.activities["explanation"]?.stretches, 1)
        // Served from the cache on the second call: same answer.
        let second = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now)
        XCTAssertEqual(second.days["2026-09-04"]?.activities["explanation"]?.stretches, 1)
        XCTAssertEqual(second.days["2026-09-04"]?.inputTokens, 10)
    }

    /// #499: a held handle sums again only the days a changed file
    /// covers; the answer must match a scan that sums everything.
    func testAHeldHandleResumsOnlyTheChangedDaysAndMatchesAFullScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stats-delta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-r-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func turn(_ stamp: String, _ id: String, out: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":\#(out)},"content":[{"type":"text","text":"a"}]}}"#
        }
        let a = project.appendingPathComponent("s1.jsonl"), b = project.appendingPathComponent("s2.jsonl")
        try [turn("2026-09-03T01:00:05.000Z", "a1", out: 700), turn("2026-09-04T01:00:05.000Z", "a2", out: 300)]
            .joined(separator: "\n").appending("\n").write(to: a, atomically: true, encoding: .utf8)
        try [turn("2026-09-04T01:00:20.000Z", "b1", out: 500)]
            .joined(separator: "\n").appending("\n").write(to: b, atomically: true, encoding: .utf8)
        let now = date("2026-09-05T02:00:00Z")
        let handle = StatsScanner.CacheHandle()
        let cacheURL = root.appendingPathComponent("cache.json")
        let first = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now, handle: handle)
        XCTAssertEqual(first.days["2026-09-04"]?.peakTokensPerMinute, 800)
        XCTAssertEqual(first.days["2026-09-03"]?.outputTokens, 700)

        // Append to one file: only the day it touches is summed again.
        let fh = try FileHandle(forWritingTo: a); try fh.seekToEnd()
        try fh.write(contentsOf: Data((turn("2026-09-04T01:00:40.000Z", "a3", out: 100) + "\n").utf8)); try fh.close()
        let second = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now, handle: handle)
        let full = StatsScanner.scan(projectsDir: root, cacheURL: nil, calendar: cal, now: now)
        XCTAssertEqual(second.days["2026-09-04"]?.peakTokensPerMinute, 900)
        XCTAssertEqual(second.days, full.days)

        // A file gone: its days lose its share.
        try FileManager.default.removeItem(at: b)
        let third = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now, handle: handle)
        XCTAssertEqual(third.days["2026-09-04"]?.peakTokensPerMinute, 400)
        XCTAssertEqual(third.days, StatsScanner.scan(projectsDir: root, cacheURL: nil, calendar: cal, now: now).days)
        // Nothing changed: the sums stand as they are.
        let fourth = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now, handle: handle)
        XCTAssertEqual(fourth.days, third.days)
    }

    func testCacheVersionIsNine() {
        XCTAssertEqual(StatsScanner.Cache().version, 9)
    }

    /// #499: the cache is written one file entry at a time (the whole-tree
    /// encode peaked +127 MB on 11k files). The bytes must be the same
    /// document the synthesized encoder wrote — version and files at the
    /// top, keys quoted and escaped — and decode to an equal cache.
    func testCacheEncodesEntryByEntryToTheSameDocument() throws {
        var cache = StatsScanner.Cache()
        var a = StatsScanner.FileEntry(); a.size = 10; a.offset = 10; a.cwd = "/r/a"
        var day = Stats.Day(); day.outputTokens = 700; day.minuteTokens = [61: 700, 62: 5, 63: 9]; day.hourSlots[3] += 1
        day.toolCalls = ["Bash": 2, "Read": 1, "Edit": 3]
        a.days["2026-09-04"] = day; a.days["2026-09-03"] = day; a.days["2026-09-05"] = day
        var b = StatsScanner.FileEntry(); b.subagent = true; b.engine = Stats.Engine.codex.rawValue
        cache.files["-r-a/s1.jsonl"] = a
        cache.files[#"-r-"quote"\back/s2.jsonl"#] = b
        let data = try StatsScanner.encodeCache(cache)
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(top["version"] as? Int, 9)
        XCTAssertEqual(Set((top["files"] as? [String: Any])?.keys.map { $0 } ?? []), Set(cache.files.keys))
        let back = try JSONDecoder().decode(StatsScanner.Cache.self, from: data)
        XCTAssertEqual(back.files, cache.files)
        XCTAssertEqual(try StatsScanner.encodeCache(cache), data)   // sorted keys: the same bytes twice
        XCTAssertEqual(try StatsScanner.encodeCache(StatsScanner.Cache()), Data(#"{"version":9,"files":{}}"#.utf8))
    }

    /// The minute buckets and the peak survive a cache round trip: the
    /// hand-written Day decoder must read them (it didn't at first, so
    /// every scan showed only the last pass's fresh minutes, 2026-09-05).
    func testMinuteBucketsSurviveTheCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stats-min-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-r-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        try [
            #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":700},"content":[{"type":"text","text":"a"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:03:05.000Z","message":{"id":"a2","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":300},"content":[{"type":"text","text":"b"}]}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let cacheURL = root.appendingPathComponent("cache.json")
        let now = date("2026-09-04T02:00:00Z")
        let first = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now)
        XCTAssertEqual(first.days["2026-09-04"]?.peakTokensPerMinute, 700)
        // Nothing new to read: the answer must come out of the cache whole.
        let second = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now)
        XCTAssertEqual(second.days["2026-09-04"]?.peakTokensPerMinute, 700)
        XCTAssertEqual(second.days["2026-09-04"]?.minuteTokens.count, 2)
        // A later append adds to the day's buckets rather than replacing them.
        let more = #"{"type":"assistant","timestamp":"2026-09-04T01:00:40.000Z","message":{"id":"a3","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100},"content":[{"type":"text","text":"c"}]}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more + "\n").utf8))
        try handle.close()
        let third = StatsScanner.scan(projectsDir: root, cacheURL: cacheURL, calendar: cal, now: now)
        XCTAssertEqual(third.days["2026-09-04"]?.peakTokensPerMinute, 800)
    }

    // MARK: engines and effort (issue #24, round 2)

    func testIngestChargesEngineAndEffortForClaudeEntries() {
        var e = StatsScanner.FileEntry()
        let lines = [
            #"{"type":"user","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","effort":"high","timestamp":"2026-09-04T01:00:10.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10},"content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:01:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"more"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-04T01:01:10.000Z","message":{"id":"a2","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":5},"content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","timestamp":"2026-09-04T01:02:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"bye"}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        let d = e.days["2026-09-04"]!
        XCTAssertEqual(d.byEngine["claude"]?.inputTokens, 150)
        XCTAssertEqual(d.byEngine["claude"]?.stretches, 2)
        XCTAssertEqual(d.byEngine["claude"]?.seconds ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(d.byEffort["high"]?.inputTokens, 100)
        XCTAssertEqual(d.byEffort["high"]?.stretches, 1)
        XCTAssertEqual(d.byEffort["unset"]?.inputTokens, 50)        // no `effort` on the entry
        XCTAssertEqual(d.byEffort["unset"]?.stretches, 1)
        XCTAssertNil(d.byEngine["codex"])
    }

    func testDayMergesEngineAndEffortAndDecodesWithoutThem() throws {
        var a = Stats.Day(), b = Stats.Day()
        a.byEngine["claude"] = Stats.ActivityTally(); a.byEngine["claude"]!.stretches = 1
        b.byEngine["claude"] = Stats.ActivityTally(); b.byEngine["claude"]!.stretches = 2
        b.byEffort["max"] = Stats.ActivityTally(); b.byEffort["max"]!.usd = 1
        let c = a + b
        XCTAssertEqual(c.byEngine["claude"]?.stretches, 3)
        XCTAssertEqual(c.byEffort["max"]?.usd, 1)
        let old = try JSONDecoder().decode(Stats.Day.self, from: Data(#"{"humanMessages":3}"#.utf8))
        XCTAssertEqual(old.byEngine, [:])
        XCTAssertEqual(old.byEffort, [:])
    }

    func testCodexIngestCountsARollout() {
        var e = StatsScanner.FileEntry()
        e.engine = Stats.Engine.codex.rawValue
        let lines = [
            #"{"timestamp":"2026-07-14T06:40:33.027Z","type":"session_meta","payload":{"id":"x","cwd":"/w/app","cli_version":"0.144.1","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-07-14T06:40:35.724Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/w/app","model":"gpt-5.6-sol","effort":"high"}}"#,
            #"{"timestamp":"2026-07-14T06:40:35.732Z","type":"event_msg","payload":{"type":"user_message","message":"<system_instruction>\nYou are working inside Conductor\n</system_instruction>"}}"#,
            #"{"timestamp":"2026-07-14T06:40:36.000Z","type":"event_msg","payload":{"type":"user_message","message":"<system_instruction>\nThe user has attached these files.\n</system_instruction>\n<system_instruction>\nRead them first.\n</system_instruction>\n\nfix the thumbnail crash"}}"#,
            #"{"timestamp":"2026-07-14T06:40:40.457Z","type":"response_item","payload":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"gAAAA"}}"#,
            #"{"timestamp":"2026-07-14T06:40:42.871Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"c1","name":"exec","input":"const r = await tools.exec_command({cmd: \"xcrun simctl boot X && ls\"})"}}"#,
            #"{"timestamp":"2026-07-14T06:40:50.000Z","type":"response_item","payload":{"type":"function_call","id":"fc_1","status":"completed","call_id":"c2","name":"wait","arguments":"{\"session_id\":1}"}}"#,
            #"{"timestamp":"2026-07-14T06:40:54.113Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"ok"}}"#,
            #"{"timestamp":"2026-07-14T06:40:55.000Z","type":"world_state","payload":{"files":{"/w/app/utils/thumb.ts":"..."}}}"#,
            #"{"timestamp":"2026-07-14T06:40:54.127Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":22462,"cached_input_tokens":0,"output_tokens":439,"reasoning_output_tokens":151,"total_tokens":22901},"last_token_usage":{"input_tokens":22462,"cached_input_tokens":12000,"output_tokens":439,"reasoning_output_tokens":151,"total_tokens":22901}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-07-14T06:45:13.953Z","type":"event_msg","payload":{"type":"patch_apply_end","call_id":"e1","turn_id":"t1","success":true,"changes":{"/w/app/utils/thumb.test.ts":{"type":"add"},"/w/app/utils/thumb.ts":{"type":"update"}}}}"#,
            #"{"timestamp":"2026-07-14T06:45:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30000,"cached_input_tokens":0,"output_tokens":600,"total_tokens":30600},"last_token_usage":{"input_tokens":8000,"cached_input_tokens":1000,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":8200}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-07-14T06:50:54.387Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Fixed."}}"#,
            #"{"timestamp":"2026-07-14T08:21:37.800Z","type":"compacted","payload":{"message":"summary","replacement_history":[]}}"#,
            #"{"timestamp":"2026-07-14T08:21:37.835Z","type":"event_msg","payload":{"type":"context_compacted"}}"#,
            #"{"timestamp":"2026-07-14T08:30:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"thanks"}}"#,
        ]
        for line in lines {
            let skipped = ["encrypted_content", "call_output", "\"world_state\"", "\"compacted\""].contains { line.contains($0) }
            XCTAssertEqual(StatsCodex.worthParsing(Data(line.utf8)), !skipped, line)
            if !skipped { StatsCodex.ingest(entry(line), sessionID: "rollout-1", into: &e, calendar: cal) }
        }
        let d = e.days["2026-07-14"]!
        XCTAssertEqual(e.cwd, "/w/app")
        XCTAssertEqual(d.humanMessages, 2)                                   // the Conductor preamble is not a person; the words after it are
        XCTAssertEqual(d.toolCalls, ["exec": 1, "apply_patch": 1])          // `wait` is polling, not a call
        XCTAssertEqual(d.inputTokens, 10462 + 7000)                          // uncached input
        XCTAssertEqual(d.outputTokens, 639)
        XCTAssertEqual(d.usd, 0)                                             // OpenAI models: unpriced
        XCTAssertEqual(d.byModel["gpt-5.6-sol"]?.inputTokens, 17462)
        XCTAssertEqual(d.byModel["gpt-5.6-sol"]?.stretches, 1)
        XCTAssertEqual(d.byEngine["codex"]?.inputTokens, 17462)
        XCTAssertEqual(d.byEngine["codex"]?.stretches, 1)
        XCTAssertEqual(d.byEffort["high"]?.stretches, 1)
        XCTAssertEqual(d.activities["simulator"]?.stretches, 1)             // the exec's `xcrun simctl` wins over the edits
        XCTAssertEqual(d.activities["simulator"]?.seconds ?? 0, 618.4, accuracy: 0.5)  // 06:40:36 → 06:50:54 task_complete
        XCTAssertEqual(d.turns, 1)
        XCTAssertEqual(d.compactions, 1)
        XCTAssertEqual(d.waitingSeconds, 5946, accuracy: 1)                  // 06:50:54 → 08:30:00
        XCTAssertEqual(d.longestUnattended, 2)
        XCTAssertEqual(d.sessions, ["rollout-1"])
        XCTAssertNotNil(e.state.stretch)                                     // "thanks" opened one, still unanswered
    }

    func testScanWalksTheCodexSessionsTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stats-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let day = root.appendingPathComponent("codex/2026/07/14")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try [
            #"{"timestamp":"2026-07-14T06:40:35.724Z","type":"turn_context","payload":{"cwd":"/w/app","model":"gpt-5.5","effort":"max"}}"#,
            #"{"timestamp":"2026-07-14T06:40:36.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#,
            #"{"timestamp":"2026-07-14T06:40:54.127Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: day.appendingPathComponent("rollout-2026-07-14T13-40-32-abc.jsonl"), atomically: true, encoding: .utf8)
        let now = date("2026-07-15T00:00:00Z")
        let r = StatsScanner.scan(projectsDir: projects, codexDir: root.appendingPathComponent("codex"),
                                  cacheURL: root.appendingPathComponent("cache.json"), calendar: cal, now: now)
        XCTAssertEqual(r.files, 1)
        XCTAssertEqual(r.cwds, ["/w/app"])
        XCTAssertEqual(r.days["2026-07-14"]?.byEngine["codex"]?.inputTokens, 100)
        XCTAssertEqual(r.days["2026-07-14"]?.byEffort["max"]?.inputTokens, 100)
        XCTAssertEqual(r.days["2026-07-14"]?.byModel["gpt-5.5"]?.outputTokens, 10)
        XCTAssertEqual(r.days["2026-07-14"]?.sessions, ["rollout-2026-07-14T13-40-32-abc"])
        // The open stretch rides the provisional view, keyed to the engine.
        XCTAssertEqual(r.days["2026-07-14"]?.byEngine["codex"]?.stretches, 1)
    }

    func testPresentationEngineAndEffortRows() {
        var d = Stats.Day()
        d.byEngine["claude"] = Stats.ActivityTally(); d.byEngine["claude"]!.usd = 4; d.byEngine["claude"]!.inputTokens = 10
        d.byEngine["codex"] = Stats.ActivityTally(); d.byEngine["codex"]!.inputTokens = 30
        d.byEffort["high"] = Stats.ActivityTally(); d.byEffort["high"]!.usd = 3
        d.byEffort["unset"] = Stats.ActivityTally(); d.byEffort["unset"]!.usd = 1
        let s = Stats.fold(days: ["2026-09-04": d], period: .day, now: date("2026-09-04T05:00:00Z"), calendar: cal)
        let engines = Stats.Presentation.engineRows(s)
        XCTAssertEqual(engines.map(\.id), ["Claude Code", "Codex CLI · unpriced"])
        XCTAssertEqual(engines[0].share, 1, accuracy: 0.001)                // $ share while anything is priced
        let efforts = Stats.Presentation.effortRows(s)
        XCTAssertEqual(efforts.map(\.id), ["High", "Unset"])
        XCTAssertEqual(efforts[0].share, 0.75, accuracy: 0.001)
    }

    func testWaitingGapIsCappedAtEightHours() {
        var e = StatsScanner.FileEntry()
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-01T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}}"#), sessionID: "s", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-02T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"back"}}"#), sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days.values.map(\.waitingSeconds).reduce(0, +), 8 * 3600, accuracy: 0.5)
    }

    func testScanIsIncrementalAndResetsOnShrink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/abc.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        let l1 = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"#
        try (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertEqual(r.cwds, ["/r/a"])
        XCTAssertEqual(r.files, 1)
        // Append: only the new line is read.
        let h = try FileHandle(forWritingTo: file); h.seekToEndOfFile()
        h.write(Data((l1 + "\n").utf8)); try h.close()
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 2)
        // A partial last line waits.
        let h2 = try FileHandle(forWritingTo: file); h2.seekToEndOfFile()
        h2.write(Data(#"{"type":"user","timest"#.utf8)); try h2.close()
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 2)
        // Shrink: the file is re-read from zero.
        try (l1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    /// `<project>/<session-id>/subagents/agent-*.jsonl` is a subagent's
    /// own transcript: `scan` must pick it up (one fixed depth below the
    /// session dir) and its tokens must land on the day, but it must not
    /// contribute a session — only the top-level file does.
    func testScanPicksUpSubagentTranscriptsForTokensOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionDir = dir.appendingPathComponent("p/sess-1")
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let topFile = dir.appendingPathComponent("p/sess-1.jsonl")
        let subFile = subagentsDir.appendingPathComponent("agent-x.jsonl")
        let cache = dir.appendingPathComponent("cache.json")

        let topLine = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#
        try (topLine + "\n").write(to: topFile, atomically: true, encoding: .utf8)
        let subLine = #"{"type":"assistant","timestamp":"2026-09-04T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"subtask done"}]}}"#
        try (subLine + "\n").write(to: subFile, atomically: true, encoding: .utf8)

        // A workflow run's agents sit one level deeper and count the same way.
        let runDir = subagentsDir.appendingPathComponent("workflows/wf_abc")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let wfLine = #"{"type":"assistant","timestamp":"2026-09-04T01:00:06.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":5,"output_tokens":7},"content":[{"type":"text","text":"stream done"}]}}"#
        try (wfLine + "\n").write(to: runDir.appendingPathComponent("agent-y.jsonl"), atomically: true, encoding: .utf8)

        let r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.files, 3)
        let d = r.days["2026-09-04"]!
        XCTAssertEqual(d.humanMessages, 1)          // from the top-level file only
        XCTAssertEqual(d.sessions, ["sess-1"])      // the subagent files added no session
        XCTAssertEqual(d.inputTokens, 15)           // from the subagent files
        XCTAssertEqual(d.outputTokens, 27)
    }

    /// A file whose last line never gets a trailing newline (a still-open
    /// transcript stalled between JSON entries — not the same as an
    /// mid-write partial line, which does eventually complete) must not
    /// keep `remaining` stuck above 0 forever: `parse` returns 0 for it,
    /// so the second scan must latch `size` and report the corpus caught
    /// up rather than spinning the caller (`StatsModel`'s chunk loop)
    /// with no way out.
    func testScanLatchesUnterminatedTailAndStopsBeingRemaining() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/tail.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        let l1 = #"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"#
        // First line complete; last line has no trailing newline at all.
        try (l1 + "\n" + #"{"type":"user","timest"#).write(to: file, atomically: true, encoding: .utf8)
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)
        XCTAssertEqual(r.remaining, 0)
        // Scanned again with no change to the file: still caught up.
        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.bytesRemaining, 0)
    }

    /// A window smaller than the file forces multiple `parse` calls per
    /// file; a budget smaller than the file's total size must stop mid
    /// file (not mid line — every line that gets counted is a whole one).
    func testScanHonorsByteBudgetAndReportsRemaining() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let day = "2026-09-04"
        // Three lines, each exactly 220 bytes (219 + trailing newline) —
        // padded so the byte math below is exact, not approximate.
        func line(_ seq: Int, targetBytes: Int) -> String {
            func build(_ padLen: Int) -> String {
                #"{"type":"user","cwd":"/r/a","timestamp":"\#(day)T0\#(seq):00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"\#(String(repeating: "x", count: padLen))"}}"#
            }
            var padLen = 0
            while build(padLen).utf8.count < targetBytes { padLen += 1 }
            return build(padLen)
        }
        let lines = (1...3).map { line($0, targetBytes: 219) + "\n" }
        XCTAssertEqual(lines[0].utf8.count, 220)
        try lines.joined().write(to: dir.appendingPathComponent("p/f.jsonl"), atomically: true, encoding: .utf8)

        // Baseline: one unbounded scan into its own cache, for comparison.
        let full = StatsScanner.scan(projectsDir: dir, cacheURL: dir.appendingPathComponent("full.json"), calendar: cal)
        XCTAssertEqual(full.days[day]?.humanMessages, 3)
        XCTAssertEqual(full.remaining, 0)

        let cache = dir.appendingPathComponent("cache.json")
        // windowBytes bigger than one line but smaller than two, so each
        // `parse` call reads exactly one line; a 300-byte budget (less
        // than the 660-byte file) affords exactly two of the three.
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal, byteBudget: 300, windowBytes: 300)
        XCTAssertEqual(r.remaining, 1)
        XCTAssertGreaterThan(r.bytesRemaining, 0)
        XCTAssertEqual(r.days[day]?.humanMessages, 2)

        r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal, byteBudget: 300, windowBytes: 300)
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.bytesRemaining, 0)
        XCTAssertEqual(r.days, full.days)
    }

    /// The byte-search tool-result path answers exactly what the full
    /// JSON path would: the entry's own (last) timestamp even when a
    /// tool's output echoes one, every errored block, the denial flag.
    func testFastToolResultPathMatchesTheDictionaryPath() throws {
        let line = #"{"type":"user","toolDenialKind":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"echo {\"timestamp\":\"1999-01-01T00:00:00.000Z\"} \"is_error\":true"},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"x"},{"type":"tool_result","tool_use_id":"t3","content":"fine"}]},"timestamp":"2026-09-04T03:00:00.000Z","uuid":"u1"}"#
        let fast = try XCTUnwrap(StatsScanner.fastParseToolResult(Data(line.utf8)))
        XCTAssertEqual(fast["type"] as? String, "user")
        XCTAssertEqual(fast["timestamp"] as? String, "2026-09-04T03:00:00.000Z")
        XCTAssertEqual(fast["toolDenialKind"] as? Bool, true)
        let blocks = try XCTUnwrap((fast["message"] as? [String: Any])?["content"] as? [[String: Any]])
        // The echoed `\"is_error\":true` inside a string is escaped, so it is not a match.
        XCTAssertEqual(blocks.count, 2)
        var viaFast = StatsScanner.FileEntry()
        StatsScanner.ingest(fast, sessionID: "s", into: &viaFast, calendar: cal)
        let full = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        var viaFull = StatsScanner.FileEntry()
        StatsScanner.ingest(full, sessionID: "s", into: &viaFull, calendar: cal)
        XCTAssertEqual(viaFast.days["2026-09-04"]?.toolErrors, viaFull.days["2026-09-04"]?.toolErrors)
        XCTAssertEqual(viaFast.days["2026-09-04"]?.denials, viaFull.days["2026-09-04"]?.denials)
        XCTAssertNil(StatsScanner.fastParseToolResult(Data(#"{"type":"user","message":{}}"#.utf8)), "no timestamp, no entry")
    }

    /// A handle carries the decoded cache across a chunked backfill and
    /// still lands the finished state on disk, identical to the
    /// handle-less scan.
    /// #499: a released handle has written what moved and forgotten the
    /// corpus; the next pass re-reads the file and sums the same days.
    func testCacheHandleReleaseWritesAndForgets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-r-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var lines: [String] = []
        for i in 0..<4 {
            lines.append(#"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:0\#(i):00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"hi"}}"#)
            lines.append(#"{"type":"assistant","timestamp":"2026-09-04T01:0\#(i):05.000Z","message":{"id":"a\#(i)","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":10},"content":[{"type":"text","text":"ok"}]}}"#)
        }
        try lines.joined(separator: "\n").appending("\n").write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let cacheURL = dir.appendingPathComponent("held.json")
        let handle = StatsScanner.CacheHandle()
        let first = StatsScanner.scan(projectsDir: dir, cacheURL: cacheURL, calendar: cal, handle: handle)
        XCTAssertEqual(first.remaining, 0)
        XCTAssertNotNil(handle.cache)
        // The corpus moves after the write, so the handle is dirty again.
        let fh = try FileHandle(forWritingTo: project.appendingPathComponent("s1.jsonl"))
        try fh.seekToEnd(); try fh.write(contentsOf: Data(lines[0...1].joined(separator: "\n").appending("\n").utf8)); try fh.close()
        let moved = StatsScanner.scan(projectsDir: dir, cacheURL: cacheURL, calendar: cal, handle: handle)
        XCTAssertTrue(handle.dirty, "a settled corpus that moved waits for the settled cadence")
        let before = try Data(contentsOf: cacheURL)
        handle.release(to: cacheURL)
        XCTAssertNil(handle.cache)
        XCTAssertNil(handle.sums)
        XCTAssertFalse(handle.dirty)
        XCTAssertNotEqual(try Data(contentsOf: cacheURL), before, "release flushed the moved corpus")
        let again = StatsScanner.scan(projectsDir: dir, cacheURL: cacheURL, calendar: cal, handle: handle)
        XCTAssertEqual(again.days, moved.days, "the re-read corpus sums the same days")
        XCTAssertEqual(again.files, 1)
        XCTAssertNotNil(handle.cache)
    }

    func testCacheHandleCarriesThePassesAndWritesTheFinishedCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-h-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var lines: [String] = []
        for i in 0..<6 {
            lines.append(#"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:0\#(i):00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"m\#(i)"}}"#)
            lines.append(#"{"type":"assistant","timestamp":"2026-09-04T01:0\#(i):05.000Z","message":{"id":"a\#(i)","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"ok"}]}}"#)
        }
        try lines.joined(separator: "\n").appending("\n").write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let plainCache = dir.appendingPathComponent("plain.json")
        let full = StatsScanner.scan(projectsDir: dir, cacheURL: plainCache, calendar: cal)

        let heldCache = dir.appendingPathComponent("held.json")
        let handle = StatsScanner.CacheHandle()
        var passes = 0
        var r = StatsScanner.scan(projectsDir: dir, cacheURL: heldCache, calendar: cal, byteBudget: 400, windowBytes: 400, handle: handle)
        passes += 1
        XCTAssertGreaterThan(r.remaining, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heldCache.path), "mid-backfill state stays in the handle until a checkpoint is due")
        while r.remaining > 0, passes < 20 {
            r = StatsScanner.scan(projectsDir: dir, cacheURL: heldCache, calendar: cal, byteBudget: 400, windowBytes: 400, handle: handle)
            passes += 1
        }
        XCTAssertEqual(r.remaining, 0)
        XCTAssertGreaterThan(passes, 2)
        if r.days != full.days, let a = r.days["2026-09-04"], let b = full.days["2026-09-04"] {
            for (x, y) in zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children) where "\(x.value)" != "\(y.value)" {
                print("DIFF \(x.label ?? "?"): held=\(x.value) full=\(y.value)")
            }
        }
        XCTAssertEqual(r.days, full.days)
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldCache.path), "the finished corpus is written")
        // The written cache is the same corpus a fresh scan would trust.
        let again = StatsScanner.scan(projectsDir: dir, cacheURL: heldCache, calendar: cal)
        XCTAssertEqual(again.days, full.days)
        XCTAssertEqual(again.files, 1)

        // Held across refreshes: a caught-up corpus that keeps moving is
        // carried in memory and rewritten on the settled cadence, not
        // after every pass — and the handle never re-reads the file.
        let written = try Data(contentsOf: heldCache)
        try FileManager.default.removeItem(at: heldCache)
        let more = lines[0...1].joined(separator: "\n").appending("\n")
        let fh = try FileHandle(forWritingTo: project.appendingPathComponent("s1.jsonl"))
        try fh.seekToEnd(); try fh.write(contentsOf: Data(more.utf8)); try fh.close()
        let settled = StatsScanner.scan(projectsDir: dir, cacheURL: heldCache, calendar: cal, handle: handle)
        XCTAssertEqual(settled.remaining, 0)
        XCTAssertEqual(settled.days["2026-09-04"]?.outputTokens, full.days["2026-09-04"]!.outputTokens + 20, "the pass parsed the new lines off the held cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heldCache.path), "a settled pass inside the write interval does not rewrite the cache")
        handle.lastWrite = .distantPast
        _ = StatsScanner.scan(projectsDir: dir, cacheURL: heldCache, calendar: cal, handle: handle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldCache.path), "past the interval it is written")
        XCTAssertNotEqual(try Data(contentsOf: heldCache), written)
    }

    /// Throughput on the real corpus — opt in with INFINITUS_BENCH=1;
    /// prints MB/s for the largest transcript and the cache round trip.
    func testBenchmarkRealCorpus() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INFINITUS_BENCH"] == "1", "set INFINITUS_BENCH=1 to run")
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var biggest: (URL, Int)?
        for case let url as URL in fm.enumerator(at: projects, includingPropertiesForKeys: [.fileSizeKey])! where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > (biggest?.1 ?? 0) { biggest = (url, size) }
        }
        let (big, size) = try XCTUnwrap(biggest)
        var entry = StatsScanner.FileEntry()
        var read = 0
        let t0 = Date()
        while read < min(size, 256 * 1024 * 1024) {
            let c = StatsScanner.parse(url: big, sessionID: "s", into: &entry, calendar: .current)
            if c <= 0 { break }
            read += c
        }
        let dt = Date().timeIntervalSince(t0)
        print("BENCH parse \(big.lastPathComponent): \(read / 1_048_576) MB in \(String(format: "%.1f", dt)) s = \(String(format: "%.1f", Double(read) / 1_048_576 / dt)) MB/s")
        let cacheURL = StatsScanner.defaultCacheURL()
        if let data = try? Data(contentsOf: cacheURL) {
            let t1 = Date()
            let cache = try JSONDecoder().decode(StatsScanner.Cache.self, from: data)
            let t2 = Date()
            _ = try JSONEncoder().encode(cache)
            print("BENCH cache \(data.count / 1_048_576) MB, \(cache.files.count) files: decode \(String(format: "%.2f", t2.timeIntervalSince(t1))) s, encode \(String(format: "%.2f", Date().timeIntervalSince(t2))) s")
        }
    }

    func testTheCacheIsPerClaudeConfigHome() {
        let real = StatsScanner.defaultCacheURL(environment: [:])
        let fixture = StatsScanner.defaultCacheURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/t3fix/claude"])
        XCTAssertEqual(real.lastPathComponent, "transcripts.json")
        XCTAssertEqual(fixture.lastPathComponent, "transcripts--tmp-t3fix-claude.json")
        XCTAssertEqual(fixture.deletingLastPathComponent(), real.deletingLastPathComponent())
        XCTAssertEqual(StatsScanner.defaultCacheURL(environment: ["CLAUDE_CONFIG_DIR": ""]), real)
    }

    func testFastPathParsesBigToolResultLineWithoutFullJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sess1.jsonl")
        let pad = String(repeating: "x", count: 200_000)
        let bigLine = #"{"type":"user","timestamp":"2026-09-04T03:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"\#(pad)"},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"ok"}]}}"#
        XCTAssertGreaterThan(bigLine.utf8.count, 200_000)
        try (bigLine + "\n").write(to: file, atomically: true, encoding: .utf8)
        var entry = StatsScanner.FileEntry()
        _ = StatsScanner.parse(url: file, sessionID: "sess1", into: &entry, calendar: cal)
        let day = entry.days["2026-09-04"]
        XCTAssertEqual(day?.toolErrors, 2)
        XCTAssertEqual(day?.sessions, ["sess1"])
        let slot = Stats.hourSlot(date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(day?.hours[slot], 1)
    }

    func testParseGitLogWithNumstatAndTrailers() {
        let log = """
        \u{1e}abc123\u{1f}2026-09-04T08:10:00+07:00\u{1f}me@x.com\u{1f}feat: thing\u{1f}Claude Code <noreply@anthropic.com>
        3\t1\tSources/A.swift
        -\t-\tassets/icon.png
        \u{1e}def456\u{1f}2026-09-03T23:59:00+07:00\u{1f}me@x.com\u{1f}Revert "feat: thing"\u{1f}
        0\t3\tSources/A.swift
        """
        let commits = RepoStats.parseLog(log)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "abc123")
        XCTAssertEqual(commits[0].added, 3)
        XCTAssertEqual(commits[0].removed, 1)
        XCTAssertEqual(commits[0].files, 2)
        XCTAssertTrue(commits[0].coAuthoredByClaude)
        XCTAssertFalse(commits[0].revert)
        XCTAssertTrue(commits[1].revert)
        XCTAssertFalse(commits[1].coAuthoredByClaude)
        XCTAssertEqual(commits[1].at, date("2026-09-03T16:59:00Z"))
    }

    func testParsePRsAndFoldDays() throws {
        let json = Data(#"[{"number":1,"createdAt":"2026-09-01T10:00:00Z","mergedAt":"2026-09-03T10:00:00Z","closedAt":"2026-09-03T10:00:00Z"},{"number":2,"createdAt":"2026-09-04T01:00:00Z","mergedAt":null,"closedAt":null}]"#.utf8)
        let prs = RepoStats.parsePRs(json)
        XCTAssertEqual(prs.count, 2)
        XCTAssertNil(prs[1].mergedAt)
        let commits = RepoStats.parseLog("\u{1e}a\u{1f}2026-09-04T08:10:00+07:00\u{1f}me@x.com\u{1f}x\u{1f}\n1\t0\tf\n")
        let days = RepoStats.days(commits: commits, prs: prs, repo: "/r/a", calendar: cal)
        XCTAssertEqual(days["2026-09-04"]?.commits, 1)
        XCTAssertEqual(days["2026-09-04"]?.linesAdded, 1)
        XCTAssertEqual(days["2026-09-04"]?.repos, ["/r/a"])
        XCTAssertEqual(days["2026-09-04"]?.prsOpened, 1)
        XCTAssertEqual(days["2026-09-01"]?.prsOpened, 1)
        XCTAssertEqual(days["2026-09-03"]?.prsMerged, 1)
        XCTAssertEqual(days["2026-09-03"]?.mergeHoursTotal ?? 0, 48, accuracy: 0.01)
        XCTAssertEqual(days["2026-09-03"]?.mergeCount, 1)
    }

    func testEventsFoldIntoDaysWithMinutesLost() {
        let ev: [StatsEvent] = [
            .init(at: date("2026-09-04T01:00:00Z"), kind: "switch", icon: "", text: "switched a → b"),
            .init(at: date("2026-09-04T01:05:00Z"), kind: "death", icon: "", text: "a hit its limit"),
            .init(at: date("2026-09-04T01:10:00Z"), kind: "limit", icon: "", text: "every account at a limit"),
            .init(at: date("2026-09-04T01:40:00Z"), kind: "revival", icon: "", text: "a is back"),
            .init(at: date("2026-09-04T02:00:00Z"), kind: "ignite", icon: "", text: "ignited c"),
            .init(at: date("2026-09-04T02:01:00Z"), kind: "resume", icon: "", text: "resumed s"),
            .init(at: date("2026-09-04T02:02:00Z"), kind: "nudge", icon: "", text: "nudged s"),
        ]
        let d = StatsEvents.days(ev, calendar: cal)["2026-09-04"]!
        XCTAssertEqual(d.switches, 1)
        XCTAssertEqual(d.limitStops, 1)
        XCTAssertEqual(d.revivals, 1)
        XCTAssertEqual(d.ignites, 1)
        XCTAssertEqual(d.resumes, 2)
        XCTAssertEqual(d.minutesLostToLimits, 30, accuracy: 0.01)
    }

    func testAwsDoneNudgeCarriesThePrefix() {
        XCTAssertTrue(AwsLogin.continueMessage(profile: "p", fromPhone: true).hasPrefix("[Infinitus] "))
    }

    // MARK: fix wave 2026-09-04

    /// The shape Claude Code actually writes for a relayed message: a
    /// preamble line, the wrapper, then its own guidance after the close
    /// tag. Socket paths and bodies are neutral stand-ins for a real
    /// transcript's.
    private func peerEntry(from: String, name: String, body: String, origin: Bool) -> [String: Any] {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        let content = "Another Claude session sent a message:\\n"
            + "<cross-session-message from=\\\"\(from)\\\" from-name=\\\"\(name)\\\" from-mode=\\\"bypass\\\">\\n"
            + esc(body) + "\\n</cross-session-message>\\n\\n"
            + "This came from another Claude session — not typed by your user."
        let originJSON = origin
            ? #","origin":{"kind":"peer","from":"\#(from)","verifiedPeerPid":1,"name":"\#(name)","fromMode":"bypass","body":"\#(esc(body))"}"#
            : ""
        return entry(#"{"type":"user","isMeta":true,"timestamp":"2026-09-04T01:00:00.000Z","message":{"role":"user","content":"\#(content)"}\#(originJSON)}"#)
    }

    func testClassifyRealPeerEnvelopes() {
        // (1) origin peer from the app's socket, nudge body.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: "[Infinitus] Your account hit a limit — continue on the next one",
            origin: true)), .nudge)
        // (2) same, but the body carries the phone preface.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: PeerSocket.phonePreface + "look at the build",
            origin: true)), .phone)
        // (3) no origin: the wrapper sits inside the preamble.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
            body: "[Infinitus] Your account hit a limit — continue on the next one",
            origin: false)), .nudge)
        // (4) no origin, another session.
        XCTAssertEqual(StatsScanner.classifyUser(peerEntry(
            from: "uds:/tmp/cc-socks/20520.sock", name: "other",
            body: "merge my branch please", origin: false)), .agent)
        // (5) no origin, a teammate envelope under the same preamble.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\n<teammate-message teammate_id=\"worker-1\" color=\"cyan\">\n{\"type\":\"idle_notification\"}\n</teammate-message>\n\nThis came from another Claude session — not typed by your user."}}"#)), .agent)
    }

    func testClassifyMachineryDenylistAndPastedImage() {
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Stop hook feedback:\n- run the tests"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"Caveat: The messages below were generated while running /x"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(##"{"type":"user","message":{"role":"user","content":"# Autonomous loop tick 4"}}"##)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[1 prior /loop tick]"}}"#)), .machinery)
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"(Re-invocation of /loop)"}}"#)), .machinery)
        // The user pasted this — still human.
        XCTAssertEqual(StatsScanner.classifyUser(entry(#"{"type":"user","message":{"role":"user","content":"[Image: screenshot.png]"}}"#)), .human)
    }

    func testNudgeDoesNotCloseTheWaitingClockOrResetToolsSinceHuman() {
        var e = StatsScanner.FileEntry()
        // A turn ends, two tool calls run, then a nudge arrives.
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#), sessionID: "s", into: &e, calendar: cal)
        StatsScanner.ingest(entry(#"{"type":"assistant","timestamp":"2026-09-04T01:00:01.000Z","message":{"id":"m2","model":"claude-opus-4-5-20250805","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"waiting on you"}]}}"#), sessionID: "s", into: &e, calendar: cal)
        var nudge = peerEntry(from: "uds:/tmp/infinitus-1.sock", name: "Infinitus",
                              body: "[Infinitus] Your account hit a limit", origin: true)
        nudge["timestamp"] = "2026-09-04T01:10:00.000Z"
        StatsScanner.ingest(nudge, sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days["2026-09-04"]?.nudges, 1)
        XCTAssertEqual(e.days["2026-09-04"]?.phoneMessages, 0)
        XCTAssertEqual(e.days["2026-09-04"]?.waitingSeconds, 0)      // clock still running
        XCTAssertNotNil(e.state.turnEndedAt)
        XCTAssertEqual(e.state.toolsSinceHuman, 1)                   // not reset
        // The human who actually answers closes it.
        StatsScanner.ingest(entry(#"{"type":"user","timestamp":"2026-09-04T01:20:01.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"here"}}"#), sessionID: "s", into: &e, calendar: cal)
        XCTAssertEqual(e.days["2026-09-04"]?.waitingSeconds ?? 0, 1200, accuracy: 0.5)
        XCTAssertEqual(e.state.toolsSinceHuman, 0)
    }

    func testUnchangedTreeDoesNotRewriteTheCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p/abc.jsonl")
        let cache = dir.appendingPathComponent("cache.json")
        try (#"{"type":"user","cwd":"/r/a","timestamp":"2026-09-04T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"one"}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        _ = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let first = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        let r = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let second = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        XCTAssertEqual(r.days["2026-09-04"]?.humanMessages, 1)   // still answered from the cache
        XCTAssertEqual(first, second)
        // A new file makes it write again.
        try (#"{"type":"user","timestamp":"2026-09-04T02:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"two"}}"# + "\n")
            .write(to: dir.appendingPathComponent("p/def.jsonl"), atomically: true, encoding: .utf8)
        _ = StatsScanner.scan(projectsDir: dir, cacheURL: cache, calendar: cal)
        let third = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as! Date
        XCTAssertNotEqual(second, third)
    }

    func testAllOutSpanIsCappedAndClosedBySwitch() {
        func ev(_ kind: String, _ stamp: String) -> StatsEvent {
            StatsEvent(at: date(stamp), kind: kind, icon: "", text: kind)
        }
        // Orphan span: the revival lands three days later (an app
        // restart in between) — capped at 8 h, not 4320 minutes.
        let capped = StatsEvents.days([ev("limit", "2026-09-01T01:00:00Z"),
                                       ev("revival", "2026-09-04T01:00:00Z")], calendar: cal)
        XCTAssertEqual(capped["2026-09-04"]?.minutesLostToLimits ?? 0, 480, accuracy: 0.01)
        // A second `limit` inside the span doesn't restart it.
        let doubled = StatsEvents.days([ev("limit", "2026-09-04T01:00:00Z"),
                                        ev("limit", "2026-09-04T01:30:00Z"),
                                        ev("revival", "2026-09-04T02:00:00Z")], calendar: cal)
        XCTAssertEqual(doubled["2026-09-04"]?.minutesLostToLimits ?? 0, 60, accuracy: 0.01)
        // A switch closes an open span, and the next limit opens a fresh one.
        let bySwitch = StatsEvents.days([ev("limit", "2026-09-04T01:00:00Z"),
                                         ev("switch", "2026-09-04T01:20:00Z"),
                                         ev("limit", "2026-09-04T02:00:00Z"),
                                         ev("revival", "2026-09-04T02:10:00Z")], calendar: cal)
        XCTAssertEqual(bySwitch["2026-09-04"]?.minutesLostToLimits ?? 0, 30, accuracy: 0.01)
    }

    func testCompactedDayDropsHoursAndSetsAndStillAdds() {
        var d = Stats.Day(); d.sessions = ["s1", "s2"]; d.repos = ["r"]; d.hours[5] = 3; d.commits = 2
        let c = d.compacted()
        XCTAssertTrue(c.hours.isEmpty)
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertEqual(c.sessionCount, 2)
        XCTAssertEqual(c.repoCount, 1)
        XCTAssertEqual(c.compacted(), c)   // idempotent
        // Mismatched lengths must not trap, and the tallies sum.
        let sum = c + d
        XCTAssertEqual(sum.hours.count, 168)
        XCTAssertEqual(sum.hours[5], 3)
        XCTAssertEqual(sum.commits, 4)
        XCTAssertEqual((c + c).sessionCount, 4)
        XCTAssertEqual(sum.sessionBuckets.count, 4)
    }

    func testBundleStaysUnderFourKilobytesWithManyToolNames() throws {
        var d = Stats.Day()
        for i in 0..<30 { d.toolCalls["ToolNumber\(i)"] = i + 1 }
        d.sessions = Set((0..<20).map { "session-\($0)" })
        d.repos = ["/a/b/c"]
        d.hours[7] = 12
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        XCTAssertFalse(json.contains("\"hours\":[0"))
        XCTAssertTrue(b.periods.allSatisfy { $0.total.hours.isEmpty && $0.previous.hours.isEmpty })
        // The spec asks for ≤ 4 KB; that floor is not reachable while
        // `Day` encodes synthetically. An EMPTY bundle is already 5375
        // bytes: four periods × (total + previous) = 8 Days × ~617
        // bytes of zero-valued fields, and dropping `hours` (the 14.8 KB
        // culprit) only takes ~2.7 KB of that. Omitting defaults on
        // encode would fix it and is deliberately NOT done — every
        // already-installed phone decodes Day with the synthesized
        // initializer that throws on a missing key, so a sparse Mac
        // would break the whole MirrorSnapshot on it (the very failure
        // B2 exists to prevent), and the e2e gate asserts `commits` and
        // `humanMessages` are present on a zero summary. 14.8 KB → this;
        // the tokens/min record book (#89: three Day fields, a 30-day
        // peak series, up to 24 marks) added ~200 bytes on an empty one.
        XCTAssertLessThan(json.utf8.count, 9_216)
    }

    func testSummaryCompactedStripsTheDailySeries() {
        var d = Stats.Day(); d.hours[3] = 1; d.sessions = ["s"]
        d.activities["code"] = tally(usd: 1)
        d.byModel["claude-sonnet-5"] = tally(usd: 1)
        let s = Stats.fold(days: ["2026-09-04": d, "2026-09-03": d], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        XCTAssertEqual(s.daily.first?.day.hours.count, 168)
        let c = s.compacted()
        XCTAssertTrue(c.daily.allSatisfy { $0.day.hours.isEmpty && $0.day.sessions.isEmpty })
        XCTAssertEqual(c.daily.first?.day.sessionCount, 1)
        XCTAssertTrue(c.previous.activities.isEmpty)
        XCTAssertTrue(c.previous.byModel.isEmpty)
        XCTAssertTrue(c.daily.allSatisfy { $0.day.activities.isEmpty && $0.day.byModel.isEmpty })
        XCTAssertFalse(c.total.activities.isEmpty)
    }

    /// Every tally populated in all four periods — worse than any real
    /// week. `GET /snapshot` has no response cap; the bound keeps the
    /// bundle a small part of the snapshot the phone fetches.
    func testBundleWithEffortTalliesStaysUnderTwentyKilobytes() throws {
        var d = Stats.Day()
        for i in 0..<30 { d.toolCalls["ToolNumber\(i)"] = i + 1 }
        d.sessions = Set((0..<20).map { "session-\($0)" })
        d.repos = ["/a/b/c"]
        d.hours[7] = 12
        var t = Stats.ActivityTally()
        t.stretches = 3; t.seconds = 900; t.inputTokens = 120_000; t.outputTokens = 9_000; t.usd = 12.34
        // Realistic cache traffic (#139) — a real tally never leaves
        // these at zero, so the worst case must carry them too.
        t.cacheReadTokens = 900_000; t.cacheWriteTokens = 60_000; t.cacheSavingsUSD = 1.62
        for a in Stats.Activity.allCases { d.activities[a.rawValue] = t }
        for i in 0..<9 { d.byModel["claude-m\(i)"] = t }
        for e in Stats.Engine.allCases { d.byEngine[e.rawValue] = t }
        for e in ["minimal", "low", "medium", "high", "max", "unset"] { d.byEffort[e] = t }
        let b = Stats.Bundle(days: ["2026-09-04": d], now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        // 16 KB → 20 KB (#139): three new ActivityTally fields (cr, cw,
        // sv) × ~96 tallies (4 periods × (total + previous) × 24 keyed
        // tallies) adds a few KB on top of the pre-#139 worst case.
        XCTAssertLessThan(json.utf8.count, 20_480)
        XCTAssertTrue(b.periods.allSatisfy { $0.total.byModel.count <= 7 })
    }

    func testDayDecodesForwardCompatibly() throws {
        let dec = JSONDecoder()
        XCTAssertEqual(try dec.decode(Stats.Day.self, from: Data("{}".utf8)), Stats.Day())
        var d = Stats.Day(); d.commits = 3; d.usd = 1.5; d.toolCalls = ["Bash": 2]; d.hours[9] = 4
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as! [String: Any]
        obj.removeValue(forKey: "commits")            // an older writer, or a field this build predates
        obj["somethingNewer"] = 7                     // a field only a newer build knows
        let back = try dec.decode(Stats.Day.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(back.commits, 0)
        XCTAssertEqual(back.usd, 1.5)
        XCTAssertEqual(back.toolCalls, ["Bash": 2])
        XCTAssertEqual(back.hours[9], 4)
    }

    func testWeekIsMondayToSundayUnderASundayFirstCalendar() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        sundayFirst.firstWeekday = 1
        var d = Stats.Day(); d.commits = 1
        // Sunday 2026-09-06 belongs to the week that STARTED Monday 2026-08-31.
        let s = Stats.fold(days: ["2026-09-06": d], period: .week,
                           now: date("2026-09-06T03:00:00Z"), calendar: sundayFirst)
        XCTAssertEqual(s.from, "2026-08-31")
        XCTAssertEqual(s.to, "2026-09-06")
        XCTAssertEqual(s.total.commits, 1)
    }

    func testStreakCountsBackFromYesterdayBeforeTodayStarts() {
        func day(_ commits: Int) -> Stats.Day { var d = Stats.Day(); d.commits = commits; return d }
        let days = ["2026-09-01": day(1), "2026-09-02": day(1), "2026-09-03": day(1)]
        // 09:00 on the 4th, nothing logged today yet.
        let s = Stats.fold(days: days, period: .day, now: date("2026-09-04T02:00:00Z"), calendar: cal)
        XCTAssertEqual(s.streak, 3)
        // With today active it counts today too.
        var withToday = days; withToday["2026-09-04"] = day(1)
        XCTAssertEqual(Stats.fold(days: withToday, period: .day,
                                  now: date("2026-09-04T02:00:00Z"), calendar: cal).streak, 4)
        // A gap yesterday and nothing today is still 0.
        XCTAssertEqual(Stats.fold(days: ["2026-09-01": day(1)], period: .day,
                                  now: date("2026-09-04T02:00:00Z"), calendar: cal).streak, 0)
    }

    func testYearSparklinesBucketToWeeks() {
        var daily: [Stats.DayPoint] = []
        var d = Stats.Day(); d.commits = 1; d.usd = 2
        for i in 0..<365 { daily.append(Stats.DayPoint(key: "d\(i)", day: d)) }
        var total = Stats.Day(); total.commits = 365; total.usd = 730
        let s = Stats.Summary(period: .year, from: "2026-01-01", to: "2026-12-31",
                              total: total, previous: Stats.Day(), daily: daily, streak: 0)
        let groups = Stats.Presentation.groups(s)
        for g in groups {
            for t in g.tiles { XCTAssertLessThanOrEqual(t.series.count, 53, "\(t.id)") }
        }
        let commits = groups.first { $0.id == "Throughput" }!.tiles.first { $0.id == "Commits" }!
        XCTAssertEqual(commits.series.first, 7)      // counts sum
        XCTAssertEqual(commits.series.last, 1)       // 365 = 52 weeks + 1 day
        let spend = groups.first { $0.id == "Cost (API-equivalent estimate)" }!.tiles.first { $0.id == "Spend" }!
        XCTAssertEqual(spend.series.first, 2)        // money means
        // A month-long series is left alone.
        let short = Stats.Summary(period: .month, from: "2026-09-01", to: "2026-09-30",
                                  total: total, previous: Stats.Day(),
                                  daily: Array(daily.prefix(30)), streak: 0)
        XCTAssertEqual(Stats.Presentation.groups(short).first!.tiles.first!.series.count, 30)
    }

    func testCatalogueSurfacesTheNewFacts() {
        var total = Stats.Day()
        total.filesTouched = 12; total.coAuthoredByClaude = 3; total.reverts = 1
        total.repos = ["a", "b"]; total.inputTokens = 4_000
        let s = Stats.Summary(period: .week, from: "2026-09-01", to: "2026-09-07",
                              total: total, previous: Stats.Day(), daily: [], streak: 0)
        let names = Stats.Presentation.groups(s).flatMap { $0.tiles.map(\.id) }
        for n in ["Files touched", "Co-authored by Claude", "Reverts", "Repos", "Input tokens"] {
            XCTAssertTrue(names.contains(n), n)
        }
        let throughput = Stats.Presentation.groups(s).first { $0.id == "Throughput" }!
        XCTAssertEqual(throughput.tiles.first { $0.id == "Repos" }?.value, "2")
        XCTAssertEqual(throughput.tiles.first { $0.id == "Files touched" }?.value, "12")
    }

    func testActivityTallyAddsAndDecodesForwardCompatibly() throws {
        var a = Stats.ActivityTally(); a.stretches = 1; a.seconds = 30; a.inputTokens = 10; a.outputTokens = 5; a.usd = 0.5
        a.cacheReadTokens = 900; a.cacheWriteTokens = 50; a.cacheSavingsUSD = 0.00162
        var b = Stats.ActivityTally(); b.stretches = 2; b.seconds = 15; b.inputTokens = 1; b.outputTokens = 1; b.usd = 0.25
        b.cacheReadTokens = 10; b.cacheWriteTokens = 1; b.cacheSavingsUSD = 0.0001
        let c = a + b
        XCTAssertEqual(c.stretches, 3); XCTAssertEqual(c.seconds, 45); XCTAssertEqual(c.inputTokens, 11)
        XCTAssertEqual(c.outputTokens, 6); XCTAssertEqual(c.usd, 0.75, accuracy: 1e-9)
        XCTAssertEqual(c.cacheReadTokens, 910); XCTAssertEqual(c.cacheWriteTokens, 51)
        XCTAssertEqual(c.cacheSavingsUSD, 0.00172, accuracy: 1e-9)
        // Short keys on the wire; a newer field is ignored, a missing one defaults.
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertTrue(json.contains("\"n\":1") && json.contains("\"in\":10") && json.contains("\"out\":5"))
        XCTAssertTrue(json.contains("\"cr\":900") && json.contains("\"cw\":50") && json.contains("\"sv\":"))
        // A v8-era tally on the wire, before cr/cw/sv existed, still decodes.
        let sparse = try JSONDecoder().decode(Stats.ActivityTally.self, from: Data(#"{"n":4,"future":9}"#.utf8))
        XCTAssertEqual(sparse.stretches, 4); XCTAssertEqual(sparse.usd, 0)
        XCTAssertEqual(sparse.cacheReadTokens, 0); XCTAssertEqual(sparse.cacheWriteTokens, 0); XCTAssertEqual(sparse.cacheSavingsUSD, 0)
    }

    func testDayAddsActivitiesAndModelsAndDecodesWithoutThem() throws {
        var a = Stats.Day(); a.activities["review"] = tally(usd: 1); a.byModel["claude-opus-5"] = tally(usd: 2)
        var b = Stats.Day(); b.activities["review"] = tally(usd: 3); b.activities["code"] = tally(usd: 4); b.byModel["claude-sonnet-5"] = tally(usd: 5)
        let c = a + b
        XCTAssertEqual(c.activities["review"]?.usd ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(c.activities["code"]?.stretches, 1)
        XCTAssertEqual(Set(c.byModel.keys), ["claude-opus-5", "claude-sonnet-5"])
        // A Day written before v2 (no keys) still decodes.
        let old = try JSONDecoder().decode(Stats.Day.self, from: Data(#"{"commits":3}"#.utf8))
        XCTAssertTrue(old.activities.isEmpty && old.byModel.isEmpty); XCTAssertEqual(old.commits, 3)
    }

    func testCompactedKeepsSixModelsAndFoldsTheRest() {
        var d = Stats.Day()
        for i in 0..<9 { d.byModel["m\(i)"] = tally(usd: Double(i)) }
        d.activities["code"] = tally(usd: 1)
        let c = d.compacted()
        XCTAssertEqual(c.byModel.count, 7)                       // six kept + "other"
        XCTAssertNil(c.byModel["m0"]); XCTAssertNotNil(c.byModel["m8"])
        XCTAssertEqual(c.byModel["other"]?.usd ?? 0, 0 + 1 + 2, accuracy: 1e-9)
        XCTAssertEqual(c.byModel["other"]?.stretches, 3)
        XCTAssertEqual(c.activities["code"]?.usd ?? 0, 1, accuracy: 1e-9)   // activities untouched
        XCTAssertEqual(c.compacted().byModel.count, 7)           // idempotent
    }

    func testActivityTitlesCoverEveryCase() {
        for a in Stats.Activity.allCases { XCTAssertFalse(a.title.isEmpty) }
        XCTAssertEqual(Stats.Activity.other.title, "Other")
        XCTAssertEqual(Stats.Activity(rawValue: "review")?.title, "Code & PR review")
    }

    func testActivitySignalsRuleOneMap() {
        typealias S = StatsScanner.ActivitySignals
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "code-review"]), .review)
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "pr-review-toolkit:review-pr"]), .review)
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "superpowers:brainstorming"]), .plan)
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "superpowers:writing-plans"]), .plan)
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "superpowers:systematic-debugging"]), .debug)
        XCTAssertEqual(S.label(tool: "Skill", input: ["skill": "playwright-cli"]), .browser)
        XCTAssertNil(S.label(tool: "Skill", input: ["skill": "sync-main"]))
        XCTAssertEqual(S.label(tool: "Agent", input: ["subagent_type": "pr-review-toolkit:code-reviewer"]), .review)
        XCTAssertEqual(S.label(tool: "Agent", input: ["subagent_type": "silent-failure-hunter"]), .review)
        XCTAssertEqual(S.label(tool: "Agent", input: ["subagent_type": "pr-test-analyzer"]), .review)
        XCTAssertNil(S.label(tool: "Agent", input: ["subagent_type": "coder"]))
        XCTAssertEqual(S.label(tool: "EnterPlanMode", input: [:]), .plan)
        XCTAssertEqual(S.label(tool: "ReportFindings", input: [:]), .review)
        XCTAssertEqual(S.label(tool: "mcp__claude-in-chrome__navigate", input: [:]), .browser)
        XCTAssertEqual(S.label(tool: "computer", input: [:]), .browser)
        XCTAssertEqual(S.label(tool: "Bash", input: ["command": "xcrun simctl boot 'iPhone 16'"]), .simulator)
        XCTAssertEqual(S.label(tool: "Bash", input: ["command": "xcodebuild -destination 'platform=iOS Simulator,name=X' build"]), .simulator)
        XCTAssertEqual(S.label(tool: "Bash", input: ["command": "xcrun devicectl device install app --device 1 x.app"]), .simulator)
        XCTAssertEqual(S.label(tool: "Bash", input: ["command": "gh pr diff 12"]), .review)
        XCTAssertNil(S.label(tool: "Bash", input: ["command": "swift test"]))
        XCTAssertNil(S.label(tool: "Edit", input: ["file_path": "/r/Tests/ATests.swift"]))
    }

    func testActivitySignalsTestPathConvention() {
        typealias S = StatsScanner.ActivitySignals
        for p in ["/r/Tests/InfinitusCoreTests/StatsTests.swift", "/r/src/FooTest.swift", "/r/web/__tests__/a.ts",
                  "/r/web/a.test.ts", "/r/web/a.spec.js", "/r/py/tests/test_x.py", "/r/py/test_x.py", "/r/go/x_test.go",
                  "/r/spec/models/user_spec.rb"] {
            XCTAssertTrue(S.isTestPath(p), p)
        }
        for p in ["/r/Sources/InfinitusCore/Stats.swift", "/r/web/a.ts", "/r/testing-notes.md", "/r/contest/a.py",
                  "/r/Sources/Latest.swift", "/r/Contest.swift"] {
            XCTAssertFalse(S.isTestPath(p), p)
        }
    }

    func testStretchLabelRulesInOrder() {
        var s = StatsScanner.Stretch(dayKey: "2026-09-04", at: 0)
        XCTAssertEqual(s.activity, .other)                        // nothing happened
        s.endedInProse = true
        XCTAssertEqual(s.activity, .explanation)                  // prose, no edits, no Bash
        s.bash = 1
        XCTAssertEqual(s.activity, .code)                         // a command ran
        s.edits = 2; s.testEdits = 2
        XCTAssertEqual(s.activity, .tests)                        // every edit is a test file
        s.testEdits = 1
        XCTAssertEqual(s.activity, .code)                         // a mix
        s.promptLabel = "debug"
        XCTAssertEqual(s.activity, .debug)                        // the person's words beat the path rules
        s.label = "review"
        XCTAssertEqual(s.activity, .review)                       // rule 1 beats everything
        s.label = "not-a-label"
        XCTAssertEqual(s.activity, .debug)                        // unknown label → rule 0, then the path rules
        s.promptLabel = nil
        XCTAssertEqual(s.activity, .code)
    }

    func testActivitySignalsPromptIntent() {
        typealias S = StatsScanner.ActivitySignals
        XCTAssertEqual(S.label(prompt: "Review PR #42 for me"), .review)
        XCTAssertEqual(S.label(prompt: "review the plan before we start"), .review)
        XCTAssertEqual(S.label(prompt: "Plan the tests for the new parser"), .plan)
        XCTAssertEqual(S.label(prompt: "add tests for SessionStart"), .tests)
        XCTAssertEqual(S.label(prompt: "the app crashes on launch, why?"), .debug)
        XCTAssertEqual(S.label(prompt: "Why is the build failing"), .debug)
        XCTAssertEqual(S.label(prompt: "open the website and check the login form"), .browser)
        XCTAssertEqual(S.label(prompt: "run it on the simulator"), .simulator)
        XCTAssertEqual(S.label(prompt: "Explain how the mirror server routes requests"), .explanation)
        XCTAssertNil(S.label(prompt: "rename the button"))
        XCTAssertNil(S.label(prompt: "previewer"))                                     // whole words only
        XCTAssertNil(S.label(prompt: String(repeating: "x ", count: 300) + "explain"))  // past the opening
    }

    func testIngestReadsThePromptIntentOffTheOpeningMessage() {
        var e = StatsScanner.FileEntry()
        let lines = [
            #"{"type":"user","timestamp":"2026-09-05T01:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"debug the crash on launch"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-05T01:00:10.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/r/Sources/A.swift"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-05T01:05:00.000Z","origin":{"kind":"peer","from":"uds:/tmp/infinitus-1.sock"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus\" from-mode=\"bypass\">\nexplain the feed\n</cross-session-message>"}}"#,
        ]
        for line in lines { StatsScanner.ingest(entry(line), sessionID: "s1", into: &e, calendar: cal) }
        let day = try! XCTUnwrap(e.days["2026-09-05"])
        XCTAssertEqual(day.activities["debug"]?.stretches, 1)     // edits alone would have said "code"
        XCTAssertEqual(e.state.stretch?.promptLabel, "explanation")
    }

    func testDayAddStretchFeedsActivitiesAndModelStretchCounts() {
        var s = StatsScanner.Stretch(dayKey: "2026-09-04", at: 100)
        s.lastAt = 160; s.entries = 3; s.model = "claude-opus-5"; s.inputTokens = 10; s.outputTokens = 5; s.usd = 0.5; s.label = "plan"
        var d = Stats.Day()
        d.byModel["claude-opus-5"] = { var t = Stats.ActivityTally(); t.inputTokens = 10; t.outputTokens = 5; t.usd = 0.5; return t }()
        d.add(stretch: s)
        let plan = d.activities["plan"]!
        XCTAssertEqual(plan.stretches, 1); XCTAssertEqual(plan.seconds, 60); XCTAssertEqual(plan.inputTokens, 10)
        XCTAssertEqual(plan.outputTokens, 5); XCTAssertEqual(plan.usd, 0.5, accuracy: 1e-9)
        let opus = d.byModel["claude-opus-5"]!
        XCTAssertEqual(opus.stretches, 1); XCTAssertEqual(opus.seconds, 60)
        XCTAssertEqual(opus.inputTokens, 10)                      // tokens were already there — not doubled
        // A stretch that never saw a usage entry has no model: activities only.
        var bare = StatsScanner.Stretch(dayKey: "2026-09-04", at: 0); bare.lastAt = 5; bare.entries = 1
        var e = Stats.Day(); e.add(stretch: bare)
        XCTAssertEqual(e.activities["other"]?.stretches, 1); XCTAssertTrue(e.byModel.isEmpty)
        // A stretch with no assistant entry at all is not effort.
        var empty = Stats.Day(); empty.add(stretch: StatsScanner.Stretch(dayKey: "2026-09-04", at: 0))
        XCTAssertTrue(empty.activities.isEmpty)
    }

    private func tally(usd: Double) -> Stats.ActivityTally {
        var t = Stats.ActivityTally(); t.stretches = 1; t.seconds = 60; t.inputTokens = 100; t.outputTokens = 10; t.usd = usd
        return t
    }

    func testPresentationActivityAndModelRows() {
        var d = Stats.Day()
        d.activities["code"] = tally(usd: 3)
        d.activities["review"] = tally(usd: 1)
        d.byModel["claude-opus-4-5-20250805"] = tally(usd: 2)
        d.byModel["claude-sonnet-5"] = tally(usd: 6)
        d.byModel["other"] = tally(usd: 0.5)
        let s = Stats.fold(days: ["2026-09-04": d], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let rows = Stats.Presentation.activityRows(s)
        XCTAssertEqual(rows.map(\.id), ["Code & PR review", "Coding"])          // catalogue order, zero rows dropped
        XCTAssertEqual(rows[0].count, 1); XCTAssertEqual(rows[0].minutes, 1); XCTAssertEqual(rows[0].tokens, 110)
        XCTAssertEqual(rows[0].share, 0.25, accuracy: 1e-9); XCTAssertEqual(rows[0].usdText, "$1.00")
        XCTAssertEqual(rows[1].share, 0.75, accuracy: 1e-9)
        let models = Stats.Presentation.modelRows(s)
        XCTAssertEqual(models.map(\.id), ["Sonnet 5", "Opus 4.5", "Other models"])   // by $ desc, "other" last
        XCTAssertEqual(models[0].share, 6 / 8.5, accuracy: 1e-9)
        XCTAssertTrue(Stats.Presentation.activityRows(Stats.fold(days: [:], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)).isEmpty)
        XCTAssertTrue(Stats.Presentation.activityFootnote.lowercased().contains("heuristic"))
    }

    func testPresentationModelRowsMergeAliasesAndCapAtSix() {
        var d = Stats.Day()
        d.byModel["claude-opus-5"] = tally(usd: 2)
        d.byModel["claude-opus-5[1m]"] = tally(usd: 3)
        let s = Stats.fold(days: ["2026-09-04": d], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let rows = Stats.Presentation.modelRows(s)
        XCTAssertEqual(rows.map(\.id), ["Opus 5"])
        XCTAssertEqual(rows[0].usd, 5, accuracy: 1e-9)
        XCTAssertEqual(rows[0].share, 1, accuracy: 1e-9)

        var e = Stats.Day()
        for i in 0..<8 { e.byModel["claude-m\(i)-1"] = tally(usd: Double(i + 1)) }
        let s2 = Stats.fold(days: ["2026-09-04": e], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let rows2 = Stats.Presentation.modelRows(s2)
        XCTAssertEqual(rows2.count, 7)   // 6 named + "Other models"
        XCTAssertEqual(rows2.last?.id, "Other models")
        XCTAssertEqual(rows2.last?.usd ?? -1, 1 + 2, accuracy: 1e-9)   // the two smallest folded
    }

    func testModelRowsShareFallsBackToTokensWhenUsdIsZero() {
        var d = Stats.Day()
        var t = Stats.ActivityTally(); t.inputTokens = 100; t.outputTokens = 10; t.usd = 0
        d.byModel["unknown-model"] = t
        let s = Stats.fold(days: ["2026-09-04": d], period: .day, now: date("2026-09-04T03:00:00Z"), calendar: cal)
        let rows = Stats.Presentation.modelRows(s)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].share, 1, accuracy: 1e-9)
    }

    func testPresentationModelTitles() {
        XCTAssertEqual(Stats.Presentation.modelTitle("claude-opus-4-5-20250805"), "Opus 4.5")
        XCTAssertEqual(Stats.Presentation.modelTitle("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(Stats.Presentation.modelTitle("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(Stats.Presentation.modelTitle("claude-fable-5[1m]"), "Fable 5")
        XCTAssertEqual(Stats.Presentation.modelTitle("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(Stats.Presentation.modelTitle("gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(Stats.Presentation.modelTitle("other"), "Other models")
    }

    func testPresentationRowTextFormats() {
        var t = Stats.ActivityTally(); t.stretches = 2; t.seconds = 7_500; t.inputTokens = 1_234_000; t.outputTokens = 56_000; t.usd = 123.4
        let row = Stats.Presentation.Row(id: "x", tally: t, share: 0.5)
        XCTAssertEqual(row.minutesText, "2 h 5 m")
        XCTAssertEqual(row.tokensText, "1.3M")
        XCTAssertEqual(row.usdText, "$123")
        var small = Stats.ActivityTally(); small.seconds = 90; small.inputTokens = 900; small.usd = 0.5
        let srow = Stats.Presentation.Row(id: "y", tally: small, share: 0)
        XCTAssertEqual(srow.minutesText, "1 min"); XCTAssertEqual(srow.tokensText, "900"); XCTAssertEqual(srow.usdText, "$0.50")
        var mid = Stats.ActivityTally(); mid.inputTokens = 45_600
        XCTAssertEqual(Stats.Presentation.Row(id: "z", tally: mid, share: 0).tokensText, "46k")
        // Untracked cache (e.g. per-activity tallies, #139): "—", not "0%" —
        // the data was never counted, it isn't zero.
        XCTAssertNil(row.cachedShare)
        XCTAssertEqual(row.cachedPercentText, "—"); XCTAssertEqual(row.cachedSuffixText, "")
        var cached = Stats.ActivityTally(); cached.inputTokens = 100; cached.cacheReadTokens = 900; cached.cacheWriteTokens = 50
        let crow = Stats.Presentation.Row(id: "w", tally: cached, share: 0)
        XCTAssertEqual(crow.cachedShare ?? 0, 900.0 / 1050.0, accuracy: 1e-9)
        XCTAssertEqual(crow.cachedPercentText, "86%"); XCTAssertEqual(crow.cachedSuffixText, " · cached 86%")
    }

    func testTokenRecordsWalkTheDaysInOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Stats.date(fromDayKey: "2026-09-05", calendar: calendar)!.addingTimeInterval(12 * 3600)
        func day(_ peak: Int) -> Stats.Day { var d = Stats.Day(); d.peakTokensPerMinute = peak; return d }
        let days: [String: Stats.Day] = [
            "2026-08-01": day(500), "2026-08-10": day(400), "2026-08-20": day(900),
            "2026-09-01": day(950), "2026-09-05": day(300),
        ]
        let r = Stats.TokenRecords(days: days, now: now, calendar: calendar)
        XCTAssertEqual(r.best?.day, "2026-09-01")
        XCTAssertEqual(r.best?.tokensPerMinute, 950)
        XCTAssertEqual(r.records.map(\.day), ["2026-09-01", "2026-08-20", "2026-08-01"])
        XCTAssertEqual(r.recordsThisMonth, 1)
        XCTAssertEqual(r.today, 300)
        XCTAssertEqual(r.dailyPeaks.count, 30)
        XCTAssertNil(r.trend)   // the week before last had no busy day in the 30-day window's last 14
    }

    func testDayPeakIsTheSumAcrossFilesForTheSameMinute() {
        var a = Stats.Day(); a.minuteTokens = [600: 100, 601: 40]
        var b = Stats.Day(); b.minuteTokens = [600: 80]
        var merged = a + b
        merged.finalizePeak()
        XCTAssertEqual(merged.peakTokensPerMinute, 180)
        XCTAssertEqual(merged.peakMinute, 600)
        XCTAssertTrue(merged.compacted().minuteTokens.isEmpty)
        XCTAssertEqual(merged.compacted().peakTokensPerMinute, 180)
        XCTAssertEqual(Stats.minuteOfDay(0, calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()), 0)
    }
}

extension StatsTests {
    /// The formatter-free timestamp path agrees with ISO8601DateFormatter
    /// to the millisecond, and leaves every other shape to it.
    func testFastStampMatchesTheFormatter() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for s in ["2026-09-05T04:02:47.463Z", "2026-09-05T04:02:47Z", "2000-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z",
                  "2024-03-01T12:00:00.5Z", "2026-12-31T23:59:59Z"] {
            let expect = (f.date(from: s) ?? plain.date(from: s))?.timeIntervalSince1970
                ?? ISO8601DateFormatter().date(from: s.replacingOccurrences(of: ".5Z", with: "Z"))!.timeIntervalSince1970 + 0.5
            XCTAssertEqual(TokenRateScanner.fastStamp(s)!, expect, accuracy: 0.0005, s)
            XCTAssertEqual(TokenRateScanner.parseStamp(s)!, expect, accuracy: 0.0005, s)
        }
        XCTAssertNil(TokenRateScanner.fastStamp("2026-09-05T04:02:47+07:00"))
        XCTAssertNil(TokenRateScanner.fastStamp("2026-13-05T04:02:47Z"))
        XCTAssertNil(TokenRateScanner.fastStamp("nope"))
        XCTAssertNotNil(TokenRateScanner.parseStamp("2026-09-05T04:02:47+07:00"), "the formatter still takes offsets")
    }

    func testByteScanAnchorsOnARareByteAndFindsEveryOccurrence() {
        let hay = Array(#"{"a":"yes","type":"user","x":"type\":\"user"}"#.utf8)
        let needle = ByteScan.Needle(#""type":"user""#)
        XCTAssertEqual(needle.bytes[needle.anchor], UInt8(ascii: "y"))
        hay.withUnsafeBytes { buf in
            XCTAssertEqual(ByteScan.firstIndex(of: needle, in: buf), 11)
            XCTAssertEqual(ByteScan.lastIndex(of: needle, in: buf), 11)
            XCTAssertEqual(ByteScan.count(needle, in: buf), 1)
            XCTAssertNil(ByteScan.firstIndex(of: needle, in: buf, from: 12))
            XCTAssertTrue(ByteScan.contains(ByteScan.Needle("yes"), in: buf))
            XCTAssertFalse(ByteScan.contains(ByteScan.Needle("yesx"), in: buf))
            XCTAssertEqual(ByteScan.count(ByteScan.Needle("\""), in: buf), 14)
        }
    }
}
