import SwiftUI
import InfinitusCore

/// T3's brand lockup (apps/mobile/src/components/CompactBrandTitle.tsx): the
/// bold mark, the rest of the name, then an uppercase stage badge. T3 draws
/// "T3" + "Code" + "DEV"; ours is the Infinitus name in the same shape, so a
/// two-word name gets the same two-tone treatment.
public struct T3Wordmark: View {
    /// The bold first token of the product name.
    public static let mark = "Infinitus"
    /// What follows it, drawn in the muted weight (empty for a one-word name).
    public static let rest = ""
    @Environment(\.t3) private var t3
    let badge: String?
    public init(badge: String? = nil) { self.badge = badge }
    public var body: some View {
        let p = t3.mobile
        HStack(spacing: 6) {
            Text(T3Wordmark.mark)
                .font(T3Font.mobileLiteral(21, .bold))
                .foregroundStyle(p.wordmark.color)
            if !T3Wordmark.rest.isEmpty {
                Text(T3Wordmark.rest)
                    .font(T3Font.mobileLiteral(21, .medium))
                    .foregroundStyle(p.foregroundMuted.color)
            }
            if let badge {
                Text(badge.uppercased())
                    .font(T3Font.mobileLiteral(9, .bold))
                    .foregroundStyle(p.foregroundMuted.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(p.subtle.color, in: Capsule())
            }
        }
    }
}
