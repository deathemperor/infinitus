// infinitus-win — the Windows mirror daemon (docs/plan-windows/01-stack.md).
// W3: `sessions`, W4: `listen`, W5: `pair`. W7 (`serve` — full snapshot,
// tail and image routes) builds on W4's listener next.
import Foundation
import InfinitusCore
#if os(Windows)
import CRT   // exit(3): Foundation doesn't re-export it on Windows
#endif

/// Tracks the app release (VERSION) via unified InfinitusVersion constant.
let infinitusWinVersion = InfinitusVersion.current

/// The Mac's mirror port, so a QR from either host scans the same.
let defaultMirrorPort: UInt16 = 47824

/// Subcommand dispatch — W6/W7 add their entries here, bodies below.
let commands: [String: ([String]) -> Int32] = [
    "sessions": sessions,
    "listen": listen,
    "pair": pair,
    "snapshot": snapshot,
    "message": message,
    "resume": resume,
    "serve": serve,
    "control": control,
    "export": exportAccounts,
    "import": importAccounts,
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let subcommand = CommandLine.arguments.dropFirst().first
if subcommand == "--version" || subcommand == "-V" {
    print("infinitus-win \(infinitusWinVersion)")
    exit(0)
}
guard let subcommand, let run = commands[subcommand] else {
    print("infinitus-win \(infinitusWinVersion) — Infinitus mirror daemon for Windows")
    let seen = subcommand.map { " \($0)" } ?? ""
    print("unknown or missing subcommand\(seen) — one of \(commands.keys.sorted().joined(separator: ", "))")
    exit(2)
}
exit(run(Array(CommandLine.arguments.dropFirst(2))))

// MARK: - sessions (W3)

/// `infinitus-win sessions` — every live Claude Code session on this box
/// as JSON: pid, name, kind, status, cwd, messagingSocketPath, and both
/// liveness signals (alive = process + FILETIME match, pipe = a server is
/// listening on the messaging pipe).
func sessions(_ args: [String]) -> Int32 {
    let rows = WinSessions.list(claudeDir: ClaudeSessions.configHome())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(rows) else { fail("sessions: couldn't encode") }
    print(String(data: data, encoding: .utf8) ?? "[]")
    return 0
}

// MARK: - snapshot (W6)

/// `infinitus-win snapshot [--claude-dir P]` — the `GET /snapshot` body
/// on stdout, so the phone's payload can be inspected without a server.
func snapshot(_ args: [String]) -> Int32 {
    var claudeDir = ClaudeSessions.configHome()
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--claude-dir":
            index += 1
            guard index < args.endIndex else { fail("snapshot: --claude-dir needs a path") }
            claudeDir = URL(fileURLWithPath: args[index])
        default:
            fail("snapshot: unknown flag \(args[index])")
        }
        index += 1
    }
    let data = SnapshotCache(claudeDir: claudeDir).data()
    guard !data.isEmpty else { fail("snapshot: couldn't encode") }
    print(String(data: data, encoding: .utf8) ?? "{}")
    return 0
}

// MARK: - message (W10)

/// `infinitus-win message --pid N <text>` — deliver one message to a live
/// session's inbox over its named pipe, the same bytes the phone's
/// `POST /sessions/<pid>/input` will write. `--dry-run` prints the frames
/// instead of writing them.
func message(_ args: [String]) -> Int32 {
    var pid: Int32?, dryRun = false, claudeDir = ClaudeSessions.configHome()
    var text: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--pid":
            index += 1
            guard index < args.endIndex, let parsed = Int32(args[index]) else {
                fail("message: --pid needs a number")
            }
            pid = parsed
        case "--claude-dir":
            index += 1
            guard index < args.endIndex else { fail("message: --claude-dir needs a path") }
            claudeDir = URL(fileURLWithPath: args[index])
        case "--dry-run": dryRun = true
        default: text.append(args[index])
        }
        index += 1
    }
    guard let pid else { fail("message: --pid is required") }
    let body = text.joined(separator: " ")
    guard !body.isEmpty else { fail("message: nothing to send") }
    guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
    else { fail("message: no live session with pid \(pid)") }
    guard !record.messagingSocketPath.isEmpty else {
        fail("message: session \(pid) carries no messaging pipe")
    }
    if dryRun {
        let payload = PeerSocket.frames(
            text: body, token: PeerSocket.peerToken(pid: pid, claudeDir: claudeDir),
            from: NamedPipe.ownAddress())
        print(String(data: payload, encoding: .utf8) ?? "")
        return 0
    }
    guard NamedPipe.send(text: body, record: record, claudeDir: claudeDir) else {
        fail("message: the pipe refused the write")
    }
    print("delivered to \(pid) (\(record.name ?? "unnamed"))")
    return 0
}

