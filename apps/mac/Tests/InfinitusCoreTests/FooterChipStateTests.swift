import XCTest
@testable import InfinitusCore

final class FooterChipStateTests: XCTestCase {
    func testServiceStatusSummaryWording() {
        XCTAssertEqual(ServiceStatusSummary(indicator: "none").shortText, "claude ok")
        XCTAssertEqual(ServiceStatusSummary(indicator: "critical").shortText, "critical outage")
        XCTAssertEqual(ServiceStatusSummary(indicator: nil).shortText, "status")
    }
}
