import XCTest
@testable import InfinitusCore

/// The terminal drawer's pure rules (#507 v4): the height clamp with its
/// constants (`ThreadTerminalDrawer.tsx:93-105`), the persisted per-thread
/// shape (`terminalUiStateStore.ts:20-27`, `:183-192`, `:508-514`) and which
/// surface draws the shells while both the drawer and the Terminal tab are
/// mounted (`ChatView.tsx:855-868`).
final class T3TerminalDrawerTests: XCTestCase {

    // MARK: - The height

    func testConstantsAreUpstreams() {
        XCTAssertEqual(T3TerminalDrawer.minHeight, 180)
        XCTAssertEqual(T3TerminalDrawer.maxHeightRatio, 0.75)
        XCTAssertEqual(T3TerminalDrawer.defaultHeight, 280)
    }

    /// `maxDrawerHeight()` (`:96-99`): `floor(innerHeight * 0.75)`, never under
    /// the minimum.
    func testMaxHeightIsThreeQuartersFloored() {
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: 1000), 750)
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: 899), 674)   // 674.25 floored
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: 200), 180)   // 150 → the minimum
    }

    /// A window that has not been laid out yet (`typeof window === "undefined"`,
    /// `:97`) answers with the default.
    func testMaxHeightWithoutAViewportIsTheDefault() {
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: 0), 280)
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: -10), 280)
        XCTAssertEqual(T3TerminalDrawer.maxHeight(viewport: .nan), 280)
    }

    /// `clampDrawerHeight` (`:101-105`).
    func testClampHoldsBetweenTheMinimumAndTheRatio() {
        XCTAssertEqual(T3TerminalDrawer.clamp(280, viewport: 1000), 280)
        XCTAssertEqual(T3TerminalDrawer.clamp(20, viewport: 1000), 180)
        XCTAssertEqual(T3TerminalDrawer.clamp(4000, viewport: 1000), 750)
        // Rounded before the comparison, upstream's `Math.round`.
        XCTAssertEqual(T3TerminalDrawer.clamp(280.6, viewport: 1000), 281)
    }

    /// `Number.isFinite` (`:102`) is false for both, so both read as the
    /// default rather than as "as tall as it can go".
    func testClampOfANonFiniteHeightIsTheDefault() {
        XCTAssertEqual(T3TerminalDrawer.clamp(.nan, viewport: 1000), 280)
        XCTAssertEqual(T3TerminalDrawer.clamp(.infinity, viewport: 1000), 280)
    }

    /// A short window: the minimum wins over the ratio, so the drawer is 180
    /// even where three quarters would be less (`:98`'s own `Math.max`).
    func testTheMinimumWinsOnAShortWindow() {
        XCTAssertEqual(T3TerminalDrawer.clamp(280, viewport: 200), 180)
        XCTAssertEqual(T3TerminalDrawer.clamp(100, viewport: 200), 180)
    }

    // MARK: - The persisted state

    func testDefaultStateIsClosedAtTheDefaultHeight() {
        XCTAssertEqual(T3TerminalDrawer.State.none, T3TerminalDrawer.State(open: false, height: 280))
        XCTAssertFalse(T3TerminalDrawer.State.none.open)
        XCTAssertEqual(T3TerminalDrawer.State.none.height, 280)
    }

    /// `normalizeThreadTerminalUiState`'s height branch
    /// (`terminalUiStateStore.ts:221-223`): finite and positive, or the default.
    func testANonPositiveHeightNormalizesToTheDefault() {
        XCTAssertEqual(T3TerminalDrawer.State(open: true, height: 0).height, 280)
        XCTAssertEqual(T3TerminalDrawer.State(open: true, height: -40).height, 280)
        XCTAssertEqual(T3TerminalDrawer.State(open: true, height: .nan).height, 280)
        // Stored RAW, not clamped: `:1085` clamps where it is drawn instead.
        XCTAssertEqual(T3TerminalDrawer.State(open: true, height: 40).height, 40)
        XCTAssertEqual(T3TerminalDrawer.State(open: true, height: 4000).height, 4000)
    }

    func testStateRoundTripsThroughDefaults() {
        let states = ["t1": T3TerminalDrawer.State(open: true, height: 420),
                      "t2": T3TerminalDrawer.State(open: false, height: 200)]
        XCTAssertEqual(T3TerminalDrawer.load(from: T3TerminalDrawer.save(states)), states)
    }

    /// `isDefaultThreadTerminalUiState` (`terminalUiStateStore.ts:508-514`): the
    /// default state leaves no key behind, on the way out AND on the way in.
    func testDefaultStatesAreNotPersisted() {
        let saved = T3TerminalDrawer.save(["t1": .none,
                                           "t2": .init(open: true, height: 280)])
        XCTAssertEqual(T3TerminalDrawer.load(from: saved), ["t2": .init(open: true, height: 280)])
        let handWritten = Data(#"{"t1":{"open":false,"height":280},"t2":{"open":false,"height":300}}"#.utf8)
        XCTAssertEqual(T3TerminalDrawer.load(from: handWritten),
                       ["t2": .init(open: false, height: 300)])
    }

    func testUnreadableDataIsNoState() {
        XCTAssertTrue(T3TerminalDrawer.load(from: nil).isEmpty)
        XCTAssertTrue(T3TerminalDrawer.load(from: Data()).isEmpty)
        XCTAssertTrue(T3TerminalDrawer.load(from: Data("not json".utf8)).isEmpty)
    }

    /// A key an older (or newer) build wrote with one member missing reads as
    /// the default for it, rather than dropping the whole entry.
    func testAPartialEntryDecodes() {
        let data = Data(#"{"t1":{"open":true},"t2":{"height":512}}"#.utf8)
        XCTAssertEqual(T3TerminalDrawer.load(from: data),
                       ["t1": .init(open: true, height: 280), "t2": .init(open: false, height: 512)])
    }

    // MARK: - Who draws the shells

    func testNoOwnerDrawsUntilOneClaims() {
        var presenters = T3TerminalDrawer.Presenters()
        XCTAssertTrue(presenters.isEmpty)
        XCTAssertNil(presenters.current)
        presenters.claim(.panel)
        XCTAssertFalse(presenters.isEmpty)
        XCTAssertEqual(presenters.current, .panel)
    }

    /// The owner that appeared LAST draws — the partition upstream makes per
    /// terminal id (`ChatView.tsx:855-868`), made per surface here because one
    /// `TerminalView` has one superview.
    func testTheNewestClaimDraws() {
        var presenters = T3TerminalDrawer.Presenters()
        presenters.claim(.panel)
        presenters.claim(.drawer)
        XCTAssertEqual(presenters.current, .drawer)
        // Switching the right panel back to Terminal takes the shells back.
        presenters.claim(.panel)
        XCTAssertEqual(presenters.current, .panel)
        XCTAssertEqual(presenters.claims, [.drawer, .panel])
    }

    /// A re-claim never leaves a duplicate behind, so a release still empties.
    func testReClaimingDoesNotStack() {
        var presenters = T3TerminalDrawer.Presenters()
        presenters.claim(.drawer)
        presenters.claim(.drawer)
        XCTAssertEqual(presenters.claims, [.drawer])
        presenters.release(.drawer)
        XCTAssertTrue(presenters.isEmpty)
    }

    /// The drawer closing hands the shells to the tab that is still open —
    /// never a detach while one owner remains.
    func testReleaseHandsBackToTheOtherOwner() {
        var presenters = T3TerminalDrawer.Presenters()
        presenters.claim(.panel)
        presenters.claim(.drawer)
        presenters.release(.drawer)
        XCTAssertEqual(presenters.current, .panel)
        XCTAssertFalse(presenters.isEmpty)
        presenters.release(.panel)
        XCTAssertTrue(presenters.isEmpty)
        XCTAssertNil(presenters.current)
    }

    func testReleasingAnUnmountedOwnerIsANoOp() {
        var presenters = T3TerminalDrawer.Presenters()
        presenters.claim(.panel)
        presenters.release(.drawer)
        XCTAssertEqual(presenters.current, .panel)
    }

    func testTheOtherSurfaceIsNamed() {
        XCTAssertEqual(T3TerminalDrawer.Presenters.elsewhere(.panel),
                       "These shells are in the Terminal tab.")
        XCTAssertEqual(T3TerminalDrawer.Presenters.elsewhere(.drawer),
                       "These shells are in the terminal drawer.")
    }
}
