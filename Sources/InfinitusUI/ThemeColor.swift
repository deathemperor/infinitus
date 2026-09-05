import SwiftUI
import InfinitusCore

/// Maps a theme color string — named or "#rrggbb" — to a SwiftUI Color.
public enum ThemeColor {
    /// Animation accent for a theme — the app accent when unset.
    public static func flash(_ theme: RowTheme) -> Color {
        theme.flashColor.isEmpty ? .accentColor : resolve(theme.flashColor)
    }

    public static func resolve(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "teal": return .teal
        case "pink": return .pink
        case "mint": return .mint
        case "brown": return .brown
        case "gray", "secondary": return .secondary
        default:
            guard let c = ThemePalette.hex(name) else { return .primary }
            return Color(red: Double(c.r) / 255,
                         green: Double(c.g) / 255,
                         blue: Double(c.b) / 255)
        }
    }
}
