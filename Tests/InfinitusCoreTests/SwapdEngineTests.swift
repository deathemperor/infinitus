#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// The swapd adapter (#8, phase 1): `list --json` → neutral fleets.
/// The fixture IS swapd's own `contract.rs` snapshot of the spec §4
/// example, so a contract change breaks this test before it reaches a row.
final class SwapdMappingTests: XCTestCase {
    /// 01:00 UTC on the fixture's day — countdowns are then exact numbers
    /// instead of "whenever the suite ran".
    let now = WeeklyRoll.parse("2026-09-09T01:00:00Z")!

    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func list(_ json: String) throws -> SwapdList {
        try JSONDecoder().decode(SwapdList.self, from: Data(json.utf8))
    }

    func testContractFixtureMapsToOneClaudeFleet() throws {
        let list = try JSONDecoder().decode(SwapdList.self, from: fixture("swapd-list.json"))
        XCTAssertEqual(list.schemaVersion, 1)
        let fleets = SwapdMapping.fleets(from: list, now: now)
        XCTAssertEqual(fleets.count, 1)
        let fleet = fleets[0]
        XCTAssertEqual(fleet.key, "swapd/claude")
        XCTAssertEqual(fleet.activeNumber, 2)
        XCTAssertEqual(fleet.nextCandidate, 1)
        XCTAssertEqual(fleet.nextRecovery, NextRecovery(number: 8, at: "2026-09-09T03:29:59Z"))
        // The engine's list is not `AccountList` bytes and knows nothing
        // about this Mac's sessions.
        XCTAssertNil(fleet.raw)
        XCTAssertNil(fleet.liveSessions)

        let account = fleet.accounts[0]
        XCTAssertEqual(account.number, 1, "slot is the app's number")
        XCTAssertEqual(account.email, "you@example.com")
        XCTAssertEqual(account.organizationName, "Example Org")
        XCTAssertEqual(account.alias, "death2")
        XCTAssertEqual(account.icon, "🩸")
        XCTAssertEqual(account.plan, "Max 20x")
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertEqual(account.disabled, false)
        XCTAssertEqual(account.preferred, false)
        XCTAssertEqual(account.usageFetchedAt, "2026-09-09T01:11:03Z")
        XCTAssertEqual(account.usageAgeSeconds, 7.6)

        XCTAssertEqual(account.usage?.fiveHour?.pct, 0)
        XCTAssertEqual(account.usage?.fiveHour?.resetsAt, "2026-09-09T05:59:59Z")
        // Countdown/clock are NOT in the contract — the app formats them.
        XCTAssertEqual(account.usage?.fiveHour?.countdown, "4h 59m")
        XCTAssertNotNil(account.usage?.fiveHour?.clock)
        XCTAssertNil(account.usage?.fiveHour?.name, "name rides scoped windows only")
        XCTAssertEqual(account.usage?.sevenDay?.pct, 19)
        XCTAssertEqual(account.usage?.sevenDay?.expectedPct, 20.3)
        XCTAssertEqual(account.usage?.sevenDay?.aheadOfPace, true)
        XCTAssertEqual(account.usage?.sevenDay?.willLastToReset, true)
        XCTAssertNil(account.usage?.sevenDay?.projectedExhaustionAt, "absent, not null")
        XCTAssertEqual(account.usage?.scoped?.map(\.name), ["Fable"])
        XCTAssertEqual(account.usage?.scoped?.first?.pct, 29)
        // `lastGood` with no windows is a fetch that carried nothing.
        XCTAssertEqual(account.lastGoodFetchedAt, "2026-09-09T01:11:03Z")
        XCTAssertNil(account.lastGoodUsage)
        // The engine's own list rides along, in its report order, each
        // window named — `UsageWindow` has no `kind` to name them by.
        XCTAssertEqual(account.windows?.map(\.name), ["5h", "7d", "Fable"])
        XCTAssertEqual(account.windows?.map(\.pct), [0, 19, 29])
    }

