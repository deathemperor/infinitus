import XCTest
@testable import InfinitusCore

/// The Infinitus → T3 adapter (spec §2.1): every `SessionTimeline` message and
/// activity as a `T3TimelineEntry`. No upstream test file covers this — the
/// mapping is ours — so these are the brief's cases plus the pending fold the
/// phone relies on.
final class T3TimelineEntryTests: XCTestCase {
    private func loadFixtureTimeline(_ name: String) throws -> SessionTimeline {
        let url = Bundle.module.url(forResource: "Fixtures/timeline/\(name)", withExtension: "jsonl")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = text.split(separator: "\n").compactMap { SessionFeedReader.decodeLine(String($0)) }
        return SessionTimelineBuilder.build(entries: entries, status: "idle", statusUpdatedAt: nil, agents: [:])
    }

    func testEntriesInterleaveMessagesAndActivitiesByTime() throws {
        // `tools.jsonl` is the fixture with a user message, tool_use pairs and
        // a terminal assistant reply (the brief's "ask-and-write" placeholder).
        let timeline = try loadFixtureTimeline("tools")
        let entries = T3TimelineEntry.entries(from: timeline)
        XCTAssertEqual(entries.map(\.createdAt), entries.map(\.createdAt).sorted())
        guard case let .message(_, _, m) = entries[0] else { return XCTFail("first entry is not a message") }
        XCTAssertEqual(m.role, .user)
        let work = entries.compactMap { entry -> T3WorkLogEntry? in
            if case let .work(_, _, w) = entry { return w } else { return nil }
        }
        XCTAssertFalse(work.isEmpty)
        // Every `tool.started` in the fixture is paired, so each collapses into
        // its `/completed` twin (see `entries(from:pending:)`).
        let ids = Set(timeline.activities.map(\.id))
        let paired = timeline.activities.filter { $0.kind == "tool.started" && ids.contains("\($0.id)/completed") }
        XCTAssertFalse(paired.isEmpty, "fixture no longer exercises lifecycle pairing")
        XCTAssertEqual(work.first?.sourceActivityKind, "tool.completed")
        XCTAssertEqual(work.map(\.sourceActivityKind).filter { $0 == "tool.started" }, [])
        XCTAssertEqual(entries.count,
                       timeline.messages.count + timeline.activities.count - paired.count)
    }

    func testActivityMapping() {
        let a = SessionTimeline.Activity(id: "a1", tone: .tool, kind: "tool.completed", summary: "Ran rg foo",
                                         detail: "3 matches",
                                         payload: ["command": .string("rg foo"), "status": .string("completed"),
                                                   "toolName": .string("Bash")],
                                         turnId: "t1", sequence: 3, createdAt: Date())
        let w = T3WorkLogEntry(activity: a)
        XCTAssertEqual(w.label, "Ran rg foo")
        XCTAssertEqual(w.detail, "3 matches")
        XCTAssertEqual(w.command, "rg foo")
        XCTAssertEqual(w.toolLifecycleStatus, .completed)
        XCTAssertEqual(w.itemType, .commandExecution)
        XCTAssertEqual(w.tone, .tool)
        XCTAssertEqual(w.sourceActivityKind, "tool.completed")
        XCTAssertEqual(w.turnId, "t1")

        let approval = SessionTimeline.Activity(id: "a2", tone: .approval, kind: "approval.requested",
                                                summary: "Write PLAN.md", detail: nil, payload: [:],
                                                turnId: "t1", sequence: 4, createdAt: Date())
        XCTAssertEqual(T3WorkLogEntry(activity: approval).tone, .info)

        let progress = SessionTimeline.Activity(id: "a3", tone: .info, kind: "task.progress",
                                                summary: "Subagent working", detail: nil, payload: [:],
                                                turnId: "t1", sequence: 5, createdAt: Date())
        XCTAssertEqual(T3WorkLogEntry(activity: progress).tone, .thinking)
    }

