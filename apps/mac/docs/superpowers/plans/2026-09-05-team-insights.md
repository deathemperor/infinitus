# Team insights — comparison, leaderboards, coverage, blockers, aggregates, members' view, policy (plan 9, core half) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything a leader (and the team) sees, computed once in InfinitusCore from a `TeamReader`: per-member comparison rows for a period, leaderboards by metric, repo coverage (who works where, effort per repo), a blockers board, cost by member / model / repo, the team hours heatmap, who is on now, and what each teammate shares with me; leaders publish `roster/aggregates/<period>.json` (wrapped to the team, per-member rows only when the roster's `membersSeeEachOther` is on) and every member reads it back; leaders set the roster policy; `infinitusctl team members --period|insights|aggregates [publish]|policy` expose it all. The Mac pane and the phone render these next round.

**Architecture:** `TeamInsights` (new, pure functions over `TeamReader` + `TeamRoster`), `TeamDocs.Aggregates` (new schema-1 document), `TeamClient.publishAggregates` + `setPolicy` + the `requests: off` rule (appended to `TeamClient`), `TeamReader.aggregates` (folded only from leaders), CLI subcommands in one contiguous block. No app UI, no phone.

**Tech Stack:** Swift 5.9 syntax (6.1 on Linux CI), the plan-1/2 Team stack, `Stats.fold` / `Stats.Day +`, XCTest with the membership tests' bare-remote helper.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` §5 roster policy, §8.2 per-member insights (the folding half; the "jump from a stat to the stretch" UI is the pane's), §8.3 team insights + aggregates, §8.4 members' view, §9 CLI, §11 unit + integration, §12 step 9. GitHub #55 notes for the parked pieces.

## Global Constraints

- Worktree `/Users/deathemperor/death/limitless-t-insights`, branch `team-insights`, branched from main `1a850a3`; stage by explicit path; every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; push nothing.
- **File ownership this round (three streams in parallel; the merge must be trivial).** This stream edits ONLY: `Sources/InfinitusCore/Team/TeamInsights.swift` (new), `TeamDocs.swift` (append `Aggregates`), `TeamReader.swift`, `TeamClient.swift` (new methods inserted directly BEFORE `public func status()`; `requests()` and `code()` gain one guard line each; `ClientError` gains `requestsOff`), `Sources/InfinitusCLI/TeamCommand.swift` (edit `case "members":` in place; insert new cases directly AFTER the `case "reshare":` block, before `default:`; the usage text), tests, CHANGELOG. Never `TeamKinds.swift` (it already knows `aggregates` under `roster/`), `TeamSnapshot.swift`, `Base32.swift`, `ControlProtocol.swift`, anything under `Sources/Infinitus/`, `e2e.sh`, `make-app.sh`. The pane stream owns `create`/`code(nonce:)`/`leave()` in `TeamClient` — keep clear of those hunks.
- No cswap anywhere; never read engine internals; never `~/.aws/login` or `~/.aws/sso`.
- Every InfinitusCore/InfinitusCLI file compiles on Linux; `Crypto.SHA256` fully qualified; canonical JSON for signed docs (`Signed<TeamRoster>` carries no floats — the policy edit keeps that); envelope plaintext may carry `Double`s (aggregates do).
- **Aggregates are leaders' documents:** written only by `isLeader`, under `roster/aggregates/<period>.json`, audience `.team`; readers keep an aggregates doc only when `roster.isLeader(header.from)` at `header.at` — a member who writes there is ignored, with a test proving it.
- **Per-member detail in aggregates only under `policy.membersSeeEachOther`** (spec §8.4); otherwise totals, repos, hours and names-on-now only.
- Money figures are the app's estimates (usage-cost caveat), never billing truth — say so in the CLI usage line.
- Verification is `swift test` in this worktree only; never `tools/e2e.sh`; never `swift build --product Infinitus` is needed (no app files change), but run it once in the final task to be sure nothing under `Sources/Infinitus` broke on a `TeamReader` signature.
- Implementers spawn no subagents.
- CHANGELOG: one feature, one line, under a `### Team (preview)` heading in **`## 0.4.4 (unreleased)`** (0.4.3 shipped; add the heading directly before `## 0.4.3` if it is not there yet).

---

## File structure

| file | responsibility |
|---|---|
| `Sources/InfinitusCore/Team/TeamInsights.swift` (new) | `comparison`, `Metric` + `leaderboard`, `repos`, `blockers`, `cost`, `hours`, `whoIsOn`/`isOn`, `sharedWithMe`, `aggregates(...)` |
| `Sources/InfinitusCore/Team/TeamDocs.swift` (append) | `TeamDocs.Aggregates` (+ `Repo`, `MemberTotal`) |
| `Sources/InfinitusCore/Team/TeamClient.swift` (modify) | `publishAggregates(_:now:)`, `setPolicy(_:)`, `readableHeaders` lists `roster/aggregates/`, `requests()`/`code()` honour `policy.requests == "off"` |
| `Sources/InfinitusCore/Team/TeamReader.swift` (modify) | `aggregates: [String: TeamDocs.Aggregates]` folded from leaders only |
| `Sources/InfinitusCLI/TeamCommand.swift` (modify) | `members --period`, `insights`, `aggregates [publish]`, `policy` |
| `Tests/InfinitusCoreTests/TeamInsightsTests.swift` (new), `TeamAggregatesTests.swift` (new) | tests |
| `CHANGELOG.md` | two lines |

---

