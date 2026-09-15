import Foundation
import XCTest
@testable import InfinitusCore

/// #1310: a cache write is skipped when its bytes did not move.
final class WriteIfChangedTests: XCTestCase {
    func testTheFirstTakeWritesRepeatsSkipAndAChangeWritesAgain() {
        var gate = WriteIfChanged()
        let a = Data("a".utf8), b = Data("b".utf8)
        XCTAssertTrue(gate.take(a))
        XCTAssertFalse(gate.take(a))
        XCTAssertFalse(gate.take(Data("a".utf8)))
        XCTAssertTrue(gate.take(b))
        XCTAssertFalse(gate.take(b))
        XCTAssertTrue(gate.take(a))
    }
}