    func testToolNameDrivesItemTypeAndRequestKind() {
        func mapped(_ toolName: String, kind: String = "tool.completed") -> T3WorkLogEntry {
            T3WorkLogEntry(activity: SessionTimeline.Activity(
                id: toolName, tone: .tool, kind: kind, summary: toolName, detail: nil,
                payload: ["toolName": .string(toolName)], turnId: "t1", sequence: 0,
                createdAt: Date(timeIntervalSince1970: 0)))
        }
        XCTAssertEqual(mapped("Bash").itemType, .commandExecution)
        XCTAssertEqual(mapped("Bash").requestKind, .command)
        XCTAssertEqual(mapped("Edit").itemType, .fileChange)
        XCTAssertEqual(mapped("Write").itemType, .fileChange)
        XCTAssertEqual(mapped("MultiEdit").itemType, .fileChange)
        XCTAssertEqual(mapped("NotebookEdit").itemType, .fileChange)
        XCTAssertNil(mapped("Read").itemType)
        XCTAssertEqual(mapped("Read").requestKind, .fileRead)
        XCTAssertEqual(mapped("WebSearch").itemType, .webSearch)
        XCTAssertEqual(mapped("WebFetch").itemType, .webSearch)
        XCTAssertEqual(mapped("Grep").itemType, .webSearch)
        XCTAssertEqual(mapped("Glob").itemType, .webSearch)
        // "grep" in the label is what makes `codeSearch` fire for Grep only.
        XCTAssertEqual(T3WorkLog.groupAction(mapped("Grep")), .codeSearch)
        XCTAssertEqual(T3WorkLog.groupAction(mapped("Glob")), .search)
        XCTAssertEqual(mapped("Agent").itemType, .collabAgentToolCall)
        XCTAssertEqual(mapped("Task").itemType, .collabAgentToolCall)
        XCTAssertEqual(mapped("mcp__github__search_issues").itemType, .mcpToolCall)
        XCTAssertEqual(mapped("ExitPlanMode").itemType, .dynamicToolCall)
        XCTAssertEqual(mapped("Read", kind: "user-input.requested").requestKind, .userInput)
    }

