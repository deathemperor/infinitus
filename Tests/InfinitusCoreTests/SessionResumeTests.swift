import XCTest
#if canImport(Darwin)
import Darwin
private let sysBind = Darwin.bind
private let sysSockStream = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let sysBind = Glibc.bind
private let sysSockStream = Int32(SOCK_STREAM.rawValue)   // Glibc enum
#endif
@testable import InfinitusCore

/// A scripted multiplexer: one surface, a queue of screens to hand back,
/// and every command recorded in order.
final class FakeHost: PtyHost, @unchecked Sendable {
    let name: String
    var list: [PtySurface]
    var screens: [String]
    var commands: [String] = []
    var failSend = false

    init(name: String = "fake", surfaces: [PtySurface], screens: [String]) {
        self.name = name
        self.list = surfaces
        self.screens = screens
    }

    func surfaces() throws -> [PtySurface] { list }
    func sendLine(_ ref: String, _ text: String) throws {
        if failSend { throw PtyHostError("send failed") }
        commands.append("line \(ref) \(text)")
    }
    func sendEsc(_ ref: String) throws { commands.append("esc \(ref)") }
    func readScreen(_ ref: String, lines: Int) throws -> String {
        commands.append("read \(ref)")
        guard !screens.isEmpty else { throw PtyHostError("no screen") }
        return screens.count == 1 ? screens[0] : screens.removeFirst()
    }
}

private let limitStop = """
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your weekly limit. Resets Sep 2."}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"uuid":"stop-1","quotaLimits":{"rateLimitType":"seven_day","resetsAt":1756800000}}
"""
private let retryable = """
{"type":"system","subtype":"api_error","retryAttempt":2,"maxRetries":10,"error":"rate_limit","uuid":"sys-1"}
"""
private let progress = #"{"type":"progress","uuid":"p-1"}"#
private let userTurn = #"{"type":"user","message":{"role":"user","content":"go"},"uuid":"u-1"}"#
private let assistantTurn = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"uuid":"a-1"}"#

