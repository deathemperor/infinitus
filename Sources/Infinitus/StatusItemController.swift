import AppKit
import SwiftUI
import Combine
import InfinitusCore
import InfinitusUI

/// The menu bar presence, owned directly as an NSStatusItem instead of a
/// SwiftUI MenuBarExtra scene. Two hard-won reasons (2026-08-29, macOS 26,
/// menu bar completely full):
///   1. A removal-allowed item that stops fitting is EVICTED and persisted
///      as user-removed; `behavior = []` makes the item non-removable, so
///      the bar squeezes it (Clock-style) instead of erasing it.
///   2. MenuBarExtra kept SwiftUI's attribute graph in a 100%-CPU
///      insert/evict retry war whenever the app was alive while the bar
///      refused its item — starving the main actor so completely that no
///      snapshot ever completed. A raw NSStatusItem doesn't fight.
/// StateObject-compatible owner so the App struct (a value type that gets
/// recreated) keeps exactly one controller alive.
/// One settings pane: toolbar label + SF Symbol + content.
struct SettingsTab {
    let title: String
    let symbol: String
    /// Sidebar icon tile color (CodexBar-style settings list).
    var tint: Color = .accentColor
    /// Extra search terms beyond the title.
    var keywords: [String] = []
    /// Providers render under a "Providers" section header with plain
    /// icons (CodexBar sidebar, user screenshot 2026-08-30); nil = a
    /// regular tab with the tinted tile.
    var provider: ProviderBadge? = nil
    /// A real image instead of the SF-symbol tile (About wears the
    /// actual Infinitus icon, user 2026-08-30).
    var image: NSImage? = nil
    let view: AnyView
}

/// Sidebar state for a provider row: dimmed when not set up, a green
/// dot when its engine is live.
struct ProviderBadge {
    var live = false
    /// Rows for engines not built yet — visible roadmap, not selectable.
    var placeholder = false
}

