import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif
import InfinitusCore

// The Omarchy/Linux face of Infinitus: a Waybar `custom` module
// (`return-type: json`) over the same InfinitusCore the macOS app uses.
// Everything engine-side stays behind `swapd … --json` subprocesses —
// the architecture rule holds on both OSes. packaging/omarchy carries
// the module config; `status` is the interval exec, `rotate` the click.

/// Waybar custom-module payload (one line of JSON on stdout).
struct WaybarPayload: Encodable {
    let text: String
    let tooltip: String
    let `class`: String
    let percentage: Int?
}

// Structured feed for the Quickshell panel (`panel` command). Themed
// strings are rendered here so QML stays a dumb renderer; pcts stay raw
// numbers so the gauges can draw. NOT pango-escaped — this is data, not
// Waybar markup.
struct PanelWindow: Encodable {
    let label: String
    let pct: Int          // used, 0–100
    let reset: String?
    /// Behind-pace glow 0…1 (GaugeMath.chillDepth); omitted when calm.
    let chill: Double?
}

struct PanelAccount: Encodable {
    let number: Int
    let name: String
    let plan: String?     // themed plan label
    let marker: String
    let active: Bool
    let disabled: Bool
    let isNext: Bool
    let note: String?     // sentinel (relogin etc.), themed
    let deadLine: String? // themed "☠ fallen — 🩸 2h 25m"
    /// Binding window in the 90s (alive): the panel row flashes.
    let critical: Bool
    let windows: [PanelWindow]
}

struct PanelTheme: Encodable {
    let id: String
    let name: String
}

/// Footer chips (#9 parity — the macOS popup's FooterChips): Anthropic
/// service status, live-session counts, the auto-switch engine badge.
/// All optional on `PanelPayload` so an older panel that ignores them
/// still decodes.
struct PanelServiceStatus: Encodable {
    let indicator: String   // none | minor | major | critical | unknown
    let word: String
}

struct PanelSessionsChip: Encodable {
    let busy: Int
    let total: Int
}

struct PanelEngine: Encodable {
    let running: Bool
    let word: String   // "auto" | "off" — the mac's EngineBadgeText wording
}

/// Present only when EVERY account is at a limit: the account that
/// recovers first (raw ISO instant — the panel ticks the countdown
/// itself) and how many limit-stopped sessions wait to be resumed.
struct PanelRecovery: Encodable {
    let number: Int
    let at: String
}

/// A phone on the mirror (#9 parity with the Mac's device list).
struct PanelDevice: Encodable {
    let name: String
    let route: String
    let secondsAgo: Int
    let active: Bool
}

struct PanelPayload: Encodable {
    let schemaVersion: Int
    let themeId: String
    let title: String       // bar-style active line for the panel header
    let sessionsLine: String?
    let activeNumber: Int?
    let accounts: [PanelAccount]
    let themes: [PanelTheme]
    let nextRecovery: PanelRecovery?
    /// Footer chips (#9 parity), all nil in the error path.
    let serviceStatus: PanelServiceStatus?
    let sessionsChip: PanelSessionsChip?
    let engine: PanelEngine?
    /// Phones heard from by `serve`, newest first; additive field.
    let devices: [PanelDevice]
    let error: String?
}

