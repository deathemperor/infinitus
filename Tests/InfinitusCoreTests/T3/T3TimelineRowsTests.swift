import XCTest
@testable import InfinitusCore

/// Transcribed from `tools/t3ref/upstream/MessagesTimeline.logic.test.ts` — one
/// method per upstream `it` (an `it.each` table becomes one method looping its
/// rows).
///
/// Not transcribed, with the reason each is inexpressible in the typed port:
/// - `describe("streaming row projection")` (7 `it`s) — exercises
///   `deriveMessagesTimelineRowsWithState`/`replaceStreamingMessageRows`, a
///   memo keyed on JavaScript object identity (`entry === previousEntry`).
///   Swift rows are values; `T3TimelineRows.stable(previous:next:)` carries the
///   intent (reuse the previous row when nothing the view reads changed).
/// - `describe("expanded tool group scrolling")` (4 `it`s) —
///   `shouldFollowWorkGroupAppend`/`resolveWorkGroupScrollIndex` are list-scroll
///   helpers outside the reducer surface the brief specifies.
/// - `describe("shouldPreserveAssistantLineBreaks")` (1) and
///   `describe("resolveAssistantMessageCopyState")` (5) — the latter needs
///   `renderCodexDirectivesForCopy`, which is not vendored; neither is in the
///   ported interface.
///
/// Adaptations disclosed at their call sites: upstream's rich `toolIcon`
/// (a website/native-app descriptor) has no field in the ported row, and the
/// `computeStableMessagesTimelineRows` assertions turn reference identity
/// (`toBe`) into value equality (`==`).
final class T3TimelineRowsTests: XCTestCase {
    private func d(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    private func at(_ sec: Int) -> Date { d("2026-01-01T00:00:00Z").addingTimeInterval(TimeInterval(sec)) }

    private func user(_ id: String, _ s: Int) -> T3TimelineEntry {
        .message(id: "\(id)-entry", createdAt: at(s),
                 T3ChatMessage(id: id, role: .user, text: id, turnId: nil, streaming: false,
                               createdAt: at(s), updatedAt: at(s)))
    }
    private func assistant(_ id: String, turn: String?, _ s: Int, updated u: Int,
                           streaming: Bool = false) -> T3TimelineEntry {
        .message(id: "\(id)-entry", createdAt: at(s),
                 T3ChatMessage(id: id, role: .assistant, text: id, turnId: turn, streaming: streaming,
                               createdAt: at(s), updatedAt: at(u)))
    }
    private func work(_ id: String, turn: String?, _ s: Int, _ label: String,
                      tone: T3WorkLogEntry.Tone = .tool,
                      _ build: (inout T3WorkLogEntry) -> Void = { _ in }) -> T3TimelineEntry {
        var e = T3WorkLogEntry(id: id, createdAt: at(s), label: label, tone: tone)
        e.turnId = turn
        build(&e)
        return .work(id: id, createdAt: at(s), e)
    }
    private func rows(_ entries: [T3TimelineEntry], working: Bool = false, startedAt: Int? = nil,
                      _ tweak: (inout T3TimelineRows.Input) -> Void = { _ in }) -> [T3TimelineRows.Row] {
        var i = T3TimelineRows.Input(entries: entries, isWorking: working,
                                     activeTurnStartedAt: startedAt.map(at))
        tweak(&i)
        return T3TimelineRows.derive(i)
    }
    private func assistantRows(_ rows: [T3TimelineRows.Row]) -> [T3TimelineRows.Row] {
        rows.filter { if case let .message(_, _, m, _, _, _, _, _, _) = $0 { return m.role == .assistant }
                      else { return false } }
    }

    // MARK: - describe("work entry labels")

    private var labelEntry: T3WorkLogEntry {
        T3WorkLogEntry(id: "tool-1", createdAt: d("2026-09-01T12:00:00Z"), label: "Tool call", tone: .tool)
    }

    /// `it.each([...])("uses the same friendly %s label in both views")`
    func testUsesTheSameFriendlyLabelInBothViews() {
        let cases: [(T3WorkLogEntry.LifecycleStatus, String)] = [
            (.inProgress, "Clicking in the preview browser"),
            (.completed, "Clicked in the preview browser"),
            (.failed, "Failed to click in the preview browser"),
            (.declined, "Declined to click in the preview browser"),
            (.stopped, "Stopped clicking in the preview browser"),
        ]
        for (status, label) in cases {
            var entry = labelEntry
            entry.toolTitle = "T3-code.preview_click"
            entry.detail = "{\"ok\":true}"
            entry.toolLifecycleStatus = status
            XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: status == .inProgress), label)
            XCTAssertEqual(T3WorkLog.displayLabel(entry, workspaceRoot: nil), label)
        }
    }

    /// `it("uses the active summary state for legacy tools without a lifecycle status")`
    func testUsesTheActiveSummaryStateForLegacyToolsWithoutALifecycleStatus() {
        var entry = labelEntry
        entry.toolTitle = "T3-code.preview_click"
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), "Clicking in the preview browser")
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: false), "Clicked in the preview browser")
    }

    /// `it("keeps the latest live activity in the present tense after the call completes")`
    func testKeepsTheLatestLiveActivityInThePresentTenseAfterTheCallCompletes() {
        var entry = labelEntry
        entry.toolTitle = "T3-code.preview_click"
        entry.toolLifecycleStatus = .completed
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), "Clicking in the preview browser")
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: false), "Clicked in the preview browser")
    }

    /// `it("keeps custom titles and output for unrecognized tools")`
    func testKeepsCustomTitlesAndOutputForUnrecognizedTools() {
        var entry = labelEntry
        entry.toolTitle = "mcp__github__search_issues"
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), "Mcp__github__search_issues")
        var withDetail = entry
        withDetail.detail = "Found 3 issues"
        XCTAssertEqual(T3WorkLog.displayLabel(withDetail, workspaceRoot: nil), "Found 3 issues")
    }

    /// `it("keeps command summaries compact without replacing the full command in expanded rows")`
    func testKeepsCommandSummariesCompactWithoutReplacingTheFullCommandInExpandedRows() {
        var entry = labelEntry
        entry.command = "vp test run"
        entry.detail = "All tests passed"
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), "Running vp")
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: false), "Ran vp")
        XCTAssertEqual(T3WorkLog.displayLabel(entry, workspaceRoot: nil), "vp test run")
    }

    /// `it("summarizes the program inside a shell wrapper while preserving the expanded command")`
    func testSummarizesTheProgramInsideAShellWrapperWhilePreservingTheExpandedCommand() {
        let command = "/bin/zsh -lc 'vp test run apps/web/src/session-logic.test.ts'"
        var entry = labelEntry
        entry.command = command
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), "Running vp")
        XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: false), "Ran vp")
        XCTAssertEqual(T3WorkLog.displayLabel(entry, workspaceRoot: nil), command)
    }

    /// `it.each([...])("uses present tense for a live %s command and the outcome once it is no longer live")`
    func testUsesPresentTenseForALiveCommandAndTheOutcomeOnceItIsNoLongerLive() {
        let cases: [(T3WorkLogEntry.LifecycleStatus, String, String)] = [
            (.inProgress, "Running vp", "Running vp"),
            (.completed, "Running vp", "Ran vp"),
            (.failed, "Failed vp", "Failed vp"),
            (.declined, "Declined vp", "Declined vp"),
            (.stopped, "Stopped vp", "Stopped vp"),
        ]
        for (status, live, settled) in cases {
            var entry = labelEntry
            entry.command = "/bin/bash -lc 'vp test run'"
            entry.toolLifecycleStatus = status
            XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: true), live, "\(status)")
            XCTAssertEqual(T3WorkLog.liveLabel(entry, workspaceRoot: nil, active: false), settled, "\(status)")
        }
    }

    /// `it.each([...])("renders a settled legacy %s call directly with its completed presentation")`
    func testRendersASettledLegacyCallDirectlyWithItsCompletedPresentation() {
        for (tool, label) in [("preview_click", "Clicked in the preview browser"),
                              ("task_status", "Got delegated task status")] {
            var entry = labelEntry
            entry.itemType = .mcpToolCall
            entry.toolName = "t3-code.\(tool)"
            let derived = rows([.work(id: "browser-entry", createdAt: entry.createdAt, entry)])
            guard case let .work(_, _, grouped, isExpanded, displayLabel)? = derived.first(where: { $0.kind == "work" })
            else { return XCTFail("no work row for \(tool)") }
            XCTAssertEqual(grouped.map(\.id), ["tool-1"])
            XCTAssertFalse(isExpanded)
            XCTAssertEqual(displayLabel, label)
        }
    }

    // MARK: - describe("computeMessageDurationStart")

    private func durationMessage(_ id: String, _ role: T3ChatMessage.Role, _ createdAt: String,
                                 _ updatedAt: String, streaming: Bool = false) -> T3ChatMessage {
        T3ChatMessage(id: id, role: role, text: "", turnId: nil, streaming: streaming,
                      createdAt: d(createdAt), updatedAt: d(updatedAt))
    }

    /// `it("returns message createdAt when there is no preceding user message")`
    func testReturnsMessageCreatedAtWhenThereIsNoPrecedingUserMessage() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("a1", .assistant, "2026-01-01T00:00:05Z", "2026-01-01T00:00:10Z"),
        ])
        XCTAssertEqual(result, ["a1": d("2026-01-01T00:00:05Z")])
    }

    /// `it("uses the user message createdAt for the first assistant response")`
    func testUsesTheUserMessageCreatedAtForTheFirstAssistantResponse() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("u1", .user, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
            durationMessage("a1", .assistant, "2026-01-01T00:00:30Z", "2026-01-01T00:00:30Z"),
        ])
        XCTAssertEqual(result, ["u1": d("2026-01-01T00:00:00Z"), "a1": d("2026-01-01T00:00:00Z")])
    }

    /// `it("uses the previous completed assistant updatedAt for subsequent assistant responses")`
    func testUsesThePreviousCompletedAssistantUpdatedAtForSubsequentAssistantResponses() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("u1", .user, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
            durationMessage("a1", .assistant, "2026-01-01T00:00:30Z", "2026-01-01T00:00:30Z"),
            durationMessage("a2", .assistant, "2026-01-01T00:00:55Z", "2026-01-01T00:00:55Z"),
        ])
        XCTAssertEqual(result, ["u1": d("2026-01-01T00:00:00Z"), "a1": d("2026-01-01T00:00:00Z"),
                                "a2": d("2026-01-01T00:00:30Z")])
    }

    /// `it("does not advance the boundary for a streaming message")`
    func testDoesNotAdvanceTheBoundaryForAStreamingMessage() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("u1", .user, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
            durationMessage("a1", .assistant, "2026-01-01T00:00:30Z", "2026-01-01T00:00:40Z", streaming: true),
            durationMessage("a2", .assistant, "2026-01-01T00:00:55Z", "2026-01-01T00:00:55Z"),
        ])
        XCTAssertEqual(result, ["u1": d("2026-01-01T00:00:00Z"), "a1": d("2026-01-01T00:00:00Z"),
                                "a2": d("2026-01-01T00:00:00Z")])
    }

    /// `it("resets the boundary on a new user message")`
    func testResetsTheBoundaryOnANewUserMessage() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("u1", .user, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
            durationMessage("a1", .assistant, "2026-01-01T00:00:30Z", "2026-01-01T00:00:30Z"),
            durationMessage("u2", .user, "2026-01-01T00:01:00Z", "2026-01-01T00:01:00Z"),
            durationMessage("a2", .assistant, "2026-01-01T00:01:20Z", "2026-01-01T00:01:20Z"),
        ])
        XCTAssertEqual(result, ["u1": d("2026-01-01T00:00:00Z"), "a1": d("2026-01-01T00:00:00Z"),
                                "u2": d("2026-01-01T00:01:00Z"), "a2": d("2026-01-01T00:01:00Z")])
    }

    /// `it("handles system messages without affecting the boundary")`
    func testHandlesSystemMessagesWithoutAffectingTheBoundary() {
        let result = T3TimelineRows.messageDurationStart([
            durationMessage("u1", .user, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
            durationMessage("s1", .system, "2026-01-01T00:00:01Z", "2026-01-01T00:00:01Z"),
            durationMessage("a1", .assistant, "2026-01-01T00:00:30Z", "2026-01-01T00:00:30Z"),
        ])
        XCTAssertEqual(result, ["u1": d("2026-01-01T00:00:00Z"), "s1": d("2026-01-01T00:00:00Z"),
                                "a1": d("2026-01-01T00:00:00Z")])
    }

    /// `it("returns empty map for empty input")`
    func testReturnsEmptyMapForEmptyInput() {
        XCTAssertEqual(T3TimelineRows.messageDurationStart([]), [:])
    }

    // MARK: - describe("normalizeCompactToolLabel")

    /// `it("removes trailing completion wording from command labels")`
    func testRemovesTrailingCompletionWordingFromCommandLabels() {
        XCTAssertEqual(T3WorkLog.normalizeCompactToolLabel("Ran command complete"), "Ran command")
    }

    /// `it("removes trailing completion wording from other labels")`
    func testRemovesTrailingCompletionWordingFromOtherLabels() {
        XCTAssertEqual(T3WorkLog.normalizeCompactToolLabel("Read file completed"), "Read file")
    }

    // MARK: - describe("deriveMessagesTimelineRows")

    /// T1 `it("keeps context compaction visible outside folded work")`
    func testKeepsContextCompactionVisibleOutsideFoldedWork() {
        let r = rows([work("compaction-entry", turn: nil, 0, "Compacted context 899K → 19K tokens", tone: .info) {
            $0.sourceActivityKind = "context-compaction"
        }])
        XCTAssertEqual(r, [.contextCompaction(id: "compaction-entry", createdAt: at(0),
                                              label: "Compacted context 899K → 19K tokens")])
    }

    /// T2 `it("only enables assistant copy for the terminal assistant message in a turn")`
    /// and T22 `it("only shows assistant metadata on the terminal assistant message")`
    func testOnlyTerminalAssistantMessageShowsMetaAndCopy() {
        let r = rows([user("user-1", 0), assistant("assistant-thought", turn: "turn-1", 10, updated: 11),
                      assistant("assistant-final", turn: "turn-1", 20, updated: 30)]) {
            $0.expandedTurnIds = ["turn-1"]
        }
        let msgs = r.compactMap { row -> (Bool, Bool)? in
            if case let .message(_, _, m, _, meta, copy, _, _, _) = row, m.role == .assistant {
                return (meta, copy)
            }
            return nil
        }
        XCTAssertEqual(msgs.map(\.0), [false, true])
        XCTAssertEqual(msgs.map(\.1), [false, true])
    }

    /// T3 `it("marks only the active assistant turn as streaming for copy controls")`
    func testOnlyTheActiveTurnStreamsForCopy() {
        let r = rows([assistant("assistant-one", turn: "turn-1", 10, updated: 11),
                      assistant("assistant-two", turn: "turn-2", 20, updated: 30)]) {
            $0.latestTurn = .init(turnId: "turn-2", state: .running, startedAt: self.at(19), completedAt: nil)
        }
        let streaming = r.compactMap { row -> Bool? in
            if case let .message(_, _, _, _, _, _, s, _, _) = row { return s } else { return nil }
        }
        XCTAssertEqual(streaming, [false, true])
    }

    /// T4 `it("projects assistant diff summaries and user revert counts onto the affected rows")`
    func testProjectsAssistantDiffSummariesAndUserRevertCounts() {
        let summary = T3TimelineRows.TurnDiffSummary(turnId: "turn-1", checkpointTurnCount: 2,
                                                     assistantMessageId: "assistant-1",
                                                     completedAt: at(30), files: ["src/index.ts"])
        let r = rows([user("user-1", 0), assistant("assistant-1", turn: "turn-1", 20, updated: 30)]) {
            $0.turnDiffSummaries = [summary]
            $0.supportsConversationRollback = true
        }
        var userRevert: Int?
        var assistantSummary: T3TimelineRows.TurnDiffSummary?
        for row in r {
            guard case let .message(_, _, m, _, _, _, _, diff, revert) = row else { continue }
            if m.role == .user { userRevert = revert } else { assistantSummary = diff }
        }
        XCTAssertEqual(userRevert, 1)
        XCTAssertEqual(assistantSummary, summary)
    }

    /// T5 `it("folds the first assistant message and settled work before the terminal response")`
    func testFoldsSettledWorkBeforeTheTerminalResponse() {
        let entries = [user("user-1", 0), assistant("assistant-first", turn: "turn-1", 5, updated: 6),
                       work("work-entry-1", turn: "turn-1", 8, "Ran command"),
                       assistant("assistant-final", turn: "turn-1", 20, updated: 22)]
        let collapsed = rows(entries)
        XCTAssertEqual(collapsed.map(\.id), ["user-1-entry", "turn-fold:turn-1", "assistant-final-entry"])
        XCTAssertEqual(collapsed[1], .turnFold(id: "turn-fold:turn-1", createdAt: at(5), turnId: "turn-1",
                                               label: "Worked for 22s", expanded: false))
        let expanded = rows(entries) { $0.expandedTurnIds = ["turn-1"] }
        XCTAssertEqual(expanded.map(\.id), ["user-1-entry", "turn-fold:turn-1", "assistant-first-entry",
                                            "work-entry-1", "assistant-final-entry"])
        XCTAssertTrue(expanded.contains { if case let .turnFold(_, _, _, _, e) = $0 { return e } else { return false } })
    }

    /// T6 `it("keeps a tool group after the terminal response visible when the turn is folded")`
    func testTrailingToolGroupStaysVisibleAndCarriesTheMeta() {
        var entries = [work("work-entry-before-text", turn: "turn-1", 1, "Status updated", tone: .info),
                       assistant("assistant-final", turn: "turn-1", 5, updated: 6)]
        for i in 0..<3 {
            entries.append(work("work-entry-after-text-\(i)", turn: "turn-1", 7 + i, "Ran command") {
                $0.itemType = .commandExecution
                $0.toolLifecycleStatus = .completed
            })
        }
        let r = rows(entries) {
            $0.latestTurn = .init(turnId: "turn-1", state: .error, startedAt: self.at(0), completedAt: self.at(10))
        }
        XCTAssertEqual(r.map(\.id), ["turn-fold:turn-1", "assistant-final-entry",
                                     "work-toggle:work-entry-after-text-0", "assistant-meta:assistant-final"])
        guard case let .workToggle(_, _, _, _, hidden, _, summary, _, _, _, _) = r[2] else { return XCTFail() }
        XCTAssertEqual(hidden, 3)
        XCTAssertEqual(summary, "Ran 3 commands")
        guard case let .message(_, _, _, _, meta, copy, _, _, _) = r[1] else { return XCTFail() }
        XCTAssertFalse(meta)
        XCTAssertFalse(copy)
        guard case let .assistantMeta(_, _, metaMessage, metaCopy, _) = r[3] else { return XCTFail() }
        XCTAssertEqual(metaMessage.id, "assistant-final")
        XCTAssertTrue(metaCopy)
        let single = rows(Array(entries.prefix(3))) {
            $0.latestTurn = .init(turnId: "turn-1", state: .error, startedAt: self.at(0), completedAt: self.at(10))
        }
        XCTAssertEqual(single.map(\.id), ["turn-fold:turn-1", "assistant-final-entry"])
    }

    /// T7 `it("folds all assistant messages before the terminal message")`
    func testFoldsAllAssistantMessagesBeforeTheTerminalMessage() {
        let r = rows([assistant("assistant-first", turn: "turn-1", 1, updated: 2),
                      assistant("assistant-middle", turn: "turn-1", 3, updated: 4),
                      assistant("assistant-final", turn: "turn-1", 5, updated: 6)])
        XCTAssertEqual(r.map(\.id), ["turn-fold:turn-1", "assistant-final-entry"])
    }

    /// T8 `it("derives a sane duration for a steer-superseded turn with one instant commentary message")`
    func testDerivesASaneDurationForASteerSupersededTurn() {
        let r = rows([user("user-1", 0),
                      work("work-entry-before-message", turn: "turn-1", 7, "Status updated", tone: .info),
                      assistant("assistant-commentary", turn: "turn-1", 9, updated: 9),
                      work("work-entry-1", turn: "turn-1", 12, "Ran command"),
                      user("user-2", 14),
                      assistant("assistant-next", turn: "turn-2", 17, updated: 17, streaming: true)],
                     working: true, startedAt: 14) {
            $0.latestTurn = .init(turnId: "turn-2", state: .running, startedAt: self.at(14), completedAt: nil)
        }
        guard case let .turnFold(_, _, turnId, label, _)? = r.first(where: { $0.kind == "turn-fold" })
        else { return XCTFail("no fold") }
        XCTAssertEqual(turnId, "turn-1")
        XCTAssertEqual(label, "Worked for 12s")
    }

    /// T9 `it("uses latest-turn timings and the stopped label for an interrupted latest turn")`
    func testInterruptedLatestTurnUsesTheStoppedLabel() {
        let r = rows([work("work-entry-1", turn: "turn-1", 5, "Ran command")]) {
            $0.latestTurn = .init(turnId: "turn-1", state: .interrupted, startedAt: self.at(0),
                                  completedAt: self.at(47))
        }
        XCTAssertEqual(r, [.turnFold(id: "turn-fold:turn-1", createdAt: at(5), turnId: "turn-1",
                                     label: "You stopped after 47s", expanded: false)])
    }

    /// T10 `it("keeps the previous turn folded while a newly sent message awaits its turn")`
    func testKeepsThePreviousTurnFoldedWhileANewlySentMessageAwaitsItsTurn() {
        let r = rows([work("work-entry-1", turn: "turn-1", 5, "Ran command"),
                      assistant("assistant-final", turn: "turn-1", 20, updated: 22),
                      user("user-followup", 60)], working: true, startedAt: 60) {
            $0.latestTurn = .init(turnId: "turn-1", state: .completed, startedAt: self.at(0),
                                  completedAt: self.at(22))
        }
        XCTAssertEqual(r.map(\.id), ["turn-fold:turn-1", "assistant-final-entry", "user-followup-entry",
                                     "working-indicator-row", "live-activity-row"])
        guard case let .message(_, _, _, _, meta, _, _, _, _)? = r.first(where: { $0.id == "assistant-final-entry" })
        else { return XCTFail() }
        XCTAssertTrue(meta)
        XCTAssertEqual(r.last?.kind, "thinking")
    }

    /// T11 `it("does not fold the active in-progress turn")`
    func testDoesNotFoldTheActiveInProgressTurn() {
        let r = rows([assistant("assistant-thought", turn: "turn-1", 5, updated: 6),
                      work("work-entry-1", turn: "turn-1", 8, "Ran command")], working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        XCTAssertFalse(r.contains { $0.kind == "turn-fold" })
        XCTAssertEqual(r.map(\.id), ["working-indicator-row", "assistant-thought-entry", "live-activity-row"])
    }

    /// T12 `it("keeps a promptless restart in one active visual response")`
    func testKeepsAPromptlessRestartInOneActiveVisualResponse() {
        let r = rows([user("user-1", 0),
                      work("old-work-entry", turn: "turn-before-restart", 5, "Searched files") {
                          $0.id = "old-work"; $0.command = "rg restart"; $0.toolLifecycleStatus = .completed },
                      work("old-stale-work-entry", turn: "turn-before-restart", 6, "Running stale command") {
                          $0.id = "old-stale-work"; $0.command = "rg stale"; $0.toolLifecycleStatus = .inProgress },
                      assistant("old-commentary", turn: "turn-before-restart", 8, updated: 8),
                      work("new-work-entry", turn: "turn-after-restart", 65, "Running tests") {
                          $0.id = "new-work"; $0.command = "vp test run"; $0.toolLifecycleStatus = .inProgress }],
                     working: true, startedAt: 60) {
            $0.latestTurn = .init(turnId: "turn-after-restart", state: .running, startedAt: self.at(60),
                                  completedAt: nil)
        }
        XCTAssertFalse(r.contains { $0.kind == "turn-fold" })
        XCTAssertEqual(r.filter { $0.id == "working-indicator-row" }.count, 1)
        let workingIndex = r.firstIndex { $0.id == "working-indicator-row" }
        let oldWorkIndex = r.firstIndex { $0.id == "old-work-entry" }
        XCTAssertNotNil(oldWorkIndex)
        XCTAssertTrue((workingIndex ?? .max) < (oldWorkIndex ?? 0))
        guard case let .working(_, createdAt)? = r.first(where: { $0.id == "working-indicator-row" })
        else { return XCTFail() }
        XCTAssertEqual(createdAt, at(0))
        guard case let .message(_, _, _, _, meta, copy, streaming, _, _)? = r.first(where: { $0.id == "old-commentary-entry" })
        else { return XCTFail() }
        XCTAssertFalse(meta)
        XCTAssertFalse(copy)
        XCTAssertTrue(streaming)
        let live = r.compactMap { row -> String? in
            if case let .workLive(_, _, entry, _, _, _, active) = row, active { return entry.id } else { return nil }
        }
        XCTAssertEqual(live, ["new-work"])
        XCTAssertFalse(r.contains { $0.kind == "thinking" })
    }

    /// T13 `it("keeps an actually running tool in the shared activity row")`
    func testKeepsAnActuallyRunningToolInTheSharedActivityRow() {
        let r = rows([work("running-command-entry", turn: "turn-1", 5, "Running rg") {
                          $0.id = "running-command"; $0.command = "rg toolCall"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress },
                      work("completed-edit-entry", turn: "turn-1", 6, "Edited files") {
                          $0.id = "completed-edit"; $0.requestKind = .fileChange
                          $0.changedFiles = ["src/one.ts", "src/two.ts"]; $0.toolLifecycleStatus = .completed },
                      work("completed-command-entry", turn: "turn-1", 7, "Ran tests") {
                          $0.id = "completed-command"; $0.command = "vp test run"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .completed }],
                     working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        XCTAssertEqual(r.map(\.kind), ["working", "work-live"])
        XCTAssertFalse(r.contains { $0.kind == "thinking" })
        guard case let .workLive(_, _, entry, grouped, _, _, active) = r[1] else { return XCTFail() }
        XCTAssertEqual(entry.id, "running-command")
        XCTAssertTrue(active)
        XCTAssertEqual(grouped.map(\.id), ["running-command", "completed-edit", "completed-command"])
    }

    /// T14 `it("renders a single completed tool call directly")`
    func testRendersASingleCompletedToolCallDirectly() {
        let r = rows([work("completed-command-entry", turn: "turn-1", 5, "Ran rg") {
                          $0.id = "completed-command"; $0.command = "rg toolCall"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .completed },
                      assistant("assistant-commentary", turn: "turn-1", 6, updated: 6),
                      work("running-command-entry", turn: "turn-1", 7, "Running tests") {
                          $0.id = "running-command"; $0.command = "vp test run"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress }],
                     working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        XCTAssertEqual(r.map(\.kind), ["working", "work", "message", "work-live"])
        guard case let .work(_, _, grouped, isExpanded, displayLabel)? = r.first(where: { $0.kind == "work" })
        else { return XCTFail() }
        XCTAssertEqual(grouped.map(\.id), ["completed-command"])
        XCTAssertEqual(grouped.first?.command, "rg toolCall")
        XCTAssertFalse(isExpanded)
        XCTAssertEqual(displayLabel, "rg toolCall")
    }

    /// T15 `it("renders one tool call directly after collapsing its lifecycle updates")`
    func testRendersOneToolCallDirectlyAfterCollapsingItsLifecycleUpdates() {
        let r = rows([work("command-started-entry", turn: "turn-1", 5, "Running rg") {
                          $0.id = "command-started"; $0.toolCallId = "call-1"; $0.command = "rg toolCall"
                          $0.itemType = .commandExecution; $0.toolLifecycleStatus = .inProgress },
                      work("command-completed-entry", turn: "turn-1", 6, "Ran rg") {
                          $0.id = "command-completed"; $0.toolCallId = "call-1"; $0.command = "rg toolCall"
                          $0.itemType = .commandExecution; $0.toolLifecycleStatus = .completed }]) {
            $0.expandedTurnIds = ["turn-1"]
        }
        guard case let .work(_, _, grouped, isExpanded, displayLabel)? = r.first(where: { $0.kind == "work" })
        else { return XCTFail() }
        XCTAssertEqual(grouped.map(\.id), ["command-completed"])
        XCTAssertEqual(grouped.first?.toolCallId, "call-1")
        XCTAssertFalse(isExpanded)
        XCTAssertEqual(displayLabel, "rg toolCall")
        XCTAssertFalse(r.contains { $0.kind == "work-toggle" })
    }

    /// T16 `it("keeps separated in-progress tool runs visible")`
    func testKeepsSeparatedInProgressToolRunsVisible() {
        let r = rows([work("first-running-entry", turn: "turn-1", 5, "Running first command") {
                          $0.id = "first-running"; $0.command = "rg first"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress },
                      assistant("assistant-commentary", turn: "turn-1", 6, updated: 6),
                      work("second-running-entry", turn: "turn-1", 7, "Running second command") {
                          $0.id = "second-running"; $0.command = "rg second"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress }],
                     working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        XCTAssertEqual(r.map(\.kind), ["working", "work-live", "message", "work-live"])
        let live = r.compactMap { row -> String? in
            if case let .workLive(_, _, entry, _, _, _, _) = row { return entry.id } else { return nil }
        }
        XCTAssertEqual(live, ["first-running", "second-running"])
    }

    /// T17 `it("does not revive stale in-progress tools before a fresh send has a turn id")`
    func testDoesNotReviveStaleInProgressToolsBeforeAFreshSendHasATurnId() {
        let r = rows([work("stale-running-entry", turn: "turn-1", 5, "Running stale command") {
                          $0.id = "stale-running"; $0.command = "rg stale"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress },
                      user("user-followup", 60)], working: true, startedAt: 60)
        XCTAssertFalse(r.contains { $0.kind == "work-live" })
    }

    /// T18 `it("does not revive separated historical task progress")`
    func testDoesNotReviveSeparatedHistoricalTaskProgress() {
        let r = rows([work("stale-progress-entry", turn: "turn-1", 5, "Old progress", tone: .thinking) {
                          $0.id = "stale-progress"; $0.sourceActivityKind = "task.progress" },
                      assistant("assistant-commentary", turn: "turn-1", 6, updated: 6),
                      work("running-command-entry", turn: "turn-1", 7, "Running command") {
                          $0.id = "running-command"; $0.command = "rg current"; $0.requestKind = .command
                          $0.toolLifecycleStatus = .inProgress }],
                     working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        let live = r.compactMap { row -> String? in
            if case let .workLive(_, _, entry, _, _, _, _) = row { return entry.id } else { return nil }
        }
        XCTAssertEqual(live, ["running-command"])
    }

    /// T19 `it.each([...])("respects the %s lifecycle of trailing task progress")`
    /// (with T20's "one live-activity row" invariant folded in, as in the brief)
    func testTrailingTaskProgressLifecycle() {
        let cases: [(T3WorkLogEntry.LifecycleStatus?, Bool?)] = [
            (nil, true), (.inProgress, true), (.completed, false), (.failed, nil), (.declined, false),
            (.stopped, false),
        ]
        for (status, active) in cases {
            let r = rows([work("task-progress", turn: "turn-task-progress", 5, "Task progress", tone: .thinking) {
                              $0.sourceActivityKind = "task.progress"; $0.toolLifecycleStatus = status }],
                         working: true, startedAt: 0) {
                $0.latestTurn = .init(turnId: "turn-task-progress", state: .running, startedAt: self.at(0),
                                      completedAt: nil)
            }
            let live = r.compactMap { row -> Bool? in
                if case let .workLive(_, _, _, _, _, _, a) = row { return a } else { return nil }
            }
            XCTAssertEqual(live.first, active, "\(String(describing: status))")
            if active == nil {
                XCTAssertEqual(r.last?.id, T3TimelineRows.liveActivityRowId)
                XCTAssertEqual(r.last?.kind, "thinking")
            }
            XCTAssertEqual(r.filter { $0.id == T3TimelineRows.liveActivityRowId }.count, 1)
        }
    }

    /// T20 `it("reuses one activity row for initial thinking and the latest tool")`
    func testOneLiveActivityRow() {
        func derive(_ status: T3WorkLogEntry.LifecycleStatus?) -> [T3TimelineRows.Row] {
            let entries = status == nil ? [] : [work("latest-command", turn: "turn-1", 5,
                                                     status == .inProgress ? "Running rg" : "Ran rg") {
                $0.command = "rg toolCall"; $0.requestKind = .command; $0.toolLifecycleStatus = status
                if status == .inProgress { $0.detail = "exit code 1" }
            }]
            return rows(entries, working: true, startedAt: 0) {
                $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
            }
        }
        XCTAssertEqual(derive(nil).first { $0.id == T3TimelineRows.liveActivityRowId }?.kind, "thinking")
        XCTAssertEqual(derive(.inProgress).first { $0.id == T3TimelineRows.liveActivityRowId }?.kind, "work-live")
        XCTAssertEqual(derive(.completed).first { $0.id == T3TimelineRows.liveActivityRowId }?.kind, "work-live")
        XCTAssertEqual(derive(.failed).last?.kind, "thinking")
        XCTAssertFalse(derive(.failed).contains { $0.kind == "work-live" })
        XCTAssertEqual(derive(.declined).last?.kind, "thinking")
        let declinedLive = derive(.declined).compactMap { row -> Bool? in
            if case let .workLive(_, _, _, _, _, _, a) = row { return a } else { return nil }
        }
        XCTAssertEqual(declinedLive, [false])
        for s in [nil, .inProgress, .completed, .failed, .declined] as [T3WorkLogEntry.LifecycleStatus?] {
            XCTAssertEqual(derive(s).filter { $0.id == T3TimelineRows.liveActivityRowId }.count, 1)
        }
    }

    /// T21 `it("does not fold the session's running turn when latestTurn regresses")`
    func testRunningTurnIdWinsOverARegressedLatestTurn() {
        let r = rows([work("previous-work", turn: "turn-1", 5, "Read files"), user("user-followup", 60),
                      work("running-work", turn: "turn-2", 65, "Searched files")],
                     working: true, startedAt: 60) {
            $0.latestTurn = .init(turnId: "turn-1", state: .completed, startedAt: self.at(0),
                                  completedAt: self.at(25))
            $0.runningTurnId = "turn-2"
        }
        let folds = r.compactMap { row -> String? in
            if case let .turnFold(_, _, t, _, _) = row { return t } else { return nil }
        }
        XCTAssertEqual(folds, ["turn-1"])
        XCTAssertTrue(r.contains { $0.id == T3TimelineRows.liveActivityRowId })
    }

    /// T23 `it("withholds assistant metadata while the active turn is still in progress")`
    func testWithholdsAssistantMetadataWhileTheActiveTurnIsStillInProgress() {
        let r = rows([assistant("assistant-thought", turn: "turn-1", 10, updated: 11)],
                     working: true, startedAt: 0) {
            $0.latestTurn = .init(turnId: "turn-1", state: .running, startedAt: self.at(0), completedAt: nil)
        }
        guard case let .message(_, _, _, _, meta, copy, _, _, _)? = assistantRows(r).first else { return XCTFail() }
        XCTAssertFalse(meta)
        XCTAssertFalse(copy)
        XCTAssertEqual(r.last?.kind, "thinking")
    }

    /// T24 `it.each([...])("expands %s through the same activity group")`
    /// Adapted: the ported row carries no rich `toolIcon` descriptor, so the
    /// upstream `toolIcon` assertion is dropped; `toolSurface` is asserted.
    func testExpandsAnActivityGroupInPlace() {
        for (tone, summary) in [(T3WorkLogEntry.Tone.tool, "Used 3 tools"),
                                (.info, "Used 2 tools and received 1 update")] {
            let entries = [work("work-entry-1", turn: nil, 1, "read") { $0.id = "work-1"; $0.detail = "Reading package.json" },
                           work("work-entry-2", turn: nil, 2, "Status updated", tone: tone) {
                               $0.id = "work-2"; $0.detail = "Editing MessagesTimeline.tsx"; $0.toolSurface = "computer" },
                           work("work-entry-3", turn: nil, 3, "test") {
                               $0.id = "work-3"; $0.detail = "Running tests"; $0.toolSurface = "browser" }]
            let collapsed = rows(entries)
            XCTAssertEqual(collapsed.map(\.id), ["work-toggle:work-entry-1"])
            guard case let .workToggle(_, _, _, groupId, hidden, expanded, s, _, surface, _, _) = collapsed[0]
            else { return XCTFail() }
            XCTAssertEqual(groupId, "work-group:work-entry-1")
            XCTAssertEqual(hidden, 3)
            XCTAssertFalse(expanded)
            XCTAssertEqual(s, summary)
            XCTAssertEqual(surface, "browser")
            let open = rows(entries) { $0.expandedWorkGroupIds = ["work-group:work-entry-1"] }
            XCTAssertEqual(open.map(\.id), ["work-toggle:work-entry-1", "work-group:work-entry-1:details"])
            guard case let .work(_, _, grouped, isExpanded, _) = open[1] else { return XCTFail() }
            XCTAssertTrue(isExpanded)
            XCTAssertEqual(grouped.map(\.id), ["work-1", "work-2", "work-3"])
            guard case let .workToggle(_, _, _, _, _, openExpanded, _, _, _, _, _) = open[0] else { return XCTFail() }
            XCTAssertTrue(openExpanded)
        }
    }

    /// T25 `it("deduplicates integration sources and uses the first source icon for the group")`
    /// Adapted: no `toolIcon` field in the ported row (see T24).
    func testDeduplicatesIntegrationSourcesForTheGroup() {
        let chrome = T3WorkLogEntry.ToolSource(key: "browser-use:chrome", name: "Chrome", kind: "integration")
        let r = rows([work("browser-1", turn: nil, 1, "Open MATLAB") {
                          $0.toolSurface = "browser"; $0.toolSource = chrome },
                      work("browser-2", turn: nil, 2, "Show summary") {
                          $0.toolSurface = "browser"; $0.toolSource = chrome },
                      work("command-1", turn: nil, 3, "Ran command") {
                          $0.command = "git status"; $0.itemType = .commandExecution }])
        guard case let .workToggle(_, _, _, _, _, _, summary, _, surface, _, _) = r[0] else { return XCTFail() }
        XCTAssertEqual(summary, "Used Chrome integration and ran 1 command")
        XCTAssertEqual(surface, "browser")
    }

    /// `it.each([true, false])("keeps a large expanded tool run inside one timeline item, live=%s")`
    func testKeepsALargeExpandedToolRunInsideOneTimelineItem() {
        for isWorking in [true, false] {
            let turnId = "turn-many-tools"
            let entries = (0..<1_000).map { index -> T3TimelineEntry in
                work("tool-entry-\(index)", turn: turnId, 0, "t3-code.preview_snapshot") {
                    $0.id = "tool-\(index)"
                    $0.toolCallId = "call-\(index)"
                    $0.toolLifecycleStatus = isWorking && index == 999 ? .inProgress : .completed
                }
            }
            let groupId = "work-group:tool:\(turnId):call-0"
            func derive(_ expandedGroups: Set<String>) -> [T3TimelineRows.Row] {
                rows(entries, working: isWorking, startedAt: isWorking ? 0 : nil) {
                    $0.expandedTurnIds = [turnId]
                    $0.runningTurnId = isWorking ? turnId : nil
                    $0.expandedWorkGroupIds = expandedGroups
                }
            }
            let groupRows = derive([groupId]).filter { $0.kind == "work" }
            XCTAssertEqual(groupRows.count, 1, "live=\(isWorking)")
            guard case let .work(id, _, grouped, _, _)? = groupRows.first else { return XCTFail() }
            XCTAssertEqual(grouped.map(\.id), (0..<1_000).map { "tool-\($0)" })
            XCTAssertEqual(id, "\(groupId):details")
            XCTAssertFalse(derive([]).contains { $0.kind == "work" })
        }
    }

    /// `it.each([...])("uses the final call for %s tool groups")`
    func testUsesTheFinalCallForToolGroups() {
        let cases: [(String, [T3WorkLogEntry.LifecycleStatus], Bool)] = [
            ("recovered", [.failed, .completed], false),
            ("ending in failure", [.completed, .failed], true),
            ("failed", [.failed, .failed], true),
        ]
        for (name, statuses, hasFailure) in cases {
            let entries = statuses.enumerated().map { index, status in
                work("work-entry-\(index)", turn: nil, index, "Ran command") {
                    $0.id = "work-\(index)"; $0.itemType = .commandExecution; $0.toolLifecycleStatus = status
                }
            }
            guard case let .workToggle(_, _, _, _, hidden, _, _, _, _, _, failure)? =
                    rows(entries).first(where: { $0.kind == "work-toggle" }) else { return XCTFail(name) }
            XCTAssertEqual(hidden, 2, name)
            XCTAssertEqual(failure, hasFailure, name)
        }
    }

    /// `it.each([...])("uses the final tool call for mixed work groups when %s")`
    func testUsesTheFinalToolCallForMixedWorkGroups() {
        let cases: [(String, [String], Bool)] = [
            ("the later success is hidden", ["failed", "completed", "info"], false),
            ("the later success is visible", ["failed", "info", "completed"], false),
            ("an error-toned entry recovers", ["error", "info", "completed"], false),
            ("the final failure is hidden", ["completed", "failed", "info"], true),
            ("the final failure is visible", ["failed", "info", "failed"], true),
            ("the only failure is visible", ["completed", "info", "failed"], true),
        ]
        for (name, statuses, hasFailure) in cases {
            let entries = statuses.enumerated().map { index, status -> T3TimelineEntry in
                switch status {
                case "info":
                    return work("work-entry-\(index)", turn: nil, index, "Status updated", tone: .info) {
                        $0.id = "work-\(index)" }
                case "error":
                    return work("work-entry-\(index)", turn: nil, index, "Command failed", tone: .error) {
                        $0.id = "work-\(index)" }
                default:
                    return work("work-entry-\(index)", turn: nil, index, "Ran command") {
                        $0.id = "work-\(index)"
                        $0.toolLifecycleStatus = T3WorkLogEntry.LifecycleStatus(rawValue: status)
                    }
                }
            }
            let r = rows(entries)
            let hasError = statuses.contains("error")
            guard case let .workToggle(_, _, _, _, hidden, _, summary, _, _, _, failure)? =
                    r.first(where: { $0.kind == "work-toggle" }) else { return XCTFail(name) }
            XCTAssertEqual(hidden, hasError ? 2 : 3, name)
            XCTAssertEqual(summary, hasError ? "Received 1 update and used 1 tool"
                                             : "Used 2 tools and received 1 update", name)
            XCTAssertEqual(failure, hasFailure, name)
            if hasError {
                guard case let .work(_, _, grouped, _, _) = r[0] else { return XCTFail(name) }
                XCTAssertEqual(grouped.map(\.tone), [.error], name)
                XCTAssertEqual(grouped.map(\.label), ["Command failed"], name)
            }
        }
    }

    // MARK: - describe("computeStableMessagesTimelineRows")

    /// `it("replaces a cached work toggle when its icon presentation changes")`
    func testStableReplacesACachedWorkToggleWhenItsIconPresentationChanges() {
        let base = T3TimelineRows.Row.workToggle(id: "work-toggle:1", createdAt: at(0), turnId: nil,
                                                 groupId: "work-group:1", hiddenCount: 1, expanded: false,
                                                 summary: "Used Browser", summaryKind: .other,
                                                 toolSurface: "browser", summaryToolIcon: nil, hasFailure: false)
        var iconOnly = base
        if case let .workToggle(id, createdAt, turnId, groupId, hidden, expanded, summary, kind, surface, _, failure) = base {
            iconOnly = .workToggle(id: id, createdAt: createdAt, turnId: turnId, groupId: groupId,
                                   hiddenCount: hidden, expanded: expanded, summary: summary, summaryKind: kind,
                                   toolSurface: surface, summaryToolIcon: .browser, hasFailure: failure)
        }
        XCTAssertEqual(T3TimelineRows.stable(previous: [base], next: [iconOnly]), [iconOnly])

        var changed = base
        if case let .workToggle(id, createdAt, turnId, groupId, hidden, expanded, _, kind, surface, icon, failure) = base {
            changed = .workToggle(id: id, createdAt: createdAt, turnId: turnId, groupId: groupId,
                                  hiddenCount: hidden, expanded: expanded, summary: "Used browser 1 time",
                                  summaryKind: kind, toolSurface: surface, summaryToolIcon: icon,
                                  hasFailure: failure)
        }
        XCTAssertEqual(T3TimelineRows.stable(previous: [base], next: [changed]), [changed])
    }

    /// `it.each(["", " \n"])("keeps Thinking after assistant content grows from %j")`
    func testKeepsThinkingAfterAssistantContentGrows() {
        for text in ["", " \n"] {
            func derive(_ body: String) -> [T3TimelineRows.Row] {
                rows([.message(id: "assistant-entry", createdAt: at(0),
                               T3ChatMessage(id: "assistant-1", role: .assistant, text: body, turnId: "turn-1",
                                             streaming: true, createdAt: at(0), updatedAt: at(0)))],
                     working: true, startedAt: 0) { $0.runningTurnId = "turn-1" }
            }
            let initial = derive(text)
            let updated = T3TimelineRows.stable(previous: initial,
                                                next: derive("I will inspect the repository."))
            let initialThinking = initial.first { $0.id == T3TimelineRows.liveActivityRowId }
            let updatedThinking = updated.first { $0.id == T3TimelineRows.liveActivityRowId }
            XCTAssertEqual(initialThinking?.kind, "thinking", text.debugDescription)
            XCTAssertEqual(updatedThinking, initialThinking, text.debugDescription)
            XCTAssertEqual(updated.last, updatedThinking, text.debugDescription)
        }
    }

    /// `it("returns the previous result when row order and content are unchanged")`
    func testStableReturnsThePreviousResultWhenRowOrderAndContentAreUnchanged() {
        let derived = rows([user("user-1", 0), user("user-2", 10)])
        XCTAssertEqual(T3TimelineRows.stable(previous: derived, next: derived), derived)
    }

    /// `it("reuses work rows when equivalent timeline derivations create new grouped arrays")`
    /// Adapted: upstream asserts JS array identity is reused; with value types
    /// the observable rule is that an equivalent re-derivation compares equal,
    /// including a work row whose own `createdAt` moved (`isRowUnchanged` skips
    /// `createdAt` for work rows).
    func testStableReusesWorkRowsForEquivalentDerivations() {
        func derived(_ firstAt: Int) -> [T3TimelineRows.Row] {
            rows([work("entry-work-1", turn: nil, firstAt, "thinking", tone: .thinking) {
                      $0.id = "work-1"; $0.createdAt = self.at(0); $0.detail = "Inspecting repository state" },
                  work("entry-work-2", turn: nil, 1, "read") {
                      $0.id = "work-2"; $0.detail = "Reading package.json" }])
        }
        let first = derived(0)
        XCTAssertEqual(T3TimelineRows.stable(previous: first, next: derived(0)), first)
        // The row's own createdAt moved but its entries did not.
        XCTAssertEqual(T3TimelineRows.stable(previous: first, next: derived(5)), first)
    }

    /// `it("returns a new result when row order changes without content changes")`
    func testStableReturnsANewResultWhenRowOrderChanges() {
        let first = rows([user("user-1", 0), user("user-2", 10)])
        let reordered = T3TimelineRows.stable(previous: first, next: [first[1], first[0]])
        XCTAssertEqual(reordered, [first[1], first[0]])
        XCTAssertNotEqual(reordered, first)
    }

    // MARK: - Brief floor case for `stable`

    func testStableRowsKeepPreviousValuesForUnchangedRows() {
        let a = rows([user("user-1", 0), assistant("assistant-1", turn: "turn-1", 5, updated: 6)])
        XCTAssertEqual(T3TimelineRows.stable(previous: a, next: a), a)
        let entry = T3WorkLogEntry(id: "w", createdAt: at(1), label: "Ran command", tone: .tool)
        let w1 = rows([.work(id: "w", createdAt: at(1), entry)])
        let w2 = rows([.work(id: "w", createdAt: at(2), entry)])
        XCTAssertEqual(T3TimelineRows.stable(previous: w1, next: w2), w1)
    }
}
