import Foundation

#if !os(iOS)
/// Typing into the terminal that hosts a stopped session — the channel
/// that works when the peer socket does not (older Claude Code builds, a
/// session that never bound one) and that can clear the limit menu the
/// socket is powerless against.
public enum PtyNudge {
    /// The "You've hit your limit" menu in Claude Code ≥ 2.1.x and the
    /// `/rc` panel both capture keyboard input: a typed nudge would land as
    /// a menu keystroke, not a prompt. One Esc dismisses either.
    static let menuMarkers = ["Wait for limit to reset", "Adjust monthly spend limit", "Usage credit balance:"]
    static let remoteControlMarkers = ["Remote Control", "Esc to continue"]
    /// The status line Claude Code shows while a turn runs.
    static let runningMarker = "esc to interrupt"
    static let settle: TimeInterval = 1.0
    static let screenLines = 40
    static let sessionURL = try! NSRegularExpression(pattern: "https://claude\\.ai/code/session_[A-Za-z0-9]+")

    public enum Status: Equatable, Sendable {
        /// Typed and the prompt line shows it (or the screen moved on).
        case delivered
        /// Typed, but the screen could not be re-read — assume it landed.
        case typedUnverified
        /// A menu still owns the keyboard after one Esc; nothing typed.
        case capturedInput
        /// A turn is running; nothing typed.
        case running
        /// No surface hosts this pid.
        case noSurface
    }

