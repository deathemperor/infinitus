import SwiftUI
import InfinitusCore

/// Maps a theme color string — named or "#rrggbb" — to a SwiftUI Color.
public enum ThemeColor {
    /// Animation accent for a theme — the app accent when unset.
    public static func flash(_ theme: RowTheme) -> Color {
        theme.flashColor.isEmpty ? .accentColor : resolve(theme.flashColor)
    }

    /// `flash(theme)` for a Core Animation layer (LayerEffect hosts take
    /// CGColor, not Color).
    public static func flashCG(_ theme: RowTheme) -> CGColor {
        #if canImport(AppKit)
        return NSColor(flash(theme)).cgColor
        #else
        return UIColor(flash(theme)).cgColor
        #endif
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
            guard name.hasPrefix("#"), name.count == 7,
                  let v = UInt32(name.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((v >> 16) & 0xff) / 255,
                         green: Double((v >> 8) & 0xff) / 255,
                         blue: Double(v & 0xff) / 255)
        }
    }
}
