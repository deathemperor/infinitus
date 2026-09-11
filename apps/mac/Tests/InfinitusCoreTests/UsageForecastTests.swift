import XCTest
@testable import InfinitusCore

final class UsageForecastTests: XCTestCase {
    private typealias A = UsageForecast.AccountInput
    private func win(_ pct: Double, resetsAt: Double? = nil) -> UsageSample.Window {
        .init(pct: pct, resetsAt: resetsAt)
    }
    private let now: Double = 100_000

    // Active: 5h 60% at 20%/h (hits in 2h, reset in 4h); 7d 50% at 1%/h
    // (hits in 50h, reset in 30h → resets first); Fable 90% at 2%/h → 5h.
    private var active: A {
        A(number: 1, email: "main@x", active: true, disabled: false,
          fiveHour: win(60, resetsAt: 100_000 + 4 * 3600),
          sevenDay: win(50, resetsAt: 100_000 + 30 * 3600),
          scoped: ["Fable": win(90, resetsAt: 100_000 + 30 * 3600)])
    }
    private let rates: [String: Double] = ["5h": 20, "7d": 1, "Fable": 2]

    func testActiveWindowsProjectHitsOrResetFirst() {
        let f = UsageForecast.build(accounts: [active], rates: rates, now: now)
        let byName = Dictionary(uniqueKeysWithValues: f.active!.windows.map { ($0.name, $0) })
        XCTAssertEqual(byName["5h"]?.hitsAt, now + 2 * 3600)
        XCTAssertNil(byName["7d"]?.hitsAt, "reset lands before the projected hit")
        XCTAssertEqual(byName["7d"]?.ratePctPerHour, 1)
        XCTAssertEqual(byName["Fable"]?.hitsAt, now + 5 * 3600)
        XCTAssertEqual(f.active?.bindsAt, now + 2 * 3600)
        XCTAssertEqual(f.active?.windows.map(\.name), ["5h", "7d", "Fable"])
    }

    func testProjectionsAnchorToTheSampleTimeNotThePoll() {
        // Same sample read 10 min ago: the hit is 10 min sooner than a
        // now-anchored one, and a later poll with the same sample agrees.
        let t = now - 600
        let a = UsageForecast.build(accounts: [active], rates: rates, now: now, measuredAt: t)
        let b = UsageForecast.build(accounts: [active], rates: rates, now: now + 300, measuredAt: t)
        XCTAssertEqual(a.active?.bindsAt, t + 2 * 3600)
        XCTAssertEqual(a.active?.bindsAt, b.active?.bindsAt)
        XCTAssertEqual(a.allDeadAt, b.allDeadAt)
        XCTAssertEqual(a.accounts, b.accounts, "the republish guard must see no move")
        // A stale sample about to bind never projects into the past.
        let nearlyFull = A(number: 1, email: "main@x", active: true, disabled: false,
                           fiveHour: win(99.9, resetsAt: now + 4 * 3600), sevenDay: nil, scoped: [:])
        let c = UsageForecast.build(accounts: [nearlyFull], rates: ["5h": 20], now: now, measuredAt: now - 3600)
        XCTAssertEqual(c.active?.bindsAt, now)
        // A sample stamped in the future (clock skew) is treated as now.
        let d = UsageForecast.build(accounts: [active], rates: rates, now: now, measuredAt: now + 900)
        XCTAssertEqual(d.active?.bindsAt, now + 2 * 3600)
    }

    func testUnknownRateProjectsNothingAndFullWindowHitsNow() {
        let full = A(number: 1, email: "main@x", active: true, disabled: false,
                     fiveHour: win(100, resetsAt: now + 600), sevenDay: win(10), scoped: [:])
        let f = UsageForecast.build(accounts: [full], rates: [:], now: now)
        XCTAssertEqual(f.active?.windows[0].hitsAt, now)
        XCTAssertNil(f.active?.windows[1].hitsAt)
        XCTAssertNil(f.active?.windows[1].ratePctPerHour)
        XCTAssertNil(f.allDeadAt, "no weekly rate → no fleet projection")
    }

