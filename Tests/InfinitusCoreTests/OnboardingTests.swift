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