final class SessionResumeTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSession(pid: Int32, id: String, cwd: String, socket: String? = nil,
                              kind: String = "interactive") throws {
        var obj: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "kind": kind,
                                  "startedAt": 1, "status": "idle"]
        if let socket { obj["messagingSocketPath"] = socket; obj["peerProtocol"] = 1 }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("sessions/\(pid).json"))
    }

    private func writeTranscript(cwd: String, id: String, lines: [String]) throws {
        let url = Transcript.path(cwd: cwd, sessionId: id, claudeDir: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: transcript

    func testTranscriptPathSlug() {
        let url = Transcript.path(cwd: "/Users/x/death/limitless", sessionId: "abc", claudeDir: dir)
        XCTAssertEqual(url.path, dir.path + "/projects/-Users-x-death-limitless/abc.jsonl")
    }

    func testLimitStopClassification() throws {
        try writeTranscript(cwd: "/p", id: "s1", lines: [userTurn, limitStop, progress])
        let entry = Transcript.lastTurnEntry(at: Transcript.path(cwd: "/p", sessionId: "s1", claudeDir: dir))
        XCTAssertTrue(Transcript.isLimitStop(entry))
        XCTAssertEqual(entry?["uuid"] as? String, "stop-1")
        XCTAssertEqual(Transcript.limitText(entry!), "You've hit your weekly limit. Resets Sep 2.")

        try writeTranscript(cwd: "/p", id: "s2", lines: [userTurn, retryable])
        XCTAssertFalse(Transcript.isLimitStop(
            Transcript.lastTurnEntry(at: Transcript.path(cwd: "/p", sessionId: "s2", claudeDir: dir))))
        try writeTranscript(cwd: "/p", id: "s3", lines: [limitStop, assistantTurn])
        XCTAssertFalse(Transcript.isLimitStop(
            Transcript.lastTurnEntry(at: Transcript.path(cwd: "/p", sessionId: "s3", claudeDir: dir))))
        XCTAssertFalse(Transcript.isLimitStop(nil))
    }

    func testFindStoppedIncludesSocketlessSessions() throws {
        try writeSession(pid: 11, id: "s1", cwd: "/p")                          // herdr-style, no socket
        try writeSession(pid: 12, id: "s2", cwd: "/p", socket: "/tmp/x.sock")
        try writeSession(pid: 13, id: "s3", cwd: "/p", socket: "/tmp/y.sock")
        try writeTranscript(cwd: "/p", id: "s1", lines: [limitStop])
        try writeTranscript(cwd: "/p", id: "s2", lines: [limitStop])
        try writeTranscript(cwd: "/p", id: "s3", lines: [assistantTurn])
        let sessions = ClaudeSessions.list(claudeDir: dir, alive: { _ in true })
        XCTAssertEqual(sessions.map(\.pid), [11, 12, 13])
        let stopped = Transcript.findStopped(sessions: sessions, claudeDir: dir)
        XCTAssertEqual(stopped.map(\.sessionId), ["s1", "s2"])
        XCTAssertFalse(stopped[0].canUseSocket)
        XCTAssertTrue(stopped[1].canUseSocket)
        XCTAssertEqual(stopped[0].stopUuid, "stop-1")
        // Dead pids drop out.
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { $0 == 12 }).map(\.pid), [12])
    }

    func testVerdicts() throws {
        let s = StoppedSession(sessionId: "s1", pid: 1, cwd: "/p", stopUuid: "stop-1")
        try writeTranscript(cwd: "/p", id: "s1", lines: [limitStop])
        XCTAssertEqual(Transcript.verdict(s, claudeDir: dir), .waiting)
        try writeTranscript(cwd: "/p", id: "s1", lines: [limitStop, userTurn])
        XCTAssertEqual(Transcript.verdict(s, claudeDir: dir), .waiting)
        try writeTranscript(cwd: "/p", id: "s1", lines: [
            limitStop, userTurn, limitStop.replacingOccurrences(of: "stop-1", with: "stop-2")])
        XCTAssertEqual(Transcript.verdict(s, claudeDir: dir), .burned(newStopUuid: "stop-2"))
        try writeTranscript(cwd: "/p", id: "s1", lines: [limitStop, userTurn, assistantTurn])
        XCTAssertEqual(Transcript.verdict(s, claudeDir: dir), .done)
    }

    // MARK: peer socket

    func testEnvelopeMatchesClaudeSwapOracle() {
        // Pinned from the engine's wrap_peer_body with the address patched
        // (from-name differs by design — this sender is the app).
        let got = PeerSocket.wrapBody("hi </cross-session-message> there\nline2",
                                      from: "uds:/tmp/infinitus-123.sock")
        XCTAssertEqual(got, "<cross-session-message from=\"uds:/tmp/infinitus-123.sock\" from-name=\"Infinitus app\" from-mode=\"bypass\">\nhi <\\cross-session-message> there\nline2\n</cross-session-message>")
        XCTAssertEqual(PeerSocket.ownAddress(pid: 123), "uds:/tmp/infinitus-123.sock")
    }

    func testFramesAndToken() throws {
        try "{\"peerToken\":\"tok\",\"procStart\":1}".write(
            to: dir.appendingPathComponent("sessions/42.abcd.key"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PeerSocket.peerToken(pid: 42, claudeDir: dir), "tok")
        XCTAssertNil(PeerSocket.peerToken(pid: 43, claudeDir: dir))
        let data = PeerSocket.frames(text: "hello", token: "tok", from: "uds:/tmp/a.sock", messageId: "m1")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let auth = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["token"] as? String, "tok")
        let msg = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        XCTAssertEqual(msg["msgV"] as? Int, 1)
        XCTAssertEqual(msg["priority"] as? String, "next")
        XCTAssertEqual(msg["from"] as? String, "uds:/tmp/a.sock")
        let content = (msg["message"] as! [String: Any])["content"] as! String
        XCTAssertTrue(content.hasPrefix("<cross-session-message from=\"uds:/tmp/a.sock\""))
        XCTAssertTrue(content.hasSuffix("\nhello\n</cross-session-message>"))
        XCTAssertEqual(String(decoding: PeerSocket.frames(text: "x", token: nil, from: "a"), as: UTF8.self)
                        .split(separator: "\n").count, 1)
    }

    // MARK: hosts

    func testCmuxTreeParse() throws {
        let tree = """
        {"windows":[{"workspaces":[{"panes":[{"surfaces":[
          {"ref":"surface:1","type":"terminal","tty":"/dev/ttys009","title":"claude"},
          {"ref":"surface:2","type":"browser","title":"web"},
          {"ref":"surface:3","type":"terminal","title":"zsh"}]}]}]}]}
        """
        let host = CmuxHost(binary: "/x/cmux") { _, args in
            XCTAssertEqual(args, ["tree", "--all", "--json"]); return tree
        }
        let s = try host.surfaces()
        XCTAssertEqual(s, [PtySurface(ref: "surface:1", tty: "ttys009", title: "claude"),
                           PtySurface(ref: "surface:3", tty: nil, title: "zsh")])
    }

    func testCmuxKeys() throws {
        var calls: [[String]] = []
        let host = CmuxHost(binary: "/x/cmux") { _, args in calls.append(args); return "" }
        try host.sendLine("surface:1", "/rc")
        XCTAssertEqual(calls, [["send", "--surface", "surface:1", "--", "/rc"],
                               ["send-key", "--surface", "surface:1", "enter"]],
                       "Enter is a key event, never a CR inside the (bracketed-paste) text")
    }

    func testTmuxParseAndKeys() throws {
        var calls: [[String]] = []
        let host = TmuxHost(binary: "/x/tmux") { _, args in
            calls.append(args)
            return args.first == "list-panes" ? "%0\t66033\t/dev/ttys031\tzsh\n%1\t70000\t/dev/ttys040\t\n" : ""
        }
        XCTAssertEqual(try host.surfaces(), [
            PtySurface(ref: "%0", tty: "ttys031", title: "zsh", pids: [66033]),
            PtySurface(ref: "%1", tty: "ttys040", title: "", pids: [70000])])
        try host.sendLine("%0", "/rc")
        try host.sendEsc("%0")
        XCTAssertEqual(Array(calls.dropFirst()), [
            ["send-keys", "-t", "%0", "-l", "--", "/rc"], ["send-keys", "-t", "%0", "Enter"],
            ["send-keys", "-t", "%0", "Escape"]])
    }

    func testHerdrParseUsesProcessInfo() throws {
        let host = HerdrHost(binary: "/x/herdr") { _, args in
            if args == ["pane", "list"] {
                return #"{"result":{"panes":[{"pane_id":"w3:p1","agent":"claude","terminal_title":"claude"}]}}"#
            }
            XCTAssertEqual(args, ["pane", "process-info", "--pane", "w3:p1"])
            return #"{"result":{"process_info":{"foreground_process_group_id":46182,"foreground_processes":[{"pid":46182},{"pid":46190}]}}}"#
        }
        XCTAssertEqual(try host.surfaces(), [PtySurface(ref: "w3:p1", title: "claude", pids: [46182, 46182, 46190])])
    }

    func testSurfaceMatchTtyThenLineage() {
        let list = [PtySurface(ref: "a", tty: "ttys009"), PtySurface(ref: "b", tty: "ttys031", pids: [66033]),
                    PtySurface(ref: "c", pids: [46182])]
        XCTAssertEqual(list.surface(for: 1, tty: "ttys009", ancestors: [])?.ref, "a")
        // A Claude inside tmux sits on a nested pty; its shell ancestor is the pane pid.
        XCTAssertEqual(list.surface(for: 69188, tty: "ttys032", ancestors: [66040, 66033])?.ref, "b")
        XCTAssertEqual(list.surface(for: 46182, tty: nil, ancestors: [])?.ref, "c")
        XCTAssertNil(list.surface(for: 5, tty: "ttys099", ancestors: [4]))
    }

    func testSurfaceMatchFallsBackToTitleWhenTheHostExposesNoPids() {
        // cmux: no pids, tty usually null, the title is Claude Code's
        // status glyph + session name.
        let list = [PtySurface(ref: "surface:1", title: "~/death/peon-wave-16"),
                    PtySurface(ref: "surface:3", title: "◑ Infinitus2"),
                    PtySurface(ref: "w1:p1", tty: "ttys009", title: "✳ Infinitus", pids: [100])]
        XCTAssertEqual(list.surface(for: 39173, tty: "ttys031", ancestors: [], name: "Infinitus2")?.ref, "surface:3")
        XCTAssertNil(list.surface(for: 39173, tty: "ttys031", ancestors: [], name: "Infinitus"),
                     "exact name only, and never a surface with pids")
        XCTAssertNil(list.surface(for: 39173, tty: "ttys031", ancestors: [], name: nil))
    }

    // MARK: nudge state machine

    private func host(_ screens: [String]) -> FakeHost {
        FakeHost(surfaces: [PtySurface(ref: "s1", tty: "ttys009")], screens: screens)
    }

    private func nudge(_ h: FakeHost, text: String = "hello there") -> PtyNudge.Status {
        PtyNudge.nudge(host: h, pid: 7, text: text, tty: "ttys009", ancestors: [], sleep: { _ in })
    }

    func testRunningTurnIsLeftAlone() {
        let h = host(["Thinking… (esc to interrupt)"])
        XCTAssertEqual(nudge(h), .running)
        XCTAssertEqual(h.commands, ["read s1"])
    }

    func testIdlePromptGetsTyped() {
        let h = host(["> ", "> hello there"])
        XCTAssertEqual(nudge(h), .delivered)
        XCTAssertEqual(h.commands, ["read s1", "line s1 hello there", "read s1"])
    }

    func testMenuGetsExactlyOneEscThenTyped() {
        let h = host(["You've hit your limit\n  Wait for limit to reset\n  Adjust monthly spend limit", "> ", "> hello there"])
        XCTAssertEqual(nudge(h), .delivered)
        XCTAssertEqual(h.commands, ["read s1", "esc s1", "read s1", "line s1 hello there", "read s1"])
    }

    func testPersistentMenuIsCapturedInputWithOneEsc() {
        let h = host(["Usage credit balance: $0", "Usage  credit\nbalance: $0"])
        XCTAssertEqual(nudge(h), .capturedInput)
        XCTAssertEqual(h.commands.filter { $0.hasPrefix("esc") }.count, 1)
        XCTAssertFalse(h.commands.contains { $0.hasPrefix("line") })
    }

    func testRemoteControlPanelCountsAsCaptured() {
        let h = host(["Remote Control\nhttps://claude.ai/code/session_abc\nEsc to continue", "> ", "> hello there"])
        XCTAssertEqual(nudge(h), .delivered)
        XCTAssertEqual(h.commands.first { $0.hasPrefix("esc") }, "esc s1")
    }

    func testUnreadableScreenAfterTypingIsUnverified() {
        let h = host(["> "])
        h.screens = ["> "]
        let status = PtyNudge.nudge(host: h, pid: 7, text: "hello there", tty: "ttys009", ancestors: [],
                                    sleep: { _ in h.screens = [] })
        XCTAssertEqual(status, .typedUnverified)
    }

    func testNoSurface() {
        let h = host(["> "])
        XCTAssertEqual(PtyNudge.nudge(host: h, pid: 7, text: "x", tty: "ttys050", ancestors: [], sleep: { _ in }), .noSurface)
        XCTAssertEqual(h.commands, [])
    }

    // MARK: /rc sweep

    func testSweepSkipsSelfIdleAndUnhosted() {
        let h = FakeHost(surfaces: [PtySurface(ref: "a", tty: "ttys001"), PtySurface(ref: "b", tty: "ttys002"),
                                    PtySurface(ref: "c", tty: "ttys003")],
                         screens: ["Remote Control\nhttps://claude.ai/code/session_XYZ12\nEsc to continue"])
        let sessions = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/"),
                        ClaudeSessionRecord(pid: 2, sessionId: "s2", cwd: "/"),
                        ClaudeSessionRecord(pid: 3, sessionId: "s3", cwd: "/"),
                        ClaudeSessionRecord(pid: 4, sessionId: "s4", cwd: "/"),
                        ClaudeSessionRecord(pid: 5, sessionId: "s5", cwd: "/", kind: "bg")]
        let r = PtyNudge.rearmRemoteControl(
            hosts: [h], sessions: sessions, selfPids: [3], activeWithin: 600, confirm: true,
            ttyOfPid: { ["ttys001", "ttys002", "ttys003", "ttys004"][Int($0) - 1] },
            ancestorsOf: { _ in [] },
            idleSeconds: { $0 == "ttys002" ? 7200 : 10 },
            sleep: { _ in })
        XCTAssertEqual(r.sent, ["fake:a"])
        XCTAssertEqual(r.skippedSelf, 1)
        XCTAssertEqual(r.skippedIdle, 1)
        XCTAssertEqual(r.noSurface, 1)
        XCTAssertEqual(r.confirmed, ["fake:a"])
        XCTAssertEqual(r.urls, ["https://claude.ai/code/session_XYZ12"])
        XCTAssertEqual(h.commands, ["line a /rc", "read a", "esc a"])
    }

    // MARK: coordinator

    private func coordinator(hosts: [any PtyHost], socket: @escaping (StoppedSession, String) -> Bool,
                             verdicts: [Transcript.Verdict], sleeps: @escaping (TimeInterval) -> Void = { _ in })
        -> ResumeCoordinator {
        var c = ResumeCoordinator(hosts: hosts, claudeDir: dir)
        c.ttyOfPid = { _ in "ttys009" }
        c.ancestorsOf = { _ in [] }
        c.socketSend = socket
        var queue = verdicts
        c.verdict = { _ in queue.isEmpty ? .done : queue.removeFirst() }
        c.sleep = sleeps
        return c
    }

    func testSocketNudgeIsNeverAlsoTyped() {
        let h = host(["> ", "> [Infinitus] Your account hit its usage limit"])
        var sent: [String] = []
        let s = StoppedSession(sessionId: "s1", pid: 7, cwd: "/", socketPath: "/tmp/s.sock", peerProtocol: 1, stopUuid: "u1")
        let out = coordinator(hosts: [h], socket: { _, t in sent.append(t); return true }, verdicts: [.done]).resume([s])
        XCTAssertEqual(out.accepted, [s])
        XCTAssertEqual(out.channel["s1"], "socket")
        XCTAssertEqual(sent, [ResumeCoordinator.message])
        XCTAssertEqual(h.commands, [], "the terminal is never touched when the socket took the message")
    }

    func testTerminalFallbackWithoutAUsableSocket() {
        let h = host(["> ", "> [Infinitus] Your account hit its usage limit"])
        // No socket in the record → typed.
        let bare = StoppedSession(sessionId: "s1", pid: 7, cwd: "/", stopUuid: "u1")
        let out = coordinator(hosts: [h], socket: { _, _ in XCTFail("no socket"); return false }, verdicts: [.done]).resume([bare])
        XCTAssertEqual(out.channel["s1"], "fake")
        // Socket present but the send fails (stale path) → typed.
        let h2 = host(["> ", "> [Infinitus] Your account hit its usage limit"])
        let s = StoppedSession(sessionId: "s2", pid: 8, cwd: "/", socketPath: "/tmp/s.sock", peerProtocol: 1, stopUuid: "u2")
        let out2 = coordinator(hosts: [h2], socket: { _, _ in false }, verdicts: [.done]).resume([s])
        XCTAssertEqual(out2.channel["s2"], "fake")
        // Neither → unreachable, no retries.
        let none = FakeHost(surfaces: [], screens: [])
        let out3 = coordinator(hosts: [none], socket: { _, _ in XCTFail("no socket"); return false }, verdicts: []).resume([bare])
        XCTAssertEqual(out3.unreachable, [bare])
        XCTAssertTrue(out3.accepted.isEmpty)
    }

    func testBurnedNudgeRetriesWithDistinctTextAndRebaselines() {
        let h = FakeHost(surfaces: [], screens: [])
        var sent: [String] = []
        var slept: [TimeInterval] = []
        let s = StoppedSession(sessionId: "s1", pid: 7, cwd: "/", socketPath: "/tmp/s.sock", peerProtocol: 1, stopUuid: "u1")
        let c = coordinator(hosts: [h], socket: { session, t in sent.append("\(session.stopUuid)|\(t)"); return true },
                            verdicts: [.burned(newStopUuid: "u2"), .waiting, .waiting, .done],
                            sleeps: { slept.append($0) })
        let out = c.resume([s])
        XCTAssertEqual(out.accepted, [s])
        XCTAssertEqual(sent, ["u1|\(ResumeCoordinator.message)", "u2|\(ResumeCoordinator.message) (nudge 2)"])
        XCTAssertEqual(slept.filter { $0 == 5 }.count, 1)
        XCTAssertEqual(slept.filter { $0 == 15 }.count, 0)
    }

    func testWaitingIsNeverRetried() {
        let h = FakeHost(surfaces: [], screens: [])
        var count = 0
        let s = StoppedSession(sessionId: "s1", pid: 7, cwd: "/", socketPath: "/tmp/s.sock", peerProtocol: 1, stopUuid: "u1")
        let c = coordinator(hosts: [h], socket: { _, _ in count += 1; return true },
                            verdicts: Array(repeating: .waiting, count: 20))
        _ = c.resume([s])
        XCTAssertEqual(count, 1)
    }

    func testRunningTurnIsUnreachableThisRound() {
        let h = host(["esc to interrupt"])
        let s = StoppedSession(sessionId: "s1", pid: 7, cwd: "/", stopUuid: "u1")   // socketless: terminal path
        let out = coordinator(hosts: [h], socket: { _, _ in XCTFail("no socket"); return true }, verdicts: []).resume([s])
        XCTAssertEqual(out.unreachable, [s])
    }
}

