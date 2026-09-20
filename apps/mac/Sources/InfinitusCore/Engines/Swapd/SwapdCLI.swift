import Foundation

#if !os(iOS)
/// Where the `swapd` binary lives. Checked in order; first hit wins.
public enum SwapdLocator {
    public static func defaultCandidates(
        home: String = NSHomeDirectory(),
        bundledExecutableDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path
    ) -> [String] {
        var paths = [
            "/opt/homebrew/bin/swapd",
            "/usr/local/bin/swapd",
            "\(home)/.cargo/bin/swapd",   // `cargo install --path .`
            "\(home)/.local/bin/swapd",
        ]
        if let bundledExecutableDirectory {
            paths.append("\(bundledExecutableDirectory)/swapd")
        }
        return paths
    }

    public static func locate(
        candidates: [String]? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        // Dev/e2e override: INFINITUS_SWAPD_CLI=/path pins the binary; the
        // empty string simulates a machine without the engine.
        if candidates == nil,
           let forced = ProcessInfo.processInfo.environment["INFINITUS_SWAPD_CLI"] {
            return forced.isEmpty ? nil : (exists(forced) ? forced : nil)
        }
        return (candidates ?? defaultCandidates()).first(where: exists)
    }
}

/// A failed engine run: the engine's own message (SwapdCLI.failure).
public struct CLIError: Error, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Thin async wrapper over Process for one-shot `swapd … --json` commands
/// (the engine's own daemon, `swapd auto --json`, is a supervisor's job).
///
/// Every verb runs with `--json`, so the engine answers with exactly one
/// JSON object on stdout — including its failures: a refusal is the error
/// envelope on STDOUT plus a non-zero exit (swapd `src/output.rs`), which
/// is why a failed run reports `error.message` and not "exited 1". The one
/// exception is `add-oauth`, which answers in two lines (`beginOAuthAdd`).
public struct SwapdCLI: Sendable {
    public let binaryPath: String

    public init(binaryPath: String) { self.binaryPath = binaryPath }

    /// The engine's id for a provider. `.other` has no id to send back —
    /// it is what an id THIS build doesn't know decoded to, so a write
    /// against it is refused rather than guessed at.
    public static func providerID(_ provider: Provider) throws -> String {
        guard provider != .other else {
            throw EngineError.unsupported("that provider (swapd calls it something this build doesn't know)")
        }
        return provider.rawValue
    }

