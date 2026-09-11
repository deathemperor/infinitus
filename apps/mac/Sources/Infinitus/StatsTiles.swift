// Sources/Infinitus/StatsTiles.swift
import SwiftUI
import Charts
import InfinitusCore

/// The Stats tiles (`Stats.Presentation.groups`) as Form sections — the
/// Stats pane and a teammate's detail render the same view.
struct StatsTiles: View {
    let summary: Stats.Summary
    var theme: RowTheme = .off

    var body: some View {
        ForEach(Stats.Presentation.groups(summary, theme: theme)) { group($0) }
    }

    private func group(_ g: Stats.Presentation.Group) -> some View {
        Section(g.id) {
            TileRows(tiles: g.tiles) { tileView($0) }
        }
    }

    private func tileView(_ t: Stats.Presentation.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t.value).font(.title3.weight(.semibold)).monospacedDigit()
                if let delta = t.delta {
                    Text(delta).font(.caption2).foregroundStyle(delta.hasPrefix("+") ? .green : delta.hasPrefix("−") ? .orange : .secondary)
                }
            }
            if t.series.contains(where: { $0 != 0 }) {
                Chart(Array(t.series.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(Color.accentColor.opacity(0.18))
                    LineMark(x: .value("d", i), y: .value("v", v)).foregroundStyle(Color.accentColor)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 26)
            } else {
                Spacer(minLength: 26)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
        .accessibilityElement(children: .combine)
    }
}

/// Tiles laid out in rows that always fill the width. A LazyVGrid with
/// `.adaptive(minimum: 150)` left the 13th Throughput tile alone in a
/// row of four with three empty cells beside it (critique, minor
/// observations) — an adaptive grid leaves the trailing row's cells
/// empty instead of sharing the width; 13 has a remainder of one at
/// every plausible column count, so the fix is to let the last row's
/// tiles share the leftover width instead of leaving holes.
private struct TileRows<Content: View>: View {
    let tiles: [Stats.Presentation.Tile]
    @ViewBuilder let tile: (Stats.Presentation.Tile) -> Content

    private static var minTile: CGFloat { 150 }
    private static var spacing: CGFloat { 10 }

    /// Seeded to the settings window's content width so the first frame
    /// (before the background `GeometryReader` reports) is already the
    /// right column count instead of one tile per row (review round 1,
    /// finding 4).
    @State private var width: CGFloat = 640

    private var columns: Int {
        max(1, Int((width + Self.spacing) / (Self.minTile + Self.spacing)))
    }

    private var rows: [[Stats.Presentation.Tile]] {
        stride(from: 0, to: tiles.count, by: columns).map {
            Array(tiles[$0..<min($0 + columns, tiles.count)])
        }
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.spacing) {
                    ForEach(row) { t in
                        tile(t).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        )
    }
}
