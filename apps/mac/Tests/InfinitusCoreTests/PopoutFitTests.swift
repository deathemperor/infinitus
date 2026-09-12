import XCTest
@testable import InfinitusCore

final class PopoutFitTests: XCTestCase {
    let s = { (w: Double, h: Double) in PopoutFit.Size(width: w, height: h) }

    func testFitsAlreadyOrPlainAsk() {
        XCTAssertNil(PopoutFit.ask(want: s(920, 340), current: s(920, 340), refused: nil, recent: []))
        XCTAssertEqual(PopoutFit.ask(want: s(920, 340), current: s(920, 319), refused: nil, recent: []),
                       .init(size: s(920, 340), settled: false))
        // A size the window refused is not asked for again.
        XCTAssertNil(PopoutFit.ask(want: s(920, 340), current: s(920, 319), refused: s(920, 340), recent: []))
    }

    func testAskedTwiceInASecondSettlesOnTheLarger() {
        // 340 asked for in a 319 window, and asked for again within the
        // second: the larger of the two is 340 itself, asked once more
        // as the settle; had the window meanwhile taken 340, nothing.
        XCTAssertEqual(PopoutFit.ask(want: s(920, 340), current: s(920, 319), refused: nil, recent: [s(920, 340)]),
                       .init(size: s(920, 340), settled: true))
        XCTAssertNil(PopoutFit.ask(want: s(920, 319), current: s(920, 340), refused: nil, recent: [s(920, 319), s(920, 340)]))
        // Wider but shorter than the window: the settle is neither size.
        XCTAssertEqual(PopoutFit.ask(want: s(920, 300), current: s(800, 400), refused: nil, recent: [s(920, 300)]),
                       .init(size: s(920, 400), settled: true))
    }

    /// #229: the settled size differs from `want`; when the screen clamps
    /// it, the refusal must match the settled ask, or every re-measure in
    /// the second asks for it again.
    func testARefusedSettledSizeIsNotAskedForAgain() {
        let want = s(920, 900)
        let settle = PopoutFit.ask(want: want, current: s(1000, 700), refused: nil, recent: [want])
        XCTAssertEqual(settle, .init(size: s(1000, 900), settled: true))
        // The screen kept the window at 800 tall: the settle is refused,
        // and the next re-measure — same ideal, still within the second —
        // must not ask for it again (it did while the guard compared the
        // refusal with `want`).
        XCTAssertNil(PopoutFit.ask(want: want, current: s(1000, 800), refused: s(1000, 900), recent: [want, s(1000, 900)]),
                     "the refused settled size must not be asked for again")
        // Once the second passes and `want` is no longer recent, `want`
        // itself is a fresh ask — it is not what was refused.
        XCTAssertEqual(PopoutFit.ask(want: want, current: s(1000, 800), refused: s(1000, 900), recent: []),
                       .init(size: want, settled: false))
    }
}
