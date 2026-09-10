import SwiftUI
import InfinitusCore

/// The resume-nudge mechanism, app-side (user 2026-08-30: "move all the
/// nudge mechanism to Infinitus" — upstream never merged the engine's
/// copy). Reads Claude Code's own session records and transcripts,
/// messages a stopped session over its peer socket (typing into its
/// terminal — cmux/tmux/herdr — when it has none), and re-arms `/rc`
/// after a switch. Off by
/// default; per-machine (the terminals are).
@MainActor
final class ResumeService: ObservableObject {
    @Published var resumeEnabled: Bool {
        didSet { defaults.set(resumeEnabled, forKey: "resume_stopped_sessions") }
    }
    @Published var rearmEnabled: Bool {
        didSet { defaults.set(rearmEnabled, forKey: "rearm_remote_control") }
    }
    /// Sessions whose terminal saw no activity for longer are left alone
    /// by the `/rc` sweep; 0 sweeps every one.
    @Published var rearmActiveWithinMinutes: Int {
        didSet { defaults.set(rearmActiveWithinMinutes, forKey: "rearm_active_within_minutes") }
    }
    @Published private(set) var lastResult: String?
    /// Multiplexers found at launch, for the pane caption.
    let hostNames: [String]

    /// Event-log sink, wired by AppModel: (SF Symbol, text).
    var log: ((String, String) -> Void)?
    /// AppModel.push (Notification Center + engine away-push), wired by
    /// AppModel — for the sub-agent nudge, which is notice-worthy on its
    /// own (#117), unlike the plain resume which only logs.
    var push: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let claudeDir = ClaudeSessions.configHome()
    private var busy = false
    /// Stop uuids already nudged. A stop that still stands after our best
    /// effort (held for review, burned twice) is never retried — only a NEW
    /// stop is, so a held message can't be queued twice.
    private var nudged: Set<String> = []
    /// Last nudge instant per SESSION — a burned retry mints a fresh
    /// stopUuid, which is how the 2026-09-01 nudge loop escaped the set
    /// above (three nudges in one minute). ResumeGate.cooldown spaces them.
    private var lastNudge: [String: Date] = [:]
    /// A nudge the control socket sent by hand (#612 `nudge <pid>`),
    /// counted like the service's own so the cooldown spaces the next
    /// automatic one from it.
    func noteManualNudge(sessionId: String) { lastNudge[sessionId] = Date() }
    /// Active account number when each stop was first observed, so a
    /// later SWITCH is distinguishable from the same stale account.
    private var stopFirstActive: [String: Int] = [:]
    /// Sub-agent limit stop uuids already nudged (#117) — same
    /// once-only rule as `nudged`, kept separate since these are the
    /// SUB-AGENT's uuid, not the parent's.
    private var nudgedSubagents: Set<String> = []
    private let activeBox = ActiveBox()

