import XCTest
@testable import InfinitusCore

/// `MessagesTimeline.test.tsx`'s minimap expectations, case for case
/// (`:588-659`, inside "treats only the strict list end as the live edge" —
/// upstream keeps them there, not in `MessagesTimeline.logic.test.ts`), plus a
/// case for `deriveTimelineMinimapItems`, which upstream unit-tests only through
/// the rendered markup (`:275-291`).
final class T3TimelineMinimapTests: XCTestCase {
    private func at(_ sec: Int) -> Date { Date(timeIntervalSince1970: 1_767_225_600).addingTimeInterval(TimeInterval(sec)) }

    private func message(_ id: String, _ role: T3ChatMessage.Role, _ text: String,
                         _ sec: Int) -> T3TimelineRows.Row {
        .message(id: id, createdAt: at(sec),
                 message: T3ChatMessage(id: id, role: role, text: text, turnId: nil, streaming: false,
                                        createdAt: at(sec), updatedAt: at(sec)),
                 durationStart: at(sec), showAssistantMeta: false, showAssistantCopyButton: false,
                 assistantCopyStreaming: false, assistantTurnDiffSummary: nil, revertTurnCount: nil)
    }

    private func work(_ id: String, _ sec: Int) -> T3TimelineRows.Row {
        .work(id: id, createdAt: at(sec), groupedEntries: [], isExpandedToolGroup: false, displayLabel: nil)
    }

    // MARK: - deriveTimelineMinimapItems

    func testItemsAreOnePerUserTurnCarryingTheTurnsFinalAnswer() {
        let rows: [T3TimelineRows.Row] = [
            message("user-1", .user, "  First\n  turn  ", 0),
            work("work-1", 1),
            message("assistant-1", .assistant, "Thinking out loud", 2),
            message("assistant-2", .assistant, "First answer", 3),
            message("user-2", .user, "Second turn", 4),
            message("assistant-3", .assistant, "   ", 5),
        ]
        let items = T3TimelineMinimap.items(rows: rows)
        XCTAssertEqual(items.count, 2)
        // Whitespace collapsed; the LAST assistant message of the turn is the
        // answer, not the commentary before it.
        XCTAssertEqual(items[0], T3TimelineMinimap.Item(id: "user-1", rowIndex: 0,
                                                       userText: "First turn",
                                                       assistantText: "First answer"))
        // A blank answer compacts to nil, and the row index is the row's own —
        // what the click scrolls to.
        XCTAssertEqual(items[1], T3TimelineMinimap.Item(id: "user-2", rowIndex: 4,
                                                       userText: "Second turn",
                                                       assistantText: nil))
    }

    func testAThreadWithNoUserTurnHasNoItems() {
        XCTAssertEqual(T3TimelineMinimap.items(rows: [work("work-1", 0),
                                                     message("assistant-1", .assistant, "Hi", 1)]).count, 0)
    }

    // MARK: - The strip's geometry

    func testStripHeightIsEightPointsPerGapCappedByTheViewport() {
        XCTAssertEqual(T3TimelineMinimap.naturalStripHeight(itemCount: 5), 32)
        XCTAssertEqual(T3TimelineMinimap.stripHeight(itemCount: 5, availableHeight: 900), 32)
        // `calc(100vh - 18rem)` wins on a short viewport.
        XCTAssertEqual(T3TimelineMinimap.stripHeight(itemCount: 60, availableHeight: 600), 312)
        // One item still has a height: `Math.max(1, …)`.
        XCTAssertEqual(T3TimelineMinimap.naturalStripHeight(itemCount: 1), 1)
    }

    func testTopPercentSpreadsTheMarksOverTheStrip() {
        XCTAssertEqual(T3TimelineMinimap.topPercent(index: 2, itemCount: 5), 50)
        XCTAssertEqual(T3TimelineMinimap.topPercent(index: 0, itemCount: 5), 0)
        XCTAssertEqual(T3TimelineMinimap.topPercent(index: 9, itemCount: 5), 100)
        XCTAssertEqual(T3TimelineMinimap.topPercent(index: 0, itemCount: 1), 0)
    }

