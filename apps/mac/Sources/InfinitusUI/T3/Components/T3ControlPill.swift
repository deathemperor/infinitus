import SwiftUI
import InfinitusCore

/// T3's `<ControlPill>` (apps/mobile/src/components/ControlPill.tsx): the
/// round-ended control the phone's toolbars are built from — a flat `subtle`
/// fill with no hairline ("rounded-full … bg-subtle"), or the glass variant
/// floating over content.
public struct T3ControlPill: View {
    public enum Style: Sendable { case solid, glass }
    @Environment(\.t3) private var t3
    let title: String, icon: T3Symbol?, style: Style, action: () -> Void
    /// The kit's pill is 36 tall; `T3EmptyState`'s call to action is the
    /// 48 pt button of the `t3-ios-4.png` reference, so height is settable
    /// inside the module while the public initialiser stays the brief's.
    var height: Double = 36
    public init(_ title: String, icon: T3Symbol? = nil, style: Style = .solid, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.style = style; self.action = action
    }
    /// A pill in `primary`/`primaryForeground` — upstream's `variant="primary"`.
    var tint: (background: Color, foreground: Color)?

    /// The primary call to action `T3EmptyState` places under its message.
    func primary(height: Double, background: Color, foreground: Color) -> T3ControlPill {
        var copy = self
        copy.height = height
        copy.tint = (background, foreground)
        return copy
    }

    public var body: some View {
        let p = t3.mobile
        Button(action: action) {
            HStack(spacing: 8) {
                // Upstream tints the glyph `accent-icon` and lets the label
                // take AppText's `text-foreground`; a primary pill paints both.
                if let icon {
                    icon.image.font(.system(size: 16))
                        .foregroundStyle(tint?.foreground ?? p.icon.color)
                }
                Text(title).font(T3Font.mobile(.sm, .medium))
                    .foregroundStyle(tint?.foreground ?? p.foreground.color)
            }
            .padding(.horizontal, 14)
            .frame(height: height)
            .background {
                if let tint { Capsule().fill(tint.background) }
                else if style == .glass { T3GlassSurface { Capsule().fill(.clear) } }
                else { Capsule().fill(p.subtle.color) }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