    func testMessageMappingCarriesTheTurnAndCopiesCreatedAtToUpdatedAt() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let user = SessionTimeline.Message(id: "u1", role: .user, text: "hi", images: nil, sender: nil,
                                           turnId: "u1", streaming: false, createdAt: at)
        let assistant = SessionTimeline.Message(id: "a1", role: .assistant, text: "done", images: nil, sender: nil,
                                                turnId: "u1", streaming: true, createdAt: at)
        // Neither message here passes updatedAt, so it defaults to createdAt.
        XCTAssertEqual(T3ChatMessage(message: user).updatedAt, at)
        XCTAssertEqual(T3ChatMessage(message: user).role, .user)
        XCTAssertNil(T3ChatMessage(message: user).turnId)      // user messages carry no turn
        XCTAssertEqual(T3ChatMessage(message: assistant).turnId, "u1")
        XCTAssertTrue(T3ChatMessage(message: assistant).streaming)
    }

    /// The phone's mirror already folds pending approvals/questions into the
    /// wire timeline; a caller that has not folded them passes them here and
    /// gets the same activity kinds, so the pending cards derive on their own.
    func testPendingRequestsFoldThroughAppendingPending() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let timeline = SessionTimeline(
            turns: [.init(id: "u1", state: .running, requestedAt: at, startedAt: at, completedAt: nil,
                          userMessageId: "u1", assistantMessageId: nil)],
            messages: [.init(id: "u1", role: .user, text: "hi", images: nil, sender: nil, turnId: "u1",
                             streaming: false, createdAt: at)],
            activities: [])
        let pending = PendingRequest(requestId: "req-1", toolName: "Write", toolUseId: "t1",
                                     description: "Write PLAN.md", inputJSON: "{}", suggestionsJSON: nil,
                                     questions: [], receivedAt: at.addingTimeInterval(5))
        let entries = T3TimelineEntry.entries(from: timeline, pending: [pending])
        let work = entries.compactMap { entry -> T3WorkLogEntry? in
            if case let .work(_, _, w) = entry { return w } else { return nil }
        }
        XCTAssertEqual(work.map(\.sourceActivityKind), ["approval.requested"])
        XCTAssertEqual(work.first?.tone, .info)                 // approval → info
        XCTAssertEqual(T3WorkLog.groupAction(work[0]), .update)
        // Already-folded timelines are not folded twice.
        XCTAssertEqual(T3TimelineEntry.entries(from: timeline.appending(pending: [pending])).count, entries.count)
    }

    func testEntryIdentityAndTurnId() {
        let at = Date(timeIntervalSince1970: 0)
        let assistant = T3ChatMessage(id: "a1", role: .assistant, text: "x", turnId: "t1", streaming: false,
                                      createdAt: at, updatedAt: at)
        let user = T3ChatMessage(id: "u1", role: .user, text: "x", turnId: "t1", streaming: false,
                                 createdAt: at, updatedAt: at)
        XCTAssertEqual(T3TimelineEntry.message(id: "e1", createdAt: at, assistant).turnId, "t1")
        XCTAssertNil(T3TimelineEntry.message(id: "e2", createdAt: at, user).turnId)
        var work = T3WorkLogEntry(id: "w", createdAt: at, label: "l", tone: .tool)
        work.turnId = "t2"
        XCTAssertEqual(T3TimelineEntry.work(id: "e3", createdAt: at, work).turnId, "t2")
        XCTAssertEqual(T3TimelineEntry.work(id: "e3", createdAt: at, work).id, "e3")
    }

    // MARK: - tool.started / tool.completed pairing (fix round 1)

    /// `SessionTimelineBuilder` writes one tool call as two activities whose
    /// summaries differ (`SessionTimelineBuilder.swift:212` and `:274`,
    /// `SessionFeed.swift:697-710`), so `omitSupersededLifecycleMarkers` cannot
    /// collapse them on its `(turnId, itemType, label)` identity.
    private func toolPair(toolUseId: String, startedSummary: String, completedSummary: String,
                          toolName: String, itemType: String, at: Date = Date(timeIntervalSince1970: 100))
        -> [SessionTimeline.Activity] {
        [SessionTimeline.Activity(id: toolUseId, tone: .tool, kind: "tool.started", summary: startedSummary,
                                  detail: nil,
                                  payload: ["toolName": .string(toolName), "itemType": .string(itemType),
                                            "title": .string(startedSummary)],
                                  turnId: "t1", sequence: 1, createdAt: at),
         SessionTimeline.Activity(id: "\(toolUseId)/completed", tone: .tool, kind: "tool.completed",
                                  summary: completedSummary, detail: "12 matches",
                                  payload: ["toolName": .string(toolName), "itemType": .string(itemType),
                                            "status": .string("completed")],
                                  turnId: "t1", sequence: 2, createdAt: at.addingTimeInterval(2))]
    }

    private func makeTimeline(_ activities: [SessionTimeline.Activity]) -> SessionTimeline {
        SessionTimeline(activities: activities)
    }

    /// (a) A Grep pair collapses to the completed entry, which keeps the
    /// started summary's pattern as its label.
    func testGrepPairCollapsesToOneCompletedEntryKeepingThePattern() {
        let timeline = makeTimeline(toolPair(toolUseId: "tu1", startedSummary: "func handleAuth",
                                                     completedSummary: "Grep", toolName: "Grep",
                                                     itemType: "search"))
        let work = T3TimelineEntry.entries(from: timeline).compactMap { entry -> T3WorkLogEntry? in
            if case let .work(_, _, w) = entry { return w } else { return nil }
        }
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.sourceActivityKind, "tool.completed")
        XCTAssertEqual(work.first?.toolLifecycleStatus, .completed)
        XCTAssertEqual(work.first?.label, "func handleAuth")
        XCTAssertEqual(work.first?.detail, "12 matches")        // the completed's own fields survive
        XCTAssertNil(work.first?.toolTitle)                     // heading reads the pattern, not "Grep"
        XCTAssertEqual(T3TimelineEntry.entries(from: timeline).first?.id, "activity:tu1/completed")
        // The label no longer carries the word "grep", so `isLocalCodeSearch`
        // classifies it by the structured tool name (its documented divergence).
        XCTAssertEqual(T3WorkLog.groupAction(work[0]), .codeSearch)
    }

    /// (b) A started marker with no `/completed` twin is an in-flight call and
    /// must still produce a row.
    func testUnpairedToolStartedStillYieldsAnInFlightEntry() {
        let started = toolPair(toolUseId: "tu2", startedSummary: "rg todo", completedSummary: "Grep",
                               toolName: "Grep", itemType: "search")[0]
        let work = T3TimelineEntry.entries(from: makeTimeline([started]))
            .compactMap { entry -> T3WorkLogEntry? in
                if case let .work(_, _, w) = entry { return w } else { return nil }
            }
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.sourceActivityKind, "tool.started")
        XCTAssertNil(work.first?.toolLifecycleStatus)
        XCTAssertEqual(work.first?.label, "rg todo")
    }

    /// (c) Bash: the started summary is the flattened, 120-char-truncated
    /// command; the completed summary is the raw one. The row takes the
    /// started (display) form — the raw command stays in `detail`.
    func testBashPairWithALongCommandIsLabelledFromTheStartedSummary() {
        let raw = "for f in $(ls);\ndo\n  echo \"\(String(repeating: "x", count: 200))\"\ndone"
        let flattened = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let timeline = makeTimeline(toolPair(toolUseId: "tu3", startedSummary: flattened,
                                                     completedSummary: raw, toolName: "Bash",
                                                     itemType: "command_execution"))
        let work = T3TimelineEntry.entries(from: timeline).compactMap { entry -> T3WorkLogEntry? in
            if case let .work(_, _, w) = entry { return w } else { return nil }
        }
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.label, flattened)
        XCTAssertFalse(work.first?.label.contains("\n") ?? true)
        XCTAssertEqual(work.first?.label.count, 120)
    }

    /// (d) The regression this fixes, reproduced: the surviving statusless
    /// `tool.started` marker reads as in-flight (`isActiveTurnActivity`), so
    /// while the session works on it takes the shared live-activity row and
    /// shows the pattern as if the search were still running. Pre-fix this row
    /// was `kind=tool.started status=nil`; the live row must instead carry the
    /// completed call.
    func testACollapsedPairLeavesNoStaleLiveRowWhileTheSessionWorksOn() {
        let at = Date(timeIntervalSince1970: 100)
        let ask = SessionTimeline.Message(id: "u1", role: .user, text: "find the auth handler", images: nil,
                                          sender: nil, turnId: "t1", streaming: false,
                                          createdAt: at.addingTimeInterval(-1))
        let timeline = SessionTimeline(messages: [ask],
                                       activities: toolPair(toolUseId: "tu4", startedSummary: "func handleAuth",
                                                            completedSummary: "Grep", toolName: "Grep",
                                                            itemType: "search", at: at))
        func liveRows(isWorking: Bool) -> [(entry: T3WorkLogEntry, active: Bool)] {
            T3TimelineRows.derive(.init(entries: T3TimelineEntry.entries(from: timeline),
                                        runningTurnId: "t1", isWorking: isWorking,
                                        activeTurnStartedAt: at))
                .compactMap { row in
                    if case let .workLive(_, _, entry, _, _, _, active) = row { return (entry, active) }
                    return nil
                }
        }
        let live = liveRows(isWorking: true)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.entry.sourceActivityKind, "tool.completed")
        XCTAssertEqual(live.first?.entry.toolLifecycleStatus, .completed)
        XCTAssertEqual(live.first?.entry.label, "func handleAuth")
        // Once the session stops working the turn folds and no active live row
        // survives at all (this half already held before the fix).
        XCTAssertFalse(liveRows(isWorking: false).contains { $0.active })
    }

    func testChatMessageUpdatedAtComesFromMessage() {
        let m = SessionTimeline.Message(id: "a", role: .assistant, text: "x", images: nil, sender: nil,
                                        turnId: "t", streaming: false,
                                        createdAt: Date(timeIntervalSince1970: 10),
                                        updatedAt: Date(timeIntervalSince1970: 40))
        let c = T3ChatMessage(message: m)
        XCTAssertEqual(c.createdAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(c.updatedAt, Date(timeIntervalSince1970: 40))
    }
}
