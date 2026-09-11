import XCTest
@testable import InfinitusCore

final class AwsLoginLedgerTests: XCTestCase {
    private func state(_ profile: String, phase: AwsLogin.Phase, pid: Int?, startedAt: Double) -> AwsLogin.State {
        AwsLogin.State(profile: profile, flow: .relay, phase: phase, url: "https://x", userCode: "ABCD",
                       callbackPort: 4321, message: nil, startedAt: startedAt, pid: pid)
    }

    func testSnapshotKeepsFinishedAndTurnsSessionRunsIntoExplainedFailures() {
        let done = state("a", phase: .done, pid: 1, startedAt: 100)
        let forSession = state("b", phase: .waitingForBrowser, pid: 2, startedAt: 200)
        let byHand = state("c", phase: .waitingForCode, pid: nil, startedAt: 300)
        let snap = AwsLogin.Ledger.snapshot(running: [forSession, byHand], finished: [done])
        XCTAssertEqual(snap.map(\.profile), ["a", "b"])
        XCTAssertEqual(snap[1].phase, .failed)
        XCTAssertEqual(snap[1].message, AwsLogin.Ledger.relaunchMessage)
        XCTAssertNil(snap[1].url)
        XCTAssertNil(snap[1].userCode)
        XCTAssertNil(snap[1].callbackPort)
        XCTAssertEqual(snap[1].pid, 2)
    }

    func testDecodeKeepsRecentOutcomesOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        let states = [
            state("fresh-done", phase: .done, pid: 1, startedAt: t - 3600),
            state("old-done", phase: .done, pid: 1, startedAt: t - 25 * 3600),
            state("fresh-failed", phase: .failed, pid: 2, startedAt: t - 600),
            state("old-failed", phase: .failed, pid: 2, startedAt: t - 2 * 3600),
            state("in-flight", phase: .waitingForCode, pid: 3, startedAt: t - 10),
        ]
        let back = AwsLogin.Ledger.decode(try AwsLogin.Ledger.encode(states), now: now)
        XCTAssertEqual(back.map(\.profile), ["fresh-done", "fresh-failed"])
        XCTAssertEqual(AwsLogin.Ledger.decode(Data("nope".utf8), now: now), [])
    }

    func testCurrentDropsOutcomesOlderThanTheNeed() {
        let need = Date(timeIntervalSince1970: 1000)
        let older = state("p", phase: .done, pid: 1, startedAt: 900)
        let newer = state("p", phase: .done, pid: 1, startedAt: 1100)
        let inFlight = state("p", phase: .waitingForCode, pid: 1, startedAt: 900)
        XCTAssertNil(AwsLogin.current(older, needFailedAt: need))
        XCTAssertEqual(AwsLogin.current(newer, needFailedAt: need), newer)
        XCTAssertEqual(AwsLogin.current(inFlight, needFailedAt: need), inFlight)
        XCTAssertEqual(AwsLogin.current(older, needFailedAt: nil), older)
        XCTAssertNil(AwsLogin.current(nil, needFailedAt: need))
    }
}
