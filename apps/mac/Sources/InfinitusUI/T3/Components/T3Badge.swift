import SwiftUI
import InfinitusCore

/// T3's `<Badge>` (ui/badge.tsx): a small pill of state next to a label.
public struct T3Badge: View {
    public enum Variant: Sendable { case `default`, secondary, outline, destructive }
    @Environment(\.t3) private var t3
    let text: String, variant: Variant
    public init(_ text: String, variant: Variant = .default) { self.text = text; self.variant = variant }
    public var body: some View {
        // size.default at the desktop breakpoint: "sm:h-4.5 sm:min-w-4.5",
        // "px-[calc(--spacing(1)-1px)]", "sm:text-xs" over the base's
        // "rounded-sm … font-medium".
        let radius = T3Theme.Metrics.radius - 4   // rounded-sm
        return Text(text)
            .font(T3Font.web(.xs, .medium))
            .padding(.horizontal, 4)
            .frame(minWidth: 18)
            .frame(height: 18)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: 1))
    }
    private var p: T3Theme.WebPalette { t3.web }
    private var background: Color {
        switch variant {
        case .default: return p.primary.color          // "bg-primary text-primary-foreground"
        case .secondary: return p.secondary.color      // "bg-secondary text-secondary-foreground"
        case .outline: return p.background.color       // "border-input bg-background text-foreground"
        case .destructive: return p.destructive.color  // "bg-destructive text-white"
        }
    }
    private var foreground: Color {
        switch variant {
        case .default: return p.primaryForeground.color
        case .secondary: return p.secondaryForeground.color
        case .outline: return p.foreground.color
        case .destructive: return .white
        }
    }
    private var border: Color { variant == .outline ? p.input.color : .clear }
}
