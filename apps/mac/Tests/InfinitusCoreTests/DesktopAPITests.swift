import XCTest
@testable import InfinitusCore

/// #822: the CLI's desktop verbs — the HTTP client against a canned
/// transport (no sockets, so Linux runs it too) and the pure row/command
/// builders.
final class DesktopAPITests: XCTestCase {
    private struct Call { var method: String; var url: String; var headers: [String: String]; var body: String? }
    private final class Log: @unchecked Sendable { var calls: [Call] = [] }

    private func api(_ answers: [(Int, String)], log: Log) -> DesktopAPI {
        var queue = answers
        return DesktopAPI(origin: URL(string: "http://127.0.0.1:3773")!, token: "tok-secret-1234") { method, url, headers, body in
            log.calls.append(Call(method: method, url: url.absoluteString, headers: headers, body: body.map { String(decoding: $0, as: UTF8.self) }))
            let (status, text) = queue.removeFirst()
            return (status, Data(text.utf8))
        }
    }

    private let shellJSON = """
    {"snapshotSequence":7,"projects":[{"id":"p1","title":"Infinitus","workspaceRoot":"/w/infinitus","defaultModelSelection":{"provider":"claude","model":"opus"},"scripts":[],"createdAt":"2026-09-12T00:00:00Z","updatedAt":"2026-09-12T00:00:00Z"}],
     "threads":[{"id":"t1","projectId":"p1","title":"Running one","modelSelection":null,"runtimeMode":"full-access","interactionMode":"default","branch":"feat/x","worktreePath":"/w/infinitus/.wt/x",
                 "latestTurn":{"turnId":"u1","state":"running","requestedAt":"2026-09-12T00:00:01Z","startedAt":"2026-09-12T00:00:01Z","completedAt":null,"assistantMessageId":null},
                 "session":{"threadId":"t1","status":"running","activeTurnId":"u1"},"updatedAt":"2026-09-12T00:00:02Z","archivedAt":null,"hasPendingApprovals":false,"hasPendingUserInput":false,"hasActionableProposedPlan":false},
                {"id":"t2","projectId":"p1","title":"Idle one","latestTurn":{"turnId":"u2","state":"completed","assistantMessageId":"m2"},"session":null,"updatedAt":"2026-09-12T00:00:03Z","hasPendingApprovals":false,"hasPendingUserInput":false}],
     "updatedAt":"2026-09-12T00:00:03Z"}
    """

    func testShellDecodesTheFieldsTheVerbsReadAndSendsTheBearer() throws {
        let log = Log()
        let shell = try api([(200, shellJSON)], log: log).shell()
        XCTAssertEqual(shell.projects.map(\.id), ["p1"])
        XCTAssertEqual(shell.threads.map(\.id), ["t1", "t2"])
        XCTAssertEqual(shell.threads[0].latestTurn?.state, "running")
        XCTAssertEqual(shell.threads[0].worktreePath, "/w/infinitus/.wt/x")
        XCTAssertNil(shell.threads[1].session)
        XCTAssertEqual(shell.projects[0].defaultModelSelection, .object(["provider": .string("claude"), "model": .string("opus")]))
        XCTAssertEqual(log.calls.map(\.url), ["http://127.0.0.1:3773/api/orchestration/shell"])
        XCTAssertEqual(log.calls[0].headers["Authorization"], "Bearer tok-secret-1234")
        XCTAssertEqual(log.calls[0].method, "GET")
    }

    func testThreadDetailPathCarriesTheTurnLimitAndEscapesTheId() throws {
        let log = Log()
        let detail = """
        {"id":"t 1","projectId":"p1","title":"T","latestTurn":{"turnId":"u9","state":"completed","assistantMessageId":"m9"},"session":null,
         "messages":[{"id":"m8","role":"user","text":"hi","turnId":"u9","streaming":false,"createdAt":"2026-09-12T00:00:00Z"},
                     {"id":"m9","role":"assistant","text":"hello","turnId":"u9","streaming":false,"createdAt":"2026-09-12T00:00:01Z"}],
         "activities":[],"proposedPlans":[],"checkpoints":[]}
        """
        let thread = try api([(200, detail)], log: log).thread("t 1", turnLimit: 3)
        XCTAssertEqual(thread.messages.map(\.text), ["hi", "hello"])
        XCTAssertEqual(log.calls[0].url, "http://127.0.0.1:3773/api/orchestration/threads/t%201?turnLimit=3")
    }