### Task 1: `TeamInsights` — the pure computations

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamInsights.swift`
- Test: `Tests/InfinitusCoreTests/TeamInsightsTests.swift`

**Interfaces:**
- Consumes: `TeamReader` (`members`, `.Member.days/now/sessions/crashes/lastPublished`), `TeamRoster` (`isLeader`, `everyone`), `TeamDocs.Now/LiveSession/SessionRow`, `Stats.fold(days:period:now:calendar:)`, `Stats.Day`, `Stats.date(fromDayKey:calendar:)`.
- Produces: `TeamInsights.MemberRow`, `comparison(_:period:now:calendar:)`, `Metric` (`usd, outputTokens, commits, prsMerged, linesAdded, messages, toolCalls, waitingMinutes, sessions`; `title`, `value(_ day:)`), `LeaderboardRow`, `leaderboard(_:metric:)`, `RepoRow` (+ `Share`), `repos(_:period:now:calendar:)`, `Blocker`, `blockers(_:now:)`, `Cost`, `cost(_:repos:)`, `hours(_:)`, `onlineWindow = 900`, `isOn(_:now:)`, `whoIsOn(_:now:)`, `ShareRow`, `sharedWithMe(_:roster:me:)`.

- [ ] **Step 1: Failing tests**

Create `Tests/InfinitusCoreTests/TeamInsightsTests.swift`:

```swift
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

    func entry(_ path: String, _ kind: String, _ from: String, _ at: Int) -> (entry: StoreEntry, header: Envelope.Header) {
        (StoreEntry(path: path, size: 1, version: "v"), Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: [], at: at, nonce: "", sig: nil))
    }

    /// Ann: 2 days this week ($3 + $1, 3 commits), busy now with one blocker; Bo: $10 last month only, stale now; Lee: nothing.
    func reader() throws -> TeamReader {
        var d1 = Stats.Day(); d1.usd = 3; d1.commits = 2; d1.humanMessages = 5; d1.outputTokens = 100; d1.hours[10] = 4; d1.repos = ["app"]
        var d2 = Stats.Day(); d2.usd = 1; d2.commits = 1; d2.byModel = ["claude-opus-5": Stats.ActivityTally(stretches: 1, seconds: 1, inputTokens: 1, outputTokens: 1, usd: 1)]
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
        ]
        let headers = docs.keys.sorted().map { path -> (entry: StoreEntry, header: Envelope.Header) in
            let kind = path.contains("/days/") ? "stats" : path.hasSuffix("now.json") ? "now" : path.contains("/sessions/") ? "sessions" : "crashes"
            return entry(path, kind, path.split(separator: "/")[1].description, nowSec - 60)
        }
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
        let r = try reader()
        XCTAssertEqual(TeamInsights.sharedWithMe(r, roster: roster, me: l.kid).map { "\($0.name):\($0.kinds.joined(separator: ","))" },
                       ["Ann:now,stats,transcripts", "Bo:stats"])
        XCTAssertEqual(TeamInsights.sharedWithMe(r, roster: roster, me: b.kid).map { "\($0.name):\($0.kinds.joined(separator: ","))" },
                       ["Ann:stats,transcripts"], "Bo is named for transcripts, in the team for stats, not a leader for now")
        XCTAssertEqual(TeamInsights.sharedWithMe(r, roster: roster, me: a.kid).map(\.name), ["Bo"], "never myself; Bo shares nothing with Ann → empty kinds row")
        XCTAssertEqual(TeamInsights.sharedWithMe(r, roster: roster, me: a.kid)[0].kinds, [])
    }
}
```

Run: `cd /Users/deathemperor/death/limitless-t-insights && swift test --filter TeamInsightsTests 2>&1 | tail -3` — expected: compile failure.

- [ ] **Step 2: Implement**

Create `Sources/InfinitusCore/Team/TeamInsights.swift`:

```swift
import Foundation

/// Spec §8.2–8.4, computed from a `TeamReader` — pure, so the pane, the
/// phone (via aggregates) and the CLI agree. Money is the app's own
/// estimate (usage-cost caveat), never billing truth.
public enum TeamInsights {
    // MARK: comparison

