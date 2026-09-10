import Foundation
import InfinitusCore

/// The Mac's PTY host (#507 step 3): one login shell per session pid, its
/// master fd read on this host's own serial queue into a `TerminalRing`, its
/// output fanned out to every attached stream as `T3Terminal` frames. The
/// wire — frames, caps, ids, the resume plan — is Core's `T3Terminal`; this
/// only serves it.
///
/// AppKit-free and Foundation-only on purpose (#507 review ruling 3): the
/// Linux tray needs the same host, and `forkpty`/`TIOCSWINSZ`/`DispatchSource`
/// are all portable. Nothing here touches the main actor — output fan-out
/// runs on `queue`, and a route's own dispatch is where the reply is framed.
///
/// v1 is one terminal per session (`T3Terminal.defaultTerminalId`), so the
/// map is keyed by session pid + terminal id and `open` on an already open
/// terminal is an attach, the way upstream's `TerminalManager.open` reuses a
/// session (`apps/server/src/terminal/Manager.ts:152`, `openOrAttachForStream`
/// resizing the live PTY when the caller asks for a different size).
///
/// Timers: a terminal arms one 30-minute idle timer while nothing is
/// attached, and one 2-second timer between `SIGHUP` and `SIGKILL` while it
/// is closing. Both live on `queue` and only exist while a terminal does —
/// with no terminal open the host has no sources at all and costs nothing
/// (the perf gate, #507 review ruling 6).
final class TerminalHost: @unchecked Sendable {

    /// How long a terminal survives with no attached stream — the phone's
    /// screen is gone and nobody is reading (#507 "idle-close after 30 min").
    static let idleTimeout: TimeInterval = 30 * 60
    /// How long the shell gets between `SIGHUP` and `SIGKILL`.
    static let killGrace: TimeInterval = 2
    /// One read per readable event; a pty hands over far less than this.
    private static let readChunk = 64 * 1024
    /// A write waits this long at a time for the shell to drain the pty's
    /// input buffer, and gives up after `writeDeadline` altogether: the
    /// master is non-blocking, so without the wait a paste into a shell
    /// that isn't reading (a running `sleep`, a paused pager) would spin
    /// on `EAGAIN` instead of waiting.
    private static let writeWaitMs: Int32 = 100
    private static let writeDeadline: TimeInterval = 5

    /// What a route needs to turn into a status. `nil` from the host's
    /// methods (never this) is "no such session or terminal" — a 404.
    enum HostError: Error, Equatable {
        /// The request failed Core's own caps (cols/rows range, 64 KB write).
        case validation(T3Terminal.ValidationError)
        /// `forkpty` or the exec failed — the phone gets the sentence.
        case spawnFailed(String)
    }

    struct OpenOutcome: Sendable {
        let reply: T3Terminal.OpenReply
        /// False when this open found the terminal already running: the
        /// route answers 200 with the existing reply instead of 201.
        let created: Bool
    }

    /// Frames for one attached stream, delivered on the host's queue and
    /// therefore in order. The sink must not call back into the host
    /// synchronously — `detach` is asynchronous for exactly that reason.
    typealias Sink = @Sendable ([T3Terminal.Frame]) -> Void

    /// A route's handle on its attachment, so a hung-up connection can take
    /// itself out of the fan-out.
    final class Attachment: Sendable {
        let id = UUID()
        let pid: Int32
        let terminalId: String
        init(pid: Int32, terminalId: String) {
            self.pid = pid
            self.terminalId = terminalId
        }
    }

    private struct Key: Hashable {
        let pid: Int32
        let id: String
    }

    /// The master fd, mutated only on `fdQueue`: every syscall that takes
    /// it (write, resize, close) runs there, so a closed fd number can
    /// never be reused under a caller mid-write.
    private final class FdBox: @unchecked Sendable {
        var fd: Int32
        init(_ fd: Int32) { self.fd = fd }
    }

    /// One live terminal. Touched only on `queue` (except `fd`, above).
    private final class Terminal {
        let sessionPid: Int32
        let id: String
        let cwd: String
        let child: pid_t
        let fd: FdBox
        var cols: Int
        var rows: Int
        var ring = TerminalRing()
        var status: T3Terminal.SessionStatus = .running
        var exitCode: Int?
        var exitSignal: Int?
        var readSource: DispatchSourceRead?
        var attachments: [UUID: Sink] = [:]
        var idleTimer: DispatchSourceTimer?
        var killTimer: DispatchSourceTimer?
        /// Between the first kill and the child being reaped.
        var closing = false
        var closeReason: String?
        /// `exited` + `closed` have gone out; the terminal is off the map.
        var finished = false
        var readBuffer = [UInt8](repeating: 0, count: TerminalHost.readChunk)

