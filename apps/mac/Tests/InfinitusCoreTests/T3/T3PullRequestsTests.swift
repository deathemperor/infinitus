import XCTest
@testable import InfinitusCore

/// Canned `gh pr list --json …` output — the shape a real read answers
/// (probed against this repository: fields alphabetical, `reviewDecision: ""`
/// where a host summarises nothing, `conclusion: ""` and
/// `completedAt: "0001-01-01T00:00:00Z"` on a run that has not finished, a
/// `StatusContext` row carrying `context`/`state`/`targetUrl` beside the
/// `CheckRun` ones). The mapping under test is the server's own
/// (`apps/server/src/pullRequest/gitHubPullRequestJson.ts:1221-1324`,
/// `pullRequestChecks.ts:30-56`) and the summary is the page's
/// (`pullRequestPresentation.tsx:421-446`).
final class T3PullRequestsTests: XCTestCase {

    private func entry(_ json: String) throws -> T3PullRequests.Entry {
        try T3PullRequests.decodeEntry(Data(json.utf8))
    }

    private func check(_ name: String, _ status: T3PullRequests.CheckStatus,
                       url: String? = nil) -> T3PullRequests.Check {
        T3PullRequests.Check(name: name, status: status, url: url)
    }

    // MARK: - Decode

    func testDecodesAList() throws {
        let json = """
        [{"author":{"id":"MDQ6VXNlcjE=","is_bot":false,"login":"deathemperor","name":"Loc"},
          "baseRefName":"main","headRefName":"stats-peaks","isDraft":false,"number":515,
          "reviewDecision":"APPROVED","state":"OPEN","statusCheckRollup":[],
          "title":"stats: a settled day keeps its peak","updatedAt":"2026-09-09T22:55:11Z",
          "url":"https://github.com/deathemperor/infinitus/pull/515"},
         {"author":null,"baseRefName":"main","headRefName":"win-core","isDraft":false,"number":228,
          "reviewDecision":"","state":"OPEN","statusCheckRollup":[],"title":"win: shared core",
          "updatedAt":"2026-09-06T10:00:00Z","url":"https://github.com/deathemperor/infinitus/pull/228"}]
        """
        let entries = try T3PullRequests.decodeList(Data(json.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].number, 515)
        XCTAssertEqual(entries[0].title, "stats: a settled day keeps its peak")
        XCTAssertEqual(entries[0].headBranch, "stats-peaks")
        XCTAssertEqual(entries[0].baseBranch, "main")
        XCTAssertEqual(entries[0].state, .open)
        XCTAssertFalse(entries[0].isDraft)
        XCTAssertEqual(entries[0].author?.login, "deathemperor")
        XCTAssertEqual(entries[0].author?.name, "Loc")
        // `gh pr list --json author` reports no avatar.
        XCTAssertNil(entries[0].author?.avatarUrl)
        XCTAssertEqual(entries[0].reviewDecision, .approved)
        XCTAssertEqual(entries[0].updatedAt.timeIntervalSince1970, 1788994511, accuracy: 1)
        // A deleted account is `null`, which the page names "ghost" itself.
        XCTAssertNil(entries[1].author)
        // `""` is the absence of a verdict, not a verdict.
        XCTAssertNil(entries[1].reviewDecision)
        // No rollup at all shows nothing rather than a tick nobody earned.
        XCTAssertNil(entries[1].checksState)
    }

