import XCTest
@testable import InfinitusCore

/// The T3-shaped timeline built from a transcript (#223 phase 1).
final class SessionTimelineTests: XCTestCase {
    /// Decoded lines of `Fixtures/timeline/<name>.jsonl`.
    func entries(_ name: String) throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "Fixtures/timeline/\(name)", withExtension: "jsonl")!
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { SessionFeedReader.decodeLine(String($0)) }
    }
    func lines(_ raw: [String]) -> [[String: Any]] { raw.compactMap(SessionFeedReader.decodeLine) }
    func build(_ e: [[String: Any]], status: String? = "idle", statusUpdatedAt: Date? = nil,
               agents: [String: SessionFeedItem.Agent] = [:]) -> SessionTimeline {
        SessionTimelineBuilder.build(entries: e, status: status, statusUpdatedAt: statusUpdatedAt, agents: agents)
    }

    // MARK: Task 1 — types
    func testTimelineRoundTripsAndKeepsAnUnknownKind() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = SessionTimeline.Activity(id: "x:0", tone: .info, kind: "future.kind", summary: "later", detail: nil,
                         payload: ["n": .number(1)], turnId: "u1", sequence: 0, createdAt: t0)
        let m = SessionTimeline.Message(id: "u1", role: .user, text: "hi", images: nil, sender: nil, turnId: "u1", streaming: false, createdAt: t0)
        let turn = SessionTimeline.Turn(id: "u1", state: .completed, requestedAt: t0, startedAt: nil, completedAt: t0,
                        userMessageId: "u1", assistantMessageId: nil)
        let tl = SessionTimeline(turns: [turn], messages: [m], activities: [a])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SessionTimeline.self, from: try enc.encode(tl))
        XCTAssertEqual(back, tl)
        XCTAssertEqual(back.activities.first?.kind, "future.kind")
        XCTAssertEqual(back.activity(id: "x:0")?.summary, "later")
        XCTAssertEqual(back.message(id: "u1")?.text, "hi")
        XCTAssertEqual(back.turn(id: "u1")?.state, .completed)
        XCTAssertEqual(back.latestTurn?.id, "u1")
    }

    func testEmptyTimelineDecodesFromMissingFields() throws {
        let tl = try JSONDecoder().decode(SessionTimeline.self, from: Data("{}".utf8))
        XCTAssertTrue(tl.turns.isEmpty && tl.messages.isEmpty && tl.activities.isEmpty)
        XCTAssertNil(tl.latestTurn)
    }

    // MARK: Task 2 — turns and messages
    func testPlainTranscriptGivesTwoTurnsAndMergedAssistantText() throws {
        let tl = build(try entries("plain"))
        XCTAssertEqual(tl.turns.map(\.id), ["u1", "u2"])
        XCTAssertEqual(tl.messages.map(\.id), ["u1", "a1", "u2", "a3"])
        XCTAssertEqual(tl.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(tl.message(id: "a1")?.text, "Looking into it.\n\nFound it.")
        XCTAssertEqual(tl.message(id: "a1")?.turnId, "u1")
        XCTAssertEqual(tl.turn(id: "u1")?.assistantMessageId, "a1")
        XCTAssertEqual(tl.turn(id: "u1")?.startedAt, UsageHistory.parseISO("2026-09-01T10:00:01.000Z"))
        XCTAssertEqual(tl.turn(id: "u1")?.completedAt, UsageHistory.parseISO("2026-09-01T10:00:03.000Z"))
        XCTAssertEqual(tl.turn(id: "u1")?.state, .completed)
        XCTAssertEqual(tl.turn(id: "u2")?.state, .completed)   // record idle ⇒ completed (T3 projector.ts:78-93)
        XCTAssertTrue(tl.activities.isEmpty)
    }

    func testBusyRecordMakesTheLastTurnRunningAndItsAnswerStreaming() throws {
        let tl = build(try entries("plain"), status: "busy")
        XCTAssertEqual(tl.turn(id: "u1")?.state, .completed)
        XCTAssertEqual(tl.turn(id: "u2")?.state, .running)
        XCTAssertNil(tl.turn(id: "u2")?.completedAt)
        XCTAssertEqual(tl.messages.filter(\.streaming).map(\.id), ["a3"])
    }

    func testIdsAreStableAcrossBuilds() throws {
        let e = try entries("plain")
        XCTAssertEqual(build(e), build(e))
        XCTAssertFalse(build(e).turns.isEmpty)
    }

    func testSidechainAndMachineryEntriesAreSkipped() {
        let tl = build(lines([
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"go"}}"#,
            #"{"type":"user","uuid":"side","isSidechain":true,"timestamp":"2026-09-01T10:00:01.000Z","message":{"content":"sub-agent prompt"}}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":"<system-reminder>noise</system-reminder>"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-01T10:00:03.000Z","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"ok"}]}}"#,
        ]))
        XCTAssertEqual(tl.messages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(tl.message(id: "a1")?.text, "ok")
    }

    func testAQueuedCommandAttachmentIsAUserMessageAndOpensATurn() {
        let tl = build(lines([
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"first"}}"#,
            #"{"type":"attachment","uuid":"q1","timestamp":"2026-09-01T10:00:05.000Z","attachment":{"type":"queued_command","prompt":"and this too"}}"#,
        ]), status: "busy")
        XCTAssertEqual(tl.turns.map(\.id), ["u1", "q1"])
        XCTAssertEqual(tl.message(id: "q1")?.text, "and this too")
    }

    // MARK: Task 3 — tools
    func testToolLifecycleRowsPairByToolUseId() throws {
        let tl = build(try entries("tools"))
        XCTAssertEqual(tl.activities.map(\.kind),
                       ["tool.started", "tool.completed", "tool.started", "tool.completed", "tool.started", "tool.completed"])
        XCTAssertEqual(tl.activities.map(\.id), ["t1", "t1/completed", "t2", "t2/completed", "t3", "t3/completed"])
        XCTAssertEqual(tl.activities.map(\.sequence), [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(tl.activities.allSatisfy { $0.turnId == "u1" })
        let started = tl.activity(id: "t1")!
        XCTAssertEqual(started.tone, .tool)
        XCTAssertEqual(started.summary, "swift test")
        XCTAssertEqual(started.payload["toolName"], .string("Bash"))
        XCTAssertEqual(started.payload["itemType"], .string("command_execution"))
        let done = tl.activity(id: "t1/completed")!
        XCTAssertEqual(done.payload["status"], .string("completed"))
        XCTAssertEqual(done.payload["output"], .string("Test Suite 'All tests' passed"))
        XCTAssertEqual(done.detail, "Test Suite 'All tests' passed")
    }

    func testAFailedToolIsAnErrorRowAndAnEditListsItsFile() throws {
        let tl = build(try entries("tools"))
        let failed = tl.activity(id: "t3/completed")!
        XCTAssertEqual(failed.tone, .error)
        XCTAssertEqual(failed.payload["status"], .string("failed"))
        XCTAssertEqual(failed.detail, "fatal: could not read from remote")
        let edit = tl.activity(id: "t2/completed")!
        XCTAssertEqual(tl.activity(id: "t2")?.payload["itemType"], .string("file_change"))
        XCTAssertEqual(edit.payload["changedFiles"], .array([.string("Deep/Nested/Path/File.swift")]))
        // the message after the tools closes the turn
        XCTAssertEqual(tl.turn(id: "u1")?.assistantMessageId, "a4")
    }

    func testSlimmingRules() {
        XCTAssertEqual(SessionTimelineBuilder.Slim.output("\n\n  first line here \nsecond\n"), "first line here")
        XCTAssertEqual(SessionTimelineBuilder.Slim.output(String(repeating: "x", count: 100) + "\ny\nz"), "3 lines")
        XCTAssertEqual(SessionTimelineBuilder.Slim.output(""), "")
        XCTAssertEqual(SessionTimelineBuilder.Slim.files(["/a/b/c/d/e/f.swift", "/x.swift"]), ["c/d/e/f.swift", "x.swift"])
        XCTAssertEqual(SessionTimelineBuilder.Slim.files((0..<20).map { "/f\($0)" }).count, 12)
        XCTAssertEqual(SessionTimelineBuilder.Slim.detail(String(repeating: "d", count: 300)).count, 180)
        // a detail that only echoes the command is dropped
        XCTAssertNil(SessionTimelineBuilder.Slim.outputDetail("git push", command: "git push"))
        XCTAssertEqual(SessionTimelineBuilder.Slim.itemType(for: "Read"), "file_read")
        XCTAssertEqual(SessionTimelineBuilder.Slim.itemType(for: "Grep"), "search")
        XCTAssertEqual(SessionTimelineBuilder.Slim.itemType(for: "mcp__x__y"), "dynamic_tool_call")
    }

    // MARK: Task 4 — prompts and turn states
    func testInterruptMarkerClosesTheTurnInterruptedAndIsNotAMessage() throws {
        let tl = build(try entries("interrupted"))
        XCTAssertEqual(tl.turn(id: "u1")?.state, .interrupted)
        XCTAssertNil(tl.message(id: "i1"))
        XCTAssertEqual(tl.turn(id: "u1")?.completedAt, UsageHistory.parseISO("2026-09-01T10:00:05.000Z"))
    }

    func testAnApiErrorEndsTheTurnInErrorWithARuntimeErrorRow() throws {
        let tl = build(try entries("interrupted"), status: "idle")
        XCTAssertEqual(tl.turn(id: "u2")?.state, .error)
        let err = tl.activities.last!
        XCTAssertEqual(err.kind, "runtime.error")
        XCTAssertEqual(err.tone, .error)
        XCTAssertEqual(err.summary, "API Error: 500 Internal server error")
        XCTAssertEqual(err.payload["status"], .number(500))
        XCTAssertNil(tl.message(id: "a2"))   // the synthetic text is the error row, not an answer
    }

    func testWaitingRecordTurnsTheTrailingToolIntoAnApprovalRequest() {
        let e = lines([
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"write it"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/p/hello.txt","content":"hi"}}]}}"#,
        ])
        let tl = build(e, status: "waiting")
        XCTAssertEqual(tl.activities.map(\.kind), ["tool.started", "approval.requested"])
        let ask = tl.activity(id: "perm:t1")!
        XCTAssertEqual(ask.tone, .approval)
        XCTAssertEqual(ask.payload["requestId"], .string("perm:t1"))
        XCTAssertEqual(ask.payload["toolName"], .string("Write"))
        XCTAssertEqual(ask.payload["requestType"], .string("file_change_approval"))
        XCTAssertEqual(ask.payload["input"], .object(["file_path": .string("/p/hello.txt"), "content": .string("hi")]))
        XCTAssertEqual(tl.turn(id: "u1")?.state, .running)
        // a "waiting" older than the newest entry is stale (2026-09-04 bypass-permissions case)
        let stale = build(e, status: "waiting", statusUpdatedAt: UsageHistory.parseISO("2026-09-01T09:00:00.000Z"))
        XCTAssertEqual(stale.activities.map(\.kind), ["tool.started"])
        XCTAssertEqual(stale.turn(id: "u1")?.state, .completed)
    }

    func testAskUserQuestionIsAUserInputRequestResolvedByItsResult() {
        let tl = build(lines([
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"pick"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}]}]}}]}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-09-01T10:00:20.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"User has answered your questions: \"Which colour?\"=\"Blue\". You can now continue with these answers in mind."}]}}"#,
        ]), status: "busy")
        XCTAssertEqual(tl.activities.map(\.kind), ["user-input.requested", "user-input.resolved"])
        let ask = tl.activity(id: "perm:q1")!
        XCTAssertEqual(ask.summary, "Which colour?")
        XCTAssertEqual(ask.payload["questions"], .array([.object([
            "id": .string("Which colour?"), "header": .string("Colour"), "question": .string("Which colour?"),
            "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("Red"), "description": .string("warm")]),
                               .object(["label": .string("Blue"), "description": .string("cool")])]),
        ])]))
        XCTAssertEqual(tl.activity(id: "perm:q1/resolved")?.payload["answers"]?.stringValue?.contains("Blue"), true)
    }

    // MARK: Task 5 — agents, plans, warnings, compaction
    func testLimitStopIsARuntimeWarningNotAnError() throws {
        let tl = build(try entries("limit"))
        XCTAssertEqual(tl.activities.map(\.kind), ["runtime.warning"])
        XCTAssertEqual(tl.activities[0].payload["code"], .string("limit"))
        XCTAssertEqual(tl.activities[0].summary, Transcript.limitText(try entries("limit")[1]))
        XCTAssertEqual(tl.turn(id: "u1")?.state, .completed)
    }

    func testHeldPeerMessageIsAWarningAndAPeerPromptCarriesItsSender() throws {
        let tl = build(try entries("peer"))
        XCTAssertEqual(tl.message(id: "u1")?.sender, "Infi3")
        XCTAssertEqual(tl.message(id: "u1")?.text, "merged #277")
        XCTAssertEqual(tl.activities.map(\.kind), ["runtime.warning"])
        XCTAssertEqual(tl.activities[0].payload["code"], .string("held"))
        XCTAssertTrue(tl.activities[0].summary.hasPrefix("Claude Code held this message"))
    }

    func testCompactBoundaryIsAnActivityAndTheSummaryPromptIsNotAMessage() throws {
        let tl = build(try entries("compact"))
        XCTAssertEqual(tl.activities.map(\.kind), ["context-compaction"])
        XCTAssertEqual(tl.activities[0].payload["beforeTokens"], .number(468265))
        XCTAssertEqual(tl.activities[0].payload["afterTokens"], .number(12384))
        XCTAssertEqual(tl.messages.map(\.id), ["u1"])
        XCTAssertEqual(tl.turns.map(\.id), ["u1"])
    }

    func testTodoWriteIsAPlanUpdateNotATool() throws {
        let tl = build(try entries("todo"))
        XCTAssertEqual(tl.activities.map(\.kind), ["turn.plan.updated"])
        let plan = tl.activities[0]
        XCTAssertEqual(plan.id, "td1")
        XCTAssertEqual(plan.summary, "1 of 3 steps")
        XCTAssertEqual(plan.payload["completed"], .number(1))
        XCTAssertEqual(plan.payload["total"], .number(3))
        XCTAssertEqual(plan.payload["steps"], .array([
            .object(["text": .string("Write tests"), "status": .string("completed")]),
            .object(["text": .string("Implement"), "status": .string("in_progress")]),
            .object(["text": .string("Commit"), "status": .string("pending")]),
        ]))
    }

    func testAgentSpawnIsATaskWithTheSubagentSummaryAttached() throws {
        let agent = SessionFeedItem.Agent(id: "abc", type: "Explore", description: "Map session feed rendering",
                                          toolCalls: 46, lastTool: "Read · SessionFeed.swift", running: false,
                                          lastActivityAt: nil)
        let tl = build(try entries("agent"), agents: ["ag1": agent])
        XCTAssertEqual(tl.activities.map(\.kind), ["task.started", "task.completed"])
        XCTAssertEqual(tl.activities.map(\.id), ["task:ag1", "task:ag1/completed"])
        XCTAssertEqual(tl.activities[0].summary, "Map session feed rendering")
        XCTAssertEqual(tl.activities[0].payload["agentType"], .string("Explore"))
        XCTAssertEqual(tl.activities[0].payload["toolCalls"], .number(46))
        XCTAssertEqual(tl.activities[1].payload["running"], .bool(false))
        XCTAssertEqual(tl.activities[1].summary, "Map session feed rendering")
        // without a summary the row still exists
        XCTAssertEqual(build(try entries("agent")).activities[0].payload["agentType"], .string("Explore"))
    }

    // MARK: Task 6 — owned prompts
    func testOwnedPendingRequestsBecomeApprovalAndUserInputRows() throws {
        let base = build(try entries("plain"), status: "busy")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let write = PendingRequest(requestId: "r1", toolName: "Write", toolUseId: "tu1", description: "hello.txt",
                                   inputJSON: #"{"file_path":"/p/hello.txt","content":"hi"}"#, suggestionsJSON: nil,
                                   questions: [], receivedAt: t0)
        let ask = PendingRequest(requestId: "r2", toolName: "AskUserQuestion", toolUseId: "tu2", description: nil,
                                 inputJSON: "{}", suggestionsJSON: nil,
                                 questions: [.init(question: "Which colour?", header: "Colour", options: ["Red", "Blue"], multiSelect: false)],
                                 receivedAt: t0)
        let tl = base.appending(pending: [write, ask])
        XCTAssertEqual(tl.activities.suffix(2).map(\.kind), ["approval.requested", "user-input.requested"])
        XCTAssertEqual(tl.activities.suffix(2).map(\.id), ["r1", "r2"])
        XCTAssertTrue(tl.activities.suffix(2).allSatisfy { $0.turnId == "u2" })
        XCTAssertEqual(tl.activity(id: "r1")?.payload["input"], .object(["file_path": .string("/p/hello.txt"), "content": .string("hi")]))
        XCTAssertEqual(tl.activity(id: "r1")?.payload["requestType"], .string("file_change_approval"))
        XCTAssertEqual(tl.activity(id: "r1")?.summary, "hello.txt")
        XCTAssertEqual(tl.activity(id: "r2")?.payload["questions"]?.arrayValue?.count, 1)
        XCTAssertEqual(tl.activities.suffix(2).map(\.sequence), [base.activities.count, base.activities.count + 1])
        XCTAssertEqual(base.appending(pending: []), base)
    }

    // MARK: Task 7 — PendingRequests
    func testDeriveKeepsOpenRequestsAndNeverReopensAResolvedOne() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func a(_ id: String, _ kind: String, _ payload: [String: JSONValue] = [:], seq: Int) -> SessionTimeline.Activity {
            let requestId = id.split(separator: "/").first.map(String.init) ?? id
            return SessionTimeline.Activity(id: id, tone: .approval, kind: kind, summary: id, detail: nil,
                            payload: payload.merging(["requestId": .string(requestId)]) { a, _ in a },
                            turnId: "u1", sequence: seq, createdAt: t0)
        }
        let acts = [
            a("perm:t1", "approval.requested", ["toolName": .string("Bash"), "requestType": .string("command_execution_approval"), "input": .object([:])], seq: 0),
            a("perm:q1", "user-input.requested", ["questions": .array([.object(["id": .string("Q?"), "options": .array([.object(["label": .string("A")])])])])], seq: 1),
            a("perm:q1/resolved", "user-input.resolved", seq: 2),
            a("perm:q1", "user-input.requested", ["questions": .array([])], seq: 3),   // a replayed request after its resolve: ignored
            a("perm:q2", "user-input.requested", ["questions": .array([.object(["id": .string("No options"), "options": .array([])])])], seq: 4),
            a("x", "tool.started", seq: 5),
        ]
        let p = PendingRequests.derive(acts)
        XCTAssertEqual(p.approvals.map(\.requestId), ["perm:t1"])
        XCTAssertEqual(p.approvals[0].toolName, "Bash")
        XCTAssertEqual(p.userInputs.map(\.requestId), [])   // q1 closed, q2 has no valid options
    }

    func testDeriveDropsMalformedOptionsButKeepsTheQuestion() {
        let q = SessionTimeline.Activity(id: "perm:q", tone: .approval, kind: "user-input.requested", summary: "q", detail: nil,
                         payload: ["requestId": .string("perm:q"),
                                   "questions": .array([.object(["id": .string("Q?"), "options": .array([.string("junk"), .object(["label": .string("Fine")])])])])],
                         turnId: "u1", sequence: 0, createdAt: Date())
        let p = PendingRequests.derive([q])
        XCTAssertEqual(p.userInputs.count, 1)
        XCTAssertEqual(p.userInputs[0].questions.first?.objectValue?["options"]?.arrayValue?.count, 1)
    }

    // MARK: Task 8 — SessionFeed carries the timeline
    func testSessionFeedDecodesWithoutATimelineAndRoundTripsWithOne() throws {
        let legacy = #"{"pid":1,"sessionId":"s","cwd":"/","status":"idle","waiting":false,"items":[]}"#
        let feed = try JSONDecoder().decode(SessionFeed.self, from: Data(legacy.utf8))
        XCTAssertNil(feed.timeline)
        let tl = build(try entries("plain"))
        let full = SessionFeed(pid: 1, sessionId: "s", cwd: "/", status: "idle", waiting: false, items: [], timeline: tl)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(SessionFeed.self, from: enc.encode(full)).timeline, tl)
    }

    func testReadBuildsTheTimelineFromTheSameTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-read-\(UUID().uuidString)")
        let claudeDir = dir.appendingPathComponent(".claude")
        let cwd = "/Users/me/proj"
        let url = Transcript.locate(cwd: cwd, sessionId: "S1", claudeDir: claudeDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "Fixtures/timeline/tools", withExtension: "jsonl")!
        try FileManager.default.copyItem(at: fixture, to: url)
        let record = ClaudeSessionRecord(pid: 4242, sessionId: "S1", cwd: cwd, status: "idle")
        let feed = try XCTUnwrap(SessionFeedReader.read(record: record, claudeDir: claudeDir))
        XCTAssertEqual(feed.timeline?.turns.map(\.id), ["u1"])
        XCTAssertEqual(feed.timeline?.activities.count, 6)
        XCTAssertEqual(feed.items.map(\.kind), [.user, .tool, .result])   // legacy untouched
    }

    func testAResultWhoseCallAgedOutOfTheTailIsDropped() {
        // T3 pairs results only against in-flight tools; a blank row is
        // worse than no row.
        let tl = build(lines([
            #"{"type":"user","uuid":"r0","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"gone","content":"old output"}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:01.000Z","message":{"content":"next"}}"#,
        ]))
        XCTAssertTrue(tl.activities.isEmpty)
        XCTAssertEqual(tl.turns.map(\.id), ["u1"])
    }

    // MARK: Task B-1 — Message.updatedAt, tool.started/completed command + toolCallId

    private func iso(_ ms: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    private func jsonLine(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func user(_ uuid: String, _ text: String, at ms: Int) -> String {
        jsonLine(["type": "user", "uuid": uuid, "timestamp": iso(ms), "message": ["content": text]])
    }
    private func assistantText(_ uuid: String, _ text: String, at ms: Int) -> String {
        jsonLine(["type": "assistant", "uuid": uuid, "timestamp": iso(ms),
                   "message": ["content": [["type": "text", "text": text]]]])
    }
    private func toolUse(_ id: String, name: String, input: [String: Any], at ms: Int) -> String {
        jsonLine(["type": "assistant", "uuid": "a:\(id)", "timestamp": iso(ms),
                   "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    private func toolResult(_ toolUseId: String, _ content: String, at ms: Int) -> String {
        jsonLine(["type": "user", "uuid": "r:\(toolUseId)", "timestamp": iso(ms),
                   "message": ["content": [["type": "tool_result", "tool_use_id": toolUseId, "content": content]]]])
    }

    func testAssistantMessageUpdatedAtAdvancesWithStreamedBlocks() throws {
        let t = build(lines([
            user("u1", "Hi", at: 1_000),
            assistantText("a1", "One", at: 2_000),
            assistantText("a2", "Two", at: 5_000),
        ]))
        let m = try XCTUnwrap(t.messages.first { $0.role == .assistant })
        XCTAssertEqual(m.createdAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(m.updatedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(m.text, "One\n\nTwo")
    }

    func testUserMessageUpdatedAtEqualsCreatedAt() throws {
        let t = build(lines([user("u1", "Hi", at: 1_000)]))
        let m = try XCTUnwrap(t.messages.first)
        XCTAssertEqual(m.updatedAt, m.createdAt)
    }

    func testMessageDecodesWithoutUpdatedAt() throws {
        let json = """
        {"id":"m","role":"user","text":"x","turnId":"t","streaming":false,"createdAt":"2026-01-01T00:00:00Z"}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = try d.decode(SessionTimeline.Message.self, from: Data(json.utf8))
        XCTAssertEqual(m.updatedAt, m.createdAt)
    }

    func testBashToolStartedCarriesCommandAndToolCallId() throws {
        let t = build(lines([
            user("u1", "run", at: 1_000),
            toolUse("tu1", name: "Bash", input: ["command": "ls -la", "description": "list"], at: 2_000),
            toolResult("tu1", "a\nb", at: 3_000),
        ]))
        let started = try XCTUnwrap(t.activities.first { $0.kind == "tool.started" })
        XCTAssertEqual(started.payload["command"]?.stringValue, "ls -la")
        XCTAssertEqual(started.payload["toolCallId"]?.stringValue, "tu1")
        let completed = try XCTUnwrap(t.activities.first { $0.kind == "tool.completed" })
        XCTAssertEqual(completed.payload["toolCallId"]?.stringValue, "tu1")
        XCTAssertEqual(completed.payload["command"]?.stringValue, "ls -la")
    }

    func testNonBashToolStartedHasNoCommandKey() throws {
        let t = build(lines([
            user("u1", "read", at: 1_000),
            toolUse("tu2", name: "Read", input: ["file_path": "/a/b.swift"], at: 2_000),
        ]))
        let started = try XCTUnwrap(t.activities.first { $0.kind == "tool.started" })
        XCTAssertNil(started.payload["command"])
        XCTAssertEqual(started.payload["toolCallId"]?.stringValue, "tu2")
    }
}
