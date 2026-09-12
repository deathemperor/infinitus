import Foundation

// Display-side logic ported from claude_swap/menubar.py — the JSON feed is
// deliberately raw (resetsAt preserved, pct as stored), so each frontend
// rolls weekly windows against its own clock.

/// Menu-bar title preferences; field names, defaults, and choice sets mirror
/// `MenuBarSettings` in menubar.py (the rumps app persists the same four).
public struct TitlePrefs: Sendable, Equatable {
    public var showAccountName: Bool
    public var titlePct: String   // "off" | "5h" | "7d" | "both"
    public var titleScoped: Bool
    /// Percentages count what's LEFT instead of what's used
    /// (menu-bar-only setting, 2026-08-30).
    public var titleRemaining: Bool
    /// When the binding window resets, in the menu bar: "off" |
    /// "countdown" ("↺2h14m") | "clock" ("↺20:29") — the one number a
    /// one-account user actually waits on (user 2026-09-03). The
    /// formatter's own default is off so the ported title tests stay
    /// put; the app defaults to countdown.
    public var titleReset: String

    public static let pctChoices = ["off", "5h", "7d", "both"]
    public static let resetChoices = ["off", "countdown", "clock"]
    public static let refreshChoices = [30, 60, 300]

    public init(showAccountName: Bool = true, titlePct: String = "both",
                titleScoped: Bool = false, titleRemaining: Bool = false,
                titleReset: String = "off") {
        self.showAccountName = showAccountName
        self.titlePct = titlePct
        self.titleScoped = titleScoped
        self.titleRemaining = titleRemaining
        self.titleReset = titleReset
    }
}

public enum WeeklyRoll {
    static let periodSeconds: TimeInterval = 7 * 24 * 3600

    public static func parse(_ iso: String?) -> Date? {
        // Cached formatters: a fresh ISO8601DateFormatter builds an ICU
        // calendar (~ms), and this runs per account per sort comparison
        // per frame under the critical overlay — the e2e's demo fleet
        // saturated the main thread at 80% and starved the control
        // socket for 15 min (2026-09-03).
        iso.flatMap(UsageHistory.parseISO)
    }

    /// The pct a weekly window should DISPLAY at `now`: 0 once its stored
    /// reset has passed (weekly limits reset on a fixed cadence, so the
    /// stored measurement belongs to a window that no longer exists —
    /// `_rolled_weekly_window` in menubar.py). Missing/future/unparseable
    /// resets return the stored pct unchanged.
    public static func displayPct(_ window: UsageWindow?, now: Date) -> Double? {
        guard let window else { return nil }
        guard let reset = parse(window.resetsAt), reset <= now else { return window.pct }
        return 0.0
    }

    /// The reset instant a rolled weekly window should display: the next
    /// 7-day boundary after `now`. Unrolled windows return their own reset.
    public static func displayReset(_ window: UsageWindow?, now: Date) -> Date? {
        guard let window, let reset = parse(window.resetsAt) else { return nil }
        guard reset <= now else { return reset }
        let missed = floor(now.timeIntervalSince(reset) / periodSeconds) + 1
        return reset.addingTimeInterval(missed * periodSeconds)
    }
}

/// Port of menubar.py `format_title` — segment for segment.
public enum TitleFormatter {
    public static let icon = "⇄"

    /// The menu bar drops (and persists as user-removed!) any status item
    /// that no longer fits — verified live 2026-08-29 on a crowded notched
    /// bar: a 12-char title was evicted, a 1-char title survived. The title
    /// therefore stays SHORT: names cap at 10 chars, percentages join with
    /// a bare dot.
    static let maxNameLength = 10

