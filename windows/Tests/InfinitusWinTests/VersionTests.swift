import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import InfinitusCore
@testable import InfinitusWinUI

/// Verifies version constants and daemon agreement across platforms.
final class VersionTests: XCTestCase {
    func testCoreIsLinkedAndCanQueryAProcess() {
        XCTAssertTrue(ClaudeSessions.isAlive(Int32(GetCurrentProcessId())))
    }

    func testInfinitusVersionParsesAsPackageVersion() {
        let parsed = PackageVersion(InfinitusVersion.current)
        XCTAssertNotNil(parsed, "InfinitusVersion.current must parse as a valid PackageVersion")
    }

    func testVersionFileMatchesCoreVersion() throws {
        // Find repo root by looking for VERSION file relative to current directory or worktree
        let candidates = [
            URL(fileURLWithPath: "VERSION"),
            URL(fileURLWithPath: "../VERSION"),
            URL(fileURLWithPath: "../../VERSION")
        ]
        var foundVersion: String? = nil
        for candidate in candidates {
            if let str = try? String(contentsOf: candidate, encoding: .utf8) {
                foundVersion = str.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard let versionFileString = foundVersion else {
            XCTFail("Could not locate VERSION file")
            return
        }
        XCTAssertEqual(versionFileString, InfinitusVersion.current,
                       "VERSION file and InfinitusVersion.current must agree")
    }

    func testReleaseTagStripsV() {
        XCTAssertEqual(UpdateLogicWin.normalizeTag("v0.5.0"), "0.5.0")
        XCTAssertEqual(UpdateLogicWin.normalizeTag("0.5.0"), "0.5.0")
        XCTAssertEqual(UpdateLogicWin.normalizeTag("v1.0.0b1"), "1.0.0b1")
    }

    func testUpdateAvailableComparison() {
        XCTAssertTrue(UpdateLogicWin.isUpdateAvailable(current: "0.4.2", latest: "0.5.0"))
        XCTAssertTrue(UpdateLogicWin.isUpdateAvailable(current: "0.4.2", latest: "v0.5.0"))
        XCTAssertFalse(UpdateLogicWin.isUpdateAvailable(current: "0.5.0", latest: "0.4.2"))
        XCTAssertFalse(UpdateLogicWin.isUpdateAvailable(current: "0.5.0", latest: "0.5.0"))
        XCTAssertTrue(UpdateLogicWin.isUpdateAvailable(current: "0.5.0b1", latest: "0.5.0"))
        XCTAssertFalse(UpdateLogicWin.isUpdateAvailable(current: "0.5.0", latest: "0.5.0b1"))
    }

    func testAutoCheckDueAfter24h() {
        let base: Double = 100_000
        XCTAssertFalse(UpdateLogicWin.shouldCheck(lastCheck: base, now: base + 3600, enabled: true))
        XCTAssertFalse(UpdateLogicWin.shouldCheck(lastCheck: base, now: base + 24 * 3600 - 1, enabled: true))
        XCTAssertTrue(UpdateLogicWin.shouldCheck(lastCheck: base, now: base + 24 * 3600, enabled: true))
        XCTAssertTrue(UpdateLogicWin.shouldCheck(lastCheck: base, now: base + 48 * 3600, enabled: true))
        XCTAssertFalse(UpdateLogicWin.shouldCheck(lastCheck: base, now: base + 48 * 3600, enabled: false))
    }

    func testNotifyOncePerVersion() {
        XCTAssertTrue(UpdateLogicWin.shouldNotify(latest: "0.5.0", lastNotified: ""))
        XCTAssertTrue(UpdateLogicWin.shouldNotify(latest: "v0.5.0", lastNotified: "0.4.2"))
        XCTAssertFalse(UpdateLogicWin.shouldNotify(latest: "0.5.0", lastNotified: "0.5.0"))
        XCTAssertFalse(UpdateLogicWin.shouldNotify(latest: "v0.5.0", lastNotified: "0.5.0"))
    }

    func testUpdateCommandsIncludeAutostartFlagWhenEnabled() {
        let withoutAuto = UpdateLogicWin.updateCommands(autostart: false)
        XCTAssertTrue(withoutAuto.contains("windows\\install.ps1"))
        XCTAssertFalse(withoutAuto.contains("-Autostart"))

        let withAuto = UpdateLogicWin.updateCommands(autostart: true)
        XCTAssertTrue(withAuto.contains("windows\\install.ps1 -Autostart"))
    }

    func testInstallLocationClassification() {
        XCTAssertEqual(UpdateLogicWin.classifyInstallLocation(path: "D:\\repo\\.build\\debug\\infinitus-tray-win.exe"), .debugBuild)
        XCTAssertEqual(UpdateLogicWin.classifyInstallLocation(path: "C:\\Users\\User\\.build\\debug"), .debugBuild)
        XCTAssertEqual(UpdateLogicWin.classifyInstallLocation(path: "C:\\Users\\User\\AppData\\Local\\Infinitus\\bin\\infinitus-tray-win.exe"), .installed)
        XCTAssertEqual(UpdateLogicWin.classifyInstallLocation(path: "C:\\Custom\\Path\\app.exe"), .other("C:\\Custom\\Path\\app.exe"))
    }
}