    /// `stdin` feeds the child's standard input and closes it — the channel
    /// secrets travel on (`swapd add-token -`), so a token never appears in
    /// an argv another process could read out of `ps`.
    /// `environment` replaces the child's environment when given.
    @discardableResult
    public func run(_ arguments: [String], stdin: String? = nil,
                    environment: [String: String]? = nil) async throws -> Data {
        // The blocking Process dance lives on a GCD thread, bridged by a
        // continuation — inline in an async function it blocked its executor
        // on macOS 26 (the fact CswapCLI.run records).
        let binaryPath = self.binaryPath
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let out = Pipe(), errors = Pipe()
                process.standardOutput = out
                process.standardError = errors
                if let stdin {
                    let input = Pipe()
                    process.standardInput = input
                    input.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                    input.fileHandleForWriting.closeFile()
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                // Drain BOTH before waiting: either pipe filling up would
                // deadlock the child against an unread reader.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    cont.resume(throwing: CLIError(message: Self.failure(
                        arguments: arguments, stdout: data, stderr: errorData,
                        status: process.terminationStatus)))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    /// What a failed run says: the engine's own message when it printed an
    /// error envelope, its stderr line when it spoke human, and only then a
    /// bare exit code.
    static func failure(arguments: [String], stdout: Data, stderr: Data, status: Int32) -> String {
        if let envelope = try? JSONDecoder().decode(SwapdErrorEnvelope.self, from: stdout) {
            return envelope.error.message
        }
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "swapd \(arguments.joined(separator: " ")) exited \(status)"
        }
        let last = text.split(separator: "\n").last.map(String.init) ?? text
        // swapd prefixes its human errors with "error: "; don't say it twice.
        return last.hasPrefix("error: ") ? String(last.dropFirst("error: ".count)) : last
    }

    /// Every list-shaped reply (list, refresh, hold, alias, prefer, reorder)
    /// decodes here, so the schema guard runs on all of them: swapd's
    /// version is additive-stable, and a BUMP means a shape this build
    /// cannot read — refused loudly instead of rendered wrong.
    func decodeList(_ data: Data) throws -> SwapdList {
        let list = try JSONDecoder().decode(SwapdList.self, from: data)
        guard list.schemaVersion <= SwapdMapping.schemaVersion else {
            throw EngineError.unsupported(
                "swapd speaks schema v\(list.schemaVersion); this build reads v\(SwapdMapping.schemaVersion)")
        }
        return list
    }

    private func arguments(_ verb: [String], provider: Provider?) throws -> [String] {
        var out = verb
        if let provider { out += ["--provider", try Self.providerID(provider)] }
        return out + ["--json"]
    }

    private func listVerb(_ verb: [String], provider: Provider?,
                          stdin: String? = nil) async throws -> SwapdList {
        try decodeList(await run(try arguments(verb, provider: provider), stdin: stdin))
    }

    /// Every provider swapd holds, in one call. No `--provider`: the app
    /// renders one fleet per provider that has accounts.
    public func list() async throws -> SwapdList {
        try await listVerb(["list"], provider: nil)
    }

    /// The provider's switch log, newest last; the view takes the tail.
    public func history(provider: Provider, limit: Int? = nil) async throws -> SwapdHistory {
        try JSONDecoder().decode(SwapdHistory.self, from: await historyData(provider: provider, limit: limit))
    }

    /// The engine's own history JSON, untouched — the `history` control
    /// verb hands it on as-is (#779), so a new field reaches the fork
    /// without a Mac release in between.
    public func historyData(provider: Provider, limit: Int? = nil) async throws -> Data {
        try await run(["history", "--json", "--provider", Self.providerID(provider)]
                      + (limit.map { ["--limit", String($0)] } ?? []))
    }

    /// Force one usage fetch past the engine's serve floor (`--slot n`), or
    /// every stale slot without one, then answer with the fresh list.
    public func refresh(provider: Provider, slot: Int? = nil) async throws -> SwapdList {
        try await listVerb(["refresh"] + (slot.map { ["--slot", String($0)] } ?? []),
                           provider: provider)
    }

    @discardableResult
    public func switchTo(provider: Provider, slot: Int) async throws -> Data {
        try await run(try arguments(["switch", String(slot)], provider: provider))
    }

    @discardableResult
    public func rotate(provider: Provider) async throws -> Data {
        try await run(try arguments(["rotate"], provider: provider))
    }

    public func reorder(provider: Provider, _ slots: [Int]) async throws -> SwapdList {
        try await listVerb(["reorder"] + slots.map(String.init), provider: provider)
    }

    /// Out of the rotation (`hold`) or back into it (`unhold`).
    public func setHold(provider: Provider, slot: Int, held: Bool) async throws -> SwapdList {
        try await listVerb([held ? "hold" : "unhold", String(slot)], provider: provider)
    }

    /// Star/unstar: the engine's own pick-first knob, per slot.
    public func setPreferred(provider: Provider, slot: Int, _ on: Bool) async throws -> SwapdList {
        try await listVerb(["prefer", String(slot), on ? "on" : "off"], provider: provider)
    }

    /// Keep-warm on/off: the daemon ignites the slot whenever its 5h window
    /// has gone cold (swapd 0.3).
    public func setAutoIgnite(provider: Provider, slot: Int, _ on: Bool) async throws -> SwapdList {
        try await listVerb(["auto-ignite", String(slot), on ? "on" : "off"], provider: provider)
    }

    /// Set (non-empty) or clear (empty) a slot's display alias.
    public func setAlias(provider: Provider, slot: Int, _ name: String) async throws -> SwapdList {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return try await listVerb(
            ["alias", String(slot)] + (trimmed.isEmpty ? ["--unset"] : [trimmed]),
            provider: provider)
    }

    /// One cheapest request under the slot's own login so its window starts
    /// now; the live login is untouched. The reply is a forced-fetch list.
    public func ignite(provider: Provider, slot: Int) async throws -> SwapdList {
        try await listVerb(["ignite", String(slot)], provider: provider)
    }

    /// Capture the login the provider's CLI is holding right now.
    @discardableResult
    public func addCurrent(provider: Provider) async throws -> Data {
        try await run(try arguments(["add"], provider: provider))
    }

    /// Register a setup token or API key — over stdin, never argv.
    @discardableResult
    public func addToken(provider: Provider, _ token: String) async throws -> Data {
        try await run(try arguments(["add-token", "-"], provider: provider), stdin: token)
    }

    /// `swapd add-oauth`: the engine holds the OAuth client, listens on the
    /// loopback port the redirect names, and redeems the code itself — no
    /// paste. It prints two lines: `{url, port}` the moment its listener is
    /// up, then the `add` envelope once the credential is stored. This
    /// returns after the first line, with the process still running; the
    /// handle's `wait()` takes the second.
    public func beginOAuthAdd(provider: Provider) async throws -> SwapdOAuthRun {
        let arguments = try arguments(["add-oauth"], provider: provider)
        let run = SwapdOAuthRun(binaryPath: binaryPath, arguments: arguments)
        let first = try await run.launch()
        // A refusal before the URL (the port already held, no browser
        // sign-in for this provider) is the error envelope on the first
        // line and an exit — swapd's own words, the way `run` reports them.
        guard let line = first, let start = try? JSONDecoder().decode(SwapdOAuthStart.self, from: line),
              let url = URL(string: start.url) else {
            // A first line that is not a refusal but not a usable URL either
            // leaves the engine listening; end it rather than wait 5 min.
            run.terminate()
            let (stdout, stderr, status) = await run.finished()
            throw CLIError(message: Self.failure(
                arguments: arguments, stdout: (first ?? Data()) + stdout, stderr: stderr, status: status))
        }
        run.url = url
        return run
    }

    /// Forget a slot. `--yes` is the confirmation; without it swapd refuses,
    /// which is what makes the caller's own confirm the only way here.
    @discardableResult
    public func removeAccount(provider: Provider, slot: Int) async throws -> Data {
        try await run(try arguments(["remove", String(slot), "--yes"], provider: provider))
    }
}

