import XCTest
@testable import InfinitusCore

/// #151 slice 1: the wire between the app and a Claude Code session it
/// owns over stdin/stdout stream-json — pure functions, no process.
final class OwnedWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: locator / version gate

    func testVersionParsesClaudeCodeBanner() {
        XCTAssertEqual(ClaudeLocator.parseVersion("2.1.263 (Claude Code)\n"), [2, 1, 263])
        XCTAssertNil(ClaudeLocator.parseVersion("not a version"))
    }

    func testOwnedSessionsNeedTheHostPromptsBuild() {
        XCTAssertTrue(ClaudeLocator.supportsOwnedSessions(version: [2, 1, 259]))
        XCTAssertTrue(ClaudeLocator.supportsOwnedSessions(version: [2, 2, 0]))
        XCTAssertFalse(ClaudeLocator.supportsOwnedSessions(version: [2, 1, 258]))
        XCTAssertFalse(ClaudeLocator.supportsOwnedSessions(version: [1, 9, 999]))
    }

    func testLocatorPrefersCandidatesThenTheLoginShell() {
        XCTAssertEqual(ClaudeLocator.locate(candidates: ["/a/claude", "/b/claude"],
                                            exists: { $0 == "/b/claude" }, loginShell: { "/c/claude" }),
                       "/b/claude")
        XCTAssertEqual(ClaudeLocator.locate(candidates: ["/a/claude"], exists: { _ in false },
                                            loginShell: { "/c/claude\n" }),
                       "/c/claude")
        XCTAssertNil(ClaudeLocator.locate(candidates: [], exists: { _ in false }, loginShell: { "" }))
    }

    // MARK: argv

    func testArgumentsCarryTheStreamingFlagsAndOnlyKnownModes() {
        let req = SessionStart.Request(cwd: "/repo", prompt: "hi", permissionMode: "acceptEdits",
                                       model: "opus", systemPrompt: "be terse", headless: true)
        let args = OwnedWire.arguments(for: req, sessionId: "S-1")
        for flag in ["--input-format", "stream-json", "--output-format", "--verbose", "--include-partial-messages",
                     "--permission-prompts", "host", "--permission-prompt-tool", "stdio", "--session-id", "S-1",
                     "--permission-mode", "acceptEdits", "--model", "opus", "--append-system-prompt", "be terse"] {
            XCTAssertTrue(args.contains(flag), "missing \(flag) in \(args)")
        }
        XCTAssertFalse(args.contains("hi"), "the prompt goes over stdin, never argv")
        XCTAssertFalse(args.contains("/repo"), "cwd is the process directory, not a flag")
        XCTAssertFalse(args.contains("-p"))
        let odd = OwnedWire.arguments(for: SessionStart.Request(cwd: "/r", permissionMode: "--rm-rf"), sessionId: "S")
        XCTAssertFalse(odd.contains("--permission-mode"))
    }

    func testResumeReplacesTheSessionIdAndForkAddsItsFlag() {
        let plain = OwnedWire.arguments(for: SessionStart.Request(cwd: "/r", resume: "OLD"), sessionId: "NEW")
        XCTAssertTrue(plain.contains("--resume") && plain.contains("OLD"))
        XCTAssertFalse(plain.contains("--session-id"))
        XCTAssertFalse(plain.contains("--fork-session"))
        let fork = OwnedWire.arguments(for: SessionStart.Request(cwd: "/r", resume: "OLD", fork: true), sessionId: "NEW")
        XCTAssertTrue(fork.contains("--fork-session"))
    }

    // MARK: stdin frames

    func testUserAndControlFramesAreOneJSONLineEach() throws {
        let user = OwnedWire.userLine("write hello")
        XCTAssertTrue(user.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "user")
        let content = ((obj["message"] as! [String: Any])["content"] as! [[String: Any]])[0]
        XCTAssertEqual(content["text"] as? String, "write hello")

        let ctl = try JSONSerialization.jsonObject(with: Data(OwnedWire.controlLine(requestId: "7", subtype: "interrupt").utf8)) as! [String: Any]
        XCTAssertEqual(ctl["type"] as? String, "control_request")
        XCTAssertEqual(ctl["request_id"] as? String, "7")
        XCTAssertEqual((ctl["request"] as! [String: Any])["subtype"] as? String, "interrupt")
        let mode = try JSONSerialization.jsonObject(with: Data(OwnedWire.controlLine(requestId: "8", subtype: "set_permission_mode", fields: ["mode": "plan"]).utf8)) as! [String: Any]
        XCTAssertEqual((mode["request"] as! [String: Any])["mode"] as? String, "plan")
    }

    // MARK: stdout events

    func testDecodesAPermissionRequestIntoAPendingRequest() throws {
        guard case .canUseTool(let pending) = OwnedWire.decode(line: try fixture("owned-can-use-tool-write")) else {
            return XCTFail("not a can_use_tool")
        }
        XCTAssertEqual(pending.requestId, "54e93891-1b8d-4e6d-9613-4bf1360717ea")
        XCTAssertEqual(pending.toolName, "Write")
        XCTAssertEqual(pending.description, "probe4.txt")
        XCTAssertTrue(pending.questions.isEmpty)
        XCTAssertTrue(pending.inputJSON.contains("probe4.txt"))
        XCTAssertEqual(pending.suggestionsJSON.map { $0.contains("acceptEdits") }, true)
    }

    func testDecodesAskUserQuestionIntoQuestionsWithOptionLabels() throws {
        guard case .canUseTool(let pending) = OwnedWire.decode(line: try fixture("owned-can-use-tool-ask")) else {
            return XCTFail("not a can_use_tool")
        }
        XCTAssertEqual(pending.toolName, "AskUserQuestion")
        XCTAssertEqual(pending.questions.count, 1)
        XCTAssertEqual(pending.questions[0].question, "Which colour?")
        XCTAssertEqual(pending.questions[0].header, "Colour")
        XCTAssertEqual(pending.questions[0].options, ["Red", "Blue"])
        XCTAssertFalse(pending.questions[0].multiSelect)
    }

    func testDecodesInitResultAndControlResponses() {
        guard case .initialized(let sid, let mode) = OwnedWire.decode(line: #"{"type":"system","subtype":"init","session_id":"S9","permissionMode":"default","tools":["Bash"]}"#) else {
            return XCTFail("init")
        }
        XCTAssertEqual(sid, "S9"); XCTAssertEqual(mode, "default")
        guard case .result = OwnedWire.decode(line: #"{"type":"result","subtype":"success","session_id":"S9"}"#) else { return XCTFail("result") }
        guard case .controlResponse(let rid) = OwnedWire.decode(line: #"{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}"#) else { return XCTFail("ctl") }
        XCTAssertEqual(rid, "1")
        guard case .other = OwnedWire.decode(line: #"{"type":"stream_event","event":{}}"#) else { return XCTFail("other") }
        guard case .other = OwnedWire.decode(line: "garbage") else { return XCTFail("garbage") }
    }

    func testManualModeReachesArgvSoAClientCanForceAskEveryTime() {
        // The step-0 probe got its can_use_tool under `--permission-mode
        // manual`; a Mac whose settings default to "auto" needs it forced.
        let args = OwnedWire.arguments(for: SessionStart.Request(cwd: "/", prompt: nil, permissionMode: "manual", headless: true), sessionId: "S")
        XCTAssertEqual(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }, "manual")
        let plan = OwnedWire.arguments(for: SessionStart.Request(cwd: "/", prompt: nil, permissionMode: "plan", headless: true), sessionId: "S")
        XCTAssertTrue(plan.contains("plan"))
        let bogus = OwnedWire.arguments(for: SessionStart.Request(cwd: "/", prompt: nil, permissionMode: "yolo", headless: true), sessionId: "S")
        XCTAssertFalse(bogus.contains("--permission-mode"))
    }

    // MARK: #223 §6 leftovers

    func testARejectedRateLimitEventBecomesANoteAndWarningsStayOther() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800008100,"rateLimitType":"five_hour","utilization":1.0}}"#
        guard case .rateLimit(let note) = OwnedWire.decode(line: line, now: now) else { return XCTFail("not a limit") }
        XCTAssertEqual(note.rateLimitType, "five_hour")
        XCTAssertEqual(note.key, "five_hour:1800008100")
        XCTAssertEqual(note.text, "Claude usage limit reached. This turn is paused until the 5-hour limit resets in 2h 15m.")
        guard case .other = OwnedWire.decode(line: #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1800008100,"rateLimitType":"five_hour"}}"#) else {
            return XCTFail("a warning is not a line")
        }
        // A reset more than 30 days out is not credible: no "in …".
        let far = LimitNote(status: "rejected", rateLimitType: "seven_day",
                            resetsAt: now.addingTimeInterval(40 * 86_400), receivedAt: now)
        XCTAssertEqual(far.text, "Claude usage limit reached. This turn is paused until the weekly limit resets.")
        XCTAssertEqual(LimitNote(status: "rejected", rateLimitType: nil, resetsAt: nil, receivedAt: now).text,
                       "Claude usage limit reached. This turn is paused until the usage limit resets.")
    }

    func testImagesGoBeforeTheOneTextBlock() throws {
        let line = OwnedWire.userLine("/compact", images: [.init(mediaType: "image/png", base64: "AAAA")])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let content = (obj["message"] as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        let source = content[0]["source"] as! [String: Any]
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AAAA")
        XCTAssertEqual(content[1]["text"] as? String, "/compact")
        XCTAssertFalse(OwnedWire.imageMediaTypes.contains("image/heic"))
    }

    func testExitPlanModeExposesItsPlanAsMarkdown() {
        let line = ##"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Ship it\n\n1. build\n2. test"},"tool_use_id":"t1"}}"##
        guard case .canUseTool(let pending) = OwnedWire.decode(line: line) else { return XCTFail("not a can_use_tool") }
        XCTAssertEqual(pending.planMarkdown, "# Ship it\n\n1. build\n2. test")
        let write = #"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"plan":"not a plan"}}}"#
        guard case .canUseTool(let other) = OwnedWire.decode(line: write) else { return XCTFail("not a can_use_tool") }
        XCTAssertNil(other.planMarkdown)
        let tl = SessionTimeline().appending(pending: [pending])
        XCTAssertEqual(tl.activities.first?.summary, "Proposed plan: Ship it")
        XCTAssertEqual(tl.activities.first?.detail, pending.planMarkdown)
    }

    func testLimitsAppendAsTheTranscriptsOwnWarningShape() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note = LimitNote(status: "rejected", rateLimitType: "five_hour", resetsAt: now.addingTimeInterval(600), receivedAt: now)
        let tl = SessionTimeline().appending(limits: [note])
        XCTAssertEqual(tl.activities.map(\.kind), ["runtime.warning"])
        XCTAssertEqual(tl.activities[0].payload["code"], .string("limit"))
        XCTAssertEqual(tl.activities[0].id, "limit:five_hour:1800000600")
        XCTAssertEqual(tl.activities[0].summary, note.text)
    }

    // MARK: answers

    func testAllowEchoesTheInputAndCarriesSuggestionsWhenAsked() throws {
        guard case .canUseTool(let pending) = OwnedWire.decode(line: try fixture("owned-can-use-tool-write")) else { return XCTFail() }
        let plain = try JSONSerialization.jsonObject(with: Data(OwnedWire.answerLine(pending, .allow(forSession: false)).utf8)) as! [String: Any]
        let resp = (plain["response"] as! [String: Any])
        XCTAssertEqual(resp["request_id"] as? String, pending.requestId)
        XCTAssertEqual(resp["subtype"] as? String, "success")
        let inner = resp["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        XCTAssertEqual((inner["updatedInput"] as! [String: Any])["content"] as? String, "hello\n")
        XCTAssertNil(inner["updatedPermissions"])

        let session = try JSONSerialization.jsonObject(with: Data(OwnedWire.answerLine(pending, .allow(forSession: true)).utf8)) as! [String: Any]
        let perms = ((session["response"] as! [String: Any])["response"] as! [String: Any])["updatedPermissions"] as! [[String: Any]]
        XCTAssertEqual(perms.first?["mode"] as? String, "acceptEdits")
    }

    func testAllowForSessionNeverLetsASuggestionPersistToSettings() throws {
        // T3's rule: "allow for session" means this session, whatever
        // destination the CLI suggested — a settings write is a different ask.
        let pending = PendingRequest(requestId: "r", toolName: "Bash", toolUseId: nil, description: nil,
                                     inputJSON: "{}",
                                     suggestionsJSON: #"[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"localSettings"}]"#,
                                     questions: [], receivedAt: Date())
        let obj = try JSONSerialization.jsonObject(with: Data(OwnedWire.answerLine(pending, .allow(forSession: true)).utf8)) as! [String: Any]
        let perms = ((obj["response"] as! [String: Any])["response"] as! [String: Any])["updatedPermissions"] as! [[String: Any]]
        XCTAssertEqual(perms.map { $0["destination"] as? String }, ["session"])
    }

    func testDenyCarriesTheMessage() throws {
        guard case .canUseTool(let pending) = OwnedWire.decode(line: try fixture("owned-can-use-tool-write")) else { return XCTFail() }
        let obj = try JSONSerialization.jsonObject(with: Data(OwnedWire.answerLine(pending, .deny(message: "not now")).utf8)) as! [String: Any]
        let inner = ((obj["response"] as! [String: Any])["response"] as! [String: Any])
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertEqual(inner["message"] as? String, "not now")
    }

    func testQuestionAnswersAreKeyedByTheFullQuestionText() throws {
        guard case .canUseTool(let pending) = OwnedWire.decode(line: try fixture("owned-can-use-tool-ask")) else { return XCTFail() }
        let obj = try JSONSerialization.jsonObject(with: Data(OwnedWire.answerLine(pending, .answers(["Which colour?": "Blue"])).utf8)) as! [String: Any]
        let inner = ((obj["response"] as! [String: Any])["response"] as! [String: Any])
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        let updated = inner["updatedInput"] as! [String: Any]
        XCTAssertEqual((updated["answers"] as! [String: String])["Which colour?"], "Blue")
        XCTAssertNotNil(updated["questions"], "the original questions ride along")
    }

    private func twoQuestions() -> PendingRequest {
        let colour = PendingRequest.Question(question: "Which colour?", header: "Colour", options: ["Red", "Blue"], multiSelect: false)
        let sizes = PendingRequest.Question(question: "Which sizes?", header: "", options: ["S", "M", "L"], multiSelect: true)
        return PendingRequest(requestId: "r-2q", toolName: "AskUserQuestion", toolUseId: nil, description: nil,
                              inputJSON: "{}", suggestionsJSON: nil, questions: [colour, sizes],
                              receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testWholePromptAnswersMustCoverEveryQuestionWithRealOptions() throws {
        let ask = twoQuestions()
        let good = ["Which colour?": "Blue", "Which sizes?": "S, L"]
        XCTAssertEqual(OwnedWire.decision(answers: SessionInput.Answers.encode(good), pending: ask), .answers(good))
        XCTAssertNil(OwnedWire.decision(answers: SessionInput.Answers.encode(["Which colour?": "Blue"]), pending: ask),
                     "the second question went unanswered")
        XCTAssertNil(OwnedWire.decision(answers: SessionInput.Answers.encode(["Which colour?": "Red", "Which sizes?": "S, XL"]), pending: ask),
                     "options and other text mixed on a multi-select")
        XCTAssertNil(OwnedWire.decision(answers: SessionInput.Answers.encode(["Which colour?": "  ", "Which sizes?": "S"]), pending: ask),
                     "an empty free text answers nothing")
        XCTAssertNil(OwnedWire.decision(answers: "not json", pending: ask))
        guard case .canUseTool(let write) = OwnedWire.decode(line: try fixture("owned-can-use-tool-write")) else { return XCTFail() }
        XCTAssertNil(OwnedWire.decision(answers: SessionInput.Answers.encode(good), pending: write), "a permission takes no answers")
    }

    /// Claude Code's "Other": a typed answer stands in for the options, on a
    /// single- or a multi-select (upstream `resolvePendingUserInputAnswer`).
    func testAFreeTextAnswerStandsInForTheOptions() {
        let ask = twoQuestions()
        let typed = ["Which colour?": "Teal, please", "Which sizes?": "S"]
        XCTAssertEqual(OwnedWire.decision(answers: SessionInput.Answers.encode(typed), pending: ask), .answers(typed))
        let multi = ["Which colour?": "Red", "Which sizes?": "huge"]
        XCTAssertEqual(OwnedWire.decision(answers: SessionInput.Answers.encode(multi), pending: ask), .answers(multi))
        let line = OwnedWire.answerLine(ask, .answers(typed))
        XCTAssertTrue(line.contains(#""Which colour?":"Teal, please""#), "the text reaches updatedInput.answers as typed")
    }

    func testAParkedPromptBecomesOneFeedItemCarryingEveryQuestion() throws {
        let item = twoQuestions().feedItem
        XCTAssertEqual(item.kind, .question)
        XCTAssertEqual(item.text, "Which colour?", "an older client still reads the first question")
        XCTAssertEqual(item.options, ["Red", "Blue"], "…and answers it with a key")
        XCTAssertEqual(item.questions?.map(\.question), ["Which colour?", "Which sizes?"])
        XCTAssertEqual(item.questions?[1].multiSelect, true)
        let back = try JSONDecoder().decode(SessionFeedItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
        let old = try JSONDecoder().decode(SessionFeedItem.self,
                                           from: Data(#"{"kind":"question","text":"Which colour?","options":["Red","Blue"]}"#.utf8))
        XCTAssertNil(old.questions, "a feed without the field decodes")
    }

    func testAKeyPicksAnOptionForEveryQuestionOrAPermissionVerdict() throws {
        guard case .canUseTool(let ask) = OwnedWire.decode(line: try fixture("owned-can-use-tool-ask")) else { return XCTFail() }
        XCTAssertEqual(OwnedWire.decision(forKey: "2", pending: ask), .answers(["Which colour?": "Blue"]))
        XCTAssertNil(OwnedWire.decision(forKey: "3", pending: ask), "no third option")
        guard case .canUseTool(let write) = OwnedWire.decode(line: try fixture("owned-can-use-tool-write")) else { return XCTFail() }
        XCTAssertEqual(OwnedWire.decision(forKey: "1", pending: write), .allow(forSession: false))
        XCTAssertEqual(OwnedWire.decision(forKey: "y", pending: write), .allow(forSession: false))
        XCTAssertEqual(OwnedWire.decision(forKey: "enter", pending: write), .allow(forSession: false))
        XCTAssertEqual(OwnedWire.decision(forKey: "2", pending: write), .allow(forSession: true))
        XCTAssertEqual(OwnedWire.decision(forKey: "3", pending: write), .deny(message: OwnedWire.denyMessage))
        XCTAssertEqual(OwnedWire.decision(forKey: "n", pending: write), .deny(message: OwnedWire.denyMessage))
        XCTAssertNil(OwnedWire.decision(forKey: "esc", pending: write), "esc interrupts, it is not an answer")
    }
}