    func testANonSuccessAnswerIsAFailureWithTheDesktopsStatusAndBody() {
        let log = Log()
        XCTAssertThrowsError(try api([(500, "{\"error\":\"boom\"}")], log: log).shell()) { error in
            let failure = error as? DesktopAPI.Failure
            XCTAssertEqual(failure?.status, 500)
            XCTAssertEqual(failure?.body, "{\"error\":\"boom\"}")
            XCTAssertEqual(failure?.description, "Infinitus desktop answered 500: {\"error\":\"boom\"}")
            XCTAssertEqual(failure?.unauthorized, false)
        }
    }

    func testHoldsAreEmptyOnADesktopWithoutTheRouteAndSessionAcceptedReadsTheAuthenticatedFlag() throws {
        let log = Log()
        let a = api([(404, "not found"), (200, "[{\"threadId\":\"t2\",\"since\":\"2026-09-12T00:00:00Z\",\"summary\":\"at limit\",\"kind\":\"held\"}]"),
                     (200, "{\"authenticated\":false,\"auth\":{}}"), (401, "{\"error\":\"Unauthorized\"}"),
                     (200, "{\"authenticated\":true,\"auth\":{},\"scopes\":[\"orchestration:read\"]}")], log: log)
        XCTAssertEqual(try a.holds(), [])
        XCTAssertEqual(try a.holds().map(\.threadId), ["t2"])
        XCTAssertFalse(try a.sessionAccepted(), "the route answers everyone; a revoked session is authenticated:false")
        XCTAssertFalse(try a.sessionAccepted(), "a 401 reads as revoked too")
        XCTAssertTrue(try a.sessionAccepted())
        XCTAssertEqual(log.calls.map(\.url).last, "http://127.0.0.1:3773/api/auth/session")
    }