    /// The payload a fresh install prints (probed against the real binary):
    /// absent optionals, no accounts, and nothing to render.
    func testInstalledProviderWithNoAccountsYieldsNoFleet() throws {
        let list = try list(#"{"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[]}]}"#)
        XCTAssertNil(list.providers[0].activeSlot)
        XCTAssertTrue(SwapdMapping.fleets(from: list, now: now).isEmpty)
    }

    func testUnknownProviderLandsInOtherOnlyOnce() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[
          {"provider":"grok","installed":true,"accounts":[\(Self.account(slot: 1))]},
          {"provider":"mystery","installed":true,"accounts":[\(Self.account(slot: 1))]},
          {"provider":"codex","installed":true,"accounts":[\(Self.account(slot: 1))]}]}
        """)
        // One state per (engine, provider) key: a second `.other` would
        // collide on "swapd/other", so the first one wins.
        XCTAssertEqual(SwapdMapping.fleets(from: list, now: now).map(\.provider), [.other, .codex])
    }

    /// The shape the engine ACTUALLY emits (`collect.rs account_view`:
    /// every non-`ok` status empties `windows` and moves the measurement
    /// into `lastGood`) — not the shape spec §4's prose describes. A
    /// stale row has no sentinel note to show, so it must still show
    /// numbers; served from `lastGood`, it does.
    func testStaleWithEmptyWindowsIsServedFromLastGood() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"stale","windows":[],
           "lastGood":{"fetchedAt":"2026-09-09T00:00:00Z","ageSeconds":900,
                       "windows":[{"kind":"5h","pct":41,"resetsAt":"2026-09-09T05:59:59Z"}]}}]}]}
        """)
        let account = SwapdMapping.fleets(from: list, now: now)[0].accounts[0]
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertNil(SentinelNotes.note(for: account.usageStatus), "stale is not a sentinel")
        // Without this the row would be both noteless and dataless, and
        // `usage == nil` drops an account out of liveness and revival.
        XCTAssertEqual(account.usage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.windows?.map(\.name), ["5h"])
        // The age shown is the fetch's, not this pass's.
        XCTAssertEqual(account.usageFetchedAt, "2026-09-09T00:00:00Z")
        XCTAssertEqual(account.usageAgeSeconds, 900)
        XCTAssertEqual(account.lastGoodUsage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.lastGoodAgeSeconds, 900)
    }

    /// The shape spec §4's prose describes — `windows` IS the last good
    /// fetch. Read as is, so either emitter renders the same row.
    func testStaleWithItsOwnWindowsIsServedAsIs() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"stale",
           "fetchedAt":"2026-09-09T00:00:00Z","ageSeconds":900,
           "windows":[{"kind":"5h","pct":41,"resetsAt":"2026-09-09T05:59:59Z"}]}]}]}
        """)
        let account = SwapdMapping.fleets(from: list, now: now)[0].accounts[0]
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertEqual(account.usage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.usageAgeSeconds, 900)
    }

    /// A sentinel keeps `usage` nil even though the engine parked a
    /// measurement in `lastGood`: its NOTE is the row (cswap's sentinel
    /// rows read the same), and serving numbers under "re-login needed"
    /// would say the account works.
    func testASentinelShowsItsNoteRatherThanTheParkedMeasurement() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"relogin-required","windows":[],
           "lastGood":{"fetchedAt":"2026-09-08T00:00:00Z","ageSeconds":90000,
                       "windows":[{"kind":"5h","pct":41}]}}]}]}
        """)
        let account = SwapdMapping.fleets(from: list, now: now)[0].accounts[0]
        XCTAssertEqual(account.usageStatus, "relogin_required")
        XCTAssertNil(account.usage)
        XCTAssertNil(account.windows)
        XCTAssertNotNil(SentinelNotes.note(for: account.usageStatus))
        // Kept for a display that wants to say how stale the last read was.
        XCTAssertEqual(account.lastGoodUsage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.lastGoodAgeSeconds, 90000)
    }

    func testSentinelStatusesTakeCswapsSpelling() {
        XCTAssertEqual(SwapdMapping.usageStatus("relogin-required"), "relogin_required")
        XCTAssertEqual(SwapdMapping.usageStatus("token-expired"), "token_expired")
        XCTAssertEqual(SwapdMapping.usageStatus("no-credentials"), "no_credentials")
        XCTAssertEqual(SwapdMapping.usageStatus("api-key"), "api_key")
        // …because every surface renders the note keyed on that spelling.
        XCTAssertEqual(SentinelNotes.short(for: SwapdMapping.usageStatus("relogin-required")),
                       "re-login needed")
        XCTAssertNotNil(SentinelNotes.note(for: SwapdMapping.usageStatus("api-key")))
        // A status this build predates still reads as a note, never a crash.
        XCTAssertEqual(SwapdMapping.usageStatus("unsupported"), "unsupported")
    }

    func testSpendNeedsItsMoneyAndUnknownKindsBecomeNamedGauges() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"ok","windows":[
             {"kind":"spend","pct":25,"used":5,"limit":20,"currency":"USD","resetsAt":"2026-10-01T00:00:00Z"},
             {"kind":"monthly","pct":12},
             {"kind":"daily","pct":3}]},
          {"slot":2,"email":"d@b.c","organizationName":"","organizationUuid":"","active":false,
           "disabled":false,"preferred":false,"usageStatus":"ok","windows":[
             {"kind":"spend","pct":25,"used":5}]}]}]}
        """)
        let accounts = SwapdMapping.fleets(from: list, now: now)[0].accounts
        XCTAssertEqual(accounts[0].usage?.spend?.used, 5)
        XCTAssertEqual(accounts[0].usage?.spend?.limit, 20)
        XCTAssertEqual(accounts[0].usage?.spend?.currency, "USD")
        // daily/monthly have no home of their own: shown, never dropped.
        XCTAssertEqual(accounts[0].usage?.scoped?.map(\.name), ["monthly", "daily"])
        // A spend pool with no limit or currency renders nothing.
        XCTAssertNil(accounts[1].usage?.spend)
        XCTAssertNil(accounts[1].usage, "no window left to show")
    }

    static func account(slot: Int) -> String {
        """
        {"slot":\(slot),"email":"a\(slot)@b.c","organizationName":"","organizationUuid":"",
         "active":true,"disabled":false,"preferred":false,"usageStatus":"ok","windows":[]}
        """
    }
}

/// The subprocess side: what the engine actually runs, and what it makes
/// of the answers. A stub `swapd` script stands in for the binary — the
/// only engine touchpoint is `swapd … --json`, so the stub is the whole
/// contract surface.
final class SwapdEngineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swapd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `list` answers with one healthy account; `refresh`/`ignite` answer
    /// with the same account carrying the window the fetch just saw;
    /// anything else answers the error envelope on stdout and exits 1,
    /// the way swapd's `--json` failures do.
    func makeEngine() throws -> SwapdEngine {
        let argv = dir.appendingPathComponent("argv").path
        func payload(_ resets: String?) -> String {
            let window = resets.map { #"{"kind":"5h","pct":3,"resetsAt":"\#($0)"}"# } ?? ""
            return """
            {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"activeSlot":1,\
            "accounts":[{"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"",\
            "active":true,"disabled":false,"preferred":false,"usageStatus":"ok","windows":[\(window)]}]}]}
            """
        }
        let script = """
        #!/bin/sh
        echo "$@" >> "\(argv)"
        case "$1" in
          list|prefer|alias) echo '\(payload(nil))' ;;
          refresh|ignite) echo '\(payload("2026-09-09T05:59:59Z"))' ;;
          *) echo '{"schemaVersion":1,"error":{"code":"no-such-slot","message":"no slot 9 for claude"}}'; exit 1 ;;
        esac
        """
        let binary = dir.appendingPathComponent("swapd")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return SwapdEngine(cli: SwapdCLI(binaryPath: binary.path))
    }

    func argv() throws -> [String] {
        let text = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    func testSnapshotIsOneListCallStampedWithTheEngineID() async throws {
        let fleets = try await makeEngine().snapshot()
        XCTAssertEqual(try argv(), ["list --json"], "one subprocess, no per-account calls")
        XCTAssertEqual(fleets.map(\.key), ["swapd/claude"])
        XCTAssertEqual(fleets[0].accounts.map(\.number), [1])
    }

    /// The ignite path's second half: the reset the popup announces comes
    /// from the fetch this call forced, not from the next poll (#338).
    func testRefreshForcesTheSlotAndAnswersWithThatProvidersFleet() async throws {
        let fleet = try await makeEngine().refresh(fleet: .claude, number: 1)
        XCTAssertEqual(try argv(), ["refresh --slot 1 --provider claude --json"])
        XCTAssertEqual(fleet.provider, .claude)
        XCTAssertEqual(fleet.accounts[0].usage?.fiveHour?.resetsAt, "2026-09-09T05:59:59Z")
    }

    func testAFailedVerbThrowsTheEnginesOwnMessage() async throws {
        do {
            try await makeEngine().remove(fleet: .claude, number: 9)
            XCTFail("a refusal must throw")
        } catch let error as CLIError {
            // The envelope rides STDOUT with a non-zero exit — "exited 1"
            // would tell the user nothing.
            XCTAssertEqual(error.message, "no slot 9 for claude")
        }
        XCTAssertEqual(try argv(), ["remove 9 --yes --provider claude --json"],
                       "--yes is the confirmation swapd demands")
    }

    /// swapd's schema is additive-stable: a BUMP means a shape this build
    /// cannot read, and reading it anyway would render wrong numbers.
    func testANewerSchemaIsRefusedInsteadOfRendered() throws {
        let cli = try makeEngine().cli
        XCTAssertNoThrow(try cli.decodeList(Data(#"{"schemaVersion":1,"providers":[]}"#.utf8)))
        do {
            _ = try cli.decodeList(Data(#"{"schemaVersion":2,"providers":[]}"#.utf8))
            XCTFail("a bumped schema must be refused")
        } catch let error as EngineError {
            XCTAssertEqual(error, .unsupported("swapd speaks schema v2; this build reads v1"))
        }
    }

    func testWritesCarryTheProviderAndAnUnknownOneIsRefused() async throws {
        let engine = try makeEngine()
        try await engine.setPreferred(fleet: .claude, number: 2, true)
        try await engine.rename(fleet: .claude, number: 2, "  ")
        do {
            try await engine.switchTo(fleet: .other, number: 1)
            XCTFail("`.other` has no id to send back")
        } catch let error as EngineError {
            XCTAssertEqual(error, .unsupported(
                "that provider (swapd calls it something this build doesn't know)"))
        }
        XCTAssertEqual(try argv(), ["prefer 2 on --provider claude --json",
                                    "alias 2 --unset --provider claude --json"])
    }

    func testCapabilitiesOmitWhatSwapdHasNoVerbFor() async throws {
        let engine = try makeEngine()
        XCTAssertTrue(engine.capabilities.contains(.refreshAccount))
        for missing in [EngineCapabilities.costReport, .addOAuth, .notify] {
            XCTAssertFalse(engine.capabilities.contains(missing))
        }
        do {
            _ = try await engine.usageReport(days: 7)
            XCTFail("no cost report")
        } catch let error as EngineError {
            XCTAssertEqual(error, .unsupported("costReport"))
        }
        // The default the protocol gives every other engine.
        XCTAssertFalse(CswapEngine(cli: CswapCLI(binaryPath: "/bin/true"))
            .capabilities.contains(.refreshAccount))
    }
}
#endif
