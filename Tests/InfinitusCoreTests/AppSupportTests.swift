import XCTest
@testable import InfinitusCore

final class AppSupportTests: XCTestCase {
    func testTheRootIsInfinitusUnderApplicationSupportUnlessOverridden() {
        let real = AppSupport.root(environment: [:])
        XCTAssertEqual(real.lastPathComponent, "Infinitus")
        XCTAssertEqual(real.deletingLastPathComponent(),
                       FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        XCTAssertEqual(AppSupport.root(environment: ["INFINITUS_APP_SUPPORT": "/tmp/fix/app-support"]).path, "/tmp/fix/app-support")
        XCTAssertEqual(AppSupport.root(environment: ["INFINITUS_APP_SUPPORT": ""]), real, "an empty override is no override")
        // Every path helper hangs off the root, so one variable moves them all.
        XCTAssertEqual(CrashStore.defaultDirectory(appSupport: URL(fileURLWithPath: "/tmp/fix")).path, "/tmp/fix/crashes")
        XCTAssertEqual(RowTheme.customThemesURL(appSupport: URL(fileURLWithPath: "/tmp/fix")).path, "/tmp/fix/themes.json")
        XCTAssertEqual(StatsScanner.defaultCacheURL(environment: ["INFINITUS_APP_SUPPORT": "/tmp/fix"]).path, "/tmp/fix/stats/transcripts.json")
    }
}