    /// The active account number as of the latest snapshot, readable
    /// from the detached resume round.
    final class ActiveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var number: Int?
        func set(_ n: Int?) { lock.lock(); number = n; lock.unlock() }
        func get() -> Int? { lock.lock(); defer { lock.unlock() }; return number }
    }

    init() {
        resumeEnabled = defaults.object(forKey: "resume_stopped_sessions") as? Bool ?? false
        rearmEnabled = defaults.object(forKey: "rearm_remote_control") as? Bool ?? false
        rearmActiveWithinMinutes = defaults.object(forKey: "rearm_active_within_minutes") as? Int ?? 120
        hostNames = PtyHosts.available().map(\.name)
    }

    /// Called on every snapshot. `switched`: the active account changed
    /// (display-feed diff, so manual and parked-engine switches count);
    /// `activeAlive`: the account we are on can take work; `activeNumber` /
    /// `activeFetchedAt` feed ResumeGate — "alive" is only as fresh as the
    /// engine's last usage poll, and a verdict that predates the stop is
    /// the stale read that burned three nudges in a minute (2026-09-01).
    /// `activeName` / `activePct` name the account in the sub-agent nudge
    /// (#117); nil when unavailable, and the nudge text degrades gracefully.
    /// Blocking work runs detached; single-flight.
    func tick(switched: Bool, activeAlive: Bool,
              activeNumber: Int? = nil, activeFetchedAt: Date? = nil,
              activeName: String? = nil, activePct: Int? = nil,
              activeSince: Date? = nil) {
        // Every snapshot updates the box, busy or not: a resume round in
        // flight reads it to notice the engine flipping under it (#136).
        activeBox.set(activeNumber)
        let doRearm = switched && rearmEnabled
        let doResume = resumeEnabled && activeAlive
        guard doRearm || doResume, !busy else { return }
        busy = true
        let claudeDir = claudeDir
        let activeWithin = TimeInterval(rearmActiveWithinMinutes) * 60
        let already = nudged
        let lastNudgeCopy = lastNudge
        let firstActiveCopy = stopFirstActive
        let alreadySubagent = nudgedSubagents
        let activeBox = activeBox
        Task.detached(priority: .utility) { [weak self] in
            let hosts = PtyHosts.available()
            let sessions = ClaudeSessions.list(claudeDir: claudeDir)
            let stops = Transcript.findStopped(sessions: sessions, claudeDir: claudeDir)
            var sweep: PtyNudge.SweepResult?
            if doRearm {
                // The app may run from inside a session (run-unbundled.sh
                // from a Claude Code shell): never type into our own lineage.
                let selfPids = Set(ProcessFacts.ancestors(of: getpid()))
                let stopBySession = Dictionary(
                    stops.compactMap { s in s.stoppedAt.map { (s.sessionId, $0) } },
                    uniquingKeysWith: { a, _ in a })
                sweep = PtyNudge.rearmRemoteControl(
                    hosts: hosts, sessions: sessions, selfPids: selfPids,
                    activeWithin: activeWithin, confirm: true,
                    stoppedAt: { stopBySession[$0.sessionId] })
            }
            var outcome: ResumeCoordinator.Outcome?
            var standing: [String] = []
            var newFirstSeen: [String: Int] = [:]
            var held = 0
            if doResume {
                var eligible: [StoppedSession] = []
                for s in stops where !already.contains(s.stopUuid) {
                    if firstActiveCopy[s.stopUuid] == nil,
                       newFirstSeen[s.stopUuid] == nil, let n = activeNumber {
                        newFirstSeen[s.stopUuid] = n
                    }
                    let first = firstActiveCopy[s.stopUuid] ?? newFirstSeen[s.stopUuid]
                    if ResumeGate.allows(stoppedAt: s.stoppedAt,
                                         firstSeenActive: first,
                                         currentActive: activeNumber,
                                         activeFetchedAt: activeFetchedAt,
                                         lastNudge: lastNudgeCopy[s.sessionId],
                                         activeSince: activeSince) {
                        eligible.append(s)
                    } else {
                        held += 1
                    }
                }
                if !eligible.isEmpty {
                    var coordinator = ResumeCoordinator(hosts: hosts, claudeDir: claudeDir)
                    let startActive = activeBox.get()
                    coordinator.activeChanged = { activeBox.get() != startActive }
                    outcome = coordinator.resume(eligible)
                    // Whatever still shows a limit stop after our best
                    // effort is remembered so the next tick leaves it alone.
                    standing = ResumeGate.standing(
                        stillStopped: Transcript.findStopped(sessions: sessions, claudeDir: claudeDir).map(\.stopUuid),
                        attempted: Set(eligible.map(\.stopUuid)))
                }
            }
            // Sub-agent limits (#117): the PARENT never stopped, so it's
            // never in `stops` above — a separate scan, same gate.
            var subagentDelivered: [Transcript.SubagentLimit] = []
            var subagentAttempted: [String] = []
            if doResume {
                // A parent that was limit-stopped at tick start belongs
                // to the resume path this tick even if its nudge just
                // landed (its transcript no longer ends in the stop).
                let stoppedIds = Set(stops.map(\.sessionId))
                let hits = Transcript.findSubagentLimits(sessions: sessions, claudeDir: claudeDir)
                    .filter { !stoppedIds.contains($0.session.sessionId) }
                let text = ResumeCoordinator.subagentMessage(account: activeName, pct: activePct)
                let coordinator = ResumeCoordinator(hosts: hosts, claudeDir: claudeDir)
                for hit in hits where !alreadySubagent.contains(hit.session.stopUuid) {
                    if newFirstSeen[hit.session.stopUuid] == nil,
                       firstActiveCopy[hit.session.stopUuid] == nil, let n = activeNumber {
                        newFirstSeen[hit.session.stopUuid] = n
                    }
                    let first = firstActiveCopy[hit.session.stopUuid] ?? newFirstSeen[hit.session.stopUuid]
                    guard ResumeGate.allows(stoppedAt: hit.session.stoppedAt,
                                            firstSeenActive: first,
                                            currentActive: activeNumber,
                                            activeFetchedAt: activeFetchedAt,
                                            lastNudge: lastNudgeCopy[hit.session.sessionId],
                                            activeSince: activeSince) else { continue }
                    // One attempt per stop, delivered or not: an
                    // unreachable parent must not cost a PTY sweep per tick.
                    subagentAttempted.append(hit.session.stopUuid)
                    if coordinator.nudgeSubagent(hit, text: text) {
                        subagentDelivered.append(hit)
                    }
                }
            }
            await self?.finish(sweep: sweep, outcome: outcome, standing: standing,
                               firstSeen: newFirstSeen, held: held,
                               subagentNudged: subagentDelivered, subagentAttempted: subagentAttempted,
                               accountName: activeName)
        }
    }

    private func finish(sweep: PtyNudge.SweepResult?, outcome: ResumeCoordinator.Outcome?,
                        standing: [String], firstSeen: [String: Int], held: Int,
                        subagentNudged: [Transcript.SubagentLimit] = [], subagentAttempted: [String] = [],
                        accountName: String? = nil) {
        busy = false
        nudgedSubagents.formUnion(subagentAttempted)
        nudged.formUnion(standing)
        stopFirstActive.merge(firstSeen) { a, _ in a }
        if let outcome {
            for session in outcome.accepted { lastNudge[session.sessionId] = Date() }
        }
        for hit in subagentNudged {
            nudgedSubagents.insert(hit.session.stopUuid)
            lastNudge[hit.session.sessionId] = Date()
            let repo = URL(fileURLWithPath: hit.session.cwd).lastPathComponent
            log?("play.circle", "sub-agent limit \(hit.session.sessionId.prefix(8)) (\(hit.agentFile)) told to continue")
            push?("sub-agents hit a limit — \(repo) was told to continue on \(accountName ?? "the active account")")
        }
        if held > 0 {
            log?("hourglass", "\(held) stopped session(s) held — waiting for "
                 + "a switch or a fresh usage poll after the stop")
        }
        var lines: [String] = []
        if let sweep, !sweep.isEmpty {
            var text = "re-armed /rc on \(sweep.sent.count) session(s)"
            if !sweep.confirmed.isEmpty { text += ", \(sweep.confirmed.count) confirmed" }
            if sweep.skippedIdle > 0 { text += ", \(sweep.skippedIdle) idle skipped" }
            if sweep.skippedBusy > 0 { text += ", \(sweep.skippedBusy) mid-turn skipped" }
            if sweep.noSurface > 0 { text += ", \(sweep.noSurface) without a terminal" }
            log?("antenna.radiowaves.left.and.right", text)
            lines.append(text)
        }
        if let outcome {
            for session in outcome.accepted {
                let via = outcome.channel[session.sessionId] ?? "?"
                log?("play.circle", "resumed \(session.sessionId.prefix(8)) via \(via)")
            }
            if !outcome.accepted.isEmpty {
                let text = "resumed \(outcome.accepted.count) stopped session(s)"
                Notifier.post(title: "Infinitus", body: text)
                lines.append(text)
            }
            if !outcome.unreachable.isEmpty {
                let text = "\(outcome.unreachable.count) stopped session(s) unreachable (no terminal, no socket, or mid-turn)"
                log?("play.slash", text)
                lines.append(text)
            }
        }
        if !lines.isEmpty {
            lastResult = lines.joined(separator: " · ")
        }
    }
}

