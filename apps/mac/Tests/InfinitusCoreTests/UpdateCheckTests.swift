import XCTest
@testable import InfinitusCore

final class PackageVersionTests: XCTestCase {
    private func v(_ s: String) -> PackageVersion { PackageVersion(s)! }

    func testPreReleaseOfNewerReleaseBeatsOlderFinal() {
        // The live machine's exact case: 0.26.0b1 installed, 0.25.0 on PyPI.
        // "Any beta < any final" would nag this install to DOWNGRADE.
        XCTAssertTrue(v("0.25.0") < v("0.26.0b1"))
        XCTAssertFalse(v("0.26.0b1") < v("0.25.0"))
    }

    func testPreReleaseLosesToItsOwnFinal() {
        XCTAssertTrue(v("0.26.0b1") < v("0.26.0"))
    }

    func testOrderingWithinPreReleases() {
        XCTAssertTrue(v("0.26.0b1") < v("0.26.0b2"))
        XCTAssertTrue(v("0.26.0a2") < v("0.26.0b1"))   // a < b < rc
        XCTAssertTrue(v("0.26.0b9") < v("0.26.0rc1"))
    }

    func testEqualityAndShortReleases() {
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertTrue(v("1.2") < v("1.2.1"))
    }

    func testUnparseableIsRejected() {
        XCTAssertNil(PackageVersion(""))
        XCTAssertNil(PackageVersion("0.4.4-"))
        XCTAssertNil(PackageVersion("not-a-version"))
        // A version that can't be ordered must never claim "newer".
        XCTAssertNil(PackageVersion("1.2.post1.dev3+local"))
    }

    func testSemverPreReleaseOrders() {
        XCTAssertTrue(v("0.4.3") < v("0.4.4-alpha.1"))
        XCTAssertTrue(v("0.4.4-alpha.1") < v("0.4.4-alpha.2"))
        XCTAssertTrue(v("0.4.4-alpha.2") < v("0.4.4-beta.1"))
        XCTAssertTrue(v("0.4.4-beta.1") < v("0.4.4"))
        XCTAssertEqual(v("0.4.4-alpha.1").pre?.letter, "alpha")
        XCTAssertEqual(v("0.4.4-alpha.1").pre?.number, 1)
    }
}