        init(sessionPid: Int32, id: String, cwd: String, child: pid_t, fd: Int32, cols: Int, rows: Int) {
            self.sessionPid = sessionPid
            self.id = id
            self.cwd = cwd
            self.child = child
            self.fd = FdBox(fd)
            self.cols = cols
            self.rows = rows
        }

        var reply: T3Terminal.OpenReply {
            T3Terminal.OpenReply(terminalId: id, status: status, cwd: cwd, pid: child)
        }
    }

    private let queue = DispatchQueue(label: "run.infinitus.terminal")
    /// Writes and resizes: a pty's input buffer is a few KB, so a 64 KB
    /// paste has to wait for the shell to drain it — never on `queue`,
    /// which output fan-out needs (#507 review ruling 4: a write must not
    /// wait on the stream).
    private let fdQueue = DispatchQueue(label: "run.infinitus.terminal-fd")
    private var terminals: [Key: Terminal] = [:]

    // MARK: - Open

    /// Opens (or re-attaches to) the session's terminal. `cwd` is the
    /// session's own working directory — the caller resolves it, an unknown
    /// pid never reaches here.
    func open(pid: Int32, cwd: String, request: T3Terminal.OpenRequest) -> Result<OpenOutcome, HostError> {
        if let invalid = request.validate() { return .failure(.validation(invalid)) }
        let key = Key(pid: pid, id: T3Terminal.defaultTerminalId)
        if let existing: Terminal = queue.sync(execute: { terminals[key] }) {
            // Upstream reuses the session and resizes it to what the new
            // caller asked for; the reply is the running terminal's.
            _ = resize(pid: pid, id: existing.id,
                       T3Terminal.ResizeRequest(cols: request.cols, rows: request.rows))
            return .success(OpenOutcome(reply: queue.sync { existing.reply }, created: false))
        }
        let spawned: (master: Int32, child: pid_t)
        do {
            spawned = try Self.spawn(cwd: cwd, cols: request.cols, rows: request.rows)
        } catch let error as HostError {
            return .failure(error)
        } catch {
            return .failure(.spawnFailed("\(error)"))
        }
        return .success(queue.sync {
            // A concurrent open for the same pid can win the race between
            // the check above and here — both saw no entry and both
            // spawned (#507 follow-up). The insert is the single point of
            // truth: whoever gets here first with `terminals[key] == nil`
            // owns the pid, and a later loser kills the shell it just
            // forked instead of orphaning it.
            if let existing = terminals[key] {
                killOrphan(master: spawned.master, child: spawned.child)
                return OpenOutcome(reply: existing.reply, created: false)
            }
            let terminal = Terminal(sessionPid: pid, id: key.id, cwd: cwd, child: spawned.child,
                                    fd: spawned.master, cols: request.cols, rows: request.rows)
            terminals[key] = terminal
            let source = DispatchSource.makeReadSource(fileDescriptor: spawned.master, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(terminal) }
            source.setCancelHandler { [fdQueue = self.fdQueue] in
                // The fd number stays reserved until every queued write and
                // resize has run: those go through fdQueue too.
                fdQueue.async { if terminal.fd.fd >= 0 { Darwin.close(terminal.fd.fd); terminal.fd.fd = -1 } }
            }
            terminal.readSource = source
            source.resume()
            // Nobody has attached yet — the idle clock starts at open.
            armIdleTimer(terminal)
            return OpenOutcome(reply: terminal.reply, created: true)
        })
    }

