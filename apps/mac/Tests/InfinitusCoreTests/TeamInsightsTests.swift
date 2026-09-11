import XCTest
@testable import InfinitusCore

final class TeamInsightsTests: XCTestCase {
    // Fixed clock: Sat 2026-09-05 12:00 UTC; the calendar is UTC so day keys are stable.
    let now = Date(timeIntervalSince1970: 1_788_609_600)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }

    let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random()
    var roster: TeamRoster {
        TeamRoster(id: "t", name: "T", createdAt: 1,
                   leaders: [TeamRoster.Member(keys: l.keys, name: "Lee", since: 1, founder: true)],
                   members: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 2), TeamRoster.Member(keys: b.keys, name: "Bo", since: 3)],
                   policy: TeamRoster.Policy(requests: "code", membersSeeEachOther: false), rev: 2)
    }

    func entry(_ path: String, _ kind: String, _ from: String, _ at: Int, to: [Envelope.Recipient] = []) -> (entry: StoreEntry, header: Envelope.Header) {
        (StoreEntry(path: path, size: 1, version: "v"), Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: to, at: at, nonce: "", sig: nil))
    }

    /// Each fixture doc's audience: Ann shares stats to the team and transcripts to Lee + Bo; everything else goes to leaders.
    func audience(_ path: String, _ kind: String) -> [Envelope.Recipient] {
        let target: TeamRoster.ShareTarget = path.hasPrefix("m/\(a.kid)/") && kind == "stats" ? .team
            : path.hasPrefix("m/\(a.kid)/") && kind == "transcripts" ? .members([l.kid, b.kid]) : .leaders
        return roster.recipients(for: target).map { Envelope.Recipient(kid: $0.kid, wrap: "") }
    }

    /// Ann: 2 days this week ($3 + $1, 3 commits), busy now with one blocker; Bo: $10 last month only, stale now; Lee: nothing.
    /// `as` folds only the envelopes that name that kid, the way `readableHeaders` does; Lee (the default) is in every audience.
    func reader(as me: String? = nil) throws -> TeamReader {
        var d1 = Stats.Day(); d1.usd = 3; d1.commits = 2; d1.humanMessages = 5; d1.outputTokens = 100; d1.hours[10] = 4; d1.repos = ["app"]
        var opus = Stats.ActivityTally(); opus.stretches = 1; opus.seconds = 1; opus.inputTokens = 1; opus.outputTokens = 1; opus.usd = 1
        var d2 = Stats.Day(); d2.usd = 1; d2.commits = 1; d2.byModel = ["claude-opus-5": opus]
        var old = Stats.Day(); old.usd = 10; old.commits = 9
        let nowSec = Int(now.timeIntervalSince1970)
        var s1 = TeamDocs.SessionRow(id: "s1", project: "app", engine: "claude"); s1.startedAt = nowSec - 3_600; s1.usd = 2.5; s1.busyMinutes = 30
        var s2 = TeamDocs.SessionRow(id: "s2", project: "site", engine: "claude"); s2.startedAt = nowSec - 40 * 86_400; s2.usd = 9; s2.busyMinutes = 200
        var s3 = TeamDocs.SessionRow(id: "s3", project: "app", engine: "codex"); s3.startedAt = nowSec - 7_200; s3.usd = 0.5; s3.busyMinutes = 10
        let docs: [String: Data] = [
            "m/\(a.kid)/days/2026-09-04.json": try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-04", stats: d1)),
            "m/\(a.kid)/days/2026-09-05.json": try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-05", stats: d2)),
            "m/\(b.kid)/days/2026-08-01.json": try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-08-01", stats: old)),
            "m/\(a.kid)/now.json": try CanonicalJSON.encode(TeamDocs.Now(at: nowSec - 60, sessions: [TeamDocs.LiveSession(id: "s1", project: "app", status: "waiting")],
                                                                        fleets: [], blockers: ["AWS login: prod"], crashesToday: 2,
                                                                        sharesTo: ["stats": .team, "transcripts": .members([l.kid, b.kid]), "now": .leaders])),
            "m/\(b.kid)/now.json": try CanonicalJSON.encode(TeamDocs.Now(at: nowSec - 3_600, sessions: [TeamDocs.LiveSession(id: "x", project: "site", status: "busy")],
                                                                        fleets: [], blockers: ["cswap: every account limited"], crashesToday: 0, sharesTo: ["stats": .leaders])),
            "m/\(a.kid)/sessions/index.json": try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: nowSec, sessions: [s1, s3], fleets: [])),
            "m/\(b.kid)/sessions/index.json": try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: nowSec, sessions: [s2], fleets: [])),
            "m/\(a.kid)/crashes.json": try CanonicalJSON.encode(TeamDocs.Crashes(crashes: ["Mac · crash · x", "Mac · crash · y"])),
            "m/\(a.kid)/transcripts/s1/0.jsonl": Data(),
        ]
        let headers = docs.keys.sorted().map { path -> (entry: StoreEntry, header: Envelope.Header) in
            let kind = path.contains("/days/") ? "stats" : path.hasSuffix("now.json") ? "now" : path.contains("/sessions/") ? "sessions"
                : path.contains("/transcripts/") ? "transcripts" : "crashes"
            return entry(path, kind, path.split(separator: "/")[1].description, nowSec - 60, to: audience(path, kind))
        }
        .filter { me == nil || $0.header.to.contains { $0.kid == me } }
        return TeamReader.fold(headers: headers, roster: roster) { docs[$0]! }
    }

    func testComparisonOrdersLeadersFirstAndFoldsThePeriod() throws {
        let rows = TeamInsights.comparison(try reader(), period: .week, now: now, calendar: cal)
        XCTAssertEqual(rows.map(\.name), ["Lee", "Ann", "Bo"])
        let ann = rows[1]
        XCTAssertEqual(ann.summary.total.usd, 4, accuracy: 0.001)
        XCTAssertEqual(ann.summary.total.commits, 3)
        XCTAssertTrue(ann.online); XCTAssertEqual(ann.sessionsNow, 1); XCTAssertEqual(ann.blockers, ["AWS login: prod"]); XCTAssertEqual(ann.crashes, 2)
        XCTAssertFalse(rows[2].online, "an hour-old now.json is stale")
        XCTAssertEqual(rows[2].summary.total.usd, 0, "Bo's August day is outside this week")
        XCTAssertEqual(rows[0].summary.total.usd, 0)
    }

    func testLeaderboardsSortDescendingWithNameTiebreak() throws {
        let rows = TeamInsights.comparison(try reader(), period: .month, now: now, calendar: cal)
        let usd = TeamInsights.leaderboard(rows, metric: .usd)
        XCTAssertEqual(usd.map(\.name), ["Ann", "Bo", "Lee"])   // 4, 0, 0 → Bo before Lee by name
        XCTAssertEqual(usd[0].value, 4, accuracy: 0.001)
        XCTAssertEqual(TeamInsights.leaderboard(rows, metric: .commits).first?.value, 3)
        XCTAssertEqual(TeamInsights.Metric.waitingMinutes.value({ var d = Stats.Day(); d.waitingSeconds = 120; return d }()), 2)
        XCTAssertEqual(TeamInsights.Metric.allCases.count, 9)
    }

    func testReposCoverThePeriodFromSessionIndexes() throws {
        let repos = TeamInsights.repos(try reader(), period: .week, now: now, calendar: cal)
        XCTAssertEqual(repos.map(\.project), ["app"], "Bo's site session is 40 days old")
        XCTAssertEqual(repos[0].usd, 3, accuracy: 0.001)
        XCTAssertEqual(repos[0].minutes, 40)
        XCTAssertEqual(repos[0].members.map(\.name), ["Ann"])
        XCTAssertEqual(repos[0].members[0].usd, 3, accuracy: 0.001)
        let year = TeamInsights.repos(try reader(), period: .year, now: now, calendar: cal)
        XCTAssertEqual(year.map(\.project), ["site", "app"], "by effort, descending")
    }

    func testBlockersBoardListsOnlyFreshMembers() throws {
        let board = TeamInsights.blockers(try reader(), now: now)
        XCTAssertEqual(board.map { "\($0.name):\($0.kind)" }, ["Ann:aws", "Ann:waiting", "Ann:crash"])
        XCTAssertEqual(board[1].text, "app is waiting for you")
        XCTAssertEqual(board[2].text, "2 crashes today")
        XCTAssertEqual(board[0].text, "AWS login: prod")
    }

    func testCostHoursAndWhoIsOn() throws {
        let r = try reader()
        let rows = TeamInsights.comparison(r, period: .week, now: now, calendar: cal)
        let cost = TeamInsights.cost(rows, repos: TeamInsights.repos(r, period: .week, now: now, calendar: cal))
        XCTAssertEqual(cost.total, 4, accuracy: 0.001)
        XCTAssertEqual(cost.byMember.map(\.name), ["Ann", "Bo", "Lee"])
        XCTAssertEqual(cost.byModel["claude-opus-5"] ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(cost.byRepo["app"] ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(TeamInsights.hours(rows)[10], 4)
        XCTAssertEqual(TeamInsights.hours(rows).count, 168)
        XCTAssertEqual(TeamInsights.whoIsOn(r, now: now).map(\.name), ["Ann"])
    }

    func testSharedWithMeReadsEachTeammatesAudiences() throws {
        func shared(_ me: String) throws -> [String] {
            TeamInsights.sharedWithMe(try reader(as: me), roster: roster, me: me).map { "\($0.name):\($0.kinds.joined(separator: ","))" }
        }
        XCTAssertEqual(try shared(l.kid), ["Ann:crashes,now,sessions,stats,transcripts", "Bo:now,sessions,stats"], "a leader is in every audience")
        XCTAssertEqual(try shared(b.kid), ["Ann:stats,transcripts"], "Bo is named for transcripts, in the team for stats, not a leader for the rest")
        XCTAssertEqual(try shared(a.kid), ["Bo:"], "never myself; Bo shares nothing with Ann → empty kinds row")
        // The envelope recipients are the truth, never the now.sharesTo hint:
        // Ann's hint names Bo for transcripts, but Bo's reader holds only a
        // now envelope, so that is the one kind listed.
        let unaddressed = TeamReader.fold(headers: [entry("m/\(a.kid)/now.json", "now", a.kid, 1)], roster: roster) { _ in
            try CanonicalJSON.encode(TeamDocs.Now(at: 1, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: ["transcripts": .members([b.kid])]))
        }
        XCTAssertEqual(TeamInsights.sharedWithMe(unaddressed, roster: roster, me: b.kid).map(\.kinds), [["now"]])
    }
}
