import Foundation
import InfinitusCore

// `infinitusctl environments | projects | threads | thread … | desktop …`
// (#822): the desktop app's projects and threads from the CLI. The verbs
// talk to Infinitus desktop's server over HTTP (DesktopAPI) with the
// credential the Mac app keeps for them (`desktop-token` over the control
// socket); nothing else hops through the app. Exit codes as main.swift:
// 0 ok · 1 the desktop refused · 2 usage, or the credential is gone ·
// 3 no Mac app, or no desktop reachable.

func desktopUsage() -> String {
    """
    usage: \(programName) environments
           \(programName) projects
           \(programName) threads [--project <id|name>] [--status running|held|paused|waiting|idle] [--limit <n>]
           \(programName) thread rename [--thread <id>] <title>
           \(programName) thread title [--thread <id>]
           \(programName) thread show <id> [--turns <n>]
           \(programName) thread send <id> <message|-> [--steer] [--wait] [--wait-idle]
           \(programName) thread new --project <id|name> <prompt|-> [--worktree <branch>] [--base <branch>] [--wait]
           \(programName) thread interrupt <id>
           \(programName) thread release <id>
           \(programName) desktop status | credential

    Infinitus desktop's projects and threads, over the credential it hands the Mac app.
    rename/title use T3_THREAD_ID when --thread is omitted. T3_ENVIRONMENT_ID guards the host.
    `-` reads the message from stdin. `send` queues nothing: a running thread refuses
    unless --steer folds the message into the turn or --wait-idle sends it when the turn ends.
    --wait prints the assistant's answer when the turn ends (exit 1 when it errors or is interrupted).

    """
}

private func desktopFail(_ message: String, code: Int32 = 1) -> Int32 {
    let text = message.hasPrefix("usage:") ? message : "error: \(message)"
    FileHandle.standardError.write(Data((text + "\n").utf8))
    return code
}

private func desktopEmit(_ value: JSONValue) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// nil when `args` is not one of ours.
func runDesktopVerbs(_ args: [String]) -> Int32? {
    guard let verb = args.first, ["environments", "projects", "threads", "thread", "desktop"].contains(verb) else { return nil }
    if args.contains("--help") || args.contains("-h") { print(desktopUsage(), terminator: ""); return 0 }
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if ["steer", "wait", "wait-idle"].contains(key) { flags.insert(key); i += 1; continue }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return desktopFail("--\(key) needs a value\n\n\(desktopUsage())", code: 2) }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    #if os(macOS)
    return DesktopVerbs(verb: verb, positional: positional, options: options, flags: flags).run()
    #else
    return desktopFail("no Infinitus desktop on this host", code: 2)
    #endif
}

#if os(macOS)
private struct DesktopVerbs {
    let verb: String
    let positional: [String]
    let options: [String: String]
    let flags: Set<String>
    let socket = ControlProtocol.socketURL().path

    func run() -> Int32 {
        do {
            switch verb {
            case "environments": return try environments()
            case "projects": return try projects()
            case "threads": return try threads()
            case "thread": return try thread()
            case "desktop": return try desktop()
            default: return desktopFail(desktopUsage(), code: 2)
            }
        } catch let failure as DesktopAPI.Failure where failure.unauthorized {
            return desktopFail("Infinitus desktop no longer accepts this credential — relaunch Infinitus desktop to issue a new one", code: 2)
        } catch let failure as DesktopAPI.Failure {
            return desktopFail(failure.description)
        } catch let failure as Unreachable {
            return desktopFail(failure.message, code: 3)
        } catch let refusal as Refused {
            return desktopFail(refusal.message, code: refusal.code)
        } catch {
            return desktopFail(error.localizedDescription)
        }
    }

    struct Refused: Error { var message: String; var code: Int32 = 1 }
    struct Unreachable: Error { var message: String }

    // MARK: the app's socket (credential) and the desktop's server

    private func control(_ command: String) throws -> ControlReply {
        guard let reply = ControlClient.roundTripRetrying(ControlRequest(command: command), path: socket) else {
            throw Unreachable(message: "Infinitus is not running (no reply at \(socket))")
        }
        return reply
    }