// MARK: - pair (W5)

/// `infinitus-win pair [--show] [--rotate] [--token-file P] [--stdin]
/// [--port N]` — print the `infinitus://pair?…` URL the phone pairs from
/// (one endpoint per route: LAN, then tailnet), with a QR when qrencode
/// is on PATH. The token lives in `%APPDATA%\Infinitus\pair-token`.
func pair(_ args: [String]) -> Int32 {
    var show = false, rotate = false, fromStdin = false
    var tokenFile: String?, port: UInt16 = defaultMirrorPort
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--show": show = true
        case "--rotate": rotate = true
        case "--stdin": fromStdin = true
        case "--token-file":
            index += 1
            guard index < args.endIndex else { fail("pair: --token-file needs a path") }
            tokenFile = args[index]
        case "--port":
            index += 1
            guard index < args.endIndex, let parsed = UInt16(args[index]) else {
                fail("pair: --port needs a number")
            }
            port = parsed
        default:
            fail("pair: unknown flag \(args[index])")
        }
        index += 1
    }

    let token: String
    do {
        if let tokenFile {
            let normalized = MirrorPairing.normalize(
                (try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "")
            guard !normalized.isEmpty else { fail("pair: \(tokenFile) holds no token") }
            try WinPairingStore.store(normalized)
            token = normalized
        } else if fromStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let normalized = MirrorPairing.normalize(String(data: data, encoding: .utf8) ?? "")
            guard !normalized.isEmpty else { fail("pair: stdin held no token") }
            try WinPairingStore.store(normalized)
            token = normalized
        } else if rotate {
            token = MirrorPairing.generateToken()
            try WinPairingStore.store(token)
        } else {
            token = try WinPairingStore.loadOrCreate()
        }
    } catch {
        fail("pair: \(error)")
    }
    if show {
        print(token)
        return 0
    }

    let addresses = WinAddresses.ipv4()
    var endpoints: [String] = []
    if let lan = MirrorPairing.lanAddress(in: addresses) {
        endpoints.append("http://\(lan):\(port)")
    }
    if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
        endpoints.append("http://\(tailnet):\(port)")
    }
    guard !endpoints.isEmpty else {
        fail("pair: no non-loopback IPv4 address found — connect to a network first")
    }
    let url = MirrorPairing.pairURL(endpoints: endpoints, token: token)
    print(url)
    print("pairing token \(MirrorPairing.mask(token)) — `infinitus-win pair --show` prints it")
    if let qrencode = which("qrencode") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qrencode)
        process.arguments = ["-t", "ANSIUTF8", url]
        if (try? process.run()) != nil { process.waitUntilExit() }
    } else {
        print("install qrencode for a QR")
    }
    return 0
}

/// PATH lookup for an optional external tool (qrencode) — no shell, no
/// `where` subprocess. Windows splits on `;`; executables end in .exe.
func which(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ";") where !dir.isEmpty {
        for suffix in [".exe", ".cmd", ""] {
            let candidate = "\(dir)\\\(name)\(suffix)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
    }
    return nil
}

// MARK: - listen (W4)

/// `infinitus-win listen --token-file P [--port N]` — the W4 HTTP
/// listener with the mirror-shaped routes W7 will replace wholesale:
/// `GET /snapshot` → 200, anything else → 404, bad token → 401 checked
/// off the head alone. The token travels by file, never argv, so the
/// test harness (and a caller wrapping this) doesn't leak it in a
/// process list. Blocks until killed.
// MARK: - serve (W7)

