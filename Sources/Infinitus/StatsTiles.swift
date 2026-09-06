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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(g.tiles) { tileView($0) }
            }
            .padding(.vertical, 4)
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
    }
}