    /// `icon`: the leading glyph. The app passes "" — the status button
    /// carries a real template image now — while the default keeps the
    /// text-only fallback (and the ported tests) intact.
    public static func format(account: Account?, prefs: TitlePrefs,
                              now: Date = Date(),
                              icon: String = TitleFormatter.icon) -> String {
        guard let account else { return icon }
        var segments: [String] = []
        if prefs.showAccountName {
            let name = account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
            segments.append(name.count > maxNameLength
                            ? name.prefix(maxNameLength - 1) + "…" : name)
        }
        let usage = account.usage
        // The remaining flip happens at display time so every window kind
        // (5h, 7d, scoped) counts the same direction.
        let shown: (Double) -> Double = {
            prefs.titleRemaining ? max(0, 100 - $0) : $0
        }
        var pcts: [String] = []
        if prefs.titlePct == "5h" || prefs.titlePct == "both",
           let pct = usage?.fiveHour?.pct {
            pcts.append("\(Int(shown(pct).rounded()))")
        }
        if prefs.titlePct == "7d" || prefs.titlePct == "both",
           let pct = WeeklyRoll.displayPct(usage?.sevenDay, now: now) {
            pcts.append("\(Int(shown(pct).rounded()))")
        }
        if !pcts.isEmpty { segments.append(pcts.joined(separator: "·") + "%") }
        if prefs.titleScoped {
            for window in usage?.scoped ?? [] {
                guard let name = window.name,
                      let pct = WeeklyRoll.displayPct(window, now: now) else { continue }
                segments.append("\(name) \(Int(shown(pct).rounded()))%")
            }
        }
        if prefs.titleReset != "off",
           let reset = bindingReset(usage, now: now) {
            segments.append("↺" + (prefs.titleReset == "clock"
                ? ResetLabel.shortClock(reset, now: now, calendar: .current)
                : ResetLabel.countdown(reset, now: now)))
        }
        if segments.isEmpty { return icon }
        let joined = segments.joined(separator: " · ")
        return icon.isEmpty ? joined : "\(icon) " + joined
    }

    /// The reset the user is waiting on: of the 5h and 7d windows with a
    /// reset still ahead, the fuller one (ties go to the 5h, which
    /// moves first). Nothing while both windows are untouched.
    static func bindingReset(_ usage: Usage?, now: Date) -> Date? {
        let windows = [usage?.fiveHour, usage?.sevenDay].compactMap { $0 }
            .compactMap { w -> (Double, Date)? in
                guard let at = WeeklyRoll.parse(w.resetsAt), at > now,
                      let pct = WeeklyRoll.displayPct(w, now: now), pct > 0 else { return nil }
                return (pct, at)
            }
        return windows.max { $0.0 < $1.0 }?.1
    }
}

/// The agent chip's tooltip — the session-counter breakdown (docs/TODO.md
/// item, tooltip form chosen 2026-08-29).
public enum SessionSummary {
    public static func tooltip(_ live: LiveSessions) -> String {
        let tail = "\(live.total) live Claude Code sessions — all ride the active account"
        guard let idle = live.idle, let waiting = live.waiting,
              let shell = live.shell, let unknown = live.unknown else {
            // Older engine: no breakdown on the record.
            return "\(live.busy) session(s) mid-turn of " + tail
        }
        var parts = ["\(live.busy) working"]
        if idle > 0 { parts.append("\(idle) idle") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if shell > 0 { parts.append("\(shell) in shell") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: " · ") + " of " + tail
    }
}


/// How old a stale reading is, for the row (#965): "just now" under a
/// minute, then minutes, hours, days — the desktop's wording.
public enum StaleAge {
    public static func label(seconds: Double) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

public extension Account {
    /// The row's age caption when swapd could not refresh this account
    /// (#965); nil for every non-stale row, and nil when stale but the
    /// engine gave no age to show.
    var staleAgeLabel: String? {
        guard stale == true else { return nil }
        return (usageAgeSeconds ?? lastGoodAgeSeconds).map(StaleAge.label)
    }
}

/// Human notes for non-"ok" `usageStatus` values. Strings are word-for-word
/// `SENTINEL_NOTES` from claude_swap/switcher.py — the codebase's stated
/// invariant is that every surface renders these identically.
public enum SentinelNotes {
    public static let notes: [String: String] = [
        "token_expired": "token expired — refresh deferred this pass; retries automatically",
        "foreign_credential": "live credential belongs to another account — a switch repairs it",
        "api_key": "API key (no quota)",
        "keychain_unavailable": "keychain unavailable — locked or in use; try again",
        "relogin_required": "re-login needed — refresh token dead; log in with Claude Code, then run: swapd add",
        "no_credentials": "no credentials",
    ]

