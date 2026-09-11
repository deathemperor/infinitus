import XCTest
@testable import InfinitusCore

/// Transcribed from `tools/t3ref/upstream/work-log-presentation.test.ts` — one
/// method per upstream `it` (an `it.each` table becomes one method looping its
/// rows), plus the brief's floor cases for the pieces the upstream suite covers
/// only indirectly (`omitSupersededLifecycleMarkers`, `formatDuration`,
/// `truncateInlinePreview`, the label helpers, `commandProgramName`).
///
/// Not transcribed (each needs a provider payload or a module the host never
/// forwards and the port therefore does not carry):
/// - `describe("command work-log details")` — `extractCommandOutputText` and
///   `commandDetailRepeatsCommand` read raw provider payloads (brief: skip).
/// - `describe("workEntryViewedImagePath")` — needs
///   `@t3tools/shared/filePreview`'s `isWorkspaceImagePreviewPath`, which is
///   not vendored; reconstructing it would be a guess.
/// - `describe("resolveViewedImageAsset")` — asset resolution (brief: skip).
final class T3WorkLogTests: XCTestCase {
    private func e(_ label: String, tone: T3WorkLogEntry.Tone = .tool,
                   _ build: (inout T3WorkLogEntry) -> Void = { _ in }) -> T3WorkLogEntry {
        var x = T3WorkLogEntry(id: label, createdAt: Date(timeIntervalSince1970: 0), label: label, tone: tone)
        build(&x)
        return x
    }

    // MARK: - Brief floor cases

