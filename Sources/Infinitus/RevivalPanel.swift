import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The all-dead revival countdown's macOS equivalent (issue #1): a small
/// floating always-on-top panel — reviver + countdown + sessions waiting
/// — that appears when every account is limited and leaves when the
/// fleet is back. Click opens the popup; ✕ hides it for this episode
/// (a different reviver or a fresh all-dead brings it back).
@MainActor
final class RevivalPanelController {
    /// One panel reused across episodes: a closed borderless window
    /// lingers in AppKit's list anyway (WallWindow, 2026-09-03).
    private var panel: NSPanel?
    /// `number|at` of the recovery the user dismissed.
    private var dismissed: String?
    private var shownFor: String?

    var isVisible: Bool { panel?.isVisible == true }

    /// Called from the snapshot hook on every fleet poll and when the
    /// Display toggle flips.
    func sync(model: AppModel) {
        guard model.revivalPanelShown, let fleet = model.primary?.lastFleet,
              let rec = fleet.nextRecovery,
              let state = LiveActivityBuilder.revival(fleet: fleet, theme: model.rowTheme, textGlyphs: false)
        else { hide(); return }
        let key = "\(rec.number)|\(rec.at)"
        if dismissed == key { hide(); return }
        if dismissed != nil { dismissed = nil }
        show(state: state, key: key, model: model)
    }

    private func show(state: RevivalActivityState, key: String, model: AppModel) {
        let root = RevivalRoot(state: state,
                               open: { [weak model] in model?.reopenPopover?() },
                               dismiss: { [weak self] in self?.dismissed = key; self?.hide() })
        let host = NSHostingController(rootView: root)
        // Never let the hosting view size the window (the pop-out's
        // unbounded-ideal-width crash): measure the fixedSize root once
        // per sync and set the frame ourselves. `fittingSize` is zero
        // for a hosting view with no sizing options; ask the controller.
        host.sizingOptions = []
        let size = host.sizeThatFits(in: NSSize(width: 2000, height: 2000))
        guard size.width > 1, size.height > 1 else { return }
        let p = panel ?? Self.makePanel()
        let wasVisible = p.isVisible
        p.contentViewController = host
        if !wasVisible, !p.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: v.maxX - size.width - 24, y: v.minY + 24))
        }
        p.setContentSize(size)
        panel = p
        shownFor = key
        if !wasVisible { p.orderFrontRegardless() }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.saveFrame(usingName: Self.autosaveName)
        // Detach the content, not just orderOut(): an ordered-out
        // hosting view keeps its TimelineView ticking (WallWindow).
        panel.contentViewController = nil
        panel.orderOut(nil)
        shownFor = nil
    }

    private static let autosaveName = "RevivalPanel"

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.title = "Revival countdown"
        return p
    }
}

/// Panel content: one 1 Hz TimelineView for the countdown (the popup's
/// AllDeadBanner ticks the same way) — never a numericText transition.
struct RevivalRoot: View {
    let state: RevivalActivityState
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(ThemeColor.resolve(state.accent))
                    Text("All accounts \(state.deadWord)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide until the next revival")
                }
                Text(RecoveryCountdown.label(until: state.revivesAt, now: ctx.date))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 150, alignment: .leading)
                // The theme's revive word is a PREFIX ("🧪 loc" / "re-release loc").
                Text("\(state.reviveWord.trimmingCharacters(in: .whitespaces)) "
                     + "\(state.icon.map { $0 + " " } ?? "")\(state.reviver)" + waitingSuffix)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(perform: open)
        }
    }

    private var waitingSuffix: String {
        guard state.waiting > 0 else { return "" }
        return " · \(state.waiting) waiting"
    }
}
