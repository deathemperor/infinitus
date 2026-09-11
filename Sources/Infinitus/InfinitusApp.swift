import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The one AppKit knob that lets a popover-only accessory app live with no
/// open windows: without it, SwiftUI terminates the process as soon as the
/// last window closes (verified live — the app died the moment the keepalive
/// window was closed OR ordered out).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Injected by InfinitusApp.init; the status item is created HERE, in
    // applicationDidFinishLaunching — creating an NSStatusItem before the
    // app finishes launching fails silently (no item, no error).
    var makeStatusItem: (() -> Void)?
    var statusHolder: StatusItemHolder?
    /// NSApp.delegate is SwiftUI's proxy, not this adaptor — anything
    /// outside the scene graph (the playground command channel) reaches
    /// the controller through here.
    static weak var shared: AppDelegate?
    /// Set in InfinitusApp.init, alongside makeStatusItem: StatusItemController
    /// keeps its AppModel private, so the URL-open handler needs its own way in.
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        makeStatusItem?()
        Lifecycle.log.notice("finished launching")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Lifecycle.log.notice("terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// Windows get willClose during an orderly terminate; shouldTerminate
    /// runs before any window teardown, covering Quit and the relaunch path
    /// both.
    static var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.terminating = true
        Lifecycle.log.notice("quit requested by pid \(Lifecycle.quitSenderPID.map(String.init) ?? "self", privacy: .public)")
        // Spec §7: `now.json` goes on quit, on EVERY quit — Cmd-Q, logout,
        // the relaunch path — not only AppModel.shutdown(). Bounded
        // (TeamModel.quitBound) so a dead remote never holds the quit.
        guard let team = model?.team, team.inTeam, !AppDelegate.teamQuitDone else { return .terminateNow }
        AppDelegate.teamQuitDone = true
        Task { @MainActor in
            await team.quit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    static var teamQuitDone = false

    /// `open Infinitus.app` on an already-running instance lands here: open
    /// Settings. This is the guaranteed way into the UI when the menu bar is
    /// too full to display the status item at all.
    /// A Dock click lands here too — the icon exists only while Settings
    /// is open (the app is `.regular` then) — and returning false stops
    /// AppKit's own window-raising, so a buried Settings never came back
    /// (user 2026-09-09).
    func applicationShouldHandleReopen(_ app: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusHolder?.controller.showSettingsWindow()
        return false
    }

    /// `infinitus://join/…` from a QR, a message or the phone (spec §6.2).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls {
            if model.team.open(url: url) { break }
        }
    }
}