    func testAllDeadDrainsWeeklyHeadroomInHeadroomOrder() {
        // Active binds on Fable in 5h. Spare A: 7d 80% (20h), Fable 40%
        // (30h) → 20h. Spare B: 7d 100% → 0h. Disabled ignored.
        let spareA = A(number: 2, email: "a@x", active: false, disabled: false,
                       fiveHour: nil, sevenDay: win(80), scoped: ["Fable": win(40)])
        let spareB = A(number: 3, email: "b@x", active: false, disabled: false,
                       fiveHour: nil, sevenDay: win(100), scoped: [:])
        let off = A(number: 4, email: "off@x", active: false, disabled: true,
                    fiveHour: nil, sevenDay: win(0), scoped: [:])
        let f = UsageForecast.build(accounts: [active, spareA, spareB, off], rates: rates, now: now)
        XCTAssertEqual(f.allDeadAt, now + (5 + 20 + 0) * 3600)
        XCTAssertEqual(f.drainOrder, [1, 3, 2], "active, then least weekly headroom first; disabled left out")
    }

    func testEveryAccountProjectsAtItsOwnPace() {
        // Spare burns its 7d at 5%/h (own samples), active at 1%/h.
        let spare = A(number: 2, email: "a@x", alias: "spare", active: false, disabled: false,
                      fiveHour: nil, sevenDay: win(50, resetsAt: now + 30 * 3600), scoped: [:])
        let f = UsageForecast.build(accounts: [active, spare],
                                    ratesByEmail: ["main@x": rates, "a@x": ["7d": 5]], now: now)
        XCTAssertEqual(f.accounts?.count, 2)
        let line = f.accounts![1]
        XCTAssertEqual(line.label, "spare")
        XCTAssertEqual(line.windows[0].ratePctPerHour, 5)
        XCTAssertEqual(line.windows[0].hitsAt, now + 10 * 3600)
        XCTAssertEqual(line.bindsWindow, "7d")
        XCTAssertEqual(f.accounts?[0].bindsWindow, "5h")
        XCTAssertEqual(f.active?.label, "main")
        // The fleet drain runs at the ACTIVE pace: spare's 7d 50% at 1%/h = 50h after main's 5h.
        XCTAssertEqual(f.allDeadAt, now + (5 + 50) * 3600)
    }

    func testNoActiveAccountMeansNoProjection() {
        let f = UsageForecast.build(accounts: [], rates: rates, now: now)
        XCTAssertNil(f.active)
        XCTAssertNil(f.allDeadAt)
    }

    func testBurnRatesPerWindowUseTheirOwnLookback() {
        func s(_ t: Double, fh: Double, sd: Double, fable: Double) -> UsageSample {
            UsageSample(t: t, email: "main@x", number: 1,
                        fiveHour: .init(pct: fh, resetsAt: 200_000),
                        sevenDay: .init(pct: sd, resetsAt: 300_000),
                        scoped: ["Fable": .init(pct: fable, resetsAt: 300_000)], active: true)
        }
        // 20h ago → now: 7d +10 (0.5%/h), Fable +20 (1%/h); last hour: 5h +15 (15%/h).
        let samples = [s(now - 20 * 3600, fh: 0, sd: 30, fable: 10),
                       s(now - 3600, fh: 40, sd: 39.5, fable: 29),
                       s(now, fh: 55, sd: 40, fable: 30)]
        let rates = WindowTelemetry.burnRates(samples, email: "main@x", now: now)
        XCTAssertEqual(rates["5h"]!, 15, accuracy: 1e-9)
        XCTAssertEqual(rates["7d"]!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rates["Fable"]!, 1, accuracy: 1e-9)
        XCTAssertNil(WindowTelemetry.burnRates(samples, email: "other@x", now: now)["5h"])
    }

    func testForecastRoundTripsAsJSON() throws {
        let f = UsageForecast.build(accounts: [active], rates: rates, now: now)
        let data = try JSONEncoder().encode(f)
        XCTAssertEqual(try JSONDecoder().decode(UsageForecast.self, from: data), f)
    }
}
