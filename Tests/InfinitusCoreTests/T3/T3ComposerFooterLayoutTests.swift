import XCTest
@testable import InfinitusCore

/// `composerFooterLayout.test.ts`'s `resolveScrollToEndClearance` suite
/// ("removes the side tab gap in both composer states while clearing
/// overlapping attachments"), case for case, at both of its overlay heights.
final class T3ComposerFooterLayoutTests: XCTestCase {
    private func clearance(overlayHeight: Double,
                           button: (left: Double, right: Double) = (340, 460),
                           attachments: [T3ComposerFooterLayout.Attachment]) -> Double {
        T3ComposerFooterLayout.scrollToEndClearance(overlayHeight: overlayHeight,
                                                    mainSurfaceTop: 534,
                                                    buttonLeft: button.left,
                                                    buttonRight: button.right,
                                                    attachments: attachments)
    }

    func testASideTabOutOfThePillsWayIsSubtracted() {
        // The attachment is to the RIGHT of the pill (600...700 against
        // 340...460): it raises the overlay's box but never crosses the pill,
        // so its 34 pt come back off the clearance.
        let sideTab = T3ComposerFooterLayout.Attachment(top: 500, left: 600, right: 700)
        for overlayHeight in [120.0, 214.0] {
            XCTAssertEqual(clearance(overlayHeight: overlayHeight, attachments: [sideTab]),
                           overlayHeight - 34)
        }
    }

    func testNoAttachmentKeepsTheWholeOverlay() {
        for overlayHeight in [120.0, 214.0] {
            XCTAssertEqual(clearance(overlayHeight: overlayHeight, attachments: []), overlayHeight)
        }
    }

    func testAnAttachmentUnderThePillKeepsTheWholeOverlay() {
        let sideTab = T3ComposerFooterLayout.Attachment(top: 500, left: 600, right: 700)
        let full = T3ComposerFooterLayout.Attachment(top: 500, left: 100, right: 700)
        for overlayHeight in [120.0, 214.0] {
            // The wide one overlaps the pill, so `top` stops at 500 — the same
            // 500 `contentTop` reached — and nothing is subtracted.
            XCTAssertEqual(clearance(overlayHeight: overlayHeight, attachments: [sideTab, full]),
                           overlayHeight)
            // Same answer from the other side: a pill wide enough to reach the
            // side tab (590...710) is itself over it.
            XCTAssertEqual(clearance(overlayHeight: overlayHeight, button: (590, 710),
                                     attachments: [sideTab]),
                           overlayHeight)
        }
    }

    /// `Math.ceil` on the result — the overlay's height arrives measured.
    func testTheClearanceRoundsUp() {
        XCTAssertEqual(clearance(overlayHeight: 119.2, attachments: []), 120)
        XCTAssertEqual(clearance(overlayHeight: 119.2,
                                 attachments: [.init(top: 500, left: 600, right: 700)]),
                       86)
    }
}