    /// nil for "ok" (rows render their usage windows); otherwise the note,
    /// falling back to the raw status for values this build doesn't know.
    public static func note(for usageStatus: String) -> String? {
        if usageStatus == "ok" { return nil }
        return notes[usageStatus] ?? usageStatus.replacingOccurrences(of: "_", with: " ")
    }

    /// One-line row form — a wrapping sentence breaks the account grid
    /// (relogin_required ran three lines, user screenshot 2026-08-31).
    /// The full note rides the row's tooltip; statuses already short
    /// fall through unchanged.
    static let shortNotes: [String: String] = [
        "token_expired": "token expired — retrying",
        "foreign_credential": "foreign credential",
        "keychain_unavailable": "keychain locked",
        "relogin_required": "re-login needed",
    ]

    public static func short(for usageStatus: String) -> String? {
        guard let full = note(for: usageStatus) else { return nil }
        return shortNotes[usageStatus] ?? full
    }
}

/// "2h 15m (11:19)" — countdown plus wall clock, port of oauth.format_reset /
/// reset_clock_string. Recomputed from `resetsAt` at render time (cached feed
/// strings drift as the measurement ages); falls back to the fetch-time
/// strings when the window carries no parseable reset.
public enum ResetLabel {
    public static func label(_ window: UsageWindow?, now: Date = Date(),
                             calendar: Calendar = .current) -> String? {
        guard let window else { return nil }
        return label(resetsAt: window.resetsAt, countdown: window.countdown,
                     clock: window.clock, now: now, calendar: calendar)
    }

