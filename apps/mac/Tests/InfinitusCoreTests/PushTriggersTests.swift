import XCTest
@testable import InfinitusCore

final class LiveSessionsDecodeTests: XCTestCase {
    func testBreakdownDecodes() throws {
        let json = #"{"busy":2,"idle":3,"waiting":1,"shell":1,"unknown":2,"total":9}"#
        let live = try JSONDecoder().decode(LiveSessions.self, from: Data(json.utf8))
        XCTAssertEqual(live.busy, 2)
        XCTAssertEqual(live.idle, 3)
        XCTAssertEqual(live.waiting, 1)
        XCTAssertEqual(live.shell, 1)
        XCTAssertEqual(live.unknown, 2)
    }

    func testOldEngineWithoutBreakdownStillDecodes() throws {
        let live = try JSONDecoder().decode(
            LiveSessions.self, from: Data(#"{"busy":1,"total":4}"#.utf8))
        XCTAssertEqual(live.busy, 1)
        XCTAssertNil(live.idle)
    }
}

final class SessionSummaryTests: XCTestCase {
    func testBreakdownTooltipSkipsZeroBuckets() throws {
        let live = try JSONDecoder().decode(LiveSessions.self, from: Data(
            #"{"busy":4,"idle":7,"waiting":0,"shell":1,"unknown":2,"total":14}"#.utf8))
        XCTAssertEqual(
            SessionSummary.tooltip(live),
            "4 working · 7 idle · 1 in shell · 2 unknown of "
            + "14 live Claude Code sessions — all ride the active account")
    }

    func testOldEngineFallsBackToTwoNumbers() throws {
        let live = try JSONDecoder().decode(
            LiveSessions.self, from: Data(#"{"busy":1,"total":3}"#.utf8))
        XCTAssertTrue(SessionSummary.tooltip(live).hasPrefix("1 session(s) mid-turn"))
    }
}

final class TitleFormatterIconTests: XCTestCase {
    private func account(pct: Double) -> Account {
        try! JSONDecoder().decode(Account.self, from: Data("""
        {"number": 1, "email": "a@x.com", "organizationName": "",
         "organizationUuid": "", "isOrganization": false, "active": true,
         "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": \(pct)}}}
        """.utf8))
    }

    func testEmptyIconDropsTheGlyphAndItsSpace() {
        let prefs = TitlePrefs(showAccountName: true, titlePct: "5h", titleScoped: false)
        let text = TitleFormatter.format(account: account(pct: 42), prefs: prefs, icon: "")
        XCTAssertEqual(text, "a · 42%")
        XCTAssertEqual(TitleFormatter.format(account: nil, prefs: prefs, icon: ""), "")
    }

    func testDefaultKeepsTheTextGlyph() {
        let prefs = TitlePrefs(showAccountName: false, titlePct: "5h", titleScoped: false)
        XCTAssertEqual(TitleFormatter.format(account: account(pct: 42), prefs: prefs),
                       "⇄ 42%")
    }
}

final class ReadyLabelThemeTests: XCTestCase {
    func testMinimalCustomThemeDefaultsToReady() throws {
        let themes = try JSONDecoder().decode(
            [RowTheme].self, from: Data(#"[{"id":"x","name":"X"}]"#.utf8))
        XCTAssertEqual(themes.first?.readyLabel, "ready")
    }

    func testBuiltinsCarryThemedReadyWords() {
        XCTAssertEqual(RowTheme.rpg.readyLabel, "full HP")
        XCTAssertEqual(RowTheme.off.readyLabel, "ready")
    }
}

final class SettingsSyncSnapshotTests: XCTestCase {
    func testSnapshotRoundTrips() throws {
        var snap = SyncSnapshot()
        snap.app = ["compact_rows": .bool(true), "refresh_interval": .number(60),
                    "popup_layout": .string("wide")]
        snap.themes = [RowTheme(id: "x", name: "X", readyLabel: "GO")]
        snap.engine = ["autoswitch.threshold": "98.0"]
        XCTAssertEqual(SyncSnapshot.decode(try snap.encoded()), snap)
    }
}

final class PushTriggersTests: XCTestCase {
    private func acct(_ n: Int, dead: Bool, pct: Double? = nil) -> PushTriggers.Account {
        PushTriggers.Account(number: n, name: "a\(n)", dead: dead, worstPct: pct)
    }
    private let all = PushTriggers.Flags()
    /// Minutes after a fixed origin: the sessions-done tests need the
    /// clock to move (ten minutes of work before the finish counts).
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }

    func testSessionsDoneNeedsTwoQuietTicks() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: 3, total: 5, accounts: [], flags: all, now: at(0)), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(11)), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(12)),
                       ["all sessions finished — 0 of 5 working"])
        // Quiet stays quiet: no repeat until a new busy episode.
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(13)), [])
        XCTAssertEqual(t.tick(busy: 2, total: 5, accounts: [], flags: all, now: at(14)), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(25)), [])
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(26)).count, 1)
    }

    func testShortBurstStaysSilentAndTheNextEpisodeStartsFresh() {
        var t = PushTriggers()
        _ = t.tick(busy: 1, total: 5, accounts: [], flags: all, now: at(0))
        _ = t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(3))
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(4)), [], "three minutes of work is not a finish")
        _ = t.tick(busy: 1, total: 5, accounts: [], flags: all, now: at(5))
        _ = t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(16))
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(17)).count, 1, "the stretch counts from the new episode's start")
    }

    func testAStretchOutlivingEverySessionStaysSilent() {
        var first = PushTriggers()
        _ = first.tick(busy: 2, total: 2, accounts: [], flags: all, now: at(0))
        // Quit mid-work; the sessions closed while the app was down.
        var relaunched = PushTriggers(memory: first.memory)
        _ = relaunched.tick(busy: 0, total: 0, accounts: [], flags: all, now: at(300))
        XCTAssertEqual(relaunched.tick(busy: 0, total: 0, accounts: [], flags: all, now: at(301)), [])
        XCTAssertNil(relaunched.memory.busySince)
    }

    func testBusyStretchAndLastAliveWarningSurviveARelaunch() {
        var first = PushTriggers()
        let warn = [acct(1, dead: true), acct(2, dead: false, pct: 92)]
        XCTAssertEqual(first.tick(busy: 3, total: 5, accounts: warn, flags: all, now: at(0)).count, 1)   // the last-alive warning
        var relaunched = PushTriggers(memory: first.memory)
        // Quiet from the first look after the relaunch: the finish still pushes, the warning does not repeat.
        XCTAssertEqual(relaunched.tick(busy: 0, total: 5, accounts: warn, flags: all, now: at(11)), [])
        XCTAssertEqual(relaunched.tick(busy: 0, total: 5, accounts: warn, flags: all, now: at(12)),
                       ["all sessions finished — 0 of 5 working"])
        XCTAssertNil(relaunched.memory.busySince)
        XCTAssertEqual(relaunched.memory.warnedLastAlive, 2)
        // The blob round-trips through JSON as the app stores it.
        let data = try! JSONEncoder().encode(first.memory)
        XCTAssertEqual(try! JSONDecoder().decode(PushTriggers.Memory.self, from: data), first.memory)
    }

    private func session(_ pid: Int, _ status: String) -> SessionDetail {
        SessionDetail(pid: pid, cwd: "/Users/me/repo\(pid)", status: status, kind: "cli",
                      startedAt: 0)
    }

    func testHookAnnouncedWaitingIsNotPushedAgainByThePoll() {
        var t = PushTriggers()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(t.tick(busy: 1, total: 1, accounts: [], flags: all,
                              sessions: [session(1, "busy")], now: start), [])
        t.announceWaiting(pid: 1, now: start)
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              sessions: [session(1, "waiting")], now: start.addingTimeInterval(5)), [])
        // Answered, then a fresh prompt after the grace: the poll pushes again.
        XCTAssertEqual(t.tick(busy: 1, total: 1, accounts: [], flags: all,
                              sessions: [session(1, "busy")], now: start.addingTimeInterval(60)), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              sessions: [session(1, "waiting")],
                              now: start.addingTimeInterval(PushTriggers.hookGrace + 61)),
                       ["waiting on you — repo1 needs an answer"])
    }

    func testWaitingFiresOncePerSessionAndRearmsWhenItLeavesWaiting() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: 1, total: 2, accounts: [], flags: all,
                              sessions: [session(1, "busy"), session(2, "idle")]), [])
        XCTAssertEqual(t.tick(busy: 1, total: 2, accounts: [], flags: all,
                              sessions: [session(1, "waiting"), session(2, "idle")]),
                       ["waiting on you — repo1 needs an answer"])
        // Still waiting: silent.
        XCTAssertEqual(t.tick(busy: 1, total: 2, accounts: [], flags: all,
                              sessions: [session(1, "waiting")]), [])
        // Answered, then waits again later: fires again.
        XCTAssertEqual(t.tick(busy: 1, total: 2, accounts: [], flags: all,
                              sessions: [session(1, "busy")]), [])
        XCTAssertEqual(t.tick(busy: 1, total: 2, accounts: [], flags: all,
                              sessions: [session(1, "waiting")]).count, 1)
    }

    func testWaitingAtLaunchIsSeededSilently() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              sessions: [session(3, "waiting")]), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              sessions: [session(3, "waiting")]), [])
        _ = t.tick(busy: 0, total: 1, accounts: [], flags: all, sessions: [session(3, "idle")])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              sessions: [session(3, "waiting")]).count, 1)
    }

    private func need(_ pid: Int?, _ profile: String, label: String? = "repo",
                      failedAt: Date? = nil) -> AwsLogin.Item {
        AwsLogin.Item(profile: profile, flow: .relay, pid: pid, sessionLabel: label, state: nil,
                      failedAt: failedAt)
    }

    /// #29: a need that failed minutes ago is pushed even on the seeding
    /// look (the relaunch swallowed it); an old one seeds silently; the
    /// same session failing again later on the same profile fires again.
    func testAwsLoginFreshNeedAtLaunchIsPushedAndRefailureRearms() {
        var t = PushTriggers()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(3, "p", failedAt: now.addingTimeInterval(-60)),
                                          need(4, "q", failedAt: now.addingTimeInterval(-3600))],
                              now: now),
                       ["needs AWS login — repo (p)"])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(3, "p", failedAt: now.addingTimeInterval(-60)),
                                          need(4, "q", failedAt: now.addingTimeInterval(-3600))],
                              now: now), [])
        // Same session, same profile, a later failure: news again.
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(3, "p", failedAt: now.addingTimeInterval(600))],
                              now: now.addingTimeInterval(660)),
                       ["needs AWS login — repo (p)"])
    }

    /// #98: the announced keys survive a relaunch — a fresh need already
    /// pushed before the restart is not pushed again by the new instance,
    /// and the set prunes to the current roster for the next persist.
    func testAwsLoginKeysPersistAcrossARelaunch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var first = PushTriggers()
        let fresh = need(3, "p", failedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(first.tick(busy: 0, total: 1, accounts: [], flags: all,
                                  awsLogins: [fresh], now: now).count, 1)
        var relaunched = PushTriggers(memory: first.memory)
        XCTAssertEqual(relaunched.tick(busy: 0, total: 1, accounts: [], flags: all,
                                       awsLogins: [fresh], now: now.addingTimeInterval(30)), [])
        XCTAssertEqual(relaunched.tick(busy: 0, total: 1, accounts: [], flags: all,
                                       awsLogins: [], now: now.addingTimeInterval(60)), [])
        XCTAssertEqual(relaunched.announcedAwsLoginKeys, [])
    }

    func testAwsLoginNeedFiresOncePerSessionAndProfileAndRearms() {
        var t = PushTriggers()
        // The first scanned look seeds silently, even when empty.
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: []), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(1, "banyan-login", label: "Nydus")]),
                       ["needs AWS login — Nydus (banyan-login)"])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(1, "banyan-login", label: "Nydus")]), [])
        // A second session, its own profile: its own news.
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(1, "banyan-login", label: "Nydus"), need(2, "banyan", label: "peon")]),
                       ["needs AWS login — peon (banyan)"])
        // Signed in, then expired again later: fires again.
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: []), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(1, "banyan-login", label: "Nydus")]).count, 1)
    }

    func testAwsLoginNeedAtLaunchIsSeededSilentlyAndUnscannedLooksDoNotSeed() {
        var t = PushTriggers()
        // nil = transcripts not scanned yet: no seeding off an empty look.
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: nil), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [need(3, "p")]), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [need(3, "p")]), [])
        _ = t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [need(3, "p")]).count, 1)
    }

    func testAwsLoginFlagOffStillAdvancesState() {
        var t = PushTriggers()
        var off = all; off.awsLogin = false
        _ = t.tick(busy: 0, total: 1, accounts: [], flags: off, awsLogins: [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: off, awsLogins: [need(7, "p")]), [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [need(7, "p")]), [])
    }

    func testHandStartedLoginWithoutSessionIsNotPushed() {
        var t = PushTriggers()
        _ = t.tick(busy: 0, total: 1, accounts: [], flags: all, awsLogins: [])
        XCTAssertEqual(t.tick(busy: 0, total: 1, accounts: [], flags: all,
                              awsLogins: [need(nil, "p", label: nil)]), [])
    }

    func testWaitingFlagOffStillAdvancesState() {
        var t = PushTriggers()
        var off = all; off.waiting = false
        XCTAssertEqual(t.tick(busy: 1, total: 1, accounts: [], flags: off,
                              sessions: [session(7, "waiting")]), [])
        // Turning the flag on later never fires the stale episode.
        XCTAssertEqual(t.tick(busy: 1, total: 1, accounts: [], flags: all,
                              sessions: [session(7, "waiting")]), [])
    }

    func testSingleTickDipBetweenTurnsStaysSilent() {
        var t = PushTriggers()
        // The dip at minute 5 does not restart the stretch: it counts from minute 0.
        for (busy, minute, expect) in [(3, 0.0, 0), (0, 5, 0), (2, 6, 0), (0, 12, 0), (0, 13, 1)] {
            XCTAssertEqual(t.tick(busy: busy, total: 5, accounts: [], flags: all, now: at(minute)).count,
                           expect, "busy=\(busy) at \(minute)")
        }
    }

    func testAllDeadFiresOnceAndRearmsAfterRecovery() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        let mixed = [acct(1, dead: false, pct: 10), acct(2, dead: true)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: mixed, flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all),
                       ["all 2 accounts exhausted — nothing left to switch to"])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
        _ = t.tick(busy: nil, total: nil, accounts: mixed, flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all).count, 1)
        XCTAssertTrue(PushTriggers.isAllDeadMessage("all 2 accounts exhausted — nothing left to switch to"))
        XCTAssertFalse(PushTriggers.isAllDeadMessage("a1 is back"))
    }

    func testAllDeadAtLaunchIsSeededSilently() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        // Empty first looks (usage not loaded yet) don't seed; the first
        // look with accounts does, and says nothing even when all dead.
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
        _ = t.tick(busy: nil, total: nil, accounts: [acct(1, dead: false, pct: 10), acct(2, dead: true)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all).count, 1)
    }

    func testEmptyOrPartialRosterDoesNotRearmAllDead() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        _ = t.tick(busy: nil, total: nil, accounts: [acct(1, dead: false, pct: 10)], flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all).count, 1)
        // An engine re-probe blanks usage: the roster thins or empties
        // for a tick, then comes back all dead — no repeat.
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: [acct(2, dead: true)], flags: all), [])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: dead, flags: all), [])
    }

    func testNoAccountsIsNeverAllDead() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: [], flags: all), [])
    }

    func testLastAliveWarnsOnceWithHysteresis() {
        var t = PushTriggers()
        let warn = [acct(1, dead: true), acct(2, dead: false, pct: 92)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all),
                       ["last account standing — a2 at 92%"])
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all), [])
        // 87% sits inside the hysteresis band: no re-arm, no repeat.
        _ = t.tick(busy: nil, total: nil,
                   accounts: [acct(1, dead: true), acct(2, dead: false, pct: 87)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all), [])
        // Dropping under 85% re-arms.
        _ = t.tick(busy: nil, total: nil,
                   accounts: [acct(1, dead: true), acct(2, dead: false, pct: 40)],
                   flags: all)
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: warn, flags: all).count, 1)
    }

    func testTwoAliveAccountsNeverWarn() {
        var t = PushTriggers()
        let accounts = [acct(1, dead: false, pct: 95), acct(2, dead: false, pct: 99)]
        XCTAssertEqual(t.tick(busy: nil, total: nil, accounts: accounts, flags: all), [])
    }

    func testDisabledFlagSuppressesTheMessageButAdvancesState() {
        var t = PushTriggers()
        _ = t.tick(busy: nil, total: nil, accounts: [acct(1, dead: false, pct: 10)], flags: all)
        let off = PushTriggers.Flags(sessionsDone: false, allDead: true, lastAlive: true)
        _ = t.tick(busy: 3, total: 5, accounts: [], flags: off, now: at(0))
        _ = t.tick(busy: 0, total: 5, accounts: [], flags: off, now: at(11))
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: off, now: at(12)), [])
        // Turning the flag on afterwards must not fire the stale episode.
        XCTAssertEqual(t.tick(busy: 0, total: 5, accounts: [], flags: all, now: at(13)), [])
    }

    func testWorstPlanPctExcludesSpend() throws {
        let usage = try JSONDecoder().decode(Usage.self, from: Data("""
        {"fiveHour": {"pct": 10}, "sevenDay": {"pct": 55},
         "scoped": [{"name": "Fable", "pct": 70}],
         "spend": {"pct": 100, "used": 5, "limit": 5, "currency": "USD"}}
        """.utf8))
        XCTAssertEqual(PushTriggers.worstPlanPct(usage), 70)
    }
}
