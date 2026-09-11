import Foundation

#if !os(iOS)
/// Assembles NDJSON lines from pipe chunks and remembers whether an
/// engine-refused event went by. Mutated from the pipe's readability
/// handler and read from the termination handler — two GCD threads, hence
/// the lock (the handlers themselves are each serial).
private final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var refused = false

    func feed(_ chunk: Data, onLine: (EventLine) -> Void) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            let line = EventFeed.decode(line: String(decoding: lineData, as: UTF8.self))
            if case .event(let e) = line, e.kind == "engine-refused" { refused = true }
            onLine(line)
        }
    }

    var sawRefusal: Bool { lock.lock(); defer { lock.unlock() }; return refused }

    private var eof = false, exited = false, finished = false
    /// True exactly once, when the pipe has drained AND the child has
    /// exited — the exit alone raced the last line (a refusal printed
    /// right before `exit 1` read as a crash under load) — or on
    /// `force`, for a grandchild that inherited the pipe and keeps it open.
    func done(eof sawEOF: Bool = false, exit sawExit: Bool = false, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if sawEOF { eof = true }
        if sawExit { exited = true }
        guard exited, eof || force, !finished else { return false }
        finished = true
        return true
    }
}

/// Supervises an engine's auto-switch daemon, `swapd auto --json` under
/// `SWAPD_SUPERVISED=1` (spec §2 — the app hosts no engine of its own;
/// other engines, like the CLIProxy, run as their own service and need
/// no supervisor).
///
/// Restarts on exit with SupervisorBackoff. Lines stream to `onLine` on an
/// arbitrary thread; the UI layer marshals. `engine-refused` means another
/// host (a stray `swapd auto`) already owns the store's engine mutex —
/// surfaced as a state, not retried hot, since the refusal is instant and
/// hammering it would spin.
public actor EngineSupervisor {
    public enum State: Sendable, Equatable {
        case stopped
        case running(pid: Int32)
        case backingOff(seconds: Double)
        case refused          // another engine holds the mutex
        case schemaMismatch(Int)
    }

    private let binaryPath: String
    private let arguments: [String]
    private let environmentFlag: String
    private let onLine: @Sendable (EventLine) -> Void
    private let onState: @Sendable (State) -> Void
    private var process: Process?
    private var backoff = SupervisorBackoff()
    private var stopping = false
    /// When our own child last exited: a refusal right after that is the
    /// dying child's mutex not yet released, not a foreign holder.
    private var lastOwnExit: Date = .distantPast

    /// `environmentFlag` is set to 1 in the child's environment so the
    /// daemon knows it is supervised (it exits on stdin EOF).
    public init(
        binaryPath: String,
        arguments: [String] = ["auto", "--json"],
        environmentFlag: String = "SWAPD_SUPERVISED",
        onLine: @escaping @Sendable (EventLine) -> Void,
        onState: @escaping @Sendable (State) -> Void
    ) {
        self.binaryPath = binaryPath
        self.arguments = arguments
        self.environmentFlag = environmentFlag
        self.onLine = onLine
        self.onState = onState
    }

    public func start() {
        stopping = false
        spawn()
    }

    public func stop() {
        stopping = true
        process?.terminate()
        process = nil
        onState(.stopped)
    }

    private func spawn() {
        guard !stopping else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = arguments
        // The supervised-engine contract: the child watches its stdin pipe
        // and exits on EOF, but only under this flag (never in tests, cron
        // pipes, or an interactive terminal).
        var env = ProcessInfo.processInfo.environment
        env[environmentFlag] = "1"
        p.environment = env
        p.standardInput = Pipe()   // held open for the child's lifetime
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        let assembler = LineAssembler()
        let onLine = self.onLine
        let started = Date()
        let finish: @Sendable () -> Void = { [weak self] in
            Task { [weak self] in
                await self?.childExited(
                    cleanSeconds: Date().timeIntervalSince(started),
                    refused: assembler.sawRefusal
                )
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {   // EOF
                handle.readabilityHandler = nil
                if assembler.done(eof: true) { finish() }
                return
            }
            assembler.feed(chunk, onLine: onLine)
        }
        p.terminationHandler = { _ in
            if assembler.done(exit: true) { finish(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if assembler.done(force: true) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    finish()
                }
            }
        }

        do {
            try p.run()
            process = p
            onState(.running(pid: p.processIdentifier))
        } catch {
            onState(.backingOff(seconds: scheduleRespawn()))
        }
    }

    private func childExited(cleanSeconds: Double, refused: Bool) {
        process = nil
        guard !stopping else { return }
        if refused {
            // Instant exit by design — but not terminal. The other holder
            // (a stray `swapd auto`, an orphan from a killed app) can go
            // away, and the 2026-08-28 orphan did exactly that: the fresh
            // app sat refused forever while nobody held a live engine. A
            // slow paced retry (60s) self-heals without spinning on the
            // instant refusal. Within seconds of our OWN child's exit the
            // holder is that child still letting go of the mutex (seen
            // 2026-09-03 restarting the engine for an upgrade: a minute
            // of "held elsewhere" for a lock that freed in under a
            // second) — retry fast then.
            let ownHandoff = Date().timeIntervalSince(lastOwnExit) < 10
            onState(.refused)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: (ownHandoff ? 3 : 60) * 1_000_000_000)
                await self?.spawn()
            }
            return
        }
        lastOwnExit = Date()
        backoff.noteExit(afterCleanSeconds: cleanSeconds)
        onState(.backingOff(seconds: scheduleRespawn()))
    }

    private func scheduleRespawn() -> Double {
        let delay = backoff.nextDelay()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.spawn()
        }
        return delay
    }
}
#endif