    /// Kills and reaps a shell a losing concurrent `open` just spawned
    /// (#507 follow-up): the winner already owns `terminals[key]`, so this
    /// one only has to not leak a fork or a zombie. `SIGHUP` then close the
    /// master fd the way the read source's cancel handler does; if the
    /// shell hasn't died by the time a normal close would give up, follow
    /// with `SIGKILL` and a blocking reap.
    private func killOrphan(master: Int32, child: pid_t) {
        kill(child, SIGHUP)
        fdQueue.async { Darwin.close(master) }
        var status: Int32 = 0
        if waitpid(child, &status, WNOHANG) != 0 { return }   // reaped, or ECHILD: already gone
        // `asyncAfter`, not a `DispatchSourceTimer`: nothing here owns a
        // `Terminal` to hang a retained timer off, and a purely local one
        // would be deallocated (and so cancelled) the moment this function
        // returns — the SIGKILL follow-up would silently never fire.
        queue.asyncAfter(deadline: .now() + Self.killGrace) {
            killpg(child, SIGKILL)
            kill(child, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
        }
    }

    // MARK: - Attach / detach

    /// Attaches a stream: the resume decision and its first frames are
    /// handed to `sink` before this returns, on `queue`, so no live output
    /// can slip in front of them. `nil` = no such terminal (404).
    func attach(pid: Int32, id: String, since: Int?, sink: @escaping Sink) -> Attachment? {
        queue.sync {
            guard let terminal = terminals[Key(pid: pid, id: id)], !terminal.finished else { return nil }
            let attachment = Attachment(pid: pid, terminalId: id)
            terminal.attachments[attachment.id] = sink
            terminal.idleTimer?.cancel()
            terminal.idleTimer = nil
            sink(Self.openingFrames(terminal, since: since))
            return attachment
        }
    }

    func detach(_ attachment: Attachment) {
        queue.async { [self] in
            guard let terminal = terminals[Key(pid: attachment.pid, id: attachment.terminalId)] else { return }
            terminal.attachments[attachment.id] = nil
            if terminal.attachments.isEmpty { armIdleTimer(terminal) }
        }
    }

    /// The `snapshot` frames, or the ring replay a `since` earns — Core's
    /// `resumePlan` decides which (#507 review ruling 1: never a gap).
    private static func openingFrames(_ terminal: Terminal, since: Int?) -> [T3Terminal.Frame] {
        switch T3Terminal.resumePlan(since: since, ringStart: terminal.ring.start,
                                     ringEnd: terminal.ring.end) {
        case .snapshot:
            return T3Terminal.snapshotFrames(history: terminal.ring.history,
                                             ringStart: terminal.ring.start,
                                             status: terminal.status,
                                             exitCode: terminal.exitCode,
                                             exitSignal: terminal.exitSignal).map { .snapshot($0) }
        case .outputFrom(let sequence):
            guard let text = terminal.ring.slice(from: sequence), !text.isEmpty else { return [] }
            var offset = sequence
            return T3Terminal.historyChunks(text).map { chunk in
                offset += chunk.utf8.count
                return .output(T3Terminal.OutputPayload(data: chunk, sequence: offset))
            }
        }
    }

    // MARK: - Write / resize

    /// `nil` = no such terminal (404). Core's `WriteRequest.validate()`
    /// decides the 64 KB refusal.
    func write(pid: Int32, id: String, _ request: T3Terminal.WriteRequest) -> Result<Void, HostError>? {
        guard let terminal: Terminal = queue.sync(execute: { live(pid: pid, id: id) }) else { return nil }
        if let invalid = request.validate() { return .failure(.validation(invalid)) }
        let bytes = [UInt8](request.data.utf8)
        guard !bytes.isEmpty else { return .success(()) }
        return fdQueue.sync { () -> Result<Void, HostError>? in
            let fd = terminal.fd.fd
            guard fd >= 0 else { return nil }
            var written = 0
            var waited: TimeInterval = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress, buffer.count)
                }
                if n > 0 { written += n; waited = 0; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&poller, 1, Self.writeWaitMs)
                    if ready > 0 { continue }
                    if ready < 0 && errno == EINTR { continue }
                    waited += TimeInterval(Self.writeWaitMs) / 1000
                    guard waited < Self.writeDeadline else {
                        return .failure(.spawnFailed("the shell is not reading its input"))
                    }
                    continue
                }
                return .failure(.spawnFailed("write failed (errno \(errno))"))
            }
            return .success(())
        }
    }

    /// `nil` = no such terminal (404).
    func resize(pid: Int32, id: String, _ request: T3Terminal.ResizeRequest) -> Result<Void, HostError>? {
        guard let terminal: Terminal = queue.sync(execute: { live(pid: pid, id: id) }) else { return nil }
        if let invalid = request.validate() { return .failure(.validation(invalid)) }
        let outcome: Result<Void, HostError>? = fdQueue.sync { () -> Result<Void, HostError>? in
            let fd = terminal.fd.fd
            guard fd >= 0 else { return nil }
            var size = winsize(ws_row: UInt16(request.rows), ws_col: UInt16(request.cols),
                               ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(fd, TIOCSWINSZ, &size) == 0 else {
                return .failure(.spawnFailed("resize failed (errno \(errno))"))
            }
            return .success(())
        }
        if case .success = outcome {
            queue.async {
                terminal.cols = request.cols
                terminal.rows = request.rows
            }
        }
        return outcome
    }

    // MARK: - Close

    /// `false` = no such terminal (404). Returns as soon as the shell has
    /// been signalled: `exited` and `closed` reach the streams when the
    /// child is actually reaped, up to `killGrace` later.
    func close(pid: Int32, id: String) -> Bool {
        queue.sync {
            guard let terminal = live(pid: pid, id: id) else { return false }
            beginClose(terminal, reason: nil)
            return true
        }
    }

    /// Every terminal, killed — the host dies with the app, and a leftover
    /// login shell holding a pty would outlive it otherwise.
    func closeAll() {
        queue.sync {
            for terminal in terminals.values where !terminal.finished {
                beginClose(terminal, reason: "app quit")
            }
        }
    }

    // MARK: - Host queue internals

    private func live(pid: Int32, id: String) -> Terminal? {
        guard let terminal = terminals[Key(pid: pid, id: id)], !terminal.finished else { return nil }
        return terminal
    }

    /// One readable event: one read, appended to the ring and fanned out.
    /// EOF — 0 bytes, or `EIO`, which is what Darwin gives a master whose
    /// slave side is gone — ends the terminal.
    private func readAvailable(_ terminal: Terminal) {
        guard !terminal.finished else { return }
        let fd = terminal.fd.fd
        guard fd >= 0 else { return }
        let n = terminal.readBuffer.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, buffer.count)
        }
        if n > 0 {
            let chunk = terminal.readBuffer.withUnsafeBytes { Data($0.prefix(n)) }
            if let emitted = terminal.ring.append(chunk) {
                fan(terminal, [.output(T3Terminal.OutputPayload(data: emitted.text,
                                                                sequence: emitted.sequence))])
            }
            return
        }
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        // EOF: stop reading first — a readable source over a dead pty fires
        // forever otherwise — then reap, or start the kill sequence for a
        // shell that closed its own fds without exiting.
        terminal.readSource?.cancel()
        terminal.readSource = nil
        if reap(terminal) {
            finish(terminal)
        } else if !terminal.closing {
            beginClose(terminal, reason: nil)
        }
    }

    /// `SIGHUP`, then `SIGKILL` after `killGrace` if the child is still
    /// there. Idempotent: a second DELETE while the first is in flight is
    /// a no-op.
    private func beginClose(_ terminal: Terminal, reason: String?) {
        guard !terminal.finished else { return }
        if terminal.closing {
            if terminal.closeReason == nil { terminal.closeReason = reason }
            return
        }
        terminal.closing = true
        terminal.closeReason = reason
        terminal.idleTimer?.cancel()
        terminal.idleTimer = nil
        kill(terminal.child, SIGHUP)
        if reap(terminal) {
            terminal.readSource?.cancel()
            terminal.readSource = nil
            finish(terminal)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.killGrace)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !terminal.finished else { return }
            // The shell ignored the hang-up (or a foreground job of its own
            // pgroup did): kill the whole process group, then reap — a
            // SIGKILLed child always comes back from waitpid.
            killpg(terminal.child, SIGKILL)
            kill(terminal.child, SIGKILL)
            terminal.readSource?.cancel()
            terminal.readSource = nil
            _ = self.reapBlocking(terminal)
            self.finish(terminal)
        }
        terminal.killTimer = timer
        timer.resume()
    }

    /// `exited` + `closed` to every stream, then the terminal is gone.
    private func finish(_ terminal: Terminal) {
        guard !terminal.finished else { return }
        terminal.finished = true
        terminal.killTimer?.cancel()
        terminal.killTimer = nil
        terminal.idleTimer?.cancel()
        terminal.idleTimer = nil
        terminal.readSource?.cancel()
        terminal.readSource = nil
        terminal.status = .exited
        var frames: [T3Terminal.Frame] = []
        if let tail = terminal.ring.flushPending() {
            frames.append(.output(T3Terminal.OutputPayload(data: tail.text, sequence: tail.sequence)))
        }
        frames.append(.exited(T3Terminal.ExitedPayload(exitCode: terminal.exitCode,
                                                       exitSignal: terminal.exitSignal)))
        frames.append(.closed(T3Terminal.ClosedPayload(reason: terminal.closeReason)))
        fan(terminal, frames)
        terminal.attachments.removeAll()
        // Only drop the map entry if it's still this terminal's — an
        // orphaned loser of the open race (#507 follow-up) must not wipe
        // out the winner that replaced it.
        let key = Key(pid: terminal.sessionPid, id: terminal.id)
        if terminals[key] === terminal { terminals[key] = nil }
    }

    /// Non-blocking reap: true once the child's status is known (or it was
    /// never ours to reap).
    private func reap(_ terminal: Terminal) -> Bool {
        var status: Int32 = 0
        let reaped = waitpid(terminal.child, &status, WNOHANG)
        if reaped == terminal.child { record(status, on: terminal); return true }
        return reaped < 0   // ECHILD: already gone, status unknowable
    }

    /// Only ever called right after `SIGKILL`, where waitpid returns at once.
    private func reapBlocking(_ terminal: Terminal) -> Bool {
        var status: Int32 = 0
        guard waitpid(terminal.child, &status, 0) == terminal.child else { return false }
        record(status, on: terminal)
        return true
    }

    /// `WIFEXITED`/`WEXITSTATUS` are C macros and don't reach Swift — the
    /// low seven bits are the signal that killed it, zero means it exited
    /// and the next byte up is its code.
    private func record(_ status: Int32, on terminal: Terminal) {
        if status & 0x7F == 0 {
            terminal.exitCode = Int((status >> 8) & 0xFF)
            terminal.exitSignal = nil
        } else {
            terminal.exitCode = nil
            terminal.exitSignal = Int(status & 0x7F)
        }
    }

    private func fan(_ terminal: Terminal, _ frames: [T3Terminal.Frame]) {
        guard !frames.isEmpty else { return }
        for sink in terminal.attachments.values { sink(frames) }
    }

    private func armIdleTimer(_ terminal: Terminal) {
        guard !terminal.finished, !terminal.closing else { return }
        terminal.idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Half a minute of leeway: this fires once every 30 minutes at
        // most, so the kernel may batch it as loosely as it likes.
        timer.schedule(deadline: .now() + Self.idleTimeout, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self, terminal.attachments.isEmpty else { return }
            self.beginClose(terminal, reason: "idle")
        }
        terminal.idleTimer = timer
        timer.resume()
    }

    // MARK: - Spawn

    /// `forkpty` + the user's login shell. Everything the child needs is a
    /// C pointer before the fork: between fork and exec only
    /// async-signal-safe calls are allowed — no Swift allocation, no
    /// Foundation, no logging.
    private static func spawn(cwd: String, cols: Int, rows: Int) throws -> (master: Int32, child: pid_t) {
        let environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // argv[0] with a leading dash is how a login shell is asked for.
        let argv0 = "-" + (shell as NSString).lastPathComponent
        var env = environment
        env["TERM"] = "xterm-256color"
        // A GUI app launched by launchd often has no locale at all, and
        // zsh's line editor then mangles every multi-byte character.
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        env["LINES"] = String(rows)
        env["COLUMNS"] = String(cols)

        let shellC = strdup(shell)
        let cwdC = strdup(cwd)
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        // Every fd this process holds — listeners, other masters — would be
        // inherited: forkpty gets no CLOEXEC help. 4096 is plenty and keeps
        // the loop bounded when RLIMIT_NOFILE is enormous.
        let fdLimit = min(getdtablesize(), 4096)
        defer {
            free(shellC)
            free(cwdC)
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var master: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 { throw HostError.spawnFailed("forkpty failed (errno \(errno))") }
        if child == 0 {
            // Child. forkpty already gave us the slave as 0/1/2, a new
            // session and the pty as the controlling terminal (job control
            // works, so ^C reaches the foreground job).
            var mask = sigset_t()
            sigemptyset(&mask)
            sigprocmask(SIG_SETMASK, &mask, nil)
            // Dispositions survive exec: libdispatch's ignored SIGPIPE would
            // break every `| head` the user types.
            for sig in [SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD] {
                Darwin.signal(sig, SIG_DFL)
            }
            var fd: Int32 = 3
            while fd < fdLimit {
                Darwin.close(fd)
                fd += 1
            }
            _ = chdir(cwdC)
            _ = execve(shellC, &argv, &envp)
            _exit(127)
        }
        // Parent: non-blocking so a readable event that races the child's
        // exit can never park the host queue inside read(2).
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        return (master, child)
    }
}
