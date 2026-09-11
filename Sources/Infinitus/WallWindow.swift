import SwiftUI
import AppKit
import InfinitusCore

/// Full-screen fleet wall (issue #11): the popup body blown up to fill a
/// whole display — for the spare screen that exists "just to look at".
/// A borderless screen-sized window (kiosk style, not the fullScreen
/// space: no menu bar reveal, no Space shuffle), content scaled to fit
/// by the PopupScale trick — measure the 1x ideal, scaleEffect to the
/// screen. Esc or a click on the corner ✕ closes it.
@MainActor
final class WallWindowController {
    /// Kept across visits: a closed borderless NSWindow lingers in
    /// AppKit's list anyway (probed 2026-09-03, content or no content),
    /// so one window is reused rather than one leaked per visit.
    private var window: NSWindow?
    private var keyMonitor: Any?
    /// Wall-mode restore hook (user 2026-09-01: "fleet wall is a mode" —
    /// popup/pop-out close when it opens): set by the controller before
    /// show, invoked on close to bring back what the wall displaced.
    var restore: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    func toggle(model: AppModel, usage: UsageModel) {
        if isVisible { close() } else { show(model: model, usage: usage) }
    }

    /// Close without restoring — the popup is opening on its own.
    func dismissForPopup() {
        restore = nil
        close()
    }

    /// The user's pick from Display settings, else the first screen that
    /// isn't the main one (the "spare screen" default), else the main.
    static func targetScreen() -> NSScreen? {
        let wanted = UserDefaults.standard.string(forKey: "wall_display")
        if let wanted,
           let hit = NSScreen.screens.first(where: { $0.localizedName == wanted }) {
            return hit
        }
        return NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.main
    }

    func show(model: AppModel, usage: UsageModel) {
        guard !isVisible, let screen = Self.targetScreen() else { return }
        // Same gate as the pop-out and Settings (#55): a locked app's wall
        // shows the lock, not the sessions.
        let root = LockGate(lock: model.lock) {
            WallRoot(model: model, usage: usage, stats: model.statsModel,
                     close: { [weak self] in self?.close() })
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let w = window ?? NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false, screen: screen)
        w.contentViewController = host
        w.setFrame(screen.frame, display: true)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .normal
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.isReleasedWhenClosed = false
        window = w
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {   // Esc
                self?.close()
                return nil
            }
            return event
        }
        w.makeKeyAndOrderFront(nil)
        visibilityChanged?()
    }

    /// Runs after every show and close (the wall is a lease-holding
    /// surface like the popup, #223 phase 5).
    var visibilityChanged: (() -> Void)?

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // Detach the content, not just orderOut(): an ordered-out
        // hosting view kept the wall's 15 fps sparks TimelineView ticking
        // after every visit (~8% idle, caught by tools/e2e.sh 2026-09-03).
        window?.contentViewController = nil
        window?.orderOut(nil)
        restore?()
        restore = nil
        visibilityChanged?()
    }
}

/// The wall content: title, the shared popup body, scaled to fill the
/// screen with margins. Same measure-then-scale trick as PopupScale —
/// fixedSize gives the honest 1x ideal, scaleEffect grows the pixels.
private struct WallRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var stats: StatsModel
    let close: () -> Void
    @State private var ideal: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                WallLayout(model: model, stats: stats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(18)
                .help("Close (Esc)")
            }
        }
        .preferredColorScheme(.dark)
        .reloadOnInjection()
    }

    private func scale(in room: CGSize) -> CGFloat {
        guard ideal.width > 0, ideal.height > 0 else { return 1 }
        return min((room.width * 0.92) / ideal.width,
                   (room.height * 0.88) / ideal.height)
    }
}

/// Display-pane rows: pick the wall's screen, enter it.
struct WallSection: View {
    @ObservedObject var model: AppModel
    @State private var choice = UserDefaults.standard.string(forKey: "wall_display")
        ?? ""

    var body: some View {
        Section {
            Picker("Screen", selection: $choice) {
                Text("Spare screen (auto)").tag("")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .onChange(of: choice) { _, v in
                if v.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "wall_display")
                } else {
                    UserDefaults.standard.set(v, forKey: "wall_display")
                }
            }
            Button("Enter Full-Screen Fleet Wall") { model.showWall?() }
        } header: {
            Text("Fleet wall")
        } footer: {
            Text("The popup, screen-sized, for the display that's just "
                 + "there to look at. Esc leaves it.")
        }
    }
}
