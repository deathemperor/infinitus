import SwiftUI
import InfinitusCore

/// One sRGB colour from the generated palettes.
public struct T3RGBA: Sendable, Equatable {
    public let r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
}

/// Core carries its colours as plain 0-255 components (`T3ProjectIcon.RGB`)
/// because `InfinitusCore` may not depend on `InfinitusUI` — this is the one
/// place they become SwiftUI colours.
extension T3ProjectIcon.RGB {
    public var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
