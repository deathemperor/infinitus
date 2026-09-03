import Foundation
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
    /// Animations tab so every effect can be fired by hand.
    let debugMenu = UserDefaults.standard.bool(forKey: "debug_menu")
    @Published var cswapState: CswapSupervisor.State = .stopped
    struct EventEntry: Identifiable {
        let id = UUID()
        let at = Date()
        let icon: String
        let text: String
    }
    @Published var eventLog: [EventEntry] = []
    /// App-side resume nudges + /rc re-arm (ResumeService.swift).
    let resume = ResumeService()
    /// Sessions popover's mini progress rows (SessionProgressModel.swift).
    let sessionProgress = SessionProgressModel()
    @Published var lastError: String?
    /// #7 layer 2: the reset battle plan for the current sprint, recomputed
    /// every snapshot; nil when there is nothing to plan. Manual mode: the
    /// popup line offers the ignite step behind a confirm, nothing runs
    /// by itself.
    @Published var battlePlan: WindowPlanner.Plan?
    @Published var igniting: Int?
    /// Run-rate projection: when the active account's windows hit their
    /// limits and when the fleet is out, at the measured pace (nil until
    /// there is an active account). The planner reads the same rates.
    @Published var forecast: UsageForecast?
    /// Last 24h of usage samples, the burn-rate input (5h pace over the
    /// last hour, weekly pace over the day). Seeded from this machine's
    /// history file at launch so the first plan doesn't wait ten minutes
    /// for fresh polls.
    private var recentSamples: [UsageSample] = []

    let cswap: CswapCLI?
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
    // The bundle on disk was rebuilt since this instance launched (the
    // dev loop, or a manual make-app.sh) — surfaced as "restart to update".
    @Published var appUpdatePending = false
    /// A newer Infinitus release than this build (About → Updates does
    /// the check; the popup chip just points there).
    @Published var appUpdateVersion: String?
    private let launchExecutableDate = AppModel.executableDate()
    private var supervisor: CswapSupervisor?
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
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/engines/cliproxy/usage.jsonl")
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
            awake.update(wanted: keepAwake, busyCount: liveSessions?.busy ?? 0)
        }
    }
    // Away-push triggers beyond switches (PushTriggers has the rules).
    @Published var pushSessionsDone: Bool { didSet { defaults.set(pushSessionsDone, forKey: "push_sessions_done") } }
    @Published var pushAllDead: Bool { didSet { defaults.set(pushAllDead, forKey: "push_all_dead") } }
    @Published var pushLastAlive: Bool { didSet { defaults.set(pushLastAlive, forKey: "push_last_alive") } }
    @Published var pushWaiting: Bool { didSet { defaults.set(pushWaiting, forKey: "push_waiting") } }
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
    let mirrorServer = MirrorServer()
    /// Agent CLI socket (ControlServer.swift); the real model only.
    private(set) lazy var controlServer = ControlServer(model: self)
    let quickTunnel = QuickTunnel()
    let namedTunnel = NamedTunnel()
    /// Live Activity pushes to the phone (APNs), LiveActivityPusher.swift.
    let liveActivityPusher = LiveActivityPusher()
    private let awake = KeepAwake()
    private var pushTriggers = PushTriggers()
    private let defaults: UserDefaults
    static let playgroundSuite = "com.huuloc.limitless.playground"

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
                              titleRemaining: titleRemaining),
            icon: "")  // the status button wears MenuBarGlyph instead
    }

    /// One-time prefs adoption from the pre-2026-08-30 bundle id
    /// (io.github.claude-swap.CswapBar.g2). Bundled runs only — the
    /// unbundled domain is per-executable name and unaffected. Copies,
    /// never moves: the old domain stays for rollback. Locally-set keys win.
    private static func migrateLegacyDefaults() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: "migrated_from_g2"),
              let legacy = std.persistentDomain(
                forName: "io.github.claude-swap.CswapBar.g2") else { return }
        for (key, value) in legacy where std.object(forKey: key) == nil {
            std.set(value, forKey: key)
        }
        std.set(true, forKey: "migrated_from_g2")
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
        let mock = defaults.object(forKey: "mock_mode") as? Bool ?? false
        mockMode = mock
        cswapEnabled = defaults.object(forKey: "engine_cswap_enabled") as? Bool ?? true
        cliproxyEnabled = defaults.object(forKey: "engine_cliproxy_enabled") as? Bool ?? false
        nineRouterEnabled = defaults.object(forKey: "engine_9router_enabled") as? Bool ?? false
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
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
        // A freshly minted token has to survive the launch that made it:
        // property initialisation doesn't run `didSet`.
        if storedToken.isEmpty { defaults.set(mirrorPairToken, forKey: "mirror_pair_token") }
        if !playground { sync.attach(model: self) }
        if let cswap, cswapEnabled || playground { registry.register(CswapEngine(cli: cswap)) }
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
    }

    /// App-side cache of our own subprocess output (never an engine
    /// internal file).
    static let snapshotCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Infinitus/snapshot-cache.json")
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
        titleIconOnly = defaults.object(forKey: "title_icon_only") as? Bool ?? false
        popupLayout = defaults.string(forKey: "popup_layout") ?? "wide"
        popupTextSize = defaults.string(forKey: "popup_text_size") ?? "default"
        glassFocused = defaults.object(forKey: "glass_focused") as? Double ?? 0.7
        keepAwake = defaults.object(forKey: "keep_awake") as? Bool ?? false
        sortByHeadroom = defaults.object(forKey: "sort_headroom") as? Bool ?? true
        pushSessionsDone = defaults.object(forKey: "push_sessions_done") as? Bool ?? true
        pushAllDead = defaults.object(forKey: "push_all_dead") as? Bool ?? true
        pushLastAlive = defaults.object(forKey: "push_last_alive") as? Bool ?? true
        pushWaiting = defaults.object(forKey: "push_waiting") as? Bool ?? true
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
        let rates = list.accounts.first { $0.active }.map {
            WindowTelemetry.burnRates(recentSamples, email: $0.email, now: now)
        } ?? [:]
        let plan = WindowPlanner.plan(accounts: states, burnPctPerHour: rates["5h"],
                                      busySessions: list.liveSessions?.busy ?? 0, now: now)
        if plan != battlePlan { battlePlan = plan }
        let inputs = list.accounts.map { a in
            UsageForecast.AccountInput(
                number: a.number, email: a.email, active: a.active,
                disabled: a.disabled ?? false,
                fiveHour: window(a.usage?.fiveHour), sevenDay: window(a.usage?.sevenDay),
                scoped: Dictionary((a.usage?.scoped ?? []).compactMap { sc in
                    window(sc).map { (sc.name ?? "?", $0) }
                }, uniquingKeysWith: { a, _ in a }))
        }
        let next = UsageForecast.build(accounts: inputs, rates: rates, now: now)
        // Skips the republish only while nothing is projected (the hits
        // move with `now` between polls — see docs/TODO.md, anchoring).
        if next.active != forecast?.active || next.allDeadAt != forecast?.allDeadAt {
            forecast = next
        }
    }

    private func window(_ w: UsageWindow?) -> UsageSample.Window? {
        guard let w else { return nil }
        return .init(pct: w.pct, resetsAt: w.resetsAt.flatMap(UsageHistory.parseISO)?.timeIntervalSince1970)
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

    /// Manual ignition (#7 MVP step 3) through the primary fleet's engine
    /// (`AccountEngine.ignite`, capability-gated): one tiny request as
    /// account n so its 5h clock starts now; the fleet stays put. Outcome
    /// in the event log; ~1K weekly tokens on n.
    func ignite(_ number: Int) {
        guard let primary, canIgnite, !isPlayground, igniting == nil else { return }
        igniting = number
        let engine = primary.engine, provider = primary.provider
        let name = accounts.first { $0.number == number }
            .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(number)"
        eventLog.append(EventEntry(icon: "flag.checkered", text: "igniting \(name)'s 5h window"))
        Task { [weak self] in
            do {
                try await engine.ignite(fleet: provider, number: number)
                self?.eventLog.append(EventEntry(icon: "flag.checkered", text: "ignited \(name) — window started"))
            } catch {
                self?.eventLog.append(EventEntry(icon: "exclamationmark.triangle", text: "ignite \(name) failed: \(error.localizedDescription)"))
            }
            if let self, self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
            self?.igniting = nil
            await self?.refreshSnapshot()
        }
    }

    /// Idempotent: called from app init so the supervised engine starts at
    /// LAUNCH — a window-style MenuBarExtra may not build its content view
    /// until the first click, and rumps started its engine immediately.
    func startFeeds() {
        detectOnboarding()
        seedRecentSamples()
        resume.log = { [weak self] icon, text in
            guard let self else { return }
            self.eventLog.append(EventEntry(icon: icon, text: text))
            if self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
        }
        mirrorServer.log = { [weak self] icon, text in
            guard let self else { return }
            self.eventLog.append(EventEntry(icon: icon, text: text))
            if self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
        }
        quickTunnel.log = { [weak self] icon, text in
            guard let self else { return }
            self.eventLog.append(EventEntry(icon: icon, text: text))
            if self.eventLog.count > 100 { self.eventLog.removeFirst(self.eventLog.count - 100) }
        }
        namedTunnel.log = quickTunnel.log
        liveActivityPusher.log = quickTunnel.log
        mirrorServer.activityTokens.set { [weak self] registration in
            Task { @MainActor in self?.liveActivityPusher.register(registration) }
        }
        quickTunnel.onURL = { [weak self] url in self?.publishRendezvous(url) }
        // The tunnels can only point at a bound port, which arrives later.
        mirrorServer.onReady = { [weak self] _ in
            self?.applyQuickTunnel()
            self?.applyNamedTunnel()
        }
        applyMirrorLAN()
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
    }

    /// Starts or stops the phone companion's LAN listener (#9). Never in
    /// the playground: it seeds from the real defaults and would
    /// advertise a second service with the same machine name.
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
        guard allowed, mirrorLANEnabled else {
            mirrorServer.stop()
            quickTunnel.stop()
            namedTunnel.stop()
            return
        }
        let payload = mirrorServer.payload
        Task { [mirrorExporter] in await mirrorExporter.attach(payload: payload) }
        mirrorServer.start(machineName: Host.current().localizedName ?? "Mac",
                           token: mirrorPairToken)
        mirrorServer.sessionFeed.set { pid, limit, since, wait in
            let claudeDir = ClaudeSessions.configHome()
            SessionFeedReader.waitForChange(pid: pid, claudeDir: claudeDir, since: since, wait: wait)
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
            else { return nil }
            guard let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit)
            else { return nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(feed)
        }
        mirrorServer.sessionInput.set { [weak self] pid, request in
            let claudeDir = ClaudeSessions.configHome()
            guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
            else {
                Task { @MainActor in self?.logMirrorInput("⚠️", "phone input not delivered: unknown session") }
                return nil
            }
            let reply = SessionInput.deliver(request: request, record: record,
                                             hosts: PtyHosts.available(), claudeDir: claudeDir)
            let label = URL(fileURLWithPath: record.cwd).lastPathComponent
            Task { @MainActor in
                if reply.outcome == "delivered" {
                    let preview = String(request.text.prefix(60))
                    self?.logMirrorInput("📲", "phone → \(label): \"\(preview)\" (\(reply.channel ?? "?"))")
                } else {
                    let why = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                    self?.logMirrorInput("⚠️", "phone input not delivered: \(why)")
                }
            }
            return reply
        }
        applyQuickTunnel()
        applyNamedTunnel()
    }

    /// Every phone-injected input is logged, per #17 — success or not.
    private func logMirrorInput(_ icon: String, _ text: String) {
        eventLog.append(EventEntry(icon: icon, text: text))
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
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
        eventLog.append(EventEntry(icon: "🔑", text: "phone pairing token regenerated"))
        // A new token is a new rendezvous key; the old entry just expires.
        if let url = quickTunnel.url { publishRendezvous(url) }
    }

    /// PUTs the quick tunnel's URL under this token's rendezvous key
    /// (MirrorRendezvous). Best effort: the QR still carries the URL, this
    /// only spares the rescan after a restart.
    func publishRendezvous(_ url: String) {
        guard mirrorRendezvousEnabled,
              let target = MirrorRendezvous.url(token: mirrorPairToken) else { return }
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = MirrorRendezvous.publishBody(url: url)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if code == 204 {
                    self?.eventLog.append(EventEntry(icon: "📍", text: "tunnel address published to infinitus.run"))
                } else {
                    let why = error?.localizedDescription ?? "HTTP \(code)"
                    self?.eventLog.append(EventEntry(icon: "⚠️", text: "rendezvous publish failed: \(why)"))
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

    private func consume(_ line: EventLine) {
        switch line {
        case .event(let event):
            eventLog.append(EventEntry(icon: event.icon, text: event.summary))
            if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
            switch event.kind {
            case "switch":
                Task { await refreshSnapshot() }  // the snapshot diff posts the notification
            case "session-resumed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "remote-control-rearmed":
                Notifier.post(title: "claude-swap", body: event.summary)
            case "account-unquarantined":
                Notifier.post(title: "claude-swap", body: "account back in rotation")
            case "all-exhausted":
                Notifier.post(title: "claude-swap", body: "every account is at its limit")
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
    /// cswap is on and its binary was found — the only case the rail's
    /// auto-switch toggle and badge mean anything.
    var cswapRegistered: Bool { registry.engines.contains { $0.id == CswapEngine.engineID } }

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
                firstAccountMessage = (error as? CLIError)?.message ?? "\(error)"
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
            let cmd = bundle.hasSuffix(".app")
                ? "sleep 0.8; /usr/bin/open \"\(bundle)\""
                : "sleep 0.8; exec \"\(exe)\""
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
            for fleet in fleets {
                let state = registry.state(for: fleet)
                let change = state.apply(fleet)
                anyChanged = anyChanged || change.changed
                if state === primary { primaryResult = (fleet, change) }
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
        if !isPlayground { updateBattlePlan(list) }
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
                sortByHeadroom: sortByHeadroom, popupTextSize: popupTextSize)
            // Footer-chip state (#9 phase D2), captured here for the
            // same main-actor reason as the prefs above.
            let serviceStatus = ServiceStatusSummary(
                indicator: ServiceStatusModel.shared.indicator)
            let engine = engineBadge ?? .stopped
            let allFleets = fleets.compactMap(\.lastFleet)
            let forecast = forecast
            let plan = battlePlan
            if let primaryFleet = primary.lastFleet {
                liveActivityPusher.tick(fleet: primaryFleet,
                                        machine: Host.current().localizedName ?? "Mac",
                                        themes: availableThemes, macTheme: rowTheme,
                                        report: usageModel?.report,
                                        tokenRate: sessionProgress.tokenRate)
            }
            Task.detached(priority: .utility) { [mirrorExporter] in
                await mirrorExporter.record(listJSON: raw, prefs: prefs,
                                            serviceStatus: serviceStatus,
                                            engine: engine, fleets: allFleets,
                                            forecast: forecast, plan: plan)
            }
        }
        // All-limited: count the limit-stopped sessions waiting to be
        // resumed (todo 2026-09-01), reusing the resume mechanism's
        // own detection — Claude Code's files, never engine internals.
        // Throttled: the transcript tails re-read at most every 20s.
        if list.nextCandidate == nil, list.nextRecovery != nil {
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
            Notifier.post(title: "claude-swap",
                          body: "switched to account \(current) (\(name))")
        }
        if !isPlayground {
            awake.update(wanted: keepAwake,
                         busyCount: list.liveSessions?.busy ?? 0)
        }
        controlServer.heal()
        // Same display-feed vantage: a switch (manual or parked-engine)
        // re-arms /rc; an active account that can work resumes stopped
        // sessions. Detached, single-flight — never awaited here.
        if !isPlayground {
            let active = list.accounts.first { $0.number == list.activeAccountNumber }
            resume.tick(switched: previous != nil && previous != list.activeAccountNumber,
                        activeAlive: active.map { !AccountVitals.isDead($0.usage) } ?? false,
                        activeNumber: list.activeAccountNumber,
                        activeFetchedAt: active?.usageFetchedAt
                            .flatMap(UsageHistory.parseISO))
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
                         waiting: pushWaiting),
            sessions: list.liveSessions?.sessions)
        for msg in pushes where !isPlayground {
            Notifier.post(title: "claude-swap", body: msg)
            // Text over stdin, matching the channel-setup commands;
            // no channels configured is a quiet no-op (try?). The
            // away-push channels are cswap's.
            if let cswap {
                Task { _ = try? await cswap.run(["notify", "push", "-"], stdin: msg) }
            }
        }
        if !isPlayground { await sync.tick() }
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
        let supervisor = supervisor
        Task {
            await supervisor?.stop()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    func rename(_ number: Int, to name: String) { primary?.rename(number, to: name) }
    var displayAccounts: [Account] { primary?.displayAccounts ?? [] }
    func setRotation(_ number: Int, enabled: Bool) {
        primary?.setRotation(number, enabled: enabled)
    }
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

    /// The primary fleet's engine decides what the mac-only panes may do.
    var capabilities: EngineCapabilities { primary?.capabilities ?? .all }
}
