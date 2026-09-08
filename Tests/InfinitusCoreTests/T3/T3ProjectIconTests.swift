import XCTest
@testable import InfinitusCore

/// `selectProjectIcon`'s classification port. The three classified cases
/// and the generic-fallback case are copied verbatim from upstream's own
/// `projectIconModel.test.ts` (`it.each` table + "gives unknown names a
/// stable generic icon") — ground truth from the source's own test suite,
/// not hand-computed.
final class T3ProjectIconTests: XCTestCase {
    func testClassifiesByKeyword() {
        XCTAssertEqual(T3ProjectIcon.select(name: "customer-api", cwd: "/workspace/customer-api"), .server)
        XCTAssertEqual(T3ProjectIcon.select(name: "ios-client", cwd: "/workspace/ios-client"), .mobile)
        XCTAssertEqual(T3ProjectIcon.select(name: "agent-runtime", cwd: "/workspace/agent-runtime"), .ai)
    }

    func testUnknownNameGetsAStableGenericIcon() {
        // Upstream's own test: "mercury" scores zero against every keyword
        // class, so it falls to the FNV-1a-ish stable hash over the 5
        // generic icons — verified independently in Python (this file's
        // dispatch report has the script) to land on `.code`.
        let icon = T3ProjectIcon.select(name: "mercury", cwd: "/workspace/mercury")
        XCTAssertEqual(icon, .code)
        // Same call, different cwd: the hash is over the name only.
        XCTAssertEqual(T3ProjectIcon.select(name: "mercury", cwd: "/elsewhere/mercury"), icon)
    }

    func testBlankNameFallsBackToTheWorkspaceDirectory() {
        // `selectProjectIcon("", "C:\\work\\mobile-app")` → "mobile".
        XCTAssertEqual(T3ProjectIcon.select(name: "", cwd: "C:\\work\\mobile-app"), .mobile)
    }
}
