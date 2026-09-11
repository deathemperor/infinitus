import XCTest
@testable import InfinitusCore

final class SessionFeedTests: XCTestCase {
    func testUnknownKindDecodesAsOtherInsteadOfFailingTheChunk() throws {
        let json = #"[{"kind":"user","text":"hi"},{"kind":"held-from-the-future","text":"later"}]"#
        let items = try JSONDecoder().decode([SessionFeedItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.map(\.kind), [.user, .other])
        XCTAssertEqual(items[1].text, "later")
        let round = try JSONDecoder().decode([SessionFeedItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(round.map(\.kind), [.user, .other])
    }

    func testHeldPeerMessageBecomesAMarker() {
        let held = #"{"type":"system","subtype":"informational","level":"warning","timestamp":"2026-09-06T10:00:00.000Z","content":"Held peer message — from uds:/tmp/infinitus-123.sock (peer claims name: Infinitus app); preview: «Infinitus The user sent this from their phone» — not delivered to Claude (1 held). The sending session's permission mode class doesn't match this session's, so it wasn't delivered automatically."}"#
        let other = #"{"type":"system","subtype":"informational","level":"warning","content":"Held peer message — from uds:/tmp/cc-socks/55.sock — not delivered to Claude (1 held). Your \"crossSessionInbound\" setting is \"hold\"."}"#
        let noise = #"{"type":"system","subtype":"informational","level":"info","content":"Released 1 held cross-session message to Claude's queue."}"#
        let items = SessionFeedReader.parse(lines: [held, other, noise], limit: 30)
        XCTAssertEqual(items.map(\.kind), [.held])
        XCTAssertTrue(items[0].text.hasPrefix("Claude Code held this message from Infinitus"))
        XCTAssertNotNil(items[0].at)
    }

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

        // The meta is written once when the agent spawns; a second read
        // is the cache (#346) — a rewrite the app would never see keeps
        // the remembered description, while the log is re-tailed.
        let meta = sub.appendingPathComponent("agent-abc.meta.json")
        try #"{"toolUseId":"toolu_A","agentType":"coder","description":"renamed"}"#.write(to: meta, atomically: true, encoding: .utf8)
        let again = SessionFeedReader.attachAgents(SessionFeedReader.parse(lines: main, limit: 30), transcript: transcript)
        XCTAssertEqual(again[0].agent?.description, agent.description)
        let held = SessionFeedReader.metas.count
        XCTAssertGreaterThan(held, 0)
        try FileManager.default.removeItem(at: meta)
        _ = SessionFeedReader.attachAgents(SessionFeedReader.parse(lines: main, limit: 30), transcript: transcript)
        XCTAssertEqual(SessionFeedReader.metas.count, held - 1, "a gone meta file leaves the cache")
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

    /// The incremental read (#346) yields what the full read does — before
    /// and after the transcript grows — and its held tail sits at the end
    /// of the file afterwards. Fixture lines are newline-terminated, as
    /// Claude Code writes them: the tail waits for a line's newline.
    func testIncrementalReadMatchesFullReadAcrossAppends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-inc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ClaudeSessionRecord(pid: 1, sessionId: "sid", cwd: "/tmp/x")
        let claudeDir = root.appendingPathComponent("claude")
        let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func line(_ n: Int) -> String {
            n % 2 == 1
                ? #"{"type":"user","uuid":"u\#(n)","timestamp":"2026-09-01T10:00:\#(String(format: "%02d", n)).000Z","message":{"content":"ask \#(n)"}}"#
                : #"{"type":"assistant","uuid":"a\#(n)","timestamp":"2026-09-01T10:00:\#(String(format: "%02d", n)).000Z","message":{"content":[{"type":"text","text":"answer \#(n)"}]}}"#
        }
        try ((1...6).map(line).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail: SessionTail?
        let full = SessionFeedReader.read(record: record, claudeDir: claudeDir)
        let inc = SessionFeedReader.read(record: record, claudeDir: claudeDir, tail: &tail)
        XCTAssertEqual(inc?.items.map(\.text), full?.items.map(\.text))
        XCTAssertEqual(inc?.timeline, full?.timeline)
        XCTAssertEqual(inc?.items.last?.text, "answer 6")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(((7...8).map(line).joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let full2 = SessionFeedReader.read(record: record, claudeDir: claudeDir)
        let inc2 = SessionFeedReader.read(record: record, claudeDir: claudeDir, tail: &tail)
        XCTAssertEqual(inc2?.items.map(\.text), full2?.items.map(\.text))
        XCTAssertEqual(inc2?.timeline, full2?.timeline)
        XCTAssertEqual(inc2?.items.last?.text, "answer 8")
        XCTAssertEqual(inc2?.timeline?.turns.map(\.id), ["u1", "u3", "u5", "u7"])
        let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? UInt64
        XCTAssertEqual(tail?.offset, size)
        XCTAssertEqual(tail?.maxBytes, SessionFeedReader.tailBytes, "a small transcript never widens")

        // Proof the held window is reused: a byte range the tail already
        // consumed is rewritten in place (same length), then more lines
        // land. The full read sees the rewrite; the incremental one
        // decodes only the appended bytes and keeps what it held.
        var bytes = try Data(contentsOf: url)
        let marker = Data("ask 1\"".utf8)
        let hit = try XCTUnwrap(bytes.range(of: marker))
        bytes.replaceSubrange(hit, with: Data("ask 9\"".utf8))
        try bytes.write(to: url)
        let tweak = try FileHandle(forWritingTo: url)
        try tweak.seekToEnd()
        try tweak.write(contentsOf: Data(((9...10).map(line).joined(separator: "\n") + "\n").utf8))
        try tweak.close()
        let full3 = SessionFeedReader.read(record: record, claudeDir: claudeDir)
        let inc3 = SessionFeedReader.read(record: record, claudeDir: claudeDir, tail: &tail)
        XCTAssertEqual(full3?.items.first?.text, "ask 9")
        XCTAssertEqual(inc3?.items.first?.text, "ask 1", "only the appended bytes were decoded")
        XCTAssertEqual(inc3?.items.last?.text, "answer 10")
        XCTAssertEqual(inc3?.items.dropFirst().map(\.text), full3?.items.dropFirst().map(\.text))
    }

    /// The incremental read grows its window past an oversized line the
    /// way the full read does, and keeps the grown window.
    func testIncrementalReadGrowsPastOversizedLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-inc-big-\(UUID().uuidString)")
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
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail: SessionTail?
        let items = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 30, tail: &tail)?.items ?? []
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first?.text, "older 1")
        XCTAssertEqual(items.last?.text, "after")
        XCTAssertGreaterThan(tail?.maxBytes ?? 0, SessionFeedReader.tailBytes)
        let again = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 30, tail: &tail)?.items ?? []
        XCTAssertEqual(again.map(\.text), items.map(\.text), "the grown window is kept")
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
        for bad in ["a:../secret.png", "a:/etc/passwd", "a:shot.txt", "a:", "x:shot.png"] {
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

    /// A stopped store's loop ends the wait on the next slice, not at the
    /// deadline (#399).
    func testCancellationEndsTheWaitOnTheNextSlice() {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: dir)
        let mark = Mark()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { mark.value = "cancel" }
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp, wait: 5, poll: 0.05,
                                        isCancelled: { mark.value == "cancel" })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testWaitsUntilDeadlineWhenNothingChanges() {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: dir)
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp, wait: 0.5, poll: 0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.45)
    }

    /// An owned session's parked prompt lives in memory (#151): the
    /// decorated stamp makes it a change, and the actor's broadcast ends
    /// the wait at once instead of on the next poll.
    func testDecoratedStateCountsAsAChangeAndAWakeCutsThePollShort() {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: dir)!
        let wake = NSCondition()
        let mark = Mark()
        let start = Date()
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp, wait: 5, poll: 5,
                                        decorate: { $0 + "+a" }, wake: wake)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "a prompt parked since the client's stamp: no wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            mark.value = "+b"
            wake.lock(); wake.broadcast(); wake.unlock()
        }
        SessionFeedReader.waitForChange(pid: pid, claudeDir: dir, since: stamp + "+a", wait: 5, poll: 5,
                                        decorate: { $0 + mark.value }, wake: wake)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "woken well before the 5 s poll")
    }

    private final class Mark: @unchecked Sendable {
        private let lock = NSLock()
        private var v = "+a"
        var value: String {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
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
