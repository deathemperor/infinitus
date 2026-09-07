#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// `OwnedSessions` against a scripted fake `claude` (#151): real process,
/// real pipes, the stream-json handshake replayed from the step-0 probe.
final class OwnedSessionsProcessTests: XCTestCase {
    private var scriptURL: URL!
    private var cwd: URL!

    /// The fake: `--version` prints a banner; otherwise it answers
    /// `initialize` with init, a user turn with the fixture's permission
    /// request, an allow with a result, and echoes every control request.
    private func writeFake(version: String = "2.1.263 (Claude Code)") throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owned-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cwd = dir
        scriptURL = dir.appendingPathComponent("claude")
        let ask = Bundle.module.url(forResource: "owned-can-use-tool-write", withExtension: "json", subdirectory: "Fixtures")!.path
        try """
        #!/bin/sh
        case "$1" in --version) echo '\(version)'; exit 0;; esac
        echo "$@" > "\(dir.path)/argv"
        echo "$PATH" > "\(dir.path)/path"
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
                              echo '{"type":"system","subtype":"init","session_id":"S-FAKE","permissionMode":"default"}';;
            *'"type": "user"'*|*'"type":"user"'*) echo "$line" >> "\(dir.path)/users"; cat '\(ask)';;
            *'"behavior": "allow"'*|*'"behavior":"allow"'*) echo "$line" >> "\(dir.path)/answers"
                              echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
            *'"behavior": "deny"'*|*'"behavior":"deny"'*) echo "$line" >> "\(dir.path)/answers"
                              echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
            *'"interrupt"'*) echo "$line" >> "\(dir.path)/controls"
                              echo '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
                              echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
            *) echo "$line" >> "\(dir.path)/controls";;
          esac
        done
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func file(_ name: String) -> String {
        (try? String(contentsOf: cwd.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let exp = expectation(description: what)
        Task {
            while !cond() { try? await Task.sleep(nanoseconds: 20_000_000) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
    }

    private final class States: @unchecked Sendable {
        private let lock = NSLock(); private var list: [(Int32, OwnedSessions.State)] = []
        func add(_ pid: Int32, _ s: OwnedSessions.State) { lock.lock(); list.append((pid, s)); lock.unlock() }
        var all: [OwnedSessions.State] { lock.lock(); defer { lock.unlock() }; return list.map(\.1) }
    }

    private func make() async throws -> (OwnedSessions, States) {
        try writeFake()
        let states = States()
        let owned = OwnedSessions(binaryPath: scriptURL.path, onState: { pid, s in states.add(pid, s) })
        return (owned, states)
    }

    private func request(_ prompt: String? = nil) -> SessionStart.Request {
        SessionStart.Request(cwd: cwd.path, prompt: prompt, permissionMode: "acceptEdits", headless: true)
    }

    func testStartSpawnsWithTheStreamingArgvAndReportsIdleAfterInit() async throws {
        let (owned, states) = try await make()
        let reply = await owned.start(request())
        XCTAssertEqual(reply.outcome, "started")
        XCTAssertEqual(reply.host, "owned")
        let pid = Int32(reply.pid ?? 0)
        XCTAssertGreaterThan(pid, 0)
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(file("argv").contains("--permission-prompt-tool stdio"), file("argv"))
        XCTAssertTrue(file("argv").contains("--permission-mode acceptEdits"))
        XCTAssertTrue(owned.ownedPids.contains(pid))
        await owned.stopAll()
    }

    func testAFirstPromptGoesOverStdinAndAPermissionParksAsPending() async throws {
        let (owned, states) = try await make()
        let reply = await owned.start(request("write hello"))
        let pid = Int32(reply.pid!)
        waitFor("pending") { !owned.pending(pid: pid).isEmpty }
        // The card must not read "idle" while the first prompt is running:
        // init keeps the child busy, only the result frees it.
        XCTAssertEqual(states.all.first, .waiting)
        XCTAssertTrue(file("users").contains("write hello"))
        XCTAssertEqual(owned.pending(pid: pid).first?.toolName, "Write")
        XCTAssertEqual(states.all.last, .waiting)

        XCTAssertTrue(owned.answer(pid: pid, requestId: owned.pending(pid: pid)[0].requestId, decision: .allow(forSession: false)))
        waitFor("result") { states.all.last == .idle }
        XCTAssertTrue(owned.pending(pid: pid).isEmpty)
        XCTAssertTrue(file("answers").contains("\"allow\""))
        XCTAssertFalse(owned.answer(pid: pid, requestId: "nope", decision: .deny(message: "x")), "unknown request id")
        await owned.stopAll()
    }

    /// The long-poll's wake (#151 follow-up): every transition and every
    /// parked prompt broadcasts on `wake`, so a waiter blocked on it
    /// returns at once.
    func testATransitionBroadcastsTheWakeCondition() async throws {
        let (owned, _) = try await make()
        let reply = await owned.start(request())
        let pid = Int32(reply.pid!)
        waitFor("idle") { owned.registry[pid]?.state == .idle }
        let woke = expectation(description: "woken")
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            owned.wake.lock()
            started.signal()
            let ok = owned.wake.wait(until: Date().addingTimeInterval(5))
            owned.wake.unlock()
            if ok { woke.fulfill() }
        }
        started.wait()
        XCTAssertTrue(owned.send(pid: pid, text: "go"))   // idle → busy, then the fake parks a can_use_tool
        await fulfillment(of: [woke], timeout: 5)
        waitFor("parked") { !owned.pending(pid: pid).isEmpty }
        await owned.stop(pid: pid)
    }

    func testSendMarksBusyAndInterruptGoesAsAControlRequest() async throws {
        let (owned, states) = try await make()
        let pid = Int32(await owned.start(request()).pid!)
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.send(pid: pid, text: "count to 30"))
        waitFor("busy then waiting") { states.all.contains(.busy) && states.all.last == .waiting }
        XCTAssertTrue(owned.interrupt(pid: pid))
        waitFor("interrupt echoed") { self.file("controls").contains("interrupt") }
        XCTAssertFalse(owned.send(pid: 999_999, text: "nobody"), "not an owned pid")
        await owned.stopAll()
    }

    func testStopClosesStdinAndTheChildExits() async throws {
        let (owned, states) = try await make()
        let pid = Int32(await owned.start(request()).pid!)
        waitFor("init") { states.all.contains(.idle) }
        await owned.stop(pid: pid)
        waitFor("exited") { states.all.last == .exited }
        XCTAssertFalse(owned.ownedPids.contains(pid))
        XCTAssertFalse(ClaudeSessions.isAlive(pid))
    }

    func testAnOldClaudeIsRefusedWithTheVersionInTheDetail() async throws {
        try writeFake(version: "2.1.200 (Claude Code)")
        let owned = OwnedSessions(binaryPath: scriptURL.path, onState: { _, _ in })
        let reply = await owned.start(request())
        XCTAssertEqual(reply.outcome, "failed")
        XCTAssertTrue(reply.detail?.contains("2.1.200") == true, reply.detail ?? "")
        XCTAssertTrue(reply.detail?.contains("2.1.259") == true)
        XCTAssertNil(reply.pid)
    }

    func testTheChildGetsAPathThatReachesTheToolsALoginShellSees() async throws {
        let (owned, states) = try await make()
        _ = await owned.start(request())
        waitFor("init") { states.all.contains(.idle) }
        waitFor("path") { !self.file("path").isEmpty }
        // The binary's own folder and the usual tool prefixes ride in front
        // of whatever the GUI app inherited.
        let path = file("path").split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains(cwd.path), "\(path)")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "\(path)")
        XCTAssertTrue(path.contains("/usr/bin"), "\(path)")
        await owned.stopAll()
    }

    func testABadCwdIsRefusedBeforeSpawning() async throws {
        let (owned, _) = try await make()
        let reply = await owned.start(SessionStart.Request(cwd: cwd.appendingPathComponent("missing").path, headless: true))
        XCTAssertEqual(reply.outcome, "badCwd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("argv").path))
    }

    // MARK: deliver — the phone's input routed into the owned child

    private func record(_ pid: Int32) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: "S-FAKE", cwd: cwd.path, kind: "interactive")
    }

    func testDeliverIsNilForAPidItDoesNotOwn() async throws {
        let (owned, _) = try await make()
        XCTAssertNil(owned.deliver(SessionInput.Request(kind: .message, text: "hi"), record: record(4242)))
    }

    func testDeliverRoutesMessageKeyApproveAndEscape() async throws {
        let (owned, states) = try await make()
        let pid = Int32(await owned.start(request()).pid!)
        waitFor("init") { states.all.contains(.idle) }

        let msg = owned.deliver(SessionInput.Request(kind: .message, text: "[Infinitus] hello"), record: record(pid))
        XCTAssertEqual(msg, SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("pending") { !owned.pending(pid: pid).isEmpty }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .key, text: "esc"), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("interrupt echoed") { self.file("controls").contains("interrupt") }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .key, text: "3"), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("denied") { self.file("answers").contains("\"deny\"") }
        XCTAssertTrue(owned.pending(pid: pid).isEmpty)

        let nothing = owned.deliver(SessionInput.Request(kind: .key, text: "1"), record: record(pid))
        XCTAssertEqual(nothing?.outcome, "rejected")
        XCTAssertEqual(nothing?.detail, "no pending request")

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .message, text: "again"), record: record(pid))?.outcome, "delivered")
        waitFor("pending again") { !owned.pending(pid: pid).isEmpty }
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .approve, text: "Write"), record: record(pid))?.outcome, "delivered")
        waitFor("allowed") { self.file("answers").contains("\"allow\"") }
        // The clients' approve button reads "Allow <tool> for this session":
        // the suggested rule rides along. A plain Allow is key "1".
        XCTAssertTrue(file("answers").contains("updatedPermissions"), file("answers"))
        await owned.stopAll()
    }

    func testDeliverRejectsAnUnsupportedKeyAndModeIsNotItsBusiness() async throws {
        let (owned, states) = try await make()
        let pid = Int32(await owned.start(request()).pid!)
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .key, text: "q"), record: record(pid))?.outcome, "rejected")
        XCTAssertNil(owned.deliver(SessionInput.Request(kind: .mode, text: "plan"), record: record(pid)))
        await owned.stopAll()
    }

    func testSetPermissionModeWritesTheControlRequest() async throws {
        let (owned, states) = try await make()
        let pid = Int32(await owned.start(request()).pid!)
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.setPermissionMode(pid: pid, mode: "plan"))
        waitFor("mode echoed") { self.file("controls").contains("set_permission_mode") && self.file("controls").contains("plan") }
        XCTAssertFalse(owned.setPermissionMode(pid: pid, mode: "rm -rf"), "only Claude Code's own mode names")
        await owned.stopAll()
    }
}

/// The real binary, when asked for: `INFINITUS_OWNED_E2E=1 swift test
/// --filter OwnedSessionsRealClaude`. Spends one small turn of the user's
/// quota, so never in the default run.
final class OwnedSessionsRealClaudeTests: XCTestCase {
    func testRealClaudeParksAWriteAndFinishesOnAllow() async throws {
        guard ProcessInfo.processInfo.environment["INFINITUS_OWNED_E2E"] == "1" else {
            throw XCTSkip("set INFINITUS_OWNED_E2E=1 to run against the installed claude")
        }
        guard let bin = ClaudeLocator.locate() else { throw XCTSkip("no claude installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owned-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        final class Box: @unchecked Sendable { let lock = NSLock(); var states: [OwnedSessions.State] = [] }
        let box = Box()
        let owned = OwnedSessions(binaryPath: bin, onState: { _, s in box.lock.lock(); box.states.append(s); box.lock.unlock() })
        let reply = await owned.start(SessionStart.Request(
            cwd: dir.path, prompt: "Use the Write tool to create hello.txt containing hello. Then stop.",
            permissionMode: "manual", headless: true))
        XCTAssertEqual(reply.outcome, "started", reply.detail ?? "")
        let pid = Int32(reply.pid!)
        // manual forces the ask whatever this Mac's settings default to, so
        // the Write must park as a prompt before the allow lets it through.
        var prompted: [String] = []
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let first = owned.pending(pid: pid).first {
                prompted.append(first.toolName)
                _ = owned.answer(pid: pid, requestId: first.requestId, decision: .allow(forSession: false))
            }
            box.lock.lock(); let last = box.states.last; let sawBusyOrIdle = box.states.contains(.idle); box.lock.unlock()
            if sawBusyOrIdle, last == .idle, FileManager.default.fileExists(atPath: dir.appendingPathComponent("hello.txt").path) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hello.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(prompted.contains("Write"), "no can_use_tool arrived; prompts seen: \(prompted)")
        let roster = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).first { $0.pid == pid }
        XCTAssertEqual(roster?.entrypoint, "sdk-cli")
        await owned.stop(pid: pid)
        XCTAssertFalse(ClaudeSessions.isAlive(pid))
    }
}
#endif
