import Foundation
import InfinitusCore
import InfinitusWinUI

/// Account + usage lines for the Infinitus Windows tray.
///
/// Shells `cswap list --json` when claude-swap is installed, with a 30s cache
/// and non-blocking refresh on the tray's 5s timer tick. When Claude Code is
/// routed through 9Router (or cswap isn't installed), the fleets come from
/// `NineRouterFleet` instead — every provider it holds, not just Claude.
/// Every failure yields nil or fallback lines, never throws, and never blocks
/// the UI thread.
enum TrayFleet {
    struct MenuLine: Equatable {
        let text: String
        let enabled: Bool
        /// The account this line switches to when clicked, or nil for a
        /// caption ("refreshing accounts…", "no accounts"). The active
        /// account carries nil too: switching to where you already are is
        /// a no-op the engine would refuse. A fleet HEADER carries nil as
        /// well and is drawn greyed, like the Mac's section header.
        let account: Int?

        init(text: String, enabled: Bool, account: Int? = nil) {
            self.text = text
            self.enabled = enabled
            self.account = account
        }
    }

    /// Cache duration matching CswapFleet (defaults to 30s, configurable via WinSettings).
    nonisolated(unsafe) static var cacheSeconds: TimeInterval = 30
    /// Engine command timeout.
    static let timeout: TimeInterval = 20

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedList: AccountList?
    private nonisolated(unsafe) static var cachedAt: Date?
    private nonisolated(unsafe) static var isRefreshing = false

    /// True when either cswap, 9Router, or CLIProxy is available.
    static func hasEngine() -> Bool {
        CswapLocator.locate() != nil || NineRouterFleet.isAvailable() || CLIProxyFleet.isAvailable()
    }

    /// Which engine this host's Claude Code traffic rides, for the panel
    /// footer and the menu's engine line. nil when nothing is installed.
    /// `routed` is Claude Code's OWN settings naming the engine — read
    /// through Core's `ClaudeCodeRouting`, the same check AppModel makes
    /// on the Mac before it picks 9Router as the primary engine.
    static func engineIndicator() -> FleetPanel.EngineIndicator? {
        let routed = ClaudeCodeRouting.isRouted(ClaudeCodeRouting.anthropicBaseURL(), to: nil)
        if NineRouterFleet.shouldUseNineRouter() {
            return FleetPanel.EngineIndicator(
                name: EngineCatalog.displayName(for: NineRouterEngine.engineID), routed: routed)
        }
        guard CswapLocator.locate() != nil else { return nil }
        // cswap is what swaps the credential, but Claude Code may still
        // be pointed elsewhere — say so rather than claim the traffic.
        return FleetPanel.EngineIndicator(
            name: EngineCatalog.displayName(for: CswapEngine.engineID), routed: false)
    }

    /// Every fleet the active engine reports — several providers when
    /// 9Router is the engine (Claude, Codex, Gemini, Kiro…), one Claude
    /// fleet for cswap. The Mac stacks exactly these (#8 multi-engine).
    static func cachedFleets() -> [EngineFleet] {
        var result: [EngineFleet] = []
        if NineRouterFleet.shouldUseNineRouter(), let fleets = NineRouterFleet.fleets(), !fleets.isEmpty {
            result.append(contentsOf: fleets)
        } else if let list = cached() {
            result.append(EngineFleet(engineID: CswapEngine.engineID, provider: .claude,
                                      accounts: list.accounts,
                                      activeNumber: list.activeAccountNumber,
                                      nextCandidate: list.nextCandidate,
                                      nextRecovery: list.nextRecovery,
                                      liveSessions: list.liveSessions))
        }
        if CLIProxyFleet.isAvailable(), let proxyFleets = CLIProxyFleet.fleets(), !proxyFleets.isEmpty {
            result.append(contentsOf: proxyFleets)
        }
        return result
    }