    public struct MemberRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var role: String
        public var summary: Stats.Summary
        public var online: Bool
        public var sessionsNow: Int
        public var blockers: [String]
        public var crashes: Int
        public var lastPublished: Int?
    }

    /// One row per roster member (and per removed sender still readable),
    /// leaders first, then by name.
    public static func comparison(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                                  calendar: Calendar = .current) -> [MemberRow] {
        reader.members.values.map { m in
            MemberRow(kid: m.kid, name: m.name, role: m.role,
                      summary: Stats.fold(days: m.days, period: period, now: now, calendar: calendar),
                      online: isOn(m, now: now), sessionsNow: m.now?.sessions.count ?? 0,
                      blockers: m.now?.blockers ?? [], crashes: m.crashes.count, lastPublished: m.lastPublished)
        }
        .sorted { x, y in
            if x.role != y.role { return x.role == "leader" }
            return x.name == y.name ? x.kid < y.kid : x.name < y.name
        }
    }

    // MARK: who is on

    /// A `now.json` older than this is stale: the member is off.
    public static let onlineWindow = 15 * 60

    public static func isOn(_ m: TeamReader.Member, now: Date) -> Bool {
        guard let n = m.now else { return false }
        return Int(now.timeIntervalSince1970) - n.at <= onlineWindow && !n.sessions.isEmpty
    }

    public static func whoIsOn(_ reader: TeamReader, now: Date = Date()) -> [TeamReader.Member] {
        reader.members.values.filter { isOn($0, now: now) }.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }

    // MARK: leaderboards

    public enum Metric: String, CaseIterable, Codable, Sendable {
        case usd, outputTokens, commits, prsMerged, linesAdded, messages, toolCalls, waitingMinutes, sessions

        public var title: String {
            switch self {
            case .usd: "Spend (est.)"
            case .outputTokens: "Output tokens"
            case .commits: "Commits"
            case .prsMerged: "PRs merged"
            case .linesAdded: "Lines added"
            case .messages: "Messages"
            case .toolCalls: "Tool calls"
            case .waitingMinutes: "Minutes waiting"
            case .sessions: "Sessions"
            }
        }

        public func value(_ d: Stats.Day) -> Double {
            switch self {
            case .usd: d.usd
            case .outputTokens: Double(d.outputTokens)
            case .commits: Double(d.commits)
            case .prsMerged: Double(d.prsMerged)
            case .linesAdded: Double(d.linesAdded)
            case .messages: Double(d.messages)
            case .toolCalls: Double(d.totalToolCalls)
            case .waitingMinutes: d.waitingSeconds / 60
            case .sessions: Double(d.sessionCount)
            }
        }
    }

    public struct LeaderboardRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var value: Double
    }

    public static func leaderboard(_ rows: [MemberRow], metric: Metric) -> [LeaderboardRow] {
        rows.map { LeaderboardRow(kid: $0.kid, name: $0.name, value: metric.value($0.summary.total)) }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    // MARK: repos

    public struct RepoRow: Equatable, Sendable {
        public struct Share: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
            public var minutes: Int
        }
        public var project: String
        public var usd: Double
        public var minutes: Int
        /// By effort, descending.
        public var members: [Share]
    }

    /// Who works where, from every member's session index: sessions that
    /// started inside the period, grouped by project, by effort.
    public static func repos(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                             calendar: Calendar = .current) -> [RepoRow] {
        let fromKey = Stats.fold(days: [:], period: period, now: now, calendar: calendar).from
        let start = Int((Stats.date(fromDayKey: fromKey, calendar: calendar) ?? now).timeIntervalSince1970)
        var byProject: [String: [String: RepoRow.Share]] = [:]
        for m in reader.members.values {
            for s in m.sessions where s.startedAt >= start {
                var share = byProject[s.project, default: [:]][m.kid] ?? RepoRow.Share(kid: m.kid, name: m.name, usd: 0, minutes: 0)
                share.usd += s.usd
                share.minutes += s.busyMinutes
                byProject[s.project, default: [:]][m.kid] = share
            }
        }
        return byProject.map { project, shares in
            let members = shares.values.sorted { $0.usd == $1.usd ? $0.name < $1.name : $0.usd > $1.usd }
            return RepoRow(project: project, usd: members.reduce(0) { $0 + $1.usd }, minutes: members.reduce(0) { $0 + $1.minutes }, members: members)
        }
        .sorted { $0.usd == $1.usd ? $0.project < $1.project : $0.usd > $1.usd }
    }

    // MARK: blockers

    public struct Blocker: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// "aws" | "limit" | "waiting" | "crash" | "other"
        public var kind: String
        public var text: String
    }

    /// Every fresh member's blockers (spec §8.3): what its pop-out shows,
    /// sessions waiting on a prompt, crashes today. Stale members are
    /// skipped so an old `now.json` cannot keep a blocker alive.
    public static func blockers(_ reader: TeamReader, now: Date = Date()) -> [Blocker] {
        var out: [Blocker] = []
        for m in reader.members.values.sorted(by: { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }) {
            guard let n = m.now, Int(now.timeIntervalSince1970) - n.at <= onlineWindow else { continue }
            for text in n.blockers {
                let kind = text.hasPrefix("AWS") ? "aws" : text.contains("limited") ? "limit" : "other"
                out.append(Blocker(kid: m.kid, name: m.name, kind: kind, text: text))
            }
            for s in n.sessions where s.status == "waiting" {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "waiting", text: "\(s.name ?? s.project) is waiting for you"))
            }
            if n.crashesToday > 0 {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "crash", text: "\(n.crashesToday) crash\(n.crashesToday == 1 ? "" : "es") today"))
            }
        }
        return out
    }

    // MARK: cost, hours

    public struct Cost: Equatable, Sendable {
        public struct MemberCost: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
        }
        public var total: Double
        /// Descending, then by name.
        public var byMember: [MemberCost]
        public var byModel: [String: Double]
        public var byRepo: [String: Double]
    }

    public static func cost(_ rows: [MemberRow], repos: [RepoRow]) -> Cost {
        var byModel: [String: Double] = [:]
        for r in rows { for (model, tally) in r.summary.total.byModel { byModel[model, default: 0] += tally.usd } }
        let byMember = rows.map { Cost.MemberCost(kid: $0.kid, name: $0.name, usd: $0.summary.total.usd) }
            .sorted { $0.usd == $1.usd ? $0.name < $1.name : $0.usd > $1.usd }
        return Cost(total: rows.reduce(0) { $0 + $1.summary.total.usd }, byMember: byMember, byModel: byModel,
                    byRepo: Dictionary(uniqueKeysWithValues: repos.map { ($0.project, $0.usd) }))
    }

    /// The team's 168-slot heatmap (weekday × hour) for the rows' period.
    public static func hours(_ rows: [MemberRow]) -> [Int] {
        var out = Array(repeating: 0, count: 168)
        for r in rows { for (i, v) in r.summary.total.hours.prefix(168).enumerated() { out[i] += v } }
        return out
    }

    // MARK: members' view (§8.4)

    public struct ShareRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// Kinds this teammate's audiences include me in, sorted.
        public var kinds: [String]
    }

    /// What each teammate shares TO `me`, read off their `now.sharesTo`
    /// (a member with no fresh `now.json` shows an empty row).
    public static func sharedWithMe(_ reader: TeamReader, roster: TeamRoster, me: String) -> [ShareRow] {
        roster.everyone.filter { $0.keys.kid != me }.map { member in
            let shares = reader.members[member.keys.kid]?.now?.sharesTo ?? [:]
            let kinds = shares.filter { _, target in
                switch target {
                case .team: true
                case .leaders: roster.isLeader(me)
                case .members(let kids): kids.contains(me)
                }
            }.keys.sorted()
            return ShareRow(kid: member.keys.kid, name: member.name, kinds: kinds)
        }
        .sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }
}
```

`Stats.fold(days: [:] …).from` must return the period's first day key even with no days (check `Stats.fold`; if it needs a non-empty map, compute the start with `Stats.range(...)` if that helper is accessible, else expose a `Stats.periodStart(_:now:calendar:)` — that is a `Stats.swift` edit nobody else makes this round; allowed, minimal). `Stats.date(fromDayKey:calendar:)` exists (the publisher uses it). If `ShareTarget`'s cases are spelled differently, follow `TeamRoster.swift`.

- [ ] **Step 3: Run**

Run: `swift test --filter TeamInsightsTests 2>&1 | tail -3` — expected: 6 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-insights && git add Sources/InfinitusCore/Team/TeamInsights.swift Tests/InfinitusCoreTests/TeamInsightsTests.swift && \
git commit -m "team: TeamInsights — comparison rows, leaderboards, repo coverage, blockers board, cost, hours, who's on, what's shared with me

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Aggregates — the document, publish (leaders), fold (from leaders only)

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamDocs.swift` (append `Aggregates`)
- Modify: `Sources/InfinitusCore/Team/TeamInsights.swift` (`aggregates(...)`)
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`publishAggregates`, `readableHeaders` lists `roster/aggregates/`)
- Modify: `Sources/InfinitusCore/Team/TeamReader.swift` (`aggregates`)
- Test: `Tests/InfinitusCoreTests/TeamAggregatesTests.swift`

