#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// `OwnedSessions` against a scripted fake `claude` (#151): real process,
/// real pipes, the stream-json handshake replayed from the step-0 probe.
final class OwnedSessionsProcessTests: XCTestCase {
    private var scriptURL: URL!
    private var cwd: URL!

    override func setUpWithError() throws {
        #if os(Windows)
        // The fake is a `#!/bin/sh` script and spawn uses POSIX pipes /
        // SIGKILL. Not ported — OwnedSessions itself compiles, this suite
        // does not run here.
        try XCTSkipIf(true, "OwnedSessions process tests spawn a POSIX shell fake; not ported to Windows yet")
        #endif
    }

    /// Common setup for every fake `claude`: a fresh temp dir as `cwd`, the
    /// script written and made executable. `body` builds the script text
    /// from the dir it will run in.
    private func writeScript(_ body: (URL) -> String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owned-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cwd = dir
        scriptURL = dir.appendingPathComponent("claude")
        try body(dir).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// The fake: `--version` prints a banner; otherwise it answers
    /// `initialize` with init, a user turn with the fixture's permission
    /// request, an allow with a result, and echoes every control request.
    private func writeFake(version: String = "2.1.263 (Claude Code)", swallowInterrupt: Bool = false) throws {
        let ask = Bundle.module.url(forResource: "owned-can-use-tool-write", withExtension: "json", subdirectory: "Fixtures")!.path
        let question = Bundle.module.url(forResource: "owned-can-use-tool-ask", withExtension: "json", subdirectory: "Fixtures")!.path
        try writeScript { dir in
            """
            #!/bin/sh
            case "$1" in --version) echo '\(version)'; exit 0;; esac
            echo "$@" > "\(dir.path)/argv"
            echo "$PATH" > "\(dir.path)/path"
            while IFS= read -r line; do
              case "$line" in
                *'"initialize"'*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
                                  echo '{"type":"system","subtype":"init","session_id":"S-FAKE","permissionMode":"default"}';;
                *'hang'*) echo "$line" >> "\(dir.path)/users";;
                *'aws please'*) echo "$line" >> "\(dir.path)/users"
                                  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"aws s3 ls --profile e2e"}}]}}'
                                  echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"aws: [error] the sso session has expired, fix: aws login"}]}}'
                                  echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
                *'limit please'*) echo "$line" >> "\(dir.path)/users"
                                  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800008100,"rateLimitType":"five_hour"}}'
                                  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800008100,"rateLimitType":"five_hour"}}';;
                *'"type": "user"'*|*'"type":"user"'*) echo "$line" >> "\(dir.path)/users"
                                  case "$line" in *colour*) cat '\(question)';; *) cat '\(ask)';; esac;;
                *'"behavior": "allow"'*|*'"behavior":"allow"'*) echo "$line" >> "\(dir.path)/answers"
                                  echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
                *'"behavior": "deny"'*|*'"behavior":"deny"'*) echo "$line" >> "\(dir.path)/answers"
                                  echo '{"type":"result","subtype":"success","session_id":"S-FAKE"}';;
                *'"interrupt"'*) echo "$line" >> "\(dir.path)/controls"
                                  echo '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
                                  \(swallowInterrupt ? "" : "echo '{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"S-FAKE\"}'");;
                *) echo "$line" >> "\(dir.path)/controls";;
              esac
            done
            exit 0
            """
        }
    }

    /// A `claude` that answers `--version` but never reads stdin again — the
    /// pid replaces itself with `sleep`, so `send`'s frame fills the pipe
    /// and blocks (#151 debt: `closeStdin` must not wedge behind it).
    private func writeNonReadingFake(version: String = "2.1.263 (Claude Code)") throws {
        try writeScript { _ in
            """
            #!/bin/sh
            case "$1" in --version) echo '\(version)'; exit 0;; esac
            exec sleep 60
            """
        }
    }

    /// A `claude` that answers `--version` then exits immediately on the
    /// real invocation, before the app's `terminationHandler` is installed.
    private func writeExitingFake(version: String = "2.1.263 (Claude Code)") throws {
        try writeScript { _ in
            """
            #!/bin/sh
            case "$1" in --version) echo '\(version)'; exit 0;; esac
            exit 3
            """
        }
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

    private func make(swallowInterrupt: Bool = false, interruptGrace: TimeInterval = 5,
                      onLoginNeed: @escaping @Sendable (Int32) -> Void = { _ in }) async throws -> (OwnedSessions, States) {
        try writeFake(swallowInterrupt: swallowInterrupt)
        let states = States()
        let owned = OwnedSessions(binaryPath: scriptURL.path, interruptGrace: interruptGrace,
                                  onState: { pid, s in states.add(pid, s) }, onLoginNeed: onLoginNeed)
        return (owned, states)
    }

    /// A start that did not spawn (the fake's `--version` probe past its
    /// deadline on a loaded machine, #365) is a failure with the reply's
    /// own words, not a crash on `pid!` that takes the xctest worker down.
    private func startedPid(_ owned: OwnedSessions, _ req: SessionStart.Request) async throws -> Int32 {
        let reply = await owned.start(req)
        return Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
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
        let pid = Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
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
        let pid = Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
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
        let pid = try await startedPid(owned, request())
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
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        await owned.stop(pid: pid)
        waitFor("exited") { states.all.last == .exited }
        XCTAssertFalse(owned.ownedPids.contains(pid))
        XCTAssertFalse(ClaudeSessions.isAlive(pid))
    }

    /// #510's sibling: a child waited on through its termination handler
    /// alone is never freed on Linux, and each kept its two pipe ends.
    func testAnExitedChildLeavesNoDescriptorBehind() async throws {
        #if os(Windows)
        throw XCTSkip("no /dev/fd to count")
        #endif
        try writeExitingFake()
        let states = States()
        let owned = OwnedSessions(binaryPath: scriptURL.path, onState: { pid, s in states.add(pid, s) })
        func exits() -> Int { states.all.filter { $0 == .exited }.count }
        func openDescriptors() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        _ = try await startedPid(owned, request())
        waitFor("first exit") { exits() == 1 }
        // `forget` (the Process's release) hops through a Task after the
        // handler; give it a beat before counting, both times.
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = try openDescriptors()
        for i in 2...9 {
            _ = try await startedPid(owned, request())
            waitFor("exit \(i)") { exits() == i }
        }
        // The handler's own cleanup (`forget`) hops through a Task.
        waitFor("cleared") { owned.ownedPids.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = try openDescriptors()
        XCTAssertLessThanOrEqual(after, before + 2, "8 exited children left \(after - before) descriptors open")
    }

    func testTheLedgerHoldsThePidWithItsSessionIdAndClearsOnStop() async throws {
        try writeFake()
        let ledgerURL = cwd.appendingPathComponent("ledger.json")
        let ledger = OwnedLedger(url: ledgerURL)
        let owned = OwnedSessions(binaryPath: scriptURL.path, ledger: ledger, onState: { _, _ in })
        let pid = try await startedPid(owned, request())
        waitFor("ledger sees the session id") { ledger.entries().first(where: { $0.pid == pid })?.sessionId == "S-FAKE" }
        await owned.stop(pid: pid)
        // `forget` runs in the termination handler, off `stop`'s own thread.
        waitFor("ledger cleared") { ledger.entries().isEmpty }
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

    /// #223 §6: the CLI's interrupt is trusted only for the grace period;
    /// a child that never answers with a `result` still reads idle after it.
    func testAnInterruptWithoutAResultClosesTheTurnAfterTheGrace() async throws {
        let (owned, states) = try await make(swallowInterrupt: true, interruptGrace: 0.5)
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.send(pid: pid, text: "hang"))   // the fake never answers this turn
        XCTAssertEqual(owned.registry[pid]?.state, .busy)
        XCTAssertTrue(owned.interrupt(pid: pid))
        waitFor("interrupt echoed") { self.file("controls").contains("interrupt") }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(owned.registry[pid]?.state, .busy, "trusted within the grace")
        waitFor("idle after the grace", timeout: 3) { owned.registry[pid]?.state == .idle }
        await owned.stop(pid: pid)
    }

    func testARejectedRateLimitIsNotedOncePerTurnAndClearedByTheNext() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.send(pid: pid, text: "limit please"))
        waitFor("noted") { !owned.limits(pid: pid).isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(owned.limits(pid: pid).count, 1, "the same window and reset is one note")
        XCTAssertEqual(owned.limits(pid: pid).first?.rateLimitType, "five_hour")
        XCTAssertTrue(owned.send(pid: pid, text: "next turn"))
        XCTAssertTrue(owned.limits(pid: pid).isEmpty)
        await owned.stop(pid: pid)
    }

    /// The CLI's error names no profile; the failed command does (#402).
    func testAnExpiredSignInOnTheStreamIsANeedNamedByTheFailedCommand() async throws {
        let fired = States()
        let (owned, states) = try await make(onLoginNeed: { fired.add($0, .busy) })
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.loginNeeds(pid: pid).isEmpty)
        let before = Date()
        XCTAssertTrue(owned.send(pid: pid, text: "aws please"))
        waitFor("need") { !owned.loginNeeds(pid: pid).isEmpty }
        let need = try XCTUnwrap(owned.loginNeeds(pid: pid).first)
        XCTAssertEqual(need.provider, .aws)
        XCTAssertEqual(need.profile, "e2e")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(need.failedAt).timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        waitFor("turn") { states.all.filter { $0 == .idle }.count >= 2 }
        XCTAssertEqual(fired.all.count, 1, "tool_use, tool_result and result: one change")
        XCTAssertEqual(owned.loginNeeds(pid: 1).count, 0, "not our pid")
        await owned.stop(pid: pid)
    }

    func testDeliverSendsImagesAsBlocksAndRefusesWhatTheAPIWontTake() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        let heic = SessionInput.Request(kind: .message, text: "look", attachments: [.init(name: "a.heic", mime: "image/heic", data: Data([1]))])
        XCTAssertEqual(owned.deliver(heic, record: record(pid))?.outcome, "rejected")
        let png = SessionInput.Request(kind: .message, text: "look", attachments: [.init(name: "a.png", mime: "image/png", data: Data([1, 2, 3]))])
        XCTAssertEqual(owned.deliver(png, record: record(pid)), SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("sent") { self.file("users").contains("image\\/png") || self.file("users").contains("image/png") }
        let users = file("users").replacingOccurrences(of: "\\/", with: "/")
        XCTAssertLessThan(users.range(of: "\"image\"")!.lowerBound, users.range(of: "\"text\"")!.lowerBound,
                          "the image block precedes the text block")
        XCTAssertTrue(users.contains(Data([1, 2, 3]).base64EncodedString()))
        await owned.stop(pid: pid)
    }

    func testDeliverIsNilForAPidItDoesNotOwn() async throws {
        let (owned, _) = try await make()
        XCTAssertNil(owned.deliver(SessionInput.Request(kind: .message, text: "hi"), record: record(4242)))
    }

    func testDeliverRoutesMessageKeyApproveAndEscape() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
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

    func testDeliverDenyCarriesTheReasonOnTheWire() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .message, text: "[Infinitus] hello"), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("pending") { !owned.pending(pid: pid).isEmpty }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .deny, text: "not on main"), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("denied") { self.file("answers").contains("\"deny\"") }
        XCTAssertTrue(file("answers").contains("\"message\":\"not on main\""), file("answers"))
        await owned.stopAll()
    }

    func testDeliverDenyWithNoReasonUsesOwnedWireDenyMessage() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .message, text: "[Infinitus] hello"), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("pending") { !owned.pending(pid: pid).isEmpty }

        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .deny, text: ""), record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("denied") { self.file("answers").contains("\"deny\"") }
        XCTAssertTrue(file("answers").contains("\"message\":\"\(OwnedWire.denyMessage)\""), file("answers"))
        await owned.stopAll()
    }

    func testDeliverAnswersEveryQuestionOfTheParkedPrompt() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .answers, text: "{}"), record: record(pid))?.detail,
                       "no pending question")
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .message, text: "[Infinitus] pick a colour"), record: record(pid))?.outcome,
                       "delivered")
        waitFor("question parked") { owned.pending(pid: pid).first?.questions.isEmpty == false }
        // Blank text answers nothing; a typed non-option is Claude Code's
        // "Other" and goes through as the answer (OwnedWireTests has the
        // option / free-text / mixed matrix).
        let blank = owned.deliver(SessionInput.Request(kind: .answers, text: SessionInput.Answers.encode(["Which colour?": "  "])),
                                  record: record(pid))
        XCTAssertEqual(blank?.outcome, "rejected")
        XCTAssertEqual(blank?.detail, "no such option")
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .answers, text: SessionInput.Answers.encode(["Which colour?": "Green"])),
                                     record: record(pid)),
                       SessionInput.Reply(outcome: "delivered", channel: "stdin"))
        waitFor("answered") { self.file("answers").contains("\"Green\"") }
        XCTAssertTrue(owned.pending(pid: pid).isEmpty)
        await owned.stopAll()
    }

    func testDeliverRejectsAnUnsupportedKeyAndModeIsNotItsBusiness() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertEqual(owned.deliver(SessionInput.Request(kind: .key, text: "q"), record: record(pid))?.outcome, "rejected")
        XCTAssertNil(owned.deliver(SessionInput.Request(kind: .mode, text: "plan"), record: record(pid)))
        await owned.stopAll()
    }

    func testSetPermissionModeWritesTheControlRequest() async throws {
        let (owned, states) = try await make()
        let pid = try await startedPid(owned, request())
        waitFor("init") { states.all.contains(.idle) }
        XCTAssertTrue(owned.setPermissionMode(pid: pid, mode: "plan"))
        waitFor("mode echoed") { self.file("controls").contains("set_permission_mode") && self.file("controls").contains("plan") }
        XCTAssertFalse(owned.setPermissionMode(pid: pid, mode: "rm -rf"), "only Claude Code's own mode names")
        await owned.stopAll()
    }

    // MARK: #151 debt (PR #278) — a wedged stdin write, a child that beats the handler

    /// A frame write blocked on a full stdin pipe (child alive, not
    /// reading) must not wedge `stop` behind it forever — `closeStdin`
    /// gives up and `stop` moves straight to `terminate()`.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: Bool?
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testStopDoesNotWedgeBehindAWriteBlockedOnAFullPipe() async throws {
        try writeNonReadingFake()
        let states = States()
        let owned = OwnedSessions(binaryPath: scriptURL.path, onState: { pid, s in states.add(pid, s) })
        let reply = await owned.start(request())
        XCTAssertEqual(reply.outcome, "started", reply.detail ?? "")
        let pid = Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
        let big = String(repeating: "x", count: 200_000) // > the 64 KiB pipe buffer
        let sent = ResultBox()
        DispatchQueue.global().async { sent.set(owned.send(pid: pid, text: big)) }
        try await Task.sleep(nanoseconds: 400_000_000) // let the writer actually fill the pipe and block
        let start = Date()
        await owned.stop(pid: pid)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "stop must not wait behind the wedged writer")
        waitFor("gone") { !owned.ownedPids.contains(pid) }
        XCTAssertFalse(ClaudeSessions.isAlive(pid))
        // false proves the write was still blocked when stop ran (a write
        // that had already completed would return true) and that
        // terminate()'s SIGTERM freed it with EPIPE rather than stop
        // wedging behind it forever.
        waitFor("writer unblocked with EPIPE") { sent.get() == false }
    }

    /// `!p.isRunning` hand-fires the termination handler for a child that
    /// exited before `run()` returned — `.exited` must still reach `onState`
    /// and the pid must leave the registry.
    func testAChildThatExitsBeforeTheHandlerIsInstalledStillReportsExited() async throws {
        try writeExitingFake()
        let states = States()
        let owned = OwnedSessions(binaryPath: scriptURL.path, onState: { pid, s in states.add(pid, s) })
        let reply = await owned.start(request())
        let pid = Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
        waitFor("exited") { states.all.contains(.exited) }
        waitFor("forgotten") { !owned.ownedPids.contains(pid) }
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
        let pid = Int32(try XCTUnwrap(reply.pid, "start: \(reply.outcome) \(reply.detail ?? "")"))
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
