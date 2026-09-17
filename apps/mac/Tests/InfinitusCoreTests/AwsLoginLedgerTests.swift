import XCTest
@testable import InfinitusCore

final class AwsLoginLedgerTests: XCTestCase {
    private func state(_ profile: String, phase: AwsLogin.Phase, startedAt: Double) -> AwsLogin.State {
        AwsLogin.State(profile: profile, flow: .relay, phase: phase, url: "https://x", userCode: "ABCD",
                       callbackPort: 4321, message: nil, startedAt: startedAt)
    }

    func testSnapshotKeepsFinishedAndTurnsEveryRunningStateIntoAnExplainedFailure() {
        let done = state("a", phase: .done, startedAt: 100)
        let running = state("b", phase: .waitingForBrowser, startedAt: 200)
        let byHand = state("c", phase: .waitingForCode, startedAt: 300)
        let snap = AwsLogin.Ledger.snapshot(running: [running, byHand], finished: [done])
        XCTAssertEqual(snap.map(\.profile), ["a", "b", "c"])
        XCTAssertEqual(snap[1].phase, .failed)
        XCTAssertEqual(snap[1].message, AwsLogin.Ledger.relaunchMessage)
        XCTAssertNil(snap[1].url)
        XCTAssertNil(snap[1].userCode)
        XCTAssertNil(snap[1].callbackPort)
        XCTAssertEqual(snap[2].phase, .failed)
    }

    func testDecodeKeepsRecentOutcomesOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        let states = [
            state("fresh-done", phase: .done, startedAt: t - 3600),
            state("old-done", phase: .done, startedAt: t - 25 * 3600),
            state("fresh-failed", phase: .failed, startedAt: t - 300),
            state("old-failed", phase: .failed, startedAt: t - 900),
            state("in-flight", phase: .waitingForCode, startedAt: t - 10),
        ]
        let back = AwsLogin.Ledger.decode(try AwsLogin.Ledger.encode(states), now: now)
        XCTAssertEqual(back.map(\.profile), ["fresh-done", "fresh-failed"])
        XCTAssertEqual(AwsLogin.Ledger.decode(Data("nope".utf8), now: now), [])
    }
}
