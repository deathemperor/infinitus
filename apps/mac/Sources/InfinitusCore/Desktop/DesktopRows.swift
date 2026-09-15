import Foundation

/// The pure half of the desktop verbs (#822): what a thread's status is,
/// what a row prints, and the client commands `thread send|new|interrupt`
/// dispatch. No I/O, so the shapes are unit-tested byte for byte.
public enum DesktopRows {
    /// `threads --status` vocabulary, derived here — the desktop has none.
    public static let statuses = ["running", "held", "paused", "waiting", "idle"]
    public static let defaultRuntimeMode = "full-access"
    public static let defaultInteractionMode = "default"

    /// held/paused when the desktop holds it (#616/#743), waiting on an
    /// approval or a question, running while a turn runs or the session
    /// starts, idle otherwise.
    public static func status(_ t: DesktopAPI.ThreadShell, hold: DesktopAPI.Hold?) -> String {
        if let hold { return hold.kind == "paused" ? "paused" : "held" }
        if t.hasPendingApprovals == true || t.hasPendingUserInput == true { return "waiting" }
        if t.latestTurn?.state == "running" || ["running", "starting"].contains(t.session?.status ?? "") { return "running" }
        return "idle"
    }

    public static func projectRow(_ p: DesktopAPI.Project) -> JSONValue {
        .object(["id": .string(p.id), "name": .string(p.title), "path": .string(p.workspaceRoot),
                 "model": p.defaultModelSelection ?? .null])
    }

