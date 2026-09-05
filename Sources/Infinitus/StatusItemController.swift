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
    init(model: AppModel, usage: UsageModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        controller = StatusItemController(model: model, usage: usage,
                                          settingsTabs: settingsTabs)
        model.showSettings = { [weak controller] in controller?.showSettingsWindow() }
        model.reopenPopover = { [weak controller] in controller?.reopenPopover() }
        model.popOut = { [weak controller] in controller?.popOut() }
        model.showWall = { [weak controller] in controller?.toggleWall() }
    }
}

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    /// The anchored popup is a borderless non-activating panel, NOT an
    /// NSPopover: popover windows refuse CABackdropLayer sampling at any
    /// level (probed 2026-08-30 — the layer renders a black slab), and
    /// the real tunable-blur glass is the whole point. A plain panel
    /// also ends the popover-frame paint fights and the fitting-size
    /// heal dance for good.
    private var anchored: NSPanel?
    /// Kept so the hosting controller outlives contentView-based setup
    /// (no contentViewController retains it any more).
    private var anchoredHost: NSViewController?
    private var anchoredIdeal: CGSize = .zero
    private var dismissMonitors: [Any] = []
    private var pinned: NSWindow?
    /// Last content size PinnedRoot reported — it fires during
    /// NSWindow(contentViewController:) itself, before `pinned` is set.
    private var pinnedIdeal: CGSize = .zero
    private var settings: NSWindow?
    private lazy var desktopCapture = DesktopCaptureController(model: model)
    private lazy var effects = MenuBarEffects(button: item.button)
    private let model: AppModel
    private let usage: UsageModel
    private let wall = WallWindowController()
    private let settingsTabs: () -> [SettingsTab]
    private var sink: AnyCancellable?

    init(model: AppModel, usage: UsageModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        self.model = model
        self.usage = usage
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
        item.button?.action = #selector(togglePopover)
        // Right-click = context menu (todo 2026-08-30). NEVER assign
        // item.menu permanently — that hijacks left-click too; the menu
        // is attached just-in-time inside togglePopover instead.
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

        // A pinned popup is a fixture, not a transient — bring it back on
        // launch (user report 2026-08-30: pinned, app restarted, gone).
        // Same for the pop-out window, at its saved position (user
        // 2026-08-30: "popout state is not saved"). Delayed so the status
        // item has landed in the bar (a popover anchored to an unplaced
        // button shows at the screen corner); no NSApp.activate —
        // restoring at login must not steal focus.
        let popOutRestore = UserDefaults.standard.bool(forKey: "popout_shown")
        if model.popoverPinned || popOutRestore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.anchored?.isVisible != true,
                      self.pinned?.isVisible != true else { return }
                if popOutRestore {
                    self.showPinnedWindow(activate: false)
                } else if let button = self.item.button, button.window != nil {
                    self.showAnchored()
                }
            }
        }
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
        // Pinned = survives click-outside; the status item still toggles
        // it closed, so a pinned popup can never strand.
        updateDismissMonitors()
        pinnedKeyChanged()
    }

    private func showAnchored() {
        if wall.isVisible { wall.dismissForPopup() }
        if anchored == nil {
            let host = NSHostingController(rootView: AnchoredRoot(
                model: model, usage: usage,
                onSize: { [weak self] size in self?.fitAnchored(to: size) })
                .glassChrome(model: model))
            // Same crash-avoidance as the pop-out: never let the hosting
            // view drive the window frame (unbounded ideal width).
            host.sizingOptions = []
            let panel = NSPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            // The blur view lives OUTSIDE the SwiftUI hosting tree:
            // hosting flattens its subtree into offscreen groups, which
            // silently breaks CABackdropLayer capture (user 2026-08-30:
            // "no blur, just alpha") — the same layer blurs fine as a
            // plain sibling under the hosting view.
            panel.contentView = GlassContainerView.wrap(host.view, scrim: true,
                scrimStrength: GlassScrimView.strength(forClarity: model.glassFocused))
            anchoredHost = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            // Floating: over normal windows, under the system's own menu
            // bar popovers (Wi-Fi, battery — the old popover blocked them).
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            anchored = panel
        }
        fitAnchored(to: anchoredIdeal)
        positionAnchored()
        anchored?.orderFrontRegardless()
        updateDismissMonitors()
        model.introOpened()
    }

    private func closeAnchored() {
        anchored?.orderOut(nil)
        updateDismissMonitors()
    }

    /// Track the content's measured ideal size, popover-measure style.
    /// SwiftUI streams sizes through onGeometryChange DURING animated
    /// layout changes, so applying the full anchored frame here (size
    /// AND position in one setFrame) makes the panel ride the content's
    /// animation frame-by-frame — setContentSize + a separate reposition
    /// let the panel lurch a frame ahead of the content (container-jump
    /// bug, user screenshot 2026-08-30).
    private func fitAnchored(to size: CGSize) {
        anchoredIdeal = size
        guard let panel = anchored, size.width > 1, size.height > 1,
              size.width < 20_000, size.height < 20_000 else { return }
        guard let frame = anchoredFrame(for: size) else { return }
        guard frame != panel.frame else { return }
        // onGeometryChange reports the END size once, not per animation
        // frame — applying it instantly snapped the panel ahead of the
        // still-easing content (intermittent container jump, user
        // screenshots ×2). Glide the panel over the same ~0.3s the
        // SwiftUI width changes use; retargeting mid-glide is fine.
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Hang the panel from the status item like the popover did: top edge
    /// under the menu bar, centered on the button, clamped to the screen.
    private func anchoredFrame(for content: CGSize) -> NSRect? {
        guard let panel = anchored, let button = item.button,
              let bw = button.window,
              let screen = bw.screen ?? NSScreen.main else { return nil }
        let rect = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: content)).size
        var x = rect.midX - size.width / 2
        x = min(x, screen.visibleFrame.maxX - size.width - 8)
        x = max(x, screen.visibleFrame.minX + 8)
        var height = size.height
        let maxHeight = min(screen.visibleFrame.height - 20,
                            max(200, rect.minY - screen.visibleFrame.minY - 14))
        if height > maxHeight {
            height = maxHeight
        }
        var y = rect.minY - height - 6
        // A layout flip can also grow the panel past the bottom edge —
        // ride up rather than hang off the screen.
        y = max(y, screen.visibleFrame.minY + 8)
        return NSRect(x: x, y: y,
                      width: size.width, height: height)
    }

    private func positionAnchored() {
        guard let panel = anchored else { return }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        if let frame = anchoredFrame(for: content) {
            panel.setFrame(frame, display: true)
        }
    }

    /// Transient behavior by hand: click anywhere outside closes the
    /// panel, unless pinned. Monitors exist only while visible+unpinned.
    private func updateDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
        guard let panel = anchored, panel.isVisible,
              !model.popoverPinned else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.closeAnchored() }) {
            dismissMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                if let self, event.window !== self.anchored {
                    self.closeAnchored()
                }
                return event
            }) {
            dismissMonitors.append(l)
        }
    }

    /// The pop-out action: close the popover, open the floating window.
    /// Toggles — with the traffic lights hidden, the same button is how
    /// the window goes away again (Cmd+W works too).
    func popOut() {
        if let pinned, pinned.isVisible {
            pinned.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "popout_shown")
            // Popping back IN: the content returns to its anchor spot —
            // just hiding the window left nothing on screen (user bug
            // report 2026-08-30).
            showAnchored()
            return
        }
        if anchored?.isVisible == true { closeAnchored() }
        showPinnedWindow()
    }

    /// The popover needed a close/reopen bounce to re-measure a
    /// wholesale content-shape change; the panel follows the content's
    /// reported size live, so a re-fit is the whole job. No-op closed.
    func reopenPopover() {
        guard anchored?.isVisible == true else { return }
        fitAnchored(to: anchoredIdeal)
        positionAnchored()
    }

    @objc private func togglePopover() {
        // Right-click gets the context menu; every action it carries is
        // reachable even when the popup footer's controls are hidden
        // (the footer-hide setting leans on this menu existing).
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        // A visible pop-out owns the content: the menu bar item focuses it
        // instead of opening a second copy as a popover (user request).
        if let pinned, pinned.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            pinned.makeKeyAndOrderFront(nil)
            return
        }
        if anchored?.isVisible == true {
            closeAnchored()
        } else {
            // Non-activating: opening the popup never yanks focus from
            // whatever the user is working in.
            showAnchored()
        }
    }

    /// Right-click menu on the status item (todo 2026-08-30): themes,
    /// the control-center actions, app chrome. Built fresh each time so
    /// checkmarks and toggle titles are current; attached only for the
    /// duration of the click (performClick tracks synchronously).
    private func showContextMenu() {
        let menu = NSMenu()

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
        menu.addItem(menuItem("Capture Screen for a Session…", #selector(menuCapture)))
        menu.addItem(.separator())
        let pin = menuItem("Pin Popup Open", #selector(menuPin))
        pin.state = model.popoverPinned ? .on : .off
        menu.addItem(pin)
        menu.addItem(menuItem(pinned?.isVisible == true
                              ? "Pop Back Into Menu Bar" : "Pop Out Into a Window",
                              #selector(menuPopOut)))
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
    @objc private func menuCapture() { desktopCapture.capture() }
    @objc private func menuPin() { model.popoverPinned.toggle() }
    @objc private func menuPopOut() { popOut() }
    @objc private func menuSettings() { showSettingsWindow() }
    @objc private func menuRestart() { model.relaunchApp() }
    @objc private func menuQuit() { model.shutdown() }

    /// Same content in a real window. No popup button opens this any more
    /// (Pin now holds the popover itself); it remains the guaranteed way in
    /// via `open Infinitus.app` -> applicationShouldHandleReopen when the
    /// status item is hidden or the bar refuses it.
    func showPinnedWindow(activate: Bool = true) {
        if wall.isVisible { wall.dismissForPopup() }
        if pinned == nil {
            let host = NSHostingController(rootView: PinnedRoot(
                model: model, usage: usage,
                onSize: { [weak self] size in self?.fitPinned(to: size) })
                .glassChrome(model: model))
            // NO hosting-driven window sizing: with .standardBounds or
            // .preferredContentSize, NSHostingView.updateAnimatedWindowSize
            // pushed the content's unbounded ideal width (2.4e196) into
            // setFrame and AppKit threw NSInternalInconsistencyException —
            // the app died on every pop-out (crash reports 22:33–23:08).
            // PinnedRoot measures its own fixedSize() geometry and reports
            // it through onSize; that number is the popover's exact width.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            // Blur under the hosting view, outside SwiftUI (see the
            // anchored panel note): swap the content view for a wrapped
            // one; the controller stays retained by the window.
            w.contentView = GlassContainerView.wrap(host.view, scrim: true,
                scrimStrength: GlassScrimView.strength(forClarity: model.glassFocused))
            w.title = "Infinitus"
            // Full-size content + hidden system title: the centered
            // "Infinitus" header is drawn by PinnedRoot instead (the
            // system title sits leading-aligned next to where the traffic
            // lights were; user wants it centered).
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // No traffic lights at all (user request): the pop-out button
            // toggles the window away, and Cmd+W still closes (.closable
            // stays in the mask for exactly that).
            for button in [NSWindow.ButtonType.closeButton,
                           .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(button)?.isHidden = true
            }
            // Float while KEY or while the pin is on — an unpinned,
            // backgrounded pop-out has no business sitting over other
            // apps (user 2026-08-31: "not pinned but still stays on top
            // always"; same treatment as Settings). Pinning it restores
            // the stay-visible-while-working-elsewhere HUD behavior.
            w.level = .floating
            NotificationCenter.default.addObserver(
                self, selector: #selector(pinnedKeyChanged),
                name: NSWindow.didBecomeKeyNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(pinnedKeyChanged),
                name: NSWindow.didResignKeyNotification, object: w)
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // Let the GlassBackground's behind-window material actually
            // see behind the window.
            w.isOpaque = false
            w.backgroundColor = .clear
            // Position is a fixture too: follow moves into defaults,
            // restore below; Cmd+W drops the restore-on-launch flag.
            NotificationCenter.default.addObserver(
                self, selector: #selector(pinnedMoved),
                name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(pinnedClosed),
                name: NSWindow.willCloseNotification, object: w)
            pinned = w
            fitPinned(to: pinnedIdeal)
            let d = UserDefaults.standard
            if let x = d.object(forKey: "popout_x") as? Double,
               let y = d.object(forKey: "popout_y") as? Double {
                w.setFrameOrigin(NSPoint(x: x, y: y))
                clampOnScreen(w)
            }
        }
        UserDefaults.standard.set(true, forKey: "popout_shown")
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            pinned?.makeKeyAndOrderFront(nil)
        } else {
            pinned?.orderFrontRegardless()
        }
        pinnedKeyChanged()
    }

    /// The pop-out's level follows key status and the pin, so a pin
    /// toggle retargets it live (apply() calls this on model changes).
    @objc private func pinnedKeyChanged() {
        guard let w = pinned else { return }
        w.level = model.popoverPinned || w.isKeyWindow ? .floating : .normal
    }

    @objc private func pinnedMoved() {
        guard let pinned, pinned.isVisible else { return }
        let d = UserDefaults.standard
        d.set(Double(pinned.frame.origin.x), forKey: "popout_x")
        d.set(Double(pinned.frame.origin.y), forKey: "popout_y")
    }

    @objc private func pinnedClosed() {
        // App-quit closes the window too; only a USER close drops the flag.
        guard !AppDelegate.terminating else { return }
        UserDefaults.standard.set(false, forKey: "popout_shown")
    }

    /// Nudge a window fully back into its screen's visible frame — a
    /// stacked->wide flip can grow it off the edge (user 2026-08-30:
    /// "auto move it in any part of container that overflow").
    private func clampOnScreen(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = w.frame
        if f.height > v.height - 20 { f.size.height = v.height - 20 }
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.minY < v.minY { f.origin.y = v.minY }
        if f != w.frame { w.setFrame(f, display: true) }
    }

    /// Track the content's measured ideal size (layout, theme, compact,
    /// popup-size changes) — the popover's re-measure, done by hand.
    private func fitPinned(to size: CGSize) {
        pinnedIdeal = size
        guard let pinned, !fittingPinned, size.width > 1, size.height > 1,
              size.width < 20_000, size.height < 20_000 else { return }
        // Whole points only: AppKit floors a fractional content size to
        // the pixel grid, so a 633.6-pt ideal made a 633-pt window that
        // never matched within 0.5 — setContentSize lays the content out
        // synchronously, the geometry callback fired again, and the app
        // froze at 94% main-thread CPU (bundle 6b587b2, 2026-09-04).
        let want = NSSize(width: ceil(size.width), height: ceil(size.height))
        let current = pinned.contentRect(forFrameRect: pinned.frame).size
        guard abs(current.width - want.width) > 0.5 || abs(current.height - want.height) > 0.5 else { return }
        // The geometry callback comes back through SwiftUI's next update,
        // not inside setContentSize, so a re-entrancy flag can't stop a
        // loop: fitPinned → setContentSize → re-measure → fitPinned, ~450
        // times a second with the main thread never idle (bundle b82d3d9
        // froze after 1h30 with the rounding fix in, 2026-09-04). Two
        // ways it loops, two guards: a size AppKit didn't take (a screen
        // clamp) is never asked for again while it's refused; a size
        // asked for again within a second means the content measures
        // differently in each of two window sizes — settle on the larger,
        // which clips nothing, and stop.
        if let refusedFit, abs(refusedFit.width - want.width) < 0.5,
           abs(refusedFit.height - want.height) < 0.5 { return }
        let now = Date()
        recentFits.removeAll { now.timeIntervalSince($0.at) > 1 }
        var target = want
        if let screen = pinned.screen ?? NSScreen.main {
            let maxH = screen.visibleFrame.height - 40
            if target.height > maxH {
                target.height = maxH
            }
        }
        if recentFits.contains(where: { $0.size == want }) {
            target = NSSize(width: max(want.width, current.width), height: max(want.height, current.height))
            if abs(target.width - current.width) < 0.5, abs(target.height - current.height) < 0.5 { return }
            NSLog("Infinitus pop-out: fit loop — content asks %.0f×%.0f in a %.0f×%.0f window; settling on %.0f×%.0f",
                  want.width, want.height, current.width, current.height, target.width, target.height)
        }
        recentFits.append((target, now))
        fittingPinned = true
        defer { fittingPinned = false }
        pinned.setContentSize(target)
        clampOnScreen(pinned)
        let got = pinned.contentRect(forFrameRect: pinned.frame).size
        if abs(got.width - want.width) > 0.5 || abs(got.height - want.height) > 0.5 {
            refusedFit = want
            NSLog("Infinitus pop-out: asked for %.0f×%.0f, the window took %.0f×%.0f — not asking again",
                  want.width, want.height, got.width, got.height)
        } else {
            refusedFit = nil
        }
    }
    /// Re-entrancy guard: setContentSize lays out synchronously, and the
    /// content's geometry callback can land inside that call.
    private var fittingPinned = false
    private var recentFits: [(size: NSSize, at: Date)] = []
    private var refusedFit: NSSize?

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
            let host = NSHostingView(rootView: SettingsRoot(tabs: settingsTabs()))
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
            w.title = "Infinitus"
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
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsClosed),
                name: NSWindow.willCloseNotification, object: w)
            settings = w
        }
        // An accessory app has no Cmd+Tab entry, so an open Settings
        // window was unreachable once buried (user bug 2026-08-30).
        // Become a regular app while it's open — Dock icon and Cmd+Tab
        // appear — and drop back to accessory when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    /// Wall is a MODE (user 2026-09-01): entering it closes the popup
    /// and pop-out; leaving restores the pop-out if it was up.
    func toggleWall() {
        if wall.isVisible { wall.close(); return }
        let hadPinned = pinned?.isVisible == true
        if anchored?.isVisible == true { closeAnchored() }
        if hadPinned { pinned?.orderOut(nil) }
        wall.restore = { [weak self] in
            if hadPinned { self?.showPinnedWindow() }
        }
        wall.show(model: model, usage: usage)
    }

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
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func settingsKeyChanged() {
        guard let w = settings else { return }
        w.level = w.isKeyWindow ? .floating : .normal
    }
}

/// The anchored panel's content: the shared popup body, self-measuring
/// so the panel follows the content's ideal size (PinnedRoot's trick).
private struct AnchoredRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    let onSize: (CGSize) -> Void

    var body: some View {
        MenuContent(model: model, usage: usage)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .reloadOnInjection()
    }
}

/// The pop-out window's content: the shared popup body under a centered
/// title header (which doubles as the drag strip where the titlebar was).
private struct PinnedRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            InfinitusHeader(model: model)
                .frame(height: 30)
            MenuContent(model: model, usage: usage, showHeader: false)
        }
        // fixedSize = the content's ideal, independent of the window; the
        // window then follows THAT (fitPinned) instead of the other way
        // round, so wide rows never compress into wrapped lines.
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // fullSizeContentView hands the hosting view a titlebar-high top
        // safe-area inset, which rendered as a dead strip above the header
        // (user screenshot 2026-08-30); the header IS the titlebar here.
        .ignoresSafeArea(.container, edges: .top)
        .reloadOnInjection()
    }
}