**Interfaces:**
- Consumes: Task 1; `TeamKinds.aggregates` (already routed for `roster/aggregates/<x>.json`, owner nil); `Envelope.seal`; `TeamRoster.recipients(for: .team)`.
- Produces: `TeamDocs.Aggregates` (`schema, period, from, to, at, members, total: Stats.Day, previous: Stats.Day, hours: [Int], repos: [Repo], byModel: [String: Double], onNow: [String], perMember: [MemberTotal]?`), `TeamInsights.aggregates(_:roster:period:now:calendar:) -> TeamDocs.Aggregates`, `TeamClient.publishAggregates(_ docs: [String: Data], now:) throws -> [String]`, `TeamReader.aggregates: [String: TeamDocs.Aggregates]`.

- [ ] **Step 1: Failing tests**

Create `Tests/InfinitusCoreTests/TeamAggregatesTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamAggregatesTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aggr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }
    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name)); return (paths, FileSecrets(dir: paths.secretsDir))
    }
    func team() throws -> (leader: TeamClient, member: TeamClient) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [], platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch(); try leader.approve(kid: member.identity.kid, now: 1_020); _ = try member.fetch()
        return (leader, member)
    }

    func testAggregatesDocumentRespectsThePolicy() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random()
        var roster = TeamRoster(id: "t", name: "T", createdAt: 1, leaders: [TeamRoster.Member(keys: l.keys, name: "Lee", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 2)], rev: 1)
        let now = Date(timeIntervalSince1970: 1_788_609_600)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var day = Stats.Day(); day.usd = 2; day.commits = 1; day.hours[5] = 3
        let doc = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-05", stats: day))
        let reader = TeamReader.fold(headers: [(StoreEntry(path: "m/\(a.kid)/days/2026-09-05.json", size: 1, version: "v"),
                                                Envelope.Header(v: 1, kind: "stats", from: a.kid, eph: "", to: [], at: 5, nonce: "", sig: nil))],
                                     roster: roster) { _ in doc }
        let closed = TeamInsights.aggregates(reader, roster: roster, period: .week, now: now, calendar: cal)
        XCTAssertEqual(closed.schema, 1); XCTAssertEqual(closed.period, "week"); XCTAssertEqual(closed.members, 2)
        XCTAssertEqual(closed.total.usd, 2, accuracy: 0.001); XCTAssertEqual(closed.total.commits, 1); XCTAssertEqual(closed.hours[5], 3)
        XCTAssertNil(closed.perMember, "membersSeeEachOther is off")
        XCTAssertEqual(closed.total.sessions, [], "compacted: sets emptied")
        roster.policy.membersSeeEachOther = true
        let open = TeamInsights.aggregates(reader, roster: roster, period: .week, now: now, calendar: cal)
        XCTAssertEqual(open.perMember?.map(\.name), ["Lee", "Ann"])
        XCTAssertEqual(open.perMember?[1].usd ?? 0, 2, accuracy: 0.001)
    }

    func testLeaderPublishesAndMemberReadsAggregates() throws {
        let (leader, member) = try team()
        let now = Date(timeIntervalSince1970: 1_788_609_600)
        let roster = leader.roster!.doc
        let doc = TeamInsights.aggregates(try TeamReader.load(client: leader), roster: roster, period: .week, now: now)
        let paths = try leader.publishAggregates(["week": try CanonicalJSON.encode(doc)], now: 2_000)
        XCTAssertEqual(paths, ["roster/aggregates/week.json"])
        _ = try member.fetch()
        let reader = try TeamReader.load(client: member)
        XCTAssertEqual(reader.aggregates["week"]?.period, "week")
        XCTAssertEqual(reader.aggregates["week"]?.members, 2)
        XCTAssertThrowsError(try member.publishAggregates(["week": Data("{}".utf8)], now: 2_001)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader)
        }
    }

    func testAggregatesFromANonLeaderAreIgnored() throws {
        let (leader, member) = try team()
        // A member with store access writes an envelope under the leaders' path.
        let forged = try Envelope.seal(Data("{\"schema\":1}".utf8), kind: TeamKinds.aggregates, from: member.identity,
                                       to: member.roster!.doc.recipients(for: .team), at: 2_000)
        try member.store.put("roster/aggregates/week.json", forged)
        _ = try leader.fetch()
        XCTAssertNil(try TeamReader.load(client: leader).aggregates["week"])
        XCTAssertNil(try TeamReader.load(client: leader).members[member.identity.kid]?.kinds.first { $0 == TeamKinds.aggregates }, "not counted as the member's kind either")
    }
}
```

