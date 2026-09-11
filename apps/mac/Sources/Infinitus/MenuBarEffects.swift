import AppKit
import InfinitusCore
import InfinitusUI
import QuartzCore
import SwiftUI

/// The status item's effects (#90): a glow flash on the button when an
/// account switches (the theme's flash color), dies (red) or revives
/// (green), and an ember pulse while the active account burns ahead of
/// pace. Core Animation on a sublayer of the button's layer — nothing
/// runs in-process per frame (CLAUDE.md: idle CPU stays near 0%).
@MainActor
final class MenuBarEffects {
    private weak var button: NSStatusBarButton?
    private var glow: CALayer?
    private var burning = false
    private var switchTick = 0
    private var deaths = 0
    private var revives = 0

    init(button: NSStatusBarButton?) {
        self.button = button
        button?.wantsLayer = true
    }

    /// Called after every model change: fires what changed since last
    /// time; `enabled` false tears everything down and only records.
    func sync(model: AppModel, enabled: Bool) {
        let switches = model.switchFlashTick
        let deathsNow = model.deathTicks.values.reduce(0, +)
        let revivesNow = model.reviveTicks.values.reduce(0, +)
        defer { switchTick = switches; deaths = deathsNow; revives = revivesNow }
        guard enabled else {
            glow?.removeFromSuperlayer()
            glow = nil
            burning = false
            return
        }
        let theme = model.rowTheme
        let tint = NSColor(ThemeColor.flash(theme))
        if switches != switchTick, switchTick != 0 || switches > 0 { flash(tint) }
        if deathsNow > deaths, deaths >= 0, deathsNow > 0 { flash(.systemRed) }
        if revivesNow > revives { flash(.systemGreen) }
        let heat = model.accounts.first(where: \.active).flatMap { account -> Double? in
            guard let w = account.usage?.sevenDay else { return nil }
            return GaugeMath.burnHeat(usedPct: w.pct, expectedPct: w.expectedPct, ahead: w.aheadOfPace)
        } ?? 0
        burn(heat: heat, tint: tint)
    }

    private func layer() -> CALayer? {
        guard let button, let host = button.layer else { return nil }
        if let glow, glow.superlayer === host {
            glow.frame = host.bounds.insetBy(dx: 1, dy: 2)
            return glow
        }
        let l = CALayer()
        l.frame = host.bounds.insetBy(dx: 1, dy: 2)
        l.cornerRadius = 5
        l.opacity = 0
        host.addSublayer(l)
        glow = l
        return l
    }

    /// One bright beat, then gone.
    private func flash(_ color: NSColor) {
        guard let l = layer() else { return }
        let key = "flash"
        l.removeAnimation(forKey: key)
        let colorAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
        colorAnim.values = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0.55).cgColor]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.6, 0]
        fade.keyTimes = [0, 0.12, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [colorAnim, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(group, forKey: key)
    }

    /// A slow ember breath while the active account burns; heat scales
    /// brightness and pace. Installed once per state, removed at 0.
    private func burn(heat: Double, tint: NSColor) {
        guard let l = layer() else { return }
        let key = "burn"
        guard heat > 0 else {
            if burning { l.removeAnimation(forKey: key); burning = false }
            return
        }
        if burning { return }
        burning = true
        l.backgroundColor = NSColor.systemOrange.blended(withFraction: 0.4, of: tint)?.withAlphaComponent(0.4).cgColor
        let top = 0.25 + 0.5 * Float(heat)
        l.add(CAKeyframeAnimation.cycle("opacity", values: [0.05, top, 0.05],
                                        duration: 1.6 - 0.6 * heat), forKey: key)
    }
}
