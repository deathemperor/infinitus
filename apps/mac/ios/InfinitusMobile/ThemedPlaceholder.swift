import SwiftUI
import InfinitusCore
import InfinitusUI

/// The theme's placeholder icon, moving the way the theme says
/// ("spin", "pulse", "bounce", "flicker") — the RPG dice spin while a
/// feed loads, the Hades flame flickers (user 2026-09-05: "themify the
/// loading texts, animation, icons too"). Still when the theme has no
/// motion, when Reduce Motion is on, or when `moving` is false.
struct ThemedIcon: View {
    let theme: RowTheme
    var moving = true
    var font: Font = .largeTitle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let icon = theme.loadingIcon
        let active = moving && !reduceMotion
        Group {
            if icon.hasPrefix("sf:") {
                let image = Image(systemName: String(icon.dropFirst(3)))
                switch theme.loadingMotion {
                case "pulse":
                    image.symbolEffect(.pulse, options: .repeating, isActive: active)
                case "bounce":
                    image.symbolEffect(.bounce, options: .repeating.speed(0.5), isActive: active)
                case "flicker":
                    image.symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: active)
                default:
                    // "spin": a system-driven symbol effect, never a
                    // repeatForever animation (CLAUDE.md); iOS 17 pulses.
                    if #available(iOS 18, *) {
                        image.symbolEffect(.rotate, options: .repeating, isActive: active)
                    } else {
                        image.symbolEffect(.pulse, options: .repeating, isActive: active)
                    }
                }
            } else {
                Text(icon)
            }
        }
        .font(font)
        .foregroundStyle(ThemeColor.flash(theme))
    }
}

/// One placeholder for every "nothing to show yet" spot on the phone:
/// the theme's word for `key` ("loading", "empty", "noSessions",
/// "searching") under its icon; the Off theme keeps the system
/// spinner and the plain ContentUnavailableView with `plainSymbol`.
struct ThemedPlaceholder: View {
    let theme: RowTheme
    let key: String
    var plainSymbol = ""
    var description: String? = nil

    var body: some View {
        if theme.plain || theme.loadingIcon.isEmpty {
            if key == "loading" {
                ProgressView(theme.loadingWord(key))
            } else {
                ContentUnavailableView(theme.loadingWord(key), systemImage: plainSymbol,
                                       description: description.map { Text($0) })
            }
        } else {
            VStack(spacing: 10) {
                ThemedIcon(theme: theme, moving: key == "loading")
                Text(theme.loadingWord(key))
                    .font(.title3.weight(.semibold))
                if let description {
                    Text(description)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
