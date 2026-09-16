import Foundation
import XCTest
@testable import InfinitusCore

/// #1310 finding 5: refresh passes never overlap, and a request made
/// mid-pass runs once more after it, shared by everyone who asked.
final class SingleFlightTests: XCTestCase {
    /// Counts passes and how many ran at once; each pass waits until
    /// `release` so the test controls the overlap window.
    private actor Probe {
        var started = 0
        var running = 0
        var peak = 0
        var finished = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// A test waiting for `waiters` to reach a count, and the count it wants.
        /// One slot: a test only ever waits from one place at a time.
        private var arrival: (want: Int, signal: CheckedContinuation<Void, Never>)?

        func begin() async {
            started += 1
            running += 1
            peak = max(peak, running)
            await withCheckedContinuation { waiter in
                waiters.append(waiter)
                if let arrival, waiters.count >= arrival.want {
                    self.arrival = nil
                    arrival.signal.resume()
                }
            }
            running -= 1
            finished += 1
        }

        /// Lets every pass waiting at this moment finish.
        func release() {
            let w = waiters
            waiters = []
            for c in w { c.resume() }
        }

        func waitingCount() -> Int { waiters.count }

        /// Returns once `want` passes have parked.
        func parked(_ want: Int) async {
            if waiters.count >= want { return }
            await withCheckedContinuation { arrival = (want, $0) }
        }

        /// Wakes a `parked` waiter that is never going to get its passes, so
        /// the test fails on the count instead of hanging.
        func giveUp() {
            guard let arrival else { return }
            self.arrival = nil
            arrival.signal.resume()
        }
    }

    /// Waits for `waiting` passes to park, on the signal `begin` sends — not
    /// a yield budget. A bounded spin (`for _ in 0..<200 where …`) gave up
    /// early on a loaded Linux runner, and the `release` that followed then
    /// resumed nobody: the test hung on a continuation no one would ever
    /// resume and `mac-linux` died on its 20-minute timeout (#1387).
    ///
    /// The deadline is not how the test passes — a passing run cancels it
    /// unused. It is there so a genuine stall reports the count it never
    /// reached rather than hanging the job.
    private func settle(_ probe: Probe, waiting: Int,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { return }  // a cancelled deadline must not wake a later `settle`
            await probe.giveUp()
        }
        await probe.parked(waiting)
        deadline.cancel()
        let parked = await probe.waitingCount()
        XCTAssertGreaterThanOrEqual(parked, waiting, "passes never parked", file: file, line: line)
    }

    func testPassesRunOneAfterAnotherWhenNothingOverlaps() async {
        let flight = SingleFlight()
        let probe = Probe()
        let first = Task { await flight.run { await probe.begin() } }
        await settle(probe, waiting: 1)
        await probe.release()
        await first.value
        let second = Task { await flight.run { await probe.begin() } }
        await settle(probe, waiting: 1)
        await probe.release()
        await second.value
        let started = await probe.started
        let peak = await probe.peak
        XCTAssertEqual(started, 2)
        XCTAssertEqual(peak, 1)
    }

    func testCallersDuringAPassShareOneFollowUpThatRunsAfterIt() async {
        let flight = SingleFlight()
        let probe = Probe()
        let first = Task { await flight.run { await probe.begin() } }
        await settle(probe, waiting: 1)
        // Three requests land mid-pass.
        let late = (0..<3).map { _ in Task { await flight.run { await probe.begin() } } }
        await Task.yield()
        var started = await probe.started
        XCTAssertEqual(started, 1, "nothing starts while a pass runs")
        await probe.release()
        await first.value
        // The follow-up is one pass, started after the first finished.
        await settle(probe, waiting: 1)
        started = await probe.started
        XCTAssertEqual(started, 2)
        let running = await probe.running
        XCTAssertEqual(running, 1)
        await probe.release()
        for task in late { await task.value }
        let finished = await probe.finished
        let peak = await probe.peak
        XCTAssertEqual(finished, 2, "three mid-pass callers coalesce into one follow-up")
        XCTAssertEqual(peak, 1, "never concurrent")
    }

    func testARequestDuringTheFollowUpGetsAThirdPass() async {
        let flight = SingleFlight()
        let probe = Probe()
        let first = Task { await flight.run { await probe.begin() } }
        await settle(probe, waiting: 1)
        let second = Task { await flight.run { await probe.begin() } }
        await Task.yield()
        await probe.release()
        await first.value
        await settle(probe, waiting: 1)
        // Arrives while the follow-up runs: it must run once more after it.
        let third = Task { await flight.run { await probe.begin() } }
        await Task.yield()
        await probe.release()
        await second.value
        await settle(probe, waiting: 1)
        await probe.release()
        await third.value
        let finished = await probe.finished
        let peak = await probe.peak
        XCTAssertEqual(finished, 3)
        XCTAssertEqual(peak, 1)
    }
}
