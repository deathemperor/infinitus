import Foundation
import Combine
import SwiftUI
import AppKit
import os
import InfinitusCore
import InfinitusUI

/// Main-actor state the MenuBarExtra renders. Feeds per spec §2:
/// snapshots from `swapd list --json` (timer + right after any switch
/// event), events from the background `swapd auto --json` service.
@MainActor
final class AppModel: ObservableObject {
    // MARK: fleets (#8 multi-engine seam)
    //
    // Every enabled engine's fleets live in the registry as FleetState
    // objects — rows, ticks, pending switch. AppModel stays the popup
    // chrome's model AND a FleetModel facade over the PRIMARY Claude
    // fleet (swapd's on a swapd machine), so the mac-only panes, the
    // title, resume nudges and push triggers keep reading `accounts`
    // exactly as before.
    private(set) lazy var registry = EngineRegistry(host: self)
    var fleets: [FleetState] { registry.fleets }
    var primary: FleetState? { registry.primary }
    /// Per-engine last error (the primary's also lands in lastError).
    @Published var engineErrors: [String: String] = [:]
    /// When each engine last answered `snapshot()`. The age a failing
    /// engine's retained rows report falls back to this when the engine
    /// stamped no `usageFetchedAt` of its own (`FleetState.markStale`).
    private var engineLastGood: [String: Date] = [:]
    /// Per-engine honesty note for the fleet header (proxy: routing
    /// strategy that ignores priority tiers).
    @Published var fleetCaveats: [String: String] = [:]
    private var forwardingFleetChange = false

    var accounts: [Account] { primary?.accounts ?? [] }
    var activeNumber: Int? { primary?.activeNumber }
    var nextCandidate: Int? { primary?.nextCandidate }
    var nextRecovery: NextRecovery? { primary?.nextRecovery }
    /// The desktop's running provider turns, read over its HTTP API once a
    /// minute (#1375; the thread-card push carried it before) — nil until
    /// the first answer, the busy signal `WindowPlanner` reads now that
    /// the terminal session tracker is gone (#1041 d6).
    @Published var desktopActiveThreads: Int?
    private var desktopActiveThreadsReadAt: Date?
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
    /// swapd's `auto` under the supervisor (#475: one daemon per enabled
    /// engine, each owning its account policy).
    @Published var swapdState: EngineSupervisor.State = .stopped
    struct EventEntry: Identifiable {
        let id = UUID()
        var at = Date()
        let kind: String
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
    lazy var statsModel = StatsModel(eventStore: eventStore)

    /// Every event goes through here: the Activity pane's tail and the
    /// durable log Stats reads. `kind` is StatsEvents' vocabulary
    /// (switch/death/limit/revival/ignite/resume/nudge/pairing/other),
    /// plus `alert`/`notice` for the app's own announcements (`announce`),
    /// deliberately outside that vocabulary so a said line never lands in
    /// a tally.
    func logEvent(_ kind: String, icon: String, _ text: String) {
        eventLog.append(EventEntry(kind: kind, icon: icon, text: text))
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
    private var awsLoginStates: [AwsLogin.State] = []
    private var awsAnnouncedRunKeys: Set<String> = []
    private var awsLoginQuitWatch: AnyCancellable?
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

    /// The swapd binary this Mac has, when it has one (#8): the engine is
    /// registered from it, and the pane shows where it is. Mock mode and
    /// the playground run the bundled demo script in its place.
    let swapd: SwapdCLI?
    /// The Animation Playground is retired (#654); the guards it gated —
    /// snapshot cache, notifications, resume nudges, push, sync, power
    /// assertions, the engine supervisor — stay put until they are swept.
    let isPlayground = false
    /// Set by StatusItemHolder — opens the Infinitus desktop app, where
    /// every setting lives since the Mac's Settings window retired; with a
    /// page (`infinitus`, `infinitus/engines`) it lands on that Settings
    /// section through the desktop's `settings` deep link.
    var openDesktop: ((_ settingsPage: String?) -> Void)?
    /// Set by StatusItemHolder — closes and re-shows an open popover.
    /// NSPopover keeps a stale fitting size when the content swaps shape
    /// wholesale (wide<->stacked left it clipped or oversized until a
    /// manual reopen, user-verified); a programmatic bounce is that same
    /// fix without the user doing it.
    var reopenPopover: (() -> Void)?
    /// Set by StatusItemHolder — closes the popover and opens the same
    /// content as a free-floating window (the pop-out action).
    var popOut: (() -> Void)?
    // The bundle on disk was rebuilt since this instance launched (the
    // dev loop, or a manual make-app.sh) — surfaced as "restart to update".
    @Published var appUpdatePending = false
    private let launchExecutableDate = AppModel.executableDate()
    private var swapdSupervisor: (any EngineLifecycle)?
    private var refreshTask: Task<Void, Never>?
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
    /// Mock mode (user 2026-08-31): the bundled demo fleet stands in
    /// for the engine. Machine-local, deliberately never synced. swapd
    /// is a let, so flipping this relaunches — the restart IS the
    /// re-detect.
    @Published var mockMode: Bool {
        didSet {
            defaults.set(mockMode, forKey: "mock_mode")
            relaunchApp()
        }
    }

    // MARK: engines (#8) — which engines the registry runs. Like
    // mockMode, flipping one relaunches: the registry is built once at
    // init and the restart IS the re-detect.
    /// The swapd engine: on by default, off when asked.
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
    /// Memoised for the process: the only writers are the two save
    /// functions below, which relaunch — and `status` asked the keychain
    /// twice per desktop-app poll before this (#346's sample).
    private var cliproxyKeyPresentCache: Bool?
    var cliproxyKeyPresent: Bool {
        if let cached = cliproxyKeyPresentCache { return cached }
        let present = Keychain.read(account: cliproxyBaseURL) != nil
        cliproxyKeyPresentCache = present
        return present
    }

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
        cliproxyKeyPresentCache = !trimmed.isEmpty
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
    private var nineRouterPasswordPresentCache: Bool?
    var nineRouterPasswordPresent: Bool {
        if let cached = nineRouterPasswordPresentCache { return cached }
        let present = Keychain.read(account: nineRouterBaseURL, service: Keychain.nineRouterService) != nil
        nineRouterPasswordPresentCache = present
        return present
    }
    func saveNineRouter(baseURL: String, password: String) {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let old = nineRouterBaseURL
        if old != url { Keychain.delete(account: old, service: Keychain.nineRouterService) }
        defaults.set(url, forKey: "9router_base_url")
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: url, service: Keychain.nineRouterService) }
        else { _ = Keychain.write(account: url, value: trimmed, service: Keychain.nineRouterService) }
        nineRouterPasswordPresentCache = !trimmed.isEmpty
        relaunchApp()
    }

    static let cliproxyLedgerURL: URL = {
        AppSupport.root().appendingPathComponent("engines/cliproxy/usage.jsonl")
    }()