    /// Raw-field variant so non-UsageWindow carriers (the spend cap) can
    /// render the same label.
    public static func label(resetsAt: String?, countdown: String?,
                             clock: String?, now: Date = Date(),
                             calendar: Calendar = .current) -> String? {
        guard let reset = WeeklyRoll.parse(resetsAt) else {
            guard let clock else { return countdown }
            return "\(countdown ?? "?") (\(clock))"
        }
        let total = max(0, Int(reset.timeIntervalSince(now)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let countdown: String
        if days > 0 { countdown = "\(days)d \(hours)h" }
        else if hours > 0 { countdown = "\(hours)h \(minutes)m" }
        else { countdown = "\(minutes)m" }
        return "\(countdown) (\(clockString(reset, now: now, calendar: calendar)))"
    }

    /// The countdown alone, no wall clock — for rows that must stay narrow
    /// (gamified gauges already spend the width the clock used to have).
    public static func short(_ window: UsageWindow?, now: Date = Date(),
                             calendar: Calendar = .current) -> String? {
        guard let full = label(window, now: now, calendar: calendar) else { return nil }
        guard let paren = full.firstIndex(of: "(") else { return full }
        let trimmed = full[..<paren].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? full : trimmed
    }

    /// Dense variant for the compact popup: "1h44m·22:10", "5d7h·Sep 4"
    /// (countdown de-spaced, wall clock without parens, date-only when the
    /// reset lands on another day).
    public static func compact(_ window: UsageWindow?, now: Date = Date(),
                               calendar: Calendar = .current) -> String? {
        guard let window else { return nil }
        return compact(resetsAt: window.resetsAt, countdown: window.countdown,
                       now: now, calendar: calendar)
    }

    public static func compact(resetsAt: String?, countdown: String?,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> String? {
        guard let reset = WeeklyRoll.parse(resetsAt) else {
            guard let countdown else { return nil }
            return countdown.replacingOccurrences(of: " ", with: "")
        }
        return "\(Self.countdown(reset, now: now))·\(shortClock(reset, now: now, calendar: calendar))"
    }

    /// "22:10" today, "Sep 4" on another day.
    static func shortClock(_ reset: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(reset, inSameDayAs: now) ? "HH:mm" : "MMM d"
        return f.string(from: reset)
    }

    /// De-spaced countdown: "5d7h", "1h44m", "12m".
    static func countdown(_ reset: Date, now: Date) -> String {
        let total = max(0, Int(reset.timeIntervalSince(now)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    static func clockString(_ reset: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(reset, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "MMM d HH:mm"
        }
        return f.string(from: reset)
    }
}

/// "Dead" = out of ANY limit right now: session (5h), weekly (7d), a
/// per-model weekly window, or the usage-credit spend cap. Display-only
/// verdict — autoswitch has its own decision logic.
public enum AccountVitals {
    /// The window that blocks a dead account, with its reset fields. When
    /// several limits are exhausted the LATEST reset governs (the account
    /// is only usable once all of them roll); a dead cap with no reset at
    /// all (spend credit) blocks indefinitely and wins outright.
    public struct DeadCause: Equatable, Sendable {
        public let kind: Kind
        public let name: String?          // model name for .scoped
        public let resetsAt: String?
        public let countdown: String?
        public let clock: String?
        public enum Kind: Equatable, Sendable { case session, weekly, scoped, credit }
    }

    public static func cause(_ usage: Usage?) -> DeadCause? {
        guard let usage else { return nil }
        var dead: [(DeadCause, Date?)] = []
        if let w = usage.fiveHour, w.pct >= 100 {
            dead.append((DeadCause(kind: .session, name: nil, resetsAt: w.resetsAt,
                                   countdown: w.countdown, clock: w.clock),
                         WeeklyRoll.parse(w.resetsAt)))
        }
        if let w = usage.sevenDay, w.pct >= 100 {
            dead.append((DeadCause(kind: .weekly, name: nil, resetsAt: w.resetsAt,
                                   countdown: w.countdown, clock: w.clock),
                         WeeklyRoll.parse(w.resetsAt)))
        }
        for w in usage.scoped ?? [] where w.pct >= 100 {
            dead.append((DeadCause(kind: .scoped, name: w.name, resetsAt: w.resetsAt,
                                   countdown: w.countdown, clock: w.clock),
                         WeeklyRoll.parse(w.resetsAt)))
        }
        // The spend cap is deliberately NOT here: spent usage credit only
        // means the overflow buffer is gone — the account stays usable on
        // its subscription windows (user-verified: papaya at 0%/0% with a
        // spent cap was marked dead and is perfectly alive).
        return dead.max {
            ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture)
        }?.0
    }

    public static func isDead(_ usage: Usage?) -> Bool {
        guard let usage else { return false }
        var pcts: [Double] = []
        if let p = usage.fiveHour?.pct { pcts.append(p) }
        if let p = usage.sevenDay?.pct { pcts.append(p) }
        for w in usage.scoped ?? [] { pcts.append(w.pct) }
        // A credit-only plan (Kiro's monthly pool) has nothing else to
        // live on: spent credit IS the death there. Under Claude's
        // windows it stays a footnote.
        if pcts.isEmpty, let spend = usage.spend { return spend.pct >= 100 }
        return pcts.contains { $0 >= 100 }
    }
}

/// Live countdown to a recovery instant, for the all-limited state
/// (todo 2026-09-01: "highlight the first to be revived with countdown
/// active"). Ticks in the UI every second; pure here so it's testable.
public enum RecoveryCountdown {
    /// "1d 02:03:04" / "02:03:04"; clamps at zero once the instant is due.
    public static func label(until: Date, now: Date) -> String {
        let secs = max(0, Int(until.timeIntervalSince(now).rounded()))
        let hms = String(format: "%02d:%02d:%02d",
                         (secs % 86400) / 3600, (secs % 3600) / 60, secs % 60)
        let days = secs / 86400
        return days > 0 ? "\(days)d \(hms)" : hms
    }
}
