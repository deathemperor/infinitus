import Foundation

/// Where the `claude` binary lives, and whether it is new enough to be
/// owned (#151). Same shape as `CswapLocator`; the login shell is the
/// last resort because a GUI app's PATH does not see version managers.
public enum ClaudeLocator {
    /// `--permission-prompts host` (2.1.259) is what lets a host answer
    /// permission prompts over stdin; older builds deny them silently.
    public static let minimumVersion = [2, 1, 259]

    public static func defaultCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    #if !os(iOS)
    public static func locate(
        candidates: [String] = defaultCandidates(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        loginShell: () -> String = loginShellLookup
    ) -> String? {
        if let hit = candidates.first(where: exists) { return hit }
        let found = loginShell().trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }

    /// One `command -v claude` in the user's login shell — cached, it costs
    /// a shell startup. Sync: `locate` runs from plain GUI code.
    public static let loginShellLookup: () -> String = { captureSync("/bin/zsh", ["-lc", "command -v claude"]) ?? "" }

    /// The PATH a login shell sees. An owned session's Bash tool needs
    /// `gh`, `node`, `swift`… and the bundled app inherits none of them;
    /// a terminal-started session gets them for free. Empty where there
    /// is no zsh (Linux CI) — callers fall back to the fixed prefixes.
    public static func loginShellPath() async -> String {
        (await capture("/bin/zsh", ["-lc", "echo $PATH"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `executable arguments…` → its stdout, nil when it won't launch. The
    /// blocking Process dance lives on a GCD thread (CswapCLI.run's lesson:
    /// inline in an async function it silently never completed in-app on
    /// macOS 26).
    public static func capture(_ executable: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: captureSync(executable, arguments))
            }
        }
    }

    static func captureSync(_ executable: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // A login shell whose rc waits on a prompt would hang `start`
        // forever; past the deadline it is killed and the caller falls back.
        let deadline = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    /// "2.1.263 (Claude Code)" → [2, 1, 263].
    public static func parseVersion(_ banner: String) -> [Int]? {
        let head = banner.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let parts = head.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    public static func supportsOwnedSessions(version: [Int]) -> Bool {
        version.lexicographicallyPrecedes(minimumVersion) == false
    }
}

/// A prompt the owned session parked on the host: a tool that needs a
/// permission verdict, or `AskUserQuestion` waiting for its answers.
public struct PendingRequest: Sendable, Equatable, Codable {
    public struct Question: Sendable, Equatable, Codable {
        public let question: String
        public let header: String
        public let options: [String]
        public let multiSelect: Bool
    }
    public let requestId: String
    public let toolName: String
    public let toolUseId: String?
    public let description: String?
    /// The tool's input, as the JSON text it arrived in — echoed back
    /// verbatim as `updatedInput` on allow.
    public let inputJSON: String
    /// `permission_suggestions` as JSON text, when Claude Code offered a
    /// rule that would stop asking ("allow for this session").
    public let suggestionsJSON: String?
    public let questions: [Question]
    public let receivedAt: Date
}

/// The stream-json protocol between the app and a `claude` it owns:
/// argv, stdin frames, stdout events, answers. Pure; `OwnedSessions`
/// runs the process. Verified against Claude Code 2.1.263 (#151 step 0).
public enum OwnedWire {
    public enum Event: Sendable {
        case initialized(sessionId: String, permissionMode: String?)
        case canUseTool(PendingRequest)
        case result
        case controlResponse(requestId: String)
        case other
    }

    public enum Decision: Sendable, Equatable {
        /// `forSession` also sends the suggested rule so this tool stops asking.
        case allow(forSession: Bool)
        case deny(message: String)
        /// AskUserQuestion: the chosen option label per question text.
        case answers([String: String])
    }

    public static let denyMessage = "Denied from Infinitus."

    /// The modes Claude Code 2.1 takes on `--permission-mode` and
    /// `set_permission_mode`. `manual` is "ask every time" — the way to get
    /// prompts on a Mac whose settings default to `auto`; the phone's own
    /// picker (`SessionStart.permissionModes`) is a shorter, curated list.
    public static let permissionModes: Set<String> = ["default", "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]

    /// `--permission-prompts host` routes prompts to the host, and only
    /// `--permission-prompt-tool stdio` actually puts them (and the
    /// AskUserQuestion tool) on stdin/stdout. The prompt is a stdin
    /// frame, never argv; cwd is the process directory.
    public static func arguments(for req: SessionStart.Request, sessionId: String) -> [String] {
        var args = ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]
        if let resume = req.resume, !resume.isEmpty {
            args += ["--resume", resume]
            if req.fork == true { args.append("--fork-session") }
        } else {
            args += ["--session-id", sessionId]
        }
        if let mode = req.permissionMode, permissionModes.contains(mode) {
            args += ["--permission-mode", mode]
        }
        if let model = req.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args += ["--model", model]
        }
        if let sys = req.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !sys.isEmpty {
            args += ["--append-system-prompt", sys]
        }
        return args
    }

    static func line(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func userLine(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    public static func controlLine(requestId: String, subtype: String, fields: [String: Any] = [:]) -> String {
        var request: [String: Any] = fields
        request["subtype"] = subtype
        return line(["type": "control_request", "request_id": requestId, "request": request])
    }

    public static func answerLine(_ pending: PendingRequest, _ decision: Decision) -> String {
        var response: [String: Any]
        let input = (try? JSONSerialization.jsonObject(with: Data(pending.inputJSON.utf8))) as? [String: Any] ?? [:]
        switch decision {
        case .allow(let forSession):
            response = ["behavior": "allow", "updatedInput": input]
            if forSession, let json = pending.suggestionsJSON,
               let suggestions = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                // "For this session" means this session, whatever the CLI
                // suggested — a settings write is a different ask (T3's rule).
                response["updatedPermissions"] = suggestions.map { var s = $0; s["destination"] = "session"; return s }
            }
        case .deny(let message):
            response = ["behavior": "deny", "message": message]
        case .answers(let answers):
            var updated = input
            updated["answers"] = answers
            response = ["behavior": "allow", "updatedInput": updated]
        }
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": pending.requestId, "response": response]])
    }

    /// What a phone key means against a parked prompt, mirroring Claude
    /// Code's own menus: 1/y/enter = yes, 2 = yes for this session,
    /// 3/n = no; on a question, N picks the Nth option of every question.
    /// nil = the key answers nothing here (esc interrupts instead).
    public static func decision(forKey key: String, pending: PendingRequest) -> Decision? {
        if !pending.questions.isEmpty {
            guard let n = Int(key), n >= 1 else { return nil }
            var answers: [String: String] = [:]
            for q in pending.questions {
                guard n <= q.options.count else { return nil }
                answers[q.question] = q.options[n - 1]
            }
            return .answers(answers)
        }
        switch key {
        case "1", "y", "enter": return .allow(forSession: false)
        case "2": return .allow(forSession: true)
        case "3", "n": return .deny(message: denyMessage)
        default: return nil
        }
    }

    public static func decode(line: String, now: Date = Date()) -> Event {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return .other }
        switch type {
        case "system" where obj["subtype"] as? String == "init":
            return .initialized(sessionId: obj["session_id"] as? String ?? "",
                                permissionMode: obj["permissionMode"] as? String)
        case "result":
            return .result
        case "control_response":
            let rid = (obj["response"] as? [String: Any])?["request_id"] as? String ?? ""
            return .controlResponse(requestId: rid)
        case "control_request":
            guard let rid = obj["request_id"] as? String,
                  let req = obj["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool" else { return .other }
            let input = req["input"] as? [String: Any] ?? [:]
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { q -> PendingRequest.Question? in
                guard let text = q["question"] as? String else { return nil }
                return PendingRequest.Question(
                    question: text, header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            return .canUseTool(PendingRequest(
                requestId: rid, toolName: req["tool_name"] as? String ?? "",
                toolUseId: req["tool_use_id"] as? String, description: req["description"] as? String,
                inputJSON: jsonText(input),
                suggestionsJSON: req["permission_suggestions"].map(jsonText),
                questions: questions, receivedAt: now))
        default:
            return .other
        }
    }

    private static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