    func testMcpToolLabelsFollowStatus() {
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3-code.preview_open"; $0.toolLifecycleStatus = .inProgress })?.displayName, "Opening a page in the preview browser")
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "mcp__t3-code__delegate_task"; $0.toolLifecycleStatus = .completed })?.displayName, "Delegated a child task")
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3code:task_cancel"; $0.toolLifecycleStatus = .failed })?.displayName, "Failed to cancel delegated task")
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3-code.preview_snapshot"; $0.toolLifecycleStatus = .stopped })?.displayName, "Stopped taking a snapshot of the preview page")
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3-code.preview_open" })?.icon, .browser)
        XCTAssertEqual(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3-code.t3_thread_list" })?.icon, .t3Code)
        XCTAssertNil(T3WorkLog.toolPresentation(e("x") { $0.toolName = "t3-code.toString" }))
        XCTAssertEqual(T3WorkLog.toolPresentation(e("t3-code · preview_click complete"))?.displayName, "Clicking in the preview browser")
    }

    func testGroupAction() {
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.sourceActivityKind = "approval.requested" }), .update)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.requestKind = .fileRead }), .read)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.itemType = .dynamicToolCall; $0.toolTitle = " Read File " }), .read)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.changedFiles = ["a.swift"] }), .edit)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.command = "ls" }), .command)
        XCTAssertEqual(T3WorkLog.groupAction(e("grep foo") { $0.itemType = .webSearch }), .codeSearch)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.itemType = .webSearch }), .search)
        // Divergence (see `isLocalCodeSearch`): an Infinitus Grep row is
        // labelled with the pattern, which need not contain "grep", so the
        // structured tool name classifies it.
        XCTAssertEqual(T3WorkLog.groupAction(e("func handleAuth") {
            $0.itemType = .webSearch; $0.toolName = "Grep"
        }), .codeSearch)
        XCTAssertEqual(T3WorkLog.groupAction(e("openai chat") {
            $0.itemType = .webSearch; $0.toolName = "WebSearch"
        }), .search)
        XCTAssertEqual(T3WorkLog.groupAction(e("x", tone: .tool)), .other)
        XCTAssertEqual(T3WorkLog.groupAction(e("x", tone: .info)), .update)
        XCTAssertEqual(T3WorkLog.groupAction(e("x") { $0.toolName = "t3-code.preview_open" }), .browser)
    }

    func testSummarizeGroup() {
        XCTAssertEqual(T3WorkLog.summarizeGroup([e("a") { $0.command = "ls" }, e("b") { $0.command = "pwd" }, e("c") { $0.requestKind = .fileRead }]), "Ran 2 commands and read 1 file")
        XCTAssertEqual(T3WorkLog.summarizeGroup([e("a") { $0.changedFiles = ["x", "y"] }, e("b") { $0.changedFiles = ["y"] }, e("c") { $0.itemType = .fileChange }]), "Changed 3 files")
        XCTAssertEqual(T3WorkLog.summarizeGroup([e("a", tone: .tool), e("b", tone: .info), e("c") { $0.command = "ls" }]), "Used 1 tool, received 1 update, and ran 1 command")
        let chrome = T3WorkLogEntry.ToolSource(key: "browser-use:chrome", name: "Chrome", kind: "integration")
        XCTAssertEqual(T3WorkLog.summarizeGroup([e("a") { $0.toolSource = chrome }, e("b") { $0.toolSource = chrome }, e("c") { $0.command = "ls" }]), "Used Chrome integration and ran 1 command")
        XCTAssertEqual(T3WorkLog.summarizeGroup([]), "")
    }

    func testSummaryKind() {
        XCTAssertEqual(T3WorkLog.summaryKind([e("a") { $0.command = "ls" }, e("b") { $0.requestKind = .fileRead }]), .mixed)
        XCTAssertEqual(T3WorkLog.summaryKind([e("a") { $0.command = "ls" }]), .command)
        XCTAssertEqual(T3WorkLog.summaryKind([e("a") { $0.itemType = .dynamicToolCall }]), .dynamicTool)
        XCTAssertEqual(T3WorkLog.summaryKind([e("a", tone: .thinking), e("b") { $0.taskId = "t" }]), .agentTool)
        XCTAssertEqual(T3WorkLog.summaryKind([e("a", tone: .tool)]), .toneTool)
        XCTAssertEqual(T3WorkLog.summaryKind([e("a") { $0.itemType = .mcpToolCall }]), .other)
    }

    func testFailurePredicates() {
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("x", tone: .error)))
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("x") { $0.toolLifecycleStatus = .declined }))
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("x") { $0.command = "cat nope"; $0.detail = "cat: nope: No such file or directory" }))
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("x") { $0.detail = "<exited with exit code 2>" }))
        XCTAssertFalse(T3WorkLog.indicatesFailure(e("x") { $0.detail = "exited with exit code 0" }))
        // legacy: the command field holds error output — only the non-display predicate reads it
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("x") { $0.command = "zsh: command not found: foo" }))
        XCTAssertFalse(T3WorkLog.displayIndicatesFailure(e("x") { $0.command = "zsh: command not found: foo" }))
        XCTAssertFalse(T3WorkLog.indicatesFailure(e("x", tone: .info) { $0.detail = "file not found" }))
        XCTAssertTrue(T3WorkLog.indicatesSuccess(e("x") { $0.toolLifecycleStatus = .completed }))
        XCTAssertFalse(T3WorkLog.indicatesSuccess(e("x", tone: .thinking)))
        XCTAssertFalse(T3WorkLog.indicatesSuccess(e("x") { $0.toolLifecycleStatus = .stopped }))
        XCTAssertTrue(T3WorkLog.indicatesNeutralStatus(e("x") { $0.toolLifecycleStatus = .inProgress }))
        XCTAssertFalse(T3WorkLog.indicatesNeutralStatus(e("x", tone: .info)))
    }

    func testOmitSupersededLifecycleMarkers() {
        let started = e("Ran rg") { $0.sourceActivityKind = "tool.started"; $0.turnId = "t1"; $0.itemType = .commandExecution }
        let updated = e("Ran rg") { $0.sourceActivityKind = "tool.updated"; $0.turnId = "t1"; $0.itemType = .commandExecution }
        let done = e("Ran rg complete") { $0.sourceActivityKind = "tool.completed"; $0.turnId = "t1"; $0.itemType = .commandExecution }
        XCTAssertEqual(T3WorkLog.omitSupersededLifecycleMarkers([started, updated, done]) { $0 }.map(\.sourceActivityKind), ["tool.completed"])
        XCTAssertEqual(T3WorkLog.omitSupersededLifecycleMarkers([started, updated]) { $0 }.count, 2)
        var idd = started
        idd.toolCallId = "c1"
        XCTAssertEqual(T3WorkLog.omitSupersededLifecycleMarkers([idd, done]) { $0 }.count, 2)
    }

    func testFormatDuration() {
        XCTAssertEqual(T3WorkLog.formatDuration(0.0004), "1ms")
        XCTAssertEqual(T3WorkLog.formatDuration(0.25), "250ms")
        XCTAssertEqual(T3WorkLog.formatDuration(1.24), "1.2s")
        XCTAssertEqual(T3WorkLog.formatDuration(9.96), "10s")
        XCTAssertEqual(T3WorkLog.formatDuration(22), "22s")
        XCTAssertEqual(T3WorkLog.formatDuration(47.4), "47s")
        XCTAssertEqual(T3WorkLog.formatDuration(3600), "1h")
        XCTAssertEqual(T3WorkLog.formatDuration(3725), "1h 2m 5s")
        XCTAssertEqual(T3WorkLog.formatDuration(-1), "0ms")
    }

    func testInlinePreview() {
        XCTAssertEqual(T3WorkLog.truncateInlinePreview(String(repeating: "a", count: 84)).count, 84)
        let long = T3WorkLog.truncateInlinePreview(String(repeating: "a", count: 85))
        XCTAssertEqual(long.count, 84)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(T3WorkLog.summarizeToolTextOutput("```\n\nfirst   line\nsecond\n"), "first line")
        // Upstream (session-logic.ts and ActivityPayloadProjection.ts alike)
        // counts the fenced lines and reports "2 lines"; the brief's floor
        // expected nil. Upstream wins — one meaningful line still returns nil.
        XCTAssertEqual(T3WorkLog.summarizeToolTextOutput("```\n```\n"), "2 lines")
        XCTAssertNil(T3WorkLog.summarizeToolTextOutput("```\n"))
        XCTAssertNil(T3WorkLog.summarizeToolTextOutput(""))
    }

    func testLabels() {
        XCTAssertEqual(T3WorkLog.singleToolCallLabel(e("read file complete")), "Read file")
        XCTAssertEqual(T3WorkLog.singleToolCallLabel(e("x") { $0.command = " rg foo " }), "rg foo")
        XCTAssertEqual(T3WorkLog.displayLabel(e("x") { $0.changedFiles = ["/w/limitless/a.swift", "/w/limitless/b.swift"] }, workspaceRoot: "/w/limitless/"), "limitless/a.swift +1 more")
        XCTAssertEqual(T3WorkLog.displayLabel(e("x") { $0.changedFiles = ["src/a.swift:12:3"] }, workspaceRoot: "/w/limitless"), "limitless/src/a.swift:12:3")
        XCTAssertEqual(T3WorkLog.liveLabel(e("x") { $0.command = "rg foo"; $0.toolLifecycleStatus = .inProgress }, workspaceRoot: nil, active: true), "Running rg")
        XCTAssertEqual(T3WorkLog.liveLabel(e("x") { $0.command = "cd /tmp && npm test"; $0.toolLifecycleStatus = .completed }, workspaceRoot: nil, active: false), "Ran npm")
        XCTAssertEqual(T3WorkLog.liveLabel(e("x") { $0.command = "rg foo"; $0.toolLifecycleStatus = .failed }, workspaceRoot: nil, active: true), "Failed rg")
        XCTAssertEqual(T3WorkLog.liveLabel(e("x") { $0.command = "sh -c 'git status'" }, workspaceRoot: nil, active: true), "Running git")
    }

    // MARK: - describe("workEntryIndicatesToolFailure")

    /// `it("is true for error tone")`
    func testIsTrueForErrorTone() {
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("Read", tone: .error) { $0.detail = "nothing special" }))
    }

    /// `it("is true when lifecycle says failed even if detail is empty")`
    func testIsTrueWhenLifecycleSaysFailedEvenIfDetailIsEmpty() {
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("Read") { $0.toolLifecycleStatus = .failed }))
    }

    /// `it("detects file-not-found style tool output with completed lifecycle")`
    func testDetectsFileNotFoundStyleToolOutputWithCompletedLifecycle() {
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("Read") {
            $0.toolLifecycleStatus = .completed
            $0.detail = "File not found: C:\\foo\\nonexistent.ts"
        }))
    }

    /// `it("detects glob no files and PowerShell command errors")`
    func testDetectsGlobNoFilesAndPowerShellCommandErrors() {
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("Glob") { $0.detail = "No files found" }))
        XCTAssertTrue(T3WorkLog.indicatesFailure(e("Bash") {
            $0.detail = "The term 'this_is_not_a_command' is not recognized as the name of a cmdlet, function, script file, or operable program."
        }))
    }

    /// `it("is false for successful completed tools")`
    func testIsFalseForSuccessfulCompletedTools() {
        XCTAssertFalse(T3WorkLog.indicatesFailure(e("Read") {
            $0.toolLifecycleStatus = .completed
            $0.detail = "Found 3 matching files"
        }))
    }

    /// `it("does not treat error text in a command as rendered failure")`
    func testDoesNotTreatErrorTextInACommandAsRenderedFailure() {
        let entry = e("Ran command") {
            $0.toolLifecycleStatus = .completed
            $0.command = "rg \"file not found\""
            $0.detail = "Found 3 matches"
        }
        XCTAssertFalse(T3WorkLog.displayIndicatesFailure(entry))
        XCTAssertTrue(T3WorkLog.indicatesFailure(entry))
        var rendered = entry
        rendered.detail = "File not found"
        XCTAssertTrue(T3WorkLog.displayIndicatesFailure(rendered))
    }

    /// `it("treats successful tool rows as success candidates")`
    func testTreatsSuccessfulToolRowsAsSuccessCandidates() {
        XCTAssertTrue(T3WorkLog.indicatesSuccess(e("Read") { $0.toolLifecycleStatus = .completed; $0.detail = "ok" }))
        XCTAssertFalse(T3WorkLog.indicatesSuccess(e("Read") { $0.toolLifecycleStatus = .inProgress; $0.detail = "…" }))
        XCTAssertFalse(T3WorkLog.indicatesSuccess(e("Read", tone: .thinking) { $0.detail = "…" }))
        XCTAssertFalse(T3WorkLog.indicatesSuccess(e("Read") { $0.toolLifecycleStatus = .stopped }))
    }

    /// `it("does not run heuristics on non-tool info rows")`
    func testDoesNotRunHeuristicsOnNonToolInfoRows() {
        XCTAssertFalse(T3WorkLog.indicatesFailure(e("Context compacted", tone: .info) {
            $0.detail = "File not found in conversation"
        }))
    }

    // MARK: - describe("summarizeToolGroup")

    /// `it.each(["command", "file-read", "file-change"])("keeps %s approvals out of tool execution counts")`
    func testKeepsApprovalsOutOfToolExecutionCounts() {
        for requestKind in [T3WorkLogEntry.RequestKind.command, .fileRead, .fileChange] {
            let approvals = [
                e("Approval requested", tone: .info) { $0.sourceActivityKind = "approval.requested"; $0.requestKind = requestKind },
                e("Approval resolved", tone: .info) { $0.sourceActivityKind = "approval.resolved"; $0.requestKind = requestKind },
                e("Provider approval response failed", tone: .error) { $0.sourceActivityKind = "provider.approval.respond.failed" },
            ]
            XCTAssertEqual(T3WorkLog.summarizeGroup(approvals + [e("Read") { $0.itemType = .dynamicToolCall }]),
                           "Received 3 updates and used 1 tool", "\(requestKind)")
            XCTAssertEqual(T3WorkLog.summarizeGroup(approvals), "Received 3 updates", "\(requestKind)")
            XCTAssertEqual(T3WorkLog.summaryKind(approvals), .update, "\(requestKind)")
        }
    }

    /// `it("deduplicates named sources ahead of ordinary actions")`
    func testDeduplicatesNamedSourcesAheadOfOrdinaryActions() {
        let source = T3WorkLogEntry.ToolSource(key: "browser-use:chrome", name: "Chrome", kind: "integration")
        XCTAssertEqual(T3WorkLog.summarizeGroup([
            e("Open page") { $0.toolSource = source },
            e("Inspect page") { $0.toolSource = source },
            e("Ran command") { $0.itemType = .commandExecution; $0.command = "git status" },
        ]), "Used Chrome integration and ran 1 command")
    }

    /// `it("omits the integration suffix for special browser and computer sources")`
    func testOmitsTheIntegrationSuffixForSpecialBrowserAndComputerSources() {
        XCTAssertEqual(T3WorkLog.summarizeGroup([
            e("Inspect page") { $0.toolSource = .init(key: "browser-use", name: "Browser", kind: "browser") },
            e("Click") { $0.toolSource = .init(key: "computer-use", name: "Computer Use", kind: "computer") },
        ]), "Used Browser and Computer Use")
    }

    // MARK: - describe("resolveWorkEntryToolPresentation")

    /// `it.each([...])("recognizes browser tool names across providers: %s")`
    func testRecognizesBrowserToolNamesAcrossProviders() {
        for label in ["mcp__t3-code__preview_click", "mcp__t3_code__preview_click", "mcp__t3code__preview_click",
                      "T3-code.preview_click", "t3-code · preview_click completed", "t3_code/preview_click",
                      "preview_click"] {
            let p = T3WorkLog.toolPresentation(e(label))
            XCTAssertEqual(p?.displayName, "Clicking in the preview browser", label)
            XCTAssertEqual(p?.icon, .browser, label)
        }
    }

    /// `it("uses structured MCP identity when the provider supplies a custom title")`
    /// Adapted: the port folds upstream's `toolData.{server,tool}` into the
    /// single `toolName` string (`"<server>.<tool>"`), per the Interfaces block.
    func testUsesStructuredMcpIdentityWhenTheProviderSuppliesACustomTitle() {
        let p = T3WorkLog.toolPresentation(e("Tool call complete") {
            $0.toolTitle = "Inspect the current page"
            $0.toolName = "t3-code.preview_snapshot"
        })
        XCTAssertEqual(p?.displayName, "Taking a snapshot of the preview page")
        XCTAssertEqual(p?.icon, .browser)
    }

    /// `it.each([...])("describes the tool's own %s state")`
    func testDescribesTheToolsOwnState() {
        let cases: [(T3WorkLogEntry.LifecycleStatus?, String)] = [
            (.inProgress, "Clicking in the preview browser"),
            (.completed, "Clicked in the preview browser"),
            (.failed, "Failed to click in the preview browser"),
            (.declined, "Declined to click in the preview browser"),
            (.stopped, "Stopped clicking in the preview browser"),
            (nil, "Clicking in the preview browser"),   // upstream's "unknown" status
        ]
        for (status, displayName) in cases {
            let p = T3WorkLog.toolPresentation(e("T3-code.preview_click") { $0.toolLifecycleStatus = status })
            XCTAssertEqual(p?.displayName, displayName, "\(String(describing: status))")
            XCTAssertEqual(p?.icon, .browser)
        }
    }

    /// `it("uses the summary's state only when the provider omitted a lifecycle status")`
    func testUsesTheSummarysStateOnlyWhenTheProviderOmittedALifecycleStatus() {
        let entry = e("T3-code.preview_click")
        XCTAssertEqual(T3WorkLog.toolPresentation(entry, fallback: .inProgress)?.displayName, "Clicking in the preview browser")
        XCTAssertEqual(T3WorkLog.toolPresentation(entry, fallback: .completed)?.displayName, "Clicked in the preview browser")
        var completed = entry
        completed.toolLifecycleStatus = .completed
        XCTAssertEqual(T3WorkLog.toolPresentation(completed, fallback: .inProgress)?.displayName, "Clicked in the preview browser")
        var failed = entry
        failed.toolLifecycleStatus = .failed
        XCTAssertEqual(T3WorkLog.toolPresentation(failed, fallback: .completed)?.displayName, "Failed to click in the preview browser")
    }

    /// `it.each([...])("preserves verb forms and the rest of %s's label")`
    func testPreservesVerbFormsAndTheRestOfTheLabel() {
        let cases = [
            ("preview_type", "Typing in the preview browser", "Typed in the preview browser"),
            ("preview_set_appearance", "Setting preview browser appearance", "Set preview browser appearance"),
            ("preview_snapshot", "Taking a snapshot of the preview page", "Took a snapshot of the preview page"),
            ("preview_recording_stop", "Stopping recording the preview browser", "Stopped recording the preview browser"),
            ("t3_thread_read", "Reading a T3 thread", "Read a T3 thread"),
            ("t3_thread_send", "Sending to a T3 thread", "Sent to a T3 thread"),
            ("t3_worktree_handoff", "Handing off thread to a git worktree", "Handed off thread to a git worktree"),
        ]
        for (tool, running, completed) in cases {
            XCTAssertEqual(T3WorkLog.toolPresentation(e("t3-code.\(tool)") { $0.toolLifecycleStatus = .inProgress })?.displayName, running, tool)
            XCTAssertEqual(T3WorkLog.toolPresentation(e("t3-code.\(tool)") { $0.toolLifecycleStatus = .completed })?.displayName, completed, tool)
        }
    }

    /// `it("keeps T3 branding for non-browser tools and falls back to the original tool label")`
    func testKeepsT3BrandingForNonBrowserToolsAndFallsBackToTheOriginalToolLabel() {
        let p = T3WorkLog.toolPresentation(e("mcp__t3_code__task_status") { $0.toolTitle = "Check the child task" })
        XCTAssertEqual(p?.displayName, "Getting delegated task status")
        XCTAssertEqual(p?.icon, .t3Code)
    }

    /// `it("does not brand unknown tools or another server's matching tool name")`
    func testDoesNotBrandUnknownToolsOrAnotherServersMatchingToolName() {
        for label in ["mcp__github__preview_click", "t3-code.unknown_tool", "t3-code.toString", "Search files"] {
            XCTAssertNil(T3WorkLog.toolPresentation(e(label)), label)
        }
        XCTAssertNil(T3WorkLog.toolPresentation(e("preview_click") { $0.toolName = "another-server.preview_click" }))
    }

    // MARK: - describe("browser group summaries")

    private var browserEntry: T3WorkLogEntry {
        e("MCP tool call") {
            $0.toolName = "t3-code.preview_click"
            $0.itemType = .mcpToolCall
            $0.toolLifecycleStatus = .completed
        }
    }
    private var commandEntry: T3WorkLogEntry {
        e("Ran command") {
            $0.command = "/bin/bash -lc 'vp test run'"
            $0.itemType = .commandExecution
            $0.toolLifecycleStatus = .completed
        }
    }

    /// `it.each([1, 18])("counts %s browser calls separately from generic tools")`
    func testCountsBrowserCallsSeparatelyFromGenericTools() {
        for count in [1, 18] {
            let entries = (0..<count).map { index -> T3WorkLogEntry in
                var entry = browserEntry
                entry.toolCallId = "browser-\(index)"
                return entry
            }
            XCTAssertEqual(T3WorkLog.summarizeGroup(entries), "Used browser \(count) \(count == 1 ? "time" : "times")")
            XCTAssertEqual(T3WorkLog.summaryKind(entries), .browser)
        }
    }

    /// `it("combines command and browser counts in a single sentence")`
    func testCombinesCommandAndBrowserCountsInASingleSentence() {
        let entries = Array(repeating: commandEntry, count: 4) + Array(repeating: browserEntry, count: 15)
        XCTAssertEqual(T3WorkLog.summarizeGroup(entries), "Ran 4 commands and used browser 15 times")
        XCTAssertEqual(T3WorkLog.summaryKind(entries), .mixed)
    }

    /// `it("preserves first-seen action ordering alongside non-browser tools")`
    func testPreservesFirstSeenActionOrderingAlongsideNonBrowserTools() {
        var taskStatus = browserEntry
        taskStatus.toolName = "t3-code.task_status"
        XCTAssertEqual(T3WorkLog.summarizeGroup([browserEntry, commandEntry, taskStatus]),
                       "Used browser 1 time, ran 1 command, and used 1 tool")
    }

    /// `it("recognizes Claude browser identity without treating script metadata as a shell command")`
    func testRecognizesClaudeBrowserIdentityWithoutTreatingScriptMetadataAsAShellCommand() {
        var entry = browserEntry
        entry.command = "node inspect-page.js"
        entry.toolName = "mcp__t3_code__preview_evaluate"
        XCTAssertEqual(T3WorkLog.summarizeGroup([entry]), "Used browser 1 time")
    }

    /// `it("keeps foreign tools and web searches out of the browser count")`
    func testKeepsForeignToolsAndWebSearchesOutOfTheBrowserCount() {
        var foreign = browserEntry
        foreign.label = "preview_click"
        foreign.toolName = "another-server.preview_click"
        XCTAssertEqual(T3WorkLog.summarizeGroup([browserEntry, foreign, e("Search") { $0.itemType = .webSearch }]),
                       "Used browser 1 time, used 1 tool, and searched the web 1 time")
    }

    /// `it("keeps browser screenshots in the browser count while preserving their image path")`
    /// Adapted: the `workEntryViewedImagePath` half is not ported (see the type
    /// comment); the browser-count half is.
    func testKeepsBrowserScreenshotsInTheBrowserCount() {
        var entry = browserEntry
        entry.viewedImagePath = "/workspace/page.png"
        XCTAssertEqual(T3WorkLog.summarizeGroup([entry]), "Used browser 1 time")
    }

    // MARK: - describe("toolGroupAction")

    /// `it("groups legacy Claude image reads with other reads")`
    func testGroupsLegacyClaudeImageReadsWithOtherReads() {
        XCTAssertEqual(T3WorkLog.groupAction(e("Tool call") {
            $0.itemType = .dynamicToolCall
            $0.viewedImagePath = "/workspace/reference.png"
        }), .read)
    }
}

