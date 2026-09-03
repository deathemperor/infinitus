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
        XCTAssertTrue(text.contains("cswap add"))
    }

    func testBriefLeavesMissingPiecesUnticked() {
        let text = OnboardingBrief.text(engineInstalled: false, claude: nil, proxy: nil, proxyLive: false)
        XCTAssertTrue(text.contains("- [ ] 1. Install the engine"))
        XCTAssertTrue(text.contains("- [ ] 2. Sign Claude Code"))
        XCTAssertTrue(text.contains("NOT installed"))
    }
}

final class EngineInstallPlanTests: XCTestCase {
    func testUVPresentInstallsTheEngineDirectly() {
        XCTAssertEqual(EngineInstall.plan(uv: "/opt/homebrew/bin/uv", brew: "/opt/homebrew/bin/brew"),
                       [.installEngine])
    }

    func testMissingUVIsBootstrappedWithHomebrewFirst() {
        XCTAssertEqual(EngineInstall.plan(uv: nil, brew: "/opt/homebrew/bin/brew"),
                       [.installUV(.brew("/opt/homebrew/bin/brew")), .installEngine])
    }

    func testNoHomebrewFallsBackToTheStandaloneInstaller() {
        XCTAssertEqual(EngineInstall.plan(uv: nil, brew: nil),
                       [.installUV(.standalone), .installEngine])
        // Whatever it lands is picked up by the locator's own candidates.
        XCTAssertTrue(EngineInstall.standaloneScript.contains("astral.sh/uv/install.sh"))
        XCTAssertTrue(EngineInstall.standaloneScript.contains("pipefail"))
        XCTAssertTrue(EngineInstall.uvCandidates(home: "/Users/x").contains("/Users/x/.local/bin/uv"))
    }

    func testMessagesNameTheStepThatIsRunning() {
        XCTAssertEqual(EngineInstall.progressMessage(.installUV(.brew("/opt/homebrew/bin/brew"))),
                       "Installing uv with Homebrew…")
        XCTAssertEqual(EngineInstall.progressMessage(.installEngine), "Installing claude-swap…")
        XCTAssertEqual(EngineInstall.failureMessage(.installUV(.standalone), output: "  boom\n"),
                       "Couldn't install uv: boom")
        XCTAssertEqual(EngineInstall.failureMessage(.installEngine, output: "nope"),
                       "Install failed: nope")
    }
}