@main
struct InfinitusApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var reliabilityModel: ResumeReliabilityModel
    @StateObject private var usageModel: UsageModel
    @StateObject private var updateModel: UpdateModel
    @StateObject private var appRelease: AppReleaseModel
    @StateObject private var brew: BrewUpdater
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Menu bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        Lifecycle.armed()
        #if DEBUG
        // Hot reload (docs/guides/hot-reload.md): opt in per launch so the
        // shots instances never dial the injection server.
        if ProcessInfo.processInfo.environment["INFINITUS_INJECT"] != nil {
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        }
        #endif
        RenameMigration.run()   // before anything reads App Support
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let settingsModel = SettingsModel(cli: model.cswap)
        _settingsModel = StateObject(wrappedValue: settingsModel)
        let usage = UsageModel(cli: model.cswap)
        _usageModel = StateObject(wrappedValue: usage)
        model.usageModel = usage   // the cswap fleet's cash column
        let update = UpdateModel(cli: model.cswap)
        _updateModel = StateObject(wrappedValue: update)
        update.restartEngine = { [weak model] in model?.restartEngine() }
        update.startAutoCheck()
        model.updateModel = update
        let release = AppReleaseModel()
        _appRelease = StateObject(wrappedValue: release)
        release.onUpdate = { [weak model] in model?.appUpdateVersion = $0 }
        release.onLatest = { [weak model] in model?.appReleaseLatest = $0 }
        release.startAutoCheck()
        // Hoisted out of AboutPane so the phone's `/app/update` route
        // (#121) drives the SAME BrewUpdater as the About pane's button
        // — never two upgrades in flight.
        let brew = BrewUpdater()
        _brew = StateObject(wrappedValue: brew)
        model.brewUpdater = brew
        let reliabilityModel = ResumeReliabilityModel()
        _reliabilityModel = StateObject(wrappedValue: reliabilityModel)
        // Warm the multi-second transcript scan at launch so the Usage tab
        // and the gamified gold column open onto data, not a spinner.
        usage.loadIfNeeded()
        appDelegate.model = model
        appDelegate.makeStatusItem = { [weak appDelegate] in
            appDelegate?.statusHolder = StatusItemHolder(
                model: model,
                settingsTabs: {
                    settingsTabs(
                        model: model, settingsModel: settingsModel,
                        reliabilityModel: reliabilityModel,
                        updateModel: update, appRelease: release, brew: brew)
                })
        }
        model.startFeeds()
        // Deferred past didFinishLaunching: requesting in App.init — before
        // the app is registered with Notification Center — fails with
        // "Notifications are not allowed for this application".
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Notifier.requestAuthorization()
        }
        Task { await model.refreshSnapshot() }
    }

    var body: some Scene {
        // No MenuBarExtra scene: the status item is a raw NSStatusItem owned
        // by StatusItemController (see its header for why). Keep-alive with
        // zero windows comes from KeepAliveDelegate.

        // macOS 26 puts this scene's window on screen by itself at launch
        // — and SwiftUI keeps it non-resizable whatever .windowResizability
        // says (it re-strips the .resizable bit on every update; probed
        // 2026-09-02). StatusItemController hides it as it appears; the
        // controller-owned window is the one Settings window.
        // (.defaultLaunchBehavior(.suppressed) would be cleaner but is
        // macOS 15+, and SceneBuilder takes no #available branch.)
        Settings {
            SettingsRoot(tabs: settingsTabs(
                model: model, settingsModel: settingsModel,
                reliabilityModel: reliabilityModel,
                updateModel: updateModel, appRelease: appRelease, brew: brew))
        }
        // ⌘, would raise that hidden scene window (and the controller
        // would hide it again — "opened and closed immediately", user
        // 2026-09-03). Route the standard Settings command to ours.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings?() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// The settings panes, declared once. The Settings scene (the standard
/// app-menu path, unreachable for an accessory app with no app menu)
/// renders them as a SwiftUI TabView; the controller-owned window the
/// popup's Settings… button opens renders them as an AppKit
/// NSTabViewController(tabStyle: .toolbar) — the REAL icon-toolbar
/// Settings look, which no public SwiftUI TabViewStyle reproduces.
@MainActor func settingsTabs(
    model: AppModel, settingsModel: SettingsModel,
    reliabilityModel: ResumeReliabilityModel,
    updateModel: UpdateModel, appRelease: AppReleaseModel, brew: BrewUpdater
) -> [SettingsTab] {
    // What cannot leave the Mac (#654): account flows, pairing, the lock,
    // the team, the engines' secrets, About. Display, Themes, Push,
    // Profiles, Usage, Utilization, Stats, Machine, Activity and the
    // Animations debug pane are the desktop app's now, over the pref
    // catalog and the control verbs.
    [
        SettingsTab(title: "Accounts", symbol: "person.2.badge.key", tint: .blue,
                    keywords: ["account", "login", "relogin", "token",
                               "add", "remove", "delete", "oauth",
                               "order", "reorder", "alias", "rename"],
                    view: AnyView(AccountsPane(model: model))),
        // "Sync" until 2026-09-02: the pane grew the phone companion and
        // its routes, and syncing settings is now the smaller half.
        SettingsTab(title: "Devices", symbol: "iphone.and.arrow.right.inward", tint: .cyan,
                    keywords: ["icloud", "sync", "settings", "drive", "devices",
                               "phone", "iphone", "lan", "bonjour", "companion",
                               "tailscale", "cloudflare", "tunnel", "pair", "qr"],
                    view: AnyView(SyncPane(sync: model.sync, app: model))),
        SettingsTab(title: LockModel.paneTitle, symbol: "lock.fill", tint: .gray,
                    keywords: ["biometric", "touch id", "face id", "password",
                               "unlock", "privacy", "team"],
                    view: AnyView(LockPane(lock: model.lock))),
        SettingsTab(title: TeamModel.paneTitle, symbol: "person.3", tint: .teal,
                    keywords: ["team", "invite", "code", "join", "members", "leader", "share", "publish", "exclude", "control", "grant", "drive"],
                    view: AnyView(TeamPane(team: model.team, feed: model.teamControlFeed))),
    ]
    + [
        SettingsTab(title: "About", symbol: "info.circle", tint: .indigo,
                    keywords: ["update", "version", "license", "links"],
                    image: AboutPane.infinitusIcon,
                    view: AnyView(AboutPane(appRelease: appRelease, brew: brew))),
        // Providers under everything, CodexBar-style (user 2026-08-30).
        // The engine is cswap; Claude is what it drives (user 2026-08-30:
        // "claude is not an engine, cswap is").
        SettingsTab(title: "cswap", symbol: "asterisk",
                    keywords: ["engine", "auto switch", "interval", "config",
                               "threshold", "rotate", "claude", "provider",
                               "update", "upgrade", "pypi",
                               "nudge", "resume", "wake", "session"],
                    // "on" = the engine is enabled and found; whether its
                    // auto-switch child runs is the tab's own business.
                    provider: ProviderBadge(live: model.cswapRegistered),
                    view: AnyView(ClaudeEnginePane(model: model,
                                                   settings: settingsModel,
                                                   update: updateModel,
                                                   reliability: reliabilityModel))),
        SettingsTab(title: "swapd", symbol: "bolt.horizontal",
                    keywords: ["swapd", "engine", "provider", "claude", "codex",
                               "kiro", "gemini", "preview", "rust"],
                    provider: ProviderBadge(live: model.swapdRegistered
                                            && model.engineErrors[SwapdEngine.engineID] == nil),
                    view: AnyView(SwapdEnginePane(model: model))),
        SettingsTab(title: "CLIProxyAPI", symbol: "network",
                    keywords: ["proxy", "cliproxy", "router", "management",
                               "key", "engine", "provider", "claude"],
                    provider: ProviderBadge(live: model.cliproxyEnabled
                                            && model.engineErrors[CLIProxyEngine.engineID] == nil
                                            && model.fleets.contains { $0.engineID == CLIProxyEngine.engineID }),
                    view: AnyView(CLIProxyEnginePane(model: model))),
        SettingsTab(title: "9Router", symbol: "arrow.triangle.branch",
                    keywords: ["9router", "router", "engine", "provider",
                               "claude", "password"],
                    provider: ProviderBadge(live: model.nineRouterEnabled
                                            && model.engineErrors[NineRouterEngine.engineID] == nil
                                            && model.fleets.contains { $0.engineID == NineRouterEngine.engineID }),
                    view: AnyView(NineRouterEnginePane(model: model))),
    ]
}

/// The settings shell: a searchable, grouped sidebar on the left and
/// the selected pane on the right. The sidebar is a `List(selection:)`
/// (arrow keys, type-select, focus ring and accessible rows, all free)
/// inside our own HStack — NOT a NavigationSplitView, whose
/// List-selection → detail hop froze under synthetic clicks
/// (2026-08-30). The plain-Button sidebar that replaced it back then
/// had none of those affordances and announced every row as "button"
/// (design critique 2026-09-06, P0); a bare List does not take the
/// split view's hop and restores them.
struct SettingsRoot: View {
    let tabs: [SettingsTab]
    @State private var selection: String?
    /// The pane actually on screen. Usually the selection; a search hit
    /// selects a ROW and opens the pane that row lives on.
    @State private var pane: String?
    @State private var query = ""
    @State private var highlight: String?
    @State private var clearHighlight: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: SettingsSearchIndex { SettingsSearchCatalog.index(tabs: tabs) }
    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var results: [(pane: String, entries: [SettingsSearchEntry])] {
        searching ? index.grouped(query) : []
    }
    private var current: SettingsTab? {
        tabs.first { $0.title == pane } ?? tabs.first
    }
    private var group: SettingsGroup {
        current.map { SettingsGroup.of($0) } ?? .general
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.top, 14)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                SettingsSidebar(tabs: tabs, results: results,
                                searching: searching, query: query,
                                selection: $selection)
            }
            .frame(width: 215)
            Divider()
            detail
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .background(WindowTitler(title: "Settings", subtitle: current?.title ?? ""))
        // ⌘F puts the caret in the field; an accessory app has no menu
        // bar to hang the standard Find item off (critique: Alex "has
        // no ⌘F").
        .overlay {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if selection == nil {
                selection = tabs.first?.title
                pane = tabs.first?.title
            }
        }
        .onChange(of: selection) { _, new in select(new) }
        .onChange(of: query) { _, _ in retargetForQuery() }
        // Dev harness: `playctl settings <Title>` lands on a named pane
        // (pane screenshots without synthetic sidebar clicks).
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("infinitus.selectPane"))) { note in
            if let title = note.object as? String,
               tabs.contains(where: { $0.title == title }) {
                query = ""
                highlight = nil
                selection = title
                pane = title
            }
        }
        .reloadOnInjection()
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        ScrollViewReader { proxy in
            Group {
                if searching, results.isEmpty {
                    // Nothing stale left on screen: the old shell blanked
                    // the sidebar and kept the previous pane showing with
                    // nothing selected (critique P1).
                    ContentUnavailableView.search(text: query)
                } else if let tab = current {
                    tab.view
                        .frame(maxWidth: group.contentWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.settingsHighlight, highlight)
            .onChange(of: highlight) { _, anchor in
                guard let anchor else { return }
                // The pane has to render before its sections have ids.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if reduceMotion {
                        proxy.scrollTo(anchor, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: search field

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
            if searching {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.secondary.opacity(0.25)))
    }

    // MARK: selection

    /// A sidebar selection is either a pane title or a search hit's id.
    private func select(_ id: String?) {
        guard let id else { return }
        if tabs.contains(where: { $0.title == id }) {
            pane = id
            flash(nil)
        } else if let hit = index.entry(id: id) {
            pane = hit.pane
            flash(hit.anchor)
        }
    }

    /// Keeps the detail honest while the query changes: the selected
    /// pane stays if it still has hits, otherwise the first hit wins.
    private func retargetForQuery() {
        // Clearing the field: the sidebar goes back to pane rows, so a
        // selection still holding a search hit's id would highlight
        // nothing. Hand it back the pane that is showing.
        guard searching else { flash(nil); selection = pane; return }
        let groups = results
        guard !groups.isEmpty else { return }
        if let pane, groups.contains(where: { $0.pane == pane }) { return }
        if let first = groups.first?.entries.first {
            selection = first.id
        }
    }

    private func flash(_ anchor: String?) {
        clearHighlight?.cancel()
        highlight = anchor
        guard anchor != nil else { return }
        clearHighlight = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}

/// The CLIProxyAPI footnote the Engines pane shows once a proxy install is
/// detected on this machine.
enum DetectionLines {
    // Plain string concat stalls the ViewBuilder type-checker (swift 6.3,
    // measured here) — built as a function instead.
    static func proxyLine(_ proxy: CLIProxyInfo, live: Bool) -> String {
        var s = "CLIProxyAPI detected"
        if live { s += " (running)" }
        s += " — \(proxy.credentialFiles) credential file"
        if proxy.credentialFiles != 1 { s += "s" }
        s += " in \(proxy.authDir). Turn the engine on to manage them here."
        return s
    }
}