/// Transcribed from `~/death/t3code/packages/client-runtime/src/work-log/commandLabel.test.ts`
/// — the POSIX subset the brief scopes in. Not transcribed (the port carries no
/// PowerShell/Windows or alias-tracking half):
/// `it.each("resolves literal PowerShell call operators")`,
/// `("labels commands inside simple PowerShell assignments")`,
/// `("unwraps Windows shell launchers")`,
/// `("handles common PowerShell setup and launch commands")`,
/// `("resolves literal command aliases from earlier shell segments")`,
/// `it("does not retain aliases assigned inside control flow")`, plus the
/// Windows-path rows inside otherwise-transcribed tables.
extension T3WorkLogTests {
    private func expectProgram(_ rows: [(String, String?)], _ file: StaticString = #filePath, _ line: UInt = #line) {
        for (command, program) in rows {
            XCTAssertEqual(T3WorkLog.commandProgramName(command), program,
                           "commandProgramName(\(command.debugDescription))", file: file, line: line)
        }
    }

    /// `it.each([...])("unwraps shell scripts without executing them: %s")`
    func testUnwrapsShellScriptsWithoutExecutingThem() {
        expectProgram([
            ("/bin/zsh -lc 'vp test run apps/web/src/session-logic.test.ts'", "vp"),
            ("/bin/zsh -lc 'git diff --check'", "git"),
            ("/bin/zsh -lc \"npx -y react-doctor@latest apps/web\"", "npx"),
            ("/bin/zsh -lc 'rg -n \"registerHooks|worker\" apps/web/src'", "rg"),
            ("/bin/bash --noprofile --norc -l -c 'sed -n 1,270p file.ts'", "sed"),
            ("/bin/bash -o pipefail -lc 'vp test run'", "vp"),
            ("/bin/bash --rcfile /tmp/config -c 'git status'", "git"),
            ("sh -ec 'node scripts/check.js'", "node"),
            ("fish --command 'rg --files'", "rg"),
            ("zsh -lc 'CI=1 env -u DEBUG sudo -u root vp test run'", "vp"),
            ("env CI=1 /bin/zsh -lc '\"/Applications/My Tools/bin/check\" --verbose'", "check"),
            ("bash -lc \"zsh -c 'git status'\"", "git"),
            ("/bin/zsh -lc 'git status\nsed -n '\"'1,20p' apps/web/src/components/DiffPanel.tsx\"", "git"),
        ])
    }

