import SwiftUI
import InfinitusCore

/// The popup background's portable half: the theme-tinted wash and the
/// themed border glow (#9 phase B2). The glass UNDER it is AppKit only
/// — NSGlassEffectView / CABackdropLayer / the popover-frame retune all
/// stay mac-side in GlassBackground.swift; a host without them puts its
/// own blur (or none) behind this and still reads as the same popup.
///
/// `milk` is the host's transparency dial, 0 = fully clear glass: the
/// wash fades out with the frost so one dial drives the whole chrome.
public struct ThemeWash: View {
    let theme: RowTheme
    let milk: Double

    public init(theme: RowTheme, milk: Double) {
        self.theme = theme
        self.milk = milk
    }

    @ViewBuilder public var body: some View {
        if !theme.plain, !theme.flashColor.isEmpty {
            let tint = ThemeColor.resolve(theme.flashColor)
            LinearGradient(
                colors: [tint.opacity(0.16 * milk),
                         tint.opacity(0.04 * milk)],
                startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                .padding(1)
        }
    }
}
