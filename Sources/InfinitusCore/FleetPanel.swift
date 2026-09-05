import Foundation

// MARK: - One fleet presentation, two frontends
//
// The Mac renders `[EngineFleet]` with SwiftUI (FleetStack → FleetHeader
// + AccountRows); Windows renders the same fleets with owner-drawn GDI
// (FleetWindow) and as a tray menu. SwiftUI, AppKit and UIKit ship only
// in Apple's SDKs, so the VIEWS can't be shared — but every decision
// ABOUT what to show can, and before this file Windows had its own copy
// that only ever knew about a single flattened `AccountList` (no 9Router
// fleets, no provider headers).
//
// So: labels, section order, row naming, death notes, gauges and the
// footer live here, in Core, next to the math they already call
// (`GaugeMath`, `WeeklyRoll`, `ResetLabel`, `AccountVitals`). Both
// frontends read this; neither re-decides it. That is what keeps the
// panel and the popup from disagreeing about the same account.

/// One fleet's header line when several fleets stack — "Claude · 9Router".
/// Core, not InfinitusUI: the Windows panel needs the same label and
/// can't import a SwiftUI target.
public struct FleetLabel: Sendable, Equatable {
    public let engineName: String
    public let provider: Provider
    /// Engine-side honesty note ("round-robin ignores priority tiers").
    public let caveat: String?

    public init(engineName: String, provider: Provider, caveat: String? = nil) {
        self.engineName = engineName
        self.provider = provider
        self.caveat = caveat
    }

    /// The whole header as one string, for a host that draws text rather
    /// than composing views (the Win32 panel, the tray menu). The Mac
    /// builds the same line out of separately-styled `Text`s.
    public var text: String {
        var line = "\(provider.displayName) \u{00B7} \(engineName)"
        if let caveat, !caveat.isEmpty { line += " \u{2014} " + caveat }
        return line
    }
}

/// An engine id's human name. One table, so the Mac popup, the phone's
/// mirror and the Windows panel can't drift into three spellings of
/// "9Router". Engines the caller holds live objects for should prefer
/// `engine.displayName`; this is for the hosts that only ever see an id
/// (a mirrored snapshot, a cached fleet).
///
/// The ids are literals rather than `CswapEngine.engineID` &c. on
/// purpose: `CswapEngine` is `#if !os(iOS)` (it spawns a subprocess) and
/// the phone still has to name the fleets it mirrors.
public enum EngineCatalog {
    public static func displayName(for engineID: String) -> String {
        switch engineID {
        case "cswap": return "cswap"
        case "cliproxy": return "CLIProxyAPI"
        case "9router": return "9Router"
        // The Windows daemon's engine-less fleets (Snapshot.swift): the
        // host runs Claude Code with no swap engine at all.
        case "claude-code-windows": return "Claude Code"
        case "claude-code-windows-9router": return "9Router"
        default: return engineID
        }
    }

    /// What an engine id can do, without instantiating the engine. The
    /// live objects' `capabilities` stay authoritative; this is for the
    /// hosts that only hold an id (the Windows tray, a mirrored snapshot).
    public static func capabilities(for engineID: String) -> EngineCapabilities {
        switch engineID {
        case "cswap": return .all
        case "cliproxy": return [.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer]
        case "9router": return [.switch, .hold, .remove]
        default: return []
        }
    }
}

public extension EngineFleet {
    /// The fleet the chrome, title and switch actions follow: the Claude
    /// one when there is one, else whatever came first. Same rule as the
    /// Mac's `EngineRegistry.primary` minus the routed-engine tiebreak,
    /// which only matters when two engines both report Claude.
    static func primary(of fleets: [EngineFleet]) -> EngineFleet? {
        fleets.first { $0.provider == .claude } ?? fleets.first
    }

    /// The primary fleet as the `AccountList` every pre-multi-engine
    /// consumer decodes (the phone's `listJSON`, the tray's cache).
    /// `liveSessions` overrides the fleet's own when the caller counted
    /// sessions itself.
    static func primaryList(_ fleets: [EngineFleet],
                            liveSessions: LiveSessions? = nil) -> AccountList? {
        guard let fleet = primary(of: fleets) else { return nil }
        return AccountList(schemaVersion: 1,
                           activeAccountNumber: fleet.activeNumber,
                           accounts: fleet.accounts,
                           nextCandidate: fleet.nextCandidate,
                           nextRecovery: fleet.nextRecovery,
                           liveSessions: liveSessions ?? fleet.liveSessions)
    }
}