    /// `it.each([...])("preserves ordinary programs and actual shell launches: %s")`
    func testPreservesOrdinaryProgramsAndActualShellLaunches() {
        expectProgram([
            ("vp test run", "vp"),
            ("sudo -u root pnpm test", "pnpm"),
            ("env --split-string='CI=1 node scripts/check.js'", "node"),
            ("/bin/zsh", "zsh"),
            ("/bin/bash -l", "bash"),
            ("zsh script.sh -c 'git status'", "zsh"),
            ("bash -- -c 'git status'", "bash"),
            ("bash --rcfile config.sh", "bash"),
            ("my-shell -c 'git status'", "my-shell"),
            ("$HOME/.bun/bin/bun test", "bun"),
            ("\"$ANDROID_HOME/emulator/emulator\" -list-avds", "emulator"),
            ("${ROOT}/bin/tool --version", "tool"),
        ])
    }

    /// `it.each([...])("falls back for missing or malformed scripts: %s")`
    func testFallsBackForMissingOrMalformedScripts() {
        expectProgram([("", nil), ("zsh -lc", nil), ("zsh -lc ''", nil), ("zsh -lc 'git status", nil),
                       ("zsh -lc 'env'", nil), ("zsh -lc \"git \\\"", nil)])
    }

    /// `it.each([...])("falls back for shell syntax and internal control commands: %s")`
    func testFallsBackForShellSyntaxAndInternalControlCommands() {
        expectProgram([
            ("if test -f package.json; then vp test; fi", nil), ("[ -f package.json ]", nil),
            ("[[ -f package.json ]]", nil), ("test -f package.json", nil),
            ("for file in *; do echo \"$file\"; done", nil), ("while true; do sleep 1; done", nil),
            ("until false; do sleep 1; done", nil), ("case $name in test) vp test;; esac", nil),
            ("select item in one two; do echo \"$item\"; done", nil), ("function check() { vp test; }", nil),
            ("check() { vp test; }", nil), ("k(){ echo ok; }; k", nil), ("{ vp test; }", nil),
            ("(vp test)", nil), ("(( count += 1 ))", nil), ("! vp test", nil), (":", nil),
            (". ./script.sh", nil), ("source ./script.sh", nil), ("eval 'vp test'", nil),
            ("cd packages/client-runtime", nil), ("export NODE_ENV=test", nil), ("local name=value", nil),
            ("set -e", nil), ("alias ll='ls -la'", nil), ("repeat 3 echo ok", nil), ("and vp test", nil),
            ("return 1", nil), ("break", nil), ("continue", nil), ("true", nil), ("false", nil),
        ])
    }

