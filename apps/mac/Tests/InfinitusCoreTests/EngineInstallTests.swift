import XCTest
@testable import InfinitusCore

final class EngineInstallPlanTests: XCTestCase {
    func testAnEngineAlreadyThereHasNothingToRun() {
        let plan = EngineInstallPlan.make(engine: "/opt/homebrew/bin/swapd",
                                          cargo: nil, brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.blocker, .alreadyInstalled)
        XCTAssertFalse(plan.isRunnable)
    }

    func testAMachineWithRustOnlyBuildsTheEngine() {
        let plan = EngineInstallPlan.make(engine: nil, cargo: "/Users/me/.cargo/bin/cargo",
                                          brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(plan.steps, [.installEngine])
        XCTAssertNil(plan.blocker)
        XCTAssertTrue(plan.isRunnable)
    }

    func testAMachineWithNeitherInstallsRustFirst() {
        let plan = EngineInstallPlan.make(engine: nil, cargo: nil, brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(plan.steps, [.installRust, .installEngine])
        XCTAssertNil(plan.blocker)
    }

    func testAMachineWithoutHomebrewIsBlockedRatherThanGuessedAt() {
        let plan = EngineInstallPlan.make(engine: nil, cargo: nil, brew: nil)
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.blocker, .needsHomebrew)
        XCTAssertTrue(plan.blocker!.message.contains("brew.sh"))
    }

    func testCommandsNameTheToolAndNeverAShellString() {
        let rust = EngineInstallPlan.command(.installRust, cargo: nil, brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(rust, EngineInstallCommand(executable: "/opt/homebrew/bin/brew",
                                                  arguments: ["install", "rust"]))
        let engine = EngineInstallPlan.command(.installEngine, cargo: "/c/cargo", brew: nil)
        XCTAssertEqual(engine?.executable, "/c/cargo")
        XCTAssertEqual(engine?.arguments,
                       ["install", "--git", "https://github.com/deathemperor/swapd", "swapd"])
    }

    func testAStepWithoutItsToolHasNoCommand() {
        XCTAssertNil(EngineInstallPlan.command(.installRust, cargo: "/c/cargo", brew: nil))
        XCTAssertNil(EngineInstallPlan.command(.installEngine, cargo: nil, brew: "/b/brew"))
    }

    /// The card, the agent brief and the runner must install the same thing.
    func testTheRunCommandIsTheDocumentedOne() {
        let engine = EngineInstallPlan.command(.installEngine, cargo: "/c/cargo", brew: nil)!
        let documented = OnboardingBrief.swapdInstallCommand
        XCTAssertEqual(documented, "cargo " + engine.arguments.joined(separator: " "))
    }
}

final class EngineToolLocatorTests: XCTestCase {
    func testCargoPrefersTheUsersOwnToolchain() {
        let path = EngineToolLocator.locate(EngineToolLocator.cargoCandidates(home: "/Users/me")) {
            $0 == "/Users/me/.cargo/bin/cargo" || $0 == "/opt/homebrew/bin/cargo"
        }
        XCTAssertEqual(path, "/Users/me/.cargo/bin/cargo")
    }

    func testNothingOnDiskLocatesNothing() {
        XCTAssertNil(EngineToolLocator.locate(EngineToolLocator.brewCandidates) { _ in false })
    }
}

final class EngineInstallProgressTests: XCTestCase {
    func testOnlyProgressLinesAreShown() {
        // cargo indents its own progress lines; they are the ones worth showing.
        XCTAssertEqual(EngineInstallProgress.label(for: "   Compiling serde v1.0.0"),
                       "Compiling serde v1.0.0")
        XCTAssertEqual(EngineInstallProgress.label(for: "   Installed package `swapd`"),
                       "Installed package `swapd`")
        XCTAssertNil(EngineInstallProgress.label(for: "some chatter"))
        XCTAssertNil(EngineInstallProgress.label(for: "   "))
    }

    func testAnErrorLineIsAlwaysShown() {
        XCTAssertEqual(EngineInstallProgress.label(for: "error: linker `cc` not found"),
                       "error: linker `cc` not found")
    }

    func testAFailureQuotesTheToolNotTheExitCode() {
        let output = ["Compiling swapd v0.1.0", "error: linking with `cc` failed", "note: see below"]
        XCTAssertEqual(EngineInstallProgress.failure(step: .installEngine, output: output, status: 101),
                       "error: linking with `cc` failed")
    }

    func testASilentFailureStillSaysWhichStepDied() {
        XCTAssertEqual(EngineInstallProgress.failure(step: .installRust, output: [], status: 1),
                       "Installing Rust (the engine is built from source) failed (exited 1).")
    }
}
