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

    /// Windows get willClose during an orderly terminate, and the pop-out's
    /// close handler must NOT read that as "the user dismissed me" — quitting
    /// wiped the restore flag every time (user 2026-08-30: "popout setting
    /// is not saved after restarting"). shouldTerminate runs before any
    /// window teardown, covering Quit and the relaunch path both.
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

    /// `open Infinitus.app` on an already-running instance lands here: show
    /// the pinned window. This is the guaranteed way into the UI when the
    /// menu bar is too full to display the status item at all.
    func applicationShouldHandleReopen(_ app: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusHolder?.controller.showPinnedWindow()
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
    @StateObject private var notifyModel: NotifyModel
    @StateObject private var usageModel: UsageModel
    @StateObject private var utilizationModel = UtilizationModel()
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
        // playground/shots instances never dial the injection server.
        if ProcessInfo.processInfo.environment["INFINITUS_INJECT"] != nil {
            Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        }
        #endif
        RenameMigration.run()   // before anything reads App Support
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let settingsModel = SettingsModel(cli: model.cswap)
        _settingsModel = StateObject(wrappedValue: settingsModel)
        let notifyModel = NotifyModel(cli: model.cswap)
        _notifyModel = StateObject(wrappedValue: notifyModel)
        let usage = UsageModel(cli: model.cswap)
        _usageModel = StateObject(wrappedValue: usage)
        model.usageModel = usage   // the cswap fleet's cash column
        let utilization = UtilizationModel()
        _utilizationModel = StateObject(wrappedValue: utilization)
        let update = UpdateModel(cli: model.cswap)
        _updateModel = StateObject(wrappedValue: update)
        update.restartEngine = { [weak model] in model?.restartEngine() }
        update.startAutoCheck()
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
                model: model, usage: usage,
                settingsTabs: {
                    settingsTabs(
                        model: model, settingsModel: settingsModel,
                        reliabilityModel: reliabilityModel,
                        notifyModel: notifyModel, usageModel: usage,
                        utilizationModel: utilization,
                        statsModel: model.statsModel,
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
        Playground.openAtLaunchIfAsked(usage: usage)
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
                notifyModel: notifyModel, usageModel: usageModel,
                utilizationModel: utilizationModel,
                statsModel: model.statsModel,
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
    notifyModel: NotifyModel, usageModel: UsageModel,
    utilizationModel: UtilizationModel,
    statsModel: StatsModel,
    updateModel: UpdateModel, appRelease: AppReleaseModel, brew: BrewUpdater
) -> [SettingsTab] {
    // Ordered by how often each pane is reached for (user 2026-08-30:
    // "reorder the settings"): everyday looks first, plumbing after,
    // About last; engines keep their own trailing section.
    [
        SettingsTab(title: "Display", symbol: "menubar.rectangle", tint: .purple,
                    keywords: ["layout", "popup", "size", "compact",
                               "menu bar", "icon"],
                    view: AnyView(DisplayPane(model: model))),
        SettingsTab(title: "Accounts", symbol: "person.2.badge.key", tint: .blue,
                    keywords: ["account", "login", "relogin", "token",
                               "add", "remove", "delete", "oauth",
                               "order", "reorder", "alias", "rename"],
                    view: AnyView(AccountsPane(model: model))),
        SettingsTab(title: "Themes", symbol: "paintpalette", tint: .orange,
                    keywords: ["theme", "skin", "gallery", "community",
                               "rpg", "row", "gamification"],
                    view: AnyView(ThemesPane(model: model))),
        SettingsTab(title: "Push", symbol: "antenna.radiowaves.left.and.right",
                    tint: .red,
                    keywords: ["slack", "telegram", "webhook", "notification"],
                    view: AnyView(NotifyPane(model: notifyModel, app: model))),
        SettingsTab(title: "Usage", symbol: "chart.bar", tint: .green,
                    keywords: ["spend", "cost", "tokens", "estimate"],
                    view: AnyView(UsagePane(model: usageModel))),
        SettingsTab(title: "Utilization", symbol: "chart.xyaxis.line",
                    tint: .mint,
                    keywords: ["history", "utilization", "waste", "window",
                               "5h", "7d", "weekly", "chart", "over time"],
                    view: AnyView(UtilizationPane(model: utilizationModel))),
        SettingsTab(title: "Stats", symbol: "chart.bar.xaxis", tint: .indigo,
                    keywords: ["stats", "metrics", "commits", "prs", "lines",
                               "messages", "sessions", "week", "month", "year"],
                    view: AnyView(StatsPane(model: statsModel))),
    ]
    + (MachineModel.paneShown
       ? [SettingsTab(title: "Machine", symbol: "cpu", tint: .brown,
                      keywords: ["machine", "health", "hooks", "runaway", "temp",
                                 "swap", "memory", "residue", "guardian"],
                      view: AnyView(MachinePane(model: model.machineModel)))]
       : [])
    + [
        SettingsTab(title: "Profiles", symbol: "person.text.rectangle", tint: .pink,
                    keywords: ["profile", "preset", "start", "session", "model",
                               "permission", "system prompt", "launch"],
                    view: AnyView(ProfilesPane(profiles: model.sessionProfiles))),
        SettingsTab(title: "Activity", symbol: "clock.arrow.circlepath", tint: .teal,
                    keywords: ["history", "switches", "log", "events"],
                    view: AnyView(ActivityPane(model: model))),
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
                    keywords: ["team", "invite", "code", "join", "members", "leader", "share", "publish", "exclude"],
                    view: AnyView(TeamPane(team: model.team, lock: model.lock))),
    ]
    + (model.debugMenu
       ? [SettingsTab(title: "Animations", symbol: "sparkles", tint: .pink,
                      keywords: ["debug", "test"],
                      view: AnyView(AnimationsDebugPane(model: model,
                                                        usage: usageModel)))]
       : [])
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

/// CodexBar-style settings shell: a searchable sidebar of icon-tile rows
/// on the left, the selected pane on the right. Hand-rolled (no
/// NavigationSplitView): the split view's List-selection -> detail hop
/// froze under synthetic clicks in the controller-owned window
/// (2026-08-30), plain Buttons cannot, and the search field finally gets
/// breathing room under the titlebar (user: "search box needs top
/// space").
struct SettingsRoot: View {
    let tabs: [SettingsTab]
    @State private var selection: String?
    @State private var query = ""

    private var filtered: [SettingsTab] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tabs }
        return tabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(q)
                || tab.keywords.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }
    private var current: SettingsTab? {
        tabs.first { $0.title == selection } ?? tabs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 215)
            Divider()
            Group {
                if let tab = current {
                    tab.view
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .onAppear { if selection == nil { selection = tabs.first?.title } }
        // Dev harness: `playctl settings <Title>` lands on a named pane
        // (pane screenshots without synthetic sidebar clicks).
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("infinitus.selectPane"))) { note in
            if let title = note.object as? String,
               tabs.contains(where: { $0.title == title }) {
                selection = title
            }
        }
        .reloadOnInjection()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.top, 14)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered.filter { $0.provider == nil }, id: \.title) { tab in
                        generalRow(tab)
                    }
                    let providers = filtered.filter { $0.provider != nil }
                    if !providers.isEmpty {
                        HStack {
                            Text("Engines")
                            Spacer()
                            Text("\(providers.filter { $0.provider?.live == true }.count) on")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        ForEach(providers, id: \.title) { tab in
                            providerRow(tab)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func generalRow(_ tab: SettingsTab) -> some View {
        let selected = current?.title == tab.title
        return Button { selection = tab.title } label: {
            HStack(spacing: 8) {
                if let image = tab.image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(tab.tint.gradient))
                }
                Text(tab.title)
                    .foregroundStyle(selected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor : .clear))
    }

    private func providerRow(_ tab: SettingsTab) -> some View {
        let badge = tab.provider ?? ProviderBadge()
        let selected = current?.title == tab.title
        return Button { selection = tab.title } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(tab.title)
                Spacer()
                if badge.live {
                    Circle().fill(.green)
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white)
                             : badge.placeholder ? AnyShapeStyle(.tertiary)
                             : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(badge.placeholder)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor : .clear))
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    /// False in the pop-out: PinnedRoot already wears the header as its
    /// drag strip, and two of them would stack.
    var showHeader = true
    @ObservedObject private var status = ServiceStatusModel.shared
    /// Measured height of the compact rows column — the rail column
    /// count follows it (never the other way round).
    @State private var compactRowsHeight: CGFloat = 0

    var body: some View {
        Group {
            if model.compactRows {
                // Compact adapts to the fleet size: a couple of accounts
                // get a horizontal icon strip under the rows (a vertical
                // rail would dwarf them); more get a two-column icon rail
                // (seven stacked icons out-grew five rows and left dead
                // space below — the rail must never drive the height).
                if model.accounts.count <= 3 {
                    VStack(alignment: .leading, spacing: 8) {
                        accountArea
                        errorLines
                        HStack(spacing: 12) { compactControls }
                            .introSlide(model, fromLeft: true)
                            .buttonStyle(.borderless)
                    }
                } else {
                    // Responsive rail (user 2026-08-30: five accounts
                    // still got two columns): one column whenever the
                    // MEASURED account column is tall enough to hold
                    // every rail icon; two only when it isn't — the rail
                    // must never drive the popup's height. Item counting
                    // mirrors compactControls' conditionals.
                    let oneColumn = compactRowsHeight
                        >= CGFloat(compactRailItemCount) * 30 - 10
                    HStack(alignment: .top, spacing: 8) {
                        LazyVGrid(columns: Array(
                            repeating: GridItem(.fixed(20), spacing: 10),
                            count: oneColumn ? 1 : 2),
                                  spacing: 10) {
                            compactControls
                        }
                        .frame(width: oneColumn ? 24 : 52)
                        .buttonStyle(.borderless)
                        .zIndex(1)   // instant tips overlay the row column
                        VStack(alignment: .leading, spacing: 8) {
                            accountArea
                            errorLines
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height }
                            action: { compactRowsHeight = $0 }
                    }
                }
            } else if model.popupLayout == "stacked" {
                // Vertical layout: the controls ride a side rail — a
                // footer row under narrow cards only added height, and
                // the icons fill the width the tall popup wasn't using
                // ("put icon on side to thicken the popup", user
                // 2026-08-30).
                VStack(alignment: .leading, spacing: 8) {
                    if showHeader { InfinitusHeader(model: model) }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 12) { stackedRail }
                            .introSlide(model, fromLeft: true)
                            .buttonStyle(.borderless)
                            // Above the cards: the instant tips overlay
                            // rightward across the card column, and a
                            // later sibling would draw over them
                            // (user screenshot 2026-08-30).
                            .zIndex(1)
                        VStack(alignment: .leading, spacing: 8) {
                            accountArea
                            errorLines
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Compact mode stays headerless on purpose — it exists
                    // to be tiny.
                    if showHeader { InfinitusHeader(model: model) }
                    accountArea
                    errorLines
                    Divider()
                    // One footer row (user request 2026-08-30, was two):
                    // actions leading, app chrome after, status chips
                    // trailing. "Test notification" retired — the Push
                    // pane keeps its own test button. Stacked layout gets
                    // icon-only buttons: the titled row out-widened the
                    // narrow cards and the footer drove the popup width
                    // (cards stretched to fill, 2026-08-30 screenshot).
                    // Grouped, not a flat run of mismatched pills
                    // ("rearrange this properly", user 2026-08-30):
                    // titled actions · icon view-toggles · status chips ·
                    // app controls at the trailing edge.
                    HStack(spacing: 6) {
                        // Intro: the two ends of the control row enter
                        // from their own sides (user launch script).
                        // footerActionsHidden strips the buttons but the
                        // status chips stay — their actions all live in
                        // the status item's right-click menu.
                        // Rotate/Refresh buttons retired 2026-09-02
                        // ("looks obsolete" with auto-rotation) — both
                        // stay in the status item's right-click menu.
                        if !model.footerActionsHidden {
                        HStack(spacing: 6) {
                            Button {
                                model.popoverPinned.toggle()
                            } label: {
                                Image(systemName: model.popoverPinned ? "pin.fill" : "pin")
                            }
                            .instantTip(model.popoverPinned ? "Unpin popup" : "Pin popup open",
                                        edge: .above)
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    model.compactRows.toggle()
                                }
                            } label: {
                                Image(systemName: "rectangle.compress.vertical")
                            }
                            .instantTip("Compact mode", edge: .above)
                            layoutToggleIcon
                                .instantTip(nextLayout.tip, edge: .above)
                            popOutIcon
                                .instantTip("Pop out into a window", edge: .above)
                        }
                        .introSlide(model, fromLeft: true)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            // The chips themselves are shared with the
                            // phone (InfinitusUI/FooterChips, #9 phase
                            // D2); only the AppKit-bound extras stay
                            // here — the status hover card rides in as
                            // a modifier, the action buttons below are
                            // mac-only.
                            FooterChips(
                                model: model, progress: model.sessionProgress,
                                status: ServiceStatusSummary(indicator: status.indicator),
                                onStatusTap: { status.openPage() },
                                serviceChrome: StatusHoverCard(status: status))
                            if !model.footerActionsHidden {
                                if model.debugMenu {
                                    // Dev builds only (defaults write
                                    // <domain> debug_menu -bool true).
                                    Button {
                                        Playground.show(usage: usage)
                                    } label: {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    .instantTip("Playground (dev)",
                                                edge: .above)
                                }
                                Button {
                                    model.showSettings?()
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .instantTip("Settings", edge: .above)
                                Button {
                                    model.relaunchApp()
                                } label: {
                                    Image(systemName: "arrow.trianglehead.clockwise")
                                }
                                .instantTip("Restart app", edge: .above)
                                Button {
                                    model.shutdown()   // engine stops first
                                } label: {
                                    Image(systemName: "power")
                                }
                                .instantTip("Quit", edge: .above)
                            }
                        }
                        .introSlide(model, fromLeft: false)
                    }
                }
            }
        }
        .padding(model.compactRows ? 8 : 10)
        // No minWidth in compact: full mode's 560 floor was sticking
        // through the switch and padding the popup out sideways
        // (user-reported overflow after full->compact).
        .frame(minWidth: model.compactRows || model.popupLayout != "wide"
                         ? nil : 560)
        .animation(.easeInOut(duration: 0.3), value: model.compactRows)
        .animation(.easeInOut(duration: 0.3), value: model.gamification)
        // ONE tip chip for the whole popup, drawn above every row and
        // control -- see ActiveTipKey for why locals couldn't win.
        .overlayPreferenceValue(ActiveTipKey.self) { InstantTipCanvas(tips: $0) }
        // Real scaling, not dynamicTypeSize: macOS ignores Dynamic Type,
        // so the popup renders at 1x and scaleEffect + a matching frame
        // grow both the pixels AND the popover's fitting size.
        .modifier(PopupScale(scale: model.popupScale))
        .environment(\.introTick, model.introTick)
        .environment(\.introBarDelay, model.introBarDelay)
        .onAppear { status.refreshIfStale() }
        // Click-to-switch asks first (user request): rows only STAGE the
        // target; this alert commits it.
        .alert(
            "Switch account?",
            isPresented: Binding(
                get: { model.pendingSwitch != nil },
                set: { if !$0 { model.pendingSwitch = nil } })
        ) {
            Button("Switch") {
                if let n = model.pendingSwitch { model.switchTo(n) }
                model.pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Claude Code session on this machine rides the "
                 + "active account. Switch to account "
                 + "\(model.pendingSwitch.map(String.init) ?? "?")?")
        }
    }

    /// Ten-plus accounts scroll instead of growing an off-screen popup.
    @ViewBuilder private var accountArea: some View {
        Group {
            if model.engineMissing {
                OnboardingCard(model: model)
            } else if model.accounts.isEmpty && model.snapshotLoaded {
                FirstAccountCard(model: model)
            } else if model.fleets.reduce(0, { $0 + $1.accounts.count }) > 10 {
                ScrollView(showsIndicators: false) {
                    FleetStack(fleets: model.fleets)
                }
                .frame(maxHeight: 560)
            } else {
                FleetStack(fleets: model.fleets)
            }
        }
        .introContent(model)
    }

    /// Stacked layout's control rail: the footer's actions as a vertical
    /// icon column beside the cards. Unlike compactControls it keeps
    /// the Compact (compress) toggle.
    @ViewBuilder private var stackedRail: some View {
        if !model.footerActionsHidden {
        if model.debugMenu {
            Button { Playground.show(usage: usage) } label: {
                Image(systemName: "wand.and.stars")
            }
            .instantTip("Playground (dev)")
        }
        Button { model.showSettings?() } label: {
            Image(systemName: "gearshape")
        }
        .instantTip("Settings")
        Button { model.popoverPinned.toggle() } label: {
            Image(systemName: model.popoverPinned ? "pin.fill" : "pin")
        }
        .instantTip(model.popoverPinned ? "Unpin popup" : "Pin popup open")
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                model.compactRows.toggle()
            }
        } label: {
            Image(systemName: "rectangle.compress.vertical")
        }
        .instantTip("Compact mode")
        layoutToggleIcon
            .instantTip(nextLayout.tip)
        popOutIcon
            .instantTip("Pop out into a window")
        }
        serviceDot
        brainBadge
        if model.appUpdatePending {
            Button { model.relaunchApp() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            .instantTip("Restart to update")
        }
        if let v = model.appUpdateVersion {
            Button { model.showSettings?() } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
            }
            .instantTip("Infinitus \(v) is out — About → Updates")
        }
        if model.cswapRegistered { engineBadgeIcon }
        if !model.footerActionsHidden {
        Button { model.relaunchApp() } label: {
            Image(systemName: "arrow.trianglehead.clockwise")
        }
        .instantTip("Restart app")
        Button { model.shutdown() } label: {
            Image(systemName: "power")
        }
        .instantTip("Quit")
        }
    }

    /// Rail-width session chip: the brain with the busy count as a badge
    /// (agentChip's full-mode text row is wider than the rail).
    @ViewBuilder private var brainBadge: some View {
        if let live = model.liveSessions {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    if live.busy > 0 {
                        Text("\(live.busy)")
                            .font(.system(size: 8, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: 8, y: -7)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.sessionsShown.toggle() }
                .popover(isPresented: $model.sessionsShown, arrowEdge: .trailing) {
                    MacSessionsPopover(model: model, live: live)
                }
                .instantTip(SessionSummary.tooltip(live))
        }
    }

    /// How many icons compactControls will actually emit — must mirror
    /// its conditionals so the rail's column math stays honest.
    private var compactRailItemCount: Int {
        var n = 1                                   // serviceDot
        if model.cswapRegistered { n += 1 }         // engineBadgeIcon
        if !model.footerActionsHidden {
            n += 7                                  // 5 actions + restart + quit
            if model.debugMenu { n += 1 }           // playground wand (dev)
        }
        if let live = model.liveSessions, live.busy > 0 { n += 1 }
        if model.appUpdatePending { n += 1 }
        if model.appUpdateVersion != nil { n += 1 }
        return n
    }

    /// The compact-mode controls, container-agnostic: the caller decides
    /// rail grid vs horizontal strip.
    @ViewBuilder private var compactControls: some View {
        if !model.footerActionsHidden {
        if model.debugMenu {
            Button { Playground.show(usage: usage) } label: {
                Image(systemName: "wand.and.stars")
            }
            .instantTip("Playground (dev)")
        }
        Button { model.showSettings?() } label: {
            Image(systemName: "gearshape")
        }
        .instantTip("Settings")
        Button { model.popoverPinned.toggle() } label: {
            Image(systemName: model.popoverPinned ? "pin.fill" : "pin")
        }
        .instantTip(model.popoverPinned ? "Unpin popup" : "Pin popup open")
        Button { model.compactRows.toggle() } label: {
            Image(systemName: "rectangle.expand.vertical")
        }
        .instantTip("Full mode")
        layoutToggleIcon
            .instantTip(nextLayout.tip)
        popOutIcon
            .instantTip("Pop out into a window")
        }
        serviceDot
        agentChip
        if model.appUpdatePending {
            Button { model.relaunchApp() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            .instantTip("Restart to update")
        }
        if let v = model.appUpdateVersion {
            Button { model.showSettings?() } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
            }
            .instantTip("Infinitus \(v) is out — About → Updates")
        }
        if model.cswapRegistered { engineBadgeIcon }
        if !model.footerActionsHidden {
        Button { model.relaunchApp() } label: {
            Image(systemName: "arrow.trianglehead.clockwise")
        }
        .instantTip("Restart app")
        Button { model.shutdown() } label: {
            Image(systemName: "power")
        }
        .instantTip("Quit")
        }
    }

    /// Cycles wide rows -> stacked cards -> horizontal cards, mirroring
    /// the Display pane's "Popup layout" picker; icon and tip name the
    /// NEXT layout in the cycle.
    private var nextLayout: (id: String, icon: String, tip: String) {
        switch model.popupLayout {
        case "stacked": return ("hstack", "rectangle.split.2x1", "Switch to horizontal cards")
        case "hstack": return ("wide", "line.3.horizontal", "Switch to wide rows")
        default: return ("stacked", "rectangle.split.1x2", "Switch to stacked cards")
        }
    }

    private var layoutToggleIcon: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                model.popupLayout = nextLayout.id
            }
        } label: {
            Image(systemName: nextLayout.icon)
        }
        .help(nextLayout.tip)
    }

    @ViewBuilder private var errorLines: some View {
        AllDeadBanner(model: model)
        if let err = model.lastError {
            Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// Live Claude Code sessions on this machine — they all ride the
    /// active account's credential. Compact shows the brain only when
    /// something is actually working.
    @ViewBuilder private var agentChip: some View {
        if let live = model.liveSessions, !model.compactRows || live.busy > 0 {
            Group {
                if model.compactRows {
                    // The icon rail's cells are 20pt: side-by-side text
                    // clips there (user screenshot), so compact wears the
                    // count as a badge on the brain instead.
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .overlay(alignment: .topTrailing) {
                            Text("\(live.busy)")
                                .font(.system(size: 8, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                                .offset(x: 8, y: -7)
                        }
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                        Text(live.busy > 0 ? "\(live.busy) working · \(live.total)"
                                           : "\(live.total)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.sessionsShown.toggle() }
            .popover(isPresented: $model.sessionsShown, arrowEdge: .bottom) {
                MacSessionsPopover(model: model, live: live)
            }
            .instantTip(SessionSummary.tooltip(live), edge: .above)
        }
    }

    /// Detach into a free-floating window (not glued to the menu bar).
    private var popOutIcon: some View {
        Button {
            model.popOut?()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
        }
        .help("Pop out into a window you can move anywhere — click again to close it")
    }

    /// Claude service status — a colored dot; click opens the status page.
    private var serviceDot: some View {
        Button { status.openPage() } label: {
            Circle().fill(status.color).frame(width: 8, height: 8)
        }
        .modifier(StatusHoverCard(status: status))
    }

    private var engineTip: String {
        switch model.cswapState {
        case .running: return "auto-switch running — click to stop"
        case .refused: return "Another auto-switch engine (TUI or cswap auto) holds the mutex."
        case .backingOff(let s): return "engine retrying in \(Int(s))s — click to stop"
        case .schemaMismatch: return "update the app"
        case .stopped: return "auto-switch off — click to start"
        }
    }

    @ViewBuilder private var engineBadgeIcon: some View {
        Button { model.toggleEngine() } label: {
            switch model.cswapState {
            case .running: Image(systemName: "bolt.fill").foregroundStyle(.green)
            case .refused: Image(systemName: "exclamationmark.triangle")
            case .backingOff: Image(systemName: "clock")
            case .schemaMismatch: Image(systemName: "arrow.down.circle")
            case .stopped: Image(systemName: "pause").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .instantTip(engineTip)
    }
}

/// Scales the popup by rendering at 1x, measuring, then applying
/// scaleEffect with a frame sized to the scaled bounds — the only route
/// that works on macOS (Dynamic Type and @ScaledMetric are iOS-only
/// no-ops there, verified live: the size setting did nothing).
private struct PopupScale: ViewModifier {
    let scale: CGFloat
    @State private var measured: CGSize = .zero

    func body(content: Content) -> some View {
        if scale == 1 {
            content
        } else {
            content
                // fixedSize: measure the IDEAL, never the proposal. Without
                // it the outer frame (measured × scale) proposed itself
                // back into flexible content, which grew to fit, got
                // re-measured, and ran away by ×scale per pass — in the
                // pop-out window that reached 2.7e11pt and AppKit aborted.
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { measured = $0 }
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: measured == .zero ? nil : measured.width * scale,
                    height: measured == .zero ? nil : measured.height * scale,
                    alignment: .topLeading)
        }
    }
}

// The fleet row/card rendering (AccountRows/Cells/Grid/Stack, the
// instant-tip canvas and the intro modifiers) moved to InfinitusUI
// (#9 phase B) — generic over FleetModel so the phone app renders
// the very same views.

// ThemeColor moved to InfinitusUI/ThemeColor.swift (#9 phase A) — shared
// with the iOS app.


/// First-run card when no cswap binary exists (todo 2026-08-30):
/// explains the engine, offers a one-click install (uv), never
/// auto-installs. The rest of the popup chrome stays functional.
struct OnboardingCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.cswap != nil {
                // Installed, but every engine is switched off (cswap
                // toggled off, no proxy key) — nothing to install.
                Text("All engines are off")
                    .font(.headline)
                Text("cswap is installed but switched off, and no "
                     + "CLIProxyAPI key is saved. Turn one on to see "
                     + "your accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.openSettings()
                } label: {
                    Label("Engine settings", systemImage: "switch.2")
                }
            } else {
                installCopy
            }
        }
        .padding(6)
    }

    @ViewBuilder private var installCopy: some View {
        Text("Welcome to Infinitus")
            .font(.headline)
        Text("The claude-swap engine isn't installed — it does the "
             + "account switching and usage reading. Infinitus is "
             + "the cockpit; cswap is the engine.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button {
                model.installEngine()
            } label: {
                if model.installingEngine {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                    }
                } else {
                    Label("Install engine", systemImage: "arrow.down.circle")
                }
            }
            .disabled(model.installingEngine)
            Text("or run: uv tool install claude-swap")
                .font(.caption).monospaced()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        if let msg = model.installMessage {
            Text(msg).font(.caption).foregroundStyle(.secondary)
        }
        Text("Then add your first account:  cswap add")
            .font(.caption).monospaced()
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        DetectionLines(model: model, afterInstall: true)
        OnboardingBriefButton(model: model, engineInstalled: false)
    }
}

/// "Copy for an AI agent" (user 2026-09-03): the whole first-run recipe,
/// with what this Mac already has ticked, on the clipboard — paste it
/// into Claude Code and let it do the typing.
struct OnboardingBriefButton: View {
    @ObservedObject var model: AppModel
    let engineInstalled: Bool
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Button(copied ? "Copied" : "Copy for an AI agent") {
                let text = OnboardingBrief.text(engineInstalled: engineInstalled,
                                                claude: model.claudeCLI, proxy: model.cliProxy,
                                                proxyLive: model.cliProxyLive)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            .font(PopupFont.caption)
            Text("paste into Claude Code; it does the steps")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Engine present, fleet empty: adopt whatever this machine already has
/// (todo 2026-09-01). `cswap add` registers Claude Code's current login.
struct FirstAccountCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Almost there")
                .font(.headline)
            Text("The engine is running but manages no accounts yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let claude = model.claudeCLI, let email = claude.email {
                Button {
                    model.addFirstAccount()
                } label: {
                    if model.addingFirstAccount {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Adding…")
                        }
                    } else {
                        Label("Add \(email)", systemImage: "person.badge.plus")
                    }
                }
                .disabled(model.addingFirstAccount)
                if let org = claude.organization {
                    Text("Claude Code on this Mac is signed in as "
                         + "\(email) — \(org).")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Sign in with Claude Code first, then:  cswap add")
                    .font(.caption).monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if let msg = model.firstAccountMessage {
                Text(msg).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DetectionLines(model: model, afterInstall: false)
            OnboardingBriefButton(model: model, engineInstalled: true)
        }
        .padding(6)
    }
}

/// Shared what-else-is-on-this-machine footnotes for both cards.
struct DetectionLines: View {
    @ObservedObject var model: AppModel
    let afterInstall: Bool

    var body: some View {
        Group {
            if afterInstall, let claude = model.claudeCLI,
               let email = claude.email {
                Text("Claude Code is signed in as \(email) — after the "
                     + "install it becomes your first account in one click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let proxy = model.cliProxy {
                Text(Self.proxyLine(proxy, live: model.cliProxyLive))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

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