`member.store` — if `store` is `private` on `TeamClient`, make it `let store: TeamGit` (internal). If `Stats.Day.sessions` compaction is named differently, use `compacted()`'s documented effect (sets emptied, tallies kept).

Run: `swift test --filter TeamAggregatesTests 2>&1 | tail -3` — expected: compile failure.

- [ ] **Step 2: The document**

Append to `TeamDocs` in `Sources/InfinitusCore/Team/TeamDocs.swift`:

```swift
    /// `roster/aggregates/<period>.json` (spec §8.3): the team picture a
    /// leader publishes to the whole team. Per-member rows only under
    /// `policy.membersSeeEachOther` (§8.4). Days are compacted.
    public struct Aggregates: Codable, Equatable, Sendable {
        public struct Repo: Codable, Equatable, Sendable {
            public var project: String
            public var usd: Double
            public var minutes: Int
            public var members: Int
            public init(project: String, usd: Double, minutes: Int, members: Int) {
                self.project = project; self.usd = usd; self.minutes = minutes; self.members = members
            }
        }
        public struct MemberTotal: Codable, Equatable, Sendable {
            public var kid: String
            public var name: String
            public var role: String
            public var usd: Double
            public var commits: Int
            public var messages: Int
            public var outputTokens: Int
            public var sessions: Int
            public var online: Bool
            public init(kid: String, name: String, role: String, usd: Double, commits: Int, messages: Int, outputTokens: Int, sessions: Int, online: Bool) {
                self.kid = kid; self.name = name; self.role = role; self.usd = usd; self.commits = commits
                self.messages = messages; self.outputTokens = outputTokens; self.sessions = sessions; self.online = online
            }
        }
        public var schema = 1
        public var period: String
        public var from: String
        public var to: String
        public var at: Int
        public var members: Int
        public var total: Stats.Day
        public var previous: Stats.Day
        public var hours: [Int]
        public var repos: [Repo]
        public var byModel: [String: Double]
        public var onNow: [String]
        public var perMember: [MemberTotal]?
        public init(period: String, from: String, to: String, at: Int, members: Int, total: Stats.Day, previous: Stats.Day,
                    hours: [Int], repos: [Repo], byModel: [String: Double], onNow: [String], perMember: [MemberTotal]?) {
            self.period = period; self.from = from; self.to = to; self.at = at; self.members = members; self.total = total
            self.previous = previous; self.hours = hours; self.repos = repos; self.byModel = byModel; self.onNow = onNow; self.perMember = perMember
        }
    }
```

- [ ] **Step 3: `TeamInsights.aggregates`**

Append to `TeamInsights`:

```swift
    // MARK: aggregates (§8.3)

    public static func aggregates(_ reader: TeamReader, roster: TeamRoster, period: Stats.Period, now: Date = Date(),
                                  calendar: Calendar = .current) -> TeamDocs.Aggregates {
        let rows = comparison(reader, period: period, now: now, calendar: calendar)
        let team = Stats.fold(days: reader.teamDays(), period: period, now: now, calendar: calendar)
        let repos = repos(reader, period: period, now: now, calendar: calendar)
        let cost = cost(rows, repos: repos)
        var total = team.total.compacted(); total.hours = hours(rows)
        let perMember: [TeamDocs.Aggregates.MemberTotal]? = roster.policy.membersSeeEachOther ? rows.map {
            TeamDocs.Aggregates.MemberTotal(kid: $0.kid, name: $0.name, role: $0.role, usd: $0.summary.total.usd,
                                            commits: $0.summary.total.commits, messages: $0.summary.total.messages,
                                            outputTokens: $0.summary.total.outputTokens, sessions: $0.summary.total.sessionCount, online: $0.online)
        } : nil
        return TeamDocs.Aggregates(period: period.rawValue, from: team.from, to: team.to, at: Int(now.timeIntervalSince1970),
                                   members: roster.everyone.count, total: total, previous: team.previous.compacted(),
                                   hours: hours(rows), repos: repos.map { TeamDocs.Aggregates.Repo(project: $0.project, usd: $0.usd, minutes: $0.minutes, members: $0.members.count) },
                                   byModel: cost.byModel, onNow: whoIsOn(reader, now: now).map(\.name), perMember: perMember)
    }
```

(`Stats.Day.compacted()` empties `sessions`/`repos` sets and keeps tallies — check whether it also drops `hours`; if it does, the `total.hours = hours(rows)` line restores the heatmap; if `hours` is kept, delete that line.)

- [ ] **Step 4: `publishAggregates`, `readableHeaders`, the reader**

In `TeamClient.swift`, directly BEFORE `public func status()` insert:

