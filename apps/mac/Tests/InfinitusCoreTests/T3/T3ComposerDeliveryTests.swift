import XCTest
@testable import InfinitusCore

/// The sequence/take rule `T3ComposerInbox` builds on (#528): a repeat of
/// the same kind must still be a fresh `.onChange`, and a slot taken once
/// must read as empty afterward.
final class T3ComposerDeliveryTests: XCTestCase {
    func testSeqStrictlyIncreases() {
        let first = T3ComposerDelivery.next(.fileDrop, after: 0)
        let second = T3ComposerDelivery.next(.fileDrop, after: first.seq)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
    }

    /// Two sidebar drops onto the same already-open thread, back to back:
    /// same kind, no payload — only the seq tells them apart, and it must,
    /// or the second drop never reaches the composer (the bug #528 fixes).
    func testTwoDeliveriesOfTheSameKindAreNotEqual() {
        let first = T3ComposerDelivery.next(.fileDrop, after: 0)
        let second = T3ComposerDelivery.next(.fileDrop, after: first.seq)
        XCTAssertNotEqual(first, second)
    }

    func testPayloadRoundTrips() {
        let insert = T3ComposerDelivery.next(.insert("refine this"), after: 0)
        let mention = T3ComposerDelivery.next(.mention("@foo.swift"), after: insert.seq)
        XCTAssertEqual(insert.kind, .insert("refine this"))
        XCTAssertEqual(mention.kind, .mention("@foo.swift"))
    }

    func testTakeEmptiesTheSlotAndASecondTakeIsNil() {
        var slot: T3ComposerDelivery? = T3ComposerDelivery.next(.fileDrop, after: 0)
        XCTAssertEqual(T3ComposerDelivery.take(&slot), .fileDrop)
        XCTAssertNil(slot)
        XCTAssertNil(T3ComposerDelivery.take(&slot))
    }

    /// The last #528 channel (B-38): a focus request rides the same slot,
    /// so back-to-back requests (⌘K to the same thread twice) still need
    /// distinct seqs, and a take still drains it.
    func testTwoFocusDeliveriesInARowDifferBySeqAndTakeDrainsIt() {
        let first = T3ComposerDelivery.next(.focus, after: 0)
        let second = T3ComposerDelivery.next(.focus, after: first.seq)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)

        var slot: T3ComposerDelivery? = second
        XCTAssertEqual(T3ComposerDelivery.take(&slot), .focus)
        XCTAssertNil(slot)
        XCTAssertNil(T3ComposerDelivery.take(&slot))
    }
}
