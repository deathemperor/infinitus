import Foundation
import InfinitusCore

#if canImport(Darwin)
/// `infinitusctl mcp`: the plugin's MCP server (#79). Every tool is one
/// control-socket command, so a session can read the fleet and talk to
/// another session without the app exposing anything new.
enum MCPCommand {
    static func run() -> Int32 {
        let path = ControlProtocol.socketURL().path
        @Sendable func control(_ command: String, args: [String] = [], options: [String: String] = [:],
                               secret: String? = nil) -> Result<String, MCPServer.ToolError> {
            let request = ControlRequest(command: command, args: args, options: options, secret: secret)
            guard let reply = roundTrip(request, path: path) else {
                return .failure(.init("Infinitus is not running on this Mac (no control socket)"))
            }
            guard reply.ok else { return .failure(.init(reply.error ?? "\(command) failed")) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let data = (try? encoder.encode(reply.result ?? JSONValue.null)) ?? Data()
            return .success(String(decoding: data, as: UTF8.self))
        }
        func string(_ v: JSONValue?) -> String? {
            switch v {
            case .string(let s)?: return s
            case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
            default: return nil
            }
        }
        let version = "control-\(ControlProtocol.schemaVersion)"
        let server = MCPServer(name: "infinitus", version: version, tools: [
            MCPTool(name: "fleet_status",
                    description: "Every engine fleet Infinitus supervises on this Mac: accounts with their usage windows, which one is active and which comes next, plus the app's status.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                    call: { _ in
                        control("fleets").flatMap { fleets in control("status").map { "status: \($0)\nfleets: \(fleets)" } }
                    }),
            MCPTool(name: "list_sessions",
                    description: "The live Claude Code sessions on this Mac: pid, name, folder, status (busy/idle/waiting/shell).",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                    call: { _ in control("sessions") }),
            MCPTool(name: "past_sessions",
                    description: "Every Claude Code session this Mac has run, newest first: session id, folder, opening prompt, last activity, whether it is live. Optional limit (default 50) and a search over repo, folder and prompt.",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object([
                                            "limit": .object(["type": .string("integer")]),
                                            "search": .object(["type": .string("string")]),
                                          ])]),
                    call: { arguments in
                        var options: [String: String] = [:]
                        if let limit = string(arguments["limit"]) { options["limit"] = limit }
                        if let search = string(arguments["search"]), !search.isEmpty { options["search"] = search }
                        return control("past-sessions", options: options)
                    }),
            MCPTool(name: "session_mode",
                    description: "Moves a running session's permission mode through the Infinitus plugin's PreToolUse hook: acceptEdits allows the editing tools, bypassPermissions every tool, supervised clears it. A mode set at start cannot be narrowed.",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object([
                                            "session": .object(["type": .string("string"), "description": .string("pid or name")]),
                                            "mode": .object(["type": .string("string"), "enum": .array([.string("supervised"), .string("acceptEdits"), .string("bypassPermissions")])]),
                                          ]),
                                          "required": .array([.string("session"), .string("mode")])]),
                    call: { arguments in
                        guard let session = string(arguments["session"]), let mode = string(arguments["mode"]) else {
                            return .failure(.init("session and mode are required"))
                        }
                        return control("session-mode", args: [session, mode])
                    }),
            MCPTool(name: "resume_session",
                    description: "Resume a past Claude Code session on this Mac: opens a new terminal in the folder it ran in with `claude --resume <id>`. Live sessions are refused — message them instead — unless `fork` is true, which branches the transcript into a new session id (`--fork-session`) and leaves the original alone.",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object([
                                            "session_id": .object(["type": .string("string")]),
                                            "fork": .object(["type": .string("boolean")]),
                                          ]),
                                          "required": .array([.string("session_id")])]),
                    call: { arguments in
                        guard let id = string(arguments["session_id"]), !id.isEmpty else {
                            return .failure(.init("session_id is required"))
                        }
                        var options: [String: String] = [:]
                        if case .bool(true)? = arguments["fork"] { options["fork"] = "true" }
                        return control("resume-session", args: [id], options: options)
                    }),
            MCPTool(name: "session_message",
                    description: "Send a message to another live session on this Mac, by pid or name, as if typed into its prompt.",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object([
                                            "session": .object(["type": .string("string"), "description": .string("pid, or the session's name")]),
                                            "text": .object(["type": .string("string")]),
                                          ]),
                                          "required": .array([.string("session"), .string("text")])]),
                    call: { arguments in
                        guard let session = string(arguments["session"]), let text = string(arguments["text"]), !text.isEmpty else {
                            return .failure(.init("session and text are required"))
                        }
                        return control("send", args: [session], secret: text)
                    }),
        ])
        server.serve()
        return 0
    }
}
#else
enum MCPCommand {
    static func run() -> Int32 {
        FileHandle.standardError.write(Data("mcp needs the Infinitus Mac app (control socket)\n".utf8))
        return 3
    }
}
#endif