```swift
    // MARK: aggregates (spec §8.3, plan 9)

    /// Leaders publish `roster/aggregates/<period>.json` to the whole team,
    /// one commit. Readers keep only what a leader sealed (TeamReader).
    @discardableResult
    public func publishAggregates(_ docs: [String: Data], now: Int = Int(Date().timeIntervalSince1970)) throws -> [String] {
        guard let roster = roster?.doc, isLeader else { throw ClientError.notALeader }
        var writes: [String: Data?] = [:]
        var paths: [String] = []
        for (period, plaintext) in docs.sorted(by: { $0.key < $1.key }) {
            let path = "roster/aggregates/\(period).json"
            try TeamKinds.check(kind: TeamKinds.aggregates, from: identity.kid, at: path)
            writes[path] = try Envelope.seal(plaintext, kind: TeamKinds.aggregates, from: identity,
                                             to: roster.recipients(for: .team), at: now)
            paths.append(path)
        }
        if !writes.isEmpty { try store.putAll(writes) }
        return paths
    }
```

In `readableHeaders()`, the `for entry in try store.list("m/")` loop must also cover `roster/aggregates/`: change it to iterate `try store.list("m/") + (try store.list("roster/aggregates/"))` (if `TeamGit.list` maps a prefix to one branch, `list("roster/")` filtered by `hasPrefix("roster/aggregates/")` is the fallback). The existing guards (kind/path check, sender in roster at `header.at`, me among readers) stay.

In `TeamReader.swift`: add `public private(set) var aggregates: [String: TeamDocs.Aggregates] = [:]`, and in `fold`, BEFORE the `var member = reader.members[header.from] ?? …` line, handle the kind:

```swift
            if header.kind == TeamKinds.aggregates {
                // Leaders' documents only: a member can write under
                // roster/ with the store credential, so the sender is checked.
                guard roster.isLeader(header.from),
                      let doc = decode(TeamDocs.Aggregates.self, entry.path), doc.schema == 1 else { continue }
                reader.aggregates[doc.period] = doc
                continue
            }
```

`roster.isLeader(_:)` checks the current roster; a leader demoted after publishing is an accepted edge (the next publish replaces the file).

- [ ] **Step 5: Run**

Run: `swift test --filter 'TeamAggregatesTests|TeamReaderTests|TeamInsightsTests|TeamMembershipTests' 2>&1 | tail -3` — expected: pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-insights && git add Sources/InfinitusCore/Team/TeamDocs.swift Sources/InfinitusCore/Team/TeamInsights.swift Sources/InfinitusCore/Team/TeamClient.swift Sources/InfinitusCore/Team/TeamReader.swift Tests/InfinitusCoreTests/TeamAggregatesTests.swift && \
git commit -m "team: leaders publish roster/aggregates/<period>.json to the team (per-member rows only under membersSeeEachOther); readers keep leaders' aggregates only

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Roster policy — `setPolicy`, `requests: off`

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`setPolicy` before `status()`; one guard in `requests()`, one in `code()`; `ClientError.requestsOff`)
- Test: `Tests/InfinitusCoreTests/TeamAggregatesTests.swift` (one test appended)

**Interfaces:**
- Produces: `TeamClient.setPolicy(_ policy: TeamRoster.Policy) throws`, `ClientError.requestsOff`; with `policy.requests == "off"`, `requests()` returns `[]` and `code(...)` throws `.requestsOff`.

- [ ] **Step 1: Failing test**

Append to `TeamAggregatesTests`:

```swift
    func testPolicyOffHidesRequestsAndTheCode() throws {
        let (leader, member) = try team()
        XCTAssertNoThrow(try leader.code(expiresIn: 60, now: 3_000))
        try leader.setPolicy(TeamRoster.Policy(requests: "off", membersSeeEachOther: true))
        XCTAssertEqual(leader.roster?.doc.policy.requests, "off")
        XCTAssertEqual(leader.roster?.doc.rev, 3)
        XCTAssertThrowsError(try leader.code(expiresIn: 60, now: 3_001)) { XCTAssertEqual($0 as? TeamClient.ClientError, .requestsOff) }
        XCTAssertEqual(try leader.requests(), [])
        _ = try member.fetch()
        XCTAssertEqual(member.roster?.doc.policy.membersSeeEachOther, true)
        XCTAssertThrowsError(try member.setPolicy(TeamRoster.Policy())) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
    }
```

- [ ] **Step 2: Implement**

Add `case requestsOff` to `ClientError`. Directly before `public func status()` (after `publishAggregates`) insert:

```swift
    /// Spec §5: one roster edit, leaders only (race loop as `approve`).
    public func setPolicy(_ policy: TeamRoster.Policy) throws {
        try editRoster { current in
            var next = current
            next.policy = policy
            return next
        }
    }
```

In `requests()`, after the `isLeader` guard add `if roster?.doc.policy.requests == "off" { return [] }`. In `code(...)`, after its `isLeader` guard add `guard roster?.doc.policy.requests != "off" else { throw ClientError.requestsOff }`.

- [ ] **Step 3: Run and commit**

Run: `swift test --filter 'TeamAggregatesTests|TeamMembershipTests|TeamClientTests' 2>&1 | tail -3` — expected: pass.

