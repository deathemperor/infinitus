import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Mac popup's chrome, rebuilt in plain SwiftUI (#9 phase D2). The
/// mac stack is AppKit — a CABackdropLayer blur under the hosting view,
/// `GlassScrimView(strength: 0.85)` over it, then `ThemedGlassChrome`'s
/// frost and `ThemeWash` on top — and none of that crosses. The phone
/// gets the same three layers with the system material standing in for
/// the tuned backdrop, at the container's 10pt radius.
struct PopupChrome: View {
    let theme: RowTheme

    /// The mac's transparency dial sits at 0.7 clarity by default, so
    /// its wash and frost render at milk 0.3 — the popup every capture
    /// shows. The phone has no dial, so it pins the same number.
    static let milk: Double = 0.3

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.85)
            Color.black.opacity(0.30 * Self.milk)
            ThemeWash(theme: theme, milk: Self.milk)
        }
    }
}

/// The Mac's `PopupScale`, on the phone: render the popup at its natural
/// ideal size, measure it, then `scaleEffect` with a frame matching the
/// scaled bounds. Same reason for the `fixedSize()` as on the mac — the
/// outer frame must never propose itself back into flexible content.
///
/// The phone adds fit-to-width: the mac's popup is as wide as it wants
/// to be, the screen isn't. `cap` raises the ceiling above 1 (portrait's
/// stacked cards fill the phone) and carries the mirrored text-size
/// pref; the width fit always wins.
struct PopupFit: ViewModifier {
    let available: CGFloat
    let cap: CGFloat
    @State private var measured: CGSize = .zero

    private var scale: CGFloat {
        guard measured.width > 0, available > 0 else { return 1 }
        return min(available / measured.width, cap)
    }

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: measured == .zero ? nil : measured.width * scale,
                   height: measured == .zero ? nil : measured.height * scale,
                   alignment: .topLeading)
    }
}

extension View {
    /// `portrait` raises the ceiling to 1.25 so the narrow stacked cards
    /// fill the phone; landscape's wide grid only ever shrinks.
    func popupFit(available: CGFloat, portrait: Bool, textScale: CGFloat) -> some View {
        modifier(PopupFit(available: available,
                          cap: (portrait ? 1.25 : 1) * textScale))
    }
}
