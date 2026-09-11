import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// T3's `<GlassSurface>` (apps/mobile/src/components/GlassSurface.tsx): the
/// blurred chrome the phone floats over content — the system material under
/// a `glassSurface` fill and a `glassTint` overlay (spec §3.4).
public struct T3GlassSurface<Content: View>: View {
    @Environment(\.t3) private var t3
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content.background(surface)
    }
    @ViewBuilder private var surface: some View {
        #if canImport(UIKit)
        T3MaterialView(style: .systemMaterial)
            .overlay(t3.mobile.glassSurface.color)
            .overlay(t3.mobile.glassTint.color)
        #else
        // The Mac has no UIVisualEffectView; SwiftUI's own material carries
        // the same two token layers, so the previews render on both.
        Rectangle().fill(.regularMaterial)
            .overlay(t3.mobile.glassSurface.color)
            .overlay(t3.mobile.glassTint.color)
        #endif
    }
}

#if canImport(UIKit)
struct T3MaterialView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ v: UIVisualEffectView, context: Context) {}
}
#endif
