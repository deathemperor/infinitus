import SwiftUI

/// T3's `<Separator>` (ui/separator.tsx): "shrink-0 bg-border h-px w-full".
public struct T3Separator: View {
    @Environment(\.t3) private var t3
    public init() {}
    public var body: some View {
        Rectangle().fill(t3.web.border.color).frame(height: 1)
    }
}