    /// The desktop client, or the refusal when the app keeps no credential.
    private func api() throws -> DesktopAPI {
        let reply = try control("desktop-token")
        guard reply.ok, case .string(let origin)? = reply.result?["origin"], case .string(let token)? = reply.result?["token"],
              let url = URL(string: origin) else {
            throw Refused(message: reply.error ?? "no Infinitus desktop credential — launch Infinitus desktop", code: 2)
        }
        return DesktopAPI(origin: url, token: token) { method, url, headers, body in
            do { return try DesktopAPI.urlSession(method, url, headers, body) } catch {
                throw Unreachable(message: "Infinitus desktop is not reachable at \(origin) (\(error.localizedDescription))")
            }
        }
    }

    // MARK: verbs

    private func environments() throws -> Int32 {
        let api = try api()
        let d = try api.descriptor()
        desktopEmit(.array([.object([
            "id": .string(d.environmentId), "name": .string(d.label), "kind": .string("local"), "status": .string("reachable"),
            "origin": .string(api.origin.absoluteString), "platform": d.platform.map(JSONValue.string) ?? .null,
            "version": d.serverVersion.map(JSONValue.string) ?? .null,
        ])]))
        return 0
    }

    private func projects() throws -> Int32 {
        let api = try api()
        let env = try api.descriptor().environmentId
        if let wanted = options["env"], wanted != env { desktopEmit(.array([])); return 0 }
        desktopEmit(.array(try api.shell().projects.map { project in
            var row = DesktopRows.projectRow(project)
            if case .object(var o) = row { o["env"] = .string(env); row = .object(o) }
            return row
        }))
        return 0
    }