    func testDecodesADraftAndTheOtherStates() throws {
        func one(_ state: String, draft: Bool) -> String {
            """
            {"author":{"login":"a"},"baseRefName":"main","headRefName":"h","isDraft":\(draft),
             "number":7,"reviewDecision":"CHANGES_REQUESTED","state":"\(state)",
             "statusCheckRollup":null,"title":"t","updatedAt":"2026-09-01T00:00:00Z",
             "url":"https://github.com/o/r/pull/7"}
            """
        }
        let draft = try entry(one("OPEN", draft: true))
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.state, .open)
        XCTAssertEqual(draft.reviewDecision, .changesRequested)
        // `resolvePullRequestState` (`pullRequestPresentation.tsx:41-83`):
        // draft outranks open, merged and closed outrank draft.
        XCTAssertEqual(T3PullRequests.stateLabel(state: .open, isDraft: true), "Draft")
        XCTAssertEqual(T3PullRequests.stateLabel(state: .open, isDraft: false), "Open")
        XCTAssertEqual(try entry(one("MERGED", draft: true)).state, .merged)
        XCTAssertEqual(T3PullRequests.stateLabel(state: .merged, isDraft: true), "Merged")
        XCTAssertEqual(try entry(one("CLOSED", draft: false)).state, .closed)
        XCTAssertEqual(T3PullRequests.stateLabel(state: .closed, isDraft: false), "Closed")
    }

    func testRefusesAnEntryWithoutTheFieldsARowNeeds() {
        let json = """
        {"author":null,"baseRefName":"main","headRefName":"h","isDraft":false,"number":3,
         "state":"","statusCheckRollup":[],"title":"t","updatedAt":"2026-09-01T00:00:00Z",
         "url":"https://github.com/o/r/pull/3"}
        """
        XCTAssertThrowsError(try entry(json)) { error in
            XCTAssertEqual(error as? T3PullRequests.Malformed, T3PullRequests.Malformed(field: "state"))
        }
    }

    func testDecodesABody() throws {
        let json = "{\"body\":\"## Why\\n\\nBecause.\"}"
        let text = try T3PullRequests.decodeBody(Data(json.utf8))
        XCTAssertEqual(text, "## Why\n\nBecause.")
        // gh writes `""` for an empty description, and `null` where a field
        // was not asked for; neither is a failure.
        XCTAssertEqual(try T3PullRequests.decodeBody(Data(#"{"body":null}"#.utf8)), "")
    }

    // MARK: - The checks rollup

    /// The real thing: a queued run (`status: QUEUED`, empty conclusion, the
    /// unset completion sentinel), completed ones, a skipped one, and a
    /// commit status that reports `state` with no `status` at all.
    func testDecodesAChecksRollup() throws {
        let json = """
        {"author":{"login":"a"},"baseRefName":"main","headRefName":"h","isDraft":false,"number":9,
         "reviewDecision":"","state":"OPEN","title":"t","updatedAt":"2026-09-09T22:55:11Z",
         "url":"https://github.com/o/r/pull/9","statusCheckRollup":[
          {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"",
           "detailsUrl":"https://github.com/o/r/actions/runs/1/job/2","name":"test-core",
           "startedAt":"2026-09-09T22:54:22Z","status":"QUEUED","workflowName":"CI"},
          {"__typename":"CheckRun","completedAt":"2026-09-09T22:54:27Z","conclusion":"SUCCESS",
           "detailsUrl":"https://github.com/o/r/actions/runs/3/job/4","name":"Label PR size",
           "startedAt":"2026-09-09T22:54:24Z","status":"COMPLETED","workflowName":"PR Size"},
          {"__typename":"CheckRun","completedAt":"2026-09-09T22:54:27Z","conclusion":"SKIPPED",
           "detailsUrl":"https://github.com/o/r/actions/runs/5/job/6","name":"Sync labels",
           "startedAt":"2026-09-09T22:54:27Z","status":"COMPLETED","workflowName":"PR Size"},
          {"__typename":"StatusContext","context":"CodeRabbit","startedAt":"2026-09-09T22:54:34Z",
           "state":"SUCCESS","targetUrl":""}]}
        """
        let pr = try entry(json)
        XCTAssertEqual(pr.checks.map(\.name), ["test-core", "Label PR size", "Sync labels", "CodeRabbit"])
        XCTAssertEqual(pr.checks.map(\.status), [.pending, .success, .skipped, .success])
        // `detailsUrl` where a run has one, `targetUrl` for a commit status —
        // and `""` is no url at all.
        XCTAssertEqual(pr.checks[1].url, "https://github.com/o/r/actions/runs/3/job/4")
        XCTAssertNil(pr.checks[3].url)
        // A run still going outranks the passes.
        XCTAssertEqual(pr.checksState, .pending)
        XCTAssertEqual(T3PullRequests.summarize(checks: pr.checks), "1 of 4 running")
    }

    func testTheRollupCountsThePassesFailuresAndWaits() {
        // Every conclusion GitHub reports, as the server reads it.
        func status(_ raw: T3PullRequests.RawCheck) -> T3PullRequests.CheckStatus {
            T3PullRequests.checkStatus(raw)
        }
        var run = T3PullRequests.RawCheck()
        run.status = "COMPLETED"
        for (conclusion, expected): (String, T3PullRequests.CheckStatus) in [
            ("SUCCESS", .success), ("ACTION_REQUIRED", .actionRequired), ("FAILURE", .failure),
            ("ERROR", .failure), ("TIMED_OUT", .failure), ("STARTUP_FAILURE", .failure),
            ("CANCELLED", .cancelled), ("SKIPPED", .skipped), ("NEUTRAL", .neutral),
        ] {
            run.conclusion = conclusion
            XCTAssertEqual(status(run), expected, conclusion)
        }
        // A run that has not completed is pending whatever it concludes later.
        var queued = T3PullRequests.RawCheck()
        queued.status = "IN_PROGRESS"
        queued.conclusion = "SUCCESS"
        XCTAssertEqual(status(queued), .pending)
        // A commit status reports `state` and no `status`.
        var context = T3PullRequests.RawCheck()
        context.state = "PENDING"
        XCTAssertEqual(status(context), .pending)
        context.state = "EXPECTED"
        XCTAssertEqual(status(context), .pending)
        context.state = "ERROR"
        XCTAssertEqual(status(context), .failure)

        // `rollupChecksState` (`gitHubPullRequestJson.ts:1307-1318`): failure
        // outranks a wait, a wait outranks a pass, and a rollup that is only
        // skips is no verdict at all.
        XCTAssertEqual(T3PullRequests.checksState(rollup: nil), nil)
        XCTAssertEqual(T3PullRequests.checksState(rollup: rollup([("a", "SUCCESS"), ("b", "SUCCESS")])), .passing)
        XCTAssertEqual(T3PullRequests.checksState(rollup: rollup([("a", "SUCCESS"), ("b", "FAILURE")])), .failing)
        XCTAssertEqual(T3PullRequests.checksState(rollup: rollup([("a", "SKIPPED"), ("b", "SUCCESS")])), .passing)
        XCTAssertEqual(T3PullRequests.checksState(rollup: rollup([("a", "SKIPPED"), ("b", "NEUTRAL")])), nil)
        XCTAssertEqual(T3PullRequests.checksState(rollup: rollup([("a", "ACTION_REQUIRED")])), .pending)
        // And a nameless row — GitHub's own rollup enum, as the cross-repository
        // search dresses it — still counts (`:1256-1258`, `:1311`).
        var nameless = T3PullRequests.RawCheck()
        nameless.status = "COMPLETED"
        nameless.conclusion = "FAILURE"
        XCTAssertEqual(T3PullRequests.checksState(rollup: [nameless]), .failing)
        XCTAssertTrue(T3PullRequests.checks(rollup: [nameless]).isEmpty)

        // The rollup's own headlines (`pullRequestPresentation.tsx:165-181`).
        XCTAssertEqual(T3PullRequests.checksStateLabel(.passing), "All checks have passed")
        XCTAssertEqual(T3PullRequests.checksStateLabel(.failing), "Some checks were not successful")
        XCTAssertEqual(T3PullRequests.checksStateLabel(.pending), "Some checks haven't completed yet")
    }

    /// A re-run arrives beside the run it repeats; one row survives, at the
    /// place the check first appeared (`pullRequestChecks.ts:30-56`).
    func testOneRowPerCheckRatherThanPerRun() {
        var first = T3PullRequests.RawCheck()
        first.name = "test"
        first.workflowName = "CI"
        first.status = "COMPLETED"
        first.conclusion = "FAILURE"
        first.completedAt = "2026-09-09T10:00:00Z"
        var rerun = first
        rerun.conclusion = "SUCCESS"
        rerun.completedAt = "2026-09-09T11:00:00Z"
        var other = first
        other.name = "lint"
        let checks = T3PullRequests.checks(rollup: [first, other, rerun])
        XCTAssertEqual(checks.map(\.name), ["test", "lint"])
        XCTAssertEqual(checks[0].status, .success)
        // A queued re-run reports no completion time; its start stands in, so
        // it still beats the run before it.
        var queued = first
        queued.status = "QUEUED"
        queued.conclusion = ""
        queued.completedAt = T3PullRequests.unsetTimestamp
        queued.startedAt = "2026-09-09T12:00:00Z"
        XCTAssertEqual(T3PullRequests.checks(rollup: [first, queued]).map(\.status), [.pending])
        // Two survivors under one name came from different workflows, and are
        // written the way GitHub writes them.
        var elsewhere = first
        elsewhere.workflowName = "Nightly"
        XCTAssertEqual(T3PullRequests.checks(rollup: [first, elsewhere]).map(\.name),
                       ["CI / test", "Nightly / test"])
    }

    func testSummarizesTheChecksTheWayThePageDoes() {
        XCTAssertEqual(T3PullRequests.summarize(checks: []), "No checks reported")
        XCTAssertEqual(T3PullRequests.summarize(checks: [check("a", .success), check("b", .success)]),
                       "All checks passed")
        XCTAssertEqual(T3PullRequests.summarize(checks: [check("a", .success), check("b", .skipped)]),
                       "1 of 2 passing")
        // A cancelled run counts with the failures in the sentence.
        XCTAssertEqual(T3PullRequests.summarize(checks: [check("a", .failure), check("b", .cancelled), check("c", .success)]),
                       "2 of 3 failing")
        XCTAssertEqual(T3PullRequests.summarize(checks: [check("a", .pending), check("b", .success)]),
                       "1 of 2 running")
        // A fork's workflow waiting to be allowed to run reads differently
        // from a check waiting on somebody (`pullRequestPresentation.tsx:152`).
        let approval = check("wf", .actionRequired, url: "https://github.com/o/r/actions/runs/42")
        XCTAssertEqual(T3PullRequests.summarize(checks: [approval]), "1 workflow awaiting approval")
        let other = check("deploy", .actionRequired, url: "https://example.com/gate")
        XCTAssertEqual(T3PullRequests.summarize(checks: [other]), "1 check awaiting action")
        XCTAssertEqual(T3PullRequests.summarize(checks: [approval, other]),
                       "1 workflow and 1 check awaiting action")
        // A failure outranks every wait.
        XCTAssertEqual(T3PullRequests.summarize(checks: [approval, check("a", .failure)]), "1 of 2 failing")
    }

    // MARK: - The availability rule

    func testTheRemoteRuleTakesTheHostNotASubstring() {
        for url in ["git@github.com:deathemperor/infinitus.git",
                    "https://github.com/deathemperor/infinitus.git",
                    "https://github.com/deathemperor/infinitus",
                    "ssh://git@github.com/deathemperor/infinitus.git",
                    "git@GitHub.com:deathemperor/infinitus.git",
                    "  git@github.com:deathemperor/infinitus.git\n"] {
            XCTAssertTrue(T3PullRequests.isGitHubRemote(url), url)
        }
        for url in ["git@gitlab.com:deathemperor/infinitus.git",
                    "https://gitlab.com/o/r.git",
                    "https://github.com.example.com/o/r.git",
                    "git@github.com.example.com:o/r.git",
                    "git@notgithub.com:o/r.git",
                    "https://ghe.example.com/o/r.git",
                    "/Users/deathemperor/death/limitless",
                    ""] {
            XCTAssertFalse(T3PullRequests.isGitHubRemote(url), url)
        }
    }

    func testAProjectWithNoRemoteIsUnavailable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3pr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a work tree at all, and then one with no `origin`: both are
        // "no GitHub remote", which is the gate the tab reads.
        XCTAssertEqual(T3PullRequests.availability(cwd: root.path), .noGitHubRemote)
        let git = GitRunner(timeout: 10)
        try git.run(["init", "-q"], cwd: root.path)
        XCTAssertEqual(T3PullRequests.availability(cwd: root.path), .noGitHubRemote)
        XCTAssertFalse(T3PullRequests.available(cwd: root.path))
        // The list refuses to run gh for it rather than answering empty.
        XCTAssertEqual(T3PullRequests.list(cwd: root.path).failureMessage,
                       "This project has no GitHub remote.")
        try git.run(["remote", "add", "origin", "git@gitlab.com:o/r.git"], cwd: root.path)
        XCTAssertEqual(T3PullRequests.availability(cwd: root.path), .noGitHubRemote)
    }
}

private extension Result where Success == [T3PullRequests.Entry], Failure == T3PullRequests.LoadError {
    var failureMessage: String? {
        guard case .failure(let error) = self else { return nil }
        return error.message
    }
}

/// `(name, conclusion)` pairs as completed check runs.
private func rollup(_ pairs: [(String, String)]) -> [T3PullRequests.RawCheck] {
    pairs.map { pair in
        var raw = T3PullRequests.RawCheck()
        raw.name = pair.0
        raw.status = "COMPLETED"
        raw.conclusion = pair.1
        return raw
    }
}