    /// Account + usage lines for the tray menu, newest data within a cache window.
    /// Format per account: `<icon/alias or email> — <5h%> / <7d%>` with active marked.
    /// With several fleets each gets a greyed `Claude · 9Router` header,
    /// matching the Mac popup's `FleetHeader`.
    /// Summary line when no accounts: "no accounts — `cswap add` registers one".
    static func menuLines() -> [MenuLine] {
        guard hasEngine() else { return [] }
        if NineRouterFleet.shouldUseNineRouter() {
            if let fleets = NineRouterFleet.fleets(), !fleets.isEmpty {
                return formatLines(from: fleets)
            }
            return [MenuLine(text: "refreshing accounts…", enabled: false)]
        }
        lock.lock()
        let list = cachedList
        let at = cachedAt
        lock.unlock()

        if at == nil {
            // Never fetched (or just invalidated): trigger asynchronous
            // fetch so UI does not stall. Stale rows keep rendering
            // meanwhile instead of collapsing to the placeholder.
            refresh()
        }
        return formatLines(from: list ?? (NineRouterFleet.isAvailable() ? NineRouterFleet.list() : nil))
    }

    /// Formats an AccountList (or nil) into menu lines.
    static func formatLines(from list: AccountList?, now: Date = Date()) -> [MenuLine] {
        guard let list else {
            return [MenuLine(text: "refreshing accounts…", enabled: false)]
        }
        return formatLines(from: [EngineFleet(
            engineID: CswapEngine.engineID, provider: .claude, accounts: list.accounts,
            activeNumber: list.activeAccountNumber, nextCandidate: list.nextCandidate,
            nextRecovery: list.nextRecovery, liveSessions: list.liveSessions)], now: now)
    }

    /// Formats every fleet into menu lines. Headers appear only when more
    /// than one fleet has accounts — a single-fleet menu is byte-identical
    /// to the pre-multi-fleet one, exactly as `FleetStack` is on the Mac.
    static func formatLines(from fleets: [EngineFleet], now: Date = Date()) -> [MenuLine] {
        let panel = FleetPanel.panel(fleets: fleets, live: nil, engineInstalled: true, now: now)
        if let empty = panel.empty {
            let text = empty.hasPrefix("No accounts")
                ? "no accounts — `cswap add` registers one" : empty
            return [MenuLine(text: text, enabled: false)]
        }
        // Rows carry no icon (Core's Row is toolkit-free and the Mac draws
        // the icon separately), so the emoji is looked back up per number.
        var iconByKey: [String: String] = [:]
        for fleet in fleets {
            for account in fleet.accounts where !(account.icon ?? "").isEmpty {
                iconByKey["\(fleet.key)#\(account.number)"] = account.icon!
            }
        }
        var out: [MenuLine] = []
        for line in panel.lines {
            switch line {
            case .header(let label):
                out.append(MenuLine(text: label.text, enabled: false))
            case .account(let row):
                let prefix = row.active ? "● " : "  "
                let key = "\(row.engineID)/\(row.provider.rawValue)#\(row.number)"
                let name = iconByKey[key].map { "\($0) \(row.name)" } ?? row.name
                let fullText = "\(prefix)\(name) — \(usageText(row))"
                let clamped = fullText.count > 60 ? String(fullText.prefix(59)) + "…" : fullText
                // Clickable unless it is where we already are, or the
                // engine has it held out of rotation — in both cases a
                // click would only earn a refusal.
                let selectable = !row.active && !row.disabled
                out.append(MenuLine(text: clamped, enabled: selectable,
                                    account: selectable ? row.number : nil))
            }
        }
        return out
    }

    /// `<5h%> / <7d%>` off the shared row's gauges, or `<model>: <pct>%`
    /// for a provider that reports only scoped windows (Gemini/Antigravity
    /// via 9Router). Reads the gauges Core already rolled over, so it can
    /// never disagree with the panel about the same account.
    static func usageText(_ row: FleetPanel.Row) -> String {
        let five = row.gauges.first { $0.label == "5h" }
        let seven = row.gauges.first { $0.label == "7d" }
        if five == nil, seven == nil {
            guard let scoped = row.gauges.first else { return "— / —" }
            return "\(scoped.label): \(Int(scoped.usedPct.rounded()))%"
        }
        let fiveText = five.map { "\(Int($0.usedPct.rounded()))%" } ?? "—"
        let sevenText = seven.map { "\(Int($0.usedPct.rounded()))%" } ?? "—"
        return "\(fiveText) / \(sevenText)"
    }

    // (`formatUsage(_ usage:)` was a second implementation of the weekly
    // roll-over and the scoped-only fallback; `usageText(_ row:)` above
    // reads the gauges Core already computed, so the menu and the panel
    // can no longer disagree.)