    /// `it.each([...])("uses the first executable-looking program: %s")`
    func testUsesTheFirstExecutableLookingProgram() {
        expectProgram([
            ("rg -n \"if|for|while\" src", "rg"), ("printf '%s\\n' 'a;b|c'", "printf"),
            ("node -e \"if (true) console.log('ok')\"", "node"), ("echo '$(git status)'", "echo"),
            ("vp test && git status", "vp"), ("vp test || git status", "vp"), ("rg needle src | head", "rg"),
            ("vp test; git status", "vp"), ("vp test &", "vp"), ("vp test\ngit status", "vp"),
            ("echo \"$(git status)\"", "echo"), ("echo `git status`", "echo"), ("cat <(rg needle src)", "cat"),
        ])
    }

    /// `it.each([...])("skips leading cd commands and uses the next useful program: %s")`
    func testSkipsLeadingCdCommandsAndUsesTheNextUsefulProgram() {
        expectProgram([
            ("cd packages/client-runtime && vp test run", "vp"),
            ("cd \"a path with spaces\"; git status", "git"),
            ("cd apps/web\npnpm test", "pnpm"),
            ("cd first && cd second && bun test", "bun"),
            ("CI=1 cd apps/web && npm test", "npm"),
            ("PATH+=:/tools npm test", "npm"),
            ("PATH+=:/tools && npm test", "npm"),
            ("TMP=$(mktemp -d); cd \"$TMP\"; npm pack ./package", "npm"),
            ("cd $(find . -type d | head -1) && git status", "git"),
            ("cd `find . -type d | head -1` && node script.js", "node"),
            ("cd /tmp 2>&1 && npm test", "npm"),
            ("cd /tmp 2<&0 && pnpm test", "pnpm"),
            ("cd /tmp &>/dev/null && bun test", "bun"),
            ("cd work |& npm test", "npm"),
            ("cd /tmp && # use the selected workspace\nnpm test", "npm"),
            ("export CI=1; # first note\n# second note\npnpm test", "pnpm"),
            ("cd&&npm test", "npm"),
            ("export CI=1;pnpm test", "pnpm"),
            ("cd ${ROOT:-path;with;semicolons} && bun test", "bun"),
            ("cd ${ROOT:-path&&fallback} && node app.js", "node"),
            ("cd @(first|second) && npm test", "npm"),
            ("cd /tmp \\\n&& npm test", "npm"),
            ("/bin/zsh -lc 'cd apps/web && vp test run'", "vp"),
        ])
    }

