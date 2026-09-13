import XCTest
@testable import InfinitusCore

/// An engine whose `snapshot()` throws keeps its last good rows, which
/// is the right call — the numbers are still the best the app has. What
/// was missing is that the rows said nothing about their age, so an
/// hour-old reading rendered exactly like one fetched this minute.
final class StaleMarkingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ number: Int, usage: Usage? = Usage(fiveHour: nil, sevenDay: nil),
                         fetchedAt: String? = nil, ageSeconds: Double? = nil) -> Account {
        Account(number: number, email: "a\(number)@b.c", usage: usage,
                usageFetchedAt: fetchedAt, usageAgeSeconds: ageSeconds)
    }

    private func fleet(_ accounts: [Account]) -> EngineFleet {
        EngineFleet(engineID: "9router", provider: .claude, accounts: accounts,
                    activeNumber: 2, nextCandidate: 3, candidateOrder: [3, 1],
                    capabilities: [.switch, .rotate])
    }

    /// The engine's own stamp for that row is the truest age: it says
    /// when THOSE numbers were fetched, which survives a relaunch off
    /// the disk cache.
    func testAgeComesFromTheRowsOwnFetchStamp() {
        let stamped = account(1, fetchedAt: "2023-11-14T21:13:20Z") // now - 1h
        let marked = StaleMarking.marked(fleet([stamped]), reason: "engine unreachable",
                                         lastGood: nil, now: now)
        let row = marked.accounts[0]
        XCTAssertEqual(row.stale, true)
        XCTAssertEqual(row.staleReason, "engine unreachable")
        XCTAssertEqual(row.usageAgeSeconds ?? 0, 3600, accuracy: 1)
        XCTAssertEqual(row.staleAgeLabel, "1 hr ago")
    }

    /// No per-row stamp: the next best answer is when this engine last
    /// answered at all, which AppModel knows.
    func testFallsBackToWhenTheEngineLastAnswered() {
        let marked = StaleMarking.marked(fleet([account(1)]), reason: "timeout",
                                         lastGood: now.addingTimeInterval(-900), now: now)
        XCTAssertEqual(marked.accounts[0].usageAgeSeconds ?? 0, 900, accuracy: 1)
        XCTAssertEqual(marked.accounts[0].staleAgeLabel, "15 min ago")
    }

    /// Neither stamp: report no age rather than re-serve the one the row
    /// arrived with. That age was measured when the reading was taken and
    /// never moves, so showing it now would draw "2 min ago" on numbers
    /// hours old — the same lie this is here to stop. The row still says
    /// it is stale, and simply carries no caption.
    func testReportsNoAgeRatherThanTheFrozenOneTheRowArrivedWith() {
        let marked = StaleMarking.marked(fleet([account(1, ageSeconds: 120)]), reason: "timeout",
                                         lastGood: nil, now: now)
        XCTAssertNil(marked.accounts[0].usageAgeSeconds)
        XCTAssertNil(marked.accounts[0].staleAgeLabel)
        XCTAssertEqual(marked.accounts[0].stale, true)
        XCTAssertEqual(marked.accounts[0].staleReason, "timeout")
    }

    /// A row the engine never had a reading for has no age to report and
    /// nothing to mislead anyone with, so it is left exactly as it was.
    func testRowsWithNoReadingAreLeftAlone() {
        let blank = Account(number: 1, email: "a@b.c", usage: nil)
        let marked = StaleMarking.marked(fleet([blank]), reason: "timeout", lastGood: nil, now: now)
        XCTAssertNil(marked.accounts[0].stale)
        XCTAssertNil(marked.accounts[0].staleReason)
    }

    /// Only the accounts change: the fleet is otherwise the one the
    /// engine last reported, since that is what the disk cache, the
    /// mirror and the control socket all serve.
    func testEverythingButTheAccountsSurvives() {
        let marked = StaleMarking.marked(fleet([account(1), account(2)]), reason: "timeout",
                                         lastGood: now, now: now)
        XCTAssertEqual(marked.engineID, "9router")
        XCTAssertEqual(marked.provider, .claude)
        XCTAssertEqual(marked.activeNumber, 2)
        XCTAssertEqual(marked.nextCandidate, 3)
        XCTAssertEqual(marked.candidateOrder, [3, 1])
        XCTAssertEqual(marked.capabilities, [.switch, .rotate])
        XCTAssertEqual(marked.accounts.map(\.number), [1, 2])
    }

    /// Marking is idempotent: the refresh loop re-marks the same rows
    /// every minute it keeps failing, and only the age moves.
    func testReMarkingOnlyMovesTheAge() {
        let once = StaleMarking.marked(fleet([account(1)]), reason: "timeout",
                                       lastGood: now.addingTimeInterval(-60), now: now)
        let twice = StaleMarking.marked(once, reason: "timeout",
                                        lastGood: now.addingTimeInterval(-60),
                                        now: now.addingTimeInterval(60))
        XCTAssertEqual(twice.accounts[0].usageAgeSeconds ?? 0, 120, accuracy: 1)
        XCTAssertEqual(twice.accounts[0].stale, true)
    }
}