@MainActor
final class StatusItemHolder: ObservableObject {
    let controller: StatusItemController
    init(model: AppModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        controller = StatusItemController(model: model,
                                          settingsTabs: settingsTabs)
        model.showSettings = { [weak controller] in controller?.showSettingsWindow() }
        model.lock.showSettings = { [weak controller] in controller?.showSettingsWindow() }
        model.team.showSettings = { [weak controller] in controller?.showSettingsWindow() }
        // A cold-launch `infinitus://join/…` can call TeamModel.open(url:)
        // before this holder (and its showSettings closure) exists; replay
        // the reveal now that Settings can actually open.
        if model.team.pendingCode != nil { model.team.revealSetting() }
    }
}

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private(set) var settings: NSWindow?
    private lazy var effects = MenuBarEffects(button: item.button)
    private let model: AppModel
    private let settingsTabs: () -> [SettingsTab]
    private var sink: AnyCancellable?

    init(model: AppModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        self.model = model
        self.settingsTabs = settingsTabs
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []                       // not user-removable
        item.button?.title = model.title
        // The Infinitus glyph rides as a template image so the bar can
        // tint it; the title is text-only percentages now (MenuBarGlyph
        // replaced the "⇄" text prefix, user request 2026-08-30).
        item.button?.image = MenuBarGlyph.image
        item.button?.imagePosition = model.title.isEmpty ? .imageOnly : .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Right-click = context menu (todo 2026-08-30). NEVER assign
        // item.menu permanently — that hijacks left-click too; the menu
        // is attached just-in-time inside statusItemClicked instead.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // The title and visibility follow the model; receive AFTER the
        // change lands (objectWillChange fires before mutation).
        sink = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }

        // macOS 26 shows the Settings scene by itself at launch, without
        // making it key; its occlusion state flips as it lands on screen
        // — hide it right there (see hideSceneSettingsWindow).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideSceneSettingsWindow() }
        }
        hideSceneSettingsWindow()
    }

    private func apply() {
        // The theme's color and icon on the item (#90), the template
        // loop under Off or with the toggle off.
        let theme = model.rowTheme
        let themed = model.menuBarThemed && !theme.plain
        var title = model.title
        if themed, !theme.activeIcon.isEmpty {
            title = title.isEmpty ? theme.activeIcon : theme.activeIcon + " " + title
        }
        item.button?.image = themed
            ? MenuBarGlyph.image(tint: NSColor(ThemeColor.flash(theme)), key: theme.flashColor)
            : MenuBarGlyph.image
        item.button?.title = title
        item.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        effects.sync(model: model, enabled: model.menuBarEffects && themed)
        if item.isVisible != model.menuBarIconShown {
            item.isVisible = model.menuBarIconShown
        }
    }

    /// Left click on the status item: the fork desktop app is the client,
    /// so hand the click to it when it is installed; without it the menu
    /// bar's own way in is Settings. Right click still gets the menu.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if !openDesktopApp() { showSettingsWindow() }
    }

    /// The fork desktop app's bundle id; nil when it isn't installed.
    private static let desktopBundleID = "run.infinitus.desktop"
    private var desktopAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.desktopBundleID)
    }
    @discardableResult private func openDesktopApp() -> Bool {
        guard let url = desktopAppURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Right-click menu on the status item (todo 2026-08-30): themes,
    /// the control-center actions, app chrome. Built fresh each time so
    /// checkmarks and toggle titles are current; attached only for the
    /// duration of the click (performClick tracks synchronously).
    private func showContextMenu() {
        let menu = NSMenu()

        // The fork desktop app is the daily client (#654): one entry to
        // reach it, shown only when LaunchServices knows the bundle.
        if desktopAppURL != nil {
            menu.addItem(menuItem("Open Infinitus", #selector(menuOpenDesktop)))
            menu.addItem(.separator())
        }

        let themes = NSMenu()
        for theme in model.availableThemes {
            let row = NSMenuItem(title: theme.name,
                                 action: #selector(pickTheme(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = theme.id
            row.state = model.gamification == theme.id ? .on : .off
            themes.addItem(row)
        }
        let themesItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themesItem.submenu = themes
        menu.addItem(themesItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Rotate to Next Account", #selector(menuRotate)))
        menu.addItem(menuItem("Refresh Usage", #selector(menuRefresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(menuSettings)))
        menu.addItem(menuItem("Restart Infinitus", #selector(menuRestart)))
        menu.addItem(menuItem("Quit Infinitus", #selector(menuQuit)))

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        return row
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.gamification = id
    }
    @objc private func menuRotate() { model.rotate() }
    @objc private func menuRefresh() {
        Task { await model.refreshSnapshot() }
    }
    @objc private func menuOpenDesktop() { openDesktopApp() }
    @objc private func menuSettings() { showSettingsWindow() }
    @objc private func menuRestart() { model.relaunchApp() }
    @objc private func menuQuit() { model.shutdown() }

    /// Controller-owned Settings window. NOT the SwiftUI Settings scene:
    /// `NSApp.sendAction(showSettingsWindow:)` does nothing on macOS 26
    /// (verified live — synthetic click on the button, no window), and the
    /// openSettings environment action doesn't exist outside the scene
    /// graph. Owning the window outright works from any host.
    /// CodexBar-style chrome: searchable icon sidebar + detail pane
    /// (SettingsRoot), replacing the old toolbar-tab NSTabViewController.
    func showSettingsWindow() {
        // Two Settings windows is how the user ended up resizing the
        // wrong one (2026-09-02) — the scene's stays hidden.
        hideSceneSettingsWindow()
        if settings == nil {
            // Tabs built once per window, as before; the gate re-evaluates
            // only which of the two it shows.
            let tabs = settingsTabs()
            let host = NSHostingView(rootView: LockGate(lock: model.lock) {
                SettingsRoot(tabs: tabs)
            })
            // No sizing input from the content: hosting-view constraints
            // pin the window to SwiftUI's ideal size and beat the
            // .resizable style bit — the window refused to grow even via
            // AX (user 2026-09-02). A plain NSWindow with no
            // contentViewController, an explicit content floor, and the
            // frame autosaved: the user owns the size from there.
            host.sizingOptions = []
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            // Blur under the hosting view, outside SwiftUI (see the
            // anchored panel note): the wrapped view is the content view;
            // it retains the hosting view. The scrim keeps sidebar text
            // readable over white apps.
            w.contentView = GlassContainerView.wrap(host, scrim: true)
            w.contentMinSize = NSSize(width: 700, height: 480)
            // System Settings is not freely widenable, and for the same
            // reason: a grouped Form self-limits to ~700pt, so every
            // extra pixel of window became empty grey (design critique
            // 2026-09-06, P1 — a 700pt column in an 1800pt window).
            w.contentMaxSize = NSSize(width: 1200, height: CGFloat.greatestFiniteMagnitude)
            w.title = "Settings"
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            // Float only while KEY: opened from the floating pop-out it
            // must land in front of it, but a backgrounded Settings window
            // has no business sitting over other apps (the "always on
            // top" bug, 2026-08-30). The level follows key status.
            w.level = .floating
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsKeyChanged),
                name: NSWindow.didBecomeKeyNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsKeyChanged),
                name: NSWindow.didResignKeyNotification, object: w)
            w.center()
            w.setFrameAutosaveName("InfinitusSettings")
            // An autosaved frame from before the cap is restored as-is.
            if w.frame.width > 1200 {
                w.setContentSize(NSSize(width: 1200, height: w.contentLayoutRect.height))
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsClosed),
                name: NSWindow.willCloseNotification, object: w)
            settings = w
        }
        // An accessory app has no Cmd+Tab entry, so an open Settings
        // window was unreachable once buried (user bug 2026-08-30).
        // Become a regular app while it's open — Dock icon and Cmd+Tab
        // appear — and drop back to accessory when it closes.
        model.lock.surfaceShown()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    /// The window is kept (`isReleasedWhenClosed = false`), so the next
    /// `show settings` reopens it with its tabs built.
    func hideSettingsWindow() { settings?.orderOut(nil) }

    /// The SwiftUI Settings scene's window: macOS 26 shows it by itself
    /// at launch, and SwiftUI keeps it non-resizable — it re-strips the
    /// .resizable bit and resets contentMinSize on every update (probed
    /// 2026-09-02), so it can't be adopted. It goes away; the
    /// controller-owned window below is the one Settings window.
    private func hideSceneSettingsWindow() {
        for w in NSApp.windows where w.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            && w.isVisible {
            w.orderOut(nil)
        }
    }

    @objc private func settingsClosed() {
        model.lock.surfaceHidden()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func settingsKeyChanged() {
        guard let w = settings else { return }
        if w.isKeyWindow { model.lock.surfaceShown() }
        w.level = w.isKeyWindow ? .floating : .normal
    }
}