    /// `it.each([...])("skips shell setup commands and uses the next useful program: %s")`
    func testSkipsShellSetupCommandsAndUsesTheNextUsefulProgram() {
        expectProgram([
            ("source ~/.nvm/nvm.sh && nvm use", "nvm"),
            (". ./.env && pnpm test", "pnpm"),
            ("export CI=1 && vp test run", "vp"),
            ("unset DEBUG; node app.js", "node"),
            ("export CI=1 && cd apps/web && pnpm test", "pnpm"),
            ("/bin/zsh -lc 'source ~/.nvm/nvm.sh && nvm use'", "nvm"),
        ])
    }

    /// `it.each([...])("skips non-descriptive shell commands before a useful program: %s")`
    func testSkipsNonDescriptiveShellCommandsBeforeAUsefulProgram() {
        expectProgram([
            ("set -eu; npm test", "npm"), (": && npm test", "npm"), ("true && npm test", "npm"),
            ("false || npm test", "npm"), ("false; npm test", "npm"), ("sudo -n true && npm test", "npm"),
            ("sudo -n true; echo checked", "echo"), ("test -d node_modules || vp i", "vp"),
            ("[ -d node_modules ] || vp i", "vp"),
        ])
    }

    /// `it.each(...)("handles shell setup followed by every command separator: %s")`
    func testHandlesShellSetupFollowedByEveryCommandSeparator() {
        var rows: [(String, String?)] = []
        for setup in ["cd /tmp", "export CI=1", "unset DEBUG", "source env.sh", ". env.sh"] {
            for op in ["&&", " || ", ";", "\n", "|", " |& ", " & "] {
                rows.append(("\(setup)\(op)npm test", "npm"))
            }
        }
        expectProgram(rows)
    }

