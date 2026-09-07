#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// The orphan ledger (#151 follow-up): round-trip, then the launch sweep
/// that stops a headless child a crashed app left behind.
final class OwnedLedgerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("owned-ledger-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func roster(pid: Int32, sessionId: String, entrypoint: String = "sdk-cli") throws -> URL {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let obj: [String: Any] = ["pid": pid, "sessionId": sessionId, "cwd": "/p", "kind": "bg",
                                  "entrypoint": entrypoint]
        let url = sessions.appendingPathComponent("\(pid).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    func testRecordForgetAndEntriesRoundTripThroughATempFile() {
        let ledger = OwnedLedger(url: dir.appendingPathComponent("ledger.json"))
        XCTAssertTrue(ledger.entries().isEmpty, "missing file reads as empty")
        ledger.record(pid: 111, sessionId: "")
        ledger.record(pid: 222, sessionId: "S1")
        XCTAssertEqual(Set(ledger.entries().map(\.pid)), [111, 222])
        // Re-recording the same pid replaces, not duplicates (init arriving
        // after the empty-sessionId spawn record).
        ledger.record(pid: 111, sessionId: "S0")
        XCTAssertEqual(ledger.entries().first { $0.pid == 111 }?.sessionId, "S0")
        ledger.forget(pid: 222)
        XCTAssertEqual(ledger.entries().map(\.pid), [111])
    }

    func testSweepSignalsAndForgetsAMatchingOwnedOrphan() throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        _ = try roster(pid: pid, sessionId: "S1")
        let ledger = OwnedLedger(url: dir.appendingPathComponent("ledger.json"))
        ledger.record(pid: pid, sessionId: "S1")
        var signalled: [Int32] = []
        let swept = OwnedSessions.sweepOrphans(ledger: ledger, claudeDir: dir, alive: { _ in true },
                                               signal: { signalled.append($0) })
        XCTAssertEqual(swept, [pid])
        XCTAssertEqual(signalled, [pid])
        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testSweepSkipsASessionIdMismatchAndForgetsIt() throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        _ = try roster(pid: pid, sessionId: "OTHER")
        let ledger = OwnedLedger(url: dir.appendingPathComponent("ledger.json"))
        ledger.record(pid: pid, sessionId: "S1")
        var signalled: [Int32] = []
        let swept = OwnedSessions.sweepOrphans(ledger: ledger, claudeDir: dir, alive: { _ in true },
                                               signal: { signalled.append($0) })
        XCTAssertTrue(swept.isEmpty)
        XCTAssertTrue(signalled.isEmpty)
        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testSweepSkipsADeadPidAndForgetsIt() {
        let ledger = OwnedLedger(url: dir.appendingPathComponent("ledger.json"))
        ledger.record(pid: 424_242, sessionId: "S1")
        var signalled: [Int32] = []
        let swept = OwnedSessions.sweepOrphans(ledger: ledger, claudeDir: dir, alive: { _ in false },
                                               signal: { signalled.append($0) })
        XCTAssertTrue(swept.isEmpty)
        XCTAssertTrue(signalled.isEmpty)
        XCTAssertTrue(ledger.entries().isEmpty)
    }

    func testSweepSkipsAnEmptySessionIdAndForgetsIt() throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        _ = try roster(pid: pid, sessionId: "")
        let ledger = OwnedLedger(url: dir.appendingPathComponent("ledger.json"))
        // init never arrived before the crash — the pid may have been reused.
        ledger.record(pid: pid, sessionId: "")
        var signalled: [Int32] = []
        let swept = OwnedSessions.sweepOrphans(ledger: ledger, claudeDir: dir, alive: { _ in true },
                                               signal: { signalled.append($0) })
        XCTAssertTrue(swept.isEmpty)
        XCTAssertTrue(signalled.isEmpty)
        XCTAssertTrue(ledger.entries().isEmpty)
    }
}
#endif