    /// Asynchronously refreshes account data if cache expired and no fetch is in flight.
    /// Safe to call on every 5s tray timer tick.
    static func refresh(force: Bool = false, now: Date = Date()) {
        guard hasEngine() else { return }

        // If 9Router should be used, refresh 9Router
        if NineRouterFleet.shouldUseNineRouter() {
            NineRouterFleet.refresh(force: force, now: now)
        }

        lock.lock()
        if isRefreshing {
            lock.unlock()
            return
        }
        if !force, let at = cachedAt, now.timeIntervalSince(at) < cacheSeconds {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        Thread.detachNewThread {
            let fresh = executeRead()
            lock.lock()
            let prevAccounts = cachedList?.accounts ?? []
            if let fresh {
                cachedList = fresh
            }
            cachedAt = Date()
            isRefreshing = false
            lock.unlock()

            if let fresh {
                WinUsageHistoryRecorder.record(accounts: fresh.accounts)
                detectFleetEvents(previous: prevAccounts, current: fresh.accounts)
            }
        }
    }

    /// The cached list as-is, without triggering a fetch — for a second
    /// view (the account panel) that renders the same data the menu does
    /// and must not shell out on its own paint. Stale rows are returned
    /// as-is while the revalidation fetch runs, so the panel never wipes.
    static func cached() -> AccountList? {
        if NineRouterFleet.shouldUseNineRouter(), let nrList = NineRouterFleet.list() {
            return nrList
        }
        lock.lock()
        let list = cachedList
        let at = cachedAt
        lock.unlock()
        if at == nil { refresh() }
        return list ?? (NineRouterFleet.isAvailable() ? NineRouterFleet.list() : nil)
    }

    /// Invalidate cache for manual refresh. KEEPS the last roster — only
    /// the freshness stamp is dropped — so a panel open across a switch
    /// or an edit keeps showing the old rows until the fresh read lands
    /// (stale-while-revalidate). Wiping the list here used to blank the
    /// panel to "Reading accounts…" and repopulate it a beat later.
    /// First-ever load (nothing cached at all) still shows the placeholder.
    static func invalidate() {
        NineRouterFleet.invalidate()
        CLIProxyFleet.invalidate()
        lock.lock()
        defer { lock.unlock() }
        cachedAt = nil
    }

    /// Asks the engine to switch, off the UI thread, then refreshes so the
    /// menu shows the new active account on its next open. `report` is
    /// called with a line fit for a balloon.
    ///
    /// CLAUDE.md: the engine owns account policy. This forwards a click
    /// and reports the engine's answer — including a refusal, verbatim,
    /// rather than a cheerful "switched" the engine never agreed to.
    /// `provider` names WHICH fleet the number belongs to — 9Router's
    /// ordinals are per-provider, so a Gemini row's #2 is not the Claude
    /// fleet's #2. cswap holds Claude only and ignores it.
    static func requestSwitch(to number: Int?, provider: Provider = .claude,
                              engineID: String = "cswap",
                              report: @escaping @Sendable (String) -> Void) {
        guard hasEngine() else {
            report("no swap engine installed")
            return
        }
        Thread.detachNewThread {
            let outcome: SwitchOutcome
            if engineID == "cliproxy", let n = number {
                let proxyOutcome = CLIProxyFleet.switchTo(n, provider: provider)
                switch proxyOutcome {
                case .switched(let num): outcome = .switched(to: num)
                case .noEngine: outcome = .noEngine
                case .failed(let d): outcome = .failed(detail: d)
                }
            } else if engineID == "9router" || NineRouterFleet.shouldUseNineRouter() {
                let nrOutcome = NineRouterFleet.switchTo(number, provider: provider)
                switch nrOutcome {
                case .switched(let n): outcome = .switched(to: n)
                case .noEngine: outcome = .noEngine
                case .failed(let d): outcome = .failed(detail: d)
                }
            } else {
                outcome = switchTo(number)
            }
            if case .switched(let n) = outcome {
                let name = findAccountName(number: n) ?? "\(n)"
                WinEventStore.append(StatsEvent(at: Date(), kind: "switch", icon: "arrow.left.arrow.right", text: "switched to \(name)"))
            }
            invalidate()
            refresh(force: true)
            report(outcome.message)
        }
    }

    private static func findAccountName(number: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let acc = cachedList?.accounts.first(where: { $0.number == number }) {
            return acc.alias ?? acc.email.split(separator: "@").first.map(String.init)
        }
        return nil
    }

    private static func detectFleetEvents(previous: [Account], current: [Account]) {
        guard !previous.isEmpty else { return }
        let prevDead = Set(previous.filter { AccountVitals.isDead($0.usage) }.map(\.email))
        let currDead = Set(current.filter { AccountVitals.isDead($0.usage) }.map(\.email))

        let prevAllDead = !previous.isEmpty && prevDead.count == previous.count
        let currAllDead = !current.isEmpty && currDead.count == current.count

        for acc in current where currDead.contains(acc.email) && !prevDead.contains(acc.email) {
            let name = acc.alias ?? (acc.email.split(separator: "@").first.map(String.init) ?? "account")
            let resetText = acc.usage?.fiveHour?.resetsAt ?? acc.usage?.sevenDay?.resetsAt ?? ""
            let timeStr = WeeklyRoll.parse(resetText).map { _ in ResetLabel.compact(resetsAt: resetText, countdown: nil, now: Date()) ?? "reset" } ?? "reset"
            WinEventStore.append(StatsEvent(at: Date(), kind: "death", icon: "skull", text: "\(name) is out until \(timeStr)"))
        }

        for acc in current where !currDead.contains(acc.email) && prevDead.contains(acc.email) {
            let name = acc.alias ?? (acc.email.split(separator: "@").first.map(String.init) ?? "account")
            WinEventStore.append(StatsEvent(at: Date(), kind: "revival", icon: "sparkles", text: "\(name) is back"))
        }

        if currAllDead && !prevAllDead {
            WinEventStore.append(StatsEvent(at: Date(), kind: "limit", icon: "exclamationmark.triangle", text: "all accounts are out of usage"))
        }
    }

    /// What a switch attempt did. Mirrors the daemon's `CswapFleet` —
    /// separate processes, so the tray runs `cswap` itself rather than
    /// reaching through a daemon that may not be running.
    enum SwitchOutcome {
        case switched(to: Int)
        case noEngine
        case failed(detail: String)

        var message: String {
            switch self {
            case .switched(let number): return "switched to account \(number)"
            case .noEngine: return "no swap engine installed"
            case .failed(let detail):
                return detail.isEmpty ? "engine refused the switch" : detail
            }
        }
    }

    /// Why a `--json` run failed, in the engine's own words.
    ///
    /// cswap reports failures as JSON on STDOUT and leaves stderr empty
    /// (`{"error":{"type":"ConfigError","message":"No accounts are
    /// managed yet"}}`, exit 1 — verified 2026-09-04), so reading stderr
    /// alone shows a bare exit code in the balloon.
    static func failureDetail(output: Data, errors: Data, status: Int32) -> String {
        if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = object["error"] as? String, !message.isEmpty {
                return message
            }
        }
        let text = String(decoding: errors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text.split(separator: "\n").last.map(String.init) ?? text
        }
        return "`cswap switch` exited \(status)"
    }