    /// `it.each([...])("unwraps shell command wrappers: %s")`
    func testUnwrapsShellCommandWrappers() {
        expectProgram([
            ("command git status", "git"), ("command -p git status", "git"), ("command -- git status", "git"),
            ("builtin printf ok", "printf"), ("builtin -- echo ok", "echo"),
            ("command cd /tmp && npm test", "npm"), ("builtin cd /tmp && pnpm test", "pnpm"),
            ("exec node app.js", "node"), ("exec -cl -a worker node app.js", "node"),
            ("exec env CI=1 /opt/tools/check --verbose", "check"),
            ("exec sh -c 'cd /tmp && npm test'", "npm"), ("exec sh -c 'cd /tmp\nnpm test'", "npm"),
            ("exec bash -c 'set -e\nnpm test'", "npm"),
        ])
    }

    /// `it.each([...])("unwraps process-launch wrappers: %s")`
    func testUnwrapsProcessLaunchWrappers() {
        expectProgram([
            ("timeout 10 pnpm test", "pnpm"), ("timeout 10s python3 script.py", "python3"),
            ("gtimeout 1.5 node app.js", "node"),
            ("nohup npx expo start >/tmp/metro.log 2>&1 &", "npx"),
            ("nohup -- env CI=1 bun test", "bun"),
            ("arch -x86_64 ./build/app-under-test", "app-under-test"),
            ("arch -arch arm64 /opt/tools/check", "check"),
            ("bundle exec pod install", "pod"),
            ("timeout 30 nohup env CI=1 node app.js", "node"),
            ("timeout 60 script -q /dev/null env CI=1 node app.js", "node"),
        ])
    }

    /// `it.each([...])("keeps process-launch wrappers when no safe payload is present: %s")`
    func testKeepsProcessLaunchWrappersWhenNoSafePayloadIsPresent() {
        expectProgram([
            ("timeout --help", "timeout"), ("nohup --version", "nohup"), ("arch", "arch"),
            ("bundle install", "bundle"), ("script output.log", "script"),
            ("/usr/bin/timeout 10 node app.js", "timeout"),
        ])
    }

    /// `it.each([...])("does not treat shell lookup and commandless wrapper forms as executions: %s")`
    func testDoesNotTreatShellLookupAndCommandlessWrapperFormsAsExecutions() {
        expectProgram([
            ("command -v git", nil), ("command -V git", nil), ("command -a git", nil),
            ("command -pv git", nil), ("builtin -p", nil), ("exec", nil), ("exec > output.log", nil),
            ("exec --", nil), ("exec cd /tmp && npm test", nil), ("exec env CI=1 cd /tmp && npm test", nil),
            ("exec CI=1 npm test", nil), ("env CI=1 cd /tmp && npm test", nil), ("env CI=1; npm test", nil),
            ("sudo cd /tmp && npm test", nil), ("command CI=1 npm test", nil),
            ("command false && npm test", nil), ("cd /tmp <<EOF\nunterminated heredoc", nil),
            ("cd /tmp && >/tmp/log", nil),
            ("(xcrun simctl io booted recordVideo /tmp/video.mp4 &) ; wait", nil),
            ("export CI=1 && (bundle exec pod install || pod install)", nil),
            ("$PY scripts/check.py", nil), ("${TOOL} --version", nil), ("broken{", nil),
            ("time -- npm test", nil), ("time -v npm test", nil), ("coproc npm test", nil),
            ("coproc worker { npm test; }", nil), ("cd [first|second] && pnpm test", nil),
            ("npm) --version", nil), ("# comment only", nil),
        ])
    }

    /// `it.each([...])("does not hide legitimate or case-distinct program names: %s")`
    func testDoesNotHideLegitimateOrCaseDistinctProgramNames() {
        expectProgram([("parallel -j4", "parallel"), ("hash --help", "hash"), ("process --help", "process"),
                       ("rem comment", "rem"), ("Exec node app.js", "Exec"), ("CD /tmp && npm test", "CD")])
    }

    /// `it.each([...])("parses shell setup inside an explicitly launched shell: %s")`
    func testParsesShellSetupInsideAnExplicitlyLaunchedShell() {
        expectProgram([("env sh -c 'cd /tmp && npm test'", "npm"),
                       ("sudo zsh -lc 'export CI=1 && pnpm test'", "pnpm")])
    }

    /// `it.each([...])("skips shell precommand modifiers: %s")`
    func testSkipsShellPrecommandModifiers() {
        expectProgram([("nocorrect pnpm test", "pnpm"), ("noglob bun test", "bun"), ("time node app.js", "node"),
                       ("time -p deno test", "deno"), ("time nocorrect npm test", "npm")])
    }

    /// `it("uses the command after leading shell comments")`
    func testUsesTheCommandAfterLeadingShellComments() {
        expectProgram([("# first comment\n  # second comment\ngit status", "git")])
    }