    private func threads() throws -> Int32 {
        let api = try api()
        let shell = try api.shell()
        let holds = Dictionary(try api.holds().map { ($0.threadId, $0) }, uniquingKeysWith: { a, _ in a })
        let projects = Dictionary(shell.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var project: DesktopAPI.Project?
        if let wanted = options["project"] {
            guard let found = shell.projects.first(where: { $0.id == wanted || $0.title == wanted }) else {
                throw Refused(message: "no project \(wanted) in Infinitus desktop")
            }
            project = found
        }
        if let status = options["status"], !DesktopRows.statuses.contains(status) {
            throw Refused(message: "usage: threads --status \(DesktopRows.statuses.joined(separator: "|"))", code: 2)
        }
        let limit = options["limit"].flatMap(Int.init) ?? 50
        guard limit > 0 else { throw Refused(message: "usage: threads --limit <n>  (n > 0)", code: 2) }
        let rows = shell.threads
            .filter { $0.archivedAt == nil && (project == nil || $0.projectId == project?.id) }
            .filter { options["status"] == nil || DesktopRows.status($0, hold: holds[$0.id]) == options["status"] }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            .prefix(limit)
            .map { DesktopRows.threadRow($0, project: projects[$0.projectId], hold: holds[$0.id]) }
        desktopEmit(.array(rows))
        return 0
    }

    private func thread() throws -> Int32 {
        guard let sub = positional.first else { throw Refused(message: desktopUsage(), code: 2) }
        if sub == "rename" || sub == "title" { return try threadTitle(rename: sub == "rename") }
        guard let id = positional.dropFirst().first ?? (sub == "new" ? "" : nil) else {
            throw Refused(message: desktopUsage(), code: 2)
        }
        let api = try api()
        switch sub {
        case "show":
            let turns = options["turns"].flatMap(Int.init) ?? 5
            guard turns > 0 else { throw Refused(message: "usage: thread show <id> [--turns <n>]  (n > 0)", code: 2) }
            let (shellThread, project, hold) = try locate(id, api: api)
            let detail = try api.thread(id, turnLimit: turns)
            desktopEmit(.object(["thread": DesktopRows.threadRow(shellThread, project: project, hold: hold),
                                 "messages": .array(detail.messages.map(DesktopRows.messageRow))]))
            return 0

        case "send":
            let text = try message(positional.dropFirst(2).first, what: "message")
            var (shellThread, _, hold) = try locate(id, api: api)
            var status = DesktopRows.status(shellThread, hold: hold)
            if ["running", "held", "paused"].contains(status), !flags.contains("steer") {
                guard flags.contains("wait-idle") else {
                    throw Refused(message: "turn running; --steer to fold it in, or --wait-idle to send when it finishes")
                }
                while ["running", "held", "paused"].contains(status) {
                    Thread.sleep(forTimeInterval: 1)
                    (shellThread, _, hold) = try locate(id, api: api)
                    status = DesktopRows.status(shellThread, hold: hold)
                }
            }
            let steering = status == "running" && flags.contains("steer")
            let previous = steering ? nil : shellThread.latestTurn?.turnId
            let (command, messageId) = DesktopRows.turnStart(
                threadId: id, text: text,
                runtimeMode: shellThread.runtimeMode ?? DesktopRows.defaultRuntimeMode,
                interactionMode: shellThread.interactionMode ?? DesktopRows.defaultInteractionMode)
            let sequence = try api.dispatch(command)
            var out: [String: JSONValue] = ["messageId": .string(messageId), "sequence": .number(Double(sequence))]
            if steering { out["steered"] = .bool(true) }
            return try finish(out, threadId: id, previousTurn: previous, api: api)

        case "new":
            guard let wanted = options["project"] else { throw Refused(message: desktopUsage(), code: 2) }
            let text = try message(positional.dropFirst().first, what: "prompt")
            let shell = try api.shell()
            guard let project = shell.projects.first(where: { $0.id == wanted || $0.title == wanted }) else {
                throw Refused(message: "no project \(wanted) in Infinitus desktop")
            }
            guard let model = project.defaultModelSelection, model != .null else {
                throw Refused(message: "project \(project.title) has no default model; pick one in Infinitus desktop")
            }
            var base = options["base"]
            if options["worktree"] != nil, base == nil {
                guard let branch = currentBranch(of: project.workspaceRoot) else {
                    throw Refused(message: "cannot read the checked-out branch of \(project.workspaceRoot); pass --base <branch>", code: 2)
                }
                base = branch
            }
            let threadId = DesktopRows.newID()
            let title = DesktopRows.title(from: text)
            let bootstrap = DesktopRows.newThreadBootstrap(
                project: project, model: model, title: title,
                runtimeMode: DesktopRows.defaultRuntimeMode, interactionMode: DesktopRows.defaultInteractionMode,
                worktree: options["worktree"], baseBranch: base ?? "")
            let (command, messageId) = DesktopRows.turnStart(
                threadId: threadId, text: text,
                runtimeMode: DesktopRows.defaultRuntimeMode, interactionMode: DesktopRows.defaultInteractionMode,
                titleSeed: title, bootstrap: bootstrap)
            let sequence = try api.dispatch(command)
            return try finish(["threadId": .string(threadId), "messageId": .string(messageId), "sequence": .number(Double(sequence))],
                              threadId: threadId, previousTurn: nil, api: api)

        case "interrupt":
            let (shellThread, _, _) = try locate(id, api: api)
            let turn = shellThread.latestTurn.flatMap { $0.state == "running" ? $0.turnId : nil }
            let sequence = try api.dispatch(DesktopRows.turnInterrupt(threadId: id, turnId: turn))
            desktopEmit(.object(["ok": .bool(true), "sequence": .number(Double(sequence)), "turnId": turn.map(JSONValue.string) ?? .null]))
            return 0

        case "release":
            let release = try api.releaseThread(id)
            desktopEmit(.object(["released": .bool(release.released), "reason": release.reason.map(JSONValue.string) ?? .null]))
            return release.released ? 0 : 1

        default:
            throw Refused(message: desktopUsage(), code: 2)
        }
    }

    private func threadTitle(rename: Bool) throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let id = DesktopRows.resolveThreadID(explicit: options["thread"], environment: environment) else {
            throw Refused(message: "no current thread: pass --thread <id> or run inside an Infinitus thread (T3_THREAD_ID)", code: 2)
        }
        guard positional.count == (rename ? 2 : 1), options.keys.allSatisfy({ $0 == "thread" || $0 == "env" }), flags.isEmpty else {
            throw Refused(message: desktopUsage(), code: 2)
        }
        let title = rename ? try message(positional[1], what: "title") : nil
        let api = try api()
        if let expected = options["env"] ?? environment["T3_ENVIRONMENT_ID"],
           try api.descriptor().environmentId != expected {
            throw Refused(message: "this thread belongs to another environment; run the command on its owning host", code: 2)
        }
        guard let thread = try api.shell().threads.first(where: { $0.id == id }) else {
            throw Refused(message: "no thread \(id) in Infinitus desktop")
        }
        if let title {
            let sequence = try api.dispatch(DesktopRows.renameThread(threadId: id, title: title))
            desktopEmit(.object(["threadId": .string(id), "title": .string(title), "sequence": .number(Double(sequence))]))
        } else {
            print(thread.title)
        }
        return 0
    }

