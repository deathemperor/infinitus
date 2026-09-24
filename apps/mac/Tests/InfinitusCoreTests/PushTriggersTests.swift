import XCTest
@testable import InfinitusCore

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
        snap.names = ["claude/a@x.io": "Dragon", "codex/a@x.io": ""]
        XCTAssertEqual(SyncSnapshot.decode(try snap.encoded()), snap)
    }

    /// A file an older Mac wrote has no `names`; it must still decode, or
    /// the reader takes it for "no file" and pushes over it.
    func testSnapshotWithoutNamesDecodes() {
        let data = Data(#"{"app":{"compact_rows":true},"themes":[],"engine":{}}"#.utf8)
        let snap = SyncSnapshot.decode(data)
        XCTAssertEqual(snap?.app["compact_rows"], .bool(true))
        XCTAssertEqual(snap?.names, [:])
    }

    func testNamesMergeKeepsAnotherMacsAccounts() {
        let file = ["claude/a@x.io": "Dragon", "claude/only-there@x.io": "Owl"]
        let mine = SyncNames.rows(provider: .claude, accounts: [
            Account(number: 1, email: "a@x.io", alias: "Wyrm"),
            Account(number: 2, email: "b@x.io"),
            Account(number: 3, email: "", alias: "NoIdentity"),
        ])
        XCTAssertEqual(SyncNames.merge(file, local: mine),
                       ["claude/a@x.io": "Wyrm", "claude/only-there@x.io": "Owl", "claude/b@x.io": ""])
    }

    func testPendingRenamesOnlyWhereTheFileDiffers() {
        let names = ["claude/a@x.io": "Dragon", "claude/b@x.io": "", "claude/c@x.io": "Same",
                     "codex/d@x.io": "OtherFleet", "claude/": "Nobody"]
        let renames = SyncNames.pendingRenames(names: names, provider: .claude, accounts: [
            Account(number: 1, email: "a@x.io"),                    // gains a name
            Account(number: 2, email: "b@x.io", alias: "Old"),      // cleared
            Account(number: 3, email: "c@x.io", alias: "Same"),     // already right
            Account(number: 4, email: "d@x.io", alias: "Kept"),     // the file names a codex slot, not this one
            Account(number: 5, email: "e@x.io", alias: "Kept"),     // unknown to the file
            Account(number: 6, email: ""),                          // no identity, never renamed
        ])
        XCTAssertEqual(renames, [1: "Dragon", 2: ""])
    }
}

final class PushTriggersTests: XCTestCase {
    private func acct(_ n: Int, dead: Bool, pct: Double? = nil) -> PushTriggers.Account {
        PushTriggers.Account(number: n, name: "a\(n)", dead: dead, worstPct: pct)
    }
    private let all = PushTriggers.Flags()

