import XCTest
@testable import InfinitusCore

final class OnboardingBriefTests: XCTestCase {
    func testBriefTicksWhatIsThereAndNamesTheAccount() {
        let claude = ClaudeCLIInfo(binaryPath: "/opt/homebrew/bin/claude", email: "me@example.com",
                                   organization: "Me's Org")
        let text = OnboardingBrief.text(engineInstalled: true, claude: claude, proxy: nil, proxyLive: false)
        XCTAssertTrue(text.contains("- [x] 1. Install the engine"))
        XCTAssertTrue(text.contains("- [x] 2. Sign Claude Code"))
        XCTAssertTrue(text.contains("signed in as me@example.com (Me's Org)"))
        XCTAssertTrue(text.contains("swapd add"))
    }

    func testBriefLeavesMissingPiecesUnticked() {
        let text = OnboardingBrief.text(engineInstalled: false, claude: nil, proxy: nil, proxyLive: false)
        XCTAssertTrue(text.contains("- [ ] 1. Install the engine"))
        XCTAssertTrue(text.contains("- [ ] 2. Sign Claude Code"))
        XCTAssertTrue(text.contains("NOT installed"))
    }
}

#if !os(iOS)
final class SwapdLocatorTests: XCTestCase {
    func testFreshInstallFallsBackToBundledEngine() {
        let paths = SwapdLocator.defaultCandidates(home: "/fixture", bundledExecutableDirectory: "/fixture/Infinitus.app/Contents/MacOS")
        let bundled = "/fixture/Infinitus.app/Contents/MacOS/swapd"
        XCTAssertEqual(SwapdLocator.locate(candidates: paths, exists: { $0 == bundled }), bundled)
        XCTAssertEqual(SwapdLocator.locate(candidates: paths, exists: { $0 == bundled || $0 == "/fixture/.cargo/bin/swapd" }), "/fixture/.cargo/bin/swapd")
        XCTAssertNil(SwapdLocator.locate(candidates: paths, exists: { _ in false }))
    }
}
#endif