    private func desktop() throws -> Int32 {
        switch positional.first {
        case "status":
            let reply = try control("desktop-status")
            guard reply.ok, case .object(var status)? = reply.result else { throw Refused(message: reply.error ?? "desktop-status failed") }
            var reachable = false
            var version: JSONValue = .null
            if status["credential"] != nil, status["credential"] != .null, let api = try? api(), let d = try? api.descriptor() {
                reachable = true
                version = d.serverVersion.map(JSONValue.string) ?? .null
            }
            status["reachable"] = .bool(reachable)
            status["version"] = version
            desktopEmit(.object(status))
            return 0
        case "credential":
            let reply = try control("desktop-status")
            guard reply.ok, case .object(let status)? = reply.result else { throw Refused(message: reply.error ?? "desktop-status failed") }
            let label = status["credential"] ?? .null
            var accepted: JSONValue = .null
            if label != .null, let api = try? api(), let ok = try? api.sessionAccepted() { accepted = .bool(ok) }
            desktopEmit(.object(["stored": .bool(label != .null), "label": label, "accepted": accepted,
                                 "expiresAt": status["expiresAt"] ?? .null]))
            return 0
        default:
            throw Refused(message: desktopUsage(), code: 2)
        }
    }

    // MARK: helpers

    private func message(_ arg: String?, what: String) throws -> String {
        guard let arg else { throw Refused(message: desktopUsage(), code: 2) }
        let text = arg == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : arg
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Refused(message: "the \(what) is empty", code: 2) }
        return trimmed
    }

    /// The project's checked-out branch — the base a new worktree starts
    /// from, as the desktop's own New-thread sheet defaults it. The CLI
    /// runs beside the desktop (v1 is this Mac), so git answers locally.
    private func currentBranch(of workspaceRoot: String) -> String? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", workspaceRoot, "rev-parse", "--abbrev-ref", "HEAD"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return git.terminationStatus == 0 && !branch.isEmpty && branch != "HEAD" ? branch : nil
    }

    private func locate(_ id: String, api: DesktopAPI) throws -> (DesktopAPI.ThreadShell, DesktopAPI.Project?, DesktopAPI.Hold?) {
        let shell = try api.shell()
        guard let thread = shell.threads.first(where: { $0.id == id }) else { throw Refused(message: "no thread \(id) in Infinitus desktop") }
        let hold = try api.holds().first { $0.threadId == id }
        return (thread, shell.projects.first { $0.id == thread.projectId }, hold)
    }

    /// Print `out`, or with --wait poll the thread until its turn ends and
    /// add the turn and the assistant's text. The desktop has no
    /// turn-ended event a client can read; the detail's latestTurn is the
    /// honest signal. A turn that never starts within 30 s is an error.
    private func finish(_ out: [String: JSONValue], threadId: String, previousTurn: String?, api: DesktopAPI) throws -> Int32 {
        guard flags.contains("wait") else { desktopEmit(.object(out)); return 0 }
        let deadline = Date().addingTimeInterval(30)
        while true {
            Thread.sleep(forTimeInterval: 1)
            let detail: DesktopAPI.Thread
            do { detail = try api.thread(threadId, turnLimit: 1) } catch let failure as DesktopAPI.Failure where failure.status == 404 && previousTurn == nil {
                guard Date() < deadline else { throw Refused(message: "the thread never appeared in Infinitus desktop") }
                continue
            }
            guard let turn = detail.latestTurn, turn.turnId != previousTurn else {
                guard Date() < deadline else { throw Refused(message: "no turn started in Infinitus desktop") }
                continue
            }
            if turn.state == "running" { continue }
            let answer = detail.messages.last { $0.id == turn.assistantMessageId } ?? detail.messages.last { $0.role == "assistant" }
            var out = out
            out["turn"] = .object(["id": .string(turn.turnId), "state": .string(turn.state)])
            out["text"] = answer.map { .string($0.text) } ?? .null
            desktopEmit(.object(out))
            return turn.state == "completed" ? 0 : 1
        }
    }
}
#endif