    func testDispatchPostsTheCommandAsJSONAndReadsTheSequence() throws {
        let log = Log()
        let a = api([(200, "{\"sequence\":42}"), (200, "{\"released\":true}")], log: log)
        XCTAssertEqual(try a.dispatch(.object(["type": .string("thread.turn.interrupt"), "threadId": .string("t1")])), 42)
        XCTAssertEqual(log.calls[0].method, "POST")
        XCTAssertEqual(log.calls[0].url, "http://127.0.0.1:3773/api/orchestration/dispatch")
        XCTAssertEqual(log.calls[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(log.calls[0].body, "{\"threadId\":\"t1\",\"type\":\"thread.turn.interrupt\"}")
        XCTAssertEqual(try a.releaseThread("t2"), DesktopAPI.Release(released: true, reason: nil))
        XCTAssertEqual(log.calls[1].body, "{\"threadId\":\"t2\"}")
    }

    // MARK: rows

    func testStatusVocabularyIsDerivedFromTheTurnTheSessionTheFlagsAndTheHold() throws {
        let shell = try JSONDecoder().decode(DesktopAPI.Shell.self, from: Data(shellJSON.utf8))
        var running = shell.threads[0], idle = shell.threads[1]
        XCTAssertEqual(DesktopRows.status(running, hold: nil), "running")
        XCTAssertEqual(DesktopRows.status(idle, hold: nil), "idle")
        idle.session = .init(status: "starting")
        XCTAssertEqual(DesktopRows.status(idle, hold: nil), "running", "a starting session counts as running")
        running.hasPendingApprovals = true
        XCTAssertEqual(DesktopRows.status(running, hold: nil), "waiting", "an approval outranks the running turn")
        let hold = DesktopAPI.Hold(threadId: "t1", since: nil, summary: "at limit", kind: nil)
        XCTAssertEqual(DesktopRows.status(running, hold: hold), "held", "a hold outranks everything")
        XCTAssertEqual(DesktopRows.status(running, hold: .init(threadId: "t1", since: nil, summary: nil, kind: "paused")), "paused")
        let row = DesktopRows.threadRow(shell.threads[0], project: shell.projects[0], hold: hold)
        XCTAssertEqual(row["project"], .string("Infinitus"))
        XCTAssertEqual(row["status"], .string("held"))
        XCTAssertEqual(row["worktree"], .string("/w/infinitus/.wt/x"))
        XCTAssertEqual(row["hold"]?["summary"], .string("at limit"))
        XCTAssertEqual(row["turn"]?["state"], .string("running"))
        XCTAssertNil(DesktopRows.threadRow(shell.threads[1], project: nil, hold: nil)["worktree"])
        XCTAssertEqual(DesktopRows.threadRow(shell.threads[1], project: nil, hold: nil)["project"], .string("p1"), "an unknown project prints its id")
    }

    func testTurnStartCarriesTheMessageTheModesAndAnOptionalBootstrap() throws {
        var n = 0
        let ids = { () -> String in n += 1; return "id\(n)" }
        let now = Date(timeIntervalSince1970: 1_789_171_200)
        let (command, messageId) = DesktopRows.turnStart(threadId: "t2", text: "do it", runtimeMode: "auto", interactionMode: "plan", now: now, id: ids)
        XCTAssertEqual(messageId, "id1")
        XCTAssertEqual(command["type"], .string("thread.turn.start"))
        XCTAssertEqual(command["commandId"], .string("id2"))
        XCTAssertEqual(command["message"]?["messageId"], .string("id1"))
        XCTAssertEqual(command["message"]?["role"], .string("user"))
        XCTAssertEqual(command["message"]?["attachments"], .array([]))
        XCTAssertEqual(command["runtimeMode"], .string("auto"))
        XCTAssertEqual(command["interactionMode"], .string("plan"))
        XCTAssertEqual(command["createdAt"], .string("2026-09-12T00:00:00.000Z"))
        XCTAssertNil(command["bootstrap"])
        XCTAssertNil(command["titleSeed"])

        let project = try JSONDecoder().decode(DesktopAPI.Shell.self, from: Data(shellJSON.utf8)).projects[0]
        let bootstrap = DesktopRows.newThreadBootstrap(project: project, model: project.defaultModelSelection!, title: "Fix the thing",
                                                       runtimeMode: "full-access", interactionMode: "default",
                                                       worktree: "fix/thing", baseBranch: "main", now: now)
        XCTAssertEqual(bootstrap["createThread"]?["projectId"], .string("p1"))
        XCTAssertEqual(bootstrap["createThread"]?["modelSelection"], .object(["provider": .string("claude"), "model": .string("opus")]))
        XCTAssertEqual(bootstrap["createThread"]?["branch"], .string("fix/thing"))
        XCTAssertEqual(bootstrap["createThread"]?["worktreePath"], .null)
        XCTAssertEqual(bootstrap["prepareWorktree"]?["projectCwd"], .string("/w/infinitus"))
        XCTAssertEqual(bootstrap["prepareWorktree"]?["baseBranch"], .string("main"))
        XCTAssertEqual(bootstrap["prepareWorktree"]?["branch"], .string("fix/thing"))
        let plain = DesktopRows.newThreadBootstrap(project: project, model: .null, title: "T", runtimeMode: "full-access",
                                                   interactionMode: "default", worktree: nil, baseBranch: "main", now: now)
        XCTAssertNil(plain["prepareWorktree"])
        XCTAssertEqual(plain["createThread"]?["branch"], .null)

        let interrupt = DesktopRows.turnInterrupt(threadId: "t1", turnId: "u1", now: now, id: ids)
        XCTAssertEqual(interrupt["type"], .string("thread.turn.interrupt"))
        XCTAssertEqual(interrupt["turnId"], .string("u1"))
        XCTAssertNil(DesktopRows.turnInterrupt(threadId: "t1", turnId: nil, now: now, id: ids)["turnId"])
    }

    func testTitleMaskAndStatusList() {
        XCTAssertEqual(DesktopRows.title(from: "  Fix the build\nand more"), "Fix the build")
        XCTAssertEqual(DesktopRows.title(from: "\n\n"), "New thread")
        XCTAssertEqual(DesktopRows.title(from: String(repeating: "x", count: 100)).count, 80)
        XCTAssertEqual(DesktopRows.masked("tok-secret-1234"), "…1234")
        XCTAssertEqual(DesktopRows.masked("abc"), "…")
        XCTAssertEqual(DesktopRows.statuses, ["running", "held", "paused", "waiting", "idle"])
    }
}