    /// `cswap switch <n> --json`, or `cswap switch --json` to rotate.
    static func switchTo(_ number: Int?) -> SwitchOutcome {
        guard let binary = CswapLocator.locate() else { return .noEngine }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = number.map { ["switch", String($0), "--json"] } ?? ["switch", "--json"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return .failed(detail: "engine did not run") }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failed(detail: "`cswap switch` timed out")
        }
        guard process.terminationStatus == 0 else {
            return .failed(detail: failureDetail(output: data, errors: errorData,
                                                 status: process.terminationStatus))
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A refusal can ride in the body on exit 0; balloon the reason
        // rather than a "switched" the engine never agreed to.
        if let object, object["error"] != nil {
            return .failed(detail: failureDetail(output: data, errors: errorData, status: 0))
        }
        if let object,
           let active = (object["activeAccountNumber"] as? NSNumber)?.intValue
                     ?? (object["active"] as? NSNumber)?.intValue {
            return .switched(to: active)
        }
        if let number { return .switched(to: number) }
        return .failed(detail: "rotated, but the engine didn't name the account")
    }

    /// Shells out to `cswap list --json` with timeout.
    private static func executeRead() -> AccountList? {
        guard let binary = CswapLocator.locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list", "--json"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        guard (try? process.run()) != nil else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(AccountList.self, from: data)
    }
}