    func testIndexFromPointerRoundsToTheNearestMark() {
        XCTAssertEqual(T3TimelineMinimap.indexFromPointer(itemCount: 101, railTop: 100,
                                                          railHeight: 500, pointerY: 350), 50)
        // Past the strip's end clamps to the last mark.
        XCTAssertEqual(T3TimelineMinimap.indexFromPointer(itemCount: 101, railTop: 100,
                                                          railHeight: 500, pointerY: 999), 100)
        XCTAssertEqual(T3TimelineMinimap.indexFromPointer(itemCount: 101, railTop: 100,
                                                          railHeight: 500, pointerY: 0), 0)
        XCTAssertEqual(T3TimelineMinimap.indexFromPointer(itemCount: 1, railTop: 100,
                                                          railHeight: 500, pointerY: 999), 0)
        XCTAssertNil(T3TimelineMinimap.indexFromPointer(itemCount: 0, railTop: 100,
                                                        railHeight: 500, pointerY: 350))
        XCTAssertNil(T3TimelineMinimap.indexFromPointer(itemCount: 101, railTop: 100,
                                                        railHeight: 0, pointerY: 350))
    }

    // MARK: - Which turn the reader is on

    func testCurrentIndexIsTheFirstTurnOnScreen() {
        let bounds = [T3TimelineMinimap.ItemBounds(top: 80, height: 20),
                      T3TimelineMinimap.ItemBounds(top: 120, height: 20),
                      T3TimelineMinimap.ItemBounds(top: 220, height: 20)]
        XCTAssertEqual(T3TimelineMinimap.currentIndex(scrollTop: 100, scrollBottom: 500,
                                                      itemBounds: bounds), 1)
        // Nothing in view: the last turn above the viewport.
        XCTAssertEqual(T3TimelineMinimap.currentIndex(scrollTop: 150, scrollBottom: 200,
                                                      itemBounds: bounds), 1)
        // The only turn is below the viewport — no current turn at all.
        XCTAssertNil(T3TimelineMinimap.currentIndex(scrollTop: 0, scrollBottom: 50,
                                                    itemBounds: [.init(top: 80, height: 20)]))
        // An unmeasured row is skipped, never counted as at the top.
        XCTAssertNil(T3TimelineMinimap.currentIndex(scrollTop: 0, scrollBottom: 50,
                                                    itemBounds: [.init(top: nil, height: nil)]))
    }

    // MARK: - The gutter the strip lives in

    func testPersistentGutterNeedsFortyEightPointsBesideTheColumn() {
        XCTAssertFalse(T3TimelineMinimap.hasPersistentGutter(viewportWidth: 832))
        XCTAssertFalse(T3TimelineMinimap.hasPersistentGutter(viewportWidth: 863))
        XCTAssertTrue(T3TimelineMinimap.hasPersistentGutter(viewportWidth: 864))
        XCTAssertFalse(T3TimelineMinimap.hasPersistentGutter(viewportWidth: 0))
        XCTAssertFalse(T3TimelineMinimap.hasPersistentGutter(viewportWidth: .nan))
    }

    func testHitStripNeverReachesPastTheGutterIntoTheColumn() {
        // No usable gutter (a narrow pane): the strip goes inert instead of
        // overlaying the centred content column.
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 768), 0)
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 792), 0)
        // Partial gutter: the strip shrinks to what fits beside the column.
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 820), 14)
        // Full gutter: the unchanged 40 pt strip.
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 872), 40)
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 1400), 40)
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: 0), 0)
        XCTAssertEqual(T3TimelineMinimap.hitStripWidth(viewportWidth: .nan), 0)
    }

    func testAnOpenPreviewKeepsItsWholeWidthInteractive() {
        // The collapsed target stays narrow, but an open preview keeps its full
        // 20 rem plus the 2 rem offset from the strip.
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 0, expanded: false), 0)
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 14, expanded: false), 14)
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 40, expanded: false), 40)
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 0, expanded: true), 352)
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 14, expanded: true), 352)
        XCTAssertEqual(T3TimelineMinimap.interactiveWidth(collapsedWidth: 40, expanded: true), 352)
    }
}