/// The account panel's CONTENT, decided without touching any UI toolkit.
public enum FleetPanel {
    /// One usage window as a panel draws it: a label, a percentage, a
    /// bar fill, and the reset caption under it.
    public struct Gauge: Equatable, Sendable {
        /// "5h", "7d", or a model's short name.
        public let label: String
        /// Used percentage, as the engine reports it.
        public let usedPct: Double
        /// 0…100 remaining — what the bar actually fills to (HP
        /// semantics: a fresh account shows a full bar).
        public let remaining: Double
        /// "3h 34m·Sep 5 00:30", when the engine gave a reset.
        public let reset: String?
        /// 0…1 how far ahead of pace (the Mac burns the bar for this).
        public let burnHeat: Double
        /// 0…1 how far behind pace.
        public let chill: Double
        /// At or past the limit — drawn in the danger colour.
        public var spent: Bool { usedPct >= 100 }
    }

    /// One account row, tagged with the fleet it came from so a click can
    /// be forwarded to the right engine/provider without the view having
    /// to remember which section it painted.
    public struct Row: Equatable, Sendable {
        public let number: Int
        /// Alias, else the email's local part — the Mac's own choice.
        public let name: String
        public let email: String
        public let active: Bool
        /// Held out of auto-rotation (`cswap disable`).
        public let disabled: Bool
        /// Every window this account can't work in is spent.
        public let dead: Bool
        /// Why it is dead, in the engine's terms ("5h spent").
        public let deadNote: String?
        public let gauges: [Gauge]
        public let engineID: String
        public let provider: Provider
    }

    /// One fleet's rows under its header.
    public struct Section: Equatable, Sendable {
        /// `EngineFleet.key` — "9router/gemini".
        public let key: String
        public let label: FleetLabel
        public let activeNumber: Int?
        public let rows: [Row]
    }

    /// What a text/GDI host paints top to bottom. A header appears only
    /// when several fleets stack, so a single-fleet panel is exactly the
    /// pre-multi-fleet one — the Mac's `FleetStack` rule, verbatim.
    public enum Line: Equatable, Sendable {
        case header(FleetLabel)
        case account(Row)
    }

    /// Which engine the host's Claude Code traffic actually rides, for
    /// the footer badge. `routed` means Claude Code's own
    /// `env.ANTHROPIC_BASE_URL` names it (ClaudeCodeRouting).
    public struct EngineIndicator: Equatable, Sendable {
        public let name: String
        public let routed: Bool

        public init(name: String, routed: Bool) {
            self.name = name
            self.routed = routed
        }

        public var text: String { routed ? "\(name) \u{00B7} routed" : name }
    }

    /// The whole panel.
    public struct Panel: Equatable, Sendable {
        public let sections: [Section]
        /// Engine + session summary for the footer.
        public let footer: String
        /// Nothing to show, and why — an absent engine is not an error.
        public let empty: String?
        public let engine: EngineIndicator?

        public init(sections: [Section] = [], footer: String = "",
                    empty: String? = nil, engine: EngineIndicator? = nil) {
            self.sections = sections
            self.footer = footer
            self.empty = empty
            self.engine = engine
        }

        /// Every row across every section, in paint order.
        public var rows: [Row] { sections.flatMap(\.rows) }
        /// The primary fleet's active account — what a single-fleet host
        /// used to read off the `AccountList`.
        public var activeNumber: Int? { sections.first?.activeNumber }

        /// Headers + rows interleaved. Headers only when more than one
        /// section has anything to show.
        public var lines: [Line] {
            let showHeaders = sections.filter { !$0.rows.isEmpty }.count > 1
            var out: [Line] = []
            for section in sections {
                if showHeaders { out.append(.header(section.label)) }
                out.append(contentsOf: section.rows.map(Line.account))
            }
            return out
        }
    }

    /// Build the panel from every fleet the host's engines reported.
    /// `now` is injected so the countdown strings are testable.
    ///
    /// `engineInstalled` false is the "no swap engine on this box" case,
    /// which is a normal state with its own copy, not an error.
    public static func panel(fleets: [EngineFleet], live: LiveSessions?,
                             engineInstalled: Bool,
                             engine: EngineIndicator? = nil,
                             caveats: [String: String] = [:],
                             now: Date = Date()) -> Panel {
        guard engineInstalled else {
            return Panel(sections: [], footer: footer(live: live, accounts: 0, engine: engine),
                         empty: "No swap engine installed. "
                              + "`uv tool install claude-swap` adds one.",
                         engine: engine)
        }
        let sections = fleets.map { fleet in
            section(fleet, caveat: caveats[fleet.engineID], now: now)
        }
        let accounts = sections.reduce(0) { $0 + $1.rows.count }
        guard accounts > 0 else {
            return Panel(sections: [], footer: footer(live: live, accounts: 0, engine: engine),
                         empty: fleets.isEmpty
                             ? "Reading accounts\u{2026}"
                             : "No accounts yet \u{2014} `cswap add` registers "
                               + "the one you are logged into.",
                         engine: engine)
        }
        return Panel(sections: sections,
                     footer: footer(live: live, accounts: accounts, engine: engine),
                     empty: nil, engine: engine)
    }

