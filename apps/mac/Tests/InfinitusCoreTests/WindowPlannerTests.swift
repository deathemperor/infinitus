import XCTest
@testable import InfinitusCore

final class WindowPlannerTests: XCTestCase {
    private typealias S = WindowPlanner.AccountState

    private func win(_ pct: Double, resetsAt: Double?) -> UsageSample.Window {
        .init(pct: pct, resetsAt: resetsAt)
    }

    private func sample(t: Double, email: String = "a@x", number: Int = 1,
                        fh: UsageSample.Window? = nil, active: Bool? = nil) -> UsageSample {
        UsageSample(t: t, email: email, number: number,
                    fiveHour: fh, sevenDay: nil, scoped: nil, active: active)
    }

    // Active at 60% burning 20%/h → binds in 2h; window resets in 4h.
    private let active = S(number: 1, email: "main@x", active: true,
                           fiveHourPct: 60, fiveHourResetsAt: 10_000 + 4 * 3600, weeklyPct: 40)

    func testColdCandidateGetsIgnitedThenSwitchedThenResets() {
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        let plan = WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.bindAt, 10_000 + 2 * 3600)
        XCTAssertEqual(plan?.steps.map(\.action), [.ignite(2), .switchTo(2), .reset(2)])
        XCTAssertEqual(plan?.steps[0].at, 10_000)
        XCTAssertEqual(plan?.steps[1].at, 10_000 + 2 * 3600)
        XCTAssertEqual(plan?.steps[2].at, 10_000 + 18_000)
        XCTAssertTrue(plan!.ignites)
    }

    func testBindAnchorsToTheSampleTimeAndNeverThePast() {
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        let early = WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 20,
                                       busySessions: 1, now: 10_000, measuredAt: 10_000 - 600)
        let later = WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 20,
                                       busySessions: 1, now: 10_300, measuredAt: 10_000 - 600)
        XCTAssertEqual(early?.bindAt, 10_000 - 600 + 2 * 3600)
        // The ignite step is "now" by design; the bind and the switch hold still.
        XCTAssertEqual(early?.bindAt, later?.bindAt, "the same sample plans the same bind on the next poll")
        XCTAssertEqual(early?.steps[1], later?.steps[1])
        let stale = S(number: 1, email: "main@x", active: true,
                      fiveHourPct: 99, fiveHourResetsAt: 10_000 + 4 * 3600, weeklyPct: 40)
        let plan = WindowPlanner.plan(accounts: [stale, cold], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000, measuredAt: 10_000 - 3600)
        XCTAssertEqual(plan?.bindAt, 10_000)
    }

    func testWarmCandidateIsOnlySwitchedTo() {
        // Resets 2h after the bind — plenty left to land on.
        let warm = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 30, fiveHourResetsAt: 10_000 + 4 * 3600, weeklyPct: 20)
        let plan = WindowPlanner.plan(accounts: [active, warm], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000)
        XCTAssertEqual(plan?.steps.map(\.action), [.switchTo(2), .reset(2)])
        XCTAssertEqual(plan?.steps[1].at, 10_000 + 4 * 3600)
        XCTAssertFalse(plan!.ignites)
    }

    func testWarmCandidateResettingBeforeTheBindGetsNoResetStep() {
        // Resets 1h from now, 1h before the bind — fresh by the switch, so
        // the plan is the switch alone (no reset step dated before it).
        let warm = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 80, fiveHourResetsAt: 10_000 + 3600, weeklyPct: 20)
        let plan = WindowPlanner.plan(accounts: [active, warm], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000)
        XCTAssertEqual(plan?.steps.map(\.action), [.switchTo(2)])
        XCTAssertEqual(plan?.steps[0].at, 10_000 + 2 * 3600)
        XCTAssertTrue(plan!.steps[0].why.contains("fresh"))
    }

    func testHoldWhenResetLandsWithinStallTolerance() {
        // Binds in 2h, resets 10 min later → hold, no candidate needed.
        let near = S(number: 1, email: "main@x", active: true,
                     fiveHourPct: 60, fiveHourResetsAt: 10_000 + 2 * 3600 + 600, weeklyPct: 40)
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        let plan = WindowPlanner.plan(accounts: [near, cold], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000)
        XCTAssertEqual(plan?.steps.map(\.action), [.hold(1), .reset(1)])
    }

    func testNothingToPlanCases() {
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        // No sprint running.
        XCTAssertNil(WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 20,
                                        busySessions: 0, now: 10_000))
        // No measurable burn.
        XCTAssertNil(WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: nil,
                                        busySessions: 1, now: 10_000))
        // Burning so slowly the window resets first (4h left, 40% at 5%/h = 8h).
        XCTAssertNil(WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 5,
                                        busySessions: 1, now: 10_000))
        // Bind beyond the horizon (2h default): 40% at 15%/h = 2h40.
        XCTAssertNil(WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 15,
                                        busySessions: 1, now: 10_000))
        // Active has no ticking window.
        let idle = S(number: 1, email: "main@x", active: true,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 40)
        XCTAssertNil(WindowPlanner.plan(accounts: [idle, cold], burnPctPerHour: 20,
                                        busySessions: 1, now: 10_000))
    }

    func testCandidateRulesHeadroomReserveAndUsability() {
        let spent = S(number: 2, email: "spent@x", active: false,
                      fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 97)   // last reserve
        let disabled = S(number: 3, email: "off@x", active: false, disabled: true,
                         fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 0)
        let boundLate = S(number: 4, email: "bound@x", active: false,
                          fiveHourPct: 100, fiveHourResetsAt: 10_000 + 3 * 3600, weeklyPct: 10)
        let boundEarly = S(number: 5, email: "soon@x", active: false,
                           fiveHourPct: 100, fiveHourResetsAt: 10_000 + 3600, weeklyPct: 50)
        let plan = WindowPlanner.plan(accounts: [active, spent, disabled, boundLate, boundEarly],
                                      burnPctPerHour: 20, busySessions: 1, now: 10_000)
        // Only #5 is usable at the bind (its 5h resets before it) and inside
        // the reserve floor; it's not cold (window ticking) → switch only.
        XCTAssertEqual(plan?.steps.first?.action, .switchTo(5))
        XCTAssertNil(WindowPlanner.plan(accounts: [active, spent, disabled, boundLate],
                                        burnPctPerHour: 20, busySessions: 1, now: 10_000))
    }

    func testWarmCandidateWithTooLittleLeftAtTheBindIsSkipped() {
        // #2's window resets 30 min after the bind — landing on it would
        // give 30 min and a stall. #3 is cold, so it gets ignited instead.
        let short = S(number: 2, email: "short@x", active: false,
                      fiveHourPct: 30, fiveHourResetsAt: 10_000 + 2 * 3600 + 1800, weeklyPct: 10)
        let cold = S(number: 3, email: "cold@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 40)
        let plan = WindowPlanner.plan(accounts: [active, short, cold], burnPctPerHour: 20,
                                      busySessions: 1, now: 10_000)
        XCTAssertEqual(plan?.steps.first?.action, .ignite(3))
        // With only the short one, nothing is worth planning.
        XCTAssertNil(WindowPlanner.plan(accounts: [active, short], burnPctPerHour: 20,
                                        busySessions: 1, now: 10_000))
        // Exactly the minimum left is fine.
        let enough = S(number: 2, email: "ok@x", active: false,
                       fiveHourPct: 30, fiveHourResetsAt: 10_000 + 2 * 3600 + 90 * 60, weeklyPct: 10)
        XCTAssertEqual(WindowPlanner.plan(accounts: [active, enough], burnPctPerHour: 20,
                                          busySessions: 1, now: 10_000)?.steps.first?.action,
                       .switchTo(2))
    }

    func testIgnitionNeedsEnoughWindowLeftAtTheBind() {
        // Horizon widened to 4h: a bind 3h45 out would leave an ignited
        // window (5h) only 1h15 at the switch — below the 90 min floor.
        var config = WindowPlanner.Config()
        config.horizon = 4 * 3600
        let far = S(number: 1, email: "main@x", active: true,
                    fiveHourPct: 25, fiveHourResetsAt: 10_000 + 4 * 3600 + 3600, weeklyPct: 40)
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        XCTAssertNil(WindowPlanner.plan(accounts: [far, cold], burnPctPerHour: 20,
                                        busySessions: 1, now: 10_000, config: config))
        // At 30%/h the bind is 2h30 out → 2h30 left at the switch → ignite.
        XCTAssertEqual(WindowPlanner.plan(accounts: [far, cold], burnPctPerHour: 30,
                                          busySessions: 1, now: 10_000, config: config)?.steps.first?.action,
                       .ignite(2))
    }

    func testBurnRateInsideOneWindow() {
        let s = [sample(t: 1000, fh: win(10, resetsAt: 20_000)),
                 sample(t: 2800, fh: win(25, resetsAt: 20_000.3)),   // 30 min, +15
                 sample(t: 400, fh: win(90, resetsAt: 5000))]         // older window, ignored
        XCTAssertEqual(WindowTelemetry.burnRate(s, email: "a@x", now: 3000)!, 30, accuracy: 0.01)
        // Too short an observation.
        XCTAssertNil(WindowTelemetry.burnRate([sample(t: 2500, fh: win(10, resetsAt: 20_000)),
                                               sample(t: 2800, fh: win(25, resetsAt: 20_000))],
                                              email: "a@x", now: 3000))
        // Window rolled inside the lookback: only samples of the current one count.
        let rolled = [sample(t: 1000, fh: win(90, resetsAt: 1500)),
                      sample(t: 1600, fh: win(2, resetsAt: 19_500)),
                      sample(t: 2800, fh: win(8, resetsAt: 19_500))]
        XCTAssertEqual(WindowTelemetry.burnRate(rolled, email: "a@x", now: 3000)!, 18, accuracy: 0.01)
    }

    func testReplayCountsSwitchesColdTargetsAndStalls() {
        // a active and bound from t=100 to t=700 (stall 600s), switch to b
        // at 700 (b had no window: cold), b runs, switch back to a at 1300
        // (a's window still ticking: warm).
        let s = [sample(t: 100, email: "a", fh: win(100, resetsAt: 5000), active: true),
                 sample(t: 100, email: "b", fh: nil, active: false),
                 sample(t: 400, email: "a", fh: win(100, resetsAt: 5000), active: true),
                 sample(t: 700, email: "b", fh: win(1, resetsAt: 18_700), active: true),
                 sample(t: 700, email: "a", fh: win(100, resetsAt: 5000), active: false),
                 sample(t: 1000, email: "b", fh: win(20, resetsAt: 18_700), active: true),
                 sample(t: 1300, email: "a", fh: win(100, resetsAt: 5000), active: true),
                 sample(t: 1600, email: "a", fh: win(100, resetsAt: 5000), active: true)]
        let r = WindowPlanner.replay(s, from: 0, to: 2000)
        XCTAssertEqual(r.switches, 2)
        XCTAssertEqual(r.coldSwitches, 1)
        // First stall 100→700, second 1300→2000 (range end).
        XCTAssertEqual(r.stalledSeconds, 600 + 700, accuracy: 0.001)
        XCTAssertTrue(r.sawActiveFlag)

        // Range edge: pre-range samples still inform the cold check, and
        // only in-range switches count.
        let late = WindowPlanner.replay(s, from: 1200, to: 2000)
        XCTAssertEqual(late.switches, 1)
        XCTAssertEqual(late.coldSwitches, 0)
        XCTAssertEqual(late.stalledSeconds, 700, accuracy: 0.001)
    }

    func testPayloadAndIgniterArguments() throws {
        let cold = S(number: 2, email: "spare@x", active: false,
                     fiveHourPct: 0, fiveHourResetsAt: nil, weeklyPct: 20)
        let plan = try XCTUnwrap(WindowPlanner.plan(accounts: [active, cold], burnPctPerHour: 20,
                                                    busySessions: 1, now: 10_000))
        XCTAssertEqual(plan.igniteNumber, 2)
        let payload = WindowPlanner.Payload(plan)
        XCTAssertEqual(payload.steps.map(\.action), ["ignite", "switch", "reset"])
        XCTAssertEqual(payload.steps.map(\.number), [2, 2, 2])
        XCTAssertEqual(payload.bindAt, plan.bindAt)
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(WindowPlanner.Payload.self, from: data), payload)
        XCTAssertEqual(WindowPlanner.igniterArguments(number: 2),
                       ["run", "2", "--", "-p", ".", "--max-turns", "1"])
    }

    func testReplayWithoutActiveFlagSeesNothing() {
        let s = [sample(t: 100, email: "a", fh: win(100, resetsAt: 5000)),
                 sample(t: 700, email: "b", fh: win(1, resetsAt: 18_700))]
        let r = WindowPlanner.replay(s, from: 0, to: 2000)
        XCTAssertEqual(r.switches, 0)
        XCTAssertEqual(r.stalledSeconds, 0)
        XCTAssertFalse(r.sawActiveFlag)
    }

    func testSampleActiveFlagRoundTripsAndStaysOptional() throws {
        let with = sample(t: 1, active: true)
        let data = try JSONEncoder().encode(with)
        XCTAssertEqual(try JSONDecoder().decode(UsageSample.self, from: data), with)
        let legacy = Data(#"{"t":1,"email":"a@x","number":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UsageSample.self, from: legacy).active)
        let without = try JSONEncoder().encode(sample(t: 1))
        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("active"))
    }
}
