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
    static let minimumSize = NSSize(width: 960, height: 600)
    /// T3's Electron traffic-light inset (`--workspace-controls-left` 12,
    /// `titlebar-area-height` 52).
    static let controlsLeft: CGFloat = 12
    static let titleBandHeight: CGFloat = 52

    func show(model: AppModel, screen: String?) {
        let wm = windowModel ?? T3WindowModel(model: model)
        windowModel = wm
        wm.focusedScreen = screen
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = LockGate(lock: model.lock) { T3Root(model: wm, app: model) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []            // never let the hosting view size the window
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.referenceSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentMinSize = Self.minimumSize
            w.setFrameAutosaveName("Workspace")
            w.center()
            w.delegate = self
            return w
        }()
        let frame = w.frame
        w.contentViewController = host
        if frame.width < Self.minimumSize.width { w.setContentSize(Self.referenceSize); w.center() } else { w.setFrame(frame, display: true) }
        w.title = "Infinitus"
        window = w
        placeTrafficLights(w)
        wm.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.uiSurface("workspace", visible: true)
        visibilityChanged?()
    }

    func close() { window?.performClose(nil) }

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
    func windowWillClose(_ notification: Notification) {
        minuteTick?.invalidate(); minuteTick = nil
        window?.contentViewController = nil            // detach: nothing ticks while hidden
        windowModel?.stop()
        windowModel?.model?.uiSurface("workspace", visible: false)
        windowModel?.model?.lock.surfaceHidden()
        visibilityChanged?()
    }
}
