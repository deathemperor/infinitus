import Foundation
import InfinitusCore

// `infinitus` — the agent-facing CLI (user 2026-09-03). Knows only the
// control protocol: one JSON line to the running app's socket, one
// back, printed verbatim. Exit codes: 0 ok · 1 command failed · 2 usage
// · 3 app not running, or this platform has no control socket · 4 schema
// mismatch.

let args = Array(CommandLine.arguments.dropFirst())
/// `infinitusctl`, or `ictl` — the shorthand symlink the bundle ships
/// beside it; usage text names whichever ran.
let programName: String = {
    let name = URL(fileURLWithPath: CommandLine.arguments.first ?? "infinitusctl").lastPathComponent
    return name.isEmpty ? "infinitusctl" : name
}()

// `team` runs in-process (TeamCommand.swift) and needs no app.
if args.first == "team" {
    exit(runTeam(Array(args.dropFirst())))
}
// `plugin` drives `claude plugin …` (PluginCommand.swift); no app needed.
if args.first == "plugin" {
    exit(PluginCommand.run(Array(args.dropFirst())))
}
// `mcp` serves the plugin's MCP tools over stdio (MCPCommand.swift).
if args.first == "mcp" {
    exit(MCPCommand.run())
}

func usage() -> String {
    var out = "usage: \(programName) <command> [args] [--option value]\n\n"
    let width = ControlCommand.all.map { ($0.name + " " + $0.args.joined(separator: " ")).count }.max() ?? 20
    for c in ControlCommand.all {
        let head = (c.name + " " + c.args.joined(separator: " ")).padding(toLength: width + 2, withPad: " ", startingAt: 0)
        out += "  \(head)\(c.summary)"
        if !c.options.isEmpty { out += "  [\(c.options.joined(separator: ", "))]" }
        out += "\n"
    }
    out += "  team <subcommand>      teams: create, code, request, approve, publish… (`\(programName) team --help`)\n"
    out += "  plugin install|uninstall|status   the Claude Code plugin: hooks that push prompts to the phone the moment they appear\n"
    out += "  mcp                    the plugin's MCP server over stdio (fleet_status, list_sessions, session_message)\n"
    out += "\nFleet keys come from `infinitusctl fleets` (e.g. cswap/claude, cliproxy/claude).\n"
    out += "proxy-key, 9router-password, aws-login-code, gcloud-login-code and signin-code read their secret from stdin.\n"
    out += "Socket: \(ControlProtocol.socketURL().path)\n"
    return out
}

guard let command = args.first, command != "--help", command != "-h", command != "help" else {
    print(usage(), terminator: "")
    exit(args.isEmpty ? 2 : 0)
}
guard ControlCommand.named(command) != nil else {
    FileHandle.standardError.write(Data("unknown command \(command)\n\n\(usage())".utf8))
    exit(2)
}

// Positional args and --options.
var positional: [String] = []
var options: [String: String] = [:]
var i = 1
while i < args.count {
    let a = args[i]
    if a.hasPrefix("--") {
        let key = String(a.dropFirst(2))
        // `--remote` is a bare flag for aws-login but carries a URL for
        // team-create (the app's fallback to the second positional stays as a belt).
        let flagOnly = command == "team-create" ? ["yes", "local", "status"] : ["yes", "local", "remote", "status"]
        if flagOnly.contains(key) || i + 1 >= args.count || args[i + 1].hasPrefix("--") {
            options[key] = "true"
        } else {
            options[key] = args[i + 1]; i += 1
        }
    } else {
        positional.append(a)
    }
    i += 1
}

// A secret or a body comes on stdin only when something is piped in: an
// interactive terminal (or an e2e run whose stdin is a live pipe) must
// not sit in readDataToEndOfFile forever for a verb that has nothing to
// read (`activities-token --forget` hung a run for 90 min, 2026-09-11).
let stdinPiped = isatty(0) == 0
var secret: String?
if stdinPiped, ["proxy-key", "9router-password", "aws-login-code", "gcloud-login-code", "signin-code", "aws-login-callback", "event", "send", "approve", "team-create", "team-join", "team-hostname"].contains(command) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// A JSON body verb (#572 N1) takes `--body <json>`; without it the JSON
// comes from stdin, so `infinitusctl crash-report < report.json` works.
if stdinPiped, ["activities-token", "client-activity", "crash-report"].contains(command), options[ControlBody.option] == nil {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    options[ControlBody.option] = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let request = ControlRequest(command: command, args: positional, options: options, secret: secret)

// MARK: socket round-trip (blocking; a CLI has no reason to be async)

#if canImport(Darwin)
let path = ControlProtocol.socketURL().path
guard let reply = ControlClient.roundTripRetrying(request, path: path) else {
    let why = ControlClient.lastConnectErrno == 0 ? "no reply at" : "\(String(cString: strerror(ControlClient.lastConnectErrno))) at"
    FileHandle.standardError.write(Data("Infinitus is not running (\(why) \(path))\n".utf8))
    exit(3)
}
if reply.schemaVersion > ControlProtocol.schemaVersion {
    FileHandle.standardError.write(Data("app speaks control schema \(reply.schemaVersion), this CLI \(ControlProtocol.schemaVersion): update the CLI\n".utf8))
    exit(4)
}

let pretty = JSONEncoder()
pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
if let result = reply.result, let data = try? pretty.encode(result) {
    print(String(decoding: data, as: UTF8.self))
}
if let error = reply.error {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
}

if reply.restarting {
    // The app is relaunching; wait for the socket to answer `status`
    // again so the next agent command lands on the new registry.
    let deadline = Date().addingTimeInterval(30)
    Thread.sleep(forTimeInterval: 2)
    while Date() < deadline {
        if ControlClient.roundTrip(ControlRequest(command: "status"), path: path) != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
exit(reply.ok ? 0 : 1)
#elseif canImport(Glibc)
// Byte-for-byte the Darwin branch above (the e2e's round-trips lean
// on that text, so it does not move): the wire, the exit codes and
// the restart wait are the protocol's, not a platform's. The socket
// is `infinitus-tray serve`'s on Linux, and only `event`/`status`
// answer there — every other command replies "not available on
// Linux yet" and this exits 1 (#486 slice 3).
let path = ControlProtocol.socketURL().path
guard let reply = ControlClient.roundTripRetrying(request, path: path) else {
    let why = ControlClient.lastConnectErrno == 0 ? "no reply at" : "\(String(cString: strerror(ControlClient.lastConnectErrno))) at"
    FileHandle.standardError.write(Data("Infinitus is not running (\(why) \(path))\n".utf8))
    exit(3)
}
if reply.schemaVersion > ControlProtocol.schemaVersion {
    FileHandle.standardError.write(Data("app speaks control schema \(reply.schemaVersion), this CLI \(ControlProtocol.schemaVersion): update the CLI\n".utf8))
    exit(4)
}

let pretty = JSONEncoder()
pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
if let result = reply.result, let data = try? pretty.encode(result) {
    print(String(decoding: data, as: UTF8.self))
}
if let error = reply.error {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
}

if reply.restarting {
    // The app is relaunching; wait for the socket to answer `status`
    // again so the next agent command lands on the new registry.
    let deadline = Date().addingTimeInterval(30)
    Thread.sleep(forTimeInterval: 2)
    while Date() < deadline {
        if ControlClient.roundTrip(ControlRequest(command: "status"), path: path) != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
exit(reply.ok ? 0 : 1)
#else
FileHandle.standardError.write(Data("\(command) needs the Infinitus Mac app (control socket); only `team` runs here\n".utf8))
exit(3)
#endif
