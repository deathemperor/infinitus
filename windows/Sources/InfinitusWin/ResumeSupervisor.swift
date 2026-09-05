import Foundation
import InfinitusCore

/// The automatic half of the resume-nudge mechanism on Windows — the Mac's
/// `ResumeService.tick` without SwiftUI (CLAUDE.md: this mechanism lives in
/// Infinitus, never engine-side).
///
/// `Resume.swift` deliberately kept the nudge manual because the box "runs
/// no engine, so it can't tell 'quota is back' from 'still limited' — it
/// would nudge into the same wall". That premise expired the moment cswap
/// was installed here: `CswapFleet.list()` reports the active account and
/// its `usageFetchedAt`, which is exactly the evidence `ResumeGate` wants.
/// With no engine we stay manual, for the original reason.
///
/// Every guard the Mac learned the hard way is kept, because they are the
/// difference between resuming work and the 2026-09-01 loop that fired
/// three nudges into a still-limited session in one minute:
///   - `ResumeGate.allows` — something must have changed SINCE the stop
///     (a switch, or a usage poll that postdates it).
///   - `nudged` — a stop still standing after our best effort is never
///     retried; only a NEW stop is.
///   - `lastNudge` per SESSION — a burned retry mints a fresh stopUuid,
///     which is how the runaway escaped the set above.
/// No pty fallback: `hosts: []`, so a session without a live pipe is
/// honestly unreachable rather than typed at.
final class ResumeSupervisor: @unchecked Sendable {
    /// How often to look. The engine polls Anthropic on its own schedule
    /// and `ResumeGate.cooldown` is 600 s, so a tighter tick would only
    /// re-read transcripts to reach the same verdict.
    static let tickSeconds: TimeInterval = 60

    /// Default-off, like the Mac's toggle: nudging types into someone's
    /// session, so it is opt-in per machine (`serve --auto-resume`).
    private let claudeDir: URL
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    /// Stop uuids already nudged (see the class comment).
    private var nudged: Set<String> = []
    /// Last nudge per session id, whatever stop entry it came from.
    private var lastNudge: [String: Date] = [:]
    /// Active account when each stop was FIRST seen, so a later switch is
    /// distinguishable from the same stale account.
    private var stopFirstActive: [String: Int] = [:]
    /// Active account at the previous tick, for the switch diff.
    private var previousActive: Int?
    private var started = false
    private var timer: DispatchSourceTimer?

    init(claudeDir: URL, log: @escaping @Sendable (String) -> Void) {
        self.claudeDir = claudeDir
        self.log = log
    }

