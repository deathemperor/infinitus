import SwiftUI

/// Zero-delay hover label for icon-only buttons ("instant tooltip",
/// user 2026-08-30): .help() waits on the system tooltip delay, too slow
/// to learn a rail of bare icons from. Rides to the RIGHT of the icon —
/// the rail hugs the popup's left edge, so right always has room.
/// Which side of the anchor the tip lands on. Trailing tips overflowed
/// the popup at the right edge and even inside gauge cells (user
/// screenshots 2026-08-30) — below/above hug the popup's vertical axis.
public enum TipEdge { case trailing, below, above }

/// One hovered tip, published up to the popup root. Drawing the chip
/// as a local overlay put it UNDER later siblings — zIndex only orders
/// views inside their own container, so a slot tip on row N rendered
/// beneath row N+1's cells (user screenshot 2026-08-30). The root
/// resolves the anchor and draws the ONE active chip above everything.
public struct TipData {
    let anchor: Anchor<CGRect>
    let text: String
    let edge: TipEdge
}

public struct ActiveTipKey: PreferenceKey {
    public static let defaultValue: [TipData] = []
    public static func reduce(value: inout [TipData], nextValue: () -> [TipData]) {
        value.append(contentsOf: nextValue())
    }
}

private struct InstantTip: ViewModifier {
    let text: String
    var edge: TipEdge = .below
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .anchorPreference(key: ActiveTipKey.self, value: .bounds) {
                hovering ? [TipData(anchor: $0, text: text, edge: edge)] : []
            }
    }
}

/// The popup root's tip renderer — overlayPreferenceValue(ActiveTipKey)
/// with this inside. Offsets mirror the old per-view overlay geometry
/// (topLeading + 22 below, bottom-anchored above, midY trailing).
public struct InstantTipCanvas: View {
    let tips: [TipData]

    public init(tips: [TipData]) { self.tips = tips }

    /// Measured chip width, for edge clamping. One tip shows at a time,
    /// so a single measurement is enough.
    @State private var chipWidth: CGFloat = 0

    /// The window clips its content, so a tip can never render OUTSIDE
    /// the popup (user ask 2026-09-01 — that would need a separate
    /// floating panel). Clamp instead: a chip near the right edge
    /// shifts left, never clips.
    private func clampX(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        max(4, min(x, width - chipWidth - 4))
    }

    public var body: some View {
        GeometryReader { geo in
            if let tip = tips.last {
                let r = geo[tip.anchor]
                let chip = TipChip(text: tip.text)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width }
                        action: { chipWidth = $0 }
                switch tip.edge {
                case .below:
                    chip
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .offset(x: clampX(r.minX, in: geo.size.width), y: r.minY + 22)
                case .above:
                    // Bottom-anchored so the chip's own height never
                    // matters: bottom edge lands at r.maxY - 22.
                    chip
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                        .offset(x: clampX(r.minX, in: geo.size.width),
                                y: r.maxY - 22 - geo.size.height)
                case .trailing:
                    chip
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .offset(x: clampX(r.minX + 24, in: geo.size.width), y: r.midY - 11)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TipChip: View {
    let text: String

    @ViewBuilder var body: some View {
        // Short tips get their ideal width (fixedSize — an overlay is
        // proposed its ANCHOR's size, so frame(maxWidth:) clamps to a
        // 20pt icon and wraps one char per line, the 'vertical strip'
        // bug). Long tips get a FIXED width, which is also honored.
        let chip = Text(text)
            .font(PopupFont.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .shadow(radius: 2, y: 1))
        if text.count > 42 {
            chip.frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            chip.fixedSize()
        }
    }
}

public extension View {
    func instantTip(_ text: String, edge: TipEdge = .below) -> some View {
        modifier(InstantTip(text: text, edge: edge))
    }
}

/// Type-erased LabelStyle so one Label can flip icon-only <-> titled at
/// runtime (the ternary needs a single concrete type).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
