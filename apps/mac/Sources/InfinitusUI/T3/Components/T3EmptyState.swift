import SwiftUI
import InfinitusCore

/// T3's `<EmptyState variant="plain">` (apps/mobile/src/components/EmptyState.tsx):
/// a centred title over its explanation, the call to action below — the
/// "No environments connected" screen of the `t3-ios-4.png` reference.
public struct T3EmptyState: View {
    @Environment(\.t3) private var t3
    let title: String, message: String
    let action: (String, () -> Void)?
    public init(title: String, message: String, action: (String, () -> Void)? = nil) {
        self.title = title; self.message = message; self.action = action
    }
    public var body: some View {
        let p = t3.mobile
        VStack(spacing: 8) {
            Text(title)
                .font(T3Font.mobile(.xl, .bold))
                .foregroundStyle(p.foreground.color)
            Text(message)
                .font(T3Font.mobile(.base))
                .foregroundStyle(p.foregroundMuted.color)
            if let action {
                // The reference's 48 pt primary button, "mt-5" under the
                // message — 12 on top of the stack's own 8.
                T3ControlPill(action.0, action: action.1)
                    .primary(height: 48, background: p.primary.color, foreground: p.primaryForeground.color)
                    .padding(.top, 12)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
}
