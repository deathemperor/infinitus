import SwiftUI

/// T3's `<ScrollArea>` (ui/scroll-area.tsx): the native bars stay hidden and
/// a 6 px rounded thumb fades in while the pointer is over the area
/// ("opacity-0 … data-hovering:opacity-100", `--app-scrollbar-thumb`).
public struct T3ScrollArea<Content: View>: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    @State private var offset: Double = 0
    @State private var contentHeight: Double = 0
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        GeometryReader { outer in
            ScrollView {
                content
                    .background(GeometryReader { inner in
                        Color.clear.preference(key: T3ScrollMetricsKey.self,
                                               value: [inner.size.height,
                                                       -inner.frame(in: .named(t3ScrollAreaSpace)).minY])
                    })
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: t3ScrollAreaSpace)
            .onPreferenceChange(T3ScrollMetricsKey.self) { m in
                contentHeight = m.first ?? 0
                offset = m.count > 1 ? m[1] : 0
            }
            .overlay(alignment: .topTrailing) { thumb(viewport: outer.size.height) }
        }
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private func thumb(viewport: Double) -> some View {
        let travel = max(0, contentHeight - viewport)
        if travel > 0 {
            let width = T3Theme.Metrics.scrollbarWidth
            let length = max(24, viewport * viewport / contentHeight)
            let y = (viewport - length) * min(1, max(0, offset / travel))
            RoundedRectangle(cornerRadius: width / 2)
                // `--app-scrollbar-thumb` is not a generated palette token.
                // `input` is its exact value on dark (white at 8%); on light
                // it is (212,212,216) against the thumb's (217,217,217).
                .fill(t3.web.input.color)
                .frame(width: width, height: length)
                .offset(x: -1, y: y)
                .opacity(hover ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: hover)
                .allowsHitTesting(false)
        }
    }
}

private let t3ScrollAreaSpace = "t3-scroll-area"

struct T3ScrollMetricsKey: PreferenceKey {
    static let defaultValue: [Double] = []
    static func reduce(value: inout [Double], nextValue: () -> [Double]) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}
