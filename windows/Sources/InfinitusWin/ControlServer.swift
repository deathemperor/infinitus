import Foundation
import InfinitusCore
import WinSDK

// MARK: - Control Server & Client for Windows (infinitus-win control)
//
// NDJSON request in -> NDJSON response out over a same-user Windows named pipe.
// Default pipe: \\.\pipe\infinitus-win-control
// Override env: INFINITUS_CONTROL_PIPE
// DACL restricts access to the current user, SYSTEM, and Administrators.

enum ControlServer {
    static let defaultPipeName = "\\\\.\\pipe\\infinitus-win-control"

    static func pipePath() -> String {
        if let override = ProcessInfo.processInfo.environment["INFINITUS_CONTROL_PIPE"], !override.isEmpty {
            if override.hasPrefix("\\\\.\\pipe\\") || override.hasPrefix("\\\\?\\pipe\\") {
                return override
            } else if override.hasPrefix("pipe\\") {
                return "\\\\.\\" + override
            } else {
                return "\\\\.\\pipe\\" + override
            }
        }
        return defaultPipeName
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var serverThread: Thread?
    private nonisolated(unsafe) static var isRunning = false
    private nonisolated(unsafe) static var activePipeName: String = defaultPipeName

    // State recorded at start for `status` command
    private nonisolated(unsafe) static var startTime: Date = Date()
    private nonisolated(unsafe) static var servingPort: UInt16 = 0
    private nonisolated(unsafe) static var bonjourAdvertised: Bool = false
    private nonisolated(unsafe) static var sharedSnapshot: SnapshotCache?
    private nonisolated(unsafe) static var sharedClaudeDir: URL?

    static func recordState(port: UInt16, bonjour: Bool) {
        lock.lock()
        defer { lock.unlock() }
        servingPort = port
        bonjourAdvertised = bonjour
    }

    /// Starts the control listener on a background thread. Never fatal:
    /// a failure logs and leaves `serve` running.
    static func start(claudeDir: URL, snapshot: SnapshotCache) {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        sharedClaudeDir = claudeDir
        sharedSnapshot = snapshot
        startTime = Date()
        isRunning = true
        let pipe = pipePath()
        activePipeName = pipe

        let thread = Thread {
            runServerLoop(pipePath: pipe, claudeDir: claudeDir, snapshot: snapshot)
        }
        thread.name = "infinitus-win.control"
        serverThread = thread
        thread.start()
    }

    static func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let pipe = activePipeName
        lock.unlock()

        // Unblock ConnectNamedPipe via a dummy connection
        let wide = Array(pipe.utf16) + [0]
        let dummy = CreateFileW(
            wide,
            DWORD(GENERIC_READ),
            0,
            nil,
            DWORD(OPEN_EXISTING),
            0,
            nil
        )
        if dummy != INVALID_HANDLE_VALUE {
            CloseHandle(dummy)
        }
    }

    private static func runServerLoop(pipePath: String, claudeDir: URL, snapshot: SnapshotCache) {
        let wide = Array(pipePath.utf16) + [0]

        while true {
            lock.lock()
            let keepGoing = isRunning
            lock.unlock()
            guard keepGoing else { break }

            var sa = SECURITY_ATTRIBUTES()
            sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
            sa.bInheritHandle = false
            var descriptor: PSECURITY_DESCRIPTOR? = nil

            if let sid = WinPairingStore.currentUserSid() {
                let sddl = Array("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;\(sid))".utf16) + [0]
                if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl, DWORD(SDDL_REVISION_1), &descriptor, nil), let desc = descriptor {
                    sa.lpSecurityDescriptor = desc
                }
            }
            defer {
                if let descriptor { LocalFree(HLOCAL(descriptor)) }
            }

            let handle = withUnsafeMutablePointer(to: &sa) { pSa -> HANDLE in
                CreateNamedPipeW(
                    wide,
                    DWORD(PIPE_ACCESS_DUPLEX),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    DWORD(PIPE_UNLIMITED_INSTANCES),
                    65536,
                    65536,
                    0,
                    pSa.pointee.lpSecurityDescriptor != nil ? pSa : nil
                )
            }

            guard handle != INVALID_HANDLE_VALUE else {
                FileHandle.standardError.write(Data("ControlServer: CreateNamedPipeW failed: \(GetLastError())\n".utf8))
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            let connected = ConnectNamedPipe(handle, nil) ? true : (GetLastError() == DWORD(ERROR_PIPE_CONNECTED))

            lock.lock()
            let alive = isRunning
            lock.unlock()
            guard alive else {
                CloseHandle(handle)
                break
            }

            if connected {
                handleConnection(handle: handle, claudeDir: claudeDir, snapshot: snapshot)
                FlushFileBuffers(handle)
                DisconnectNamedPipe(handle)
            }
            CloseHandle(handle)
        }
    }