    /// Single-fleet convenience for a host that only has a `cswap list
    /// --json` payload (the panel's `INFINITUS_ACCOUNTS_JSON` fixture,
    /// an older mirror).
    public static func panel(list: AccountList?, live: LiveSessions?,
                             engineInstalled: Bool,
                             engineID: String = "cswap",
                             engine: EngineIndicator? = nil,
                             now: Date = Date()) -> Panel {
        guard let list else {
            return panel(fleets: [], live: live, engineInstalled: engineInstalled,
                         engine: engine, now: now)
        }
        let fleet = EngineFleet(engineID: engineID, provider: .claude,
                                accounts: list.accounts,
                                activeNumber: list.activeAccountNumber,
                                nextCandidate: list.nextCandidate,
                                nextRecovery: list.nextRecovery,
                                liveSessions: list.liveSessions)
        return panel(fleets: [fleet], live: live, engineInstalled: engineInstalled,
                     engine: engine, now: now)
    }

    public static func section(_ fleet: EngineFleet, caveat: String? = nil,
                               now: Date = Date()) -> Section {
        Section(key: fleet.key,
                label: FleetLabel(engineName: EngineCatalog.displayName(for: fleet.engineID),
                                  provider: fleet.provider, caveat: caveat),
                activeNumber: fleet.activeNumber,
                rows: fleet.accounts.map {
                    row($0, active: fleet.activeNumber, engineID: fleet.engineID,
                        provider: fleet.provider, now: now)
                })
    }

    public static func row(_ account: Account, active: Int?, engineID: String,
                           provider: Provider, now: Date) -> Row {
        let isActive = account.active || (active != nil && account.number == active)
        // The Mac's display name: alias if set, else the local part of
        // the address (AccountCells.displayName).
        let name: String = {
            if let alias = account.alias, !alias.isEmpty { return alias }
            return String(account.email.prefix(while: { $0 != "@" }))
        }()
        let cause = AccountVitals.cause(account.usage)
        return Row(number: account.number, name: name, email: account.email,
                   active: isActive, disabled: account.disabled ?? false,
                   dead: AccountVitals.isDead(account.usage),
                   deadNote: cause.map { deadNote($0) },
                   gauges: gauges(account.usage, now: now),
                   engineID: engineID, provider: provider)
    }

    /// "5h spent", "7d spent" — short enough for a row that already
    /// carries two bars.
    public static func deadNote(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "5h spent"
        case .weekly: return "7d spent"
        case .scoped: return "\(cause.name ?? "model") spent"
        case .credit: return "credit spent"
        }
    }

    /// The 5h and 7d windows, then any per-model windows the engine
    /// reported — the same order the Mac's grid uses.
    public static func gauges(_ usage: Usage?, now: Date) -> [Gauge] {
        guard let usage else { return [] }
        var out: [Gauge] = []
        if let five = usage.fiveHour {
            out.append(gauge(five, label: "5h", now: now))
        }
        if let seven = usage.sevenDay {
            // The weekly window rolls: after its reset instant the
            // engine's own pct is stale until the next poll, and
            // WeeklyRoll is what the Mac uses to show 0 instead.
            let pct = WeeklyRoll.displayPct(seven, now: now) ?? seven.pct
            out.append(gauge(seven, label: "7d", overridePct: pct, now: now))
        }
        for scoped in usage.scoped ?? [] {
            let pct = WeeklyRoll.displayPct(scoped, now: now) ?? scoped.pct
            out.append(gauge(scoped, label: scoped.name ?? "model", overridePct: pct, now: now))
        }
        return out
    }

    public static func gauge(_ window: UsageWindow, label: String,
                             overridePct: Double? = nil, now: Date) -> Gauge {
        let pct = overridePct ?? window.pct
        return Gauge(
            label: label,
            usedPct: pct,
            remaining: GaugeMath.remaining(usedPct: pct),
            reset: ResetLabel.compact(resetsAt: window.resetsAt,
                                      countdown: window.countdown, now: now),
            burnHeat: GaugeMath.burnHeat(usedPct: pct,
                                         expectedPct: window.expectedPct,
                                         ahead: window.aheadOfPace),
            chill: GaugeMath.chillDepth(usedPct: pct,
                                        expectedPct: window.expectedPct,
                                        ahead: window.aheadOfPace))
    }

    /// "7 sessions · 1 busy · 2 accounts · 9Router · routed".
    public static func footer(live: LiveSessions?, accounts: Int,
                              engine: EngineIndicator? = nil) -> String {
        var parts: [String] = []
        if let live {
            parts.append("\(live.total) session\(live.total == 1 ? "" : "s")")
            if live.busy > 0 { parts.append("\(live.busy) busy") }
            if let waiting = live.waiting, waiting > 0 { parts.append("\(waiting) waiting") }
        }
        if accounts > 0 {
            parts.append("\(accounts) account\(accounts == 1 ? "" : "s")")
        }
        if let engine { parts.append(engine.text) }
        return parts.isEmpty ? "no sessions" : parts.joined(separator: " \u{00B7} ")
    }
}
