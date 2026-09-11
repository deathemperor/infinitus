import SwiftUI
import InfinitusCore

/// T3's `<Button>` (apps/web/src/components/ui/button.tsx). Sizes come from
/// `T3ButtonMetrics`; each variant's Tailwind classes sit above its case.
public struct T3Button: View {
    public enum Variant: Sendable { case `default`, secondary, ghost, outline, destructive }
    @Environment(\.t3) private var t3
    @State private var hover = false
    let title: String, variant: Variant, size: T3ButtonMetrics.Size, icon: Lucide?, action: () -> Void
    public init(_ title: String, variant: Variant = .default, size: T3ButtonMetrics.Size = .default,
                icon: Lucide? = nil, action: @escaping () -> Void) {
        self.title = title; self.variant = variant; self.size = size; self.icon = icon; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { LucideIcon(icon, size: 16) }
                // `button.tsx:36` `xs`'s `sm:text-xs` (the rest render `sm:text-sm`).
                if size != .icon { Text(title).font(T3Font.web(size == .xs ? .xs : .sm, .medium)) }
            }
            .padding(.horizontal, T3ButtonMetrics.horizontalPadding(size))
            .frame(height: T3ButtonMetrics.height(size))
            .frame(minWidth: size == .icon ? T3ButtonMetrics.height(size) : nil)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius).stroke(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
    private var p: T3Theme.WebPalette { t3.web }
    private var background: Color {
        switch variant {
        // "border-primary bg-primary … [:hover,[data-pressed]]:bg-primary/90"
        case .default: return p.primary.color.opacity(hover ? 0.9 : 1)
        // "bg-secondary … [:hover,[data-pressed]]:bg-secondary/90"
        case .secondary: return p.secondary.color.opacity(hover ? 0.9 : 1)
        // "border-transparent … [:hover,[data-pressed]]:bg-accent"
        case .ghost: return hover ? p.accent.color : .clear
        // "border-input bg-popover … [:hover,[data-pressed]]:bg-accent/50"
        case .outline: return hover ? p.accent.color.opacity(0.5) : p.popover.color
        // "border-destructive bg-destructive text-white … :hover:bg-destructive/90"
        case .destructive: return p.destructive.color.opacity(hover ? 0.9 : 1)
        }
    }
    private var foreground: Color {
        switch variant {
        case .default: return p.primaryForeground.color
        case .destructive: return .white
        case .secondary: return p.secondaryForeground.color
        case .ghost, .outline: return hover ? p.accentForeground.color : p.foreground.color
        }
    }
    private var border: Color { variant == .outline ? p.input.color : .clear }
}
