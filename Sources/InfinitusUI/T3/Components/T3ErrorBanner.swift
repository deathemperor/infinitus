import SwiftUI
import InfinitusCore

/// T3's `<ErrorBanner>` (apps/mobile/src/components/ErrorBanner.tsx):
/// "rounded-2xl border border-danger-border bg-danger px-3.5 py-3" with a
/// `danger-foreground` medium sm label.
public struct T3ErrorBanner: View {
    @Environment(\.t3) private var t3
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        let p = t3.mobile
        Text(text)
            .font(T3Font.mobile(.sm, .medium))
            .foregroundStyle(p.dangerForeground.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(p.danger.color, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.dangerBorder.color, lineWidth: 1))
    }
}