    func testAllDeadFiresOnceAndRearmsAfterRecovery() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        let mixed = [acct(1, dead: false, pct: 10), acct(2, dead: true)]
        XCTAssertEqual(t.tick(accounts: mixed, flags: all), [])
        XCTAssertEqual(t.tick(accounts: dead, flags: all),
                       ["all 2 accounts exhausted — nothing left to switch to"])
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
        _ = t.tick(accounts: mixed, flags: all)
        XCTAssertEqual(t.tick(accounts: dead, flags: all).count, 1)
    }

    func testAllDeadNamesTheModelWhenItAloneKilledEveryone() {
        var t = PushTriggers()
        let fable = (1...2).map {
            PushTriggers.Account(number: $0, name: "a\($0)", dead: true, worstPct: 100, spentModel: "Fable")
        }
        _ = t.tick(accounts: [acct(1, dead: false, pct: 10), acct(2, dead: true)], flags: all)
        XCTAssertEqual(t.tick(accounts: fable, flags: all),
                       ["all 2 accounts out of Fable — nothing left to switch to"])
        // One death by a plan window: the plain line.
        _ = t.tick(accounts: [acct(1, dead: false, pct: 10), acct(2, dead: true)], flags: all)
        XCTAssertEqual(t.tick(accounts: [fable[0], acct(2, dead: true)], flags: all),
                       ["all 2 accounts exhausted — nothing left to switch to"])
    }

    func testAllDeadAtLaunchIsSeededSilently() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        // Empty first looks (usage not loaded yet) don't seed; the first
        // look with accounts does, and says nothing even when all dead.
        XCTAssertEqual(t.tick(accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
        _ = t.tick(accounts: [acct(1, dead: false, pct: 10), acct(2, dead: true)], flags: all)
        XCTAssertEqual(t.tick(accounts: dead, flags: all).count, 1)
    }

    func testEmptyOrPartialRosterDoesNotRearmAllDead() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        _ = t.tick(accounts: [acct(1, dead: false, pct: 10)], flags: all)
        XCTAssertEqual(t.tick(accounts: dead, flags: all).count, 1)
        // An engine re-probe blanks usage: the roster thins or empties
        // for a tick, then comes back all dead — no repeat.
        XCTAssertEqual(t.tick(accounts: [], flags: all), [])
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
        XCTAssertEqual(t.tick(accounts: [acct(2, dead: true)], flags: all), [])
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
    }

    func testNoAccountsIsNeverAllDead() {
        var t = PushTriggers()
        XCTAssertEqual(t.tick(accounts: [], flags: all), [])
    }

    func testLastAliveWarnsOnceWithHysteresis() {
        var t = PushTriggers()
        let warn = [acct(1, dead: true), acct(2, dead: false, pct: 92)]
        XCTAssertEqual(t.tick(accounts: warn, flags: all),
                       ["last account standing — a2 at 92%"])
        XCTAssertEqual(t.tick(accounts: warn, flags: all), [])
        // 87% sits inside the hysteresis band: no re-arm, no repeat.
        _ = t.tick(accounts: [acct(1, dead: true), acct(2, dead: false, pct: 87)], flags: all)
        XCTAssertEqual(t.tick(accounts: warn, flags: all), [])
        // Dropping under 85% re-arms.
        _ = t.tick(accounts: [acct(1, dead: true), acct(2, dead: false, pct: 40)], flags: all)
        XCTAssertEqual(t.tick(accounts: warn, flags: all).count, 1)
    }

    func testTwoAliveAccountsNeverWarn() {
        var t = PushTriggers()
        let accounts = [acct(1, dead: false, pct: 95), acct(2, dead: false, pct: 99)]
        XCTAssertEqual(t.tick(accounts: accounts, flags: all), [])
    }

    /// The last-alive warning survives a relaunch: the blob round-trips
    /// through JSON as the app stores it, and a fresh instance seeded
    /// with it does not repeat the warning.
    func testLastAliveWarningSurvivesARelaunch() {
        var first = PushTriggers()
        let warn = [acct(1, dead: true), acct(2, dead: false, pct: 92)]
        XCTAssertEqual(first.tick(accounts: warn, flags: all).count, 1)
        var relaunched = PushTriggers(memory: first.memory)
        XCTAssertEqual(relaunched.tick(accounts: warn, flags: all), [])
        XCTAssertEqual(relaunched.memory.warnedLastAlive, 2)
        let data = try! JSONEncoder().encode(first.memory)
        XCTAssertEqual(try! JSONDecoder().decode(PushTriggers.Memory.self, from: data), first.memory)
    }

    func testDisabledFlagSuppressesTheMessageButAdvancesState() {
        var t = PushTriggers()
        let dead = [acct(1, dead: true), acct(2, dead: true)]
        let off = PushTriggers.Flags(allDead: false, lastAlive: true)
        _ = t.tick(accounts: dead, flags: off)
        XCTAssertEqual(t.tick(accounts: dead, flags: off), [])
        // Turning the flag on afterwards must not fire the stale episode.
        XCTAssertEqual(t.tick(accounts: dead, flags: all), [])
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
