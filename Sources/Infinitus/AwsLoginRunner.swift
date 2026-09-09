import Foundation
import InfinitusCore

/// Runs the AWS CLI sign-in for a profile and reports its prompts
/// (AwsLogin.swift) — and gcloud's (#367, GcloudLogin.swift): every
/// slot is keyed by (provider, profile), `AwsLogin.runKey`. One process
/// per slot at a time; the CLI runs
/// under `script` so its prompts behave as on a terminal, with the code
/// written to its stdin and nothing else. Output is parsed for the URL /
/// code / success line only — never logged whole.
actor AwsLoginRunner {
    private struct Run {
        let process: Process
        let stdin: Pipe
        var output = ""
        var state: AwsLogin.State
    }

    /// Keyed by `AwsLogin.runKey` (provider + profile).
    private var runs: [String: Run] = [:]
    private var finished: [String: AwsLogin.State] = [:]
    /// Every CLI still running, reachable without hopping onto the actor:
    /// app quit is synchronous, and a CLI left behind keeps its localhost
    /// listener (and a half-done sign-in) alive (2026-09-03).
    private let live = LiveProcesses()
    private final class LiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        func add(_ p: Process) { lock.lock(); processes.append(p); lock.unlock() }
        func remove(_ p: Process) { lock.lock(); processes.removeAll { $0 === p }; lock.unlock() }
        func killAll() {
            lock.lock(); let all = processes; processes = []; lock.unlock()
            for p in all where p.isRunning { p.terminate() }
        }
    }

    /// Terminates every login in flight; for app quit.
    nonisolated func killAll() { live.killAll() }
    private let onChange: @Sendable ([AwsLogin.State]) -> Void
    /// Called once per login that ends in `.done`.
    private let onDone: @Sendable (AwsLogin.State) -> Void
    /// Where outcomes survive a relaunch (`AwsLogin.Ledger`); nil keeps
    /// them in memory only (tests, the playground).
    private let ledgerURL: URL?

    init(onChange: @escaping @Sendable ([AwsLogin.State]) -> Void,
         onDone: @escaping @Sendable (AwsLogin.State) -> Void,
         ledgerURL: URL? = nil) {
        self.onChange = onChange
        self.onDone = onDone
        self.ledgerURL = ledgerURL
        if let ledgerURL, let data = try? Data(contentsOf: ledgerURL) {
            for state in AwsLogin.Ledger.decode(data) { finished[state.runKey] = state }
        }
        if !finished.isEmpty { onChange(Array(finished.values)) }
        Task.detached(priority: .utility) { Self.sweepOrphans() }
    }

    /// Kills the login wrappers an earlier instance left behind (#274):
    /// each holds the cred broker's refresh lock, so every caller on
    /// that profile fails until it dies. Once, at launch, off the actor.
    nonisolated static func sweepOrphans() {
        guard let ps = try? Subprocess.run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return }
        let markers = AwsLogin.Provider.allCases.compactMap { provider in
            // `auth ` covers `auth login` and `auth application-default login`.
            cli(provider).map { "script -q /dev/null \($0) " + (provider == .aws ? "login" : "auth ") }
        }
        for pid in markers.flatMap({ AwsLogin.orphanLogins(ps: ps, marker: $0) }) {
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }

    static let awsCandidates = [
        "/opt/homebrew/bin/aws", "/usr/local/bin/aws",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/aws").path,
        "/usr/bin/aws",
    ]
    /// The SDK's installer unpacks `google-cloud-sdk/` wherever the user
    /// ran it — home, or one folder down (`~/death/google-cloud-sdk`).
    static let gcloudCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let oneDown = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).sorted()
            .map { home.appendingPathComponent($0).appendingPathComponent("google-cloud-sdk/bin/gcloud").path }
        return ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
                "/opt/homebrew/share/google-cloud-sdk/bin/gcloud", "/usr/local/share/google-cloud-sdk/bin/gcloud",
                home.appendingPathComponent("google-cloud-sdk/bin/gcloud").path] + oneDown
    }()

    /// The CLI for a provider: the e2e stub (`INFINITUS_AWS_CLI` /
    /// `INFINITUS_GCLOUD_CLI`), a known install spot, else wherever the
    /// user's login shell finds it (the SDK's installer drops it in a
    /// folder of the user's choosing and only edits the shell rc). The
    /// shell lookup runs once.
    nonisolated static func cli(_ provider: AwsLogin.Provider) -> String? {
        if let stub = ProcessInfo.processInfo.environment[provider.cliOverrideEnv] { return stub }
        if let found = Subprocess.find(provider == .aws ? awsCandidates : gcloudCandidates) { return found }
        return shellPath.value(provider.cliName)
    }
    private static let shellPath = ShellPathCache()
    private final class ShellPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: String?] = [:]
        func value(_ name: String) -> String? {
            lock.lock(); if let hit = known[name] { lock.unlock(); return hit }; lock.unlock()
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // Interactive AND login: the SDK installer puts its PATH line
            // in .zshrc, which a plain login shell never reads. The last
            // line: a chatty rc file prints before the answer; the run's
            // timeout bounds an rc that never returns.
            let out = (try? Subprocess.run(shell, ["-lic", "command -v \(name)"]))?
                .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let path = (out?.hasPrefix("/") == true && FileManager.default.isExecutableFile(atPath: out!)) ? out : nil
            lock.lock(); known[name] = path; lock.unlock()
            return path
        }
    }

    func states() -> [AwsLogin.State] {
        Array(runs.values.map(\.state)) + finished.values.filter { s in runs[s.runKey] == nil }
    }

    func state(provider: AwsLogin.Provider = .aws, profile: String) -> AwsLogin.State? {
        let key = AwsLogin.runKey(provider: provider, profile: profile)
        return runs[key]?.state ?? finished[key]
    }

    /// Starts the flow, or returns the login already in flight for that
    /// profile. `pid` is the session to nudge when it lands.
    func start(provider: AwsLogin.Provider = .aws, profile: String, flow: AwsLogin.Flow, pid: Int?) -> AwsLogin.Reply {
        let key = AwsLogin.runKey(provider: provider, profile: profile)
        if let run = runs[key] {
            // Same flow: the login already in flight. Another flow (the
            // phone's "Use a code" after the relay page couldn't do a
            // passkey, 2026-09-03): drop the old CLI and start over.
            if run.state.flow == flow { return AwsLogin.Reply(ok: true, state: run.state) }
            runs[key] = nil
            run.process.terminationHandler = nil
            run.process.terminate()
            live.remove(run.process)
        }
        guard let cli = Self.cli(provider) else {
            return AwsLogin.Reply(ok: false, error: "\(provider.cliName) CLI not found")
        }
        let process = Process()
        // `script -q /dev/null <cmd>`: a pty for the CLI, so its prompt
        // reads the pasted code the way it would from a terminal.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", cli] + provider.arguments(profile: profile, flow: flow)
        var env = ProcessInfo.processInfo.environment
        env["AWS_PAGER"] = ""
        env["NO_COLOR"] = "1"
        // Relay: the CLI must not open THIS Mac's browser — the phone's
        // web view is the browser. Python's webbrowser honors BROWSER.
        if flow == .relay { env["BROWSER"] = "/usr/bin/true" }
        process.environment = env
        let stdin = Pipe(), out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = out
        let state = AwsLogin.State(profile: profile, flow: flow, startedAt: Date().timeIntervalSince1970, pid: pid,
                                   provider: provider == .aws ? nil : provider)
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { await self.consume(key: key, process: process, chunk: chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            Task { await self.ended(key: key, process: proc, status: proc.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            return AwsLogin.Reply(ok: false, error: "could not start \(provider.cliName): \(error.localizedDescription)")
        }
        live.add(process)
        runs[key] = Run(process: process, stdin: stdin, state: state)
        finished[key] = nil
        publish()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AwsLogin.timeout))
            await self?.expire(key: key)
        }
        return AwsLogin.Reply(ok: true, state: state)
    }

    /// Writes the pasted code to the waiting `--remote` flow.
    func submit(provider: AwsLogin.Provider = .aws, profile: String, code: String) -> AwsLogin.Reply {
        let key = AwsLogin.runKey(provider: provider, profile: profile)
        guard var run = runs[key] else {
            return AwsLogin.Reply(ok: false, state: finished[key], error: "no login in flight for \(profile)")
        }
        guard run.state.flow == .remote else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "this flow takes no code")
        }
        guard AwsLogin.isValidCode(code) else { return AwsLogin.Reply(ok: false, state: run.state, error: "invalid code") }
        guard Self.write(code + "\n", to: run) else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "the \(provider.cliName) CLI is no longer waiting for a code")
        }
        run.state.phase = .waitingForBrowser
        run.state.message = "code submitted"
        runs[key] = run
        publish()
        return AwsLogin.Reply(ok: true, state: run.state)
    }

    /// A line to the CLI's stdin, or false when the CLI is gone: the
    /// non-throwing `write(_:)` raises an uncaught Foundation exception
    /// on a broken pipe, which took the whole app down in CI when the
    /// stub `aws` exited before the runner answered its prompt (#39's
    /// e2e run, 2026-09-04). `ended` then reports the login as failed.
    private static func write(_ text: String, to run: Run) -> Bool {
        guard run.process.isRunning else { return false }
        do {
            try run.stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    /// Replays the redirect the phone intercepted against the CLI's own
    /// localhost listener; the CLI then finishes the exchange itself.
    func relay(profile: String, url: String) async -> AwsLogin.Reply {
        let key = AwsLogin.runKey(provider: .aws, profile: profile)
        guard var run = runs[key] else {
            return AwsLogin.Reply(ok: false, state: finished[key], error: "no login in flight for \(profile)")
        }
        guard run.state.flow == .relay || run.state.flow == .local, let port = run.state.callbackPort else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "this flow takes no callback")
        }
        guard AwsLogin.isValidCallback(url, port: port), let target = URL(string: url) else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "not the CLI's callback")
        }
        do {
            _ = try await URLSession.shared.data(from: target)
        } catch {
            return AwsLogin.Reply(ok: false, state: run.state, error: "callback not accepted: \(error.localizedDescription)")
        }
        run.state.message = "callback relayed"
        runs[key] = run
        publish()
        return AwsLogin.Reply(ok: true, state: run.state)
    }

    private func consume(key: String, process: Process, chunk: String) {
        // A replaced CLI's last output must not land on its successor.
        guard var run = runs[key], run.process === process else { return }
        run.output += chunk
        if run.output.count > 64 * 1024 { run.output = String(run.output.suffix(32 * 1024)) }
        let prompt = run.state.providerOrAws.parseOutput(run.output)
        if let url = prompt.url, run.state.url == nil {
            run.state.url = url
            run.state.phase = .waitingForBrowser
            if run.state.flow == .relay || run.state.flow == .local {
                run.state.callbackPort = AwsLogin.callbackPort(inURL: url)
            }
        }
        if let code = prompt.userCode { run.state.userCode = code }
        if prompt.wantsCode, run.state.message != "code submitted" { run.state.phase = .waitingForCode }
        if prompt.succeeded { run.state.phase = .done }
        if let refusal = prompt.rebindRefusal, run.state.phase != .failed {
            // The verdict first, then the answer: a CLI that already gave
            // up on its prompt makes the write fail, and the verdict must
            // not depend on it.
            run.state.phase = .failed
            run.state.message = refusal
            _ = Self.write("n\n", to: run)
        }
        runs[key] = run
        publish()
    }

    private func ended(key: String, process: Process, status: Int32) {
        live.remove(process)
        guard var run = runs[key], run.process === process else { return }
        let prompt = run.state.providerOrAws.parseOutput(run.output)
        if status == 0 || prompt.succeeded {
            run.state.phase = .done
            run.state.message = "signed in"
        } else if run.state.phase == .failed, run.state.message != nil {
            // Already explained (the declined rebind); the CLI's own last
            // line after a "n" is just its EOF/expired complaint.
        } else {
            run.state.phase = .failed
            let last = run.output.replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("https://") && !$0.lowercased().hasPrefix("enter the authorization") }
            run.state.message = last.map { String($0.prefix(160)) } ?? "\(run.state.providerOrAws.cliName) exited \(status)"
        }
        try? run.stdin.fileHandleForWriting.close()
        runs[key] = nil
        finished[key] = run.state
        publish()
        if run.state.phase == .done { onDone(run.state) }
    }

    private func expire(key: String) {
        guard let run = runs[key], run.process.isRunning else { return }
        run.process.terminate()
        // `script` can sit on its pty past SIGTERM; SIGKILL after a grace
        // (a wrapper found alive 1d 21h after its 600 s, #274).
        let process = run.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Records a profile as signed in without a run of its own — its need
    /// was met by another profile's login — so the need clears and the
    /// sessions on it get their nudge.
    func markDone(provider: AwsLogin.Provider = .aws, profile: String, via: String) {
        let key = AwsLogin.runKey(provider: provider, profile: profile)
        guard runs[key] == nil else { return }
        finished[key] = AwsLogin.State(profile: profile, flow: .local, phase: .done,
                                       message: "signed in with \(via)",
                                       startedAt: Date().timeIntervalSince1970, pid: nil,
                                       provider: provider == .aws ? nil : provider)
        publish()
    }

    /// Whether the profile's credentials work right now: `aws sts
    /// get-caller-identity` / `gcloud auth print-access-token`, nothing
    /// interactive (no browser, no stdin, no prompts), by exit status
    /// only — gcloud's prints the token, so stdout stays on the null
    /// device. 30 s at most. Off the actor — a broker profile can take
    /// a while.
    nonisolated static func signedIn(provider: AwsLogin.Provider = .aws, profile: String) async -> Bool {
        guard let cli = cli(provider) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = provider == .aws ? ["sts", "get-caller-identity", "--profile", profile]
                                             : GcloudLogin.probeArguments(profile: profile)
        var env = ProcessInfo.processInfo.environment
        env["AWS_PAGER"] = ""
        env["BROWSER"] = "/usr/bin/true"
        env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        env["NO_GCE_CHECK"] = "true"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                if process.isRunning { process.terminate() }
                // A broker that ignores SIGTERM would hold the continuation
                // forever; SIGKILL is what actually fires terminationHandler.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    /// Drops a finished entry (after the session has moved on).
    /// #275: a login the session started itself is still waiting on its
    /// callback — its Bash sits there until the tool timeout, and the
    /// continue nudge only drains after that. Any callback ends the wait
    /// (the CLI checks the OAuth state and exits), so once the sign-in
    /// landed, poke every such listener under the session and let its
    /// command return now. Returns how many answered.
    nonisolated static func releaseSessionLogins(profile: String, sessionPid: Int) async -> Int {
        guard let ps = try? Subprocess.run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return 0 }
        let pids = AwsLogin.sessionLogins(ps: ps, sessionPid: Int32(sessionPid), profile: profile)
        // lsof exits 1 when nothing is listed — a throw is "no listener".
        guard !pids.isEmpty, let lsof = try? Subprocess.run("/usr/sbin/lsof", [
            "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ","), "-Fpn",
        ]) else { return 0 }
        var released = 0
        for port in AwsLogin.listeningPorts(lsof: lsof).values.flatMap({ $0 }) {
            guard let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=infinitus&state=infinitus") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if (try? await URLSession.shared.data(for: request)) != nil { released += 1 }
        }
        return released
    }

    func forget(provider: AwsLogin.Provider = .aws, profile: String) {
        finished[AwsLogin.runKey(provider: provider, profile: profile)] = nil
        publish()
    }

    private func publish() {
        onChange(states())
        if let ledgerURL {
            let snapshot = AwsLogin.Ledger.snapshot(running: runs.values.map(\.state),
                                                    finished: Array(finished.values))
            try? FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? AwsLogin.Ledger.encode(snapshot).write(to: ledgerURL, options: .atomic)
        }
    }
}
