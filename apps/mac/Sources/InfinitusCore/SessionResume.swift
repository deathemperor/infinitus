import Foundation

#if !os(iOS)
/// Resumes Claude Code sessions a usage limit stopped: a message on the
/// session's peer socket first, a terminal nudge (cmux/tmux/herdr) as
/// the fallback, with the engine's pacing — 5s/15s retries while a nudge burns on stale
/// credentials, a 10s watch to tell burned from held-for-review.
/// Blocking throughout; run detached.
public struct ResumeCoordinator {
    public static let message = "[Infinitus] Your account hit its usage limit and this session stopped. There is quota available again, so you can continue where you left off."
    /// Claude Code drops a message identical to the previous one from the
    /// same sender, so every retry carries a distinct suffix.
    public static func nudgeText(attempt: Int) -> String {
        attempt == 0 ? message : "\(message) (nudge \(attempt + 1))"
    }
    /// A session whose SUB-AGENTS hit the limit while its own transcript
    /// kept going: it read the limit off the sub-agents' results and
    /// parked itself, so it never lands its own limit-stop entry (#117).
    public static func subagentMessage(account: String?, pct: Int?) -> String {
        let clause: String
        if let account, let pct {
            clause = "the account has been swapped: \(account) has \(100 - pct)% headroom now"
        } else {
            clause = "an account with headroom is active now"
        }
        return "[Infinitus] Your sub-agents hit a usage limit, but \(clause). "
            + "It is safe to continue right away — no need to wait for the reset."
    }
    /// Credentials propagate to a running session within seconds; the
    /// second retry waits out a slow one.
    public static let retryDelays: [TimeInterval] = [5, 15]
    public static let verifySeconds: TimeInterval = 10
    public static let pollSeconds: TimeInterval = 1

    public var hosts: [any PtyHost]
    public var claudeDir: URL
    public var ttyOfPid: (Int32) -> String? = ProcessFacts.tty(of:)
    public var ancestorsOf: (Int32) -> [Int32] = ProcessFacts.ancestors(of:)
    public var socketSend: (StoppedSession, String) -> Bool = { s, text in
        let claudeDir = ClaudeSessions.configHome()
        let transcript = Transcript.locate(cwd: s.cwd, sessionId: s.sessionId, claudeDir: claudeDir)
        return PeerSocket.send(socketPath: s.socketPath, text: text, pid: s.pid, claudeDir: claudeDir,
                               mode: Transcript.peerModeClass(at: transcript)
                                   ?? ProcessFacts.peerModeClass(pid: s.pid))
    }
    public var verdict: (StoppedSession) -> Transcript.Verdict
    public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Whether the active account changed since attempt 0: a retry would
    /// re-fire into whatever the engine flipped to (#136), so the round
    /// ends and the next tick starts over through the gate.
    public var activeChanged: () -> Bool = { false }

    public init(hosts: [any PtyHost], claudeDir: URL) {
        self.hosts = hosts
        self.claudeDir = claudeDir
        self.verdict = { Transcript.verdict($0, claudeDir: claudeDir) }
    }

    public struct Outcome: Equatable, Sendable {
        public var accepted: [StoppedSession] = []
        public var unreachable: [StoppedSession] = []
        /// The last channel used per session id, for the event log.
        public var channel: [String: String] = [:]
        public init() {}
    }

    /// One delivery. The peer socket first: Claude Code's own inbox, a
    /// message rather than keystrokes (user 2026-09-03: "cmux -> native
    /// messages"). A terminal host only for a record without a usable
    /// socket, or when the send fails — never both (two prompts). On the
    /// terminal path a running turn is left alone and a menu that stays
    /// captured makes the session unreachable this round.
    func deliver(_ session: StoppedSession, text: String) -> String? {
        if session.canUseSocket, socketSend(session, text) { return "socket" }
        let tty = ttyOfPid(session.pid)
        let ancestors = ancestorsOf(session.pid)
        for host in hosts {
            switch PtyNudge.nudge(host: host, pid: session.pid, text: text, tty: tty,
                                  ancestors: ancestors, name: session.name, sleep: sleep) {
            case .delivered, .typedUnverified: return host.name
            case .running: return nil
            case .capturedInput, .noSurface: continue
            }
        }
        return nil
    }

    /// One-shot nudge for a sub-agent limit: the parent is not stopped —
    /// it is running, just waiting on a stale usage read — so there is
    /// nothing to verify and no retry loop, unlike `resume`.
    public func nudgeSubagent(_ hit: Transcript.SubagentLimit, text: String) -> Bool {
        deliver(hit.session, text: text) != nil
    }

    /// Nudge every stopped session, retrying the ones whose nudge burned.
    public func resume(_ stopped: [StoppedSession]) -> Outcome {
        var outcome = Outcome()
        var pending = stopped
        for attempt in 0...Self.retryDelays.count {
            if attempt > 0 {
                sleep(Self.retryDelays[attempt - 1])
                if activeChanged() { break }
            }
            var sent: [StoppedSession] = []
            for session in pending {
                if let channel = deliver(session, text: Self.nudgeText(attempt: attempt)) {
                    outcome.channel[session.sessionId] = channel
                    sent.append(session)
                    if attempt == 0 { outcome.accepted.append(session) }
                } else if attempt == 0 {
                    outcome.unreachable.append(session)
                }
            }
            pending = watch(sent)
            if pending.isEmpty { break }
        }
        return outcome
    }

    /// Poll each nudged session's transcript until it moves or the watch
    /// expires; returns the ones that burned, re-baselined to the new
    /// stop so the next verdict compares against it.
    func watch(_ sent: [StoppedSession]) -> [StoppedSession] {
        var pending = sent
        var burned: [StoppedSession] = []
        var elapsed: TimeInterval = 0
        while !pending.isEmpty, elapsed < Self.verifySeconds {
            sleep(Self.pollSeconds)
            elapsed += Self.pollSeconds
            var still: [StoppedSession] = []
            for session in pending where !session.stopUuid.isEmpty {
                switch verdict(session) {
                case .waiting: still.append(session)
                case .burned(let uuid):
                    var again = session
                    again.stopUuid = uuid
                    burned.append(again)
                case .done: break
                }
            }
            pending = still
        }
        return burned
    }
}
#endif
