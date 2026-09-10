import Foundation
import Combine
import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// Main-actor state the MenuBarExtra renders. Feeds per spec §2:
/// snapshots from `cswap list --json` (timer + right after any switch
/// event), events from the supervised `cswap auto --json`.
@MainActor
final class AppModel: ObservableObject {
    // MARK: fleets (#8 multi-engine seam)
    //
    // Every enabled engine's fleets live in the registry as FleetState
    // objects — rows, ticks, pending switch. AppModel stays the popup
    // chrome's model AND a FleetModel facade over the PRIMARY Claude
    // fleet (cswap's on a cswap machine), so the mac-only panes, the
    // title, resume nudges and push triggers keep reading `accounts`
    // exactly as before.
    private(set) lazy var registry = EngineRegistry(host: self)
    var fleets: [FleetState] { registry.fleets }
    var primary: FleetState? { registry.primary }
    /// Per-engine last error (the primary's also lands in lastError).
    @Published var engineErrors: [String: String] = [:]
    /// Per-engine honesty note for the fleet header (proxy: routing
    /// strategy that ignores priority tiers).
    @Published var fleetCaveats: [String: String] = [:]
    /// The cswap cash column's source (UsagePane.swift owns the scan);
    /// the cswap fleet mirrors it, other engines report their own.
    var usageModel: UsageModel? {
        didSet {
            guard let usageModel else { return }
            for f in fleets where f.engineID == CswapEngine.engineID { f.follow(usageModel) }
        }
    }
    private var forwardingFleetChange = false

    var accounts: [Account] { primary?.accounts ?? [] }
    var activeNumber: Int? { primary?.activeNumber }
    /// When the current active account became active — ResumeGate holds
    /// post-switch nudges until it has held for a while (#136).
    private var activeSince: Date?
    var nextCandidate: Int? { primary?.nextCandidate }
    /// Limit-stopped sessions waiting to resume; non-nil only while
    /// every account is at a limit (rides the all-limited banner).
    @Published var waitingResume: Int?
    private var waitingScanAt: Date = .distantPast
    var nextRecovery: NextRecovery? { primary?.nextRecovery }
    var liveSessions: LiveSessions? { primary?.liveSessions }
    /// Session-list popover (brain chip click) — popup-wide state so the
    /// wide chip and the rail badge share one popover.
    @Published var sessionsShown = false
    // Animation triggers. switchFlashTick fires the celebration sweep on
    // the (new) active row; dataPulseTick ripples the sync dot whenever a
    // snapshot actually changed something visible.
    var switchFlashTick: Int {
        get { primary?.switchFlashTick ?? 0 }
        set { primary?.switchFlashTick = newValue }
    }
    /// Per-account death beats: bumped when a row flips alive -> dead
    /// in a snapshot (the celebration's mirror, user 2026-08-30).
    var deathTicks: [Int: Int] {
        get { primary?.deathTicks ?? [:] }
        set { primary?.deathTicks = newValue }
    }
    /// Rows currently DYING: dead in the data, but still rendered with
    /// their gauges for a beat so the killing-blow drama (drop plunge,
    /// shard finisher, death beat) plays out — the dead layout swap
    /// unmounted the bar instantly ("killed instantly", user
    /// 2026-08-31). Cleared a few seconds after each death.
    var dying: Set<Int> {
        get { primary?.dying ?? [] }
        set { primary?.dying = newValue }
    }
    /// Revival fanfares: bumped when a row flips dead -> alive (its
    /// window reset while drained) — the dramatic full-line glow
    /// (user 2026-08-31).
    var reviveTicks: [Int: Int] {
        get { primary?.reviveTicks ?? [:] }
        set { primary?.reviveTicks = newValue }
    }
    /// Click-to-switch staging: the row sets this, the popup's
    /// confirmation alert commits or clears it.
    var pendingSwitch: Int? {
        get { primary?.pendingSwitch }
        set { primary?.pendingSwitch = newValue }
    }
    @Published var dataPulseTick = 0

    /// A fleet's rows changed: whoever observes the host (title, popup
    /// chrome, panes) re-renders. Guarded — FleetState forwards host
    /// changes down, and this is the return trip.
    func forwardFleetChange() {
        guard !forwardingFleetChange else { return }
        forwardingFleetChange = true
        objectWillChange.send()
        forwardingFleetChange = false
    }
    /// Debug-only (defaults write … debug_menu -bool true): adds the
    /// Animations tab so every effect can be fired by hand. Set in init
    /// AFTER migrateLegacyDefaults: a stored-property initializer runs
    /// first, and the first launch under the new bundle id read the
    /// not-yet-copied key (user 2026-09-03 "not seeing the animations
    /// setting on current build").
    let debugMenu: Bool
    @Published var cswapState: CswapSupervisor.State = .stopped
    struct EventEntry: Identifiable {
        let id = UUID()
        var at = Date()
        let icon: String
        let text: String
    }
    /// The Activity tail, `infinitusctl events` and the wall's last
    /// lines: the last 100 events — seeded from the durable log at
    /// launch (`seedEventLog`), so a relaunch or rebuild no longer wipes
    /// what the user just did (#338).
    @Published var eventLog: [EventEntry] = []
    let eventStore = EventStore()
    private let launchedAt = Date()
    /// Team session control (#220): the audit feed and who is driving
    /// which session (by session id) until when — read at render time,
    /// no timer.
    let teamControlFeed = TeamControlFeed()
    struct Driven { let name: String; let project: String; let until: Date }
    @Published var drivenBy: [String: Driven] = [:]
    /// One "your commands are failing" notification per driver per hour.
    private var controlRefusalNotified: [String: Date] = [:]
    static let drivenByWindow: TimeInterval = 60
    static let executedOutcomes: Set<String> = ["delivered", "running", "captured"]
    static let notifiedRefusals: Set<String> = ["expired", "replayed", "notLive", "rateLimited", "badRequest"]