    /// OAuth add / re-login for an engine that signs accounts in through
    /// a browser and takes the redirect itself (swapd's `add-oauth`, the
    /// proxy): the native sign-in flow (`TokenFlow`: the system sheet, or
    /// the default browser's private window where the sheet cannot
    /// present; the desktop's `signin-begin` path runs it headless),
    /// waiting on the engine until the credential lands — no code to paste.
    func addOAuthAccount(engineID: String, provider: Provider, relogin: Account? = nil,
                         headless: Bool = false) {
        guard let engine = registry.engine(id: engineID),
              engine.capabilities.contains(.addOAuth),
              !addingFirstAccount, !TokenFlow.shared.running else { return }
        addingFirstAccount = true
        firstAccountMessage = nil
        TokenFlow.shared.start(model: self, engine: engine, provider: provider,
                               relogin: relogin, headless: headless) { [weak self] message in
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
    // Persisted since #828 (`menu_bar_enabled`): the desktop app and
    // `infinitusctl prefs set menu_bar_enabled true` can restore a hidden
    // icon, so it no longer needs the popup to be reachable. Off, the app
    // runs headless — the socket, the mirror and the pinned window stay.
    @Published var menuBarIconShown: Bool { didSet { defaults.set(menuBarIconShown, forKey: "menu_bar_enabled") } }
    // Pin holds the popover open (click-outside stops closing it).
    // Persisted by request — a pinned popup stays pinned across relaunches.
    @Published var popoverPinned: Bool { didSet { defaults.set(popoverPinned, forKey: "popover_pinned") } }
    /// Display-only row order (PopupSort): the engine's slots, headroom
    /// with active + next pinned (todo 2026-09-01), or the engine's own
    /// candidate ranking (#542). Engine slots never move — nothing is
    /// written (the app-side auto-order writer was removed 2026-09-03:
    /// pick-first is an engine knob, see EngineCapabilities.prefer).
    /// `popup_sort`; a pre-#542 `sort_headroom` Bool seeds it once.
    @Published var popupSort: PopupSort {
        didSet { defaults.set(popupSort.rawValue, forKey: "popup_sort") }
    }
    static func popupSort(_ defaults: UserDefaults) -> PopupSort {
        if let raw = defaults.string(forKey: "popup_sort"), let sort = PopupSort(rawValue: raw) {
            return sort
        }
        return PopupSort(legacyHeadroom: defaults.object(forKey: "sort_headroom") as? Bool ?? true)
    }
    // Away-push triggers beyond switches (PushTriggers has the rules).
    @Published var pushAllDead: Bool { didSet { defaults.set(pushAllDead, forKey: "push_all_dead") } }
    @Published var pushLastAlive: Bool { didSet { defaults.set(pushLastAlive, forKey: "push_last_alive") } }
    /// "<name> is back" (and "all accounts are back — reset early") pushes (2026-09-05).
    @Published var pushRevived: Bool { didSet { defaults.set(pushRevived, forKey: "push_revived") } }
    /// Minutes before a reset that the row's countdown goes live and the
    /// phone's reset alarm fires (#227).
    @Published var reviveLeadMinutes: Int { didSet { defaults.set(reviveLeadMinutes, forKey: "revive_lead_minutes") } }
    var reviveLead: TimeInterval { TimeInterval(reviveLeadMinutes * 60) }
    /// Headroom mode (#616): "off" or "hold"; the thresholds are the
    /// hysteresis band each fleet's verdict moves in. A change re-judges
    /// every fleet at once, so `fleets` answers the new setting now.
    @Published var priorityMode: String { didSet { defaults.set(priorityMode, forKey: "priority_mode"); rejudgeHeadroom() } }
    @Published var priorityLowPct: Int { didSet { defaults.set(priorityLowPct, forKey: "priority_low_pct"); rejudgeHeadroom() } }
    @Published var priorityAbundantPct: Int { didSet { defaults.set(priorityAbundantPct, forKey: "priority_abundant_pct"); rejudgeHeadroom() } }
    private func rejudgeHeadroom() { for fleet in fleets { fleet.judgeHeadroom() } }
    /// Settings › Sync "This Mac's name" (#99); empty follows the computer name.
    @Published var machineNameOverride: String {
        didSet {
            defaults.set(machineNameOverride, forKey: MachineName.overrideKey)
        }
    }
    var machineName: String { MachineName.current(defaults: defaults) }
    /// The status item in the theme's color with the theme's icon (#90),
    /// and its effects (switch/death/revival flash, the burn breath).
    @Published var menuBarThemed: Bool { didSet { defaults.set(menuBarThemed, forKey: "menubar_themed") } }
    @Published var menuBarEffects: Bool { didSet { defaults.set(menuBarEffects, forKey: "menubar_effects") } }
    /// Where the desktop server bound (it scans up from 3773 when that
    /// one is taken, so the server sets this pref on startup): the CLI's
    /// credential origin and the pairing QR's LAN link follow it.
    @Published var forkServerPort: Int {
        didSet { defaults.set(forkServerPort, forKey: "fork_server_port") }
    }
    /// How a fork-server publish is probed before it is followed (#1137);
    /// a stored property so a test can answer without a socket.
    var forkServerProbe: ForkServerProbe.Transport = ForkServerProbe.urlSession
    let sync = SettingsSyncModel()
    let historyRecorder = UsageHistoryRecorder()

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
    func uiSurface(_ id: String, visible: Bool) {
        if visible { visibleSurfaces.insert(id) } else { visibleSurfaces.remove(id) }
        // Every change re-reports: the scopes follow WHICH surfaces show,
        // not only whether any does (the stats pane closing while the
        // popup stays must drop `.stats`, #499).
        reportLocalActivity(visible: localUIVisible)
    }
    /// The popup and pop-out watch sessions and fleets; only the Stats
    /// pane watches stats. Holding `.stats` from every local surface kept
    /// the lazy stats cache (~27 MB of Day maps, tallies and file entries)
    /// resident whenever the popup was open (#499).
    private func reportLocalActivity(visible: Bool) {
        if visible {
            var scopes: [ClientActivity.Scope] = []
            if !visibleSurfaces.subtracting([Self.statsSurface]).isEmpty { scopes += [.sessions, .fleets] }
            if visibleSurfaces.contains(Self.statsSurface) { scopes.append(.stats) }
            leases.report(.init(clientId: ClientActivity.localClientId, visible: true, focused: true,
                                             recentlyInteracted: true, scopes: scopes,
                                             ttlMs: ClientActivity.ttlCapMs))
        } else {
            leases.release(clientId: ClientActivity.localClientId)
        }
    }
    /// `uiSurface` id the Stats pane reports while it shows.
    static let statsSurface = "stats"
    /// Who is watching what (ClientActivity): the local UI, the desktop
    /// (`client-activity`) and the Stats pane hold scoped leases here.
    let leases = LeaseTable()
    /// Agent CLI socket (ControlServer.swift); the real model only.
    private(set) lazy var controlServer = ControlServer(model: self)
    /// The desktop's CLI credential (#822): stored by `desktop-credential`, read by `desktop-token`.
    private(set) lazy var desktopCredential: DesktopCredential = {
        let credential = DesktopCredential(defaults: defaults)
        credential.log = { [weak self] text in self?.logEvent("desktop", icon: "key", text) }
        return credential
    }()
    /// Every app notification: Notification Center here, and the same
    /// text to the phones (issue #3; #756: the engine's own away-push
    /// channels went with cswap; swapd's `notify` only reports).
    func push(_ msg: String) {
        notify(msg)
    }

    /// The desktop server's HTTP API with the credential it minted for
    /// this Mac (#822), or nil while none is stored.
    private var desktopAPI: DesktopAPI? {
        guard let origin = desktopCredential.origin, let url = URL(string: origin),
              let token = desktopCredential.token() else { return nil }
        return DesktopAPI(origin: url, token: token)
    }

    /// The desktop calls run here, one at a time: `DesktopAPI` blocks a
    /// thread per request (its transport is synchronous, like the CLI's),
    /// so it stays off the cooperative pool, as TeamModel does.
    private let desktopQueue = DispatchQueue(label: "run.infinitus.desktop-api", qos: .utility)

    /// The busy-session count for the battle plan (#1375): the desktop's
    /// running turns, asked at most once a minute, off the main actor. The
    /// throttle runs before the keychain read the credential costs.
    func refreshDesktopActiveThreads() {
        guard !isPlayground else { return }
        let now = Date()
        if let last = desktopActiveThreadsReadAt, now.timeIntervalSince(last) < 60 { return }
        guard let api = desktopAPI else { return }
        desktopActiveThreadsReadAt = now
        desktopQueue.async { [weak self] in
            guard let count = try? api.runningTurns().count else { return }
            Task { @MainActor in self?.desktopActiveThreads = count }
        }
    }

    /// A line the app says out loud — the one call every banner site makes.
    ///
    /// It logs the line as its own event row before pushing it, so the
    /// desktop shows the same news from `snapshot.events` wherever the
    /// user actually is (#1032 finished: one notifier per machine). The
    /// row's kind is the announcement itself, not the observation: `death`
    /// / `revival` / `limit` rows keep meaning "this is what the fleet
    /// did", `alert` and `notice` mean "this is what the app would have
    /// said". Both are outside StatsEvents' vocabulary, so months of
    /// tallies are untouched.
    ///
    /// `urgent` is the difference between a banner that interrupts (every
    /// account dead, the last one nearly dead, a crash) and one that
    /// informs (a switch, an account back).
    func announce(_ body: String, icon: String, urgent: Bool = false) {
        logEvent(urgent ? "alert" : "notice", icon: icon, body)
        notify(body)
    }

    /// The alias every live session runs on right now — one active
    /// account per engine, so it is the fleet's, not the session's (#612).
    var activeAccountName: String? {
        guard let fleet = primary, let n = fleet.activeNumber,
              let account = fleet.accounts.first(where: { $0.number == n }) else { return nil }
        return account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
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

    /// The pass a freshly surfaced AWS-login need starts (rebuildAwsLogins).
    private var awsNeedRefresh: Task<Void, Never>?

    /// Notification Center — only while no desktop is watching (#1032
    /// finished: a desktop holding a `fleets` lease shows this news itself
    /// from `snapshot.events` through its own `notificationMode`, so a
    /// banner here would be the second one for one event) — then the
    /// phones through the desktop server and the Infinitus Connect relay
    /// (#1375; the Mac's own APNs key left with it), best-effort, off the
    /// main actor. A desktop on this Mac says nothing to a phone away from
    /// it, so the alert always goes. A desktop without a relay link answers
    /// 503 and that is silent; any other failure is one Activity-log line,
    /// never a retry.
    func notify(_ body: String) {
        if !desktopIsWatching { Notifier.post(title: "Infinitus", body: body) }
        guard !isPlayground, let api = desktopAPI else { return }
        desktopQueue.async { [weak self] in
            do { _ = try api.alert(title: "Infinitus", body: body) } catch {
                Task { @MainActor in
                    self?.logEvent("other", icon: "exclamationmark.triangle", "phone alert not sent: \(error)")
                }
            }
        }
    }

    /// Is some client other than this app's own UI holding a `fleets`
    /// lease — i.e. a desktop that will show the account news itself?
    /// The Mac's own popup reports `.fleets` too (`reportLocalActivity`)
    /// and is not one, hence the exclusion.
    var desktopIsWatching: Bool {
        leases.holds(.fleets, excluding: ClientActivity.localClientId)
    }
    /// Seeded with what the triggers remembered before the last relaunch
    /// (#98, #231): the last-alive warning.
    private lazy var pushTriggers = PushTriggers(memory: persistedPushMemory)
    private lazy var persistedPushMemory: PushTriggers.Memory = {
        if let data = defaults.data(forKey: Self.pushMemoryKey),
           let memory = try? JSONDecoder().decode(PushTriggers.Memory.self, from: data) { return memory }
        return PushTriggers.Memory()
    }()
    static let pushMemoryKey = "push_triggers_memory"
    private let defaults: UserDefaults

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

    /// One-time prefs adoption across the app's bundle-id renames.
    /// Bundled runs only — the unbundled domain is per-executable name
    /// and unaffected. Copies, never moves: the old domain stays for
    /// rollback. Locally-set keys win. First launch under a new bundle
    /// id copies the previous id's prefs domain (the bundled app's
    /// UserDefaults.standard IS the bundle id): com.huuloc.limitless
    /// (2026-08-30 → 2026-09-03), then com.huuloc.infinitus. Each hop
    /// runs once; existing keys are never overwritten.
    private static func migrateLegacyDefaults() {
        guard AppDefaults.suite == nil else { return }   // a dev suite starts empty
        let std = AppDefaults.standard
        for (domain, marker) in [("com.huuloc.infinitus", "migrated_from_huuloc_id"),
                                 ("com.huuloc.limitless", "migrated_from_limitless_id")] {
            guard !std.bool(forKey: marker), let legacy = std.persistentDomain(forName: domain) else { continue }
            for (key, value) in legacy where std.object(forKey: key) == nil {
                std.set(value, forKey: key)
            }
            std.set(true, forKey: marker)
        }
    }

    init() {
        // The playground is retired (#654); `isPlayground` is a constant
        // now and `self` is out of reach during phase 1, so the guards
        // below read this local until they are swept.
        let playground = false
        defaults = AppDefaults.standard
        Self.migrateLegacyDefaults()
        debugMenu = AppDefaults.standard.bool(forKey: "debug_menu")
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
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        introStyle = defaults.string(forKey: "intro_style") ?? "top"
        introSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        introTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        burnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        // Local: init reads it again below before every stored
        // property is set (two-phase init forbids self.mockMode there).
        // `bool(forKey:)`, not `object as? Bool`: the argument domain of
        // a dev launch (`-mock_mode YES`) holds the String "YES", which
        // only the typed getter reads as true (#249).
        let mock = defaults.bool(forKey: "mock_mode")
        mockMode = mock
        swapdEnabled = defaults.object(forKey: "engine_swapd_enabled") as? Bool ?? true
        cliproxyEnabled = defaults.object(forKey: "engine_cliproxy_enabled") as? Bool ?? false
        nineRouterEnabled = defaults.object(forKey: "engine_9router_enabled") as? Bool ?? false
        popupSort = Self.popupSort(defaults)
        forkServerPort = defaults.object(forKey: "fork_server_port") as? Int ?? ForkServerProbe.defaultPort
        // Push triggers default ON — they exist because they were asked for.
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
        pushRevived = defaults.object(forKey: "push_revived") as? Bool ?? true
        reviveLeadMinutes = defaults.object(forKey: "revive_lead_minutes") as? Int ?? 10
        priorityMode = Self.priorityMode(defaults)
        priorityLowPct = defaults.object(forKey: "priority_low_pct") as? Int ?? 80
        priorityAbundantPct = defaults.object(forKey: "priority_abundant_pct") as? Int ?? 50
        machineNameOverride = defaults.string(forKey: MachineName.overrideKey) ?? ""
        menuBarThemed = defaults.object(forKey: "menubar_themed") as? Bool ?? true
        menuBarIconShown = defaults.object(forKey: "menu_bar_enabled") as? Bool ?? true
        menuBarEffects = defaults.object(forKey: "menubar_effects") as? Bool ?? true
        if playground {
            // Isolation is the contract: no demo script, no data at all
            // (never fall back to the real engine here).
            if let demo = Self.demoScriptPath() {
                swapd = SwapdCLI(binaryPath: demo)
            } else {
                swapd = nil
                lastError = "demo script missing — playground has no data"
            }
        } else if mock, let demo = Self.demoScriptPath() {
            swapd = SwapdCLI(binaryPath: demo)
        } else if let path = SwapdLocator.locate() {
            swapd = SwapdCLI(binaryPath: path)
            if mock {
                lastError = "demo script missing — running the real engine"
            }
        } else {
            swapd = nil
            if swapdEnabled { lastError = "Account engine missing — install a current Infinitus release to restore bundled swapd, then relaunch." }
        }
        if !playground { sync.attach(model: self) }
        if let swapd, swapdEnabled || playground { registry.register(SwapdEngine(cli: swapd)) }
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
        // `swapd list` returned, eating the intro (user 2026-08-30).
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
        statsModel.leases = leases
        // Settings › Team (#1313): the loop rides the refresh tick; the
        // publisher works from StatsModel's scan (#251) and gives the
        // table back once folded (#499).
        statsModel.scanFeedsTeam = { [weak self] in self?.team.enabled == true }
        team.sources = { [weak self] in self?.teamSources() ?? TeamPublisher.Sources(home: NSHomeDirectory(), machine: "Mac") }
        team.ownsScan = { [weak self] in self?.statsModel.enabled == true }
        team.scanEntries = { [weak self] in self?.statsModel.scanEntries }
        team.scanGeneration = { [weak self] in self?.statsModel.scanGeneration ?? 0 }
        team.scanConsumed = { [weak self] generation in self?.statsModel.dropScanEntries(generation: generation) }
        team.scanRequested = { [weak self] in self?.statsModel.refresh() }
        team.desktopCredential = { [weak self] in
            guard let self, let origin = desktopCredential.origin, let url = URL(string: origin),
                  let token = desktopCredential.token() else { return nil }
            return (url, token)
        }
        team.onLog = { [weak self] text in self?.logEvent("team", icon: "person.2", text) }
        team.load()
    }

    /// Settings › Team (spec §9). Secrets in the keychain, or files when
    /// INFINITUS_TEAM_DIR redirects the team dir (e2e, a second instance).
    private(set) lazy var team: TeamModel = {
        let paths = TeamPaths.standard()
        let model = TeamModel(paths: paths, makeSecrets: TeamSecretsFactory.make(paths: paths), defaults: defaults)
        model.enabled = !isPlayground && (!mockMode || ProcessInfo.processInfo.environment["INFINITUS_TEAM_DIR"] != nil)
        return model
    }()

    /// What this Mac publishes to its team (spec §7) besides the scan and
    /// the desktop's threads: each engine's active account with its window
    /// percentages, every account for the member fleet view (#221), and
    /// the blockers the pop-out shows (lapsed AWS logins, an all-limited
    /// fleet). Crash reports stay on this Mac (#1422).
    func teamSources() -> TeamPublisher.Sources {
        var s = TeamPublisher.Sources(home: NSHomeDirectory(), machine: machineName)
        let lastFleets = fleets.compactMap(\.lastFleet)
        s.fleets = lastFleets.map { fleet in
            let active = fleet.accounts.first { $0.number == fleet.activeNumber }
            var windows: [TeamDocs.Window] = []
            if let w = active?.usage?.fiveHour { windows.append(TeamDocs.Window(label: "5h", pct: Int(w.pct.rounded()))) }
            if let w = active?.usage?.sevenDay { windows.append(TeamDocs.Window(label: "7d", pct: Int(w.pct.rounded()))) }
            return TeamDocs.Fleet(engine: fleet.engineID, account: active.map { $0.alias ?? $0.email }, windows: windows)
        }
        s.fleetRows = lastFleets.map { TeamDocs.FleetDoc.row($0) }
        s.blockers = awsLogins.map { "\($0.providerOrAws.loginLabel): \($0.profile)" }
            + lastFleets.filter { !$0.accounts.isEmpty && $0.activeNumber == nil && $0.nextCandidate == nil }
                .map { "\($0.engineID): every account limited" }
        return s
    }

    /// App-side cache of our own subprocess output (never an engine
    /// internal file).
    private var snapshotCacheWrite = WriteIfChanged()
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
    /// The preference catalog with this install's values (#558): what
    /// `infinitusctl prefs` and the mirror's `GET /prefs` answer.
    func prefsReply(keys: [String]? = nil) throws -> PrefCatalog.Reply {
        try PrefCatalog.reply(from: defaults, keys: keys, choices: ["gamification_style": themeChoices])
    }

    /// The open theme set as `{id, name}` rows (#747): the built-ins plus
    /// the user's `themes.json`, which no static catalog can list.
    private var themeChoices: [JSONValue] {
        availableThemes.map { .object(["id": .string($0.id), "name": .string($0.name)]) }
    }

    /// One preference written and taken live (#558 write side): the
    /// engine toggles go through their own setters, whose `didSet`
    /// relaunches the app, with the `engine` command's guards; every
    /// other key is stored and re-read by `reloadPrefs`, so its `didSet`
    /// side effects (the LAN listener, the title) run as
    /// they do from the panes. Returns the updated pref and whether the
    /// app is relaunching behind the reply.
    func setPref(key: String, value: JSONValue) throws -> (pref: PrefCatalog.Pref, restarting: Bool) {
        let entry = try PrefCatalog.validate(key: key, value: value)
        if entry.effect == .restart, case .bool(let on) = value,
           let engine = Self.enginePrefs[key] {
            let changed = try setEngineEnabled(engine, on: on)
            return (PrefCatalog.pref(entry, in: defaults), changed)
        }
        if key == "mock_mode", case .bool(let on) = value {
            guard mockMode != on else { return (PrefCatalog.pref(entry, in: defaults), false) }
            mockMode = on   // didSet stores it and relaunches
            return (PrefCatalog.pref(entry, in: defaults), true)
        }
        let pref = try PrefCatalog.write(value, key: key, to: defaults)
        reloadPrefs()
        return (pref, false)
    }

    static let enginePrefs = ["engine_swapd_enabled": "swapd", "engine_cliproxy_enabled": "cliproxy",
                              "engine_9router_enabled": "9router"]

    /// `engine <id> on|off` and `prefs set engine_<id>_enabled`: the
    /// toggle behind the same guards; true when it changed (the setter's
    /// `didSet` then relaunches), false when it already was so.
    func setEngineEnabled(_ engine: String, on: Bool) throws -> Bool {
        switch engine {
        case "swapd":
            guard swapd != nil || !on else { throw PrefCatalog.Violation(key: "engine_swapd_enabled", message: "swapd is not installed") }
            guard swapdEnabled != on else { return false }
            swapdEnabled = on
        case "cliproxy":
            guard cliproxyKeyPresent || !on else { throw PrefCatalog.Violation(key: "engine_cliproxy_enabled", message: "store a management key first (proxy-key)") }
            guard cliproxyEnabled != on else { return false }
            cliproxyEnabled = on
        case "9router":
            guard nineRouterEnabled != on else { return false }
            nineRouterEnabled = on
        default:
            throw PrefCatalog.Violation(key: engine, message: "unknown engine \(engine)")
        }
        return true
    }

    /// Every pref re-read from defaults (an iCloud apply, `prefs set`).
    /// Each property is assigned only when its value moved: a `didSet`
    /// that re-applies its state — the LAN listener, the revival panel,
    /// the theme's layers — must not run for the thirty-odd keys a
    /// one-key write leaves alone (an e2e `prefs set popup_layout` cost
    /// 40 MB of RSS through the untouched didSets, 2026-09-10).
    private static func priorityMode(_ defaults: UserDefaults) -> String {
        let mode = defaults.string(forKey: "priority_mode") ?? "off"
        return PrefCatalog.priorityModes.contains(mode) ? mode : "off"
    }

    func reloadPrefs() {
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        set(\.showAccountName, defaults.object(forKey: "show_account_name") as? Bool ?? true)
        let pct = defaults.string(forKey: "title_pct") ?? "both"
        set(\.titlePct, TitlePrefs.pctChoices.contains(pct) ? pct : "both")
        set(\.titleScoped, defaults.object(forKey: "title_scoped") as? Bool ?? false)
        let interval = defaults.object(forKey: "refresh_interval") as? Int ?? 60
        set(\.refreshInterval, TitlePrefs.refreshChoices.contains(interval) ? interval : 60)
        set(\.gamification, defaults.string(forKey: "gamification_style") ?? "off")
        set(\.introStyle, defaults.string(forKey: "intro_style") ?? "top")
        set(\.introSpeed, defaults.object(forKey: "intro_speed") as? Double ?? 1.0)
        set(\.introTitle, defaults.string(forKey: "intro_title") ?? "zoom")
        set(\.burnStyle, defaults.string(forKey: "burn_style") ?? "ember")
        set(\.compactRows, defaults.object(forKey: "compact_rows") as? Bool ?? false)
        set(\.footerActionsHidden, defaults.object(forKey: "footer_actions_hidden") as? Bool ?? false)
        set(\.titleRemaining, defaults.object(forKey: "title_remaining") as? Bool ?? false)
        let reset = defaults.string(forKey: "title_reset") ?? "countdown"
        set(\.titleReset, TitlePrefs.resetChoices.contains(reset) ? reset : "countdown")
        set(\.titleIconOnly, defaults.object(forKey: "title_icon_only") as? Bool ?? false)
        set(\.popupLayout, defaults.string(forKey: "popup_layout") ?? "wide")
        set(\.popupTextSize, defaults.string(forKey: "popup_text_size") ?? "default")
        set(\.glassFocused, defaults.object(forKey: "glass_focused") as? Double ?? 0.7)
        set(\.popupSort, Self.popupSort(defaults))
        set(\.pushAllDead, defaults.object(forKey: "push_all_dead") as? Bool ?? true)
        set(\.pushLastAlive, defaults.object(forKey: "push_last_alive") as? Bool ?? true)
        set(\.pushRevived, defaults.object(forKey: "push_revived") as? Bool ?? true)
        set(\.reviveLeadMinutes, defaults.object(forKey: "revive_lead_minutes") as? Int ?? 10)
        set(\.priorityMode, Self.priorityMode(defaults))
        set(\.priorityLowPct, defaults.object(forKey: "priority_low_pct") as? Int ?? 80)
        set(\.priorityAbundantPct, defaults.object(forKey: "priority_abundant_pct") as? Int ?? 50)
        set(\.machineNameOverride, defaults.string(forKey: MachineName.overrideKey) ?? "")
        set(\.menuBarThemed, defaults.object(forKey: "menubar_themed") as? Bool ?? true)
        set(\.menuBarIconShown, defaults.object(forKey: "menu_bar_enabled") as? Bool ?? true)
        set(\.menuBarEffects, defaults.object(forKey: "menubar_effects") as? Bool ?? true)
        set(\.forkServerPort, defaults.object(forKey: "fork_server_port") as? Int ?? ForkServerProbe.defaultPort)
        // #1178: the Devices page's prefs land on their owners; each didSet
        // writes the same key back.
        set(\.sync.enabled, defaults.object(forKey: "icloud_sync") as? Bool ?? false)
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
        // The terminal session count is gone (#1041 d6); the desktop's
        // running turns (#1375, refreshDesktopActiveThreads) say whether
        // threads are running, and before the first answer the plan is
        // drawn as if busy.
        let plan = WindowPlanner.plan(accounts: states, burnPctPerHour: rates["5h"],
                                      busySessions: desktopActiveThreads ?? 1, now: now,
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
            // The forecast lands after `apply` already judged this
            // poll's headroom (#616 remainder 1) — re-judge now that a
            // fresh projection exists. Idempotent: judge only publishes
            // on change.
            primary?.judgeHeadroom()
        }
        let relay = LiveForecastRelay.shared
        relay.forecast = forecast
        relay.plan = battlePlan
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
                self.eventLog = past.map { EventEntry(at: $0.at, kind: $0.kind, icon: $0.icon, text: $0.text) } + self.eventLog
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
        try await state.engine.ignite(fleet: state.provider, number: number)
        let resets = try await igniteReset(state, number: number)
        // The endpoint reports the window minutes after the run (#338):
        // keep asking for this account until its clock shows.
        if resets == nil { followUpIgnite(state, number: number) }
        return resets
    }

    /// Fetch account n again and read when its 5h window ends, or nil
    /// while the endpoint has not reported one.
    private func igniteReset(_ state: FleetState, number: Int) async throws -> Date? {
        let engine = state.engine, provider = state.provider
        guard engine.capabilities.contains(.refreshAccount) else {
            await refreshSnapshot()
            return state.accounts.first { $0.number == number }?.usage?.fiveHour?.resetsAt
                .flatMap(UsageHistory.parseISO)
        }
        let fleet = try await engine.refresh(fleet: provider, number: number)
        _ = registry.state(for: fleet).apply(fleet)
        return fleet.accounts.first { $0.number == number }?.usage?.fiveHour?.resetsAt
            .flatMap(UsageHistory.parseISO)
    }

    private var igniteFollowUp: Task<Void, Never>?

    /// `IgniteFollowUp.delays` more fetches of account n; the plan line
    /// keeps its "waiting" result (and so does not offer the account
    /// again) until the clock shows or the schedule runs out.
    private func followUpIgnite(_ state: FleetState, number: Int) {
        igniteFollowUp?.cancel()
        let name = accountName(number)
        igniteFollowUp = Task { [weak self] in
            for delay in IgniteFollowUp.delays {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                guard let resets = try? await self?.igniteReset(state, number: number) else { continue }
                let result = IgniteResult(text: IgniteFollowUp.started(name, resets: resets), ok: true)
                self?.logEvent("ignite", icon: "flag.checkered", "ignited \(name) — window started, resets \(IgniteFollowUp.clock(resets))")
                self?.igniteResult = result
                try? await Task.sleep(for: .seconds(10))
                if self?.igniteResult == result { self?.igniteResult = nil }
                return
            }
            let result = IgniteResult(text: IgniteFollowUp.unseen(name), ok: false)
            self?.logEvent("other", icon: "exclamationmark.triangle", result.text)
            self?.igniteResult = result
        }
    }

    private func accountName(_ number: Int) -> String {
        accounts.first { $0.number == number }
            .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(number)"
    }

    /// Manual ignition (#7 MVP step 3) through the primary fleet's engine
    /// (`AccountEngine.ignite`, capability-gated): one tiny request as
    /// account n so its 5h clock starts now; the fleet stays put. Outcome
    /// in the event log; ~1K weekly tokens on n.
    func ignite(_ number: Int) {
        guard let primary, canIgnite, !isPlayground, igniting == nil else { return }
        igniting = number
        let fleet = primary
        let name = accountName(number)
        logEvent("ignite", icon: "flag.checkered", "igniting \(name)'s 5h window")
        Task { [weak self] in
            var result: IgniteResult?
            var waiting = false
            do {
                // No guessed "now + 5 h": the run's window is only known
                // once the endpoint reports it, which takes minutes (#338).
                // Meanwhile the follow-up asks again and the result stays
                // "waiting", so the plan line does not offer n again.
                if let resets = try await self?.igniteAndPublish(fleet, number: number) {
                    result = IgniteResult(text: IgniteFollowUp.started(name, resets: resets), ok: true)
                    self?.logEvent("ignite", icon: "flag.checkered", "ignited \(name) — window started, resets \(IgniteFollowUp.clock(resets))")
                } else {
                    result = IgniteResult(text: IgniteFollowUp.waiting(name), ok: true)
                    self?.logEvent("ignite", icon: "flag.checkered", "ignited \(name) — waiting for its clock to show")
                    waiting = true
                }
            } catch {
                result = IgniteResult(text: "ignite \(name) failed: \((error as? CLIError)?.message ?? error.localizedDescription)", ok: false)
                self?.logEvent("other", icon: "exclamationmark.triangle", result!.text)
            }
            self?.igniting = nil
            self?.igniteResult = result
            if waiting { return }
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
        }
        crashReports = crashStore.list()
        scanMacCrashReports()
        _ = awsLoginRunner
        // The playground gets a socket only where INFINITUS_CONTROL_SOCKET
        // points — never the real app's path.
        if !isPlayground || ProcessInfo.processInfo.environment["INFINITUS_CONTROL_SOCKET"] != nil {
            controlServer.start()
        }
        guard swapdSupervisor == nil, refreshTask == nil else { return }
        if let swapd, !isPlayground, swapdEnabled { startSwapd(binary: swapd.binaryPath) }
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
    }

    /// Every phone-injected input is logged, per #17 — success or not.
    // MARK: AWS sign-in from the phone (AwsLogin.swift)

    /// Items are the logins the verbs started (aws-login / gcloud-login):
    /// they show while running and after a failure, and clear once the
    /// runner reports them done.
    private func rebuildAwsLogins() {
        let configText = (try? String(contentsOf: AwsLogin.defaultConfigURL(), encoding: .utf8)) ?? ""
        let items: [AwsLogin.Item] = awsLoginStates.filter { $0.phase != .done }.map { state in
            AwsLogin.Item(profile: state.profile, flow: state.flow, state: state,
                         account: state.providerOrAws == .aws ? AwsLogin.account(profile: state.profile, configText: configText) : nil,
                         provider: state.provider)
        }
        if items != awsLogins { awsLogins = items }
        // A run that just reached a phase with something to show (a URL
        // or a user code) goes out now — the mirror snapshot and the
        // phone's alert otherwise ride the fleet poll, up to a minute
        // away. Re-keyed per run (not per item), so moving from
        // `starting` to `waitingForCode` still counts as new: `key()`
        // does not change across that move.
        let waiting = Set(awsLoginStates.filter { $0.phase == .waitingForBrowser || $0.phase == .waitingForCode }.map(\.runKey))
        awsAnnouncedRunKeys.formIntersection(Set(awsLoginStates.filter { $0.phase != .done }.map(\.runKey)))
        let fresh = waiting.subtracting(awsAnnouncedRunKeys)
        awsAnnouncedRunKeys.formUnion(waiting)
        if !fresh.isEmpty, !isPlayground, awsNeedRefresh == nil {
            awsNeedRefresh = Task { [weak self] in
                await self?.refreshSnapshot()
                self?.awsNeedRefresh = nil
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
            let state = await awsLoginRunner.state(provider: provider, profile: profile)
            return AwsLogin.Reply(ok: state != nil, state: state, error: state == nil ? "no login in flight for \(profile)" : nil)
        }
        let configText = (try? String(contentsOf: AwsLogin.defaultConfigURL(), encoding: .utf8)) ?? ""
        // A credential_process profile signs in through the login profile it names.
        let profile = provider == .aws ? AwsLogin.loginProfile(profile: profile, configText: configText) : profile
        var flow: AwsLogin.Flow = local ? .local : provider.flow(profile: profile, configText: configText)
        if remote == true, flow == .relay { flow = .remote }
        let reply = await awsLoginRunner.start(provider: provider, profile: profile, flow: flow)
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

    func dismissAwsLogin(provider: AwsLogin.Provider = .aws, profile: String) async -> AwsLogin.Reply {
        let reply = await awsLoginRunner.dismiss(provider: provider, profile: profile)
        logMirrorInput("🔐", "\(provider.cliName) login for \(profile) dismissed")
        return reply
    }

    func submitAwsLoginCode(provider: AwsLogin.Provider = .aws, profile: String, code: String) async -> AwsLogin.Reply {
        await awsLoginRunner.submit(provider: provider, profile: profile, code: code)
    }

    /// The login landed: log the sign-in.
    private func awsLoginLanded(_ state: AwsLogin.State) {
        logMirrorInput("🔐", "\(state.providerOrAws.cliName) login for \(state.profile) signed in")
    }

    // MARK: crash reports (built-in, no third party — user 2026-09-04)

    /// Stores a report, logs it, and — for the phone's — says so.
    func ingestCrash(_ report: CrashReport, announce: Bool) {
        guard !crashReports.contains(where: { $0.id == report.id }) else { return }
        try? crashStore.save(report)
        crashReports = crashStore.list()
        logEvent("other", icon: "💥", "\(report.summary)")
        if announce, !isPlayground {
            self.announce("phone app crashed — \(report.reason)", icon: "💥", urgent: true)
        }
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

    private func logMirrorInput(_ icon: String, _ text: String) {
        logEvent("other", icon: icon, text)
    }

    /// Guards a fork-server publish that would move the target (#1137): the
    /// CLI's credential origin only follows a port that serves
    /// `/.well-known/t3/environment`, and only when the port it would
    /// leave still does. `ForkServerProbe.verdict` holds the rule; this adds
    /// the work-log line, so a refusal is on the record rather than inferred.
    func acceptsForkServerPublish(port: Int) async -> Bool {
        // Only a port a publish stored is a target of this instance's (#1199):
        // on the default with no pref, what answers there is another
        // instance's server — the installed app's desktop, on a dev Mac.
        let published = defaults.object(forKey: "fork_server_port") as? Int
        let verdict = await ForkServerProbe.verdict(newPort: port, currentPort: published,
                                                   using: forkServerProbe)
        if verdict == .accept { return true }
        logMirrorInput("⚠️", ForkServerProbe.refusalLine(port: port))
        return false
    }

    /// launchd owns the production engine; fixture overrides stay process-local.
    private func startSwapd(binary: String) {
        let onLine: @Sendable (EventLine) -> Void = { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }
        let onState: @Sendable (EngineSupervisor.State) -> Void = { [weak self] state in
            Task { @MainActor in self?.swapdState = state }
        }
        let supervisor: any EngineLifecycle
        if mockMode || ProcessInfo.processInfo.environment["INFINITUS_SWAPD_CLI"] != nil {
            supervisor = EngineSupervisor(binaryPath: binary, onLine: onLine, onState: onState)
        } else {
            supervisor = SwapdLaunchAgent(binaryPath: binary, onLine: onLine, onState: onState)
        }
        swapdSupervisor = supervisor
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

    /// The last "no-switch" line logged: the engine repeats "no switch —
    /// already consuming soonest" after every minute's poll, and the
    /// poll itself says nothing, so neither reaches the Activity tail or
    /// the durable log until the reason changes (Infi4, 2026-09-11).
    private var lastNoSwitch: String?

    /// When the engine last logged a `switch` row of its own. The display
    /// -feed diff below announces the switch the desktop shows, and that
    /// row already is one — so the diff only carries the news when the
    /// engine was parked (or a person swapped by hand) and logged nothing.
    private var lastEngineSwitchLog: Date?

    private func consume(_ line: EventLine) {
        switch line {
        case .event(let event):
            // Heartbeats: `poll` and `sleep` mark every tick and say
            // nothing (#475: the real daemon logs "sleep" once a minute).
            if event.kind == "poll" || event.kind == "sleep" { return }
            if event.kind == "no-switch" {
                if event.summary == lastNoSwitch { return }
                lastNoSwitch = event.summary
            }
            logEvent(Self.eventKind(event.kind), icon: event.icon, event.summary)
            switch event.kind {
            case "switch":
                lastEngineSwitchLog = Date()
                Task { await refreshSnapshot() }  // the snapshot diff posts the notification
            // Logged only (#231). "all-exhausted" arrives on every engine
            // re-probe (~10 min while dead): the latched PushTriggers message
            // owns that notification. session-resumed, remote-control-rearmed
            // and account-unquarantined used to post banners with no latch
            // and no Settings › Notify toggle; both are swapd's own
            // housekeeping now (#1041), and the revival diff already
            // carries the account-back news.
            default:
                break
            }
        case .schemaMismatch(let version):
            swapdState = .schemaMismatch(version)
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

    /// The bundled demo engine (tools/demo-swapd -> Resources), a tiny
    /// fabricated-fleet swapd. Unbundled dev runs look next to the
    /// executable instead (run-unbundled.sh copies it there).
    static func demoScriptPath() -> String? {
        if let p = Bundle.main.path(forResource: "demo-swapd", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        if let dir = (Bundle.main.executablePath as NSString?)?
            .deletingLastPathComponent {
            let p = dir + "/demo-swapd"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Playground-only: pretend no engine was found, so the onboarding
    /// card is reachable without an env-var relaunch (issue #6).
    @Published var simulateNoEngine = false
    /// True when no engine at all is configured (no swapd binary and no
    /// proxy); the popup swaps its rows for the onboarding card. A
    /// proxy-only setup is a working setup, not a missing engine.
    var engineMissing: Bool { registry.engines.isEmpty || simulateNoEngine }
    /// A setup step (no engine / no account yet) is on screen: the popup
    /// paints solid over the glass so the steps read against any desktop
    /// (user 2026-09-07 from the phone: "Disable liquid glass for set up
    /// steps", photo of the card over a Finder icon grid).
    var setupStepShown: Bool { engineMissing || (accounts.isEmpty && snapshotLoaded) }
    /// swapd is on and its binary was found — the only case the rail's
    /// auto-switch toggle and badge mean anything.
    var swapdRegistered: Bool { registry.engines.contains { $0.id == SwapdEngine.engineID } }
    /// The primary fleet's engine when it can adopt Claude Code's current
    /// login (`.addCurrent`): the in-app sign-in flow hands it the fresh
    /// credential. Gate UI on this, never on an engine id.
    var currentLoginEngine: AccountEngine? {
        guard let primary, primary.capabilities.contains(.addCurrent) else { return nil }
        return primary.engine
    }

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

    /// `swapd add` registers whichever account Claude Code is signed in
    /// as — the "adopt the current login" onboarding path.
    func addFirstAccount() {
        guard let engine = currentLoginEngine, !addingFirstAccount else { return }
        addingFirstAccount = true
        firstAccountMessage = nil
        Task {
            do {
                try await engine.addCurrent()
                await refreshSnapshot()
            } catch {
                // The engine's own text when it gave one (`swapd add` says
                // what went wrong in its login); otherwise a sentence, never
                // the raw error.
                firstAccountMessage = EngineFailure.sentence(error)
            }
            addingFirstAccount = false
        }
    }
    func relaunchApp() {
        let bundle = Bundle.main.bundleURL.path
        let oldSwapd = swapdSupervisor
        swapdSupervisor = nil
        let team = team
        let keepEngine = swapdEnabled && !mockMode
        Task {
            if keepEngine { await oldSwapd?.disconnect() }
            else { await oldSwapd?.stop() }
            // The team's now.json delete (bounded by TeamModel.quitBound), so
            // teammates stop seeing this Mac "on" across the relaunch.
            await team.quit()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Unbundled dev runs are a bare executable — `open` on its
            // directory would just raise Finder.
            let exe = Bundle.main.executablePath ?? ""
            // A fixed sleep can't be trusted to outlast this process —
            // wait for the pid to actually exit instead.
            let pid = ProcessInfo.processInfo.processIdentifier
            let wait = "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; "
            let cmd = bundle.hasSuffix(".app")
                ? wait + "/usr/bin/open \"\(bundle)\""
                : wait + "exec \"\(exe)\""
            p.arguments = ["-c", cmd]
            try? p.run()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// One pass over every enabled engine: snapshots gathered
    /// concurrently, applied per fleet, then the app-level hooks
    /// (cache, history, mirror, notifications, resume, push, sync) run
    /// off the PRIMARY Claude fleet exactly as they did when swapd was
    /// the only engine. An engine that fails keeps its last good rows
    /// (the rumps menubar's _worker policy) and records its error.
    /// One pass at a time (#1310): the timer, a control verb and the
    /// revival probe all land here, and a request made mid-pass runs once
    /// more after it instead of alongside it.
    /// `seeded` is a snapshot an engine already handed over (a flag edit's
    /// reply, #1481), by engine id: the pass takes it instead of asking
    /// that engine again, and runs all of its bookkeeping over it. A pass
    /// coalesced behind another drops nothing — every pass that is not
    /// seeded asks the engine.
    func refreshSnapshot(seeded: [String: [EngineFleet]] = [:]) async {
        await refreshFlight.run { [weak self] in await self?.refreshSnapshotPass(seeded: seeded) }
    }

    private let refreshFlight = SingleFlight()

    private func refreshSnapshotPass(seeded: [String: [EngineFleet]] = [:]) async {
        let engines = registry.engines
        guard !engines.isEmpty else { return }
        var results: [(id: String, fleets: [EngineFleet]?, error: Error?)] = []
        await withTaskGroup(of: (String, [EngineFleet]?, Error?).self) { group in
            for engine in engines {
                group.addTask {
                    if let fleets = seeded[engine.id] { return (engine.id, fleets, nil) }
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
                // Keeping the rows is right — they are still the best
                // numbers the app has — but they must stop reading as
                // current: every countdown on them is recomputed live
                // off stored reset times, so an hour-old reading looked
                // exactly like a fresh one. Age them instead.
                for state in registry.fleets where state.engineID == r.id {
                    state.markStale(reason: message, lastGood: engineLastGood[r.id], now: Date())
                }
                continue
            }
            // Only publish a change: every @Published set re-runs each
            // observer's body, once per refresh, even for an identical value (#18).
            if engineErrors[r.id] != nil { engineErrors[r.id] = nil }
            engineLastGood[r.id] = Date()
            for reported in fleets {
                let state = registry.state(for: reported)
                let fleet = reported
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
                            announce("all accounts are back" + (early ? " — Anthropic reset early" : ""),
                                     icon: "heart.fill")
                        } else {
                            for n in change.newlyAlive {
                                let name = fleet.accounts.first { $0.number == n }.map { $0.alias ?? $0.email } ?? "#\(n)"
                                announce("\(name) is back" + (early ? " — reset early" : ""), icon: "heart.fill")
                            }
                        }
                    }
                    scheduleRevivalProbe(accounts: fleet.accounts)
                }
            }
        }
        // The same account in two fleets: hand each engine the usage the
        // others fetched, so Anthropic sees one usage poll per email,
        // not one per engine (user 2026-09-02: 429s). Claude fleets only:
        // the budget being spared is Anthropic's, and a Codex login with
        // the same email is a different account with its own window (#899).
        // `results` fills in completion order, so when two engines hold one
        // email the donation goes to the richest reading (`richest(with:)`),
        // never to whichever engine happened to answer first.
        let stamp = Date()
        for engine in engines {
            var byEmail: [String: SharedUsage] = [:]
            for r in results where r.id != engine.id {
                for fleet in r.fleets ?? [] where fleet.provider == .claude {
                    for a in fleet.accounts where a.usageStatus == "ok" {
                        guard let u = a.usage else { continue }
                        let offered = SharedUsage(usage: u, at: stamp)
                        byEmail[a.email] = byEmail[a.email]?.richest(with: offered) ?? offered
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
            // Sorted keys so two passes over the same state are the same
            // bytes, and the write is skipped when they are (#1310).
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(cache), snapshotCacheWrite.take(data) {
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
                               candidateOrder: fleet.candidateOrder,
                               nextRecovery: fleet.nextRecovery)
        let previous = change.previousActive
        let firstLoad = change.firstLoad
        if !isPlayground {
            refreshDesktopActiveThreads()
            updateBattlePlan(list)
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
            statsModel.refreshIfStale()
            team.refreshIfStale()
            // A living UI keeps its lease; the cap only catches one that died.
            if localUIVisible { reportLocalActivity(visible: true) }
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
        // host (a stray `swapd auto`) holds the mutex, and a
        // parked engine sees no events — the 2026-08-28 silent-switch
        // bug. The diff sees every switch regardless of who executed it,
        // manual ones included.
        if !isPlayground, let current = list.activeAccountNumber,
           let previous, previous != current, lastNotifiedActive != current {
            lastNotifiedActive = current
            let name = accounts.first(where: { $0.number == current })
                .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(current)"
            let line = "switched to account \(current) (\(name))"
            // The engine's own `switch` row is already the switch the
            // desktop shows; a second row here would toast one swap twice.
            // A parked engine — or a manual swap — logs nothing, and then
            // this diff is the only witness and carries the news itself.
            if let logged = lastEngineSwitchLog, Date().timeIntervalSince(logged) < 30 {
                notify(line)
            } else {
                announce(line, icon: "arrow.triangle.2.circlepath")
            }
        }
        controlServer.heal()
        // Same display-feed vantage as the switch diff above: these
        // triggers fire even while the supervised engine is parked.
        let health = list.accounts
            .filter { !($0.disabled ?? false) && $0.usage != nil }
            .map { a in PushTriggers.Account(
                number: a.number,
                name: a.alias ?? String(a.email.prefix(while: { $0 != "@" })),
                dead: AccountVitals.isDead(a.usage),
                worstPct: PushTriggers.worstPlanPct(a.usage),
                spentModel: AccountVitals.spentModel(a.usage)) }
        let pushes = pushTriggers.tick(
            accounts: health,
            flags: .init(allDead: pushAllDead, lastAlive: pushLastAlive),
            now: Date())
        if pushTriggers.memory != persistedPushMemory {
            persistedPushMemory = pushTriggers.memory
            if let data = try? JSONEncoder().encode(persistedPushMemory) { defaults.set(data, forKey: Self.pushMemoryKey) }
        }
        // Both lines read "<headline> — <detail>", the shape Notifier splits
        // into a banner subtitle and body — and the shape `eventToast` splits
        // into a desktop notification's title and text.
        for msg in pushes where !isPlayground {
            announce(msg, icon: "exclamationmark.triangle", urgent: true)
        }
        if !isPlayground { await sync.tick() }
    }

    /// The badge click: running -> stop, stopped -> start ("auto switch
    /// status is clickable to toggle", user 2026-08-30). Deliberate states
    /// only — refused/backing-off/mismatch stay informational.
    func toggleEngine() {
        switch swapdState {
        case .running, .backingOff:
            let supervisor = swapdSupervisor
            swapdSupervisor = nil
            swapdState = .stopped
            Task { await supervisor?.stop() }
        case .stopped:
            guard let swapd, swapdRegistered else { return }
            startSwapd(binary: swapd.binaryPath)
        case .refused, .schemaMismatch:
            break
        }
    }

    /// The daemon the sidebar badge reports.
    var engineState: EngineSupervisor.State { swapdState }
    var engineBadgeShown: Bool { swapdRegistered }

    // Primary-fleet actions (the mac-only panes and the wall call these;
    // the shared rows act on their own FleetState).
    func switchTo(_ number: Int) { primary?.switchTo(number) }
    func rotate() { primary?.rotate() }

    @Published var reorderError: String?

    /// Closing the UI leaves automatic switching with launchd. Only the
    /// explicit engine toggle disables that service.
    func shutdown() {
        let swapdSupervisor = swapdSupervisor
        let team = team
        Task {
            await swapdSupervisor?.disconnect()
            await team.quit()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func rename(_ number: Int, to name: String) { primary?.rename(number, to: name) }
    var displayAccounts: [Account] { primary?.displayAccounts ?? [] }
    func setRotation(_ number: Int, enabled: Bool) {
        primary?.setRotation(number, enabled: enabled)
    }
    func setPreferred(_ number: Int, _ on: Bool) { primary?.setPreferred(number, on) }
    func setAutoIgnite(_ number: Int, _ on: Bool) { primary?.setAutoIgnite(number, on) }
    func reorder(_ order: [Int], done: (() -> Void)? = nil) {
        guard let primary else { done?(); return }
        primary.reorder(order, done: done)
    }
}

/// The shared fleet views (InfinitusUI, #9 phase B) render off this —
/// every requirement is an existing member; only the relogin action is
/// mac-only, so it lands here rather than in the protocol's no-op.
extension AppModel: FleetModel {
    // A click while a flow already runs brings ITS windows back rather
    // than doing nothing (user 2026-09-13: "pressing again show nothing"
    // — the sign-in was alive the whole time, buried under the pinned
    // pop-out). `start` keeps its own guard; this is the way back in.
    func startRelogin(_ account: Account) {
        guard !TokenFlow.shared.running, !addingFirstAccount else {
            TokenFlow.shared.reopenAuth(); return
        }
        // The primary's own sign-in when it takes the OAuth redirect
        // itself (FleetState.startRelogin's rule); the PTY flow otherwise.
        if let primary, primary.capabilities.contains(.addOAuth) {
            addOAuthAccount(engineID: primary.engineID, provider: primary.provider, relogin: account)
            return
        }
        TokenFlow.shared.start(model: self, relogin: account)
    }
    func addAccount() {
        guard !TokenFlow.shared.running, !addingFirstAccount else {
            TokenFlow.shared.reopenAuth(); return
        }
        if let primary, primary.capabilities.contains(.addOAuth) {
            addOAuthAccount(engineID: primary.engineID, provider: primary.provider)
            return
        }
        TokenFlow.shared.start(model: self)
    }
    var canAddAccount: Bool { currentLoginEngine != nil }

    /// The engine badge's portable half (#9 phase D2) — the supervisor's
    /// own State can't cross to iOS, so the shared footer reads this.
    var engineBadge: EngineBadge? {
        // The badge is the supervised daemon's state; with no engine the
        // footer hides the chip.
        guard engineBadgeShown else { return nil }
        switch engineState {
        case .running: return .running
        case .refused: return .refused
        case .backingOff(let seconds): return .backingOff(seconds: seconds)
        case .schemaMismatch: return .schemaMismatch
        case .stopped: return .stopped
        }
    }

    /// The onboarding card's "Engine settings" button: Settings ›
    /// Infinitus › Engines is the desktop app's (#1177).
    func openSettings() { openDesktop?("engines") }

    /// The "at this pace" line's click. The Utilization page is the
    /// desktop app's (#654, #774).
    func openForecast() { openDesktop?(nil) }

    /// The primary fleet's engine decides what the mac-only panes may do.
    var capabilities: EngineCapabilities { primary?.capabilities ?? .all }
}