    /// `it.each([...])("skips comments after commandless shell setup: %s")`
    func testSkipsCommentsAfterCommandlessShellSetup() {
        expectProgram([
            ("CI=1 # note\nnpm test", "npm"), ("CI=1 # it's configured\nnpm test", "npm"),
            ("CI=1 # \"unterminated quote\nbun test", "bun"), (">/tmp/log # note\npnpm test", "pnpm"),
            (">/tmp/log # it's configured\ndeno test", "deno"),
        ])
    }

    /// `it.each([...])("does not treat qualified paths as shell syntax: %s")`
    func testDoesNotTreatQualifiedPathsAsShellSyntax() {
        expectProgram([("./cd /tmp && npm test", "cd"), ("/opt/exec node app.js", "exec"),
                       ("/usr/bin/time npm test", "time"), ("/usr/bin/test -f package.json", "test")])
    }

    /// `it("skips a shell array assignment before the command")`
    func testSkipsAShellArrayAssignmentBeforeTheCommand() {
        expectProgram([("items=(one two); npm test", "npm")])
    }

    /// `it.each([...])("does not evaluate dynamic or non-persistent command aliases: %s")`
    func testDoesNotEvaluateDynamicOrNonPersistentCommandAliases() {
        expectProgram([
            ("TOOL=$(pick-command); \"$TOOL\" --version", nil), ("TOOL=\"git status\"; \"$TOOL\"", nil),
            ("# TOOL=git\n$TOOL status", nil), ("TOOL=git true; \"$TOOL\" status", nil),
            ("TOOL=git; TOOL=$(pick-command); \"$TOOL\" status", nil),
            ("TOOL=git; unset TOOL; \"$TOOL\" status", nil),
        ])
    }

    /// `it.each([...])("keeps expansions inside assignment words: %s")`
    func testKeepsExpansionsInsideAssignmentWords() {
        expectProgram([("ROOT=${BASE:-path with spaces}; npm test", "npm"),
                       ("ROOT=`printf 'path with spaces'`; pnpm test", "pnpm")])
    }

    /// `it.each([...])("skips redirections before the next command: %s")`
    func testSkipsRedirectionsBeforeTheNextCommand() {
        expectProgram([
            (">/tmp/log && npm test", "npm"), ("2>/tmp/error.log; pnpm test", "pnpm"),
            ("cd /tmp && >/tmp/log npm test", "npm"), ("cd /tmp && > /tmp/log pnpm test", "pnpm"),
            ("cd /tmp && 2>&1 bun test", "bun"), ("cd /tmp && 2>& 1 node app.js", "node"),
            ("cd /tmp && &>/tmp/log git status", "git"), ("cd /tmp && *>>/tmp/log vp test", "vp"),
            ("cd /tmp && {output}>/tmp/log deno test", "deno"),
            ("cd /tmp && <<<input ruby script.rb", "ruby"),
        ])
    }

    /// `it.each([...])("skips heredoc bodies before finding the next command: %s")`
    func testSkipsHeredocBodiesBeforeFindingTheNextCommand() {
        expectProgram([
            ("cd /tmp <<EOF\nnot-a-command\nEOF\nnpm test", "npm"),
            ("cd /tmp <<'EOF'\nnot-a-command\nEOF\npnpm test", "pnpm"),
            ("cd /tmp <<'EOF'\nnot-a-command\\\nEOF\npnpm test", "pnpm"),
            ("cd /tmp <<-EOF\n\tnot-a-command\n\tEOF\nbun test", "bun"),
            ("cd /tmp <<A <<B\none\nA\ntwo\nB\ngit status", "git"),
            ("cd /tmp <<EOF; # setup\nnot-a-command\nEOF\nnpm test", "npm"),
            ("cd /tmp <<EOF && pnpm test\nnot-a-command\nEOF\nbun test", "pnpm"),
        ])
    }

    /// `it.each([...])("falls back when no useful program follows cd: %s")`
    func testFallsBackWhenNoUsefulProgramFollowsCd() {
        expectProgram([("cd apps/web && [ -f package.json ]", nil), ("cd apps/web || exit 1", nil),
                       ("cd one && cd two", nil)])
    }

    /// `it.each([...])("does not label commands inside multiline shell control flow: %s")`
    func testDoesNotLabelCommandsInsideMultilineShellControlFlow() {
        expectProgram([
            ("if test -f package.json\nthen\n  npm test\nfi", nil),
            ("[[ -d first && -d second ]] && npm test", nil),
            ("for file in *\ndo\n  echo \"$file\"\ndone", nil),
            ("while true\ndo\n  sleep 1\ndone", nil),
            ("cd /tmp; build () { npm test; }", nil),
        ])
    }

    /// `it("bounds nested shell unwrapping")`
    func testBoundsNestedShellUnwrapping() {
        var command = "git status"
        for _ in 0..<9 { command = "sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))'" }
        XCTAssertNil(T3WorkLog.commandProgramName(command))
    }

    /// `it("does not spend the shell nesting budget on setup commands")`
    func testDoesNotSpendTheShellNestingBudgetOnSetupCommands() {
        let command = ((0..<10).map { "export VALUE_\($0)=configured" } + ["npm test"]).joined(separator: "\n")
        XCTAssertEqual(T3WorkLog.commandProgramName(command), "npm")
    }

    /// `it("bounds the number of top-level setup segments")`
    func testBoundsTheNumberOfTopLevelSetupSegments() {
        let command = ((0..<2000).map { "export VALUE_\($0)=configured" } + ["npm test"]).joined(separator: ";")
        XCTAssertNil(T3WorkLog.commandProgramName(command))
    }

    /// `it("bounds nested command wrappers")`
    func testBoundsNestedCommandWrappers() {
        XCTAssertNil(T3WorkLog.commandProgramName(String(repeating: "command ", count: 9) + "git status"))
    }
}
