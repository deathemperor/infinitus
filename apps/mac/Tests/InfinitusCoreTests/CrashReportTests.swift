import XCTest
@testable import InfinitusCore

final class CrashReportTests: XCTestCase {
    func testFramesFollowTheAttributedThreadsFirstChildren() {
        let json = """
        {"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem","offsetIntoBinaryTextSegment":1,"subFrames":[]}]},
          {"threadAttributed":true,"callStackRootFrames":[
            {"binaryName":"InfinitusMobile","offsetIntoBinaryTextSegment":4096,
             "subFrames":[{"binaryName":"SwiftUI","offsetIntoBinaryTextSegment":77,
                           "subFrames":[{"binaryName":"UIKitCore","offsetIntoBinaryTextSegment":9}]}]}]}]}
        """
        XCTAssertEqual(CrashReport.frames(fromCallStackTree: Data(json.utf8)),
                       ["InfinitusMobile +4096", "SwiftUI +77", "UIKitCore +9"])
        XCTAssertEqual(CrashReport.frames(fromCallStackTree: Data("nope".utf8)), [])
    }

    func testMacIPSParsesReasonFramesAndTime() throws {
        let ips = """
        {"app_name":"Infinitus","bug_type":"309"}
        {"captureTime":"2026-09-04 22:49:12.0000 +0700","faultingThread":1,
         "exception":{"type":"EXC_CRASH","signal":"SIGABRT"},
         "termination":{"indicator":"abort() called"},
         "bundleInfo":{"CFBundleShortVersionString":"0.4.3"},"osVersion":{"train":"macOS 26.0"},
         "usedImages":[{"name":"Infinitus"},{"name":"Foundation"}],
         "threads":[{"frames":[]},{"frames":[{"imageIndex":1,"imageOffset":10,"symbol":"-[NSConcreteFileHandle writeData:]"},{"imageIndex":0,"imageOffset":2048}]}]}
        """
        let report = try XCTUnwrap(CrashReport.fromIPS(ips, device: "Studio"))
        XCTAssertEqual(report.platform, "mac")
        XCTAssertEqual(report.reason, "EXC_CRASH SIGABRT — abort() called")
        XCTAssertEqual(report.frames, ["Foundation +10 -[NSConcreteFileHandle writeData:]", "Infinitus +2048"])
        XCTAssertEqual(report.appVersion, "0.4.3")
        XCTAssertEqual(report.osVersion, "macOS 26.0")
        XCTAssertEqual(Int(report.at.timeIntervalSince1970), 1788536952)
        XCTAssertEqual(report.summary, "Studio · crash · EXC_CRASH SIGABRT — abort() called")
        XCTAssertTrue(report.transcript.contains("faulting thread:\n  Foundation +10"))
        XCTAssertNil(CrashReport.fromIPS("no newline"))
    }

    func testStoreListsNewestFirstAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crashes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CrashStore(directory: dir, keep: 2)
        func report(_ id: String, _ t: Double) -> CrashReport {
            CrashReport(id: id, platform: "ios", device: "iPhone", appVersion: "1", osVersion: "iOS 26",
                        at: Date(timeIntervalSince1970: t), kind: "crash", reason: "SIGSEGV", frames: ["a +1"], raw: "x")
        }
        try store.save(report("a", 100))
        try store.save(report("c", 300))
        try store.save(report("b", 200))
        XCTAssertEqual(store.list().map(\.id), ["c", "b"], "keep 2, newest first")
        XCTAssertEqual(store.list().first?.raw, "x")
        store.remove("c")
        XCTAssertEqual(store.list().map(\.id), ["b"])
    }

    func testRawIsCapped() {
        let big = String(repeating: "z", count: CrashReport.rawCap + 10)
        let r = CrashReport(platform: "ios", device: "d", appVersion: "1", osVersion: "o", at: Date(), kind: "crash", reason: "r", raw: big)
        XCTAssertEqual(r.raw?.count, CrashReport.rawCap)
    }
}
