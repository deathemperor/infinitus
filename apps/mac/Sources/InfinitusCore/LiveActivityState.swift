import Foundation

// The iPhone's Live Activities (#1 all-dead revival countdown, #2
// working sessions), as plain data: the phone renders these, and BOTH
// the phone (while it runs) and the Mac (over APNs, app closed) build
// them from the same fleet with `LiveActivityBuilder`, so a push and an
// in-app update never disagree. Everything is pre-themed — RowTheme
// labels, glyphs, colour names, dense reset labels — the widget only
// draws.

/// One usage window, themed: "MP" / "HP" / "× Dragon", its colour name,
/// percent used, and the dense reset label ("4h20m·17:49").
public struct ActivityWindow: Codable, Hashable, Sendable {
    public var label: String
    public var color: String
    public var pct: Double
    public var reset: String?

    public init(label: String, color: String, pct: Double, reset: String?) {
        self.label = label
        self.color = color
        self.pct = pct
        self.reset = reset
    }
}

/// #2: the active account as its themed popup row, the session counts,
/// the tokens/minute gauge, the next candidate as a subtle hint.
public struct WorkingActivityState: Codable, Hashable, Sendable {
    public var active: String
    public var icon: String?
    public var slot: String
    public var plan: String?
    public var cash: String?
    public var windows: [ActivityWindow]
    /// Index into `windows` of the one closest to its limit.
    public var binding: Int?
    public var busy: Int
    public var total: Int
    public var waiting: Int
    public var next: String?
    /// Output tokens per minute across the fleet, and 0…1 of the
    /// recent peak for the bar. Nil until something flows.
    public var tokensPerMinute: Int?
    public var tokenFraction: Double
    public var accent: String
    public var plain: Bool
    /// The theme's tokens/minute icon and unit (#218); nil keeps the
    /// bolt and "tok/min". Optional so older payloads still decode.
    public var rateIcon: String? = nil
    public var rateLabel: String? = nil

    public init(active: String, icon: String?, slot: String, plan: String?, cash: String?,
                windows: [ActivityWindow], binding: Int?, busy: Int, total: Int, waiting: Int,
                next: String?, tokensPerMinute: Int?, tokenFraction: Double, accent: String, plain: Bool,
                rateIcon: String? = nil, rateLabel: String? = nil) {
        self.active = active
        self.icon = icon
        self.slot = slot
        self.plan = plan
        self.cash = cash
        self.windows = windows
        self.binding = binding
        self.busy = busy
        self.total = total
        self.waiting = waiting
        self.next = next
        self.tokensPerMinute = tokensPerMinute
        self.tokenFraction = tokenFraction
        self.accent = accent
        self.plain = plain
        self.rateIcon = rateIcon
        self.rateLabel = rateLabel
    }
}

/// #1: every account is limited; counts down to the first reviver's
/// reset (the countdown ticks natively from `revivesAt`).
public struct RevivalActivityState: Codable, Hashable, Sendable {
    public var reviver: String
    public var icon: String?
    public var revivesAt: Date
    /// Live sessions on the Mac, and how many are stopped waiting for an
    /// account (the ones a revival resumes).
    public var sessions: Int
    public var waiting: Int
    /// The accounts after the reviver, in recovery order: "loc 2:50 PM".
    public var later: [String]
    /// Theme words: "revives" / "is dead" … and the flash colour.
    public var reviveWord: String
    public var deadWord: String
    public var accent: String
    /// Final state: the fleet came back.
    public var revived: Bool

    public init(reviver: String, icon: String?, revivesAt: Date, sessions: Int, waiting: Int,
                later: [String], reviveWord: String, deadWord: String, accent: String, revived: Bool) {
        self.reviver = reviver
        self.icon = icon
        self.revivesAt = revivesAt
        self.sessions = sessions
        self.waiting = waiting
        self.later = later
        self.reviveWord = reviveWord
        self.deadWord = deadWord
        self.accent = accent
        self.revived = revived
    }
}

public enum LiveActivityBuilder {
    /// How long a working activity stays fresh without an update.
    public static let workingStale: TimeInterval = 15 * 60

    /// #2's state, or nil when nothing is working (the activity ends).
    /// `textGlyphs`: apply iOS text-presentation to the theme's glyphs —
    /// true whenever the state is bound for a phone, wherever it's built.
    public static func working(fleet: EngineFleet, theme: RowTheme, report: UsageReport?,
                               tokenRate: TokenRate?, textGlyphs: Bool = true) -> WorkingActivityState? {
        let busy = fleet.liveSessions?.busy ?? 0
        guard busy > 0, let active = fleet.accounts.first(where: { $0.active }) else { return nil }
        let glyph = { (s: String) in textGlyphs ? GlyphText.textPresentation(s) : s }
        let windows = windows(active, theme: theme, glyph: glyph)
        return WorkingActivityState(
            active: name(of: active),
            icon: (active.icon ?? (theme.plain || theme.activeIcon.isEmpty ? nil : theme.activeIcon)).map(glyph),
            slot: theme.plain ? "#\(active.number)" : glyph(theme.slotPrefix) + "\(active.number)",
            plan: active.plan.map { theme.plain ? $0 : theme.planLabel($0, compact: true) },
            cash: cash(active, report: report, theme: theme, glyph: glyph),
            windows: windows,
            binding: windows.indices.max { windows[$0].pct < windows[$1].pct },
            busy: busy,
            total: fleet.liveSessions?.total ?? busy,
            waiting: fleet.liveSessions?.waiting ?? 0,
            next: fleet.nextCandidate.flatMap { number in
                fleet.accounts.first { $0.number == number }.map { next in
                    (theme.plain ? "→ " : glyph(theme.nextIcon) + " ") + name(of: next)
                }
            },
            tokensPerMinute: tokenRate.flatMap { $0.perMinute > 0 ? $0.perMinute : nil },
            tokenFraction: tokenRate?.fraction ?? 0,
            accent: theme.flashColor,
            plain: theme.plain,
            rateIcon: theme.rateGlyph.map(glyph),
            rateLabel: theme.rateUnit)
    }