    /// Screen text with runs of whitespace collapsed — markers straddle
    /// wrapped lines and padded columns.
    static func flat(_ screen: String) -> String {
        screen.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func inputCaptured(_ flat: String) -> Bool {
        if menuMarkers.contains(where: { flat.contains($0) }) { return true }
        return remoteControlMarkers.allSatisfy { flat.contains($0) }
    }

    static func isRunning(_ flat: String) -> Bool { flat.contains(runningMarker) }

    static func locate(_ host: any PtyHost, pid: Int32, tty: String?, ancestors: [Int32],
                       name: String?) -> PtySurface? {
        ((try? host.surfaces()) ?? []).surface(for: pid, tty: tty, ancestors: ancestors, name: name)
    }

    /// Deliver `text` to the session's terminal. The state machine:
    /// running → leave it alone; menu → exactly one Esc, re-read, still a
    /// menu → capturedInput; else type. Never more than one Esc: a second
    /// one lands in a freed prompt as an interrupt.
    public static func nudge(host: any PtyHost, pid: Int32, text: String, tty: String?,
                             ancestors: [Int32], name: String? = nil,
                             sleep: (TimeInterval) -> Void) -> Status {
        guard let surface = locate(host, pid: pid, tty: tty, ancestors: ancestors, name: name)
        else { return .noSurface }
        var screen = flat((try? host.readScreen(surface.ref, lines: screenLines)) ?? "")
        if isRunning(screen) { return .running }
        if inputCaptured(screen) {
            try? host.sendEsc(surface.ref)
            sleep(settle)
            screen = flat((try? host.readScreen(surface.ref, lines: screenLines)) ?? "")
            if inputCaptured(screen) { return .capturedInput }
            if isRunning(screen) { return .running }
        }
        do { try host.sendLine(surface.ref, text) } catch { return .noSurface }
        sleep(settle)
        guard let after = try? host.readScreen(surface.ref, lines: screenLines) else { return .typedUnverified }
        let seen = flat(after)
        // The prompt echoes the text (possibly wrapped) or it was consumed.
        return seen.contains(flat(String(text.prefix(40)))) || seen != screen ? .delivered : .typedUnverified
    }

    /// Presses one key into the session's terminal — the menu-answering
    /// counterpart to `nudge`, which must NEVER be reused here: `nudge`
    /// dismisses a captured menu with one Esc before typing, but a key
    /// press's whole point is to answer that very menu. Running is still
    /// left alone; anything else is sent straight through. `enter` is an
    /// empty line (Claude Code's menus select on Enter alone), `esc` is
    /// the terminal's escape, everything else is typed as a line (a digit
    /// selects an option, the trailing Enter confirms it).
    public static func press(host: any PtyHost, pid: Int32, key: String, tty: String?,
                             ancestors: [Int32], name: String? = nil,
                             sleep: (TimeInterval) -> Void) -> Status {
        guard let surface = locate(host, pid: pid, tty: tty, ancestors: ancestors, name: name)
        else { return .noSurface }
        let screen = flat((try? host.readScreen(surface.ref, lines: screenLines)) ?? "")
        if isRunning(screen) { return .running }
        do {
            switch key {
            case "enter": try host.sendLine(surface.ref, "")
            case "esc": try host.sendEsc(surface.ref)
            default: try host.sendLine(surface.ref, key)
            }
        } catch { return .noSurface }
        sleep(settle)
        return (try? host.readScreen(surface.ref, lines: screenLines)) == nil ? .typedUnverified : .delivered
    }

    // MARK: - /rc re-arm

    public struct SweepResult: Equatable, Sendable {
        public var sent: [String] = []          // "host:ref" per surface typed into
        public var skippedSelf = 0
        public var skippedIdle = 0
        /// Mid-turn sessions left alone — typing or Esc would land inside
        /// running work (user bug 2026-09-01: "Interrupted" after a sweep).
        public var skippedBusy = 0
        public var noSurface = 0
        public var confirmed: [String] = []
        public var urls: [String] = []
        public init() {}
        public var isEmpty: Bool {
            sent.isEmpty && noSurface == 0 && skippedIdle == 0
                && skippedSelf == 0 && skippedBusy == 0
        }
    }

    /// Type `/rc` into every terminal hosting a live interactive session,
    /// so Remote Control re-arms on the account just switched to. Sessions
    /// in this process's own ancestry are skipped (the app may have been
    /// launched from inside one); idle ones beyond `activeWithin` are left
    /// alone. With `confirm`, each screen is re-read after a moment for the
    /// session URL, then the panel is dismissed with one Esc.
    public static func rearmRemoteControl(
        hosts: [any PtyHost], sessions: [ClaudeSessionRecord], selfPids: Set<Int32>,
        activeWithin: TimeInterval, confirm: Bool,
        ttyOfPid: (Int32) -> String? = ProcessFacts.tty(of:),
        ancestorsOf: (Int32) -> [Int32] = ProcessFacts.ancestors(of:),
        idleSeconds: (String) -> TimeInterval? = { ProcessFacts.idleSeconds(tty: $0) },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        /// When a session's last turn was a limit stop, its instant —
        /// idleness is then measured against the STOP, not against now
        /// (user 2026-09-01: a 7d-limit wait made every session "idle").
        stoppedAt: (ClaudeSessionRecord) -> Date? = { _ in nil },
        now: () -> Date = Date.init
    ) -> SweepResult {
        var result = SweepResult()
        var typed: [(host: any PtyHost, ref: String)] = []
        var seen = Set<String>()
        let surfaces = hosts.map { ($0, (try? $0.surfaces()) ?? []) }
        for session in sessions where session.kind == "interactive" || session.kind.isEmpty {
            if selfPids.contains(session.pid) { result.skippedSelf += 1; continue }
            // A busy session is mid-turn: /rc queues into the running
            // work and the later Esc interrupts it. It re-arms on the
            // next sweep once idle.
            if session.status == "busy" { result.skippedBusy += 1; continue }
            let tty = ttyOfPid(session.pid)
            if activeWithin > 0, let tty, let idle = idleSeconds(tty) {
                // The clock a limit stop froze doesn't count as idleness:
                // subtract the wait since the stop, so "active within N
                // min" means active in the N minutes BEFORE the limit hit.
                var effective = idle
                if let stop = stoppedAt(session) {
                    effective = max(0, idle - now().timeIntervalSince(stop))
                }
                if effective > activeWithin {
                    result.skippedIdle += 1
                    continue
                }
            }
            let ancestors = ancestorsOf(session.pid)
            var hit: (any PtyHost, PtySurface)?
            for (host, list) in surfaces {
                if let s = list.surface(for: session.pid, tty: tty, ancestors: ancestors,
                                        name: session.name) { hit = (host, s); break }
            }
            guard let (host, surface) = hit else { result.noSurface += 1; continue }
            let key = "\(host.name):\(surface.ref)"
            guard seen.insert(key).inserted else { continue }
            guard (try? host.sendLine(surface.ref, "/rc")) != nil else { result.noSurface += 1; continue }
            result.sent.append(key)
            typed.append((host, surface.ref))
        }
        guard confirm, !typed.isEmpty else { return result }
        sleep(3)
        for (host, ref) in typed {
            guard let screen = try? host.readScreen(ref, lines: screenLines) else { continue }
            let range = NSRange(screen.startIndex..., in: screen)
            let urls = sessionURL.matches(in: screen, range: range).compactMap {
                Range($0.range, in: screen).map { String(screen[$0]) }
            }
            let f = flat(screen)
            if !urls.isEmpty || remoteControlMarkers.allSatisfy({ f.contains($0) }) {
                result.confirmed.append("\(host.name):\(ref)")
                result.urls.append(contentsOf: urls)
                // The session URL also lives in the persistent
                // "/remote-control is active" status line: when a turn is
                // RUNNING the panel is long gone and this Esc would land
                // on the turn itself (user bug 2026-09-01, "Interrupted ·
                // What should Claude do instead?"). Dismiss only settled
                // screens.
                if !isRunning(f) { try? host.sendEsc(ref) }
            }
        }
        return result
    }
}
#endif