```bash
cd /Users/deathemperor/death/limitless-t-insights && git add Sources/InfinitusCore/Team/TeamClient.swift Tests/InfinitusCoreTests/TeamAggregatesTests.swift && \
git commit -m "team: leaders set the roster policy; requests off hides the request list and refuses to mint a code

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: CLI — `members --period`, `insights`, `aggregates [publish]`, `policy`

**Files:**
- Modify: `Sources/InfinitusCLI/TeamCommand.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `team members [--period day|week|month|year]` → rows `{kid, name, role, online, sessionsNow, blockers, crashes, lastPublished, usd, commits, messages, outputTokens, sessions, sharesToMe: [kind]}`; `team insights [--period]` → `{period, from, to, leaderboards: {metric: [{kid,name,value}]}, repos, blockers, cost: {total, byMember, byModel, byRepo}, onNow: [name], hours}`; `team aggregates` → `{period: Aggregates}` as read; `team aggregates publish [--period all|<p>]` (leaders) → `{published: [path]}`; `team policy [--requests code|off] [--members-see-each-other on|off]` → the policy after the change.

- [ ] **Step 1: `members`**

Replace the body of `case "members":` so it folds the period (default `week`) through `TeamInsights.comparison` and adds `sharesToMe`:

```swift
        case "members":
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            let roster = c.roster?.doc
            let shared = Dictionary(uniqueKeysWithValues: (roster.map { TeamInsights.sharedWithMe(reader, roster: $0, me: c.identity.kid) } ?? []).map { ($0.kid, $0.kinds) })
            emit(TeamInsights.comparison(reader, period: period).map { r in
                MemberRow(kid: r.kid, name: r.name, role: r.role, online: r.online, sessionsNow: r.sessionsNow, blockers: r.blockers,
                          crashes: r.crashes, lastPublished: r.lastPublished, usd: r.summary.total.usd, commits: r.summary.total.commits,
                          messages: r.summary.total.messages, outputTokens: r.summary.total.outputTokens,
                          sessions: r.summary.total.sessionCount, sharesToMe: shared[r.kid] ?? [])
            })
```

and extend the file's `MemberRow` (the CLI's private Encodable row) with `online: Bool, usd: Double, commits: Int, messages: Int, outputTokens: Int, sessions: Int, sharesToMe: [String]` (drop `shares` if it duplicates `kinds` — keep whatever the existing struct has and add these).

- [ ] **Step 2: The new cases**

Directly after the `case "reshare":` block (before `default:`) insert:

```swift
        case "insights":
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            let rows = TeamInsights.comparison(reader, period: period)
            let repos = TeamInsights.repos(reader, period: period)
            let cost = TeamInsights.cost(rows, repos: repos)
            struct Board: Encodable { var kid, name, kind, text: String }
            struct Repo: Encodable { var project: String; var usd: Double; var minutes: Int; var members: [String] }
            struct Row: Encodable { var kid, name: String; var value: Double }
            struct Money: Encodable { var kid, name: String; var usd: Double }
            struct Costs: Encodable { var total: Double; var byMember: [Money]; var byModel: [String: Double]; var byRepo: [String: Double] }
            struct Insights: Encodable {
                var period, from, to: String
                var leaderboards: [String: [Row]]
                var repos: [Repo]
                var blockers: [Board]
                var cost: Costs
                var onNow: [String]
                var hours: [Int]
            }
            let sample = rows.first?.summary
            emit(Insights(
                period: period.rawValue, from: sample?.from ?? "", to: sample?.to ?? "",
                leaderboards: Dictionary(uniqueKeysWithValues: TeamInsights.Metric.allCases.map { m in
                    (m.rawValue, TeamInsights.leaderboard(rows, metric: m).map { Row(kid: $0.kid, name: $0.name, value: $0.value) }) }),
                repos: repos.map { Repo(project: $0.project, usd: $0.usd, minutes: $0.minutes, members: $0.members.map(\.name)) },
                blockers: TeamInsights.blockers(reader).map { Board(kid: $0.kid, name: $0.name, kind: $0.kind, text: $0.text) },
                cost: Costs(total: cost.total, byMember: cost.byMember.map { Money(kid: $0.kid, name: $0.name, usd: $0.usd) },
                            byModel: cost.byModel, byRepo: cost.byRepo),
                onNow: TeamInsights.whoIsOn(reader).map(\.name), hours: TeamInsights.hours(rows)))
        case "aggregates":
            let c = try client(); _ = try c.fetch()
            if positional.first == "publish" {
                guard let roster = c.roster?.doc else { throw TeamClient.ClientError.noRoster }
                let which = options["period"] ?? "all"
                let periods = which == "all" ? Stats.Period.allCases : [Stats.Period(rawValue: which)].compactMap { $0 }
                guard !periods.isEmpty else { return fail("--period is all, day, week, month or year", code: 2) }
                let reader = try TeamReader.load(client: c)
                var docs: [String: Data] = [:]
                for p in periods { docs[p.rawValue] = try CanonicalJSON.encode(TeamInsights.aggregates(reader, roster: roster, period: p)) }
                emit(["published": try c.publishAggregates(docs)])
            } else {
                emit(try TeamReader.load(client: c).aggregates)
            }
        case "policy":
            let c = try client(); _ = try c.fetch()
            guard var policy = c.roster?.doc.policy else { throw TeamClient.ClientError.noRoster }
            var changed = false
            if let r = options["requests"] {
                guard ["code", "off"].contains(r) else { return fail("--requests is code or off", code: 2) }
                policy.requests = r; changed = true
            }
            if let m = options["members-see-each-other"] {
                guard ["on", "off"].contains(m) else { return fail("--members-see-each-other is on or off", code: 2) }
                policy.membersSeeEachOther = m == "on"; changed = true
            }
            if changed { try c.setPolicy(policy) }
            emit(policy)
```

`emit` takes any `Encodable` (check its signature; wrap dictionaries in a struct if it wants a concrete type). `policy` needs the lock gate like `approve` (it is a roster edit): add `"policy"` to the gated list.

