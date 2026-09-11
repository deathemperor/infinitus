import SwiftUI

/// Cross-fleet column alignment (user 2026-09-03, "align the columns"):
/// every fleet renders its own Grid, so its columns sized to its own
/// widest cell and the HP of one section sat under the MP of another.
/// Tagged cells report their width per column key; FleetStack keeps the
/// max per key and hands it back as a minimum width, so the same key
/// lands at the same x in every section. Widths only grow while the
/// stack lives (a max never shrinks); the stack resets them when the
/// fleet count changes. Layout-only: nothing here ticks.
struct ColumnWidths: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct SharedColumnWidthsKey: EnvironmentKey {
    static let defaultValue: [String: CGFloat] = [:]
}

extension EnvironmentValues {
    var sharedColumnWidths: [String: CGFloat] {
        get { self[SharedColumnWidthsKey.self] }
        set { self[SharedColumnWidthsKey.self] = newValue }
    }
}

private struct AlignedColumn: ViewModifier {
    let key: String
    @Environment(\.sharedColumnWidths) private var widths

    func body(content: Content) -> some View {
        if key.isEmpty {
            content
        } else {
            content
                .frame(minWidth: widths[key], alignment: .leading)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ColumnWidths.self, value: [key: geo.size.width])
                })
        }
    }
}

extension View {
    /// Tag a grid cell with its column so sibling fleets line it up.
    func alignedColumn(_ key: String) -> some View { modifier(AlignedColumn(key: key)) }
}
