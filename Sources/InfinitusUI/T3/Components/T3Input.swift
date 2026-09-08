import SwiftUI
import InfinitusCore

/// T3's `<Input>` (ui/input.tsx): a bordered control wrapping a plain field,
/// the `ring` showing while it holds focus.
public struct T3Input: View {
    @Environment(\.t3) private var t3
    @FocusState private var focused: Bool
    @Binding var text: String
    let placeholder: String
    let leading: Lucide?
    public init(text: Binding<String>, placeholder: String, leading: Lucide? = nil) {
        self._text = text; self.placeholder = placeholder; self.leading = leading
    }
    public var body: some View {
        let p = t3.web
        let radius = T3Theme.Metrics.radius   // "rounded-lg" = var(--radius)
        HStack(spacing: 8) {
            if let leading { LucideIcon(leading, size: 16).foregroundStyle(p.mutedForeground.color) }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(p.placeholder.color))
                .textFieldStyle(.plain)
                .font(T3Font.web(.sm))
                .foregroundStyle(p.foreground.color)
                .focused($focused)
        }
        // The field's own "px-[calc(--spacing(3)-1px)]" — the calc subtracts
        // the wrapper's border, which SwiftUI strokes without consuming layout.
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(p.background.color, in: RoundedRectangle(cornerRadius: radius))
        // "border border-input … has-focus-visible:border-ring", and the
        // 3 px "ring-ring/24" halo just outside it while focus is held.
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? p.ring.color : p.input.color, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: radius + 1.5)
            .stroke(focused ? p.ring.color.opacity(0.24) : .clear, lineWidth: 3)
            .padding(-1.5))
    }
}