/// `add-oauth`'s first line: what to open, and the loopback port the
/// redirect lands on.
struct SwapdOAuthStart: Decodable {
    let schemaVersion: Int
    let url: String
    let port: Int
}

/// One `swapd add-oauth` in flight: the process holding the loopback
/// listener between the URL line and the redirect. Cancelling the task
/// that waits on it kills the process, which frees the port for the next
/// attempt — a listener left behind would refuse it.
public final class SwapdOAuthRun: @unchecked Sendable {
    /// The page to open, once the first line has been read.
    public internal(set) var url: URL?
    private let binaryPath: String
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var outcome: (stdout: Data, stderr: Data, status: Int32)?
    private var waiters: [CheckedContinuation<(stdout: Data, stderr: Data, status: Int32), Never>] = []

    init(binaryPath: String, arguments: [String]) {
        self.binaryPath = binaryPath
        self.arguments = arguments
    }

    /// Spawns the engine and answers its first stdout line — nil when it
    /// closed stdout before writing one. The whole Process lives on the one
    /// GCD thread this starts (`SwapdCLI.run`'s rule: `waitUntilExit` off
    /// the launching thread never returned, 2026-09-20): after the first
    /// line it stays to drain both pipes and take the exit, which settles
    /// `finished()`.
    func launch() async throws -> Data? {
        let binaryPath = self.binaryPath, arguments = self.arguments
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments
                let out = Pipe(), errors = Pipe()
                process.standardOutput = out
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                self.lock.lock()
                self.process = process
                self.lock.unlock()

                let fh = out.fileHandleForReading
                var buffer = Data()
                var first: Data?
                while true {
                    let chunk = fh.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        first = Data(buffer[..<newline])
                        buffer = Data(buffer[buffer.index(after: newline)...])
                        break
                    }
                }
                cont.resume(returning: first)

                // Drain BOTH before waiting: either pipe filling up would
                // deadlock the child against an unread reader.
                let data = buffer + fh.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                self.settle((data, errorData, process.terminationStatus))
            }
        }
    }

    private func settle(_ result: (stdout: Data, stderr: Data, status: Int32)) {
        lock.lock()
        outcome = result
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    /// The rest of both pipes and the exit status, once the process ends.
    func finished() async -> (stdout: Data, stderr: Data, status: Int32) {
        await withCheckedContinuation { cont in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(returning: outcome)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    /// Ends the engine early; `wait`/`finished` then report its exit.
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { process.terminate() }
    }

    /// Blocks until the redirect has landed and the credential is stored
    /// (the second line), or the engine gave up. Cancelling the waiting
    /// task terminates the engine, which then reports a non-zero exit.
    @discardableResult
    public func wait() async throws -> Data {
        try await withTaskCancellationHandler {
            let (stdout, stderr, status) = await finished()
            guard status == 0 else {
                throw CLIError(message: SwapdCLI.failure(
                    arguments: arguments, stdout: stdout, stderr: stderr, status: status))
            }
            return stdout
        } onCancel: {
            terminate()
        }
    }
}
#endif