    private static func handleConnection(handle: HANDLE, claudeDir: URL, snapshot: SnapshotCache) {
        // Read NDJSON request line (capped at 64 KB)
        var buffer = [UInt8](repeating: 0, count: 65536)
        var totalRead = 0

        while totalRead < buffer.count {
            var readCount: DWORD = 0
            let ok = ReadFile(
                handle,
                &buffer[totalRead],
                DWORD(buffer.count - totalRead),
                &readCount,
                nil
            )
            guard ok, readCount > 0 else { break }
            totalRead += Int(readCount)
            if buffer.prefix(totalRead).contains(0x0A) { break }
        }

        guard totalRead > 0 else { return }
        let requestData = Data(buffer.prefix(totalRead))
        let responseData = executeCommand(requestData: requestData, claudeDir: claudeDir, snapshot: snapshot)

        var written = 0
        responseData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < responseData.count {
                var wrote: DWORD = 0
                guard WriteFile(handle, base.advanced(by: written), DWORD(responseData.count - written), &wrote, nil),
                      wrote > 0 else { break }
                written += Int(wrote)
            }
        }
    }

    private struct StatusResponse: Encodable {
        let servingPort: UInt16
        let uptimeSeconds: Int
        let sessionCount: Int
        let enginePresent: Bool
        let bonjour: Bool
    }

    private static func executeCommand(requestData: Data, claudeDir: URL, snapshot: SnapshotCache) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            return Data(#"{"error":"unknown command"}"# .utf8) + Data([0x0A])
        }

        switch cmd {
        case "status":
            let uptime = max(0, Int(Date().timeIntervalSince(startTime)))
            let live = ClaudeSessions.list(claudeDir: claudeDir, alive: ClaudeSessions.isAlive)
            let engine = CswapLocator.locate() != nil
            let status = StatusResponse(
                servingPort: servingPort,
                uptimeSeconds: uptime,
                sessionCount: live.count,
                enginePresent: engine,
                bonjour: bonjourAdvertised
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = (try? encoder.encode(status)) ?? Data(#"{"error":"failed to encode status"}"#.utf8)
            data.append(0x0A)
            return data

        case "sessions":
            let rows = WinSessions.list(claudeDir: claudeDir)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = (try? encoder.encode(rows)) ?? Data("[]".utf8)
            data.append(0x0A)
            return data

        case "snapshot":
            var data = snapshot.data()
            if data.isEmpty {
                data = Data("{}".utf8)
            }
            data.append(0x0A)
            return data

        case "switch":
            // Account policy is the engine's (CLAUDE.md): this forwards
            // the ask. A missing `account` rotates — the engine's own
            // order, not ours.
            let number = (json["account"] as? NSNumber)?.intValue ?? (json["account"] as? Int)
            let outcome = CswapFleet.switchTo(number)
            var payload: [String: Any] = ["outcome": "\(outcome)"]
            switch outcome {
            case .switched(let active):
                payload = ["outcome": "switched", "activeAccountNumber": active]
            case .noEngine:
                payload = ["error": "no swap engine installed"]
            case .failed(let detail):
                payload = ["error": detail.isEmpty ? "engine refused the switch" : detail]
            }
            var data = (try? JSONSerialization.data(withJSONObject: payload))
                ?? Data(#"{"error":"failed to encode switch reply"}"#.utf8)
            data.append(0x0A)
            return data

        case "message":
            guard let pid = (json["pid"] as? NSNumber)?.int32Value ?? (json["pid"] as? Int).map(Int32.init),
                  let text = json["text"] as? String, !text.isEmpty else {
                return Data(#"{"error":"invalid pid or text"}"#.utf8) + Data([0x0A])
            }
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }) else {
                let reply = SessionInput.Reply(outcome: "noChannel", channel: nil, detail: "no live session with pid \(pid)")
                var data = (try? JSONEncoder().encode(reply)) ?? Data()
                data.append(0x0A)
                return data
            }
            let req = SessionInput.Request(kind: .message, text: text)
            let reply = SessionInput.deliver(
                request: req,
                record: record,
                hosts: [],
                claudeDir: claudeDir,
                ttyOfPid: { _ in nil },
                ancestorsOf: { _ in [] },
                socketSend: { record, text in
                    NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
                }
            )
            var data = (try? JSONEncoder().encode(reply)) ?? Data(#"{"outcome":"rejected"}"#.utf8)
            data.append(0x0A)
            return data

        default:
            return Data(#"{"error":"unknown command"}"#.utf8) + Data([0x0A])
        }
    }
}

// MARK: - Client subcommand: `infinitus-win control`

func control(_ args: [String]) -> Int32 {
    guard let cmd = args.first else {
        FileHandle.standardError.write(Data("usage: infinitus-win control status|sessions|snapshot|message [--pid N <text>]|switch [N]\n".utf8))
        return 2
    }

    var requestPayload: [String: Any] = [:]

    switch cmd {
    case "status", "sessions", "snapshot":
        requestPayload["cmd"] = cmd

    case "switch":
        // `control switch` rotates; `control switch 3` targets account 3.
        requestPayload["cmd"] = "switch"
        if let word = args.dropFirst().first {
            guard let number = Int(word) else {
                FileHandle.standardError.write(
                    Data("control switch: '\(word)' is not an account number\n".utf8))
                return 2
            }
            requestPayload["account"] = number
        }

    case "message":
        var pid: Int32?
        var textWords: [String] = []
        var i = 1
        while i < args.count {
            if args[i] == "--pid" {
                i += 1
                if i < args.count, let parsed = Int32(args[i]) {
                    pid = parsed
                }
            } else {
                textWords.append(args[i])
            }
            i += 1
        }
        guard let pid else {
            FileHandle.standardError.write(Data("control message: --pid is required\n".utf8))
            return 2
        }
        let text = textWords.joined(separator: " ")
        guard !text.isEmpty else {
            FileHandle.standardError.write(Data("control message: text is required\n".utf8))
            return 2
        }
        requestPayload["cmd"] = "message"
        requestPayload["pid"] = pid
        requestPayload["text"] = text

    default:
        FileHandle.standardError.write(Data("control: unknown command '\(cmd)'\n".utf8))
        return 2
    }

    guard var reqData = try? JSONSerialization.data(withJSONObject: requestPayload) else {
        FileHandle.standardError.write(Data("control: failed to encode request\n".utf8))
        return 1
    }
    reqData.append(0x0A)

    let pipePath = ControlServer.pipePath()
    let wide = Array(pipePath.utf16) + [0]

    let desiredAccess = DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE)
    let handle = CreateFileW(
        wide,
        desiredAccess,
        0,
        nil,
        DWORD(OPEN_EXISTING),
        0,
        nil
    )

    guard handle != INVALID_HANDLE_VALUE else {
        let err = GetLastError()
        FileHandle.standardError.write(Data("control: cannot connect to pipe '\(pipePath)': error \(err)\n".utf8))
        return 3
    }
    defer { CloseHandle(handle) }

    var written = 0
    let writeOk = reqData.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        while written < reqData.count {
            var wrote: DWORD = 0
            guard WriteFile(handle, base.advanced(by: written), DWORD(reqData.count - written), &wrote, nil),
                  wrote > 0 else { return false }
            written += Int(wrote)
        }
        return true
    }
    guard writeOk else {
        FileHandle.standardError.write(Data("control: failed to write request\n".utf8))
        return 1
    }
    FlushFileBuffers(handle)

    var responseData = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        var readCount: DWORD = 0
        let ok = ReadFile(handle, &chunk, DWORD(chunk.count), &readCount, nil)
        if !ok || readCount == 0 { break }
        responseData.append(chunk, count: Int(readCount))
        if responseData.last == 0x0A { break }
    }

    guard !responseData.isEmpty else {
        FileHandle.standardError.write(Data("control: empty response from server\n".utf8))
        return 1
    }

    if let jsonObj = try? JSONSerialization.jsonObject(with: responseData),
       let pretty = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: pretty, as: UTF8.self))
    } else {
        print(String(decoding: responseData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    if let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
       parsed["error"] != nil {
        return 1
    }
    return 0
}