/// `infinitus-win serve [--port N] [--claude-dir P] [--token-file P]` —
/// the real thing: the phone's whole HTTP surface (snapshot, feed tail
/// with long-poll, images, input) over the pairing token. Without
/// `--token-file` it uses the stored token, so `pair` then `serve` is the
/// entire setup.
func serve(_ args: [String]) -> Int32 {
    var tokenFile: String?, port: UInt16 = defaultMirrorPort
    var claudeDir = ClaudeSessions.configHome()
    var autoResume = false
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--token-file":
            index += 1
            guard index < args.endIndex else { fail("serve: --token-file needs a path") }
            tokenFile = args[index]
        case "--claude-dir":
            index += 1
            guard index < args.endIndex else { fail("serve: --claude-dir needs a path") }
            claudeDir = URL(fileURLWithPath: args[index])
        case "--port":
            index += 1
            guard index < args.endIndex, let parsed = UInt16(args[index]) else {
                fail("serve: --port needs a number")
            }
            port = parsed
        case "--auto-resume": autoResume = true
        default:
            fail("serve: unknown flag \(args[index])")
        }
        index += 1
    }

    let token: String
    if let tokenFile {
        token = MirrorPairing.normalize(
            (try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "")
        guard !token.isEmpty else { fail("serve: \(tokenFile) holds no token") }
    } else {
        do { token = try WinPairingStore.loadOrCreate() } catch { fail("serve: \(error)") }
    }

    let snapshot = SnapshotCache(claudeDir: claudeDir)
    let handler = Routes.handler(claudeDir: claudeDir, snapshot: snapshot, token: token) { line in
        print(line)
        fflush(stdout)
    }
    let server = WinHTTPServer(
        authorize: { MirrorTransport.isAuthorized($0, token: token) },
        handler: handler)
    do {
        let bound = try server.start(port: port)
        print("listening on \(bound)")
        for endpoint in WinAddresses.ipv4().filter({ $0 != "127.0.0.1" }) {
            print("  http://\(endpoint):\(bound)")
        }
        print("token \(MirrorPairing.mask(token)) — `infinitus-win pair` prints the pairing URL")
        print("if the phone can't reach it, allow inbound TCP \(bound):")
        print("  netsh advfirewall firewall add rule name=\"Infinitus \(bound)\" dir=in action=allow protocol=TCP localport=\(bound)")
        let advertised = WinBonjour.advertise(port: bound)
        ControlServer.start(claudeDir: claudeDir, snapshot: snapshot)
        ControlServer.recordState(port: bound, bonjour: advertised)
        // Opt-in, like the Mac's toggle: a nudge types into someone's
        // session. Held alive by the run loop below.
        var supervisor: ResumeSupervisor?
        if autoResume {
            let started = ResumeSupervisor(claudeDir: claudeDir) { line in
                print(line)
                fflush(stdout)
            }
            started.start()
            supervisor = started
        }
        _ = supervisor
        fflush(stdout)
        RunLoop.main.run()
    } catch {
        fail("serve: \(error)")
    }
    return 0
}

// MARK: - listen (W4)

func listen(_ args: [String]) -> Int32 {
    var tokenFile: String?, port: UInt16 = defaultMirrorPort
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--token-file":
            index += 1
            guard index < args.endIndex else { fail("listen: --token-file needs a path") }
            tokenFile = args[index]
        case "--port":
            index += 1
            guard index < args.endIndex, let parsed = UInt16(args[index]) else {
                fail("listen: --port needs a number")
            }
            port = parsed
        default:
            fail("listen: unknown flag \(args[index])")
        }
        index += 1
    }
    guard let tokenFile else { fail("listen: --token-file is required") }
    let token = MirrorPairing.normalize(
        (try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "")
    guard !token.isEmpty else { fail("listen: \(tokenFile) holds no token") }

    let server = WinHTTPServer(authorize: { MirrorTransport.isAuthorized($0, token: token) }) { request in
        guard MirrorTransport.isAuthorized(request, token: token) else {
            return MirrorTransport.unauthorizedResponse()
        }
        guard request.method == "GET", request.path == MirrorTransport.snapshotPath else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.snapshotResponse(
            Data(#"{"machineName":"infinitus-win-listen"}"#.utf8))
    }
    do {
        let bound = try server.start(port: port)
        print("listening on \(bound)")
        fflush(stdout)   // the harness reads this line to know it's up
        RunLoop.main.run()
    } catch {
        fail("listen: \(error)")
    }
    return 0
}
