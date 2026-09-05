import Foundation

/// Canonical theme colour resolution across platforms.
///
/// Ports the colour mapping from `InfinitusUI.ThemeColor` into pure Core so macOS,
/// Windows, Linux, and mobile resolve a theme's colours identically without
/// importing SwiftUI.
public enum ThemePalette {
    public struct RGB: Sendable, Equatable, Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// "#rrggbb" only (case-insensitive). Named colours are platform-dynamic and return nil
    /// — `named` below carries a fixed fallback for platforms without a system palette (Win32).
    public static func hex(_ name: String) -> RGB? {
        guard name.hasPrefix("#"), name.count == 7 else { return nil }
        let hexStr = name.dropFirst()
        guard let v = UInt32(hexStr, radix: 16) else { return nil }
        return RGB(
            r: UInt8((v >> 16) & 0xff),
            g: UInt8((v >> 8) & 0xff),
            b: UInt8(v & 0xff)
        )
    }

    /// The canonical names a RowTheme may use.
    public static let names = [
        "red", "blue", "green", "yellow", "orange",
        "purple", "indigo", "cyan", "teal", "pink",
        "mint", "brown", "gray", "secondary", "primary"
    ]

    /// Fixed sRGB for each name — Apple's dark-appearance system colours,
    /// so the Windows tray and the Mac popup read the same at a glance.
    /// `secondary`/`gray`/`primary` return nil: they mean "the platform's
    /// label colour", which the caller supplies.
    public static func named(_ name: String) -> RGB? {
        switch name.lowercased() {
        case "red": return RGB(r: 255, g: 69, b: 58)
        case "blue": return RGB(r: 10, g: 132, b: 255)
        case "green": return RGB(r: 48, g: 209, b: 88)
        case "yellow": return RGB(r: 255, g: 214, b: 10)
        case "orange": return RGB(r: 255, g: 159, b: 10)
        case "purple": return RGB(r: 191, g: 90, b: 242)
        case "indigo": return RGB(r: 94, g: 92, b: 230)
        case "cyan": return RGB(r: 100, g: 210, b: 255)
        case "teal": return RGB(r: 64, g: 200, b: 224)
        case "pink": return RGB(r: 255, g: 55, b: 95)
        case "mint": return RGB(r: 102, g: 212, b: 207)
        case "brown": return RGB(r: 172, g: 142, b: 104)
        case "secondary", "gray", "primary": return nil
        default: return nil
        }
    }

    /// hex -> named -> nil.
    public static func rgb(_ name: String) -> RGB? {
        hex(name) ?? named(name)
    }
}
