import SwiftUI
import InfinitusCore
import InfinitusUI

/// A theme's four colours — session, weekly, model, credit — as one
/// small chip. The Settings row wears it beside the theme's name so the
/// name is not the only thing the reader has to go on before opening
/// the chooser (critique, iOS heuristic 6).
struct ThemeSwatch: View {
    let theme: RowTheme
    /// Tracks the row's text so the chip grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var height = 15

    private var colors: [Color] {
        [theme.sessionColor, theme.weeklyColor, theme.scopedColor, theme.creditColor]
            .map(ThemeColor.resolve)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: height * 0.55, height: height)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
                .frame(width: height * 0.55 * 4 + 6, height: height)
        )
        // The name beside it says everything a reader needs; the chip is
        // the same fact in colour.
        .accessibilityHidden(true)
    }
}