Usage text additions:

```
  members [--period <p>]              every member's period totals (spend is an estimate), online, blockers, and what they share with you
  insights [--period <p>]             leaderboards, repo coverage, blockers board, cost by member/model/repo, who's on, hours
  aggregates                          the leaders' published team picture
  aggregates publish [--period all|<p>]   (leaders) publish the team picture to the whole team
  policy [--requests code|off] [--members-see-each-other on|off]   (leaders) show or set the roster policy
```

- [ ] **Step 3: Smoke it**

Run (two temp identities on a local bare repo; the gate opened):

```bash
cd /Users/deathemperor/death/limitless-t-insights && swift build --product infinitusctl 2>&1 | tail -1 && \
T=$(mktemp -d) && export INFINITUS_LOCK_GATE=open && CTL=.build/debug/infinitusctl && git init -q --bare "$T/r.git" && \
INFINITUS_TEAM_DIR="$T/l" $CTL team create Papaya --remote "file://$T/r.git" >/dev/null && \
CODE=$(INFINITUS_TEAM_DIR="$T/l" $CTL team code | python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])') && \
printf '%s' "$CODE" | INFINITUS_TEAM_DIR="$T/m" $CTL team request - --name Bo >/dev/null && \
KID=$(INFINITUS_TEAM_DIR="$T/m" $CTL team status | python3 -c 'import json,sys; print(json.load(sys.stdin)["kid"])') && \
INFINITUS_TEAM_DIR="$T/l" $CTL team fetch >/dev/null && INFINITUS_TEAM_DIR="$T/l" $CTL team approve "$KID" >/dev/null && \
INFINITUS_TEAM_DIR="$T/l" $CTL team members --period month | python3 -c 'import json,sys; d=json.load(sys.stdin); print("members:", [r["name"] for r in d])' && \
INFINITUS_TEAM_DIR="$T/l" $CTL team insights | python3 -c 'import json,sys; d=json.load(sys.stdin); print("insights:", sorted(d["leaderboards"]))' && \
INFINITUS_TEAM_DIR="$T/l" $CTL team aggregates publish | python3 -c 'import json,sys; print(json.load(sys.stdin)["published"])' && \
INFINITUS_TEAM_DIR="$T/m" $CTL team fetch >/dev/null && INFINITUS_TEAM_DIR="$T/m" $CTL team aggregates | python3 -c 'import json,sys; print("member sees:", sorted(json.load(sys.stdin)))' && \
INFINITUS_TEAM_DIR="$T/l" $CTL team policy --requests off | grep -q '"requests":"off"' && echo "policy: off" && \
INFINITUS_TEAM_DIR="$T/l" $CTL team code; echo "code exit=$? (expected non-zero)"; rm -rf "$T"
```

Expected: `members: ['Leader', 'Bo']`, nine leaderboard keys, four published paths, `member sees: ['day', 'month', 'week', 'year']`, `policy: off`, non-zero exit on `code`.

- [ ] **Step 4: Full suite, app build, commit**

Run: `swift test 2>&1 | grep -E "Executed|error:" | tail -2 && swift build --product Infinitus 2>&1 | grep -E "error|Build complete" | tail -2`

```bash
cd /Users/deathemperor/death/limitless-t-insights && git add Sources/InfinitusCLI/TeamCommand.swift && \
git commit -m "cli: team members --period, insights, aggregates [publish], policy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Release lines

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: The lines**

Under `## 0.4.4 (unreleased)`, directly before `## 0.4.3` (create `### Team (preview)` there if the other streams have not), add:

```markdown
- Leaders see the team: per-member comparison for a period, leaderboards by spend, tokens, commits, PRs, lines, messages, tool calls, waiting time and sessions, who works in which repo, a blockers board, cost by member / model / repo, the hours heatmap and who's on now (`infinitusctl team members --period|insights`).
- Leaders publish the team picture to everyone (`team aggregates publish`), with per-member rows only when the roster's members-see-each-other policy is on, and `team policy` sets that and whether new requests are accepted.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-insights && git add CHANGELOG.md && \
git commit -m "changelog: team insights and aggregates

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage.** §8.2 per-member effort/rhythm/quality/fleet/now come from `Stats.Summary` (T1 `comparison`); transcripts list/open are plan-2 reader + the pane. §8.3 totals and trends (`total`/`previous`), comparison table, leaderboards, repo coverage with effort per repo (from session indexes), blockers board, cost per member/repo/model, hours heatmap, who's on now (T1); `aggregates/<period>.json` wrapped to the team (T2); `UsageForecast` per member is engine-driven and not published by members — parked to #55; narrative digests are phase 3. §8.4 roster with what each shares to me (`sharedWithMe`), the leaders' aggregates (T2), `membersSeeEachOther` → per-member rows in aggregates (T2, T3 policy). §5 policy edit (T3). §9 CLI `members|member --period` (T4).
- **Placeholders.** None. Two bounded checks are left to the implementer (`Stats.fold` on an empty map; `Stats.Day.compacted()` and `hours`), each with the fallback named.
- **Type consistency.** `TeamInsights.comparison(_:period:now:calendar:)`, `repos(_:period:now:calendar:)`, `cost(_:repos:)`, `hours(_:)`, `whoIsOn(_:now:)`, `blockers(_:now:)`, `sharedWithMe(_:roster:me:)`, `aggregates(_:roster:period:now:calendar:)` are used with the same labels in T1 tests, T2, T4. `TeamClient.publishAggregates(_:now:)` returns `[String]`; `setPolicy(_:)`; `TeamReader.aggregates` keyed by `Aggregates.period`.
