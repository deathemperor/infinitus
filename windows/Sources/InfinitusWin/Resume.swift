import Foundation
import InfinitusCore

/// W15: the manual half of the resume-nudge mechanism on Windows
/// (docs/plan-windows/06-nudge-resume.md). A session Claude Code stopped
/// at a usage limit is nudged back to work with a peer message — the same
/// `ResumeCoordinator` the Mac runs, with the named pipe standing in for
/// the unix socket and NO pty fallback: Windows Terminal exposes no
/// send-keys, so a session whose pipe is gone is simply unreachable.
///
/// Manual on purpose. The Mac decides WHEN to nudge from the engine's
/// quota signal (`ResumeGate`); this box runs no engine, so it can't tell
/// "quota is back" from "still limited" — it would nudge into the same
/// wall. The operator (or the phone) picks the moment; this delivers it.
enum Resume {
    /// Sessions whose transcript tail ends in a limit stop.
    static func stopped(claudeDir: URL) -> [StoppedSession] {
        Transcript.findStopped(sessions: ClaudeSessions.list(claudeDir: claudeDir),
                               claudeDir: claudeDir)
    }

    /// The coordinator wired to the pipe. `hosts: []` is the whole reason
    /// this is safe on Windows: with no pty host the coordinator's
    /// terminal fallback can't fire, so every delivery is a peer write or
    /// nothing.
    static func coordinator(claudeDir: URL) -> ResumeCoordinator {
        var coordinator = ResumeCoordinator(hosts: [], claudeDir: claudeDir)
        coordinator.socketSend = { session, text in
            guard !session.socketPath.isEmpty else { return false }
            let record = ClaudeSessions.list(claudeDir: claudeDir)
                .first { $0.pid == session.pid }
            guard let record else { return false }
            return NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
        }
        return coordinator
    }
}

/// `infinitus-win resume [--pid N] [--dry-run] [--explain] [--claude-dir P]`
/// — nudge every limit-stopped session, or just one. `--dry-run` lists
/// what it would nudge and writes nothing; `--explain` shows what the
/// AUTOMATIC pass (`serve --auto-resume`) would decide right now and why,
/// which is the only way to see the gate's reasoning without waiting for
/// a tick.
func resume(_ args: [String]) -> Int32 {
    var pid: Int32?, dryRun = false, explain = false
    var claudeDir = ClaudeSessions.configHome()
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--pid":
            index += 1
            guard index < args.endIndex, let parsed = Int32(args[index]) else {
                fail("resume: --pid needs a number")
            }
            pid = parsed
        case "--claude-dir":
            index += 1
            guard index < args.endIndex else { fail("resume: --claude-dir needs a path") }
            claudeDir = URL(fileURLWithPath: args[index])
        case "--dry-run": dryRun = true
        case "--explain": explain = true
        default:
            fail("resume: unknown flag \(args[index])")
        }
        index += 1
    }

    if explain {
        // The automatic pass's own decision, printed. Writes nothing.
        //
        // `INFINITUS_ACCOUNTS_JSON=<path>` substitutes a file for the
        // engine's `list --json`, so the gate can be driven over a known
        // account state. A test seam: `Process.run()` goes through
        // CreateProcess and cannot launch a `.cmd`, so a stub engine
        // script is located fine and then silently fails to run.
        let supervisor = ResumeSupervisor(claudeDir: claudeDir, log: { _ in })
        var override: AccountList?
        if let path = ProcessInfo.processInfo.environment["INFINITUS_ACCOUNTS_JSON"],
           !path.isEmpty {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let decoded = try? JSONDecoder().decode(AccountList.self, from: data) else {
                fail("resume --explain: cannot read accounts JSON at \(path)")
            }
            override = decoded
        }
        let plan = supervisor.plan(list: override)
        if override != nil {
            print("engine: accounts from INFINITUS_ACCOUNTS_JSON")
        } else {
            print("engine: \(CswapLocator.locate() ?? "not installed")")
        }
        if let account = plan.activeAccount {
            print("active account \(account) — \(plan.activeAlive ? "can take work" : "at a limit")")
        } else {
            print("active account: none")
        }
        if let skipped = plan.skipped {
            print("would nudge nothing: \(skipped)")
            return 0
        }
        for stop in plan.eligible {
            print("would nudge \(stop.pid) \(stop.name ?? "unnamed") — gate clear")
        }
        for (stop, reason) in plan.held {
            print("would hold  \(stop.pid) \(stop.name ?? "unnamed") — \(reason)")
        }
        if plan.eligible.isEmpty, plan.held.isEmpty {
            print("would nudge nothing: no limit stops")
        }
        return 0
    }

    var stopped = Resume.stopped(claudeDir: claudeDir)
    if let pid { stopped = stopped.filter { $0.pid == pid } }
    guard !stopped.isEmpty else {
        print("nothing stopped at a usage limit")
        return 0
    }

    if dryRun {
        for session in stopped {
            let reachable = session.socketPath.isEmpty ? "no pipe"
                : (NamedPipe.isListening(session.socketPath) ? "pipe" : "pipe gone")
            print("\(session.pid) \(session.name ?? "unnamed") — \(reachable) — \(session.cwd)")
        }
        return 0
    }

    let outcome = Resume.coordinator(claudeDir: claudeDir).resume(stopped)
    for session in outcome.accepted {
        print("nudged \(session.pid) (\(outcome.channel[session.sessionId] ?? "peer"))")
    }
    for session in outcome.unreachable {
        print("unreachable \(session.pid) — no peer channel (Windows has no send-keys fallback)")
    }
    return outcome.unreachable.isEmpty ? 0 : 1
}
