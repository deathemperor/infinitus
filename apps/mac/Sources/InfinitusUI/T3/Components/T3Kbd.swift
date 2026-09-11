import SwiftUI
import InfinitusCore

/// T3's `<Kbd>` (ui/kbd.tsx): "h-5 min-w-5 rounded bg-muted px-1 font-medium
/// text-muted-foreground text-xs".
public struct T3Kbd: View {
    @Environment(\.t3) private var t3
    let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys)
            .font(T3Font.web(.xs, .medium))
            .padding(.horizontal, 4)
            .frame(minWidth: 20)
            .frame(height: 20)
            .foregroundStyle(t3.web.mutedForeground.color)
            .background(t3.web.muted.color, in: RoundedRectangle(cornerRadius: 4))
    }
}