@main
struct InfinitusTray {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "status" : args.removeFirst()
        var themeID = "off"
        var remaining = false
        var engineOrder = false
        var port: UInt16 = MirrorTransport.defaultPort
        var token: String?
        var tokenFile: String?
        var interval: UInt64 = 30
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--theme" where i + 1 < args.count:
                themeID = args[i + 1]
                i += 1
            case "--remaining":
                remaining = true
            case "--engine-order":
                engineOrder = true
            case "--port" where i + 1 < args.count:
                guard let parsed = UInt16(args[i + 1]) else { fail("--port needs a number") }
                port = parsed
                i += 1
            case "--token" where i + 1 < args.count:
                token = args[i + 1]
                i += 1
            case "--token-file" where i + 1 < args.count:
                tokenFile = args[i + 1]
                i += 1
            case "--interval" where i + 1 < args.count:
                guard let parsed = UInt64(args[i + 1]) else { fail("--interval needs a number") }
                interval = parsed
                i += 1
            case let a where !a.hasPrefix("-"):
                positional.append(a)
            default:
                fail("unknown option: \(args[i])")
            }
            i += 1
        }
        switch command {
        case "status":
            await status(themeID: themeID, remaining: remaining)
        case "panel":
            await panel(themeID: themeID, engineOrder: engineOrder)
        case "rotate":
            await rotate()
        case "switch":
            await switchTo(positional.first)
        case "disable", "enable":
            await setRotation(positional.first, enabled: command == "enable")
        case "themes":
            for theme in RowTheme.builtins {
                print("\(theme.id)\t\(theme.name)")
            }
        case "serve":
            await serve(port: port, token: token, tokenFile: tokenFile, themeID: themeID, interval: interval)
        case "pair":
            pair(port: port)
        case "help", "--help", "-h":
            print(help)
        default:
            fail("unknown command: \(command)\n\(help)")
        }
    }

    static let help = """
    infinitus-tray — Waybar module for the claude-swap fleet (Omarchy/Linux)

      status [--theme ID] [--remaining]   Waybar JSON: active account + fleet tooltip
      panel [--theme ID] [--engine-order] structured fleet JSON for the Quickshell panel
      rotate                              switch to the next account
      switch <n>                          switch to account n
      disable <n> / enable <n>            hold an account out of rotation / return it
      themes                              list built-in theme ids
      serve [--port N] [--token T|--token-file PATH] [--interval S]
                                           phone companion: serve the fleet snapshot
                                           over HTTP (Linux only); also ticks the
                                           away-push triggers (#13 parity) every S
                                           seconds (default 30) — env vars
                                           INFINITUS_PUSH_ALL_DEAD/LAST_ALIVE
                                           (default on) gate them
      pair [--port N]                     print the pair URL (+ QR if qrencode is on PATH)

    Wire-up (packaging/omarchy/waybar-infinitus.jsonc):
      "custom/infinitus": exec `infinitus-tray status --theme rpg`,
      on-click `infinitus-tray rotate && pkill -RTMIN+8 waybar`.
    """

    static let swapdInstall = "cargo install --git https://github.com/deathemperor/swapd swapd"

    /// The Claude fleet off one `swapd list --json` (#756): the provider's
    /// view through the same SwapdMapping the Mac uses, the live Claude
    /// Code sessions attached (swapd knows nothing about them), packed as
    /// the AccountList this file renders — and its bytes, which are what
    /// the mirror hands the phone. No Claude provider, or one with no
    /// accounts, is an empty fleet, not an error: the onboarding branch.
    static func fleet(bin: String, now: Date = Date()) async throws -> (AccountList, Data) {
        let swapd = try await SwapdCLI(binaryPath: bin).list()
        let view = swapd.providers.first { SwapdMapping.provider(for: $0.provider) == .claude }
        let mapped = view.map { SwapdMapping.fleet(from: $0, provider: .claude, now: now) }
        let list = AccountList(
            activeAccountNumber: mapped?.activeNumber, accounts: mapped?.accounts ?? [],
            nextCandidate: mapped?.nextCandidate, nextRecovery: mapped?.nextRecovery,
            liveSessions: LiveSessions(records: ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())))
        return (list, (try? JSONEncoder().encode(list)) ?? Data())
    }

    // MARK: status

    static func status(themeID: String, remaining: Bool) async {
        guard let bin = SwapdLocator.locate() else {
            emit(WaybarPayload(
                text: "\(TitleFormatter.icon) no swapd",
                tooltip: "swapd not found — install it:\n\(swapdInstall)",
                class: "error", percentage: nil))
            return
        }
        let theme = RowTheme.builtins.first { $0.id == themeID } ?? .off
        do {
            let (list, raw) = try await fleet(bin: bin)
            // Utilization history rides the Waybar heartbeat — one
            // append per fresh engine usage poll (todo 2026-09-01).
            TrayHistory.record(accounts: list.accounts, enginePath: bin)
            // Fleet mirror export (#9 phase 1 parity — macOS's
            // MirrorExporter). Own throttle, own demo-swapd gate.
            let footer = await FooterState.current()
            TrayMirror.export(raw: raw,
                              enginePath: bin, prefs: FleetPrefs(themeID: theme.id),
                              serviceStatus: footer.serviceStatus, engine: footer.engine)
            // Engine installed, fleet empty: a bare glyph with no
            // tooltip reads as broken — onboard instead.
            guard !list.accounts.isEmpty else {
                // Onboarding parity with the macOS FirstAccountCard
                // (todo 2026-09-01): name the login `swapd add` adopts.
                var tip = "the engine has no accounts yet — "
                let claude = ClaudeCLIDetect.info()
                if let email = claude.email {
                    tip += "Claude Code is signed in as \(email); "
                        + "adopt it with:\nswapd add"
                } else {
                    tip += "sign in with Claude Code, then:\nswapd add"
                }
                emit(WaybarPayload(
                    text: "\(TitleFormatter.icon) no accounts",
                    tooltip: tip,
                    class: "warning", percentage: nil))
                return
            }
            let now = Date()
            let active = list.accounts.first { $0.active }
            let prefs = TitlePrefs(showAccountName: true, titlePct: "both",
                                   titleScoped: false, titleRemaining: remaining,
                                   titleReset: "countdown")
            let recovery = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts, activeNumber: list.activeAccountNumber)
            let rows = list.accounts.map { row($0, list: list, recovery: recovery, theme: theme, now: now) }
            var tooltip = rows.joined(separator: "\n")
            if let live = list.liveSessions {
                tooltip += "\n" + SessionSummary.tooltip(live)
            }
            let cls: String
            if let active, AccountVitals.isDead(active.usage) { cls = "dead" }
            else if let active, active.usageStatus != "ok" { cls = "warning" }
            else { cls = "ok" }
            emit(WaybarPayload(
                text: TitleFormatter.format(account: active, prefs: prefs, now: now),
                tooltip: tooltip,
                class: cls,
                percentage: (active?.usage?.fiveHour?.pct).map { Int($0.rounded()) }))
        } catch {
            emit(WaybarPayload(
                text: "\(TitleFormatter.icon) engine error",
                tooltip: pango("\(error)"), class: "error", percentage: nil))
        }
    }

    /// One themed fleet line: marker, slot, name, plan, then either the
    /// sentinel note, the dead cause + revive reset, or the usage windows.
    ///
    /// `recovery` is the corrected next-recovery (RecoveryMath), not
    /// `list.nextRecovery` verbatim — the engine's advisory skips the
    /// active account, which misnames the reviver when the active one is
    /// both dead and soonest (user report 2026-09-02).
    static func row(_ a: Account, list: AccountList, recovery: NextRecovery?, theme: RowTheme, now: Date) -> String {
        let name = a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
        let marker: String
        if a.active { marker = theme.activeIcon.isEmpty ? "●" : theme.activeIcon }
        else if a.number == list.nextCandidate { marker = theme.nextIcon.isEmpty ? "▶" : theme.nextIcon }
        // All limited: hollow marker on the first to recover (the macOS
        // popup's gray/orange triangle).
        else if list.nextCandidate == nil, a.number == recovery?.number { marker = "▷" }
        else { marker = "·" }
        var parts = ["\(marker) \(theme.slotPrefix)\(a.number) \(name)"]
        if let plan = a.plan { parts.append(theme.planLabel(plan, compact: true)) }
        if let note = SentinelNotes.short(for: a.usageStatus) {
            parts.append(note)
        } else if let cause = AccountVitals.cause(a.usage) {
            var s = "\(theme.deadMarker) \(theme.deadVerb)"
            if let reset = ResetLabel.label(resetsAt: cause.resetsAt,
                                           countdown: cause.countdown,
                                           clock: cause.clock, now: now) {
                s += " — \(theme.revivePrefix)\(reset)"
            }
            parts.append(s)
        } else {
            if let w = a.usage?.fiveHour {
                var s = "\(theme.sessionLabel) \(Int(w.pct.rounded()))%"
                if let r = ResetLabel.short(w, now: now) { s += " (\(r))" }
                parts.append(s)
            }
            if let w = a.usage?.sevenDay, let pct = WeeklyRoll.displayPct(w, now: now) {
                var s = "\(theme.weeklyLabel) \(Int(pct.rounded()))%"
                if let r = ResetLabel.compact(w, now: now) { s += " (\(r))" }
                parts.append(s)
            }
            for w in a.usage?.scoped ?? [] {
                guard let pct = WeeklyRoll.displayPct(w, now: now) else { continue }
                parts.append("\(theme.scopedPrefix)\(theme.modelName(w.name)) \(Int(pct.rounded()))%")
            }
        }
        return parts.joined(separator: "  ")
    }

    // MARK: panel

    /// Structured fleet JSON for the Quickshell popup panel.
    static func panel(themeID: String, engineOrder: Bool = false) async {
        let theme = RowTheme.builtins.first { $0.id == themeID } ?? .off
        let themes = RowTheme.builtins.map { PanelTheme(id: $0.id, name: $0.name) }
        func emitError(_ message: String) {
            emitPanel(PanelPayload(
                schemaVersion: 1, themeId: theme.id,
                title: "\(TitleFormatter.icon) \(message)", sessionsLine: nil,
                activeNumber: nil, accounts: [], themes: themes,
                nextRecovery: nil,
                serviceStatus: nil, sessionsChip: nil, engine: nil, devices: [], error: message))
        }
        guard let bin = SwapdLocator.locate() else {
            emitError("swapd not found")
            return
        }
        do {
            let now = Date()
            let (list, raw) = try await fleet(bin: bin, now: now)
            let active = list.accounts.first { $0.active }
            let prefs = TitlePrefs(showAccountName: true, titlePct: "both",
                                   titleScoped: false, titleRemaining: false,
                                   titleReset: "countdown")
            // Display order (todo 2026-09-01, matches the macOS popup):
            // active, next candidate, then most headroom first —
            // display-only, engine slots untouched. --engine-order opts out.
            let ordered = engineOrder ? list.accounts
                : DisplayOrder.sort(list.accounts,
                                    active: active?.number,
                                    next: list.nextCandidate)
            // Corrected, not the engine's verbatim value: its advisory
            // skips the active account, which misnames the reviver when
            // the active one is both dead and soonest (2026-09-02).
            let recovery = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts, activeNumber: list.activeAccountNumber)
            let accounts = ordered.map { a -> PanelAccount in
                let name = a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
                let marker: String
                if a.active { marker = theme.activeIcon.isEmpty ? "●" : theme.activeIcon }
                else if a.number == list.nextCandidate { marker = theme.nextIcon.isEmpty ? "▶" : theme.nextIcon }
                else if list.nextCandidate == nil, a.number == recovery?.number { marker = "▷" }
                else { marker = "·" }
                var note: String?
                var deadLine: String?
                var deadBySession = false
                var critical = false
                var windows: [PanelWindow] = []
                if let s = SentinelNotes.short(for: a.usageStatus) {
                    note = s
                } else if let cause = AccountVitals.cause(a.usage) {
                    deadBySession = cause.kind == .session
                    var s = "\(theme.deadMarker) \(theme.deadVerb)"
                    if let reset = ResetLabel.label(resetsAt: cause.resetsAt,
                                                   countdown: cause.countdown,
                                                   clock: cause.clock, now: now) {
                        s += " — \(theme.revivePrefix)\(reset)"
                    }
                    deadLine = s
                } else if (PushTriggers.worstPlanPct(a.usage) ?? 0) >= 90 {
                    // Dying flash (user 2026-09-01): alive, binding
                    // window in the 90s.
                    critical = true
                }
                func paceChill(_ w: UsageWindow) -> Double? {
                    let c = GaugeMath.chillDepth(usedPct: w.pct,
                                                 expectedPct: w.expectedPct,
                                                 ahead: w.aheadOfPace)
                    return c > 0 ? c : nil
                }
                if let w = a.usage?.fiveHour, !deadBySession {
                    // The 5h bar stays calm on macOS too — pace effects
                    // are weekly/model signals. Dead-by-5h drops it: the
                    // death line IS the 5h story (user 2026-09-01).
                    windows.append(PanelWindow(label: theme.sessionLabel,
                                               pct: Int(w.pct.rounded()),
                                               reset: ResetLabel.short(w, now: now),
                                               chill: nil))
                }
                if let w = a.usage?.sevenDay, let pct = WeeklyRoll.displayPct(w, now: now) {
                    // Dead-by-5h keeps the weekly gauge, skips its timer.
                    windows.append(PanelWindow(label: theme.weeklyLabel,
                                               pct: Int(pct.rounded()),
                                               reset: deadBySession ? nil
                                                   : ResetLabel.compact(w, now: now),
                                               chill: paceChill(w)))
                }
                for w in a.usage?.scoped ?? [] {
                    guard let pct = WeeklyRoll.displayPct(w, now: now) else { continue }
                    windows.append(PanelWindow(
                        label: "\(theme.scopedPrefix)\(theme.modelName(w.name))",
                        pct: Int(pct.rounded()), reset: nil,
                        chill: paceChill(w)))
                }
                return PanelAccount(
                    number: a.number, name: name,
                    plan: a.plan.map { theme.planLabel($0, compact: true) },
                    marker: marker, active: a.active,
                    disabled: a.disabled ?? false,
                    isNext: a.number == list.nextCandidate,
                    note: note, deadLine: deadLine, critical: critical,
                    windows: windows)
            }
            // All-limited: the engine names the first account to recover.
            var panelRecovery: PanelRecovery?
            if list.nextCandidate == nil, let rec = recovery {
                panelRecovery = PanelRecovery(number: rec.number, at: rec.at)
            }
            // Fleet mirror export (#9 phase 1 parity — macOS's
            // MirrorExporter). Shares the throttle sidecar with status().
            let footer = await FooterState.current(now: now)
            TrayMirror.export(raw: raw, enginePath: bin,
                              prefs: FleetPrefs(themeID: theme.id, sortByHeadroom: !engineOrder),
                              serviceStatus: footer.serviceStatus, engine: footer.engine, now: now)
            emitPanel(PanelPayload(
                schemaVersion: 1, themeId: theme.id,
                title: list.accounts.isEmpty
                    ? "\(TitleFormatter.icon) no accounts — swapd add"
                    : TitleFormatter.format(account: active, prefs: prefs, now: now),
                sessionsLine: list.liveSessions.map { SessionSummary.tooltip($0) },
                activeNumber: active?.number, accounts: accounts,
                themes: themes, nextRecovery: panelRecovery,
                serviceStatus: footer.panelStatus,
                sessionsChip: list.liveSessions.map { PanelSessionsChip(busy: $0.busy, total: $0.total) },
                engine: footer.panelEngine, devices: TrayClients.panelDevices(now: now), error: nil))
        } catch {
            emitError("engine error: \(error)")
        }
    }

    static func emitPanel(_ payload: PanelPayload) {
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: rotate / switch

    static func switchTo(_ arg: String?) async {
        guard let arg, let n = Int(arg) else { fail("usage: infinitus-tray switch <n>") }
        guard let bin = SwapdLocator.locate() else { fail("swapd not found") }
        do {
            _ = try await SwapdCLI(binaryPath: bin).switchTo(provider: .claude, slot: n)
            print("switched to \(n)")
        } catch {
            fail("switch failed: \(error)")
        }
    }

    static func setRotation(_ arg: String?, enabled: Bool) async {
        let verb = enabled ? "enable" : "disable"
        guard let arg, let n = Int(arg) else { fail("usage: infinitus-tray \(verb) <n>") }
        guard let bin = SwapdLocator.locate() else { fail("swapd not found") }
        do {
            // swapd's knob is the hold: held = out of the rotation.
            _ = try await SwapdCLI(binaryPath: bin).setHold(provider: .claude, slot: n, held: !enabled)
            print("\(verb)d \(n)")
        } catch {
            fail("\(verb) failed: \(error)")
        }
    }

    static func rotate() async {
        guard let bin = SwapdLocator.locate() else { fail("swapd not found") }
        do {
            _ = try await SwapdCLI(binaryPath: bin).rotate(provider: .claude)
            print("rotated")
        } catch {
            fail("rotate failed: \(error)")
        }
    }

    // MARK: serve / pair (#9 phone companion, Linux side)

    /// One collection pass, independent of `panel`/`status`'s stdout
    /// paths — always produces *some* snapshot, even with no `swapd` on
    /// the box: `serve` in a container with no engine installed answers
    /// `/snapshot` with an empty fleet rather than crashing. Returns the
    /// decoded list (nil when `swapd` is missing or the fetch failed) so
    /// `serve`'s loop can tick `PushTriggers` off the same fetch instead
    /// of paying for a second `swapd list --json`.
    @discardableResult
    static func collectAndExport(themeID: String, now: Date = Date()) async -> AccountList? {
        var raw = Data(#"{"schemaVersion":1,"accounts":[]}"#.utf8)
        var list: AccountList?
        let bin = SwapdLocator.locate()
        if let bin, let (fetched, rawData) = try? await fleet(bin: bin, now: now) {
            list = fetched
            raw = rawData
        }
        let footer = await FooterState.current(now: now)
        TrayMirror.export(raw: raw, enginePath: bin ?? "",
                          prefs: FleetPrefs(themeID: themeID),
                          serviceStatus: footer.serviceStatus, engine: footer.engine, now: now)
        return list
    }

    /// Env-var flags for `serve`'s push triggers (#13 parity, Linux side)
    /// — the tray has no settings file, and `INFINITUS_SWAPD_CLI` already
    /// sets the precedent of env as the tray's config channel. Default
    /// on, same as the Mac app's toggles.
    static func pushFlagsFromEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> PushTriggers.Flags {
        func on(_ name: String) -> Bool {
            guard let v = env[name] else { return true }
            return !["0", "false", "off"].contains(v.lowercased())
        }
        return .init(allDead: on("INFINITUS_PUSH_ALL_DEAD"),
                     lastAlive: on("INFINITUS_PUSH_LAST_ALIVE"))
    }

    /// One `PushTriggers` tick off a freshly-collected list — mirrors
    /// `AppModel.refreshSnapshot`'s block verbatim (same account health
    /// mapping, same `liveSessions.sessions`). Only `serve` calls this:
    /// it runs a persistent process, unlike `status`/`panel` which are
    /// one-shot waybar/quickshell execs with no state to carry a
    /// multi-tick episode (e.g. the two-quiet-ticks "sessions finished"
    /// rule) across.
    static func tickPushes(list: AccountList?, pushes box: PushBox,
                           flags: PushTriggers.Flags) async {
        let health = (list?.accounts ?? [])
            .filter { !($0.disabled ?? false) && $0.usage != nil }
            .map { a in PushTriggers.Account(
                number: a.number,
                name: a.alias ?? String(a.email.prefix(while: { $0 != "@" })),
                dead: AccountVitals.isDead(a.usage),
                worstPct: PushTriggers.worstPlanPct(a.usage)) }
        let pushes = box.with { $0.tick(accounts: health, flags: flags) }
        for msg in pushes { await deliverPush(msg) }
    }

    /// One push, every way this box can deliver it: the desktop's
    /// notify-send.
    static func deliverPush(_ msg: String) async {
        logPhoneInput("🔔 \(msg)")
        if let notifySend = which("notify-send") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: notifySend)
            process.arguments = ["Infinitus", msg]
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// The descriptor's `machineId` (#486): systemd's stable per-machine id
    /// where one exists — no daemon of its own to persist a minted one in,
    /// unlike the Mac's `MachineIdentity` (UserDefaults) or the tray's own
    /// pairing token (a 0600 file, `PairingStore`).
    static func machineIdentity(path: String = "/etc/machine-id") -> String {
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ProcessInfo.processInfo.hostName
    }

    // MARK: #486 slice 3 — the control socket
    //
    // Same rule as the slice 2 routes above: the work lives in plain funcs
    // out here (type-checked by a Mac build too), `serve` only binds the
    // socket and hands `ControlDispatch` these handlers.

    /// `infinitusctl status` against the tray: enough to prove whose
    /// socket answered and that it can see this box's sessions.
    static func controlStatus(appVersion: String = BuiltVersion.string) -> JSONValue {
        let sessions = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).count
        return .object(["platform": .string("linux"),
                        "version": .string(appVersion),
                        "sessions": .number(Double(sessions))])
    }

    static func controlHandlers() -> ControlDispatch.Handlers {
        ControlDispatch.Handlers(status: { controlStatus() })
    }

    /// `serve`'s push state, shared between its tick and the control
    /// socket's thread (a hook's push, #486): mutations run under the
    /// lock, delivery outside it.
    final class PushBox: @unchecked Sendable {
        private let lock = NSLock()
        private var triggers = PushTriggers()
        func with<T>(_ body: (inout PushTriggers) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&triggers)
        }
    }

    static func serve(port: UInt16, token: String?, tokenFile: String?, themeID: String,
                      interval: UInt64 = 30) async {
        #if canImport(Glibc)
        let resolved: String
        if let token, !token.isEmpty {
            resolved = MirrorPairing.normalize(token)
        } else if let tokenFile {
            guard let contents = try? String(contentsOfFile: tokenFile, encoding: .utf8) else {
                fail("--token-file \(tokenFile): couldn't read")
            }
            resolved = MirrorPairing.normalize(contents)
        } else {
            resolved = PairingStore.loadOrCreate()
        }
        guard !resolved.isEmpty else { fail("serve: empty pairing token") }
        let pushes = PushBox()
        let pushFlags = pushFlagsFromEnv()
        // The first request must not 503 while the first 30s tick is
        // still pending. This first tick also seeds PushTriggers: a
        // session already `waiting` at launch is not news (same rule
        // as the Mac — PushTriggers.seededWaiting).
        let firstList = await collectAndExport(themeID: themeID)
        await tickPushes(list: firstList, pushes: pushes, flags: pushFlags)
        // `GET /.well-known/infinitus` (#486 slice 1+2): what this tray
        // serves, read before pairing, same as the Mac's descriptor
        // (`MirrorServer.descriptor`, #223 phase 4) — unauthenticated by
        // design, so it never changes and is built once up front.
        //
        let descriptorBody = (try? JSONEncoder().encode(MirrorDescriptor.tray(
            machineId: machineIdentity(), label: ProcessInfo.processInfo.hostName, appVersion: BuiltVersion.string)))
            ?? Data()
        let server = PosixHTTPServer(authorize: {
            $0.path == MirrorTransport.wellKnownPath || MirrorTransport.isAuthorized($0, token: resolved)
        }) { request in
            if request.method == "GET", request.path == MirrorTransport.wellKnownPath {
                return MirrorTransport.jsonResponse(descriptorBody)
            }
            guard MirrorTransport.isAuthorized(request, token: resolved) else {
                return MirrorTransport.unauthorizedResponse()
            }
            TrayClients.note(request)
            if request.method == "GET", request.path == MirrorTransport.snapshotPath {
                guard let data = try? Data(contentsOf: TrayMirror.url) else {
                    return MirrorTransport.unavailableResponse()
                }
                return MirrorTransport.snapshotResponse(data)
            }
            return MirrorTransport.notFoundResponse()
        }
        let bound: UInt16
        do {
            bound = try server.start(port: port)
        } catch {
            fail("serve: couldn't bind port \(port): \(error)")
        }
        print("infinitus-tray serve: listening on 0.0.0.0:\(bound), "
            + "pairing token \(MirrorPairing.mask(resolved))")
        // #486 slice 3: the control socket beside the HTTP listener, so
        // `infinitusctl status` reaches this box. `status` only —
        // `ControlDispatch` answers everything else with a considered no.
        // A bind that fails is logged, never fatal: the phone's mirror is
        // this process's job, the socket is the extra.
        let handlers = controlHandlers()
        let controlPath = ControlProtocol.socketURL().path
        let control = PosixControlSocket(path: controlPath) {
            ControlDispatch.replyLine(to: $0, handlers: handlers)
        }
        do {
            try control.start()
            print("infinitus-tray serve: control socket at \(controlPath)")
        } catch {
            logPhoneInput("⚠️ control socket at \(controlPath) not bound: \(error) "
                + "— hooks and infinitusctl won't reach this tray")
        }
        while true {
            // MirrorWriter.shouldWrite needs a strict `>` on the interval
            // — sleep a touch over it so this loop's own tick never gets
            // throttled away by itself.
            try? await Task.sleep(nanoseconds: (interval + 1) * 1_000_000_000)
            let list = await collectAndExport(themeID: themeID)
            await tickPushes(list: list, pushes: pushes, flags: pushFlags)
        }
        #else
        fail("serve is Linux-only (no POSIX HTTP listener on this platform)")
        #endif
    }

    static func pair(port: UInt16) {
        #if canImport(Glibc)
        let token = PairingStore.loadOrCreate()
        let addresses = PosixInterfaceAddresses.ipv4()
        var endpoints: [String] = []
        if let lan = MirrorPairing.lanAddress(in: addresses) {
            endpoints.append("http://\(lan):\(port)")
        }
        if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
            endpoints.append("http://\(tailnet):\(port)")
        }
        guard !endpoints.isEmpty else {
            fail("pair: no non-loopback IPv4 address found — connect to a network first")
        }
        let url = MirrorPairing.pairURL(endpoints: endpoints, token: token)
        print(url)
        if let qrencode = which("qrencode") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: qrencode)
            process.arguments = ["-t", "ANSIUTF8", url]
            try? process.run()
            process.waitUntilExit()
        } else {
            print("install qrencode for a QR")
        }
        #else
        fail("pair is Linux-only")
        #endif
    }

    /// PATH lookup for an optional external tool (qrencode) — no shell,
    /// no `which` subprocess.
    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: plumbing

    /// Waybar tooltips are pango markup — escape the payload wholesale.
    static func pango(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func emit(_ payload: WaybarPayload) {
        let escaped = WaybarPayload(text: pango(payload.text),
                                    tooltip: pango(payload.tooltip),
                                    class: payload.class,
                                    percentage: payload.percentage)
        let data = (try? JSONEncoder().encode(escaped)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    /// The tray's stand-in for the Mac's event log (#17): every phone
    /// input delivery/failure — and, since #486 slice 3, the first
    /// checkpoint of a session, any that fails, and every restore the phone
    /// asks for — timestamped, to stderr.
    static func logPhoneInput(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(text)\n".utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