    func recordTeamControl(_ audit: TeamControl.Audit, driverName: String?) {
        let driver = driverName ?? String(audit.driver.prefix(8))
        let project = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
            .first { $0.sessionId == audit.session }.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? audit.session
        let line = TeamControlFeed.Line(driver: driver, session: project, action: audit.action, outcome: audit.outcome, detail: audit.detail)
        teamControlFeed.append(line)
        logEvent("team-control", icon: "person.2", line.text)
        if Self.executedOutcomes.contains(audit.outcome) {
            drivenBy[audit.session] = Driven(name: driver, project: project, until: Date().addingTimeInterval(Self.drivenByWindow))
        }
        if driverName != nil, Self.notifiedRefusals.contains(audit.outcome),
           controlRefusalNotified[audit.driver].map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            controlRefusalNotified[audit.driver] = Date()
            notify("\(driver)'s commands are failing: \(audit.outcome)")
        }
    }

    /// Where a teammate reaches this Mac right now (#220 §5.1), for now.json.
    var controlEndpoints: TeamControl.Endpoints {
        var e = TeamControl.Endpoints()
        if let port = mirrorServer.port, let lan = MirrorPairing.lanAddress(in: LocalAddresses.ipv4()) { e.lan = "\(lan):\(port)" }
        if namedTunnel.connected { e.hostname = namedTunnel.hostname }
        if quickTunnel.url != nil, let kid = team.kid, let id = team.paths.teamIDs().sorted().first {
            e.rendezvous = TeamControl.rendezvousKey(team: id, kid: kid)
        }
        return e
    }
    lazy var statsModel = StatsModel(eventStore: eventStore)

    /// Every event goes through here: the Activity pane's tail and the
    /// durable log Stats reads. `kind` is StatsEvents' vocabulary
    /// (switch/death/limit/revival/ignite/resume/nudge/pairing/other).
    func logEvent(_ kind: String, icon: String, _ text: String) {
        eventLog.append(EventEntry(icon: icon, text: text))
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
        // The durable log belongs to the real instance alone. A mock,
        // playground or e2e instance shares the same App Support path
        // (only the defaults domain and the control socket differ), and
        // would otherwise write demo switches into the user's own
        // months of history — the same gate `statsModel.enabled` uses.
        guard !isPlayground, !mockMode else { return }
        let event = StatsEvent(at: Date(), kind: kind, icon: icon, text: text)
        Task.detached(priority: .utility) { [eventStore] in await eventStore.append(event) }
    }
    /// App-side resume nudges + /rc re-arm (ResumeService.swift).
    let resume = ResumeService()
    /// Sessions popover's mini progress rows (SessionProgressModel.swift).
    let sessionProgress = SessionProgressModel()
    /// The machine-health guardian (#115): Settings › Machine's model.
    let machineModel = MachineModel()
    let sessionProfiles = SessionProfilesModel()
    /// What Infinitus started each live session as (#163/#165), by pid;
    /// kept across launches, pruned to the roster on every export.
    @Published private(set) var sessionBirths: [Int: SessionBirth] = SessionBirths.load(from: AppModel.birthsURL)
    static let birthsURL = AppSupport.root().appendingPathComponent("session-births.json")
    func recordBirth(pid: Int, _ birth: SessionBirth) {
        let live = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
        let alive = Set(live.map { Int($0.pid) })
        sessionBirths = SessionBirths.pruned(sessionBirths, alive: alive.union([pid]))
        // Pinned to the session id whenever the roster has it, so a
        // reused pid after a reboot can never inherit a grant.
        let id = live.first { Int($0.pid) == pid }?.sessionId
        sessionBirths[pid] = id.map { birth.identified(as: $0) } ?? birth
        // The profile's allow-list (#165) becomes the session's hook rules.
        if let id { seedAllowList(birth, sessionId: id) }
        try? SessionBirths.save(sessionBirths, to: Self.birthsURL)
    }
    /// "Allow for this session" rules from the phone (#79), per session id.
    let toolApprovals = ToolApprovals()

    private func profileAllowRules(_ birth: SessionBirth) -> [ToolApproval.Rule] {
        guard let name = birth.profile else { return [] }
        return sessionProfiles.profiles.first { SessionProfiles.same($0.name, name) }?.allowRules ?? []
    }

    /// A session born from a profile runs its allow-list without asking:
    /// the same rules the phone's "Allow for this session" adds.
    private func seedAllowList(_ birth: SessionBirth, sessionId: String) {
        let rules = profileAllowRules(birth)
        guard !rules.isEmpty, let name = birth.profile else { return }
        for rule in rules { toolApprovals.add(rule, sessionId: sessionId) }
        logEvent("hook", icon: "checkmark.shield", "profile \(name) allows \(rules.map(\.label).joined(separator: ", ")) in session \(sessionId.prefix(8))")
    }

    /// The phone's star/pause verbs (`POST /accounts/action`), with the
    /// popup's own semantics: the same capability guards the control
    /// server runs, and a star lands on the account right away when it
    /// isn't the active one (FleetState.setPreferred).
    func performAccountAction(_ request: AccountAction.Request) async -> AccountAction.Reply {
        guard let fleet = fleets.first(where: { $0.id == request.fleet }) else {
            return AccountAction.Reply(outcome: "notFound", detail: "no fleet \(request.fleet)")
        }
        guard let account = fleet.accounts.first(where: { $0.number == request.number }) else {
            return AccountAction.Reply(outcome: "notFound", detail: "no account #\(request.number) in \(fleet.id)")
        }
        let engine = fleet.engine, provider = fleet.provider, number = request.number
        do {
            switch request.action {
            case "hold", "unhold":
                guard fleet.capabilities.contains(.hold) else {
                    return AccountAction.Reply(outcome: "unsupported", detail: "\(fleet.id) does not support hold")
                }
                try await engine.setHold(fleet: provider, number: number, held: request.action == "hold")
            case "prefer", "unprefer":
                guard fleet.capabilities.contains(.prefer), account.preferred != nil else {
                    return AccountAction.Reply(outcome: "unsupported", detail: "\(fleet.id) has no pick-first setting")
                }
                let on = request.action == "prefer"
                try await engine.setPreferred(fleet: provider, number: number, on)
                if on, !account.active, fleet.capabilities.contains(.switch) {
                    try await engine.switchTo(fleet: provider, number: number)
                }
            default:
                return AccountAction.Reply(outcome: "unsupported", detail: "unknown action \(request.action)")
            }
        } catch {
            return AccountAction.Reply(outcome: "failed", detail: "\(error)")
        }
        await refreshSnapshot()
        return AccountAction.Reply(outcome: "done")
    }

    /// Moves a running session's permission mode (#163 phase 2): the
    /// plugin's PreToolUse hook answers from it. The start mode is a
    /// floor — Claude Code itself already lets those tools through, so
    /// narrowing from here would only pretend.
    func setSessionMode(_ text: String, pid: Int, record: ClaudeSessionRecord) -> SessionInput.Reply {
        let mode = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let choice = SessionStart.hookModes.first(where: { $0.mode == mode }) else {
            return SessionInput.Reply(outcome: "rejected", detail: "mode must be one of \(SessionStart.hookModes.map(\.mode).joined(separator: ", "))")
        }
        let birth = sessionBirths[pid] ?? SessionBirth()
        let target: String? = choice.mode == "supervised" ? nil : choice.mode
        if SessionStart.modeRank(target) < SessionStart.modeRank(birth.permissionMode) {
            let started = birth.modeLabelForStart ?? "supervised"
            return SessionInput.Reply(outcome: "rejected", detail: "the session started as \(started); a start mode cannot be narrowed from here")
        }
        toolApprovals.setMode(target, sessionId: record.sessionId)
        recordBirth(pid: pid, birth.moved(to: target))
        logEvent("hook", icon: "checkmark.shield", "session \(pid) moved to \(choice.label)")
        return SessionInput.Reply(outcome: "delivered", channel: "mac", detail: choice.label)
    }
    @Published var lastError: String?
    /// #7 layer 2: the reset battle plan for the current sprint, recomputed
    /// every snapshot; nil when there is nothing to plan. Manual mode: the
    /// popup line offers the ignite step behind a confirm, nothing runs
    /// by itself.
    @Published var battlePlan: WindowPlanner.Plan?
    @Published var igniting: Int?
    /// #338: what the last ignition did, for the plan line to say out
    /// loud for a few seconds — the chip otherwise vanishes silently.
    @Published var igniteResult: IgniteResult?
    /// Run-rate projection: when the active account's windows hit their
    /// limits and when the fleet is out, at the measured pace (nil until
    /// there is an active account). The planner reads the same rates.
    @Published var forecast: UsageForecast?
    /// Sessions whose AWS sign-in lapsed + logins in flight (AwsLogin.swift).
    @Published var awsLogins: [AwsLogin.Item] = []
    /// Crash reports from the phone (MetricKit, over the mirror) and this
    /// Mac's own diagnostic reports; newest first (CrashReport.swift).
    @Published private(set) var crashReports: [CrashReport] = []
    let crashStore = CrashStore(directory: CrashStore.defaultDirectory())
    /// True once `awsLogins` reflects a finished transcript scan. The
    /// push trigger seeds off it, not off the scanner's own flag: the
    /// list rebuilds one run-loop hop after the scan lands, and a poll
    /// in that gap would seed on the stale (empty) list and push every
    /// pre-existing need on the next one.
    private var awsLoginsScanned = false
    private var awsLoginStates: [AwsLogin.State] = []
    private var awsLoginNeedsWatch: AnyCancellable?
    private var awsLoginQuitWatch: AnyCancellable?
    /// How often an unmet session need is put to the CLI (#313); the
    /// e2e gate shortens it.
    static let awsProbeInterval: TimeInterval =
        Double(ProcessInfo.processInfo.environment["INFINITUS_AWS_PROBE_S"] ?? "") ?? 300
    private var awsProbeTask: Task<Void, Never>?
    private(set) lazy var awsLoginRunner: AwsLoginRunner = {
        let runner = AwsLoginRunner(
            onChange: { [weak self] states in Task { @MainActor in self?.awsLoginStates = states; self?.rebuildAwsLogins() } },
            onDone: { [weak self] state in Task { @MainActor in self?.awsLoginLanded(state) } },
            // INFINITUS_AWS_LEDGER: the e2e gate's own file, so its stub
            // logins never land in (or read) the real app's ledger.
            ledgerURL: ProcessInfo.processInfo.environment["INFINITUS_AWS_LEDGER"].map { URL(fileURLWithPath: $0) }
                ?? AppSupport.root().appendingPathComponent("aws-logins.json"))
        // A CLI left behind at quit keeps its localhost listener alive.
        awsLoginQuitWatch = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in runner.killAll() }
        return runner
    }()
    /// Last 24h of usage samples, the burn-rate input (5h pace over the
    /// last hour, weekly pace over the day). Seeded from this machine's
    /// history file at launch so the first plan doesn't wait ten minutes
    /// for fresh polls.
    private var recentSamples: [UsageSample] = []

    let cswap: CswapCLI?
    /// The swapd binary this Mac has, when it has one (preview, #8): the
    /// engine is registered from it, and the pane shows where it is.
    /// Never in the playground — that model is demo data only.
    let swapd: SwapdCLI?
    /// True for the Animation Playground's private model: cswap is pinned
    /// to the bundled demo script and every outward side effect —
    /// snapshot cache, notifications, resume nudges, push, sync, power
    /// assertions, the engine supervisor — is suppressed, so nothing it
    /// does can touch real accounts or real sessions (user 2026-08-31).
    let isPlayground: Bool
    /// Set by StatusItemHolder — opens the controller-owned Settings window
    /// (the SwiftUI Settings scene is unreachable from popover hosts).
    var showSettings: (() -> Void)?
    /// Set by StatusItemHolder — closes and re-shows an open popover.
    /// NSPopover keeps a stale fitting size when the content swaps shape
    /// wholesale (wide<->stacked left it clipped or oversized until a
    /// manual reopen, user-verified); a programmatic bounce is that same
    /// fix without the user doing it.
    var reopenPopover: (() -> Void)?
    /// Set by StatusItemHolder — closes the popover and opens the same
    /// content as a free-floating window (the pop-out action).
    var popOut: (() -> Void)?
    /// Set by StatusItemHolder — toggles the full-screen fleet wall
    /// (issue #11).
    var showWall: (() -> Void)?
    /// Opens the workspace window (T3 clone B), optionally on a screen
    /// ("sidebar" | "thread" | "composer" — the parity harness's names).
    var showWorkspace: ((String?) -> Void)?
    /// Opens a live session's chat window (#151); set by the status item
    /// controller, called from the sessions card's rows.
    var openSessionChat: ((SessionDetail) -> Void)?
    // The bundle on disk was rebuilt since this instance launched (the
    // dev loop, or a manual make-app.sh) — surfaced as "restart to update".
    @Published var appUpdatePending = false
    /// A newer Infinitus release than this build (About → Updates does
    /// the check; the popup chip just points there).
    @Published var appUpdateVersion: String?
    /// Whatever About's release check last found, newer or not (#121) —
    /// the phone mirrors this to know when a newer PHONE build is out.
    @Published var appReleaseLatest: String?
    /// The one BrewUpdater instance the About pane's button and the
    /// phone's `POST /app/update` route both drive; set by InfinitusApp.
    var brewUpdater: BrewUpdater?
    private let launchExecutableDate = AppModel.executableDate()
    private var supervisor: CswapSupervisor?
    private var refreshTask: Task<Void, Never>?
    private var rateTask: Task<Void, Never>?
    private var lastNotifiedActive: Int?

    // Display prefs, persisted to UserDefaults under the same names and
    // defaults as the rumps MenuBarSettings. @Published (not @AppStorage):
    // @AppStorage inside an ObservableObject never fires objectWillChange,
    // so the MenuBarExtra title would go stale.
    @Published var showAccountName: Bool { didSet { defaults.set(showAccountName, forKey: "show_account_name") } }
    @Published var titlePct: String { didSet { defaults.set(titlePct, forKey: "title_pct") } }
    @Published var titleScoped: Bool { didSet { defaults.set(titleScoped, forKey: "title_scoped") } }
    // Menu bar percentages count remaining instead of used (todo
    // 2026-08-30). Menu-bar-only: the popup gauges stay HP-style.
    @Published var titleRemaining: Bool { didSet { defaults.set(titleRemaining, forKey: "title_remaining") } }
    @Published var titleReset: String { didSet { defaults.set(titleReset, forKey: "title_reset") } }
    /// Icon only in the menu bar — no name, no percentages (user
    /// 2026-08-30). Display-time override; the individual title prefs
    /// keep their values for when this flips back off.
    @Published var titleIconOnly: Bool { didSet { defaults.set(titleIconOnly, forKey: "title_icon_only") } }
    @Published var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refresh_interval") } }
    @Published var gamification: String { didSet { defaults.set(gamification, forKey: "gamification_style") } }
    @Published var compactRows: Bool { didSet { defaults.set(compactRows, forKey: "compact_rows") } }
    // Hide the popup's action controls but keep the status chips (claude
    // status, working sessions, engine badge) — todo 2026-08-30. Safe to
    // persist: every hidden action lives in the status item's right-click
    // menu, so Settings/Quit can never strand.
    @Published var footerActionsHidden: Bool { didSet { defaults.set(footerActionsHidden, forKey: "footer_actions_hidden") } }
    @Published var popupLayout: String { didSet { defaults.set(popupLayout, forKey: "popup_layout") } }
    @Published var popupTextSize: String { didSet { defaults.set(popupTextSize, forKey: "popup_text_size") } }
    // Popup transparency, 0 (full frost) … 1 (clearest). ONE dial for
    // every focus state: the backdrop-blur glass renders identically
    // everywhere, and a per-focus value made the popup visibly jump as
    // key state flapped (user 2026-08-30: "another state that randomly
    // transition"). Key name kept for existing prefs.
    @Published var glassFocused: Double { didSet { defaults.set(glassFocused, forKey: "glass_focused") } }
    /// Content-fill scale for the transparency dial. Once the chrome
    /// went pure at max (measured: body gaps match the backdrop's
    /// luminance), the card/band fills were what still blocked the
    /// backdrop (user 2026-08-30: "max transparency doesn't make glass
    /// transparency that much") — so they thin with the dial too.
    var fillScale: Double { 1 - 0.6 * glassFocused }
    // Launch-intro choreography (dev-tunable, 2026-08-30): content
    // entrance style, overall speed multiplier, title flourish variant.
    // introTick replays the whole intro on demand.
    @Published var introTick = 0
    @Published var introStyle: String { didSet { defaults.set(introStyle, forKey: "intro_style") } }
    @Published var introSpeed: Double { didSet { defaults.set(introSpeed, forKey: "intro_speed") } }
    @Published var introTitle: String { didSet { defaults.set(introTitle, forKey: "intro_title") } }
    /// Pace fire on 7d/model bars ("off"/"ember"/"flame"/"limit").
    @Published var burnStyle: String { didSet { defaults.set(burnStyle, forKey: "burn_style") } }
    /// The chat window's header — "compact", "strip" or "hud" (#151), the
    /// phone's own `chat_header` choices.
    @Published var chatHeader: String { didSet { defaults.set(chatHeader, forKey: "chat_header") } }
    /// Mock mode (user 2026-08-31): the bundled demo fleet stands in
    /// for the engine. Machine-local, deliberately never synced. cswap
    /// is a let, so flipping this relaunches — the restart IS the
    /// re-detect (installEngine precedent).
    @Published var mockMode: Bool {
        didSet {
            defaults.set(mockMode, forKey: "mock_mode")
            relaunchApp()
        }
    }

    // MARK: engines (#8) — which engines the registry runs. Like
    // mockMode, flipping one relaunches: the registry is built once at
    // init and the restart IS the re-detect.
    @Published var cswapEnabled: Bool {
        didSet {
            guard cswapEnabled != oldValue else { return }
            defaults.set(cswapEnabled, forKey: "engine_cswap_enabled")
            relaunchApp()
        }
    }
    /// The swapd engine (preview): off until asked for, and it runs
    /// BESIDE cswap during the transition — neither is assumed.
    @Published var swapdEnabled: Bool {
        didSet {
            guard swapdEnabled != oldValue else { return }
            defaults.set(swapdEnabled, forKey: "engine_swapd_enabled")
            relaunchApp()
        }
    }
    @Published var cliproxyEnabled: Bool {
        didSet {
            guard cliproxyEnabled != oldValue else { return }
            defaults.set(cliproxyEnabled, forKey: "engine_cliproxy_enabled")
            relaunchApp()
        }
    }
    /// The proxy's management endpoint; the key lives in the keychain
    /// under this string (Keychain.swift).
    var cliproxyBaseURL: String {
        defaults.string(forKey: "cliproxy_base_url") ?? CLIProxyEngine.defaultBaseURL.absoluteString
    }
    var cliproxyKeyPresent: Bool { Keychain.read(account: cliproxyBaseURL) != nil }

    /// Pane "Save & restart": URL to defaults, key to the keychain
    /// (empty key = clear), then relaunch so the registry rebuilds.
    func saveCLIProxy(baseURL: String, key: String) {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let old = cliproxyBaseURL
        if old != url { Keychain.delete(account: old) }
        defaults.set(url, forKey: "cliproxy_base_url")
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: url) }
        else { _ = Keychain.write(account: url, value: trimmed) }
        relaunchApp()
    }

    /// 9Router (third engine): same shape as the proxy — toggle in
    /// defaults, password in the keychain under the base URL.
    @Published var nineRouterEnabled: Bool {
        didSet {
            guard nineRouterEnabled != oldValue else { return }
            defaults.set(nineRouterEnabled, forKey: "engine_9router_enabled")
            relaunchApp()
        }
    }
    var nineRouterBaseURL: String {
        defaults.string(forKey: "9router_base_url") ?? NineRouterEngine.defaultBaseURL.absoluteString
    }
    var nineRouterPasswordPresent: Bool {
        Keychain.read(account: nineRouterBaseURL, service: Keychain.nineRouterService) != nil
    }
    func saveNineRouter(baseURL: String, password: String) {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let old = nineRouterBaseURL
        if old != url { Keychain.delete(account: old, service: Keychain.nineRouterService) }
        defaults.set(url, forKey: "9router_base_url")
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: url, service: Keychain.nineRouterService) }
        else { _ = Keychain.write(account: url, value: trimmed, service: Keychain.nineRouterService) }
        relaunchApp()
    }

    static let cliproxyLedgerURL: URL = {
        AppSupport.root().appendingPathComponent("engines/cliproxy/usage.jsonl")
    }()

    /// OAuth add / re-login for an engine that signs accounts in through
    /// a browser (the proxy): the same in-app sign-in chooser as cswap
    /// (system sheet or per-account private window — never the user's
    /// default browser), polling the engine until the credential lands.
    func addOAuthAccount(engineID: String, provider: Provider, relogin: Account? = nil) {
        guard let engine = registry.engine(id: engineID),
              engine.capabilities.contains(.addOAuth),
              !addingFirstAccount, !TokenFlow.shared.running else { return }
        addingFirstAccount = true
        firstAccountMessage = nil
        TokenFlow.shared.start(model: self, engine: engine, provider: provider,
                               relogin: relogin) { [weak self] message in
            self?.firstAccountMessage = message
            self?.addingFirstAccount = false
        }
    }

    /// `GET /routing/strategy` as of the last refresh (proxy engine only).
    @Published var proxyRoutingStrategy: String?
    /// nil = the proxy has no session-affinity route (pre-#5447): the
    /// pane shows the YAML note instead of a toggle.
    @Published var proxySessionAffinity: Bool?

    /// The CLIProxyAPI tab's routing picker: PUT, then a refresh so the
    /// caveat line and the mapped fleet follow the new mode.
    func setProxySessionAffinity(_ on: Bool) {
        guard let proxy = registry.engine(id: CLIProxyEngine.engineID) as? CLIProxyEngine else { return }
        Task {
            do {
                try await proxy.setSessionAffinity(on)
                engineErrors[CLIProxyEngine.engineID] = nil
            } catch {
                engineErrors[CLIProxyEngine.engineID] =
                    (error as? EngineError)?.errorDescription ?? "\(error)"
            }
            await refreshSnapshot()
        }
    }

    func setProxyRoutingStrategy(_ strategy: String) {
        guard let proxy = registry.engine(id: CLIProxyEngine.engineID) as? CLIProxyEngine else { return }
        Task {
            do {
                try await proxy.setRoutingStrategy(strategy)
                engineErrors[CLIProxyEngine.engineID] = nil
            } catch {
                engineErrors[CLIProxyEngine.engineID] =
                    (error as? EngineError)?.errorDescription ?? "\(error)"
            }
            await refreshSnapshot()
        }
    }

    /// Intro phase timing: bars (and the active-row flash) hold until
    /// the content entrance has fully landed (user 2026-08-30: "only
    /// when content in full display -> play bar fills + flash").
    var introContentDuration: Double { 0.7 / max(0.2, introSpeed) }
    var introBarDelay: Double { introContentDuration + 0.25 }

    /// The debug pane's Replay: the WHOLE sequence, not just the
    /// entrances — bars replay via the introTick environment, and the
    /// flash fires after the fill starts.
    func replayIntro() {
        introTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.switchFlashTick += 1
        }
    }
    // Deliberately NOT persisted: if a hidden icon survived a relaunch there
    // would be no UI left to unhide it from (the Settings window is only
    // reachable through the popup). Hiding lasts until quit.
    @Published var menuBarIconShown = true
    // Pin holds the popover open (click-outside stops closing it).
    // Persisted by request — a pinned popup stays pinned across relaunches.
    @Published var popoverPinned: Bool { didSet { defaults.set(popoverPinned, forKey: "popover_pinned") } }
    /// Floating revival countdown while every account is limited (#1's
    /// macOS equivalent). On by default; ✕ on the panel hides one episode.
    @Published var revivalPanelShown: Bool {
        didSet {
            defaults.set(revivalPanelShown, forKey: "revival_panel")
            if !isPlayground { revivalPanel.sync(model: self) }
        }
    }
    private lazy var revivalPanel = RevivalPanelController()
    /// Haiku names unnamed sessions (SessionNamer). On by default; one
    /// short Haiku turn per session on the active account.
    @Published var sessionAutoNames: Bool {
        didSet {
            defaults.set(sessionAutoNames, forKey: "session_auto_names")
            sessionProgress.namer?.enabled = sessionAutoNames
        }
    }
    /// Hold a power assertion while any session is mid-turn (KeepAwake).
    /// Display-only: rows sorted most-headroom-first with the active
    /// account and the next candidate pinned on top (todo 2026-09-01).
    /// Engine slots never move — nothing is written (the app-side
    /// auto-order writer was removed 2026-09-03: pick-first is an engine
    /// knob, see EngineCapabilities.prefer).
    @Published var sortByHeadroom: Bool {
        didSet { defaults.set(sortByHeadroom, forKey: "sort_headroom") }
    }
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keep_awake")
            awake.update(wanted: keepAwake, display: keepAwakeDisplay, busyCount: liveSessions?.busy ?? 0)
        }
    }
    /// With `keepAwake`: the screen stays on too, the way a caffeine app
    /// keeps it (#455). Off, only system sleep is held.
    @Published var keepAwakeDisplay: Bool {
        didSet {
            defaults.set(keepAwakeDisplay, forKey: "keep_awake_display")
            awake.update(wanted: keepAwake, display: keepAwakeDisplay, busyCount: liveSessions?.busy ?? 0)
        }
    }
    // Away-push triggers beyond switches (PushTriggers has the rules).
    @Published var pushSessionsDone: Bool { didSet { defaults.set(pushSessionsDone, forKey: "push_sessions_done") } }
    @Published var pushAllDead: Bool { didSet { defaults.set(pushAllDead, forKey: "push_all_dead") } }
    @Published var pushLastAlive: Bool { didSet { defaults.set(pushLastAlive, forKey: "push_last_alive") } }
    @Published var pushWaiting: Bool { didSet { defaults.set(pushWaiting, forKey: "push_waiting") } }
    @Published var pushAwsLogin: Bool { didSet { defaults.set(pushAwsLogin, forKey: "push_aws_login") } }
    /// "<name> is back" (and "all accounts are back — reset early") pushes (2026-09-05).
    @Published var pushRevived: Bool { didSet { defaults.set(pushRevived, forKey: "push_revived") } }
    /// Minutes before a reset that the row's countdown goes live and the
    /// phone's reset alarm fires (#227); mirrored to the phone in FleetPrefs.
    @Published var reviveLeadMinutes: Int { didSet { defaults.set(reviveLeadMinutes, forKey: "revive_lead_minutes") } }
    var reviveLead: TimeInterval { TimeInterval(reviveLeadMinutes * 60) }
    /// Settings › Sync "Phone lock screen": how often the working Live
    /// Activity's tok/min is pushed on its own (user 2026-09-08 "update the
    /// tok/min every 5s, make it configurable"); 0 = only with other changes.
    @Published var liveActivityRateSeconds: Int { didSet { defaults.set(liveActivityRateSeconds, forKey: "live_activity_rate_seconds") } }
    /// Settings › Sync "This Mac's name" (#99); empty follows the computer name.
    @Published var machineNameOverride: String {
        didSet {
            defaults.set(machineNameOverride, forKey: MachineName.overrideKey)
            guard machineNameOverride != oldValue else { return }
            // The Bonjour service carries the name — re-advertise.
            mirrorServer.stop()
            applyMirrorLAN()
        }
    }
    var machineName: String { MachineName.current(defaults: defaults) }
    /// Where a session started from the phone opens (#91): "auto" (cmux
    /// when installed, else Terminal), "cmux", "terminal".
    @Published var sessionHost: String { didSet { defaults.set(sessionHost, forKey: "session_host") } }
    /// Per-turn workspace checkpoints (#167): a hidden git ref per prompt,
    /// recorded when the plugin's UserPromptSubmit hook fires.
    @Published var checkpointsEnabled: Bool { didSet { defaults.set(checkpointsEnabled, forKey: "checkpoints_enabled") } }
    /// The status item in the theme's color with the theme's icon (#90),
    /// and its effects (switch/death/revival flash, the burn breath).
    @Published var menuBarThemed: Bool { didSet { defaults.set(menuBarThemed, forKey: "menubar_themed") } }
    @Published var menuBarEffects: Bool { didSet { defaults.set(menuBarEffects, forKey: "menubar_effects") } }
    // Phone companion (#9): serve the mirror snapshot over the LAN when
    // the Sync pane's toggle is on. Off by default — it's an open port.
    @Published var mirrorLANEnabled: Bool {
        didSet {
            defaults.set(mirrorLANEnabled, forKey: "mirror_lan_enabled")
            applyMirrorLAN()
        }
    }
    /// The pairing token every mirror request must carry (#9 remote
    /// access). Not a credential to Anthropic — a read key for this
    /// Mac's snapshot, which is why plain UserDefaults is its home.
    @Published var mirrorPairToken: String {
        didSet {
            defaults.set(mirrorPairToken, forKey: "mirror_pair_token")
            mirrorServer.token.set(mirrorPairToken)
        }
    }
    /// Publish the quick tunnel's current URL to the infinitus.run
    /// rendezvous (MirrorRendezvous) so a paired phone finds the new
    /// address after a restart instead of rescanning. On by default: it
    /// only ever runs while the quick tunnel does, and the URL is useless
    /// without the token.
    @Published var mirrorRendezvousEnabled: Bool {
        didSet {
            defaults.set(mirrorRendezvousEnabled, forKey: "mirror_rendezvous_enabled")
            if mirrorRendezvousEnabled, let url = quickTunnel.url { publishRendezvous(url) }
        }
    }
    /// "Expose through a Cloudflare quick tunnel" — off by default; a
    /// public hostname, even a throwaway one, is never a default.
    @Published var mirrorTunnelEnabled: Bool {
        didSet {
            defaults.set(mirrorTunnelEnabled, forKey: "mirror_tunnel_enabled")
            applyQuickTunnel()
        }
    }
    /// The named Cloudflare tunnel (#9, the restart-proof route): the
    /// user's own hostname, the token in the keychain. Off by default.
    @Published var mirrorNamedTunnelEnabled: Bool {
        didSet {
            defaults.set(mirrorNamedTunnelEnabled, forKey: NamedTunnel.enabledKey)
            applyNamedTunnel()
        }
    }
    @Published var mirrorNamedTunnelHost: String {
        didSet {
            defaults.set(mirrorNamedTunnelHost, forKey: NamedTunnel.hostnameKey)
            applyNamedTunnel()
        }
    }
    let sync = SettingsSyncModel()
    let historyRecorder = UsageHistoryRecorder()
    let mirrorExporter = MirrorExporter()
    /// T3 attention flags and the per-session timeline cache (#223 phase 3).
    let attentionStore = AttentionStore(url: AttentionStore.defaultURL)
    /// Numbers every timeline change for `/timeline` resumes (#223 phase 4).
    let sequenceLog = SequenceLog()

    /// The Mac's own popup / pop-out / chat window is a client too (#223
    /// phase 5): while one is open, nothing the user sees here depends on
    /// a phone holding a lease. StatusItemController and the chat window
    /// call it on show / hide; the cap is the TTL, so a UI that dies
    /// never pins work for more than five minutes.
    /// The local surfaces on screen by id — "popup", "popout",
    /// "chat:<pid>" — the lease holds while any is up, so closing the
    /// popup over an open chat window drops nothing.
    private var visibleSurfaces = Set<String>()
    private var localUIVisible: Bool { !visibleSurfaces.isEmpty }
    /// The pass a surface's very first appearance starts (below).
    private var localSurfaceRefresh: Task<Void, Never>?
    func uiSurface(_ id: String, visible: Bool) {
        let was = localUIVisible
        if visible { visibleSurfaces.insert(id) } else { visibleSurfaces.remove(id) }
        if localUIVisible != was || visible { reportLocalActivity(visible: localUIVisible) }
        // The exporter's one unthrottled pass (launch) can land before this
        // lease does — a startup race between StatusItemController's
        // delayed pop-out/workspace restore and refreshSnapshot's first,
        // faster turnaround. That pass then writes an empty factsByPid,
        // and the 30 s throttle after it starves every thread's row
        // (`guard let f = inputs.facts[...]`) for the rest of the window
        // (#468). A surface's first appearance forces the next export
        // through, the same bypass an AWS-login need uses below — but only
        // while facts are actually empty: a reopen soon after a good
        // export has real facts already and must not fight the 30 s
        // throttle #346 relies on to keep a busy fleet cheap.
        if !was, localUIVisible, !isPlayground, sessionProgress.facts.isEmpty, localSurfaceRefresh == nil {
            mirrorExportDue = true
            localSurfaceRefresh = Task { [weak self] in
                await self?.refreshSnapshot()
                self?.localSurfaceRefresh = nil
            }
        }
    }
    private func reportLocalActivity(visible: Bool) {
        if visible {
            mirrorServer.leases.report(.init(clientId: ClientActivity.localClientId, visible: true, focused: true,
                                             recentlyInteracted: true, scopes: [.sessions, .fleets, .stats],
                                             ttlMs: ClientActivity.ttlCapMs))
        } else {
            mirrorServer.leases.release(clientId: ClientActivity.localClientId)
        }
    }
    private(set) lazy var timelineCache = TimelineCache(log: sequenceLog)
    let mirrorServer = MirrorServer()
    /// Agent CLI socket (ControlServer.swift); the real model only.
    private(set) lazy var controlServer = ControlServer(model: self)
    /// The biometric lock (LockModel.swift); the surfaces and the Lock pane read it.
    private(set) lazy var lock = LockModel(defaults: defaults)
    /// Settings › Team (spec §9). Secrets in the keychain, or files when
    /// INFINITUS_TEAM_DIR redirects the team dir (e2e, a second instance).
    private(set) lazy var team: TeamModel = {
        let paths = TeamPaths.standard()
        let model = TeamModel(paths: paths, makeSecrets: TeamSecretsFactory.make(paths: paths), defaults: defaults)
        model.enabled = !isPlayground && (!mockMode || ProcessInfo.processInfo.environment["INFINITUS_TEAM_DIR"] != nil)
        return model
    }()
    let quickTunnel = QuickTunnel()
    let namedTunnel = NamedTunnel()
    /// Live Activity pushes to the phone (APNs), LiveActivityPusher.swift.
    let liveActivityPusher = LiveActivityPusher()

    /// Every app notification: Notification Center here, and the same
    /// text to any phone that registered an alert token (issue #3).
    /// Both push channels: the Mac notice (+ Live Activity alert) and the
    /// engine's away-push. Text over stdin, matching the channel-setup
    /// commands; no channels configured is a quiet no-op (try?). The
    /// away-push channels are cswap's.
    func push(_ msg: String) {
        notify(msg, phoneUnlessRevival: PushTriggers.isAllDeadMessage(msg))
        if let cswap {
            Task { _ = try? await cswap.run(["notify", "push", "-"], stdin: msg) }
        }
    }

    struct SessionRow { let pid: Int; let name: String?; let cwd: String; let status: String?; let kind: String }

    /// The live sessions as the control socket lists them (#79): the
    /// record plus the name the popup shows.
    func sessionRows() -> [SessionRow] {
        ownedRoster(claudeDir: ClaudeSessions.configHome()).map { record in
            let pid = Int(record.pid)
            let progress = sessionProgress.byPid[pid]
            let shown = SessionNaming.displayName(name: progress?.name ?? record.name,
                                                  autoName: progress?.autoName, cwd: record.cwd)
            return SessionRow(pid: pid, name: shown, cwd: record.cwd, status: record.status, kind: record.kind)
        }
    }

    /// A pid, or a name / folder name, case-insensitively; the newest
    /// session wins a tie.
    func sessionPid(matching who: String) -> Int? {
        let rows = sessionRows()
        if let pid = Int(who), rows.contains(where: { $0.pid == pid }) { return pid }
        let wanted = who.lowercased()
        return rows.last { row in
            row.name?.lowercased() == wanted
                || URL(fileURLWithPath: row.cwd).lastPathComponent.lowercased() == wanted
        }?.pid
    }

    /// Probes the engine as each dead account's countdown ends (see
    /// RevivalProbe): the next reset's schedule replaces the last, and
    /// a probe that finds nothing dead ends the run.
    private var revivalProbe: Task<Void, Never>?
    private var revivalProbeReset: Date?
    private func scheduleRevivalProbe(accounts: [Account]) {
        let reset = RevivalProbe.nextReset(accounts: accounts)
        guard reset != revivalProbeReset else { return }
        revivalProbe?.cancel()
        revivalProbeReset = reset
        guard let reset else { revivalProbe = nil; return }
        let probes = RevivalProbe.schedule(reset: reset)
        revivalProbe = Task { [weak self] in
            for at in probes {
                let wait = at.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let self else { return }
                logEvent("other", icon: "arrow.clockwise", "countdown ended — asking the engine again")
                await refreshSnapshot()
                guard !Task.isCancelled else { return }
                if RevivalProbe.nextReset(accounts: primary?.lastFleet?.accounts ?? []).map({ $0 > Date() }) ?? true { return }
            }
        }
    }

    /// A Claude Code hook event from the plugin (#79): a prompt is pushed
    /// the moment it appears — the poll would take up to a minute — and
    /// the fleet refreshes right after, so a turn's end shows up as fast
    /// as its prompts. Returns the session's pid when the record is known.
    func handleHookEvent(_ event: HookEvent) -> Int? {
        let pid = event.sessionId.flatMap { id in
            ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
                .first { $0.sessionId == id }.map { Int($0.pid) }
        }
        if event.name == "UserPromptSubmit", checkpointsEnabled, !isPlayground,
           let sessionId = event.sessionId, let cwd = event.cwd {
            recordCheckpoint(sessionId: sessionId, cwd: cwd, subject: event.prompt ?? "")
        }
        if let line = event.pushLine, !isPlayground {
            logEvent("hook", icon: "bolt.horizontal", event.logLine)
            if let pid { pushTriggers.announceWaiting(pid: pid) }
            if pushWaiting { push(line) }
        }
        // One refresh per burst, at most every 30 s: the record's status
        // flips a beat after the hook fires, Stop + Notification often
        // land together, and the "sessions done" trigger counts quiet
        // polls — hook polls a second apart would fire it mid-typing.
        if hookRefresh == nil {
            let wait = max(1, Self.hookRefreshSpacing - Date().timeIntervalSince(lastHookRefresh))
            hookRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                lastHookRefresh = Date()
                await refreshSnapshot()
                hookRefresh = nil
            }
        }
        return pid
    }
    private var hookRefresh: Task<Void, Never>?
    private var lastHookRefresh = Date.distantPast
    /// The pass a freshly surfaced AWS-login need starts (rebuildAwsLogins).
    private var awsNeedRefresh: Task<Void, Never>?
    /// That pass writes the mirror snapshot past the exporter's throttle.
    private var mirrorExportDue = false

    /// The snapshot runs git in the session's repository, off the main
    /// thread; the first checkpoint of a session is logged, the rest are
    /// quiet (one per prompt would drown the Activity pane). A failure
    /// is logged once per session too.
    private var checkpointed: Set<String> = []
    private func recordCheckpoint(sessionId: String, cwd: String, subject: String) {
        let first = !checkpointed.contains(sessionId)
        checkpointed.insert(sessionId)
        let repo = (cwd as NSString).lastPathComponent
        Task.detached(priority: .utility) { [weak self] in
            do {
                guard let made = try Checkpoints.snapshot(cwd: cwd, sessionId: sessionId, subject: subject) else { return }
                if first {
                    await MainActor.run { self?.logEvent("other", icon: "clock.arrow.2.circlepath",
                                                         "checkpointing \(repo) — \(made.subject)") }
                }
            } catch {
                if first {
                    await MainActor.run { self?.logEvent("other", icon: "exclamationmark.triangle",
                                                         "checkpoint of \(repo) failed: \(error)") }
                }
            }
        }
    }
    static let hookRefreshSpacing: TimeInterval = 30

    /// `phoneUnlessRevival`: a phone showing the all-dead countdown activity
    /// (or about to get its start alert) already has this news — the Mac
    /// banner still posts.
    func notify(_ body: String, phoneUnlessRevival: Bool = false) {
        Notifier.post(title: "Infinitus", body: body)
        liveActivityPusher.pushAlert(title: "Infinitus", body: body, unlessRevival: phoneUnlessRevival)
    }
    private let awake = KeepAwake()
    /// Seeded with what the triggers remembered before the last relaunch
    /// (#98, #231): AWS-login needs already pushed (`failedAt` comes from
    /// the transcript line, so the key is stable across launches), the
    /// last-alive warning, the busy stretch.
    private lazy var pushTriggers = PushTriggers(memory: persistedPushMemory)
    private lazy var persistedPushMemory: PushTriggers.Memory = {
        if let data = defaults.data(forKey: Self.pushMemoryKey),
           let memory = try? JSONDecoder().decode(PushTriggers.Memory.self, from: data) { return memory }
        // Before the blob only the AWS keys were kept.
        return PushTriggers.Memory(announcedAwsLogins: Set(defaults.stringArray(forKey: Self.announcedAwsLoginsKey) ?? []))
    }()
    static let pushMemoryKey = "push_triggers_memory"
    static let announcedAwsLoginsKey = "push_announced_aws_logins"
    private let defaults: UserDefaults
    static let playgroundSuite = "run.infinitus.playground"

    /// Custom skins from themes.json, loaded at launch and on demand
    /// (the Display pane reloads when it appears).
    @Published var customThemes: [RowTheme] = RowTheme.loadCustom()
    var availableThemes: [RowTheme] { RowTheme.builtins + customThemes }
    var rowTheme: RowTheme {
        availableThemes.first { $0.id == gamification } ?? .off
    }
    func reloadCustomThemes() { customThemes = RowTheme.loadCustom() }

    /// Popup scale factor — applied as a measured scaleEffect (macOS has
    /// no Dynamic Type; see PopupScale).
    var popupScale: CGFloat {
        switch popupTextSize {
        case "large": return 1.15
        case "xlarge": return 1.3
        case "huge": return 1.5
        default: return 1
        }
    }

    var title: String {
        if titleIconOnly { return "" }
        return TitleFormatter.format(
            account: accounts.first(where: { $0.active }),
            prefs: TitlePrefs(showAccountName: showAccountName,
                              titlePct: titlePct, titleScoped: titleScoped,
                              titleRemaining: titleRemaining,
                              titleReset: titleReset),
            icon: "")  // the status button wears MenuBarGlyph instead
    }

    /// One-time prefs adoption from the pre-2026-08-30 bundle id
    /// (io.github.claude-swap.CswapBar.g2). Bundled runs only — the
    /// unbundled domain is per-executable name and unaffected. Copies,
    /// never moves: the old domain stays for rollback. Locally-set keys win.
    /// First launch under a new bundle id copies the previous id's
    /// prefs domain (the bundled app's UserDefaults.standard IS the
    /// bundle id): com.huuloc.limitless (2026-08-30 → 2026-09-03), and
    /// before it the CswapBar g2 domain. Each hop runs once; existing
    /// keys are never overwritten.
    private static func migrateLegacyDefaults() {
        let std = UserDefaults.standard
        for (domain, marker) in [("com.huuloc.infinitus", "migrated_from_huuloc_id"),
                                 ("com.huuloc.limitless", "migrated_from_limitless_id"),
                                 ("io.github.claude-swap.CswapBar.g2", "migrated_from_g2")] {
            guard !std.bool(forKey: marker), let legacy = std.persistentDomain(forName: domain) else { continue }
            for (key, value) in legacy where std.object(forKey: key) == nil {
                std.set(value, forKey: key)
            }
            std.set(true, forKey: marker)
        }
    }

    init(playground: Bool = false) {
        isPlayground = playground
        // Playground prefs sandbox: reads SEED from the user's live
        // settings (registration domain, volatile), writes land in a
        // private suite that now PERSISTS across launches (user
        // 2026-08-31: "persist playground state with selected
        // changes") — still never touching real prefs. Reset wipes the
        // suite back to the live-settings seed.
        if playground {
            let d = UserDefaults(suiteName: Self.playgroundSuite)!
            d.register(defaults: UserDefaults.standard.dictionaryRepresentation())
            defaults = d
        } else {
            defaults = UserDefaults.standard
        }
        Self.migrateLegacyDefaults()
        debugMenu = UserDefaults.standard.bool(forKey: "debug_menu")
        showAccountName = defaults.object(forKey: "show_account_name") as? Bool ?? true
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        titlePct = TitlePrefs.pctChoices.contains(pct) ? pct : "both"
        titleScoped = defaults.object(forKey: "title_scoped") as? Bool ?? false
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        refreshInterval = TitlePrefs.refreshChoices.contains(interval) ? interval : 60
        // Any string is allowed — resolution falls back to the plain theme
        // when the id names neither a built-in nor a custom theme.
        gamification = defaults.string(forKey: "gamification_style")
            ?? ((defaults.object(forKey: "gamified_rows") as? Bool ?? false) ? "rpg" : "off")
        compactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        footerActionsHidden = defaults.object(forKey: "footer_actions_hidden") as? Bool ?? false
        titleRemaining = defaults.object(forKey: "title_remaining") as? Bool ?? false
        let reset = defaults.string(forKey: "title_reset") ?? "countdown"
        titleReset = TitlePrefs.resetChoices.contains(reset) ? reset : "countdown"
        titleIconOnly = defaults.object(forKey: "title_icon_only") as? Bool ?? false
        popoverPinned = defaults.object(forKey: "popover_pinned") as? Bool ?? false
        revivalPanelShown = defaults.object(forKey: "revival_panel") as? Bool ?? true
        sessionAutoNames = defaults.object(forKey: "session_auto_names") as? Bool ?? true
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        introStyle = defaults.string(forKey: "intro_style") ?? "top"
        introSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        introTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        burnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        chatHeader = defaults.string(forKey: "chat_header") ?? "compact"
        // Local: init reads it again below before every stored
        // property is set (two-phase init forbids self.mockMode there).
        // `bool(forKey:)`, not `object as? Bool`: the argument domain of
        // a dev launch (`-mock_mode YES`) holds the String "YES", which
        // only the typed getter reads as true (#249).
        let mock = defaults.bool(forKey: "mock_mode")
        mockMode = mock
        cswapEnabled = defaults.object(forKey: "engine_cswap_enabled") as? Bool ?? true
        swapdEnabled = defaults.object(forKey: "engine_swapd_enabled") as? Bool ?? false
        cliproxyEnabled = defaults.object(forKey: "engine_cliproxy_enabled") as? Bool ?? false
        nineRouterEnabled = defaults.object(forKey: "engine_9router_enabled") as? Bool ?? false
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
        keepAwakeDisplay = defaults.object(forKey: "keep_awake_display") as? Bool ?? true
        sortByHeadroom = defaults.object(forKey: "sort_headroom") as? Bool ?? true
        mirrorLANEnabled = defaults.object(forKey: "mirror_lan_enabled") as? Bool ?? false
        mirrorTunnelEnabled = defaults.object(forKey: "mirror_tunnel_enabled") as? Bool ?? false
        mirrorRendezvousEnabled = defaults.object(forKey: "mirror_rendezvous_enabled") as? Bool ?? true
        mirrorNamedTunnelEnabled = defaults.bool(forKey: NamedTunnel.enabledKey)
        mirrorNamedTunnelHost = defaults.string(forKey: NamedTunnel.hostnameKey) ?? ""
        // One token per install, minted the first time anyone looks.
        let storedToken = defaults.string(forKey: "mirror_pair_token") ?? ""
        mirrorPairToken = storedToken.isEmpty ? MirrorPairing.generateToken() : storedToken
        // Push triggers default ON — they exist because they were asked for.
        pushSessionsDone = defaults.object(forKey: "push_sessions_done") as? Bool ?? true
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
        pushWaiting = defaults.object(forKey: "push_waiting") as? Bool ?? true
        pushAwsLogin = defaults.object(forKey: "push_aws_login") as? Bool ?? true
        pushRevived = defaults.object(forKey: "push_revived") as? Bool ?? true
        reviveLeadMinutes = defaults.object(forKey: "revive_lead_minutes") as? Int ?? 10
        liveActivityRateSeconds = defaults.object(forKey: "live_activity_rate_seconds") as? Int ?? 5
        machineNameOverride = defaults.string(forKey: MachineName.overrideKey) ?? ""
        sessionHost = defaults.string(forKey: "session_host") ?? "auto"
        checkpointsEnabled = defaults.object(forKey: "checkpoints_enabled") as? Bool ?? true
        menuBarThemed = defaults.object(forKey: "menubar_themed") as? Bool ?? true
        menuBarEffects = defaults.object(forKey: "menubar_effects") as? Bool ?? true
        if playground {
            // Isolation is the contract: no demo script, no data at all
            // (never fall back to the real engine here).
            if let demo = Self.demoScriptPath() {
                cswap = CswapCLI(binaryPath: demo)
            } else {
                cswap = nil
                lastError = "demo script missing — playground has no data"
            }
        } else if mock, let demo = Self.demoScriptPath() {
            cswap = CswapCLI(binaryPath: demo)
        } else if let path = CswapLocator.locate() {
            cswap = CswapCLI(binaryPath: path)
            if mock {
                lastError = "demo script missing — running the real engine"
            }
        } else {
            cswap = nil
            lastError = "cswap not found — install it (uv tool install claude-swap)"
        }
        swapd = playground ? nil : SwapdLocator.locate().map(SwapdCLI.init(binaryPath:))
        // A freshly minted token has to survive the launch that made it:
        // property initialisation doesn't run `didSet`.
        if storedToken.isEmpty { defaults.set(mirrorPairToken, forKey: "mirror_pair_token") }
        if !playground { sync.attach(model: self) }
        if let cswap, cswapEnabled || playground { registry.register(CswapEngine(cli: cswap)) }
        // After cswap on purpose: while both are on, the Claude fleet the
        // popup chrome reasons about stays the one cswap reports.
        if let swapd, swapdEnabled { registry.register(SwapdEngine(cli: swapd)) }
        else if swapdEnabled, !playground {
            lastError = "swapd is enabled but no binary was found — install it (cargo install --path swapd)"
        }
        // The proxy is never part of the playground (isolation contract)
        // and needs its key before it can be an engine at all.
        if !playground, cliproxyEnabled,
           let url = URL(string: cliproxyBaseURL),
           let key = Keychain.read(account: cliproxyBaseURL) {
            registry.register(CLIProxyEngine(
                baseURL: url, managementKey: key, ledgerURL: Self.cliproxyLedgerURL))
        } else if !playground, cliproxyEnabled {
            lastError = "CLIProxyAPI is enabled but no management key is readable — enter it in Settings → CLIProxyAPI"
        }
        if !playground, nineRouterEnabled, let url = URL(string: nineRouterBaseURL) {
            // A missing password still registers: 9Router with "require
            // login" off answers loopback anonymously; otherwise the first
            // poll reports unauthorized and the pane says so.
            registry.register(NineRouterEngine(
                baseURL: url,
                password: Keychain.read(account: nineRouterBaseURL, service: Keychain.nineRouterService) ?? ""))
        }
        NSLog("Infinitus engines: %@", registry.engines.map(\.id).joined(separator: ", "))
        // Last run's snapshot renders NOW — the popup otherwise opened
        // as an empty sliver and expanded seconds later when the first
        // `cswap list` returned, eating the intro (user 2026-08-30).
        // Live values roll in over it via the numeric transitions.
        if !playground,
           let data = try? Data(contentsOf: Self.snapshotCacheURL),
           let cached = try? JSONDecoder().decode([EngineFleet].self, from: data) {
            for fleet in cached where registry.engine(id: fleet.engineID) != nil {
                registry.state(for: fleet).seed(fleet)
            }
        }
        // A mock/playground instance must never start a real cold
        // backfill or write real App Support caches under
        // Infinitus/stats/ (matches the historyRecorder guard above).
        statsModel.enabled = !isPlayground && !mockMode
        statsModel.leases = mirrorServer.leases
        statsModel.scanFeedsTeam = { [weak self] in self?.team.enabled == true }
        if !isPlayground, !mockMode {
            let namer = SessionNamer(appSupport: AppSupport.root())
            namer.enabled = sessionAutoNames
            sessionProgress.namer = namer
        }
        machineModel.host = self
    }

    /// App-side cache of our own subprocess output (never an engine
    /// internal file).
    static let snapshotCacheURL: URL = {
        return AppSupport.root().appendingPathComponent("snapshot-cache.json")
    }()

    /// The popup just opened with data already on screen (cache or an
    /// earlier snapshot): play the launch flash on the same clock the
    /// data-landing path uses. No-op while empty — that case is handled
    /// by firstLoad in refreshSnapshot.
    func introOpened() {
        guard !accounts.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.switchFlashTick += 1
        }
    }

    /// Re-read the persisted display prefs after an iCloud sync pull — the
    /// @Published values were initialized once at launch and would
    /// otherwise never see the imported defaults.
    func reloadPrefs() {
        showAccountName = defaults.object(forKey: "show_account_name") as? Bool ?? true
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        titlePct = TitlePrefs.pctChoices.contains(pct) ? pct : "both"
        titleScoped = defaults.object(forKey: "title_scoped") as? Bool ?? false
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        refreshInterval = TitlePrefs.refreshChoices.contains(interval) ? interval : 60
        gamification = defaults.string(forKey: "gamification_style") ?? "off"
        compactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        footerActionsHidden = defaults.object(forKey: "footer_actions_hidden") as? Bool ?? false
        titleRemaining = defaults.object(forKey: "title_remaining") as? Bool ?? false
        let reset = defaults.string(forKey: "title_reset") ?? "countdown"
        titleReset = TitlePrefs.resetChoices.contains(reset) ? reset : "countdown"
        titleIconOnly = defaults.object(forKey: "title_icon_only") as? Bool ?? false
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
        keepAwakeDisplay = defaults.object(forKey: "keep_awake_display") as? Bool ?? true
        sortByHeadroom = defaults.object(forKey: "sort_headroom") as? Bool ?? true
        pushSessionsDone = defaults.object(forKey: "push_sessions_done") as? Bool ?? true
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
        pushWaiting = defaults.object(forKey: "push_waiting") as? Bool ?? true
        pushAwsLogin = defaults.object(forKey: "push_aws_login") as? Bool ?? true
        pushRevived = defaults.object(forKey: "push_revived") as? Bool ?? true
        reviveLeadMinutes = defaults.object(forKey: "revive_lead_minutes") as? Int ?? 10
        liveActivityRateSeconds = defaults.object(forKey: "live_activity_rate_seconds") as? Int ?? 5
        machineNameOverride = defaults.string(forKey: MachineName.overrideKey) ?? ""
        sessionHost = defaults.string(forKey: "session_host") ?? "auto"
        checkpointsEnabled = defaults.object(forKey: "checkpoints_enabled") as? Bool ?? true
        menuBarThemed = defaults.object(forKey: "menubar_themed") as? Bool ?? true
        menuBarEffects = defaults.object(forKey: "menubar_effects") as? Bool ?? true
    }

    /// Playground reset (user 2026-08-31): wipe the sandbox suite so
    /// every knob falls back to the registration seed — the user's
    /// live settings — then re-read. Playground models only.
    func resetPlaygroundPrefs() {
        guard isPlayground else { return }
        defaults.removePersistentDomain(forName: Self.playgroundSuite)
        reloadPrefs()
        introStyle = defaults.string(forKey: "intro_style") ?? "top"
        introSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        introTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        burnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        chatHeader = defaults.string(forKey: "chat_header") ?? "compact"
    }

    // MARK: battle plan (#7)

    private func updateBattlePlan(_ list: AccountList) {
        let now = Date().timeIntervalSince1970
        let fresh = UsageHistory.samples(accounts: list.accounts)
        var seen = Set(recentSamples.map(\.dedupeKey))
        for s in fresh where seen.insert(s.dedupeKey).inserted { recentSamples.append(s) }
        recentSamples.removeAll { $0.t < now - UsageForecast.weeklyLookback }
        let states = list.accounts.map { a in
            WindowPlanner.AccountState(
                number: a.number, email: a.email, active: a.active,
                disabled: a.disabled ?? false,
                fiveHourPct: a.usage?.fiveHour?.pct,
                fiveHourResetsAt: a.usage?.fiveHour?.resetsAt
                    .flatMap(UsageHistory.parseISO)?.timeIntervalSince1970,
                weeklyPct: ([a.usage?.sevenDay?.pct] + (a.usage?.scoped ?? []).map { $0.pct })
                    .compactMap { $0 }.max() ?? 0)
        }
        // Every account at its own measured pace (the detail dashboard);
        // the planner and the fleet drain read the active one's.
        var ratesByEmail: [String: [String: Double]] = [:]
        for a in list.accounts where ratesByEmail[a.email] == nil {
            ratesByEmail[a.email] = WindowTelemetry.burnRates(recentSamples, email: a.email, now: now)
        }
        let rates = list.accounts.first { $0.active }.flatMap { ratesByEmail[$0.email] } ?? [:]
        // Projections extrapolate from when the engine READ the
        // percentages (usageFetchedAt → the sample's t), not from this
        // poll's clock: anchored to `now` they crept later between
        // fetches and snapped back on each new sample.
        let measuredAt = fresh.map(\.t).max() ?? now
        let plan = WindowPlanner.plan(accounts: states, burnPctPerHour: rates["5h"],
                                      busySessions: list.liveSessions?.busy ?? 0, now: now,
                                      measuredAt: measuredAt)
        if plan != battlePlan { battlePlan = plan }
        let inputs = list.accounts.map { a in
            UsageForecast.AccountInput(
                number: a.number, email: a.email, alias: a.alias, active: a.active,
                disabled: a.disabled ?? false,
                fiveHour: window(a.usage?.fiveHour), sevenDay: window(a.usage?.sevenDay),
                scoped: Dictionary((a.usage?.scoped ?? []).compactMap { sc in
                    window(sc).map { (sc.name ?? "?", $0) }
                }, uniquingKeysWith: { a, _ in a }))
        }
        let next = UsageForecast.build(accounts: inputs, ratesByEmail: ratesByEmail, now: now,
                                       measuredAt: measuredAt)
        // Republish only when a projection moved — with the sample-time
        // anchor that is a new sample or a new rate, not every poll.
        if next.accounts != forecast?.accounts || next.allDeadAt != forecast?.allDeadAt {
            forecast = next
        }
        let relay = LiveForecastRelay.shared
        relay.forecast = forecast
        relay.plan = battlePlan
        relay.tokenRate = sessionProgress.tokenRate
        if relay.theme.id != rowTheme.id { relay.theme = rowTheme }
    }

    private func window(_ w: UsageWindow?) -> UsageSample.Window? {
        guard let w else { return nil }
        return .init(pct: w.pct, resetsAt: w.resetsAt.flatMap(UsageHistory.parseISO)?.timeIntervalSince1970)
    }

    /// The last 100 durable events back into the Activity tail (#338),
    /// under whatever this launch has logged meanwhile — those are on
    /// disk too by now, so only events from before launch are taken.
    private func seedEventLog() {
        guard !isPlayground, !mockMode else { return }
        let launchedAt = launchedAt
        Task.detached(priority: .utility) { [weak self, eventStore] in
            let past = await eventStore.load().filter { $0.at < launchedAt }.suffix(100)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.eventLog = past.map { EventEntry(at: $0.at, icon: $0.icon, text: $0.text) } + self.eventLog
                if self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
            }
        }
    }

    /// Seed the burn-rate buffer from this machine's own history file.
    private func seedRecentSamples() {
        guard !isPlayground, !mockMode else { return }
        let url = UsageHistoryRecorder.localURL
        Task.detached(priority: .utility) { [weak self] in
            let cutoff = Date().timeIntervalSince1970 - UsageForecast.weeklyLookback
            let recent = UsageHistory.load(url: url).filter { $0.t >= cutoff }
            await MainActor.run { [weak self] in
                guard let self, self.recentSamples.isEmpty else { return }
                self.recentSamples = recent
            }
        }
    }

    var canIgnite: Bool { capabilities.contains(.ignite) }

    /// Ignite account n on that fleet's engine and publish what the engine
    /// then says about it; the returned instant is when the window it
    /// started ends, or nil when nothing could say.
    ///
    /// A `.refreshAccount` engine (swapd) fetches THAT account past its
    /// serve floor and answers with the fleet, so the reset is the real
    /// one; everything else waits for the next full snapshot, whose rows
    /// may still carry the pre-ignite window.
    @discardableResult
    func igniteAndPublish(_ state: FleetState, number: Int) async throws -> Date? {
        let engine = state.engine, provider = state.provider
        try await engine.ignite(fleet: provider, number: number)
        guard engine.capabilities.contains(.refreshAccount) else {
            await refreshSnapshot()
            return state.accounts.first { $0.number == number }?.usage?.fiveHour?.resetsAt
                .flatMap(UsageHistory.parseISO)
        }
        let fleet = overlayingOwnedStatus(try await engine.refresh(fleet: provider, number: number))
        _ = registry.state(for: fleet).apply(fleet)
        return fleet.accounts.first { $0.number == number }?.usage?.fiveHour?.resetsAt
            .flatMap(UsageHistory.parseISO)
    }

    /// Manual ignition (#7 MVP step 3) through the primary fleet's engine
    /// (`AccountEngine.ignite`, capability-gated): one tiny request as
    /// account n so its 5h clock starts now; the fleet stays put. Outcome
    /// in the event log; ~1K weekly tokens on n.
    func ignite(_ number: Int) {
        guard let primary, canIgnite, !isPlayground, igniting == nil else { return }
        igniting = number
        let fleet = primary
        let name = accounts.first { $0.number == number }
            .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(number)"
        logEvent("ignite", icon: "flag.checkered", "igniting \(name)'s 5h window")
        Task { [weak self] in
            var result: IgniteResult?
            do {
                // now + 5 h only when nothing knows better: an engine that
                // refreshes one account answers with the window the run
                // just opened (#338: "nothing happens" after an ignite).
                let resets = try await self?.igniteAndPublish(fleet, number: number)
                    ?? Date().addingTimeInterval(5 * 3_600)
                let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
                result = IgniteResult(text: "\(name)'s window started — resets \(f.string(from: resets))", ok: true)
                self?.logEvent("ignite", icon: "flag.checkered", "ignited \(name) — window started, resets \(f.string(from: resets))")
            } catch {
                result = IgniteResult(text: "ignite \(name) failed: \((error as? CLIError)?.message ?? error.localizedDescription)", ok: false)
                self?.logEvent("other", icon: "exclamationmark.triangle", result!.text)
            }
            self?.igniting = nil
            self?.igniteResult = result
            try? await Task.sleep(for: .seconds(10))
            if self?.igniteResult == result { self?.igniteResult = nil }
        }
    }

    /// Idempotent: called from app init so the supervised engine starts at
    /// LAUNCH — a window-style MenuBarExtra may not build its content view
    /// until the first click, and rumps started its engine immediately.
    func startFeeds() {
        detectOnboarding()
        seedEventLog()
        seedRecentSamples()
        // Same gate as logEvent: a mock instance must not rewrite the
        // real events log either.
        if !isPlayground, !mockMode {
            Task.detached(priority: .utility) { [eventStore] in await eventStore.prune() }
            Task.detached(priority: .utility) { [weak self] in
                let swept = Self.sweepOwnedOrphans()
                guard !swept.isEmpty else { return }
                await MainActor.run { self?.logEvent("other", icon: "terminal", "swept \(swept.count) orphaned headless sessions") }
            }
        }
        resume.log = { [weak self] icon, text in
            self?.logEvent("nudge", icon: icon, text)
        }
        resume.push = { [weak self] text in
            self?.push(text)
        }
        mirrorServer.log = { [weak self] icon, text in
            self?.logEvent("other", icon: icon, text)
        }
        mirrorServer.teamControl.onAudit = { [weak self] audit, name in
            Task { @MainActor in self?.recordTeamControl(audit, driverName: name) }
        }
        // Both re-apply the listener first: joining, leaving or flipping
        // Discoverable decides whether the team keeps it up (#356).
        team.onLoaded = { [weak self] in self?.reapplyMirrorLANForTeam(); self?.mirrorServer.refreshTeamControl() }
        team.onActed = { [weak self] in self?.reapplyMirrorLANForTeam(); self?.mirrorServer.refreshTeamStanding(force: true) }
        // #220 §5.4: a leader's hostname for this Mac — token to the keychain,
        // the named tunnel on. The LAN listener is the user's switch, not ours.
        team.onHostname = { [weak self] hostname, from in
            guard let self else { return }
            let host = NamedTunnel.normalizeHostname(hostname.hostname)
            guard !host.isEmpty else { return }
            // A re-give mints a fresh token for the same host: the running
            // cloudflared holds the old one, so it restarts below.
            if namedTunnel.isRunning, namedTunnel.hostname == host { namedTunnel.stop() }
            NamedTunnel.setToken(hostname.token, for: host)
            mirrorNamedTunnelHost = host
            mirrorNamedTunnelEnabled = true
            let who = team.snapshot?.members.first { $0.kid == from }?.name ?? String(from.prefix(8))
            let hint = mirrorLANEnabled ? "" : " — turn on the LAN listener to run it"
            logEvent("team", icon: "network", "\(who) gave this Mac the hostname \(host)\(hint)")
        }
        // Team session control (#220): the phone's delivery path, origin
        // "team". Wired here, not in applyMirrorLAN — the store lane runs
        // with the LAN listener off.
        mirrorServer.teamControl.setDeliver { [weak self] pid, request, origin in
            self?.deliverSessionInput(pid: pid, request, from: origin)
                ?? SessionInput.Reply(outcome: "rejected", detail: "app is shutting down")
        }
        team.onFetched = { [mirrorServer] client in mirrorServer.teamControl.storePass(client) }
        quickTunnel.log = { [weak self] icon, text in
            self?.logEvent("other", icon: icon, text)
        }
        namedTunnel.log = quickTunnel.log
        liveActivityPusher.log = quickTunnel.log
        mirrorServer.activityTokens.set { [weak self] registration in
            Task { @MainActor in self?.liveActivityPusher.register(registration) }
        }
        mirrorServer.crashes.set { [weak self] report in
            Task { @MainActor in self?.ingestCrash(report, announce: true) }
        }
        mirrorServer.appUpdate.set { [weak self] in
            guard let self else { return AppUpdate.Reply(outcome: "unavailable", detail: nil) }
            return await self.triggerAppUpdate()
        }
        mirrorServer.accountAction.set { [weak self] request in
            guard let self else { return AccountAction.Reply(outcome: "failed", detail: "app gone") }
            return await self.performAccountAction(request)
        }
        let host = sessionHost
        mirrorServer.sessionStart.set { [weak self] request in
            guard let self else { return SessionStart.Reply(outcome: "failed", detail: "app gone") }
            // The box is synchronous (the terminal launcher blocks too);
            // an owned start awaits the actor from this off-main thread.
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var reply = SessionStart.Reply(outcome: "failed", detail: "start did not complete")
            Task { reply = await self.startSession(request, preferredHost: host); done.signal() }
            done.wait()
            let label = (request.cwd as NSString).lastPathComponent
            let verb = request.resume == nil ? "started" : "resumed"
            let born = request.profile.map { " (profile \($0))" } ?? ""
            Task { @MainActor in
                if reply.outcome == "started", let pid = reply.pid, let birth = SessionBirth(request: request, host: reply.host) {
                    self.recordBirth(pid: pid, birth)
                }
                self.logMirrorInput(reply.outcome == "started" ? "🚀" : "⚠️",
                                    "phone \(verb) a session in \(label)\(born): \(reply.outcome)\(reply.host.map { " via \($0)" } ?? "")")
            }
            return reply
        }
        // A session's hook mode (#163 phase 2) is remembered in its birth
        // across a relaunch, but the hook answers from ToolApprovals'
        // memory — reseed it, or the chip would promise a mode the hook
        // no longer grants.
        let live = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
        for (pid, birth) in sessionBirths {
            guard let record = live.first(where: { Int($0.pid) == pid }), birth.sessionId == record.sessionId else { continue }
            if let mode = birth.hookMode { toolApprovals.setMode(mode, sessionId: record.sessionId) }
            for rule in profileAllowRules(birth) { toolApprovals.add(rule, sessionId: record.sessionId) }
        }
        mirrorServer.pastSessions.set { limit, search in
            PastSessions.Reply(sessions: PastSessions.list(claudeDir: ClaudeSessions.configHome(),
                                                           limit: limit, search: search))
        }
        // The phone's checkpoint routes (#167 phase 2) act on the live
        // session's record — the same lookup `infinitusctl checkpoints`
        // makes; an unknown pid is a 404.
        let session: @Sendable (Int32) -> ClaudeSessionRecord? = { pid in
            ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).first { $0.pid == pid }
        }
        mirrorServer.checkpoints.set(.init(
            list: { pid in
                guard let record = session(pid) else { return nil }
                let list = (try? Checkpoints.list(cwd: record.cwd, sessionId: record.sessionId)) ?? []
                return Checkpoints.Reply(sessionId: record.sessionId, cwd: record.cwd, checkpoints: list)
            },
            diff: { pid, n, m in
                guard let record = session(pid) else { return nil }
                return try? Checkpoints.diff(cwd: record.cwd, sessionId: record.sessionId, from: n, to: m)
            },
            restore: { [weak self] pid, n in
                guard let record = session(pid) else { return nil }
                do {
                    let (restored, backup) = try Checkpoints.restore(cwd: record.cwd, sessionId: record.sessionId, n: n)
                    Task { @MainActor in
                        self?.logEvent("other", icon: "clock.arrow.2.circlepath",
                                       "phone restored \((record.cwd as NSString).lastPathComponent) to checkpoint \(restored.subject)")
                    }
                    return Checkpoints.RestoreReply(outcome: "restored", backup: backup?.n)
                } catch {
                    return Checkpoints.RestoreReply(outcome: "failed", detail: "\(error)")
                }
            }))
        // The phone's Team tab (spec §9 step 8) — every call lands on the
        // main actor, where TeamModel lives.
        mirrorServer.teamMirror.set { [weak self] request in
            guard let team = await MainActor.run(body: { self?.team }) else { return nil }
            return await TeamMirrorHandler.reply(request, team: team)
        }
        team.sources = { [weak self] in self?.teamSources() ?? TeamPublisher.Sources(projectsDir: URL(fileURLWithPath: "/nonexistent"), home: NSHomeDirectory()) }
        // The fixture instance (e2e) publishes what the publisher scans itself.
        let fixture = ProcessInfo.processInfo.environment["INFINITUS_TEAM_PROJECTS"] ?? ""
        team.ownsScan = { [weak self] in fixture.isEmpty && self?.statsModel.enabled == true }
        team.scanEntries = { [weak self] in self?.statsModel.scanEntries }
        team.load()
        crashReports = crashStore.list()
        scanMacCrashReports()
        quickTunnel.onURL = { [weak self] url in self?.publishRendezvous(url) }
        // The tunnels can only point at a bound port, which arrives later.
        mirrorServer.onReady = { [weak self] _ in
            self?.applyQuickTunnel()
            self?.applyNamedTunnel()
        }
        applyMirrorLAN()
        // The Mac's own "Needs AWS login" line follows the transcripts
        // whether or not the phone's mirror is on (it lived inside the
        // mirror setup, so a LAN-off or mock-mode instance never rebuilt
        // the list — caught by the e2e gate, 2026-09-03).
        awsLoginNeedsWatch = sessionProgress.$byPid
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildAwsLogins() }
        // The ledger's finished logins reach that list only once the
        // runner exists, and nothing else touches it until a login is
        // asked for — so after every relaunch a met need came back as
        // "Log in here" for as long as the failing result stayed in the
        // transcript's window (Overlord, for hours, 2026-09-07).
        _ = awsLoginRunner
        // The playground gets a socket only where INFINITUS_CONTROL_SOCKET
        // points — never the real app's path.
        if !isPlayground || ProcessInfo.processInfo.environment["INFINITUS_CONTROL_SOCKET"] != nil {
            controlServer.start()
        }
        guard supervisor == nil, refreshTask == nil else { return }
        if let cswap, !isPlayground, cswapEnabled { startEngine(binary: cswap.binaryPath) }
        guard !registry.engines.isEmpty else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                // Read the pref each pass so an interval change applies on
                // the next tick without restarting the task.
                let seconds = await MainActor.run { self?.refreshInterval ?? 60 }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
        // The tok/min line of the phone's working card, on its own beat: the
        // token rate is fresh within a second of a transcript write, the
        // fleet refresh above is a minute apart.
        rateTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = await MainActor.run { () -> Int in
                    guard let self else { return 0 }
                    if self.liveActivityRateSeconds > 0 {
                        self.liveActivityPusher.pushRate(self.sessionProgress.tokenRate)
                    }
                    return self.liveActivityRateSeconds
                }
                try? await Task.sleep(for: .seconds(max(seconds, 1)))
            }
        }
    }

    /// `POST /app/update` (#121): the phone's own trigger for this Mac's
    /// update, reusing the same BrewUpdater the About pane's button
    /// drives so the two never run two upgrades at once.
    private func triggerAppUpdate() -> AppUpdate.Reply {
        guard BrewUpdater.channel != .source else {
            return AppUpdate.Reply(outcome: "unavailable",
                                   detail: "this Mac runs a source build — rebuild from the repo")
        }
        guard appUpdateVersion != nil else {
            return AppUpdate.Reply(outcome: "upToDate", detail: nil)
        }
        brewUpdater?.upgrade()
        return AppUpdate.Reply(outcome: "started",
                               detail: "brew is upgrading Infinitus; the Mac relaunches when it's done")
    }

    /// Starts or stops the phone companion's LAN listener (#9). Never in
    /// the playground: it seeds from the real defaults and would
    /// advertise a second service with the same machine name.
    /// The team hooks' cheap form (#356): re-run the full apply only when
    /// the listener's up/down answer changed — `applyMirrorLAN` rewires
    /// every handler and drops the thumbnail cache, too much for every load.
    private func reapplyMirrorLANForTeam() {
        let wanted = mirrorLANEnabled || team.discoverable || team.inTeam
        if wanted != mirrorServer.isListening { applyMirrorLAN() }
    }

    private func applyMirrorLAN() {
        // Mock mode only swaps the CLI — sessions/usage in the snapshot
        // are still this machine's real ones, so a dev instance must
        // never advertise them on the LAN. `mirror_lan_allow_mock` lifts
        // that for a dev COPY of the binary only (the shipped process is
        // named Infinitus), so the server can be exercised end to end.
        let mockAllowed = mockMode
            && ProcessInfo.processInfo.processName != "Infinitus"
            && defaults.bool(forKey: "mirror_lan_allow_mock")
        let allowed = !isPlayground && (!mockMode || mockAllowed)
        // Team Nearby rides the same listener (#356): a discoverable Mac
        // or a team member keeps it up with the phone switch off, and the
        // phone routes then drop their connections. The tunnels stay the
        // phone's alone.
        let teamWantsLAN = team.discoverable || team.inTeam
        team.nearbyAvailable = allowed
        mirrorServer.phoneEnabled = mirrorLANEnabled
        guard allowed, mirrorLANEnabled || teamWantsLAN else {
            mirrorServer.stop()
            quickTunnel.stop()
            namedTunnel.stop()
            return
        }
        if !mirrorLANEnabled {
            quickTunnel.stop()
            namedTunnel.stop()
        }
        let payload = mirrorServer.payload
        Task { [mirrorExporter] in await mirrorExporter.attach(payload: payload) }
        mirrorServer.start(machineName: machineName,
                           token: mirrorPairToken)
        let ownedBox = ownedBox
        let feedTails = FeedTails()
        mirrorServer.sessionFeed.set { pid, limit, since, wait, rows in
            let claudeDir = ClaudeSessions.configHome()
            let owned = ownedBox.existing.flatMap { $0.ownedPids.contains(pid) ? $0 : nil }
            SessionFeedReader.waitForChange(pid: pid, claudeDir: claudeDir, since: since, wait: wait,
                                            decorate: { stamp in owned.map { OwnedFeed.decorate(stamp, pending: $0.pending(pid: pid), limits: $0.limits(pid: pid)) } ?? stamp },
                                            wake: owned?.wake)
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
            else { return nil }
            guard var feed = feedTails.read(record: record, claudeDir: claudeDir, limit: limit)
            else { return nil }
            if let owned { feed = OwnedFeed.augment(feed, pending: owned.pending(pid: pid), limits: owned.limits(pid: pid)) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard rows, let timeline = feed.timeline,
                  let data = try? encoder.encode(feed),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rowData = try? encoder.encode(ThreadFeedPresentation.deriveExpanded(timeline)),
                  let rowJSON = try? JSONSerialization.jsonObject(with: rowData)
            else { return try? encoder.encode(feed) }
            object["rows"] = rowJSON
            return try? JSONSerialization.data(withJSONObject: object)
        }
        mirrorServer.awsLogin.set(
            start: { [weak self] request in
                guard let self else { return AwsLogin.Reply(ok: false, error: "app gone") }
                let items = await MainActor.run { self.awsLogins }
                let provider = request.provider ?? AwsLogin.inferProvider(profile: request.profile, pid: request.pid, items: items)
                return await self.startAwsLogin(provider: provider, profile: request.profile, pid: request.pid,
                                                local: request.local ?? false, remote: request.remote)
            },
            code: { [weak self] request in
                guard let self else { return AwsLogin.Reply(ok: false, error: "app gone") }
                let items = await MainActor.run { self.awsLogins }
                let provider = request.provider ?? AwsLogin.inferProvider(profile: request.profile, pid: nil, items: items)
                return await self.submitAwsLoginCode(provider: provider, profile: request.profile, code: request.code)
            },
            callback: { [weak self] request in
                guard let self else { return AwsLogin.Reply(ok: false, error: "app gone") }
                let items = await MainActor.run { self.awsLogins }
                let provider = request.provider ?? AwsLogin.inferProvider(profile: request.profile, pid: nil, items: items)
                return await self.awsLoginRunner.relay(provider: provider, profile: request.profile, url: request.url)
            })
        let thumbnails = ThumbnailCache()
        mirrorServer.sessionImage.set { pid, id in
            let key = "\(pid)/\(id)"
            if let hit = thumbnails[key] { return (hit, "image/jpeg") }
            let claudeDir = ClaudeSessions.configHome()
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
                  let image = SessionFeedReader.imageData(record: record, id: id, claudeDir: claudeDir,
                                                          attachmentsDir: SessionInput.defaultAttachmentsDir),
                  let thumb = ImageThumbnail.jpeg(image.data, maxPixels: 640) else { return nil }
            thumbnails[key] = thumb
            return (thumb, "image/jpeg")
        }
        // T3 attention (#223 phase 3): settle / snooze / pin one session —
        // the mirror's attention route and the workspace window share
        // `Self.applyAttention` (a static func: `timelineCache` is a
        // `lazy var`, main-actor-isolated, so it must be captured here
        // on the actor rather than touched from the nonisolated closure).
        let timelineCache = timelineCache, attentionStore = attentionStore
        mirrorServer.attention.set { pid, request in
            Self.applyAttention(pid: pid, request, timelineCache: timelineCache, attentionStore: attentionStore, ownedBox: ownedBox)
        }
        // `GET /sessions/<pid>/commands` (#223, the phone's `/` popover): the
        // session's cwd decides the list; the reply is cached per cwd for a
        // few seconds in the handler.
        let commandsCache = MirrorCommandsCache()
        mirrorServer.commands.set { pid in
            let claudeDir = ClaudeSessions.configHome()
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }) else { return nil }
            return commandsCache.data(cwd: record.cwd) {
                try? JSONEncoder().encode(SlashCommands.discover(cwd: record.cwd, claudeDir: claudeDir))
            }
        }
        // The phone's file browser (#223, spec E): the session's cwd is the
        // workspace, and `T3ProjectFiles` decides every refusal — the route
        // only maps its status.
        mirrorServer.files.set(.init(
            list: { pid in
                T3ProjectFiles.list(pid: pid, sessions: ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()))
            },
            read: { pid, path in
                T3ProjectFiles.answer(pid: pid, path: path,
                                      sessions: ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()))
            }))
        // The phone's terminal (#507 step 3): the session's cwd is where the
        // shell opens, and `TerminalHost` owns everything after that — the
        // routes only map its result to a status. An unknown pid is a 404.
        let terminalHost = terminalHost
        mirrorServer.terminal.set(.init(
            open: { [weak self] pid, request in
                guard let record = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
                    .first(where: { $0.pid == pid }) else { return nil }
                let outcome = terminalHost.open(pid: pid, cwd: record.cwd, request: request)
                if case .success(let opened) = outcome, opened.created {
                    Task { @MainActor in
                        self?.logEvent("other", icon: "apple.terminal",
                                       "phone opened a terminal in \((record.cwd as NSString).lastPathComponent)")
                    }
                }
                return outcome
            },
            attach: { pid, id, since, sink in
                terminalHost.attach(pid: pid, id: id, since: since, sink: sink)
            },
            detach: { terminalHost.detach($0) },
            write: { pid, id, request in terminalHost.write(pid: pid, id: id, request) },
            resize: { pid, id, request in terminalHost.resize(pid: pid, id: id, request) },
            close: { pid, id in terminalHost.close(pid: pid, id: id) }))
        // Sequence-resumable timeline and the pre-pairing descriptor (#223 phase 4).
        let sequenceLog = sequenceLog
        mirrorServer.timeline.set { pid, after, epoch, wait in
            let claudeDir = ClaudeSessions.configHome()
            let owned = ownedBox.existing.flatMap { $0.ownedPids.contains(pid) ? $0 : nil }
            guard var record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
                  var timeline = timelineCache.timeline(record: record, claudeDir: claudeDir) else { return nil }
            // Rebuilt first, so a change since the client's last reply
            // answers at once; the long-poll only when THIS pid has
            // nothing after the cursor (a gap snapshots without waiting).
            // Same wait rule as /tail: the record stamp, an owned pid's
            // parked prompts folded in and its actor's wake-up.
            if wait > 0, let after, sequenceLog.events(pid: pid, after: after)?.isEmpty == true {
                let decorate = { (stamp: String) in owned.map { OwnedFeed.decorate(stamp, pending: $0.pending(pid: pid), limits: $0.limits(pid: pid)) } ?? stamp }
                SessionFeedReader.waitForChange(pid: pid, claudeDir: claudeDir,
                                                since: SessionFeedReader.stamp(record: record, claudeDir: claudeDir).map(decorate),
                                                wait: wait, decorate: decorate, wake: owned?.wake)
                if let fresh = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
                   let rebuilt = timelineCache.timeline(record: fresh, claudeDir: claudeDir) {
                    record = fresh; timeline = rebuilt
                }
            }
            let full = timeline.appending(limits: owned?.limits(pid: pid) ?? []).appending(pending: owned?.pending(pid: pid) ?? [])
            let facts = SessionFacts.derive(timeline: full, status: record.status,
                                            attention: attentionStore.entry(sessionId: record.sessionId))
            _ = sequenceLog.record(pid: pid, facts: facts)
            let reply = TimelineSync.reply(log: sequenceLog, pid: pid, afterSequence: after, epoch: epoch,
                                           timeline: full, facts: facts)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(reply)
        }
        mirrorServer.descriptor.set {
            MirrorDescriptor.current(machineId: MachineIdentity.current(), label: MachineName.current(),
                                     appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        }
        mirrorServer.sessionInput.set { [weak self] pid, request in
            self?.deliverSessionInput(pid: pid, request, from: "phone")
                ?? SessionInput.Reply(outcome: "rejected", detail: "app is shutting down")
        }
        applyQuickTunnel()
        applyNamedTunnel()
    }

    /// One request into a live session, the way the phone's
    /// `POST /sessions/<pid>/input` lands it — and the Mac's own chat
    /// window (#151): a mode change is decided here, "allow for this
    /// session" records the rule then answers Yes, everything else goes
    /// through `SessionInput.deliver`. Off the main actor; hops in for
    /// the log and the births.
    /// Settle / snooze / pin one session (#223 phase 3) — the mirror's
    /// attention route and the workspace window (`T3WindowModel.attention`)
    /// share it. A static func, not an instance method: `timelineCache` is
    /// a `lazy var` (main-actor-isolated), so callers capture the three
    /// pieces on the actor and pass them in, rather than this touching
    /// `self` from whatever thread the caller runs on.
    nonisolated static func applyAttention(pid: Int32, _ request: SessionAttention.Request,
                                           timelineCache: TimelineCache, attentionStore: AttentionStore,
                                           ownedBox: OwnedSessionsBox) -> SessionAttention.Outcome? {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.record(pid: pid, sessionId: request.sessionId, in: ClaudeSessions.list(claudeDir: claudeDir)),
              let timeline = timelineCache.timeline(record: record, claudeDir: claudeDir) else { return nil }
        let pending = ownedBox.existing?.pending(pid: record.pid) ?? []
        return SessionAttention.apply(request, sessionId: record.sessionId,
                                      timeline: timeline.appending(pending: pending),
                                      status: record.status, store: attentionStore)
    }

    nonisolated func deliverSessionInput(pid: Int32, _ request: SessionInput.Request,
                                         from source: String) -> SessionInput.Reply {
            let claudeDir = ClaudeSessions.configHome()
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            // #168: a queued request may name a pid from before a reboot —
            // the session lives on under a new one; its id does not change.
            guard let record = records.first(where: { $0.pid == pid })
                    ?? request.sessionId.flatMap({ id in records.first { $0.sessionId == id } })
            else {
                Task { @MainActor in self.logMirrorInput("⚠️", "\(source) input not delivered: unknown session") }
                return SessionInput.Reply(outcome: "rejected", detail: "session ended")
            }
            // A mode change never reaches the terminal: it is the Mac's
            // own state, decided on the main actor (the births live
            // there). This queue never blocks main, so a hop is safe.
            if request.kind == .mode {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self.setSessionMode(request.text, pid: Int(pid), record: record)
                            ?? SessionInput.Reply(outcome: "rejected", detail: "app is shutting down")
                    }
                }
            }
            // "Allow for this session": remember the rule for the plugin's
            // PreToolUse hook; the request itself goes down as `.approve`,
            // and Core's arm answers it — an owned session gets the wire's
            // allow-for-session, a terminal a Yes keypress (#430).
            if request.kind == .approve, let rule = ToolApproval.decode(request.text) {
                self.toolApprovals.add(rule, sessionId: record.sessionId)
                Task { @MainActor in self.logMirrorInput("🛡️", "\(source) allows \(rule.label) for the rest of session \(pid)") }
            }
            let reply = SessionInput.deliver(request: request, record: record,
                                             hosts: PtyHosts.available(), claudeDir: claudeDir,
                                             owned: self.ownedBox.existing.map { owned in
                                                 { owned.deliver(Self.imagesForOwned($0), record: $1) }
                                             })
            let label = URL(fileURLWithPath: record.cwd).lastPathComponent
            Task { @MainActor in
                if reply.outcome == "delivered" {
                    let preview = String(request.text.prefix(60))
                    self.logMirrorInput("📲", "\(source) → \(label): \"\(preview)\" (\(reply.channel ?? "?"))")
                } else {
                    let why = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                    self.logMirrorInput("⚠️", "\(source) input not delivered: \(why)")
                }
                if source == "phone", request.queuedAt != nil, ["delivered", "running", "captured"].contains(reply.outcome) {
                    // The phone queued this while the Mac was away; the
                    // push reaches it even when the app is closed.
                    self.liveActivityPusher.pushAlert(title: "Delivered to \(label)",
                                                       body: String(request.text.prefix(80)))
                }
            }
            return reply
    }

    /// Every phone-injected input is logged, per #17 — success or not.
    // MARK: AWS sign-in from the phone (AwsLogin.swift)

    /// Needs come from the sessions' transcript tails (SessionProgress
    /// .awsLoginProfile); a finished login for a profile that no session
    /// needs any more is dropped so the line clears itself.
    private func rebuildAwsLogins() {
        let configText = (try? String(contentsOf: AwsLogin.defaultConfigURL(), encoding: .utf8)) ?? ""
        let byKey = Dictionary(awsLoginStates.map { ($0.runKey, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [AwsLogin.Item] = []
        var needed = Set<String>()
        for (pid, progress) in sessionProgress.byPid.sorted(by: { $0.key < $1.key }) {
            // Both CLIs can lapse under one session (#367); each need is its own item.
            for provider in AwsLogin.Provider.allCases {
                guard let profile = progress.loginProfile(provider) else { continue }
                let failedAt = progress.loginFailedAt(provider)
                let key = AwsLogin.runKey(provider: provider, profile: profile)
                // Signed in since the failure: the failing result stays in the
                // transcript's window until the session moves on, but the
                // need is met (the key badge outlived the login, 2026-09-03).
                if let done = byKey[key], done.phase == .done,
                   let failedAt, failedAt.timeIntervalSince1970 < done.startedAt { continue }
                needed.insert(key)
                let label = progress.name ?? liveSessions?.sessions?.first { $0.pid == pid }
                    .map { URL(fileURLWithPath: $0.cwd).lastPathComponent }
                items.append(AwsLogin.Item(profile: profile,
                                           flow: provider.flow(profile: profile, configText: configText),
                                           pid: pid, sessionLabel: label,
                                           state: AwsLogin.current(byKey[key], needFailedAt: failedAt),
                                           failedAt: failedAt,
                                           account: provider == .aws ? AwsLogin.account(profile: profile, configText: configText) : nil,
                                           provider: provider == .aws ? nil : provider))
            }
        }
        // Logins started by hand (no session asked) still show while they
        // run or after they fail; one a session asked for belongs with
        // that session's need and goes when the need does.
        for state in awsLoginStates where !needed.contains(state.runKey) && state.phase != .done
            && state.pid == nil {
            items.append(AwsLogin.Item(profile: state.profile, flow: state.flow, pid: state.pid,
                                       sessionLabel: nil, state: state,
                                       account: state.providerOrAws == .aws ? AwsLogin.account(profile: state.profile, configText: configText) : nil,
                                       provider: state.provider))
        }
        // A need that just appeared goes out now: the mirror snapshot and
        // the phone's alert ride the fleet poll, up to a minute away. The
        // first scan after launch only seeds (its needs are old news).
        func key(_ item: AwsLogin.Item) -> String { "\(item.id)|\(Int(item.failedAt?.timeIntervalSince1970 ?? 0))" }
        let known = Set(awsLogins.map(key)), seeded = awsLoginsScanned
        let news = items.contains { $0.pid != nil && !known.contains(key($0)) }
        if items != awsLogins { awsLogins = items }
        if sessionProgress.scanned { awsLoginsScanned = true }
        if news, seeded, !isPlayground, awsNeedRefresh == nil {
            mirrorExportDue = true
            awsNeedRefresh = Task { [weak self] in
                await self?.refreshSnapshot()
                self?.awsNeedRefresh = nil
            }
        }
        probeAwsNeeds()
    }

    /// A need met outside the app — `aws login` in a terminal, or the
    /// ledger's done login past its day (#313) — has no login of the
    /// app's to clear it, and an idle session never scrolls the failing
    /// result out of its transcript (Overlord, 2026-09-07). So while a
    /// session need shows unmet, the CLI is asked whether the profile
    /// works: on the need's arrival and every `awsProbeInterval` after.
    /// No nudge on a hit — the session may have moved on hours ago.
    private var unmetAwsNeeds: [AwsLogin.Item] {
        var seen = Set<String>()
        return awsLogins.filter { $0.pid != nil && ($0.state == nil || $0.state?.phase == .failed) && seen.insert($0.runKey).inserted }
    }
    private func probeAwsNeeds() {
        if unmetAwsNeeds.isEmpty { awsProbeTask?.cancel(); awsProbeTask = nil; return }
        guard awsProbeTask == nil else { return }
        awsProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for item in self.unmetAwsNeeds {
                    let provider = item.providerOrAws, profile = item.profile
                    guard await AwsLoginRunner.signedIn(provider: provider, profile: profile), !Task.isCancelled else { continue }
                    await self.awsLoginRunner.markDone(provider: provider, profile: profile, via: "a sign-in outside the app")
                    self.logMirrorInput("🔐", "\(provider.cliName) login for \(profile) done outside the app")
                }
                try? await Task.sleep(for: .seconds(Self.awsProbeInterval))
            }
        }
    }

    /// `remote` nil = no flow asked for: this only REPORTS the profile's
    /// login (in flight or finished) and starts nothing — the phone polls
    /// this route every 2 s, and a poll that started the default flow
    /// re-opened the sign-in the moment the code flow finished
    /// (2026-09-03). false = the profile's default flow, true = the code
    /// flow; either replaces a run of the other kind.
    func startAwsLogin(provider: AwsLogin.Provider = .aws, profile: String, pid: Int?, local: Bool, remote: Bool? = nil) async -> AwsLogin.Reply {
        // The e2e gate runs in mock mode against a stub CLI (INFINITUS_AWS_CLI / INFINITUS_GCLOUD_CLI).
        guard !isPlayground, !mockMode || ProcessInfo.processInfo.environment[provider.cliOverrideEnv] != nil
        else { return AwsLogin.Reply(ok: false, error: "not in a demo instance") }
        if !local, remote == nil {
            // Against the profile's need, when a session has one: a login
            // finished before that need failed isn't this need's login.
            let need = awsLogins.first { $0.providerOrAws == provider && $0.profile == profile && $0.pid != nil }
            let state = AwsLogin.current(await awsLoginRunner.state(provider: provider, profile: profile), needFailedAt: need?.failedAt)
            return AwsLogin.Reply(ok: state != nil, state: state, error: state == nil ? "no login in flight for \(profile)" : nil)
        }
        let configText = (try? String(contentsOf: AwsLogin.defaultConfigURL(), encoding: .utf8)) ?? ""
        var flow: AwsLogin.Flow = local ? .local : provider.flow(profile: profile, configText: configText)
        if remote == true, flow == .relay { flow = .remote }
        let reply = await awsLoginRunner.start(provider: provider, profile: profile, flow: flow, pid: pid)
        logMirrorInput(reply.ok ? "🔐" : "⚠️",
                       reply.ok ? "\(provider.cliName) login started for \(profile) (\(flow.rawValue))"
                                : "\(provider.cliName) login for \(profile): \(reply.error ?? "failed")")
        return reply
    }

    /// FleetModel's fire-and-forget forms (the popup button).
    func startAwsLogin(profile: String, pid: Int?, local: Bool) {
        startLogin(provider: .aws, profile: profile, pid: pid, local: local)
    }

    func startLogin(provider: AwsLogin.Provider, profile: String, pid: Int?, local: Bool) {
        Task { _ = await startAwsLogin(provider: provider, profile: profile, pid: pid, local: local) }
    }

    func submitAwsLoginCode(provider: AwsLogin.Provider = .aws, profile: String, code: String) async -> AwsLogin.Reply {
        await awsLoginRunner.submit(provider: provider, profile: profile, code: code)
    }

    /// The login landed: tell the session that needed it to carry on —
    /// the phone's own message path, so it works wherever replies do.
    private func awsLoginLanded(_ state: AwsLogin.State) {
        let provider = state.providerOrAws
        logMirrorInput("🔐", "\(provider.cliName) login for \(state.profile) signed in")
        let fromPhone = state.flow != .local
        // Every session that needed this profile, not only the one the
        // login was started for (two sessions, one sign-in, 2026-09-04).
        var pids = Set(sessionProgress.byPid.filter { $0.value.loginProfile(provider) == state.profile }.map(\.key))
        if let pid = state.pid { pids.insert(pid) }
        for pid in pids { nudgeAfterAwsLogin(pid: pid, provider: provider, profile: state.profile, fromPhone: fromPhone) }
        // A login often signs other profiles in underneath — a broker
        // profile over its anchor `aws login` profile, an SSO session
        // several profiles share, gcloud's active account under a named
        // one — and the config can't say which. Ask the CLI: whichever
        // other outstanding profile works now is met.
        let others = Set(sessionProgress.byPid.values.compactMap { $0.loginProfile(provider) }).subtracting([state.profile])
        for profile in others {
            Task { [weak self] in
                guard await AwsLoginRunner.signedIn(provider: provider, profile: profile), let self else { return }
                await self.awsLoginRunner.markDone(provider: provider, profile: profile, via: state.profile)
                self.logMirrorInput("🔐", "\(provider.cliName) login for \(state.profile) also signed \(profile) in")
                for (pid, progress) in self.sessionProgress.byPid where progress.loginProfile(provider) == profile {
                    self.nudgeAfterAwsLogin(pid: pid, provider: provider, profile: profile, fromPhone: fromPhone)
                }
            }
        }
    }

    /// Tells a session that needed the login to carry on — the phone's
    /// own message path, so it works wherever replies do.
    // MARK: crash reports (built-in, no third party — user 2026-09-04)

    /// Stores a report, logs it, and — for the phone's — says so.
    func ingestCrash(_ report: CrashReport, announce: Bool) {
        guard !crashReports.contains(where: { $0.id == report.id }) else { return }
        try? crashStore.save(report)
        crashReports = crashStore.list()
        logEvent("other", icon: "💥", "\(report.summary)")
        if announce, !isPlayground { notify("phone app crashed — \(report.reason)") }
    }

    func removeCrash(_ id: String) {
        crashStore.remove(id)
        crashReports = crashStore.list()
    }

    /// What this Mac publishes to its team (spec §7): Claude Code's own
    /// files, this Mac's live sessions and crash reports, each engine's
    /// active account with its window percentages, and the blockers
    /// the pop-out shows (lapsed AWS logins, an all-limited fleet).
    /// INFINITUS_TEAM_PROJECTS swaps the projects dir for a fixture
    /// (the e2e gate) and skips the Codex scan.
    func teamSources() -> TeamPublisher.Sources {
        let claudeDir = ClaudeSessions.configHome()
        var s = TeamPublisher.Sources(projectsDir: claudeDir.appendingPathComponent("projects"), home: NSHomeDirectory())
        s.codexDir = StatsScanner.defaultCodexDir()
        if let fixture = ProcessInfo.processInfo.environment["INFINITUS_TEAM_PROJECTS"], !fixture.isEmpty {
            s.projectsDir = URL(fileURLWithPath: fixture)
            s.codexDir = nil
        }
        s.liveSessions = ClaudeSessions.list(claudeDir: claudeDir)
        s.crashes = crashStore.list()
        s.endpoints = controlEndpoints
        if let id = team.paths.teamIDs().sorted().first {
            let hints = TeamGrants.load(teamDir: team.paths.teamDir(id)).hints
            s.grantsTo = hints.isEmpty ? nil : hints
        }
        let lastFleets = fleets.compactMap(\.lastFleet)
        s.fleets = lastFleets.map { fleet in
            let active = fleet.accounts.first { $0.number == fleet.activeNumber }
            var windows: [TeamDocs.Window] = []
            if let w = active?.usage?.fiveHour { windows.append(TeamDocs.Window(label: "5h", pct: Int(w.pct.rounded()))) }
            if let w = active?.usage?.sevenDay { windows.append(TeamDocs.Window(label: "7d", pct: Int(w.pct.rounded()))) }
            return TeamDocs.Fleet(engine: fleet.engineID, account: active.map { $0.alias ?? $0.email }, windows: windows)
        }
        // Every account, for the member fleet view (#221); this Mac's one
        // token rate rides the primary fleet.
        let perMinute = sessionProgress.tokenRate?.perMinute ?? 0
        let rate: Double? = perMinute > 0 ? Double(perMinute) : nil
        s.fleetRows = lastFleets.enumerated().map { i, fleet in
            TeamDocs.FleetDoc.row(fleet, tokensPerMinute: i == 0 ? rate : nil)
        }
        s.blockers = awsLogins.map { "\($0.providerOrAws.loginLabel): \($0.profile)" }
            + lastFleets.filter { !$0.accounts.isEmpty && $0.activeNumber == nil && $0.nextCandidate == nil }
                .map { "\($0.engineID): every account limited" }
        return s
    }

    /// This Mac's own crashes: `~/Library/Logs/DiagnosticReports/
    /// Infinitus-*.ips` newer than the last look. The first look starts
    /// the clock — old reports aren't news.
    private func scanMacCrashReports() {
        let key = "crash_scan_watermark"
        let now = Date().timeIntervalSince1970
        guard let since = defaults.object(forKey: key) as? Double else {
            defaults.set(now, forKey: key)
            return
        }
        defaults.set(now, forKey: key)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("Infinitus-") && name.hasSuffix(".ips") {
            let url = dir.appendingPathComponent(name)
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  mtime.timeIntervalSince1970 > since,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let report = CrashReport.fromIPS(text, device: machineName) else { continue }
            ingestCrash(report, announce: false)
        }
    }

    /// Hands a report to a session as a message with the report attached
    /// (text), the way the phone sends attachments — the session reads
    /// the stack and triages it.
    func sendCrash(_ report: CrashReport, toPid pid: Int) {
        let text = "The Infinitus \(report.platform == "ios" ? "phone app" : "Mac app") had a \(report.kind) on "
            + "\(report.device) (\(report.reason)). The report is attached — please triage it and propose a fix."
        let attachment = SessionInput.Attachment(name: "crash-\(report.id.prefix(8)).txt", mime: "text/plain",
                                                 data: Data(report.transcript.utf8))
        let request = SessionInput.Request(kind: .message, text: text, attachments: [attachment])
        Task { await send(request, toPid: pid, icon: "💥", what: "crash report") }
    }

    /// A message from this Mac into a session — a crash report, a
    /// desktop capture (#69) — over the route phone messages take,
    /// logged in Settings › Sync like them.
    @discardableResult
    func send(_ request: SessionInput.Request, toPid pid: Int, icon: String, what: String) async -> SessionInput.Reply {
        let reply = await Task.detached(priority: .utility) { () -> SessionInput.Reply in
            let claudeDir = ClaudeSessions.configHome()
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { Int($0.pid) == pid }) else {
                return SessionInput.Reply(outcome: "noSurface", detail: "that session is gone")
            }
            return SessionInput.deliver(request: request, record: record,
                                        hosts: PtyHosts.available(), claudeDir: claudeDir)
        }.value
        logMirrorInput(reply.outcome == "delivered" ? icon : "⚠️", "\(what) → session \(pid): \(reply.outcome)")
        return reply
    }

    private func nudgeAfterAwsLogin(pid: Int, provider: AwsLogin.Provider = .aws, profile: String, fromPhone: Bool) {
        Task.detached(priority: .utility) { [weak self] in
            // The session's own stuck `aws login` first (#275), so the
            // nudge drains now instead of after its tool timeout. gcloud's
            // paste-back login has no callback to poke.
            let released = provider == .aws ? await AwsLoginRunner.releaseSessionLogins(profile: profile, sessionPid: pid) : 0
            let text = provider.continueMessage(profile: profile, fromPhone: fromPhone, released: released > 0)
            let request = SessionInput.Request(kind: .message, text: text)
            let claudeDir = ClaudeSessions.configHome()
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { Int($0.pid) == pid }) else { return }
            let reply = SessionInput.deliver(request: request, record: record,
                                             hosts: PtyHosts.available(), claudeDir: claudeDir)
            await MainActor.run { [weak self] in
                if released > 0 { self?.logMirrorInput("🔐", "session \(pid)'s own aws login for \(profile) released") }
                self?.logMirrorInput(reply.outcome == "delivered" ? "📲" : "⚠️",
                                     "session \(pid) nudged after \(provider.cliName) login: \(reply.outcome)")
            }
        }
    }

    private func logMirrorInput(_ icon: String, _ text: String) {
        logEvent("other", icon: icon, text)
    }

    /// Starts or stops the Cloudflare quick tunnel (#9). It only ever
    /// fronts the listener, so it follows the LAN toggle too.
    private func applyQuickTunnel() {
        guard mirrorTunnelEnabled, mirrorLANEnabled,
              let port = mirrorServer.port else {
            quickTunnel.stop()
            return
        }
        quickTunnel.start(port: port)
    }

    /// Starts or stops the named tunnel (#9): needs the toggle, a
    /// hostname, a token in the keychain and a bound port. A hostname
    /// change while running restarts it — the token is per hostname.
    private func applyNamedTunnel() {
        let host = NamedTunnel.normalizeHostname(mirrorNamedTunnelHost)
        if namedTunnel.isRunning, namedTunnel.hostname != host { namedTunnel.stop() }
        guard mirrorNamedTunnelEnabled, mirrorLANEnabled, mirrorServer.port != nil,
              !host.isEmpty else {
            namedTunnel.stop()
            return
        }
        // A local cloudflared config for this hostname wins over a token:
        // it was set up on this Mac and carries its own credentials file.
        if NamedTunnel.localConfigCovers(host) {
            namedTunnel.start(hostname: host, token: nil)
        } else if let token = NamedTunnel.token(for: host) {
            namedTunnel.start(hostname: host, token: token)
        } else {
            namedTunnel.stop()
        }
    }

    var namedTunnelTokenPresent: Bool {
        let host = NamedTunnel.normalizeHostname(mirrorNamedTunnelHost)
        return !host.isEmpty && NamedTunnel.token(for: host) != nil
    }

    /// The locally-managed setup is in place for the typed hostname.
    var namedTunnelLocalConfig: Bool {
        NamedTunnel.localConfigCovers(NamedTunnel.normalizeHostname(mirrorNamedTunnelHost))
    }

    /// Stores (or, when empty, forgets) the tunnel token for the current
    /// hostname and applies it at once.
    func saveNamedTunnelToken(_ token: String) {
        let host = NamedTunnel.normalizeHostname(mirrorNamedTunnelHost)
        guard !host.isEmpty else { return }
        NamedTunnel.setToken(token, for: host)
        namedTunnel.stop()
        applyNamedTunnel()
    }

    /// A new pairing token: every phone must be re-paired, and the
    /// running listener picks it up without a restart.
    func regeneratePairToken() {
        mirrorPairToken = MirrorPairing.generateToken()
        logEvent("pairing", icon: "🔑", "phone pairing token regenerated")
        // A new token is a new rendezvous key; the old entry just expires.
        if let url = quickTunnel.url { publishRendezvous(url) }
    }

    /// PUTs the quick tunnel's URL under this token's rendezvous key
    /// (MirrorRendezvous). Best effort: the QR still carries the URL, this
    /// only spares the rescan after a restart.
    func publishRendezvous(_ url: String) {
        guard mirrorRendezvousEnabled else { return }
        if let target = MirrorRendezvous.url(token: mirrorPairToken) { publish(url, at: target, label: "tunnel address") }
        // #220: teammates derive this key from the roster alone.
        if let key = controlEndpoints.rendezvous, let target = MirrorRendezvous.url(key: key) {
            publish(url, at: target, label: "team control address")
        }
    }

    private func publish(_ url: String, at target: URL, label: String) {
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = MirrorRendezvous.publishBody(url: url)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if code == 204 {
                    self?.logEvent("other", icon: "mappin", "\(label) published to infinitus.run")
                } else {
                    let why = error?.localizedDescription ?? "HTTP \(code)"
                    self?.logEvent("other", icon: "exclamationmark.triangle", "rendezvous publish failed (\(label)): \(why)")
                }
            }
        }.resume()
    }

    /// Every way a phone can reach this Mac right now (#9 remote access):
    /// lan, tailnet, named tunnel, quick tunnel, in that order — the order the single pair QR
    /// lists them in, and the order the phone tries them in.
    var pairRoutes: [PairRoute] {
        guard let port = mirrorServer.port else { return [] }
        var routes: [PairRoute] = []
        let addresses = LocalAddresses.ipv4()
        func route(id: String, title: String, detail: String, endpoint: String) {
            routes.append(PairRoute(id: id, title: title, detail: detail, endpoint: endpoint))
        }
        if let lan = MirrorPairing.lanAddress(in: addresses) {
            route(id: "lan", title: "On this Wi-Fi",
                  detail: "Both devices on the same network.",
                  endpoint: "http://\(lan):\(port)")
        }
        if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
            route(id: "tailnet", title: "Anywhere via Tailscale",
                  detail: "The phone needs Tailscale, signed into the same "
                        + "tailnet. Nothing else to set up — this Mac already "
                        + "listens on every interface.",
                  endpoint: "http://\(tailnet):\(port)")
        }
        if let named = namedTunnel.endpoint {
            route(id: "named", title: "Anywhere, your domain",
                  detail: "Your Cloudflare tunnel hostname — the same every start.",
                  endpoint: named)
        }
        if let tunnel = quickTunnel.url {
            route(id: "tunnel", title: "Anywhere, no account",
                  detail: "A random Cloudflare URL that changes every start; "
                        + "the pairing token is the only lock.",
                  endpoint: tunnel)
        }
        return routes
    }

    /// The one QR a phone ever needs to scan (#9 pair once, every route):
    /// every current route's endpoint, in `pairRoutes` order, plus the
    /// token. Empty until at least one route is up, so the pane can hide
    /// the QR instead of encoding a useless link.
    var pairURL: String {
        let endpoints = pairRoutes.map(\.endpoint)
        guard !endpoints.isEmpty else { return "" }
        return MirrorPairing.pairURL(endpoints: endpoints, token: mirrorPairToken)
    }

    private func startEngine(binary: String) {
        let supervisor = CswapSupervisor(
            binaryPath: binary,
            onLine: { [weak self] line in
                Task { @MainActor in self?.consume(line) }
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.cswapState = state }
            }
        )
        self.supervisor = supervisor
        Task { await supervisor.start() }
    }

    /// Engine event kinds → the durable log's vocabulary.
    static func eventKind(_ engineKind: String) -> String {
        switch engineKind {
        case "switch": "switch"
        case "all-exhausted": "limit"
        case "session-resumed": "resume"
        default: "other"
        }
    }

    private func consume(_ line: EventLine) {
        switch line {
        case .event(let event):
            logEvent(Self.eventKind(event.kind), icon: event.icon, event.summary)
            switch event.kind {
            case "switch":
                Task { await refreshSnapshot() }  // the snapshot diff posts the notification
            // Logged only (#231). "all-exhausted" arrives on every engine
            // re-probe (~10 min while dead): the latched PushTriggers message
            // owns that notification. session-resumed, remote-control-rearmed
            // and account-unquarantined used to post banners with no latch
            // and no Settings › Notify toggle; resumes are this app's own
            // ResumeService now, the /rc re-arm is housekeeping, and the
            // revival diff already carries the account-back news.
            default:
                break
            }
        case .schemaMismatch(let version):
            cswapState = .schemaMismatch(version)
        case .garbage:
            break  // logged upstream; never fatal (spec §2)
        }
    }

    private static func executableDate() -> Date? {
        guard let url = Bundle.main.executableURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Stop the engine cleanly, then relaunch this app from its bundle —
    /// the "restart to update" action after an on-disk rebuild.
    // MARK: onboarding — engine install (todo 2026-08-30)

    /// The bundled demo engine (tools/demo-cswap -> Resources), a tiny
    /// fabricated-fleet cswap. Unbundled dev runs look next to the
    /// executable instead (run-unbundled.sh copies it there).
    static func demoScriptPath() -> String? {
        if let p = Bundle.main.path(forResource: "demo-cswap", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        if let dir = (Bundle.main.executablePath as NSString?)?
            .deletingLastPathComponent {
            let p = dir + "/demo-cswap"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Playground-only: pretend no engine was found, so the onboarding
    /// card is reachable without an env-var relaunch (issue #6).
    @Published var simulateNoEngine = false
    /// True when no engine at all is configured (no cswap binary and no
    /// proxy); the popup swaps its rows for the onboarding card. A
    /// proxy-only setup is a working setup, not a missing engine.
    var engineMissing: Bool { registry.engines.isEmpty || simulateNoEngine }
    /// A setup step (no engine / no account yet) is on screen: the popup
    /// paints solid over the glass so the steps read against any desktop
    /// (user 2026-09-07 from the phone: "Disable liquid glass for set up
    /// steps", photo of the card over a Finder icon grid).
    var setupStepShown: Bool { engineMissing || (accounts.isEmpty && snapshotLoaded) }
    /// cswap is on and its binary was found — the only case the rail's
    /// auto-switch toggle and badge mean anything.
    var cswapRegistered: Bool { registry.engines.contains { $0.id == CswapEngine.engineID } }
    var swapdRegistered: Bool { registry.engines.contains { $0.id == SwapdEngine.engineID } }

    // MARK: onboarding — machine detection (todo 2026-09-01)

    @Published var claudeCLI: ClaudeCLIInfo?
    @Published var cliProxy: CLIProxyInfo?
    /// Something answered on the management port while the auth dir
    /// exists — the proxy is probably running right now.
    @Published var cliProxyLive = false
    @Published var addingFirstAccount = false
    @Published var firstAccountMessage: String?
    /// Set once a real snapshot decoded — gates the "no accounts" card
    /// so it can't flash during the first refresh.
    var snapshotLoaded: Bool { primary?.snapshotLoaded ?? false }

    func detectOnboarding() {
        Task.detached(priority: .utility) { [weak self] in
            let claude = ClaudeCLIDetect.info()
            let proxy = CLIProxyDetect.info()
            let live: Bool
            if proxy != nil {
                var req = URLRequest(
                    url: URL(string: "http://127.0.0.1:\(CLIProxyDetect.defaultPort)/")!)
                req.timeoutInterval = 0.8
                // ANY HTTP answer counts — management routes 404 without a
                // secret key, the point is that something is listening.
                live = (try? await URLSession.shared.data(for: req)) != nil
            } else {
                live = false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.claudeCLI = claude.isPresent ? claude : nil
                self.cliProxy = proxy
                self.cliProxyLive = live
            }
        }
    }

    /// `cswap add` registers whichever account Claude Code is signed in
    /// as — the "adopt the current login" onboarding path.
    func addFirstAccount() {
        guard let cswap, !addingFirstAccount else { return }
        addingFirstAccount = true
        firstAccountMessage = nil
        Task {
            do {
                _ = try await cswap.run(["add"])
                await refreshSnapshot()
            } catch {
                // The engine's own text when it gave one (`cswap add` says
                // what went wrong in its login); otherwise a sentence, never
                // the raw error.
                firstAccountMessage = (error as? CLIError)?.message ?? EngineFailure.sentence(error)
            }
            addingFirstAccount = false
        }
    }
    @Published var installingEngine = false
    @Published var installMessage: String?

    /// Button-triggered only — never auto-installs. Bootstraps `uv`
    /// first when the Mac has none (Homebrew if it is there, else
    /// Astral's standalone installer), then runs
    /// `uv tool install claude-swap` and relaunches so init re-runs the
    /// locator (cswap stays a let; the restart IS the re-detect).
    func installEngine() {
        guard !installingEngine else { return }
        let steps = EngineInstall.plan(
            uv: CswapLocator.locate(candidates: EngineInstall.uvCandidates()),
            brew: CswapLocator.locate(candidates: EngineInstall.brewCandidates()))
        installingEngine = true
        installMessage = steps.first.map(EngineInstall.progressMessage)
        Task.detached {
            for step in steps {
                await MainActor.run { [weak self] in
                    self?.installMessage = EngineInstall.progressMessage(step)
                }
                let result: (ok: Bool, output: String)
                switch step {
                case .installUV(.brew(let brew)):
                    result = AppModel.runInstallStep(brew, ["install", "uv"])
                case .installUV(.standalone):
                    result = AppModel.runInstallStep(
                        "/bin/sh", ["-c", EngineInstall.standaloneScript])
                case .installEngine:
                    guard let uv = CswapLocator.locate(
                        candidates: EngineInstall.uvCandidates()) else {
                        await MainActor.run { [weak self] in
                            self?.installingEngine = false
                            self?.installMessage = "uv installed but not on this Mac's "
                                + "usual paths — run: uv tool install claude-swap"
                        }
                        return
                    }
                    result = AppModel.runInstallStep(uv, ["tool", "install", "claude-swap"])
                }
                guard result.ok else {
                    await MainActor.run { [weak self] in
                        self?.installingEngine = false
                        self?.installMessage = EngineInstall.failureMessage(
                            step, output: result.output)
                    }
                    return
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.installingEngine = false
                self.installMessage = "Installed — restarting…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.relaunchApp()
                }
            }
        }
    }

    /// One blocking install child, combined stdout+stderr. Called only
    /// off the main actor (Task.detached).
    private nonisolated static func runInstallStep(_ path: String, _ arguments: [String])
        -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        // A GUI app's inherited PATH reaches neither Homebrew nor
        // ~/.local/bin, and both installers shell out to their own tools.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            // Drain before waiting: a filled pipe buffer would wedge the
            // child forever (the uv installer is chatty).
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus == 0, out)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func relaunchApp() {
        let bundle = Bundle.main.bundleURL.path
        let old = supervisor
        supervisor = nil
        Task {
            await old?.stop()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Unbundled dev runs are a bare executable — `open` on its
            // directory would just raise Finder.
            let exe = Bundle.main.executablePath ?? ""
            // applicationShouldTerminate can hold quit up to
            // TeamModel.quitBound (20s) for a team's now.json delete, so a
            // fixed sleep can no longer be trusted to outlast this
            // process — wait for the pid to actually exit instead.
            let pid = ProcessInfo.processInfo.processIdentifier
            let wait = "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; "
            let cmd = bundle.hasSuffix(".app")
                ? wait + "/usr/bin/open \"\(bundle)\""
                : wait + "exec \"\(exe)\""
            p.arguments = ["-c", cmd]
            try? p.run()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    /// One pass over every enabled engine: snapshots gathered
    /// concurrently, applied per fleet, then the app-level hooks
    /// (cache, history, mirror, notifications, resume, push, sync) run
    /// off the PRIMARY Claude fleet exactly as they did when cswap was
    /// the only engine. An engine that fails keeps its last good rows
    /// (the rumps menubar's _worker policy) and records its error.
    func refreshSnapshot() async {
        // Fire-and-forget: the machine sample (ps, hook scan, occasional
        // tree-size walk) must never stall the fleet poll this pass
        // exists for. `sampling` guards overlap; never in the
        // playground (writes real UserDefaults keys, pushes real
        // notifications — the same guard every other side effect here
        // uses) or a mock/e2e instance sharing this Mac's real process
        // table with the perf gate's launch-time samples.
        if !isPlayground, !mockMode, MachineModel.paneShown { Task { await machineModel.tick() } }
        let engines = registry.engines
        guard !engines.isEmpty else { return }
        var results: [(id: String, fleets: [EngineFleet]?, error: Error?)] = []
        await withTaskGroup(of: (String, [EngineFleet]?, Error?).self) { group in
            for engine in engines {
                group.addTask {
                    do { return (engine.id, try await engine.snapshot(), nil) }
                    catch { return (engine.id, nil, error) }
                }
            }
            for await r in group { results.append((r.0, r.1, r.2)) }
        }
        var primaryResult: (fleet: EngineFleet, change: FleetState.Change)?
        var anyChanged = false
        for r in results {
            guard let fleets = r.fleets else {
                let message = (r.error as? EngineError)?.errorDescription ?? "\(r.error!)"
                if engineErrors[r.id] != message {
                    NSLog("Infinitus engine %@: %@", r.id, message)
                    engineErrors[r.id] = message
                }
                continue
            }
            // Only publish a change: every @Published set re-runs each
            // observer's body, once per refresh, even for an identical value (#18).
            if engineErrors[r.id] != nil { engineErrors[r.id] = nil }
            for fleet in fleets.map(overlayingOwnedStatus) {
                let state = registry.state(for: fleet)
                let before = state.lastFleet
                let change = state.apply(fleet)
                anyChanged = anyChanged || change.changed
                if state === primary {
                    primaryResult = (fleet, change)
                    for n in change.newlyDead {
                        let name = fleet.accounts.first { $0.number == n }.map { $0.alias ?? $0.email } ?? "#\(n)"
                        logEvent("death", icon: "heart.slash", "\(name) hit a limit")
                    }
                    // A revival before the advertised reset is Anthropic
                    // resetting early — worth saying; the whole fleet
                    // coming back at once, doubly so (user 2026-09-05).
                    let wasAllDead = before.map { f in
                        let live = f.accounts.filter { $0.disabled != true && $0.usage != nil }
                        return !live.isEmpty && live.allSatisfy { AccountVitals.isDead($0.usage) }
                    } ?? false
                    let noneDeadNow = !fleet.accounts.contains { $0.disabled != true && AccountVitals.isDead($0.usage) }
                    var early = false
                    for n in change.newlyAlive {
                        let name = fleet.accounts.first { $0.number == n }.map { $0.alias ?? $0.email } ?? "#\(n)"
                        let wasEarly = RevivalProbe.wasEarly(previous: before?.accounts.first { $0.number == n })
                        early = early || wasEarly
                        logEvent("revival", icon: "heart.fill", "\(name) is back" + (wasEarly ? " — reset early" : ""))
                    }
                    if !change.firstLoad, !change.newlyAlive.isEmpty, pushRevived, !isPlayground {
                        if wasAllDead && noneDeadNow {
                            push("all accounts are back" + (early ? " — Anthropic reset early" : ""))
                        } else {
                            for n in change.newlyAlive {
                                let name = fleet.accounts.first { $0.number == n }.map { $0.alias ?? $0.email } ?? "#\(n)"
                                push("\(name) is back" + (early ? " — reset early" : ""))
                            }
                        }
                    }
                    scheduleRevivalProbe(accounts: fleet.accounts)
                }
            }
        }
        // The same account in two fleets: hand each engine the usage the
        // others fetched, so Anthropic sees one usage poll per email,
        // not one per engine (user 2026-09-02: 429s).
        let stamp = Date()
        for engine in engines {
            var byEmail: [String: SharedUsage] = [:]
            for r in results where r.id != engine.id {
                for fleet in r.fleets ?? [] {
                    for a in fleet.accounts where a.usageStatus == "ok" {
                        if let u = a.usage, byEmail[a.email] == nil {
                            byEmail[a.email] = SharedUsage(usage: u, at: stamp)
                        }
                    }
                }
            }
            if !byEmail.isEmpty { await engine.offerSharedUsage(byEmail) }
        }
        if let proxy = registry.engine(id: CLIProxyEngine.engineID) as? CLIProxyEngine {
            let strategy = await proxy.routingStrategy ?? ""
            proxyRoutingStrategy = strategy.isEmpty ? nil : strategy
            proxySessionAffinity = await proxy.sessionAffinity
            fleetCaveats[CLIProxyEngine.engineID] =
                (strategy.isEmpty || strategy == "fill-first")
                    ? nil : "\(strategy) routing ignores priority — switch is advisory"
        }
        if !isPlayground {
            let cache = fleets.compactMap(\.lastFleet)
            if let data = try? JSONEncoder().encode(cache) {
                try? FileManager.default.createDirectory(
                    at: Self.snapshotCacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: Self.snapshotCacheURL, options: .atomic)
            }
        }
        if anyChanged { dataPulseTick += 1 }
        guard let primary, let primaryResult else {
            // The primary engine failed this pass (or there is none).
            if let id = primary?.engineID, let err = engineErrors[id] {
                lastError = err
            }
            return
        }
        let (fleet, change) = primaryResult
        let list = AccountList(activeAccountNumber: fleet.activeNumber,
                               accounts: fleet.accounts,
                               nextCandidate: fleet.nextCandidate,
                               nextRecovery: fleet.nextRecovery,
                               liveSessions: fleet.liveSessions)
        let raw = fleet.raw ?? (try? JSONEncoder().encode(list)) ?? Data()
        let previous = change.previousActive
        let firstLoad = change.firstLoad
        if !isPlayground {
            updateBattlePlan(list)
            revivalPanel.sync(model: self)
        }
        // The footer's ⚡ tokens/minute needs the transcripts read even
        // with the sessions card closed (user 2026-09-03 "display
        // toks/m on bottom right status"). Every listed session, not
        // just the busy ones: a session that hit the expired AWS
        // sign-in has STOPPED on it and is idle by the time the scan
        // runs (the aws-login sim never surfaced, 2026-09-03). Idle
        // ones cost a stat each — the model skips any transcript
        // whose size+mtime held still. Transcripts are Claude Code's
        // own files, not the engine's: a mock-mode instance reads them
        // too, so the e2e gate drives the AWS sign-in need off a fixture.
        if !isPlayground, let live = primary.lastFleet?.liveSessions?.sessions {
            sessionProgress.refresh(sessions: live)
        }
        // Utilization history (todo 2026-09-01): every real snapshot
        // feeds the per-machine JSONL; the playground's fabricated
        // fleet must never pollute it — nor a mock-mode dev instance's
        // (four demo-cast files turned up in App Support, 2026-09-03).
        if !isPlayground, !mockMode {
            let accts = list.accounts
            let syncOn = sync.enabled
            Task.detached(priority: .utility) { [historyRecorder] in
                await historyRecorder.record(accounts: accts, syncEnabled: syncOn)
            }
            // Fleet mirror (#9 phase 1): lets the mobile companion see
            // this machine's last snapshot. Throttled inside the actor.
            // Prefs (#9 phase C1: "Follow Mac") captured here on the
            // main actor since AppModel's published properties aren't
            // Sendable-safe to read from the detached task.
            let prefs = FleetPrefs(
                themeID: gamification, compactRows: compactRows,
                popupLayout: popupLayout, burnStyle: burnStyle,
                introStyle: introStyle, introTitle: introTitle,
                introSpeed: introSpeed, customThemes: customThemes,
                sortByHeadroom: sortByHeadroom, popupTextSize: popupTextSize,
                reviveLeadMinutes: reviveLeadMinutes)
            // Footer-chip state (#9 phase D2), captured here for the
            // same main-actor reason as the prefs above.
            let serviceStatus = ServiceStatusSummary(
                indicator: ServiceStatusModel.shared.indicator)
            let engine = engineBadge ?? .stopped
            let allFleets = fleets.compactMap { $0.lastFleet?.with(capabilities: $0.capabilities) }
            let forecast = forecast
            let plan = battlePlan
            let awsLogins = awsLogins
            let progress = sessionProgress.byPid
            if let primaryFleet = primary.lastFleet {
                liveActivityPusher.tick(fleet: primaryFleet,
                                        machine: machineName,
                                        themes: availableThemes, macTheme: rowTheme,
                                        report: usageModel?.report,
                                        tokenRate: sessionProgress.tokenRate)
            }
            statsModel.refreshIfStale()
            team.refreshIfStale() // inside the !mockMode guard above: the automatic loop is real-instance-only; a mock instance still answers team-* control commands directly
            let stats = statsModel.bundle
            let teamSnapshot = team.snapshot
            // This Mac's own version, mirrored for the phone's Settings
            // (#121) — same keys ControlServer.status reads.
            let info = Bundle.main.infoDictionary ?? [:]
            let appInfo = AppInfo(
                version: info["CFBundleShortVersionString"] as? String ?? "dev",
                sha: info["InfinitusGitSHA"] as? String ?? info["CFBundleVersion"] as? String ?? "dev",
                updateVersion: appUpdateVersion,
                updateChannel: BrewUpdater.channel.rawValue,
                phoneLatest: appReleaseLatest)
            let timelineCache = timelineCache, attentionStore = attentionStore, ownedBox = ownedBox
            let sequenceLog = sequenceLog, leases = mirrorServer.leases
            let sessionProfilesList = sessionProfiles.profiles
            let mirrorNow = mirrorExportDue
            mirrorExportDue = false
            // A living UI keeps its lease; the cap only catches one that died.
            if localUIVisible { reportLocalActivity(visible: true) }
            Task.detached(priority: .utility) { [mirrorExporter] in
                await mirrorExporter.record(listJSON: raw, prefs: prefs,
                                            serviceStatus: serviceStatus,
                                            engine: engine, fleets: allFleets,
                                            forecast: forecast, plan: plan,
                                            awsLogins: awsLogins, progress: progress,
                                            stats: stats,
                                            pushesAlerts: self.liveActivityPusher.configured,
                                            app: appInfo, team: teamSnapshot,
                                            profiles: sessionProfilesList,
                                            projects: { self.projectSummaries(profiles: sessionProfilesList) },
                                            births: self.sessionBirths,
                                            facts: { records in
                                                // Only leased sessions get a timeline rebuild (#223
                                                // phase 5); an unleased pid is absent from factsByPid
                                                // and the phone falls back to today's rows.
                                                let wanted = leases.leasedPids().map { pids in records.filter { pids.contains($0.pid) } } ?? records
                                                let facts = timelineCache.facts(records: wanted, claudeDir: ClaudeSessions.configHome(),
                                                                                attention: attentionStore, roster: records,
                                                                                watched: leases.watchedPids()) { ownedBox.existing?.pending(pid: $0) ?? [] }
                                                // The Mac's own sessions card reads the same facts (phase 3).
                                                Task { @MainActor [weak self] in self?.sessionProgress.setFacts(facts) }
                                                return facts
                                            },
                                            sequence: sequenceLog, now: mirrorNow,
                                            overlay: self.overlayingOwnedStatus)
            }
        }
        // All-limited: count the limit-stopped sessions waiting to be
        // resumed (todo 2026-09-01), reusing the resume mechanism's
        // own detection — Claude Code's files, never engine internals.
        // Throttled: the transcript tails re-read at most every 20s.
        if list.nextCandidate == nil,
           RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts,
                                  activeNumber: list.activeAccountNumber) != nil {
            if Date().timeIntervalSince(waitingScanAt) > 20 {
                waitingScanAt = Date()
                Task.detached(priority: .utility) { [weak self] in
                    let dir = ClaudeSessions.configHome()
                    let stopped = Transcript.findStopped(
                        sessions: ClaudeSessions.list(claudeDir: dir),
                        claudeDir: dir)
                    let count = stopped.count
                    await MainActor.run { [weak self] in
                        self?.waitingResume = count
                    }
                }
            }
        } else {
            waitingResume = nil
        }
        // Death/revive ticks fired inside FleetState.apply.
        // Launch greeting: once the first snapshot renders, the
        // active row plays its sweep alongside the bars' fill-up
        // (user 2026-08-30). Delayed so the popup has drawn.
        // First snapshot = the intro's single clock: every entrance,
        // the bars, the flash, and the title all key off this tick,
        // so the sequence is identical run to run (title timing
        // drifted when it ran from view-mount instead).
        if firstLoad {
            DispatchQueue.main.async { self.replayIntro() }
        }
        lastError = nil
        // Piggyback on the refresh tick: one cheap stat per pass.
        if !appUpdatePending, let launched = launchExecutableDate,
           let now = Self.executableDate(),
           now > launched.addingTimeInterval(1) {
            appUpdatePending = true
        }
        // Switch notifications come from this DISPLAY-feed diff, not the
        // engine's `switch` events: our engine is parked whenever another
        // host (rumps, cswap watch, cswap auto) holds the mutex, and a
        // parked engine sees no events — the 2026-08-28 silent-switch
        // bug. The diff sees every switch regardless of who executed it,
        // manual ones included.
        if !isPlayground, let current = list.activeAccountNumber,
           let previous, previous != current, lastNotifiedActive != current {
            lastNotifiedActive = current
            let name = accounts.first(where: { $0.number == current })
                .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(current)"
            notify("switched to account \(current) (\(name))")
        }
        if !isPlayground {
            awake.update(wanted: keepAwake, display: keepAwakeDisplay,
                         busyCount: list.liveSessions?.busy ?? 0)
        }
        controlServer.heal()
        // Same display-feed vantage: a switch (manual or parked-engine)
        // re-arms /rc; an active account that can work resumes stopped
        // sessions. Detached, single-flight — never awaited here.
        if !isPlayground {
            let active = list.accounts.first { $0.number == list.activeAccountNumber }
            if previous != list.activeAccountNumber { activeSince = Date() }
            resume.tick(switched: previous != nil && previous != list.activeAccountNumber,
                        activeAlive: active.map { !AccountVitals.isDead($0.usage) } ?? false,
                        activeNumber: list.activeAccountNumber,
                        activeFetchedAt: active?.usageFetchedAt
                            .flatMap(UsageHistory.parseISO),
                        activeName: active.map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) },
                        activePct: active.flatMap { PushTriggers.worstPlanPct($0.usage) }.map { Int($0) },
                        activeSince: activeSince)
        }
        // Same display-feed vantage as the switch diff above: these
        // triggers fire even while the supervised engine is parked.
        let health = list.accounts
            .filter { !($0.disabled ?? false) && $0.usage != nil }
            .map { a in PushTriggers.Account(
                number: a.number,
                name: a.alias ?? String(a.email.prefix(while: { $0 != "@" })),
                dead: AccountVitals.isDead(a.usage),
                worstPct: PushTriggers.worstPlanPct(a.usage)) }
        let pushes = pushTriggers.tick(
            busy: list.liveSessions?.busy, total: list.liveSessions?.total,
            accounts: health,
            flags: .init(sessionsDone: pushSessionsDone,
                         allDead: pushAllDead, lastAlive: pushLastAlive,
                         waiting: pushWaiting, awsLogin: pushAwsLogin),
            sessions: list.liveSessions?.sessions,
            awsLogins: awsLoginsScanned ? awsLogins : nil,
            now: Date())
        if pushTriggers.memory != persistedPushMemory {
            persistedPushMemory = pushTriggers.memory
            if let data = try? JSONEncoder().encode(persistedPushMemory) { defaults.set(data, forKey: Self.pushMemoryKey) }
        }
        for msg in pushes where !isPlayground { push(msg) }
        if !isPlayground { await sync.tick() }
    }

    private let pastSessionsMemo = PastSessionsMemo()

    /// T3's project list for the window and the mirror (spec §2.1). Off
    /// the main actor (called from the exporter's detached tick) — takes
    /// `profiles` from the caller since a `nonisolated` func can't read
    /// the main-actor-isolated `sessionProfiles` itself.
    /// `live` is the caller's own `ClaudeSessions.list` when it has one
    /// (the workspace window lists for its inputs anyway, #384); nil lists here.
    nonisolated func projectSummaries(profiles: [SessionProfile], live: [ClaudeSessionRecord]? = nil) -> [ProjectSummary] {
        let claudeDir = ClaudeSessions.configHome()
        let live = live ?? ClaudeSessions.list(claudeDir: claudeDir)
        // `PastSessions.list` stats every transcript under the projects
        // dir (10k files, ~1 s of CPU here) and the export asked for it
        // on every refresh — 7% idle CPU on its own (#346). The walk is
        // reused for a minute while the live set holds; a session ending
        // is what turns a transcript into a past one, so that key catches
        // the change that matters and the project picker never lags by
        // more than the minute otherwise.
        let liveKey = live.map(\.sessionId).sorted().joined(separator: ",")
        let past = pastSessionsMemo.value(key: liveKey, maxAge: 60) {
            PastSessions.list(claudeDir: claudeDir, limit: 200)
        }
        let recentCwds = UserDefaults.standard.stringArray(forKey: "recent_cwds") ?? []
        // The branch is one HEAD-file read per cwd (#346) — no spawn, no
        // memo, so a checkout shows on the next pump.
        return ProjectSummary.derive(live: live, past: past, profiles: profiles,
                                     recentCwds: recentCwds,
                                     branch: { cwd in T3GitFacts.branch(cwd: cwd) })
    }

    /// The badge click: running -> stop, stopped -> start ("auto switch
    /// status is clickable to toggle", user 2026-08-30). Deliberate states
    /// only — refused/backing-off/mismatch stay informational.
    func toggleEngine() {
        switch cswapState {
        case .running, .backingOff:
            let supervisor = supervisor
            self.supervisor = nil
            cswapState = .stopped
            Task { await supervisor?.stop() }
        case .stopped:
            guard let cswap, cswapRegistered else { return }
            startEngine(binary: cswap.binaryPath)
        case .refused, .schemaMismatch:
            break
        }
    }

    /// Bounce the supervised engine — after a cswap upgrade the child is
    /// still the OLD binary until respawned.
    func restartEngine() {
        guard let cswap else { return }
        let old = supervisor
        supervisor = nil
        Task {
            await old?.stop()
            await MainActor.run { self.startEngine(binary: cswap.binaryPath) }
        }
    }

    // Primary-fleet actions (the mac-only panes and the wall call these;
    // the shared rows act on their own FleetState).
    func switchTo(_ number: Int) { primary?.switchTo(number) }
    func rotate() { primary?.rotate() }

    @Published var reorderError: String?

    /// Apply a drag-reorder: `order` is the account numbers in their new
    /// top-to-bottom sequence. Optimistically re-sorts the local rows so the
    /// row lands where it was dropped, then lets the snapshot confirm.
    /// Quit path: stop the supervised engine BEFORE the process dies, so
    /// the child never outlives the app holding the mutex (the engine also
    /// watches its stdin pipe for EOF as the backstop against a hard kill).
    func shutdown() {
        // The tunnels are child processes: they must not outlive the app.
        quickTunnel.stop()
        namedTunnel.stop()
        // So are the phone's terminals (#507): a login shell holding a pty
        // must not outlive the app either.
        terminalHost.closeAll()
        let supervisor = supervisor
        let owned = ownedBox.existing
        Task {
            await supervisor?.stop()
            // Owned Claude sessions are this process's children (#151):
            // they don't outlive the app either (the #274 lesson).
            await owned?.stopAll()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    /// The phone's terminals (#507 step 3): one PTY per session pid, opened
    /// on demand by the mirror's terminal routes. Costs nothing until one is
    /// open — the host has no sources of its own.
    let terminalHost = TerminalHost()

    // MARK: - Owned sessions (#151)

    /// Headless Claude Code sessions this app spawned and talks to over
    /// stdin. Made on first use, off the main actor — locating `claude`
    /// may run a login shell.
    let ownedBox = OwnedSessionsBox()
    nonisolated static let ownedLedgerURL = AppSupport.root().appendingPathComponent("owned-sessions.json")

    nonisolated func ownedSessions() -> OwnedSessions? {
        ownedBox.get { [weak self] in
            guard let path = ClaudeLocator.locate() else { return nil }
            return OwnedSessions(binaryPath: path, ledger: OwnedLedger(url: Self.ownedLedgerURL)) { pid, state in
                Task { @MainActor in self?.ownedStateChanged(pid: pid, state: state) }
            }
        }
    }

    /// The roster with an owned child's status filled in from its actor
    /// (the CLI leaves an sdk-cli record's status empty).
    nonisolated func ownedRoster(claudeDir: URL) -> [ClaudeSessionRecord] {
        overlayingOwnedStatus(ClaudeSessions.list(claudeDir: claudeDir))
    }

    nonisolated func overlayingOwnedStatus(_ records: [ClaudeSessionRecord]) -> [ClaudeSessionRecord] {
        guard let owned = ownedBox.existing, !owned.ownedPids.isEmpty else { return records }
        return records.map { r in owned.status(pid: r.pid).map { r.with(status: $0) } ?? r }
    }

    /// The engine's live-session list with the same overlay, so the card
    /// says busy/idle/waiting for an owned session, not "unknown".
    nonisolated func overlayingOwnedStatus(_ fleet: EngineFleet) -> EngineFleet {
        guard let live = fleet.liveSessions, let owned = ownedBox.existing, !owned.ownedPids.isEmpty else { return fleet }
        return fleet.with(liveSessions: live.overlaying { owned.status(pid: Int32($0)) })
    }

    /// A headless child from a crashed prior launch (no PDEATHSIG on
    /// Darwin) — swept once at startup, off the main actor (#151 follow-up).
    nonisolated static func sweepOwnedOrphans() -> [Int32] {
        OwnedSessions.sweepOrphans(ledger: OwnedLedger(url: ownedLedgerURL), claudeDir: ClaudeSessions.configHome())
    }

    /// A headless session takes the API's image types only; a phone file
    /// pick can be HEIC — ImageIO reads it, so it goes as a JPEG bounded
    /// to the API's recommended long edge instead of bouncing.
    nonisolated static func imagesForOwned(_ request: SessionInput.Request) -> SessionInput.Request {
        guard let attachments = request.attachments, attachments.contains(where: needsJPEG) else { return request }
        let converted = attachments.map { a -> SessionInput.Attachment in
            guard needsJPEG(a), let jpeg = ImageThumbnail.jpeg(a.data, maxPixels: 1568) else { return a }
            return SessionInput.Attachment(name: a.name, mime: "image/jpeg", data: jpeg)
        }
        return SessionInput.Request(kind: request.kind, text: request.text, attachments: converted,
                                    requestId: request.requestId, queuedAt: request.queuedAt,
                                    sessionId: request.sessionId, commandId: request.commandId)
    }

    private nonisolated static func needsJPEG(_ a: SessionInput.Attachment) -> Bool {
        a.mime.hasPrefix("image/") && !OwnedWire.imageMediaTypes.contains(a.mime)
    }

    private func ownedStateChanged(pid: Int32, state: OwnedSessions.State) {
        switch state {
        case .exited: logEvent("other", icon: "terminal", "headless session \(pid) ended")
        case .waiting: logEvent("other", icon: "hand.raised", "headless session \(pid) is waiting for an answer")
        default: break
        }
    }

    /// Start a session the way the phone, the popup and Past sessions ask:
    /// `headless` (or the "owned" host) spawns a child this app talks to,
    /// anything else opens a terminal through `SessionLauncher`.
    nonisolated func startSession(_ request: SessionStart.Request, preferredHost: String) async -> SessionStart.Reply {
        let headless = request.headless ?? (preferredHost == "owned")
        guard headless else {
            return SessionLauncher.start(request, preferredHost: preferredHost == "owned" ? "auto" : preferredHost)
        }
        // Locating `claude` may block on a login shell: never on the
        // cooperative pool (Infi4, 2026-09-07) — a GCD thread does it.
        let located = await withCheckedContinuation { (c: CheckedContinuation<OwnedSessions?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: self.ownedSessions()) }
        }
        guard let owned = located else {
            return SessionStart.Reply(outcome: "failed",
                                      detail: "claude isn't on this Mac's PATH; a headless session needs Claude Code \(ClaudeLocator.minimumVersion.map(String.init).joined(separator: ".")) or newer")
        }
        return await owned.start(request)
    }

    func rename(_ number: Int, to name: String) { primary?.rename(number, to: name) }
    var displayAccounts: [Account] { primary?.displayAccounts ?? [] }
    func setRotation(_ number: Int, enabled: Bool) {
        primary?.setRotation(number, enabled: enabled)
    }
    func setPreferred(_ number: Int, _ on: Bool) { primary?.setPreferred(number, on) }
    func reorder(_ order: [Int], done: (() -> Void)? = nil) {
        guard let primary else { done?(); return }
        primary.reorder(order, done: done)
    }
}

/// The shared fleet views (InfinitusUI, #9 phase B) render off this —
/// every requirement is an existing member; only the relogin action is
/// mac-only, so it lands here rather than in the protocol's no-op.
extension AppModel: FleetModel {
    func startRelogin(_ account: Account) {
        TokenFlow.shared.start(model: self, relogin: account)
    }
    func addAccount() {
        guard !TokenFlow.shared.running, !addingFirstAccount else { return }
        TokenFlow.shared.start(model: self)
    }
    var canAddAccount: Bool { cswapRegistered }

    /// The engine badge's portable half (#9 phase D2) — the supervisor's
    /// own State can't cross to iOS, so the shared footer reads this.
    var engineBadge: EngineBadge? {
        // The badge is the cswap child's state; with cswap off there is
        // nothing to report and the footer hides the chip.
        guard cswapRegistered else { return nil }
        switch cswapState {
        case .running: return .running
        case .refused: return .refused
        case .backingOff(let seconds): return .backingOff(seconds: seconds)
        case .schemaMismatch: return .schemaMismatch
        case .stopped: return .stopped
        }
    }

    /// The footer's update chip opens Settings through the closure the
    /// status item injects.
    func openSettings() { showSettings?() }

    /// The "at this pace" line's click: Settings on the Utilization pane
    /// (the forecast dashboard), selected through the same notification
    /// the playground's `playctl settings` uses.
    func openForecast() {
        showSettings?()
        NotificationCenter.default.post(name: Notification.Name("infinitus.selectPane"),
                                        object: "Utilization")
    }

    /// The primary fleet's engine decides what the mac-only panes may do.
    var capabilities: EngineCapabilities { primary?.capabilities ?? .all }
}

    private let pastSessionsMemo = PastSessionsMemo()
/// One remembered `PastSessions.list` for `projectSummaries` (#346):
/// a value, the key it was computed under and when. Called off the main
/// actor from the exporter's detached tick, so it locks.
final class PastSessionsMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var key = "", at = Date.distantPast, stored: [PastSession] = []

    func value(key: String, maxAge: TimeInterval, now: Date = Date(),
               compute: () -> [PastSession]) -> [PastSession] {
        lock.lock()
        if self.key == key, now.timeIntervalSince(at) < maxAge {
            let hit = stored; lock.unlock(); return hit
        }
        lock.unlock()
        let fresh = compute()
        lock.lock(); self.key = key; at = now; stored = fresh; lock.unlock()
        return fresh
    }
}