    public static func threadRow(_ t: DesktopAPI.ThreadShell, project: DesktopAPI.Project?, hold: DesktopAPI.Hold?) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(t.id), "title": .string(t.title), "project": .string(project?.title ?? t.projectId),
            "projectId": .string(t.projectId), "status": .string(status(t, hold: hold)),
            "updatedAt": t.updatedAt.map(JSONValue.string) ?? .null,
        ]
        if let turn = t.latestTurn { row["turn"] = .object(["id": .string(turn.turnId), "state": .string(turn.state)]) }
        if let path = t.worktreePath { row["worktree"] = .string(path) }
        if let branch = t.branch { row["branch"] = .string(branch) }
        if let hold {
            row["hold"] = .object(["kind": .string(hold.kind ?? "held"), "summary": hold.summary.map(JSONValue.string) ?? .null,
                                   "since": hold.since.map(JSONValue.string) ?? .null])
        }
        return .object(row)
    }

    public static func messageRow(_ m: DesktopAPI.Message) -> JSONValue {
        .object(["id": .string(m.id), "role": .string(m.role), "text": .string(m.text),
                 "turnId": m.turnId.map(JSONValue.string) ?? .null, "createdAt": m.createdAt.map(JSONValue.string) ?? .null])
    }

    // MARK: client commands (`POST /api/orchestration/dispatch` payloads)

    /// `thread.turn.start`; the message id is the CLI's (the desktop
    /// answers only a sequence), so the caller prints it.
    public static func turnStart(threadId: String, text: String, runtimeMode: String, interactionMode: String,
                                 titleSeed: String? = nil, bootstrap: JSONValue? = nil,
                                 now: Date = Date(), id: () -> String = newID) -> (command: JSONValue, messageId: String) {
        let messageId = id()
        var command: [String: JSONValue] = [
            "type": .string("thread.turn.start"), "commandId": .string(id()), "threadId": .string(threadId),
            "message": .object(["messageId": .string(messageId), "role": .string("user"), "text": .string(text), "attachments": .array([])]),
            "runtimeMode": .string(runtimeMode), "interactionMode": .string(interactionMode),
            "createdAt": .string(iso(now)),
        ]
        if let titleSeed { command["titleSeed"] = .string(titleSeed) }
        if let bootstrap { command["bootstrap"] = bootstrap }
        return (.object(command), messageId)
    }

    /// Why `thread new` has no model to create the thread on (#1315).
    public struct NoModel: Error, Equatable { public let message: String }

    /// The model `thread new` creates the thread on (#1315): `--model`
    /// first — `instanceId/model`, or a bare `model` on the instance of
    /// whichever default names one (the project's, else the environment's)
    /// — else the project's default, else the environment's. Refuses when
    /// none of them answers. A default's instance is its `instanceId`, or
    /// the `provider` of a rollout-era row (the server promotes that too).
    public static func modelSelection(option: String?, project: DesktopAPI.Project, environment: JSONValue?) throws -> JSONValue {
        let projectDefault = project.defaultModelSelection.flatMap { $0 == .null ? nil : $0 }
        if let option {
            if let slash = option.firstIndex(of: "/") {
                let instance = String(option[..<slash]), model = String(option[option.index(after: slash)...])
                guard !instance.isEmpty, !model.isEmpty else {
                    throw NoModel(message: "--model wants <instanceId>/<model> or <model>, not \(option)")
                }
                return .object(["instanceId": .string(instance), "model": .string(model)])
            }
            guard let instance = [projectDefault, environment].compactMap(instanceID).first else {
                throw NoModel(message: "no default model on project \(project.title) or the environment names an instance for --model \(option); pass --model <instanceId>/\(option)")
            }
            return .object(["instanceId": .string(instance), "model": .string(option)])
        }
        if let projectDefault { return projectDefault }
        if let environment { return environment }
        throw NoModel(message: "no default model on project \(project.title) or the environment; set one in Settings › General (scope: \(project.title) or All projects), or pass --model")
    }

    private static func instanceID(_ selection: JSONValue?) -> String? {
        guard case .object(let row)? = selection else { return nil }
        for key in ["instanceId", "provider"] { if case .string(let id)? = row[key], !id.isEmpty { return id } }
        return nil
    }

    /// The bootstrap that makes `thread new` one dispatch: create the
    /// thread on the project (its default model), and with `--worktree`
    /// prepare that branch's worktree off `baseBranch` first. The desktop
    /// fills the worktree path in; the CLI names only the branches.
    public static func newThreadBootstrap(project: DesktopAPI.Project, model: JSONValue, title: String,
                                          runtimeMode: String, interactionMode: String,
                                          worktree: String?, baseBranch: String, now: Date = Date()) -> JSONValue {
        var bootstrap: [String: JSONValue] = [
            "createThread": .object([
                "projectId": .string(project.id), "title": .string(title), "modelSelection": model,
                "runtimeMode": .string(runtimeMode), "interactionMode": .string(interactionMode),
                "branch": worktree.map(JSONValue.string) ?? .null, "worktreePath": .null,
                "createdAt": .string(iso(now)),
            ]),
        ]
        if let worktree {
            bootstrap["prepareWorktree"] = .object(["projectCwd": .string(project.workspaceRoot), "baseBranch": .string(baseBranch),
                                                    "branch": .string(worktree)])
        }
        return .object(bootstrap)
    }

    /// An explicit rename uses the same metadata command as the UI. It also
    /// supersedes any in-flight title regeneration on the server.
    public static func renameThread(threadId: String, title: String, id: () -> String = newID) -> JSONValue {
        .object(["type": .string("thread.meta.update"), "commandId": .string(id()),
                 "threadId": .string(threadId), "title": .string(title)])
    }

    public static func resolveThreadID(explicit: String?, environment: [String: String]) -> String? {
        let value = (explicit ?? environment["T3_THREAD_ID"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public static func turnInterrupt(threadId: String, turnId: String?, now: Date = Date(), id: () -> String = newID) -> JSONValue {
        var command: [String: JSONValue] = [
            "type": .string("thread.turn.interrupt"), "commandId": .string(id()), "threadId": .string(threadId),
            "createdAt": .string(iso(now)),
        ]
        if let turnId { command["turnId"] = .string(turnId) }
        return .object(command)
    }

    /// A thread's title from its first prompt: the first line, at most 80 characters.
    public static func title(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let head = line.isEmpty ? "New thread" : line
        return head.count > 80 ? String(head.prefix(79)) + "…" : head
    }

    /// The masked credential for `desktop status`: only its last four characters.
    public static func masked(_ token: String) -> String {
        token.count > 4 ? "…" + token.suffix(4) : "…"
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
