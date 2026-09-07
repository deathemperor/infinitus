import Foundation
import InfinitusCore

// `infinitus` — the agent-facing CLI (user 2026-09-03). Knows only the
// control protocol: one JSON line to the running app's socket, one
// back, printed verbatim. Exit codes: 0 ok · 1 command failed · 2 usage
// · 3 app not running, or this platform has no control socket · 4 schema
// mismatch.

let args = Array(CommandLine.arguments.dropFirst())

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
    var out = "usage: infinitusctl <command> [args] [--option value]\n\n"
    let width = ControlCommand.all.map { ($0.name + " " + $0.args.joined(separator: " ")).count }.max() ?? 20
    for c in ControlCommand.all {
        let head = (c.name + " " + c.args.joined(separator: " ")).padding(toLength: width + 2, withPad: " ", startingAt: 0)
        out += "  \(head)\(c.summary)"
        if !c.options.isEmpty { out += "  [\(c.options.joined(separator: ", "))]" }
        out += "\n"
    }
    out += "  team <subcommand>      teams: create, code, request, approve, publish… (`infinitusctl team --help`)\n"
    out += "  plugin install|uninstall|status   the Claude Code plugin: hooks that push prompts to the phone the moment they appear\n"
    out += "  mcp                    the plugin's MCP server over stdio (fleet_status, list_sessions, session_message)\n"
    out += "\nFleet keys come from `infinitusctl fleets` (e.g. cswap/claude, cliproxy/claude).\n"
    out += "proxy-key, 9router-password and aws-login-code read their secret from stdin.\n"
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

var secret: String?
if ["proxy-key", "9router-password", "aws-login-code", "aws-login-callback", "event", "send", "approve"].contains(command) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let request = ControlRequest(command: command, args: positional, options: options, secret: secret)

// MARK: socket round-trip (blocking; a CLI has no reason to be async)

#if canImport(Darwin)
/// errno of the last failed connect — what "not running" gets to say.
var lastConnectErrno: Int32 = 0

/// The app re-binds its socket in ~2 ms when the path went stale
/// (ControlServer.heal); a call landing in that gap, or on the dead
/// inode a moment before, said "not running" (#265, an e2e flake twice
/// in a day). `roundTripRetrying` below retries for a second.
func connect(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
    }
    guard rc == 0 else { lastConnectErrno = errno; close(fd); return nil }
    lastConnectErrno = 0
    return fd
}

func roundTrip(_ req: ControlRequest, path: String) -> ControlReply? {
    guard let fd = connect(path: path) else { return nil }
    defer { close(fd) }
    let out = (try? ControlCodec.encode(req)) ?? Data()
    var sent = 0
    out.withUnsafeBytes { buf in
        while sent < out.count {
            let n = write(fd, buf.baseAddress! + sent, out.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        data.append(chunk, count: n)
        if data.last == 0x0A { break }
    }
    return try? ControlCodec.decode(ControlReply.self, from: data)
}

let path = ControlProtocol.socketURL().path
/// A connect that lands while the app's listener is half re-bound gets
/// accepted and then nothing (#265: "no reply" a second before the app
/// logged the re-bind); the whole round trip gets the retry, not just
/// the connect.
func roundTripRetrying(_ req: ControlRequest, path: String) -> ControlReply? {
    for attempt in 0..<10 {
        if let reply = roundTrip(req, path: path) { return reply }
        guard attempt < 9, lastConnectErrno == 0 || lastConnectErrno == ENOENT || lastConnectErrno == ECONNREFUSED else { return nil }
        usleep(100_000)
    }
    return nil
}
guard let reply = roundTripRetrying(request, path: path) else {
    let why = lastConnectErrno == 0 ? "no reply at" : "\(String(cString: strerror(lastConnectErrno))) at"
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
        if roundTrip(ControlRequest(command: "status"), path: path) != nil { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
exit(reply.ok ? 0 : 1)
#else
FileHandle.standardError.write(Data("\(command) needs the Infinitus Mac app (control socket); only `team` runs here\n".utf8))
exit(3)
#endif
