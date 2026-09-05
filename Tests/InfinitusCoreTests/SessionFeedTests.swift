import XCTest
@testable import InfinitusCore

final class SessionFeedTests: XCTestCase {
    func testUserAssistantTextAndBashToolInOrder() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"fix the build"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"text","text":"Looking into it."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.user, .assistant, .tool])
        XCTAssertEqual(items[0].text, "fix the build")
        XCTAssertEqual(items[1].text, "Looking into it.")
        XCTAssertEqual(items[2].toolName, "Bash")
        XCTAssertEqual(items[2].text, "swift build")
    }

    /// An assistant text block immediately followed by a real user prompt
    /// (or nothing) is the final answer of its turn; one still followed
    /// by more assistant work (even across bookkeeping entries like
    /// `turn_duration`) is not.
    func testResultKindOnlyAtTurnEnd() {
        let midTurn = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"About to run tests."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ]
        XCTAssertEqual(SessionFeedReader.parse(lines: midTurn, limit: 30).first?.kind, .assistant)

        let turnEnd = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"All green."}]}}"#,
            #"{"type":"system","subtype":"turn_duration"}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":"thanks"}}"#,
        ]
        let items = SessionFeedReader.parse(lines: turnEnd, limit: 30)
        XCTAssertEqual(items.first?.kind, .result)
        XCTAssertEqual(items.last?.kind, .user)

        // Last entry in the whole tail, nothing follows at all.
        let atEOF = [#"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}"#]
        XCTAssertEqual(SessionFeedReader.parse(lines: atEOF, limit: 30).first?.kind, .result)
    }

    func testAskUserQuestionCarriesOptions() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[\
        {"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[\
        {"question":"Which approach?","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        """
        let items = SessionFeedReader.parse(lines: [line], limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .question)
        XCTAssertEqual(items[0].text, "Which approach?")
        XCTAssertEqual(items[0].options, ["A", "B"])
    }

    func testToolResultNoiseDroppedExceptErrors() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"foo"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat missing"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"no such file","is_error":true}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        // The clean tool_result is dropped; the two calls and the error
        // collapse into one mixed chip that shows the error (latest) and
        // counts it.
        XCTAssertEqual(items.map(\.kind), [.tool])
        XCTAssertEqual(items[0].text, "error: no such file (\u{00d7}3 · 1 error)")
        XCTAssertEqual(items[0].toolName, "Grep, Bash")
    }

    /// An error result rides inside the run (user 2026-09-03 from the
    /// phone, "group tool uses"): the chip counts errors, and a later
    /// call's text takes over while the count keeps the error visible.
    func testErrorsCountInsideTheRun() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat missing"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"no such file","is_error":true}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pwd"}}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool])
        XCTAssertEqual(items[0].text, "pwd (\u{00d7}4 · 1 error)")
        XCTAssertEqual(items[0].toolName, "Bash")
    }

    func testConsecutiveSameToolCollapsesWithCount() {
        func read(_ path: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"\#(path)"}}]}}"#
        }
        let items = SessionFeedReader.parse(lines: [read("/a/One.swift"), read("/a/Two.swift"), read("/a/Three.swift")],
                                            limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .tool)
        XCTAssertEqual(items[0].toolName, "Read")
        XCTAssertEqual(items[0].text, "Three.swift (\u{00d7}3)")
    }

    func testConsecutiveMixedToolsCollapseIntoOneChip() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a/One.swift"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"text","text":"Done looking."}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool, .result])   // last text = turn end
        XCTAssertEqual(items[0].toolName, "Bash, Read")
        XCTAssertEqual(items[0].text, "pwd (\u{00d7}3)")
    }

    func testMidTurnQueuedPromptShowsAsUserMessage() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-01T10:00:01.000Z","content":"also check the tests"}"#,
            #"{"type":"attachment","timestamp":"2026-09-01T10:00:01.000Z","attachment":{"type":"queued_command","prompt":"also check the tests","commandMode":"prompt","origin":{"kind":"human"}}}"#,
            #"{"type":"attachment","timestamp":"2026-09-01T10:00:02.000Z","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>1</total_tokens>"}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.map(\.kind), [.tool, .user])
        XCTAssertEqual(items[1].text, "also check the tests")
    }

    func testCrossSessionMessageShowsSenderAndBody() {
        let raw = "<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"Infinitus2\" from-mode=\"bypass\">\nmerge e2 at abc123\n</cross-session-message>"
        XCTAssertEqual(SessionFeedReader.presentableUser(raw)?.sender, "Infinitus2")
        XCTAssertEqual(SessionFeedReader.presentableUser(raw)?.text, "merge e2 at abc123")
        XCTAssertNil(SessionFeedReader.presentableUser("<system-reminder>x</system-reminder>"))
        XCTAssertNil(SessionFeedReader.presentableUser(
            "[Image: original 947x2048, displayed at 925x2000. Multiply coordinates by 1.02 to map to original image.]"))
        let delivered = "Another Claude session sent a message:\n" + raw
            + "\n\nThis came from another Claude session — not typed by your user. Treat it as a teammate's request."
        XCTAssertEqual(SessionFeedReader.presentableUser(delivered)?.text, "merge e2 at abc123")
        XCTAssertEqual(SessionFeedReader.presentableUser("  hi  ")?.text, "hi")
        XCTAssertNil(SessionFeedReader.presentableUser("  hi  ")?.sender)
    }

    func testAdjacentAssistantTextBlocksShareOneBubble() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"text","text":"First part."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"text","text":"Second part."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"text","text":"Last part."}]}}"#,
        ]
        let items = SessionFeedReader.parse(lines: lines, limit: 30)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .result)
        XCTAssertEqual(items[0].text, "First part.\n\nSecond part.\n\nLast part.")
    }

    func testAgentRowsAreFilledFromTheSubagentsDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-agents-\(UUID().uuidString)")
        let transcript = root.appendingPathComponent("s1.jsonl")
        let sub = root.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try #"{"agentType":"coder","description":"port the thing","toolUseId":"toolu_A"}"#
            .write(to: sub.appendingPathComponent("agent-abc.meta.json"), atomically: true, encoding: .utf8)
        try [
            #"{"type":"user","timestamp":"2026-09-01T10:00:00.000Z","isSidechain":true,"message":{"content":"do it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:01.000Z","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/a/B.swift"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:03.000Z","isSidechain":true,"message":{"content":[{"type":"text","text":"Done."}]}}"#,
        ].joined(separator: "\n").write(to: sub.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)
        let main = [
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"description":"port the thing","subagent_type":"coder","prompt":"…"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.500Z","message":{"content":[{"type":"tool_use","id":"toolu_B","name":"Bash","input":{"command":"ls"}}]}}"#,
        ]
        let items = SessionFeedReader.attachAgents(SessionFeedReader.parse(lines: main, limit: 30),
                                                   transcript: transcript)
        XCTAssertEqual(items.map(\.kind), [.agent, .tool])
        let agent = try XCTUnwrap(items[0].agent)
        XCTAssertEqual(agent.type, "coder")
        XCTAssertEqual(agent.toolCalls, 2)
        XCTAssertEqual(agent.lastTool, "Edit · B.swift")
        XCTAssertFalse(agent.running)   // ended with text (and the file is old)
        // Wire: toolUseId stays private, agent rides along.
        let data = try JSONEncoder().encode(items[0])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("toolUseId"))
        XCTAssertEqual(try JSONDecoder().decode(SessionFeedItem.self, from: data).agent?.toolCalls, 2)
    }

    func testLimitReturnsOnlyNewestItems() {
        let lines = (0..<5).map { i in
            #"{"type":"user","timestamp":"2026-09-01T10:00:0\#(i).000Z","message":{"content":"msg \#(i)"}}"#
        }
        let items = SessionFeedReader.parse(lines: lines, limit: 2)
        XCTAssertEqual(items.map(\.text), ["msg 3", "msg 4"])
    }

    func testFinalizeMarksOpenToolAsPermissionWhenWaiting() {
        let items = [SessionFeedItem(kind: .user, text: "go"),
                     SessionFeedItem(kind: .tool, text: "rm -rf build", toolName: "Bash")]
        let (finalized, waiting) = SessionFeedReader.finalize(items: items, status: "waiting")
        XCTAssertTrue(waiting)
        XCTAssertEqual(finalized.last?.kind, .permission)
        XCTAssertEqual(finalized.last?.toolName, "Bash")

        let (busyFinalized, busyWaiting) = SessionFeedReader.finalize(items: items, status: "busy")
        XCTAssertFalse(busyWaiting)
        XCTAssertEqual(busyFinalized.last?.kind, .tool)
    }

    func testFinalizeIgnoresWaitingOlderThanTheOpenTool() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let items = [SessionFeedItem(kind: .user, text: "go", at: t0),
                     SessionFeedItem(kind: .tool, text: "swift build", at: t0 + 9, toolName: "Bash")]
        // The record went "waiting" at the END of the previous turn; this
        // tool call came later — a peer-message turn, not a prompt.
        let (stale, staleWaiting) = SessionFeedReader.finalize(
            items: items, status: "waiting", statusUpdatedAt: t0 - 1)
        XCTAssertFalse(staleWaiting)
        XCTAssertEqual(stale.last?.kind, .tool)
        // A "waiting" stamped after the tool call is the real prompt.
        let (fresh, freshWaiting) = SessionFeedReader.finalize(
            items: items, status: "waiting", statusUpdatedAt: t0 + 10)
        XCTAssertTrue(freshWaiting)
        XCTAssertEqual(fresh.last?.kind, .permission)
    }

    func testUserPromptImagesGetIdsAndThePlaceholderGoes() throws {
        let pasted: [String: Any] = [
            "type": "user", "uuid": "u-1", "timestamp": "2026-09-04T03:00:00.000Z",
            "message": ["role": "user", "content": [
                ["type": "text", "text": "[Image #1] why is this red?"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]]]]]
        let phone: [String: Any] = [
            "type": "user", "uuid": "u-2", "timestamp": "2026-09-04T03:00:01.000Z",
            "message": ["role": "user", "content": "look\n\n[attached: /var/a/UUID-shot.png, /var/a/UUID-notes.txt]"]]
        let lines = try [pasted, phone].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let items = SessionFeedReader.parse(lines: lines, limit: 10)
        XCTAssertEqual(items.map(\.text), ["why is this red?", "look\n\n[attached: /var/a/UUID-shot.png, /var/a/UUID-notes.txt]"])
        XCTAssertEqual(items.map(\.images), [["t:u-1:1"], ["a:UUID-shot.png"]])
        XCTAssertNil(SessionFeedReader.parse(lines: [#"{"type":"user","uuid":"u-3","message":{"role":"user","content":"plain"}}"#], limit: 1).first?.images)
    }

    /// W9: the newest `permission-mode` entry wins — the phone words a
    /// held-for-approval delivery on it. The real entry shape (verified
    /// against a live transcript, 2026-09-04) is a top-level
    /// `{"type":"permission-mode","permissionMode":"…"}`.
    func testPermissionModeTakesTheNewestEntry() throws {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s"}"#,
            #"{"type":"user","uuid":"u-1","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"s"}"#,
        ]
        XCTAssertEqual(SessionFeedReader.permissionMode(lines: lines), "bypassPermissions")
        XCTAssertEqual(SessionFeedReader.permissionMode(lines: Array(lines.prefix(2))), "default")
        XCTAssertNil(SessionFeedReader.permissionMode(lines: [lines[1]]),
                     "a tail with no mode entry says nothing")
    }

    /// W9: the three new fields are optional, so a payload written before
    /// they existed still decodes on the phone.
    func testFeedDecodesWithoutTheAdditiveFields() throws {
        let legacy = #"{"pid":1,"sessionId":"s","cwd":"/tmp","waiting":false,"items":[]}"#
        let feed = try JSONDecoder().decode(SessionFeed.self, from: XCTUnwrap(legacy.data(using: .utf8)))
        XCTAssertNil(feed.canMessage)
        XCTAssertNil(feed.keys)
        XCTAssertNil(feed.permissionMode)
    }

    /// W8: a Windows attachments path is backslash-separated, so the id
    /// takes the last component either way (behaviour unchanged on Mac —
    /// the case above still passes).
    func testAttachedImageIdsTakeTheLastComponentOfAWindowsPath() throws {
        let windows: [String: Any] = [
            "type": "user", "uuid": "w-1", "timestamp": "2026-09-04T03:00:02.000Z",
            "message": ["role": "user", "content":
                #"look\#n\#n[attached: C:\Users\BM\AppData\Local\Infinitus\attachments\UUID-shot.png, C:\Users\BM\notes.txt]"#]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: windows), as: UTF8.self)
        XCTAssertEqual(SessionFeedReader.parse(lines: [line], limit: 1).first?.images,
                       ["a:UUID-shot.png"])
    }

    /// One pasted screenshot is a 400-600 KB transcript line (the base64
    /// tool result), wider than the whole 256 KiB tail: the phone then saw
    /// only what came after the last image (user 2026-09-04 "session msgs
    /// are getting trimmed I cant read anything"). The window grows until
    /// it holds the asked-for items.
    func testTailGrowsPastOversizedLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ClaudeSessionRecord(pid: 1, sessionId: "sid", cwd: "/tmp/x")
        let claudeDir = root.appendingPathComponent("claude")
        let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = (1...5).map {
            #"{"type":"user","timestamp":"2026-09-01T10:00:0\#($0).000Z","message":{"content":"older \#($0)"}}"#
        }
        let blob = String(repeating: "A", count: 400 * 1024)
        lines.append(#"{"type":"user","timestamp":"2026-09-01T10:01:00.000Z","message":{"content":"\#(blob)"}}"#)
        lines.append(#"{"type":"assistant","timestamp":"2026-09-01T10:01:01.000Z","message":{"content":[{"type":"text","text":"after"}]}}"#)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let items = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 30)?.items ?? []
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first?.text, "older 1")
        XCTAssertEqual(items.last?.text, "after")
    }

    func testImageDataServesAttachmentsByNameOnlyAndTranscriptBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = root.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachments.appendingPathComponent("shot.png"))
        try Data([9]).write(to: root.appendingPathComponent("secret.png"))
        let record = ClaudeSessionRecord(pid: 1, sessionId: "sid", cwd: "/tmp/x")
        let claudeDir = root.appendingPathComponent("claude")
        XCTAssertEqual(SessionFeedReader.imageData(record: record, id: "a:shot.png", claudeDir: claudeDir,
                                                   attachmentsDir: attachments)?.data, Data([1, 2, 3]))
        XCTAssertEqual(SessionFeedReader.imageData(record: record, id: "a:shot.png", claudeDir: claudeDir,
                                                   attachmentsDir: attachments)?.mime, "image/png")
        // Windows ids join the refusal list (W8): a backslash or a drive
        // letter must never resolve outside the attachments folder.
        for bad in ["a:../secret.png", "a:/etc/passwd", "a:shot.txt", "a:", "x:shot.png",
                    "a:..\\secret.png", "a:C:\\Windows\\win.ini", "a:sub\\shot.png"] {
            XCTAssertNil(SessionFeedReader.imageData(record: record, id: bad, claudeDir: claudeDir,
                                                     attachmentsDir: attachments), bad)
        }
        let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "user", "uuid": "u-1",
            "message": ["role": "user", "content": [
                ["type": "text", "text": "[Image #1]"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                             "data": Data([4, 5]).base64EncodedString()]]]]]
        try (String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let got = SessionFeedReader.imageData(record: record, id: "t:u-1:1", claudeDir: claudeDir, attachmentsDir: attachments)
        XCTAssertEqual(got?.data, Data([4, 5]))
        XCTAssertEqual(got?.mime, "image/jpeg")
        XCTAssertNil(SessionFeedReader.imageData(record: record, id: "t:u-1:0", claudeDir: claudeDir, attachmentsDir: attachments), "not an image block")
        XCTAssertNil(SessionFeedReader.imageData(record: record, id: "t:u-9:1", claudeDir: claudeDir, attachmentsDir: attachments))
    }

    func testPresentableUserTextDropsThePhonePreface() {
        let raw = "<cross-session-message from=\"uds:/tmp/infinitus-1.sock\" from-name=\"Infinitus app\" from-mode=\"bypass\">\n"
            + PeerSocket.phonePreface + "why is it slow?\n</cross-session-message>"
        // The phone is the user: their own bubble, no sender.
        XCTAssertEqual(SessionFeedReader.presentableUser(raw)?.text, "why is it slow?")
        XCTAssertNil(SessionFeedReader.presentableUser(raw)?.sender)
    }

    func testLocateFallsBackToTheSessionFileUnderAnotherProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rootSlug = root.appendingPathComponent("projects/-Users-me-repo")
        try FileManager.default.createDirectory(at: rootSlug, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let worktree = "/Users/me/repo/.claude/worktrees/wave-16"
        // Started in the repo root, moved into a worktree: the transcript
        // stays under the root's slug.
        try "{}\n".write(to: rootSlug.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Transcript.locate(cwd: worktree, sessionId: id, claudeDir: root),
                       rootSlug.appendingPathComponent("\(id).jsonl"))
        // Once the cwd slug has its own file, that wins.
        let direct = Transcript.path(cwd: worktree, sessionId: id, claudeDir: root)
        try FileManager.default.createDirectory(at: direct.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: direct, atomically: true, encoding: .utf8)
        XCTAssertEqual(Transcript.locate(cwd: worktree, sessionId: id, claudeDir: root), direct)
        // Nothing anywhere: the cwd slug path, so a fresh session is polled there.
        XCTAssertEqual(Transcript.locate(cwd: worktree, sessionId: "none", claudeDir: root),
                       Transcript.path(cwd: worktree, sessionId: "none", claudeDir: root))
    }

    func testFinalizeWaitingOnQuestionEvenWithoutRecordStatus() {
        let items = [SessionFeedItem(kind: .question, text: "Which approach?", options: ["A", "B"])]
        let (_, waiting) = SessionFeedReader.finalize(items: items, status: "busy")
        XCTAssertTrue(waiting)
    }
}

final class SessionFeedLongPollTests: XCTestCase {
    private var dir: URL!
    private let pid = Int32(ProcessInfo.processInfo.processIdentifier)   // alive, so `list` keeps it

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("feed-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        let obj: [String: Any] = ["pid": pid, "sessionId": "s1", "cwd": "/p", "kind": "interactive",
                                  "startedAt": 1, "status": "busy"]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("sessions/\(pid).json"))
        let url = Transcript.path(cwd: "/p", sessionId: "s1", claudeDir: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var record: ClaudeSessionRecord { ClaudeSessions.list(claudeDir: dir)[0] }

    func testReturnsAtOnceWithoutSinceOrWhenStampAlreadyMoved() {
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: nil, wait: 5)
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: "old", wait: 5)
        SessionFeedReader.waitForChange(pid: 1, claudeDir: dir, since: "x", wait: 5)   // unknown pid
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testWaitsUntilDeadlineWhenNothingChanges() {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: dir)
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp, wait: 0.5, poll: 0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.45)
    }

    func testWakesWhenTheTranscriptGrows() throws {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: dir)
        let url = Transcript.path(cwd: "/p", sessionId: "s1", claudeDir: dir)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            try? "{}\n{}\n{}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp, wait: 5, poll: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