/// The Darwin socket path end to end against a scratch listener — the
/// only channel for terminals without an injection API (Ghostty).
/// AF_UNIX listener + client: Windows has neither here (the daemon writes
/// PeerSocket.frames to a named pipe), so the whole suite stays Unix-only.
#if !os(Windows)
final class PeerSocketLoopbackTests: XCTestCase {
    func testSendDeliversAuthAndMessageFrames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"peerToken\":\"tok-77\"}".write(
            to: dir.appendingPathComponent("sessions/77.beef.key"), atomically: true, encoding: .utf8)
        // sun_path is 104 bytes; the temp dir is far longer.
        let path = "/tmp/inf-\(getpid())-\(UInt32.random(in: 0...9999)).sock"
        unlink(path)
        defer { unlink(path) }
        let server = socket(AF_UNIX, sysSockStream, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, 103) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sysBind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(server, 1), 0)

        let done = expectation(description: "sent")
        var ok = false
        DispatchQueue.global().async {
            ok = PeerSocket.send(socketPath: path, text: "wake up", pid: 77, claudeDir: dir, timeout: 3)
            done.fulfill()
        }
        let client = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        var received = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            received.append(contentsOf: buf[0..<n])
        }
        close(client)
        wait(for: [done], timeout: 5)
        XCTAssertTrue(ok)

        let lines = String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let auth = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(auth["token"] as? String, "tok-77")
        let msg = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        let content = (msg["message"] as! [String: Any])["content"] as! String
        XCTAssertEqual(content, PeerSocket.wrapBody("wake up", from: PeerSocket.ownAddress()))
        XCTAssertEqual(msg["priority"] as? String, "next")
        // A dead socket path fails fast and quietly.
        XCTAssertFalse(PeerSocket.send(socketPath: "/tmp/inf-nope.sock", text: "x", pid: 77, claudeDir: dir, timeout: 1))
    }
}
#endif
