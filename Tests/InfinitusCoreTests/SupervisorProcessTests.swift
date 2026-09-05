import XCTest
@testable import InfinitusCore

/// CswapSupervisor against a scripted fake `cswap` — real process spawning,
/// no real engine (running one here would fight the user's live menubar for
/// the store mutex). The fake is a `#!/bin/sh` script: nothing to spawn on
/// Windows.
#if !os(Windows)
final class SupervisorProcessTests: XCTestCase {
    private var scriptURL: URL!

    private func writeScript(_ body: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cswapbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scriptURL = dir.appendingPathComponent("cswap")
        try "#!/bin/sh\n\(body)\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func testEventsArriveAndACrashSchedulesARespawn() throws {
        try writeScript("""
        echo '{"schemaVersion": 1, "event": "poll", "ts": "2026-01-01T00:00:00Z"}'
        exit 1
        """)
        let gotPoll = expectation(description: "poll event")
        let backedOff = expectation(description: "backing off after exit")
        // The script exits after every respawn, so both fire again on
        // the second run when the suite is slow enough for it to land
        // before `wait` returns (flaked ~1 in 3 full runs, 2026-09-03).
        gotPoll.assertForOverFulfill = false
        backedOff.assertForOverFulfill = false
        let supervisor = CswapSupervisor(
            binaryPath: scriptURL.path,
            onLine: { line in
                if case .event(let e) = line, e.kind == "poll" { gotPoll.fulfill() }
            },
            onState: { state in
                if case .backingOff = state { backedOff.fulfill() }
            }
        )
        Task { await supervisor.start() }
        wait(for: [gotPoll, backedOff], timeout: 5)
        Task { await supervisor.stop() }
    }

    func testARefusalParksInsteadOfRespawning() throws {
        try writeScript("""
        echo '{"schemaVersion": 1, "event": "engine-refused", "message": "held elsewhere"}'
        exit 1
        """)
        let refused = expectation(description: "refused state")
        let supervisor = CswapSupervisor(
            binaryPath: scriptURL.path,
            onLine: { _ in },
            onState: { state in
                if state == .refused { refused.fulfill() }
            }
        )
        Task { await supervisor.start() }
        wait(for: [refused], timeout: 5)
        Task { await supervisor.stop() }
    }

    func testStopTerminatesWithoutARespawn() throws {
        try writeScript("sleep 30")
        let running = expectation(description: "running")
        let stopped = expectation(description: "stopped")
        let supervisor = CswapSupervisor(
            binaryPath: scriptURL.path,
            onLine: { _ in },
            onState: { state in
                if case .running = state { running.fulfill() }
                if state == .stopped { stopped.fulfill() }
            }
        )
        Task { await supervisor.start() }
        wait(for: [running], timeout: 5)
        Task { await supervisor.stop() }
        wait(for: [stopped], timeout: 5)
    }
}
#endif