/// Engines-pane section: the app-side switches. Sits above the Claude
/// Code-side reliability rows, which gate deliverability for any sender.
struct ResumeNudgesSection: View {
    @ObservedObject var service: ResumeService

    private var hostsCaption: String {
        service.hostNames.isEmpty
            ? "No terminal multiplexer found (cmux, tmux, herdr) — only sessions with a peer socket can be reached."
            : "Peer socket first; terminals (\(service.hostNames.joined(separator: ", "))) for sessions without one."
    }

    var body: some View {
        Section("Resume nudges — Infinitus side") {
            Toggle("Resume sessions a usage limit stopped", isOn: $service.resumeEnabled)
                .help("When the active account can take work again, type a "
                      + "short message into every Claude Code session whose "
                      + "last turn was a plan-limit stop, so it continues "
                      + "where it left off.")
            Toggle("Re-arm Remote Control (/rc) after a switch", isOn: $service.rearmEnabled)
                .help("Type /rc into the terminal of every live session "
                      + "after the active account changes, so Remote "
                      + "Control follows the new credentials.")
            Stepper(value: $service.rearmActiveWithinMinutes, in: 0...1440, step: 15) {
                Text(service.rearmActiveWithinMinutes == 0
                     ? "Sweep every session, however idle"
                     : "Only sessions active within \(service.rearmActiveWithinMinutes) min")
            }
            .disabled(!service.rearmEnabled)
            Text(hostsCaption + " If a local claude-swap fork still carries "
                 + "autoswitch.resumeStoppedSessions / rearmRemoteControl, "
                 + "turn those off — two senders nudge twice.")
                .font(.caption).foregroundStyle(.secondary)
            if let last = service.lastResult {
                Text("Last run: \(last)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
