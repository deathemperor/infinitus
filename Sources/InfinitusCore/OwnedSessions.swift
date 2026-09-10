import Foundation
#if os(Windows)
import WinSDK
#endif

#if !os(iOS)
/// Claude Code sessions the app owns (#151): `claude` spawned with
/// stream-json on both pipes, stdin held open for the process lifetime,
/// prompts and answers written as frames, `can_use_tool` parked as
/// `PendingRequest`s until the phone or the Mac answers. The child writes
/// its own roster record (`~/.claude/sessions/<pid>.json`, entrypoint
/// "sdk-cli") and transcript, so the feed and the session list see it
/// like any other session — only input differs, and only stdin reaches
/// it (a peer-socket message is accepted and never delivered; step-0
/// probe). Lifecycle is actor-isolated; the per-child handles live in a
/// locked registry so `deliver`/`pending`/`ownedPids` are plain sync
/// calls from the input path.
public actor OwnedSessions {
    public enum State: Sendable, Equatable { case busy, idle, waiting, exited }

    /// One child: its stdin, its parked prompts, its last state. Written
    /// from the pipe-reader thread and the callers' threads; the lock
    /// keeps every mutation whole.
    final class Child: @unchecked Sendable {
        let pid: Int32
        let cwd: String
        private let stdin: FileHandle
        private let lock = NSLock()
        /// Frames go out whole, one writer at a time — but never under
        /// `lock`: a full pipe would stall the stdout reader, which needs
        /// `lock` to park and set, and the child would wedge on both ends.
        private let writeLock = NSLock()
        private var pendingList: [PendingRequest] = []
        private(set) var state: State = .busy
        /// A prompt is out and its `result` hasn't come back — `init`
        /// arriving mid-turn must not read as idle.
        private var turnOpenFlag = false
        var turnOpen: Bool {
            get { lock.lock(); defer { lock.unlock() }; return turnOpenFlag }
            set { lock.lock(); turnOpenFlag = newValue; lock.unlock() }
        }
        var sessionId: String = ""
        private var counter = 100
        /// Rejected rate-limit events of the current turn, one per
        /// window+reset; cleared when the next turn goes out.
        private var limitList: [LimitNote] = []
        /// The interrupt whose `result` is still awaited, for the soft
        /// fallback: nil once a result lands or a new turn starts.
        private var interruptStamp: Date?

        init(pid: Int32, cwd: String, stdin: FileHandle) {
            self.pid = pid; self.cwd = cwd; self.stdin = stdin
            // A write to a child that already exited must fail, not raise
            // SIGPIPE at the app (TeamGit.feed's idiom).
            #if canImport(Darwin)
            _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
            #elseif canImport(Glibc)
            _ = Child.ignoreSigpipe   // Windows has no SIGPIPE: the write just fails
            #endif
        }
        #if canImport(Glibc)
        private static let ignoreSigpipe: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
        #endif

        /// One frame, whole or not at all. False once the child is gone.
        @discardableResult
        func write(_ line: String) -> Bool {
            lock.lock(); let gone = state == .exited; lock.unlock()
            guard !gone else { return false }
            writeLock.lock(); defer { writeLock.unlock() }
            do { try stdin.write(contentsOf: Data(line.utf8)); return true } catch { return false }
        }
        func nextRequestId() -> String { lock.lock(); defer { lock.unlock() }; counter += 1; return String(counter) }
        var pending: [PendingRequest] { lock.lock(); defer { lock.unlock() }; return pendingList }
        func park(_ p: PendingRequest) { lock.lock(); pendingList.append(p); lock.unlock() }
        func take(requestId: String) -> PendingRequest? {
            lock.lock(); defer { lock.unlock() }
            guard let i = pendingList.firstIndex(where: { $0.requestId == requestId }) else { return nil }
            return pendingList.remove(at: i)
        }
        /// True when the state changed — callbacks fire on transitions only.
        func set(_ s: State) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard state != s else { return false }
            state = s
            if s == .exited { pendingList.removeAll() }
            return true
        }
        /// False when a frame write is stuck on a full pipe — the fd is
        /// left open (still owned by that writer) so `stop` can move on to
        /// `terminate()` instead of wedging behind it forever.
        @discardableResult
        func closeStdin(timeout: TimeInterval = 3) -> Bool {
            guard writeLock.lock(before: Date().addingTimeInterval(timeout)) else { return false }
            try? stdin.close(); writeLock.unlock()
            return true
        }

        var limits: [LimitNote] { lock.lock(); defer { lock.unlock() }; return limitList }
        /// True when the note is new for this turn.
        func note(_ limit: LimitNote) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !limitList.contains(where: { $0.key == limit.key }) else { return false }
            limitList.append(limit)
            return true
        }
        func clearLimits() { lock.lock(); limitList.removeAll(); lock.unlock() }
        var interrupted: Date? {
            get { lock.lock(); defer { lock.unlock() }; return interruptStamp }
            set { lock.lock(); interruptStamp = newValue; lock.unlock() }
        }
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var children: [Int32: Child] = [:]
        subscript(pid: Int32) -> Child? { lock.lock(); defer { lock.unlock() }; return children[pid] }
        func add(_ c: Child) { lock.lock(); children[c.pid] = c; lock.unlock() }
        func remove(_ pid: Int32) { lock.lock(); children[pid] = nil; lock.unlock() }
        var pids: Set<Int32> { lock.lock(); defer { lock.unlock() }; return Set(children.keys) }
        var all: [Child] { lock.lock(); defer { lock.unlock() }; return Array(children.values) }
    }

    nonisolated let registry = Registry()
    /// Broadcast on every parked prompt and state transition, so a
    /// long-poll on an owned pid (`SessionFeedReader.waitForChange`)
    /// wakes at once instead of on its next disk poll — the prompt shows
    /// the moment it parks, not up to two seconds later.
    public nonisolated let wake = NSCondition()
    private let binaryPath: String
    private let onState: @Sendable (Int32, State) -> Void
    /// The orphan ledger (#151 follow-up): nil in tests that don't care.
    private let ledger: OwnedLedger?
    /// How long an `interrupt` control request gets to produce its
    /// `result` before the turn is closed as idle anyway (T3 does not
    /// trust the CLI's interrupt; this trusts it for this long).
    private nonisolated let interruptGrace: TimeInterval
    private var processes: [Int32: Process] = [:]
    private var version: [Int]?
    private var loginShellPath: String?

    public init(binaryPath: String, ledger: OwnedLedger? = nil, interruptGrace: TimeInterval = 5,
                onState: @escaping @Sendable (Int32, State) -> Void) {
        self.binaryPath = binaryPath
        self.ledger = ledger
        self.interruptGrace = interruptGrace
        self.onState = onState
    }

    /// Pids of the children alive right now — the session card's "owned" tell.
    public nonisolated var ownedPids: Set<Int32> { registry.pids }

    /// A transition (or a parked prompt) to the app and to every waiter.
    private nonisolated func publish(_ pid: Int32, _ state: State) {
        onState(pid, state)
        poke()
    }

    private nonisolated func poke() {
        wake.lock(); wake.broadcast(); wake.unlock()
    }

    /// The roster's word for a child's state — the CLI leaves an sdk-cli
    /// record's `status` empty, so the card would say "unknown" without
    /// this. Nil for a pid that isn't ours or has exited.
    public nonisolated func status(pid: Int32) -> String? {
        switch registry[pid]?.state {
        case .busy?: return "busy"
        case .idle?: return "idle"
        case .waiting?: return "waiting"
        case .exited?, nil: return nil
        }
    }

    // MARK: lifecycle

    /// Spawns the session and answers as soon as the child runs: the pid
    /// is the reply, the `init` event arrives on the pipe a moment later.
    /// "failed" with the versions in `detail` when the installed Claude
    /// Code predates host permission prompts.
    public func start(_ req: SessionStart.Request) async -> SessionStart.Reply {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: req.cwd, isDirectory: &isDir), isDir.boolValue else {
            return SessionStart.Reply(outcome: "badCwd", detail: "no such folder: \(req.cwd)")
        }
        let v = await installedVersion()
        guard let v, ClaudeLocator.supportsOwnedSessions(version: v) else {
            let found = v.map { $0.map(String.init).joined(separator: ".") } ?? "unknown"
            let need = ClaudeLocator.minimumVersion.map(String.init).joined(separator: ".")
            return SessionStart.Reply(outcome: "failed",
                                      detail: "Claude Code \(need) or newer is needed to own a session; found \(found) at \(binaryPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = OwnedWire.arguments(for: req, sessionId: UUID().uuidString)
        p.currentDirectoryURL = URL(fileURLWithPath: req.cwd)
        // Not a nested session: the host's own CLAUDECODE would make the
        // child think it runs inside another Claude.
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        // The login shell's PATH first (the igniter's lesson: a GUI app's
        // own PATH reaches neither `claude` nor the tools its Bash calls),
        // then the fixed prefixes for a Mac without zsh output.
        let home = NSHomeDirectory()
        let front = [await loginPath(), (binaryPath as NSString).deletingLastPathComponent,
                     "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (front + [env["PATH"] ?? "/usr/bin:/bin"]).filter { !$0.isEmpty }.joined(separator: ":")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            return SessionStart.Reply(outcome: "failed", detail: "couldn't start claude: \(error.localizedDescription)")
        }
        let child = Child(pid: p.processIdentifier, cwd: req.cwd, stdin: stdin.fileHandleForWriting)
        registry.add(child)
        processes[child.pid] = p
        let ledger = self.ledger
        // Recorded before init arrives — a crash between spawn and init
        // must still leave a pid the next launch's sweep can find (empty
        // sessionId there means "skip", never "match anything").
        ledger?.record(pid: child.pid, sessionId: "")
        attach(stdout.fileHandleForReading, to: child, ledger: ledger)
        p.terminationHandler = { [weak self, registry] proc in
            // Instant once the child is gone; on Linux it is what frees the
            // Process (corelibs keeps a handler-waited one in a run-loop
            // source cycle), and with it the stdin/stdout pipe ends (#510).
            proc.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            if child.set(.exited) { self?.publish(child.pid, .exited) }
            // The child is already gone — any blocked write has failed with
            // EPIPE by now, so a short wait is enough.
            child.closeStdin(timeout: 0.5)
            registry.remove(child.pid)
            ledger?.forget(pid: child.pid)
            Task { [weak self] in await self?.forget(child.pid) }
        }
        // The handler goes on after `run()` (it needs the pid for the
        // child); a child that died in between never fires it, so fire it.
        if !p.isRunning { p.terminationHandler?(p) }
        // The turn is open before any frame goes out: `init` answers on the
        // reader thread and must not see a closed turn and publish idle.
        let prompt = req.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        child.turnOpen = !prompt.isEmpty
        child.write(OwnedWire.controlLine(requestId: "1", subtype: "initialize"))
        if !prompt.isEmpty { child.write(OwnedWire.userLine(prompt)) }
        return SessionStart.Reply(outcome: "started", host: "owned", pid: Int(child.pid))
    }

    private func forget(_ pid: Int32) { processes[pid] = nil }

    /// The pipe reader: lines to states, prompts to the parked list.
    /// Nothing is published per line — `onState` fires on transitions.
    private nonisolated func attach(_ handle: FileHandle, to child: Child, ledger: OwnedLedger?) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            for line in buffer.feed(chunk) {
                switch OwnedWire.decode(line: line) {
                case .initialized(let sid, _):
                    child.sessionId = sid
                    // The sweep matches on this — the roster record's
                    // sessionId is what tells our pid apart from a reused one.
                    ledger?.record(pid: child.pid, sessionId: sid)
                    if !child.turnOpen, child.set(.idle) { self?.publish(child.pid, .idle) }
                case .canUseTool(let pending):
                    child.park(pending)
                    // A second prompt parks under an unchanged state:
                    // waiters still need to hear about it.
                    if child.set(.waiting) { self?.publish(child.pid, .waiting) } else { self?.poke() }
                case .result:
                    child.turnOpen = false
                    child.interrupted = nil
                    if child.set(child.pending.isEmpty ? .idle : .waiting) { self?.publish(child.pid, child.state) }
                case .rateLimit(let note):
                    if child.note(note) { self?.poke() }
                case .controlResponse, .other:
                    break
                }
            }
        }
    }

    /// Closes stdin — the child exits on EOF (step-0: within 3 s) — then
    /// SIGTERM, then SIGKILL, so a wedged child never outlives the app
    /// (#274's lesson).
    public func stop(pid: Int32) async {
        guard let child = registry[pid] else { return }
        // A frame write stuck on a full pipe holds `writeLock`; closeStdin
        // gives up rather than wait behind it, straight to terminate().
        if child.closeStdin() {
            for _ in 0..<30 where processes[pid]?.isRunning == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if processes[pid]?.isRunning == true {
            processes[pid]?.terminate()
            for _ in 0..<20 where processes[pid]?.isRunning == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            #if canImport(Darwin) || canImport(Glibc)
            if processes[pid]?.isRunning == true { kill(pid, SIGKILL) }   // Windows' terminate() is already TerminateProcess
            #endif
        }
    }

    /// App quit: every child, in parallel.
    public func stopAll() async {
        let pids = registry.pids
        await withTaskGroup(of: Void.self) { group in
            for pid in pids { group.addTask { await self.stop(pid: pid) } }
        }
    }

    /// `sweepOrphans` defaults. POSIX: a null signal probes, SIGTERM asks.
    /// Windows has neither (#406): the process handle answers, and
    /// TerminateProcess is the only ask there is.
    public nonisolated static func orphanAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        ClaudeSessions.isAlive(pid)
        #else
        kill(pid, 0) == 0
        #endif
    }
    public nonisolated static func orphanTerminate(_ pid: Int32) {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
        defer { CloseHandle(handle) }
        _ = TerminateProcess(handle, 1)
        #else
        kill(pid, SIGTERM)
        #endif
    }

    /// Launch-time cleanup (#151 follow-up): a headless child survives a
    /// SIGKILL of the app (no PDEATHSIG on Darwin), so the NEXT launch
    /// reconciles last run's ledger against the live roster. A pid is only
    /// ever signalled when its roster record's sessionId matches OURS —
    /// `entrypoint: sdk-cli` alone is not proof (any SDK consumer writes
    /// it) — and only ever SIGTERM, the same as the orderly `stop` path's
    /// first step. Every entry is removed whether or not it matched: a
    /// stale one (pid dead, record gone, sessionId changed) is just noise.
    public nonisolated static func sweepOrphans(ledger: OwnedLedger, claudeDir: URL,
                                                alive: (Int32) -> Bool = OwnedSessions.orphanAlive,
                                                signal: (Int32) -> Void = OwnedSessions.orphanTerminate) -> [Int32] {
        let records = ClaudeSessions.list(claudeDir: claudeDir, alive: alive)
        var signalled: [Int32] = []
        for entry in ledger.entries() {
            defer { ledger.forget(pid: entry.pid) }
            guard !entry.sessionId.isEmpty, alive(entry.pid),
                  let record = records.first(where: { $0.pid == entry.pid }),
                  record.sessionId == entry.sessionId, record.entrypoint == "sdk-cli"
            else { continue }
            signal(entry.pid)
            signalled.append(entry.pid)
        }
        return signalled
    }

    private func installedVersion() async -> [Int]? {
        if let version { return version }
        guard let banner = await ClaudeLocator.capture(binaryPath, ["--version"]) else { return nil }
        version = ClaudeLocator.parseVersion(banner)
        return version
    }

    private func loginPath() async -> String {
        if let loginShellPath { return loginShellPath }
        let path = await ClaudeLocator.loginShellPath()
        loginShellPath = path
        return path
    }

    // MARK: input — sync, from any thread

    /// A user turn. False when the pid is not ours or the child is gone.
    public nonisolated func send(pid: Int32, text: String, images: [OwnedWire.Image] = []) -> Bool {
        guard let child = registry[pid], child.write(OwnedWire.userLine(text, images: images)) else { return false }
        child.turnOpen = true
        child.interrupted = nil
        child.clearLimits()
        if child.set(.busy) { publish(pid, .busy) }
        return true
    }

    /// The CLI's `interrupt` control request, trusted for `interruptGrace`:
    /// if the turn's `result` hasn't landed by then, the turn closes as
    /// idle here so no client sits on "busy" (#151, #223 §6).
    public nonisolated func interrupt(pid: Int32) -> Bool {
        guard let child = registry[pid] else { return false }
        guard child.write(OwnedWire.controlLine(requestId: child.nextRequestId(), subtype: "interrupt")) else { return false }
        let stamp = Date()
        child.interrupted = stamp
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptGrace) { [weak self] in
            guard child.interrupted == stamp, child.turnOpen else { return }
            child.turnOpen = false
            child.interrupted = nil
            if child.set(child.pending.isEmpty ? .idle : .waiting) { self?.publish(pid, child.state) }
        }
        return true
    }

    /// The current turn's rejected rate-limit notes, for the feed.
    public nonisolated func limits(pid: Int32) -> [LimitNote] { registry[pid]?.limits ?? [] }

    /// `set_permission_mode`, Claude Code's own mode names only.
    public nonisolated func setPermissionMode(pid: Int32, mode: String) -> Bool {
        guard let child = registry[pid], OwnedWire.permissionModes.contains(mode) else { return false }
        return child.write(OwnedWire.controlLine(requestId: child.nextRequestId(),
                                                 subtype: "set_permission_mode", fields: ["mode": mode]))
    }

    public nonisolated func pending(pid: Int32) -> [PendingRequest] { registry[pid]?.pending ?? [] }

    /// Answers one parked prompt; false for an unknown pid or request id.
    public nonisolated func answer(pid: Int32, requestId: String, decision: OwnedWire.Decision) -> Bool {
        guard let child = registry[pid], let pending = child.take(requestId: requestId) else { return false }
        guard child.write(OwnedWire.answerLine(pending, decision)) else { return false }
        // The answered prompt leaves the parked list either way.
        if child.pending.isEmpty, child.set(.busy) { publish(pid, .busy) } else { poke() }
        return true
    }

    /// `SessionInput.deliver`'s `owned` hook: nil for a pid we don't own;
    /// otherwise the request lands on stdin — a message as a turn, `esc`
    /// as an interrupt, a digit/y/n/enter as the verdict or option for the
    /// oldest parked prompt, `approve` as allow. Mode changes stay the
    /// app's business (nil), like the terminal path.
    public nonisolated func deliver(_ request: SessionInput.Request, record: ClaudeSessionRecord) -> SessionInput.Reply? {
        guard registry[record.pid] != nil else { return nil }
        let pid = record.pid
        let delivered = SessionInput.Reply(outcome: "delivered", channel: "stdin")
        switch request.kind {
        case .mode:
            return nil
        case .message, .resume:
            if let rejection = SessionInput.attachmentRejection(request.attachments) {
                return SessionInput.Reply(outcome: "rejected", detail: rejection)
            }
            let attachments = request.attachments ?? []
            guard attachments.allSatisfy({ OwnedWire.imageMediaTypes.contains($0.mime) }) else {
                return SessionInput.Reply(outcome: "rejected",
                                          detail: "a headless session takes png, jpeg, gif and webp images only")
            }
            let images = attachments.map { OwnedWire.Image(mediaType: $0.mime, base64: $0.data.base64EncodedString()) }
            return send(pid: pid, text: request.text, images: images) ? delivered
                : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
        case .approve:
            guard let first = pending(pid: pid).first else {
                return SessionInput.Reply(outcome: "rejected", detail: "no pending request")
            }
            return answer(pid: pid, requestId: first.requestId, decision: .allow(forSession: true)) ? delivered
                : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
        case .deny:
            guard let first = pending(pid: pid).first else {
                return SessionInput.Reply(outcome: "rejected", detail: "no pending request")
            }
            let message = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer(pid: pid, requestId: first.requestId,
                          decision: .deny(message: message.isEmpty ? OwnedWire.denyMessage : message)) ? delivered
                : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
        case .answers:
            // Every question of the oldest parked AskUserQuestion at once.
            guard let ask = pending(pid: pid).first(where: { !$0.questions.isEmpty }) else {
                return SessionInput.Reply(outcome: "rejected", detail: "no pending question")
            }
            guard let decision = OwnedWire.decision(answers: request.text, pending: ask) else {
                return SessionInput.Reply(outcome: "rejected", detail: "no such option")
            }
            return answer(pid: pid, requestId: ask.requestId, decision: decision) ? delivered
                : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
        case .key:
            guard SessionInput.allowedKeys.contains(request.text) else {
                return SessionInput.Reply(outcome: "rejected", detail: "unsupported key")
            }
            if request.text == "esc" {
                return interrupt(pid: pid) ? delivered : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
            }
            guard let first = pending(pid: pid).first else {
                return SessionInput.Reply(outcome: "rejected", detail: "no pending request")
            }
            guard let decision = OwnedWire.decision(forKey: request.text, pending: first) else {
                return SessionInput.Reply(outcome: "rejected", detail: "no such option")
            }
            return answer(pid: pid, requestId: first.requestId, decision: decision) ? delivered
                : SessionInput.Reply(outcome: "noChannel", detail: "the session has exited")
        }
    }
}

/// Splits pipe chunks into complete lines; the tail waits for its newline.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[..<nl], as: UTF8.self))
            data = Data(data[data.index(after: nl)...])
        }
        return lines
    }
}
#endif
