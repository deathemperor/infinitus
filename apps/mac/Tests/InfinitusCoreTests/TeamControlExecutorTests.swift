import XCTest
@testable import InfinitusCore

/// Spec §8: each capability is one of `infinitusctl thread`'s own
/// dispatches against the desktop, refused with the desktop's words.
final class TeamControlExecutorTests: XCTestCase {
    private final class Log: @unchecked Sendable { var calls: [(method: String, path: String, body: [String: JSONValue]?)] = [] }

    private func api(_ answers: [(Int, String)], log: Log) -> DesktopAPI {
        var queue = answers
        return DesktopAPI(origin: URL(string: "http://127.0.0.1:3773")!, token: "tok") { method, url, _, body in
            let json = body.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
            log.calls.append((method, url.path, json))
            let (status, text) = queue.removeFirst()
            return (status, Data(text.utf8))
        }
    }

    private let shell = """
    {"projects":[{"id":"p1","title":"Demo","workspaceRoot":"/w/demo","defaultModelSelection":{"provider":"claude","model":"opus"}},
                 {"id":"p2","title":"Bare","workspaceRoot":"/w/bare","defaultModelSelection":null}],
     "threads":[{"id":"t1","projectId":"p1","title":"One","latestTurn":{"turnId":"u1","state":"running"},"session":null,"updatedAt":"2026-09-12T00:00:02Z","archivedAt":null},
                {"id":"t2","projectId":"p1","title":"Old","latestTurn":null,"session":null,"updatedAt":"2026-09-12T00:00:02Z","archivedAt":"2026-09-12T00:00:02Z"}]}
    """
    private let running = """
    {"thread":{"id":"t1","projectId":"p1","title":"One","runtimeMode":"approval-required","interactionMode":"plan",
               "latestTurn":{"turnId":"u1","state":"running"},"messages":[{"id":"m1","role":"user","text":"token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"},{"id":"m2","role":"assistant","text":"noted"}]}}
    """
    private let idle = """
    {"thread":{"id":"t1","projectId":"p1","title":"One","latestTurn":{"turnId":"u1","state":"completed"},"messages":[]}}
    """

    func command(_ action: String, thread: String = "t1", text: String? = "hello", project: String? = nil) -> TeamControl.Command {
        TeamControl.Command(id: "c-0123456789", to: "g", thread: thread, action: action, text: text, project: project, at: 1)
    }

    func testThreadsAreTheUnarchivedShellIds() {
        let log = Log()
        XCTAssertEqual(TeamControlExecutor.threads(api([(200, shell)], log: log)), ["t1"])
        XCTAssertEqual(TeamControlExecutor.threads(api([(500, "")], log: log)), [], "a desktop that does not answer has no threads")
    }

    func testSendStartsATurnInTheThreadsOwnModes() {
        let log = Log()
        let reply = TeamControlExecutor.execute(command(TeamGrants.send), api: api([(200, running), (200, "{\"sequence\":3}")], log: log), home: "/Users/me")
        XCTAssertEqual(reply, TeamControl.Reply(outcome: "delivered"))
        let dispatched = log.calls.last?.body
        XCTAssertEqual(log.calls.last?.path, "/api/orchestration/dispatch")
        XCTAssertEqual(dispatched?["type"], .string("thread.turn.start"))
        XCTAssertEqual(dispatched?["threadId"], .string("t1"))
        XCTAssertEqual(dispatched?["runtimeMode"], .string("approval-required"))
        XCTAssertEqual(dispatched?["interactionMode"], .string("plan"))
        XCTAssertEqual(dispatched?["message"]?["text"], .string("hello"))
        XCTAssertEqual(TeamControlExecutor.execute(command(TeamGrants.send, text: "  "), api: api([], log: log), home: "/").outcome, "refused")
    }

    func testInterruptNeedsARunningTurn() {
        let log = Log()
        let done = TeamControlExecutor.execute(command(TeamGrants.interrupt, text: nil), api: api([(200, running), (200, "{\"sequence\":4}")], log: log), home: "/")
        XCTAssertEqual(done, TeamControl.Reply(outcome: "done"))
        XCTAssertEqual(log.calls.last?.body?["type"], .string("thread.turn.interrupt"))
        XCTAssertEqual(log.calls.last?.body?["turnId"], .string("u1"))
        let none = TeamControlExecutor.execute(command(TeamGrants.interrupt, text: nil), api: api([(200, idle)], log: log), home: "/")
        XCTAssertEqual(none, TeamControl.Reply(outcome: "refused", detail: "no running turn"))
    }

    func testNewCreatesAThreadOnTheProjectsDefaultModelOrRefuses() {
        let log = Log()
        let made = TeamControlExecutor.execute(command(TeamGrants.new, thread: "-", text: "Fix the build\nplease", project: "Demo"),
                                               api: api([(200, shell), (404, ""), (200, "{\"sequence\":5}")], log: log), home: "/")
        XCTAssertEqual(made.outcome, "done")
        XCTAssertEqual(made.detail?.count, 36, "the new thread's id")
        let body = log.calls.last?.body
        XCTAssertEqual(body?["bootstrap"]?["createThread"]?["projectId"], .string("p1"))
        XCTAssertEqual(body?["bootstrap"]?["createThread"]?["title"], .string("Fix the build"))
        XCTAssertEqual(body?["bootstrap"]?["createThread"]?["modelSelection"], .object(["provider": .string("claude"), "model": .string("opus")]))
        XCTAssertEqual(body?["titleSeed"], .string("Fix the build\nplease"))
        XCTAssertEqual(TeamControlExecutor.execute(command(TeamGrants.new, thread: "-", text: "x", project: "Nope"),
                                                   api: api([(200, shell)], log: log), home: "/"),
                       TeamControl.Reply(outcome: "refused", detail: "no project Nope"))
        let bare = TeamControlExecutor.execute(command(TeamGrants.new, thread: "-", text: "x", project: "p2"),
                                               api: api([(200, shell), (200, "{\"defaultModelSelection\":null}")], log: log), home: "/")
        XCTAssertEqual(bare.outcome, "refused")
        XCTAssertTrue(bare.detail?.contains("no default model") == true, bare.detail ?? "")
    }

    func testViewAnswersTheRedactedLastTurnAndDesktopFailuresAreRefusals() {
        let log = Log()
        let viewed = TeamControlExecutor.execute(command(TeamGrants.view, text: nil), api: api([(200, running)], log: log), home: "/Users/me")
        XCTAssertEqual(viewed.outcome, "done")
        XCTAssertEqual(viewed.detail?.contains("assistant: noted"), true)
        XCTAssertEqual(viewed.detail?.contains("sk-ant-api03-abc"), false, "the API key is redacted: \(viewed.detail ?? "")")
        XCTAssertEqual(log.calls.map(\.path), ["/api/orchestration/threads/t1"])
        let gone = TeamControlExecutor.execute(command(TeamGrants.view, thread: "t9", text: nil), api: api([(404, "no thread t9")], log: log), home: "/")
        XCTAssertEqual(gone.outcome, "refused")
        XCTAssertEqual(gone.detail, "Infinitus desktop answered 404: no thread t9")
        XCTAssertEqual(TeamControlExecutor.capped(String(repeating: "x", count: 5_000)).count, TeamControl.viewDetailCap + 1)
    }
}