    /// #1's state, or nil when the fleet isn't all-dead (the activity ends
    /// — `revived` is the caller's final frame).
    public static func revival(fleet: EngineFleet, theme: RowTheme, textGlyphs: Bool = true,
                               now: Date = Date()) -> RevivalActivityState? {
        guard fleet.nextCandidate == nil,
              let rec = RecoveryMath.corrected(engine: fleet.nextRecovery, accounts: fleet.accounts,
                                               activeNumber: fleet.activeNumber, now: now),
              let at = WeeklyRoll.parse(rec.at), at > now,
              at <= now.addingTimeInterval(RecoveryMath.plausibleHorizon) else { return nil }
        let glyph = { (s: String) in textGlyphs ? GlyphText.textPresentation(s) : s }
        let account = fleet.accounts.first { $0.number == rec.number }
        return RevivalActivityState(
            reviver: account.map(name(of:)) ?? "#\(rec.number)",
            icon: account?.icon.map(glyph),
            revivesAt: at,
            sessions: fleet.liveSessions?.total ?? 0,
            waiting: fleet.liveSessions?.waiting ?? 0,
            later: laterRevivals(fleet, after: rec.number, now: now),
            reviveWord: theme.plain ? "recovers" : glyph(theme.revivePrefix),
            deadWord: theme.plain ? "limited" : theme.deadVerb,
            accent: theme.flashColor,
            revived: false)
    }

    /// Switch, ≥5-point move of any window, a reset label that rolled,
    /// session counts, or a fifth of the tokens bar — everything else
    /// waits for the next refresh (push budget discipline).
    public static func differs(_ a: WorkingActivityState, _ b: WorkingActivityState) -> Bool {
        var stable = a
        stable.windows = b.windows
        stable.tokensPerMinute = b.tokensPerMinute
        stable.tokenFraction = b.tokenFraction
        if stable != b { return true }
        if (a.tokensPerMinute == nil) != (b.tokensPerMinute == nil)
            || abs(a.tokenFraction - b.tokenFraction) >= 0.2 { return true }
        guard a.windows.count == b.windows.count else { return true }
        return zip(a.windows, b.windows).contains { x, y in
            x.label != y.label || x.reset != y.reset || abs(x.pct - y.pct) >= 5
        }
    }

    // MARK: pieces

    public static func name(of account: Account) -> String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// "💰1,871" — the popup's cash cell, same estimate, same caveat.
    static func cash(_ account: Account, report: UsageReport?, theme: RowTheme,
                     glyph: (String) -> String) -> String? {
        guard !theme.plain,
              let row = report?.accounts.first(where: { $0.number == account.number }) else { return nil }
        return glyph(theme.cashIcon) + Int(row.estimatedUSD).formatted()
    }

    /// The row's windows in popup order — session, weekly, then each
    /// scoped (per-model) one — with the theme's labels and colours.
    static func windows(_ account: Account, theme: RowTheme, glyph: (String) -> String) -> [ActivityWindow] {
        guard let u = account.usage else { return [] }
        var out: [ActivityWindow] = []
        if let w = u.fiveHour {
            out.append(ActivityWindow(label: theme.plain ? "5h" : glyph(theme.sessionLabel),
                                      color: theme.sessionColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        if let w = u.sevenDay {
            out.append(ActivityWindow(label: theme.plain ? "7d" : glyph(theme.weeklyLabel),
                                      color: theme.weeklyColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        for w in u.scoped ?? [] {
            let name = theme.modelName(w.name)
            out.append(ActivityWindow(label: theme.plain ? name : glyph(theme.scopedPrefix) + name,
                                      color: theme.scopedColor, pct: w.pct, reset: ResetLabel.compact(w)))
        }
        return out
    }

    /// The other dead accounts' recovery times after the first reviver,
    /// soonest first — "loc 2:50 PM · P2 Sep 4".
    static func laterRevivals(_ fleet: EngineFleet, after number: Int, now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let rows: [(Date, String)] = fleet.accounts.compactMap { account in
            // The same pick as the headline's, so every surface agrees
            // on who revives when (#226).
            guard account.number != number, account.disabled != true,
                  let at = RecoveryMath.revival(of: account, now: now)?.at, at > now else { return nil }
            let clock = Calendar.current.isDate(at, inSameDayAs: now)
                ? formatter.string(from: at)
                : at.formatted(.dateTime.month(.abbreviated).day())
            return (at, "\(name(of: account)) \(clock)")
        }
        return rows.sorted { $0.0 < $1.0 }.prefix(3).map(\.1)
    }
}

/// Text-vs-emoji presentation for theme glyphs bound for iOS (see
/// InfinitusUI.PopupGlyph, which applies this on the phone and is the
/// identity on the Mac): appends U+FE0E to every emoji-capable scalar
/// that isn't already emoji-presentation, so ⚔ / ⏸ draw as monochrome
/// text on both platforms. Here in Core so the Mac can build phone-bound
/// content with the phone's glyphs.
public enum GlyphText {
    public static func textPresentation(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            out.append(scalar)
            guard scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation else { continue }
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if next?.value != 0xFE0F, next?.value != 0xFE0E {
                out.append(Unicode.Scalar(0xFE0E)!)
            }
        }
        return String(out)
    }
}
