import XCTest
@testable import InfinitusCore

/// The Agents panel model (`AgentsPanel.tsx` + `subagentRuntime.ts` at the
/// pinned sha 6c583620f), driven on canned agent JSONL.
final class T3AgentsTests: XCTestCase {
    // MARK: Canned logs

    private static let start = "2026-09-10T08:00:00.000Z"

    private func user(_ at: String) -> String {
        #"{"type":"user","timestamp":"\#(at)","message":{"role":"user","content":"go"}}"#
    }

    private func assistantTool(_ at: String, name: String, input: Int = 5,
                               output: Int = 7, cacheCreation: Int = 0, cacheRead: Int = 0) -> String {
        #"""
        {"type":"assistant","timestamp":"\#(at)","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead)},"content":[{"type":"tool_use","name":"\#(name)","input":{}}]}}
        """#
    }

    private func assistantText(_ at: String, _ text: String, input: Int = 3, output: Int = 11) -> String {
        #"""
        {"type":"assistant","timestamp":"\#(at)","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"content":[{"type":"text","text":"\#(text)"}]}}
        """#
    }

    private func meta(type: String = "coder", description: String? = "Port the Agents tab",
                      toolUseId: String? = "toolu_1") -> T3Agents.Meta {
        T3Agents.Meta(agentType: type, description: description, toolUseId: toolUseId)
    }

    private func iso(_ s: String) -> Date { UsageHistory.parseISO(s)! }

    // MARK: Status

    func testARunningAgentIsTheOneWhoseLogHasNoFinalTextAndWasJustTouched() {
        let now = iso("2026-09-10T08:01:00.000Z")
        let log = T3Agents.log(id: "a1",
                               lines: [user(Self.start), assistantTool("2026-09-10T08:00:30.000Z", name: "Bash")],
                               meta: meta(), modifiedAt: iso("2026-09-10T08:00:30.000Z"))
        let panel = T3Agents.panel(direct: [log], now: now)
        let agent = panel.directAgents[0]
        XCTAssertEqual(agent.status, .running)
        XCTAssertEqual(agent.kind, .subagent)
        XCTAssertEqual(agent.title, "Port the Agents tab")
        XCTAssertEqual(agent.role, "coder")
        XCTAssertEqual(agent.lastToolName, "Bash")
        XCTAssertNil(agent.completedAt, "a running agent has no completedAt")
        XCTAssertEqual(agent.startedAt, iso(Self.start))
        XCTAssertEqual(T3Agents.activityText(agent), "▸ Bash")
        XCTAssertEqual(panel.liveCount, 1)
        XCTAssertEqual(panel.settledCount, 0)
    }

    func testALogWithNoFinalTextThatHasNotBeenTouchedInTwoMinutesReadsSettled() {
        // The rule `SessionFeedReader.attachAgents` applies today, reused: a
        // stale log with no final assistant text is not "running".
        let log = T3Agents.log(id: "a1", lines: [user(Self.start), assistantTool("2026-09-10T08:00:30.000Z", name: "Bash")],
                               meta: meta(), modifiedAt: iso("2026-09-10T08:00:30.000Z"))
        let panel = T3Agents.panel(direct: [log], now: iso("2026-09-10T09:00:00.000Z"))
        XCTAssertEqual(panel.directAgents[0].status, .completed)
        XCTAssertEqual(panel.liveCount, 0)
    }

    func testACompletedAgentCarriesItsUsageItsLastToolAndItsResult() {
        let log = T3Agents.log(
            id: "a2",
            lines: [user(Self.start),
                    assistantTool("2026-09-10T08:00:10.000Z", name: "Read", input: 2, output: 7,
                                  cacheCreation: 59_103, cacheRead: 0),
                    assistantTool("2026-09-10T08:00:20.000Z", name: "Edit", input: 4, output: 9,
                                  cacheCreation: 0, cacheRead: 12_000),
                    assistantText("2026-09-10T08:00:45.000Z", "Ported the tab.\\nDetails follow.")],
            meta: meta(), modifiedAt: iso("2026-09-10T08:00:45.000Z"))
        let panel = T3Agents.panel(direct: [log], now: iso("2026-09-10T08:00:50.000Z"))
        let agent = panel.directAgents[0]
        XCTAssertEqual(agent.status, .completed)
        XCTAssertEqual(agent.completedAt, iso("2026-09-10T08:00:45.000Z"))
        // Cache tokens included: 2+7+59103 + 4+9+12000 + 3+11.
        XCTAssertEqual(agent.usage, T3Agents.Usage(totalTokens: 71_139, toolUses: 2))
        XCTAssertEqual(agent.lastToolName, "Edit")
        XCTAssertEqual(agent.result, "Ported the tab.", "the result is the final text's FIRST line")
        XCTAssertNil(agent.error)
        XCTAssertEqual(T3Agents.activityText(agent), "Ported the tab.")
        XCTAssertEqual(T3Agents.metadataLine(agent), "sonnet-4-5 · 71.1k tok · 2 tools")
        XCTAssertEqual(T3Agents.elapsed(of: agent, panel: panel), "45s")
        XCTAssertEqual(panel.settledCount, 1)
        XCTAssertEqual(panel.totalTokens, 71_139)
    }

    func testAFailedAgentTakesItsStateFromTheChatsSpawnRowAndItsTextIsTheError() {
        let log = T3Agents.log(id: "a3",
                               lines: [user(Self.start), assistantText("2026-09-10T08:00:30.000Z", "Could not build.")],
                               meta: meta(), modifiedAt: iso("2026-09-10T08:00:30.000Z"))
        let spawn = AgentSpawn.Member(
            id: "toolu_1", title: "Port the Agents tab", agentType: "coder",
            running: false, failed: true, lastTool: "Bash · swift build")
        let panel = T3Agents.panel(direct: [log], spawns: [spawn], now: iso("2026-09-10T08:00:35.000Z"))
        let agent = panel.directAgents[0]
        XCTAssertEqual(agent.status, .failed)
        XCTAssertEqual(agent.error, "Could not build.")
        XCTAssertNil(agent.result)
        XCTAssertEqual(T3Agents.activityText(agent), "Could not build.")
        XCTAssertEqual(T3Agents.statusLabel(agent.status), "Failed")
        XCTAssertEqual(panel.liveCount, 0)
        XCTAssertEqual(panel.settledCount, 1)
    }

    /// The join the panel makes with the chat, end to end: a parent transcript
    /// with an `Agent` call whose result is an error, through
    /// `SessionTimelineBuilder` and `ThreadFeedPresentation`, must land on the
    /// agent's own log as `.failed` — a hand-built `Member` cannot prove the
    /// key the real rows carry.
    func testTheChatsOwnSpawnRowsJoinOntoTheAgentsOnDiskLog() {
        let parent: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "timestamp": Self.start,
             "message": ["role": "user", "content": "spawn one"]],
            ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "timestamp": "2026-09-10T08:00:01.000Z",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_join", "name": "Agent",
                 "input": ["description": "Port the Agents tab", "subagent_type": "coder"]]]]],
            ["type": "user", "uuid": "u2", "parentUuid": "a1", "timestamp": "2026-09-10T08:00:40.000Z",
             "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_join", "is_error": true,
                 "content": "the agent could not build"]]]],
        ]
        let timeline = SessionTimelineBuilder.build(entries: parent, status: "idle")
        let spawns = ThreadFeedPresentation.deriveExpanded(timeline).flatMap { row -> [AgentSpawn.Member] in
            guard case .agentSpawn(let spawn) = row.kind else { return [] }
            return spawn.members
        }
        XCTAssertEqual(spawns.map { T3Agents.spawnToolUseId($0) }, ["toolu_join"],
                       "one member, keyed on the tool_use id: \(spawns.map(\.id))")
        XCTAssertEqual(spawns.map(\.failed), [true], "the error result is what makes the row red")

        let log = T3Agents.log(id: "a9", lines: [user(Self.start), assistantText("2026-09-10T08:00:30.000Z", "Could not build.")],
                               meta: meta(description: "Port the Agents tab", toolUseId: "toolu_join"),
                               modifiedAt: iso("2026-09-10T08:00:30.000Z"))
        let panel = T3Agents.panel(direct: [log], spawns: spawns, now: iso("2026-09-10T08:00:45.000Z"))
        XCTAssertEqual(panel.directAgents[0].status, .failed)
        XCTAssertEqual(panel.directAgents[0].error, "Could not build.")
    }

    func testTheSpawnRowWinsOverTheOnDiskFallbackSoThePanelAgreesWithTheChat() {
        // Stale log (the fallback would say completed), but the chat still has
        // it running.
        let log = T3Agents.log(id: "a4", lines: [user(Self.start), assistantText("2026-09-10T08:00:30.000Z", "Draft.")],
                               meta: meta(), modifiedAt: iso("2026-09-10T08:00:30.000Z"))
        let spawn = AgentSpawn.Member(
            id: "toolu_1", title: "Port the Agents tab", agentType: "coder",
            running: true, failed: false, lastTool: nil)
        let panel = T3Agents.panel(direct: [log], spawns: [spawn], now: iso("2026-09-10T10:00:00.000Z"))
        XCTAssertEqual(panel.directAgents[0].status, .running)
    }

    // MARK: Workflows

    func testAWorkflowMemberGroupsUnderItsRunAndSettlesOnTheRunsJournal() {
        // A real workflow meta has neither a description nor a toolUseId.
        let workflowMeta = T3Agents.Meta(agentType: "general-purpose", description: nil, toolUseId: nil)
        let member = T3Agents.log(id: "wa1",
                                  lines: [user(Self.start), assistantTool("2026-09-10T08:00:10.000Z", name: "Bash")],
                                  meta: workflowMeta, modifiedAt: iso("2026-09-10T08:00:10.000Z"))
        let journal = T3Agents.Journal.parse(lines: [
            #"{"type":"started","key":"v2:abc","agentId":"wa1"}"#,
            #"{"type":"result","key":"v2:abc","agentId":"wa1","result":"stages=6"}"#,
        ])
        let run = T3Agents.Run(id: "wf_086bd472-5ba", logs: [member], journal: journal)
        let panel = T3Agents.panel(direct: [], runs: [run], now: iso("2026-09-10T08:00:15.000Z"))

        XCTAssertTrue(panel.directAgents.isEmpty)
        XCTAssertEqual(panel.workflows.count, 1)
        let workflow = panel.workflows[0]
        XCTAssertEqual(workflow.id, "wf_086bd472-5ba")
        XCTAssertEqual(workflow.title, "wf_086bd472-5ba", "no coordinator agent: the run dir names it")
        XCTAssertEqual(workflow.members.count, 1)
        let agent = workflow.members[0]
        XCTAssertEqual(agent.kind, .workflowAgent)
        XCTAssertEqual(agent.status, .completed, "the journal's result settles it")
        XCTAssertEqual(agent.title, "general-purpose", "no description on a workflow meta")
        XCTAssertNil(T3Agents.visibleRole(agent), "the role repeats the title, so the pill is hidden")
        XCTAssertEqual(agent.result, "stages=6")
        XCTAssertFalse(workflow.isLive)
        XCTAssertEqual(workflow.failedCount, 0)
        XCTAssertEqual(panel.settledCount, 1)
        XCTAssertTrue(panel.hasAgents)
    }

    func testALiveWorkflowMemberKeepsTheRunLiveAndCounts() {
        let workflowMeta = T3Agents.Meta(agentType: "general-purpose", description: nil, toolUseId: nil)
        let running = T3Agents.log(id: "wa1", lines: [user(Self.start), assistantTool("2026-09-10T08:00:10.000Z", name: "Bash")],
                                   meta: workflowMeta, modifiedAt: iso("2026-09-10T08:00:10.000Z"))
        let done = T3Agents.log(id: "wa2", lines: [user("2026-09-10T08:00:05.000Z"),
                                                   assistantText("2026-09-10T08:00:12.000Z", "done")],
                                meta: workflowMeta, modifiedAt: iso("2026-09-10T08:00:12.000Z"))
        let panel = T3Agents.panel(direct: [], runs: [T3Agents.Run(id: "wf_1", logs: [done, running])],
                                   now: iso("2026-09-10T08:00:20.000Z"))
        let workflow = panel.workflows[0]
        XCTAssertTrue(workflow.isLive)
        XCTAssertNil(workflow.completedAt, "a live run shows no elapsed")
        XCTAssertEqual(workflow.members.map(\.id), ["wa1", "wa2"], "spawn order: earliest first timestamp first")
        XCTAssertEqual(panel.liveCount, 1)
        XCTAssertEqual(panel.settledCount, 1)
    }

    func testAnEmptyPanelHasNoAgents() {
        let panel = T3Agents.panel(direct: [])
        XCTAssertFalse(panel.hasAgents)
        XCTAssertEqual(panel.liveCount, 0)
        XCTAssertEqual(panel.totalTokens, 0)
    }

    // MARK: Formatters

    func testFormatElapsedSeconds() {
        XCTAssertEqual(T3Agents.formatElapsedSeconds(5), "5s")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(0), "0s")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(-3), "0s", "clamped at zero")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(59.9), "59s", "floored")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(185), "3m 05s")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(600), "10m 00s")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(3720), "1h 02m")
        XCTAssertEqual(T3Agents.formatElapsedSeconds(3600), "1h 00m")
    }

    func testElapsedBetweenNeedsBothEnds() {
        XCTAssertEqual(T3Agents.elapsed(from: iso(Self.start), to: iso("2026-09-10T08:03:05.000Z")), "3m 05s")
        XCTAssertEqual(T3Agents.elapsed(from: nil, to: iso(Self.start)), "")
        XCTAssertEqual(T3Agents.elapsed(from: iso(Self.start), to: nil), "")
    }

    func testModelLabel() {
        XCTAssertEqual(T3Agents.modelLabel("claude-sonnet-5[1m]"), "sonnet-5[1m]")
        XCTAssertEqual(T3Agents.modelLabel("claude-opus-4-20250514"), "opus-4")
        XCTAssertEqual(T3Agents.modelLabel("claude-3-5-haiku-latest"), "3-5-haiku")
        XCTAssertEqual(T3Agents.modelLabel("gpt-5-codex"), "gpt-5-codex", "an unknown id passes through")
        XCTAssertNil(T3Agents.modelLabel(nil))
        XCTAssertNil(T3Agents.modelLabel(""))
    }

    func testTokenCount() {
        XCTAssertEqual(T3Agents.tokenCount(0), "0")
        XCTAssertEqual(T3Agents.tokenCount(999), "999")
        XCTAssertEqual(T3Agents.tokenCount(1000), "1.0k")
        XCTAssertEqual(T3Agents.tokenCount(71_139), "71.1k")
        XCTAssertEqual(T3Agents.tokenCount(99_949), "99.9k")
        XCTAssertEqual(T3Agents.tokenCount(150_400), "150k", "at 100k and up the fraction goes")
        XCTAssertEqual(T3Agents.tokenCount(999_999), "1000k")
        XCTAssertEqual(T3Agents.tokenCount(1_240_000), "1.2M")
    }

    func testTheMetadataLineSaysSoWhenUsageIsUnknown() {
        let log = T3Agents.log(id: "a5", lines: [user(Self.start)], meta: meta(),
                              modifiedAt: iso("2026-09-10T08:00:00.000Z"))
        let agent = T3Agents.panel(direct: [log], now: iso("2026-09-10T09:00:00.000Z")).directAgents[0]
        XCTAssertNil(agent.usage, "no assistant line: nothing is known")
        XCTAssertEqual(T3Agents.metadataLine(agent), "— tok")
    }

    func testTheRolePillHidesWhenItOnlyRepeatsTheTitle() {
        let log = T3Agents.log(id: "a6", lines: [user(Self.start)],
                               meta: meta(type: "Coder", description: "coder", toolUseId: nil),
                               modifiedAt: iso("2026-09-10T08:00:00.000Z"))
        let agent = T3Agents.panel(direct: [log], now: iso("2026-09-10T09:00:00.000Z")).directAgents[0]
        XCTAssertNil(T3Agents.visibleRole(agent), "case-insensitive match")
    }

    // MARK: The whole directory

    func testTheDirectoryScanSplitsDirectSpawnsFromWorkflowRuns() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3agents-\(UUID().uuidString)/subagents")
        let runDir = root.appendingPathComponent("workflows/wf_test")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try [user(Self.start), assistantText("2026-09-10T08:00:20.000Z", "Direct done.")]
            .joined(separator: "\n").appending("\n")
            .write(to: root.appendingPathComponent("agent-d1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"coder","description":"A direct spawn","toolUseId":"toolu_1","spawnDepth":1}"#
            .write(to: root.appendingPathComponent("agent-d1.meta.json"), atomically: true, encoding: .utf8)
        try [user(Self.start), assistantTool("2026-09-10T08:00:10.000Z", name: "Glob")]
            .joined(separator: "\n").appending("\n")
            .write(to: runDir.appendingPathComponent("agent-w1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"general-purpose","spawnDepth":1,"model":"fable"}"#
            .write(to: runDir.appendingPathComponent("agent-w1.meta.json"), atomically: true, encoding: .utf8)
        try #"{"type":"result","key":"v2:x","agentId":"w1","result":"ok"}"#.appending("\n")
            .write(to: runDir.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)

        let panel = T3Agents.panel(subagentsDir: root, now: Date())
        XCTAssertEqual(panel.directAgents.map(\.title), ["A direct spawn"])
        XCTAssertEqual(panel.workflows.map(\.id), ["wf_test"])
        XCTAssertEqual(panel.workflows[0].members.map(\.id), ["w1"])
        XCTAssertEqual(panel.workflows[0].members[0].result, "ok")
        XCTAssertEqual(panel.settledCount, 2)
        XCTAssertTrue(panel.hasAgents)
    }

    func testAMissingDirectoryIsAnEmptyPanel() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3agents-missing-\(UUID().uuidString)/subagents")
        XCTAssertFalse(T3Agents.panel(subagentsDir: missing).hasAgents)
    }

    func testALogThatGrewIsFoldedOnFromWhereTheLastPumpStopped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3agents-\(UUID().uuidString)/subagents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let log = root.appendingPathComponent("agent-g1.jsonl")
        try #"{"agentType":"coder","description":"Grows","toolUseId":"toolu_1"}"#
            .write(to: root.appendingPathComponent("agent-g1.meta.json"), atomically: true, encoding: .utf8)
        try [user(Self.start), assistantTool("2026-09-10T08:00:10.000Z", name: "Read", input: 10, output: 0)]
            .joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)

        let first = T3Agents.panel(subagentsDir: root, now: Date())
        XCTAssertEqual(first.directAgents[0].usage, T3Agents.Usage(totalTokens: 10, toolUses: 1))

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistantText("2026-09-10T08:00:30.000Z", "All done.") + "\n").utf8))
        try handle.close()

        let second = T3Agents.panel(subagentsDir: root, now: Date())
        let agent = second.directAgents[0]
        XCTAssertEqual(agent.usage, T3Agents.Usage(totalTokens: 24, toolUses: 1), "10 + 3 + 11, counted once each")
        XCTAssertEqual(agent.result, "All done.")
        XCTAssertEqual(agent.status, .completed)
    }

    func testScanningOneThreadKeepsAnotherThreadsParsedLogs() throws {
        func seed(_ id: String) throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("t3agents-\(UUID().uuidString)/subagents")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try [user(Self.start), assistantText("2026-09-10T08:00:20.000Z", "Done.")]
                .joined(separator: "\n").appending("\n")
                .write(to: root.appendingPathComponent("agent-\(id).jsonl"), atomically: true, encoding: .utf8)
            return root
        }
        let a = try seed("k1"), b = try seed("k2")
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        _ = T3Agents.panel(subagentsDir: a, now: Date())
        let afterA = T3Agents.logs.count
        _ = T3Agents.panel(subagentsDir: b, now: Date())
        XCTAssertEqual(T3Agents.logs.count, afterA + 1, "b's scan must not evict a's parsed log")
    }

    func testALogWhoseMtimeMovedButWhoseBytesDidNotKeepsItsFold() throws {
        // The live fixture caught this: a touch (new mtime, same size) missed
        // the cache, and `readToEnd()` answering nil at EOF read as a failure —
        // the row lost its usage, its tool and its start.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3agents-\(UUID().uuidString)/subagents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let log = root.appendingPathComponent("agent-t1.jsonl")
        try #"{"agentType":"coder","description":"Touched","toolUseId":"toolu_1"}"#
            .write(to: root.appendingPathComponent("agent-t1.meta.json"), atomically: true, encoding: .utf8)
        try [user(Self.start), assistantTool("2026-09-10T08:00:10.000Z", name: "Read", input: 10, output: 0)]
            .joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)

        let before = T3Agents.panel(subagentsDir: root, now: Date()).directAgents[0]
        XCTAssertEqual(before.usage, T3Agents.Usage(totalTokens: 10, toolUses: 1))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)],
                                              ofItemAtPath: log.path)
        let after = T3Agents.panel(subagentsDir: root, now: Date()).directAgents[0]
        XCTAssertEqual(after.usage, before.usage)
        XCTAssertEqual(after.lastToolName, "Read")
        XCTAssertEqual(after.startedAt, iso(Self.start))
    }

    func testAHalfWrittenTailLineIsLeftForTheNextPump() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3agents-\(UUID().uuidString)/subagents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let log = root.appendingPathComponent("agent-h1.jsonl")
        let complete = user(Self.start) + "\n" + assistantTool("2026-09-10T08:00:10.000Z", name: "Read", input: 10, output: 0) + "\n"
        try (complete + #"{"type":"assistant","timesta"#).write(to: log, atomically: true, encoding: .utf8)

        let first = T3Agents.panel(subagentsDir: root, now: Date())
        XCTAssertEqual(first.directAgents[0].usage, T3Agents.Usage(totalTokens: 10, toolUses: 1))

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        // The writer finishes the line it had started.
        try handle.write(contentsOf: Data(#"mp":"2026-09-10T08:00:30.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"Fin."}]}}"#.appending("\n").utf8))
        try handle.close()

        let agent = T3Agents.panel(subagentsDir: root, now: Date()).directAgents[0]
        XCTAssertEqual(agent.usage, T3Agents.Usage(totalTokens: 13, toolUses: 1), "the partial line was not double-counted")
        XCTAssertEqual(agent.result, "Fin.")
    }
}
