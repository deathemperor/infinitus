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

        func begin() async {
            started += 1
            running += 1
            peak = max(peak, running)
            await withCheckedContinuation { waiters.append($0) }
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
    }

    private func settle(_ probe: Probe, waiting: Int) async {
        for _ in 0..<200 where await probe.waitingCount() < waiting {
            await Task.yield()
        }
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
