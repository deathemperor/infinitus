import XCTest
@testable import InfinitusCore

/// #17 layer 2: the phone sends a reply or a decision into a session.
/// `FakeHost` is `SessionResumeTests`' scripted multiplexer, reused here
/// unchanged.
final class SessionInputTests: XCTestCase {
    private func record(socket: String = "") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 7, sessionId: "s1", cwd: "/repo", messagingSocketPath: socket)
    }

    private func host(_ screens: [String]) -> FakeHost {
        FakeHost(surfaces: [PtySurface(ref: "s1", tty: "ttys009")], screens: screens)
    }

    private func deliver(_ request: SessionInput.Request, hosts: [any PtyHost],
                         socket: String = "", attachmentsDir: URL? = nil,
                         socketSend: @escaping (ClaudeSessionRecord, String) -> Bool = { _, _ in false }
    ) -> SessionInput.Reply {
        SessionInput.deliver(request: request, record: record(socket: socket), hosts: hosts,
                             claudeDir: FileManager.default.temporaryDirectory,
                             attachmentsDir: attachmentsDir ?? FileManager.default.temporaryDirectory
                                 .appendingPathComponent("infinitus-attachment-tests-\(UUID().uuidString)"),
                             ttyOfPid: { _ in "ttys009" }, ancestorsOf: { _ in [] },
                             socketSend: socketSend, sleep: { _ in })
    }

    private func tinyPNG() -> SessionInput.Attachment {
        SessionInput.Attachment(name: "photo.png", mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    }

    // MARK: key validation

    func testUnsupportedKeyIsRejectedWithoutTouchingAHost() {
        let h = host(["> "])
        let reply = deliver(.init(kind: .key, text: "zz"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "rejected", detail: "unsupported key"))
        XCTAssertEqual(h.commands, [])
    }

    func testKeyWhileRunningIsRunning() {
        let h = host(["Thinking… (esc to interrupt)"])
        let reply = deliver(.init(kind: .key, text: "1"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "running"))
    }

    func testKeyEnterSendsAnEmptyLine() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "enter"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "line s1 ", "read s1"])
    }

    func testKeyEscSendsEscape() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "esc"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "esc s1", "read s1"])
    }

    func testKeyDigitTypesTheDigit() {
        let h = host(["some menu"])
        let reply = deliver(.init(kind: .key, text: "1"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        XCTAssertEqual(h.commands, ["read s1", "line s1 1", "read s1"])
    }

    func testKeyWithNoSurfaceReportsNoSurface() {
        let reply = deliver(.init(kind: .key, text: "y"), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "noSurface"))
    }

    // MARK: message validation

    func testEmptyOrOverlongOrControlCharMessageIsRejected() {
        let h = host(["> "])
        XCTAssertEqual(deliver(.init(kind: .message, text: ""), hosts: [h]).outcome, "rejected")
        XCTAssertEqual(deliver(.init(kind: .message, text: String(repeating: "x", count: 4001)),
                               hosts: [h]).outcome, "rejected")
        XCTAssertEqual(deliver(.init(kind: .message, text: "hi\tthere"), hosts: [h]).outcome, "rejected")
        // A newline is fine.
        XCTAssertEqual(h.commands, [])
    }

    /// A Continue tap: the Mac's own text, socket first, then the terminal.
    func testResumeSendsTheContinueTextSocketFirst() {
        var sent: [String] = []
        let reply = deliver(.init(kind: .resume, text: "ignored"), hosts: [host(["> "])], socket: "/tmp/x.sock",
                            socketSend: { _, text in sent.append(text); return true })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].hasPrefix("[Infinitus] Continue where you left off"))
        XCTAssertFalse(sent[0].contains("ignored"))
        let h = host(["> "])
        XCTAssertEqual(deliver(.init(kind: .resume, text: ""), hosts: [h]).channel, "pty")
        XCTAssertTrue(h.commands.contains { $0.contains("Continue where you left off") })
    }

    func testMessageDeliveredViaPty() {
        let h = host(["> ", "> hi there"])
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [h])
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
    }

    func testMessageWithASocketIsNeverTyped() {
        let h = host(["> ", "> hi there"])
        let reply = deliver(.init(kind: .message, text: "hi\nthere"), hosts: [h],
                            socket: "/tmp/x.sock", socketSend: { _, text in text == PeerSocket.phonePreface + "hi\nthere" })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertEqual(h.commands, [], "line breaks kept, terminal untouched")
    }

    func testMessageGoesToSocketWhenNoSurface() {
        var sent: (ClaudeSessionRecord, String)?
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [],
                            socket: "/tmp/x.sock", socketSend: { record, text in
            sent = (record, text)
            return true
        })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertEqual(sent?.1, PeerSocket.phonePreface + "hi there")
    }

    func testMessageWhileRunningWithNoUsableSocketReportsRunning() {
        let running = host(["Thinking… (esc to interrupt)"])
        // Socket also unavailable: outcome reflects the pty's own state.
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [running],
                            socket: "/tmp/x.sock", socketSend: { _, _ in false })
        XCTAssertEqual(reply, .init(outcome: "running"))
    }

    func testMessageWhileRunningButSocketSucceedsIsStillDelivered() {
        let running = host(["Thinking… (esc to interrupt)"])
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [running],
                            socket: "/tmp/x.sock", socketSend: { _, _ in true })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
    }

    func testMessageWithNoSurfaceAndNoSocketPathIsNoChannel() {
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "noChannel"))
    }

    func testMessageWithNoSurfaceButUnsendableSocketIsNoSurface() {
        let reply = deliver(.init(kind: .message, text: "hi there"), hosts: [],
                            socket: "/tmp/x.sock", socketSend: { _, _ in false })
        XCTAssertEqual(reply, .init(outcome: "noSurface"))
    }

    // MARK: wire round-trip

    func testRequestAndReplyRoundTripJSON() throws {
        let request = SessionInput.Request(kind: .message, text: "yes please")
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(SessionInput.Request.self, from: requestData), request)

        let reply = SessionInput.Reply(outcome: "delivered", channel: "pty", detail: nil)
        let replyData = try JSONEncoder().encode(reply)
        XCTAssertEqual(try JSONDecoder().decode(SessionInput.Reply.self, from: replyData), reply)
    }

    /// An old client's JSON — no `attachments` key at all — must still
    /// decode, with `attachments == nil`.
    func testRequestWithoutAttachmentsKeyStillDecodes() throws {
        let data = Data(#"{"kind":"message","text":"hi"}"#.utf8)
        let request = try JSONDecoder().decode(SessionInput.Request.self, from: data)
        XCTAssertNil(request.attachments)
    }

    // MARK: attachments (2026-09-03 "add features to allow attachments")

    func testTooManyAttachmentsIsRejected() {
        let attachments = (0..<5).map { _ in tinyPNG() }
        let reply = deliver(.init(kind: .message, text: "hi", attachments: attachments), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "rejected", detail: "too many attachments"))
    }

    func testOversizedAttachmentIsRejected() {
        let big = SessionInput.Attachment(name: "big.png", mime: "image/png",
                                          data: Data(count: SessionInput.maxAttachmentBytes + 1))
        let reply = deliver(.init(kind: .message, text: "hi", attachments: [big]), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "rejected", detail: "attachment too large"))
    }

    func testUnsupportedMimeIsRejected() {
        let exe = SessionInput.Attachment(name: "a.exe", mime: "application/x-msdownload",
                                          data: Data([0]))
        let reply = deliver(.init(kind: .message, text: "hi", attachments: [exe]), hosts: [])
        XCTAssertEqual(reply, .init(outcome: "rejected", detail: "unsupported attachment type"))
    }

    func testAttachmentValidationRunsBeforeTouchingAHost() {
        let h = host(["> "])
        _ = deliver(.init(kind: .message, text: "hi", attachments: (0..<5).map { _ in tinyPNG() }),
                    hosts: [h])
        XCTAssertEqual(h.commands, [])
    }

    func testAttachmentLandsOnDiskWithASanitizedNameAndDeliveredTextListsItsPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-attachment-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let attachment = SessionInput.Attachment(name: "my photo!.png", mime: "image/png",
                                                 data: Data([1, 2, 3]))
        let h = host(["> ", "> typed"])
        let reply = deliver(.init(kind: .message, text: "look", attachments: [attachment]),
                            hosts: [h], attachmentsDir: dir)
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "pty"))
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(written.count, 1)
        let name = try XCTUnwrap(written.first)
        XCTAssertTrue(name.hasSuffix("-myphoto.png"), name)
        XCTAssertFalse(name.contains("!"), name)
        XCTAssertFalse(name.contains(" "), name)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), attachment.data)
        let typedLine = h.commands.first { $0.hasPrefix("line s1 ") }
        XCTAssertTrue(typedLine?.contains(dir.appendingPathComponent(name).path) ?? false,
                     typedLine ?? "<nil>")
    }

    func testAttachmentsOnlyMessageGetsAPlaceholderText() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-attachment-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var sent: String?
        let reply = deliver(.init(kind: .message, text: "", attachments: [tinyPNG()]),
                            hosts: [], socket: "/tmp/x.sock", attachmentsDir: dir,
                            socketSend: { _, text in sent = text; return true })
        XCTAssertEqual(reply, .init(outcome: "delivered", channel: "socket"))
        XCTAssertTrue(sent?.hasPrefix(PeerSocket.phonePreface + "Please look at the attached file(s):") ?? false, sent ?? "<nil>")
        XCTAssertTrue(sent?.contains("[attached:") ?? false, sent ?? "<nil>")
    }

    func testEmptyTextAndNoAttachmentsIsStillRejected() {
        let reply = deliver(.init(kind: .message, text: ""), hosts: [host(["> "])])
        XCTAssertEqual(reply.outcome, "rejected")
    }

    func testSessionStartShellCommandQuotesEverything() {
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/Users/x/my repo", engine: nil, prompt: nil),
                       "cd '/Users/x/my repo' && exec claude")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: "codex", prompt: "fix it's bug"),
                       "cd '/r' && exec codex 'fix it'\\''s bug'")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: "claude", prompt: "   "),
                       "cd '/r' && exec claude")
    }

    func testSessionStartResumeNamesTheSessionForClaudeOnly() throws {
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: nil, prompt: nil, resume: "abc-1"),
                       "cd '/r' && exec claude --resume 'abc-1'")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: "claude", prompt: "go on", resume: "abc-1"),
                       "cd '/r' && exec claude --resume 'abc-1' 'go on'")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: "codex", prompt: nil, resume: "abc-1"),
                       "cd '/r' && exec codex")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: nil, prompt: "go", permissionMode: "acceptEdits"),
                       "cd '/r' && exec claude --permission-mode acceptEdits 'go'")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: nil, prompt: nil, resume: "abc-1", permissionMode: "bypassPermissions"),
                       "cd '/r' && exec claude --resume 'abc-1' --permission-mode bypassPermissions")
        // Unknown modes never reach the command line; Codex has no such flag.
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: nil, prompt: nil, permissionMode: "yolo; rm -rf /"),
                       "cd '/r' && exec claude")
        XCTAssertEqual(SessionStart.shellCommand(cwd: "/r", engine: "codex", prompt: nil, permissionMode: "auto"),
                       "cd '/r' && exec codex")
        // A phone from before resume existed sends no such field.
        let old = try JSONDecoder().decode(SessionStart.Request.self, from: Data(#"{"cwd":"/r"}"#.utf8))
        XCTAssertEqual(old, SessionStart.Request(cwd: "/r"))
        XCTAssertNil(old.resume)
    }
}
