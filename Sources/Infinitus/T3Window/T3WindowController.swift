import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The workspace window (spec §4.1) — a full-window desktop shell over
/// Infinitus's sessions. One window, reused (WallWindow's lesson); the
/// content is detached on close so nothing ticks while it is hidden.
@MainActor
final class T3WindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var windowModel: T3WindowModel?
    private var minuteTick: Timer?
    var visibilityChanged: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    static let referenceSize = NSSize(width: 1800, height: 1050)
    /// Upstream's window minimum (`DesktopWindow.ts:366-367`), not the plan's
    /// superseded 960×600.
    static let minimumSize = NSSize(width: 840, height: 620)
    /// T3's Electron traffic-light inset (`--workspace-controls-left` 12,
    /// `titlebar-area-height` 52).
    static let controlsLeft: CGFloat = 12
    static let titleBandHeight: CGFloat = 52

    func show(model: AppModel, screen: String?) {
        let wm = windowModel ?? T3WindowModel(model: model)
        windowModel = wm
        wm.closeRequested = { [weak self] in self?.close() }
        wm.focusedScreen = screen
        if let w = window, w.isVisible {
            wm.applyPendingScreen()   // no fresh refresh() on the raise path — push it now
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = LockGate(lock: model.lock) { T3Root(model: wm, app: model) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []            // never let the hosting view size the window
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.clampedInitialSize()),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentMinSize = Self.minimumSize
            w.center()                     // before the autosave name so a restored frame wins
            w.setFrameAutosaveName("Workspace")
            clampOnScreen(w)
            w.delegate = self
            return w
        }()
        let frame = w.frame
        w.contentViewController = host
        if frame.width < Self.minimumSize.width {
            w.setContentSize(Self.clampedInitialSize())
            w.center()
            clampOnScreen(w)
        } else {
            w.setFrame(frame, display: true)
        }
        w.title = "Infinitus"
        window = w
        placeTrafficLights(w)
        wm.start()
        wm.applyPendingScreen()   // double-apply with refresh()'s own is harmless — the request is one-shot
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.uiSurface("workspace", visible: true)
        visibilityChanged?()
    }

    /// Idempotent: a no-op once the window is already hidden.
    func close() {
        guard window?.isVisible == true else { return }
        window?.performClose(nil)
    }

    /// The first-open size, never larger than the screen minus a margin, and
    /// never below `minimumSize` (a 1800×1050 reference size lands the traffic
    /// lights off-screen on a 1440-pt display, and an accessory app with no
    /// menu bar then has no way to close the window).
    private static func clampedInitialSize() -> NSSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? referenceSize
        let margin: CGFloat = 40
        return NSSize(width: min(referenceSize.width, max(minimumSize.width, visible.width - margin)),
                      height: min(referenceSize.height, max(minimumSize.height, visible.height - margin)))
    }

    /// Nudge the window fully back into its screen's visible frame (the
    /// StatusItemController.clampOnScreen pattern) — a restored autosaved
    /// frame can land off-screen after a display change.
    private func clampOnScreen(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = w.frame
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.minY < v.minY { f.origin.y = v.minY }
        if f != w.frame { w.setFrame(f, display: true) }
    }

    /// Electron puts the three buttons at x 12, centred in a 52 pt band.
    private func placeTrafficLights(_ w: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var x = Self.controlsLeft
        for type in buttons {
            guard let b = w.standardWindowButton(type), let bar = b.superview else { continue }
            let y = bar.bounds.height - (Self.titleBandHeight + b.frame.height) / 2
            b.setFrameOrigin(NSPoint(x: x, y: y))
            x += b.frame.width + 6   // Electron's 6 pt gap between lights
        }
    }

    func windowDidResize(_ notification: Notification) { if let w = window { placeTrafficLights(w) } }
    func windowDidBecomeKey(_ notification: Notification) {
        minuteTick?.invalidate()
        minuteTick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.windowModel?.tick() }
        }
        windowModel?.tick()
        windowModel?.model?.lock.surfaceShown()
    }
    func windowDidResignKey(_ notification: Notification) { minuteTick?.invalidate(); minuteTick = nil }
    // No `visibilityChanged?()` here (E1): `window.isVisible` is still true
    // during this notification, so syncLocalLease's re-check would re-add
    // "workspace" to the visible surfaces right after tearDown()'s explicit
    // uiSurface(false) removed it — the lease would never release.
    func windowWillClose(_ notification: Notification) { tearDown() }

    private func tearDown() {
        minuteTick?.invalidate(); minuteTick = nil
        window?.contentViewController = nil            // detach: nothing ticks while hidden
        windowModel?.stop()
        windowModel?.model?.uiSurface("workspace", visible: false)
        windowModel?.model?.lock.surfaceHidden()
    }
}