    /// Arms the tick on a background queue. Idempotent.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        guard CswapLocator.locate() != nil else {
            // No engine, no quota signal: say so once rather than tick
            // forever deciding nothing.
            log("auto-resume off: no swap engine found — `infinitus-win resume` nudges by hand")
            return
        }
        log("auto-resume on: checking every \(Int(Self.tickSeconds))s "
            + "(gate: a switch or a usage poll after the stop; \(Int(ResumeGate.cooldown))s per-session cooldown)")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.tickSeconds, repeating: Self.tickSeconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// What a tick decided, before anything is delivered. Split out so
    /// the decision — the part that once fired three nudges into a
    /// still-limited session in a minute — can be inspected and tested
    /// without writing to anyone's session.
    struct Plan {
        /// Stops that clear the gate and would be nudged.
        var eligible: [StoppedSession] = []
        /// Stops deliberately held, with the reason the gate gives.
        var held: [(stop: StoppedSession, reason: String)] = []
        /// Why nothing was considered at all, when that's the case.
        var skipped: String?
        /// The active account this pass saw, for the caption.
        var activeAccount: Int?
        var activeAlive = false
        var switched = false
    }

    /// The decision for right now. Mutates the first-seen map (a stop's
    /// first-observed account is part of the gate's evidence) but writes
    /// nothing to any session.
    func plan(now: Date = Date(), list providedList: AccountList? = nil) -> Plan {
        var plan = Plan()
        let list = providedList ?? CswapFleet.list(now: now)
        // No list means the engine failed or timed out. Holding is the
        // safe read: an unknown active account can't clear the gate.
        guard let list else {
            plan.skipped = "engine reported nothing (not installed, timed out, or undecodable)"
            return plan
        }

        let active = list.accounts.first { $0.number == list.activeAccountNumber }
        let activeAlive = active.map { !AccountVitals.isDead($0.usage) } ?? false
        let activeFetchedAt = active?.usageFetchedAt.flatMap(UsageHistory.parseISO)
        plan.activeAccount = list.activeAccountNumber
        plan.activeAlive = activeAlive

        lock.lock()
        let previous = previousActive
        previousActive = list.activeAccountNumber
        lock.unlock()
        plan.switched = previous != nil && previous != list.activeAccountNumber

        // Resume only when the account it would resume ONTO can take
        // work; a switch alone doesn't make a dead account alive.
        guard activeAlive else {
            plan.skipped = list.activeAccountNumber == nil
                ? "no active account"
                : "active account \(list.activeAccountNumber!) is at a limit"
            return plan
        }

        let sessions = ClaudeSessions.list(claudeDir: claudeDir)
        let stops = Transcript.findStopped(sessions: sessions, claudeDir: claudeDir)
        guard !stops.isEmpty else {
            plan.skipped = "nothing stopped at a usage limit"
            return plan
        }

        lock.lock()
        let already = nudged
        let lastNudgeCopy = lastNudge
        let firstActiveCopy = stopFirstActive
        lock.unlock()

        var newFirstSeen: [String: Int] = [:]
        for stop in stops {
            if already.contains(stop.stopUuid) {
                plan.held.append((stop, "already nudged; this stop still stands"))
                continue
            }
            if firstActiveCopy[stop.stopUuid] == nil, newFirstSeen[stop.stopUuid] == nil,
               let number = list.activeAccountNumber {
                newFirstSeen[stop.stopUuid] = number
            }
            let first = firstActiveCopy[stop.stopUuid] ?? newFirstSeen[stop.stopUuid]
            if ResumeGate.allows(stoppedAt: stop.stoppedAt,
                                 firstSeenActive: first,
                                 currentActive: list.activeAccountNumber,
                                 activeFetchedAt: activeFetchedAt,
                                 lastNudge: lastNudgeCopy[stop.sessionId],
                                 now: now) {
                plan.eligible.append(stop)
            } else if let last = lastNudgeCopy[stop.sessionId],
                      now.timeIntervalSince(last) < ResumeGate.cooldown {
                let left = Int(ResumeGate.cooldown - now.timeIntervalSince(last))
                plan.held.append((stop, "cooldown, \(left)s left"))
            } else {
                plan.held.append((stop, "no switch and no usage poll after the stop"))
            }
        }

        lock.lock()
        stopFirstActive.merge(newFirstSeen) { a, _ in a }
        lock.unlock()
        return plan
    }

    /// One pass. Runs on the timer queue — everything here may block.
    /// `now` and `list` are injectable so a caller can drive it without
    /// an engine or a clock.
    func tick(now: Date = Date(), list providedList: AccountList? = nil) {
        let plan = plan(now: now, list: providedList)
        let eligible = plan.eligible
        guard !eligible.isEmpty else {
            if !plan.held.isEmpty, plan.switched {
                log("auto-resume: \(plan.held.count) stopped session(s) held — "
                    + "waiting for a usage poll after the stop")
            }
            return
        }

        let outcome = Resume.coordinator(claudeDir: claudeDir).resume(eligible)
        // Whatever STILL reads as a limit stop after our best effort is
        // remembered, so the next tick leaves it alone. Re-listed rather
        // than reusing the plan's records: a nudged session may have
        // moved on, and that is the whole point of re-reading.
        let standing = Transcript.findStopped(
            sessions: ClaudeSessions.list(claudeDir: claudeDir), claudeDir: claudeDir)
            .map(\.stopUuid).filter { !$0.isEmpty }

        lock.lock()
        nudged.formUnion(standing)
        for session in outcome.accepted { lastNudge[session.sessionId] = now }
        lock.unlock()

        for session in outcome.accepted {
            let via = outcome.channel[session.sessionId] ?? "peer"
            log("auto-resume: nudged \(session.pid) (\(session.name ?? "unnamed")) via \(via)")
        }
        if !outcome.unreachable.isEmpty {
            log("auto-resume: \(outcome.unreachable.count) stopped session(s) unreachable "
                + "— no peer channel (Windows has no send-keys fallback)")
        }
    }
}
