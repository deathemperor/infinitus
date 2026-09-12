import XCTest
@testable import InfinitusCore

final class ResumeGateTests: XCTestCase {
    let stop = Date(timeIntervalSince1970: 1000)
    let now = Date(timeIntervalSince1970: 2000)

    func testStaleAliveVerdictIsHeld() {
        // The 2026-09-01 loop: usage fetched BEFORE the stop said "alive".
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 1,
            activeFetchedAt: Date(timeIntervalSince1970: 900),
            lastNudge: nil, now: now))
    }

    func testAliveVerdictMomentsBeforeStopNudges() {
        // 2026-09-03: switch + fresh poll at :37, the old token's stop at
        // :56 — the account cannot have died in 19 s; nudge.
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 6, currentActive: 6,
            activeFetchedAt: Date(timeIntervalSince1970: 981),
            lastNudge: nil, now: now))
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 6, currentActive: 6,
            activeFetchedAt: Date(timeIntervalSince1970: 1000 - ResumeGate.freshBeforeStop - 1),
            lastNudge: nil, now: now))
    }

    func testFreshAliveVerdictAfterStopNudges() {
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 1,
            activeFetchedAt: Date(timeIntervalSince1970: 1500),
            lastNudge: nil, now: now))
    }

    func testSwitchSinceStopNudgesEvenOnOldPoll() {
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 900),
            lastNudge: nil, now: now))
    }

    func testSwitchHoldsUntilTheAccountIsStable() {
        // #136: the engine flipped #2 → #1 → #2 → #1 in under a minute;
        // a nudge 10 s after a switch landed on the dead account.
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 1995),
            lastNudge: nil, activeSince: now.addingTimeInterval(-10), now: now))
        // Stable for 40 s with the only poll before the switch: the
        // switch is the poll (#964).
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 1950),
            lastNudge: nil, activeSince: now.addingTimeInterval(-40), now: now))
        // Stable and polled alive since the switch: nudge.
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 1980),
            lastNudge: nil, activeSince: now.addingTimeInterval(-40), now: now))
    }

    func testSwitchInstantCountsAsThePollForTheTarget() {
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 7, currentActive: 11,
            activeFetchedAt: nil,
            lastNudge: nil, activeSince: now.addingTimeInterval(-35), now: now))
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 7, currentActive: 11,
            activeFetchedAt: nil,
            lastNudge: nil, activeSince: now.addingTimeInterval(-20), now: now))
    }

    func testCooldownBlocksWhateverElseIsTrue() {
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 1500),
            lastNudge: now.addingTimeInterval(-ResumeGate.cooldown + 5),
            now: now))
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 1, currentActive: 2,
            activeFetchedAt: nil,
            lastNudge: now.addingTimeInterval(-ResumeGate.cooldown - 5),
            now: now))
    }

    func testUnknownStopTimeWithoutSwitchHolds() {
        XCTAssertFalse(ResumeGate.allows(
            stoppedAt: nil, firstSeenActive: 1, currentActive: 1,
            activeFetchedAt: Date(timeIntervalSince1970: 1500),
            lastNudge: nil, now: now))
    }

    func testFindStoppedParsesTimestamp() throws {
        // A minimal transcript whose last decisive entry is a limit stop
        // with a timestamp.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rg-\(UUID().uuidString)")
        let cwd = "/tmp/proj"
        let sid = "abc"
        let tdir = dir.appendingPathComponent("projects/-tmp-proj")
        try FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
        let entry = """
        {"type":"assistant","isApiErrorMessage":true,"error":"rate_limit",\
        "uuid":"u1","timestamp":"2026-09-01T05:50:00.000Z",\
        "message":{"content":[{"type":"text","text":"limit"}]}}
        """
        try (entry + "\n").write(to: tdir.appendingPathComponent("\(sid).jsonl"),
                                 atomically: true, encoding: .utf8)
        let rec = ClaudeSessionRecord(pid: 1_000_000, sessionId: sid, cwd: cwd)
        let stops = Transcript.findStopped(sessions: [rec], claudeDir: dir)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops[0].stoppedAt,
                       UsageHistory.parseISO("2026-09-01T05:50:00.000Z"))
    }

    func testRearmIdleMeasuredAgainstStop() {
        // Session idle 3h by tty clock, but the stop hit 2h55m ago —
        // it was active 5 minutes before the limit: swept.
        let host = FakeHost(
            surfaces: [PtySurface(ref: "r1", tty: "ttys001", pids: [42])],
            screens: [""])
        let session = ClaudeSessionRecord(pid: 42, sessionId: "s1", cwd: "/x")
        let now = Date(timeIntervalSince1970: 100_000)
        let stopAt = now.addingTimeInterval(-10_500)   // 2h55m ago
        let result = PtyNudge.rearmRemoteControl(
            hosts: [host], sessions: [session], selfPids: [],
            activeWithin: 3600, confirm: false,
            ttyOfPid: { _ in "ttys001" },
            ancestorsOf: { [$0] },
            idleSeconds: { _ in 10_800 },              // 3h
            sleep: { _ in },
            stoppedAt: { _ in stopAt },
            now: { now })
        XCTAssertEqual(result.skippedIdle, 0)
        XCTAssertEqual(result.sent.count, 1)
        // Without the stop the same numbers skip it.
        let plain = PtyNudge.rearmRemoteControl(
            hosts: [host], sessions: [session], selfPids: [],
            activeWithin: 3600, confirm: false,
            ttyOfPid: { _ in "ttys001" },
            ancestorsOf: { [$0] },
            idleSeconds: { _ in 10_800 },
            sleep: { _ in },
            now: { now })
        XCTAssertEqual(plain.skippedIdle, 1)
    }

    /// #621: two stops, one eligible and one held. After the tick that
    /// resumed the eligible one, only ITS stop (still standing after a
    /// best effort) is remembered as nudged; the held one stays out of
    /// the set so the next tick gates it again with a fresh verdict.
    func testAHeldStopIsNotMarkedNudgedByANeighboursResume() {
        let attempted: Set<String> = ["eligible-stop"]
        let stillStopped = ["eligible-stop", "held-stop", ""]
        XCTAssertEqual(ResumeGate.standing(stillStopped: stillStopped, attempted: attempted), ["eligible-stop"])
        // A fresh alive verdict after the stop lets the held one through.
        XCTAssertTrue(ResumeGate.allows(
            stoppedAt: stop, firstSeenActive: 2, currentActive: 2,
            activeFetchedAt: Date(timeIntervalSince1970: 1500), lastNudge: nil, activeSince: nil))
    }
}
