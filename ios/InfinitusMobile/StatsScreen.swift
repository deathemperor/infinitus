import SwiftUI
import InfinitusCore

/// The Mac's Stats tab on the phone: the same tile catalogue
/// (`Stats.Presentation`, fix round 1) as `StatsPane`, minus the
/// sparklines and the hour heatmap — everything else the Mac shows,
/// same names, same values, same deltas.
struct StatsScreen: View {
    @ObservedObject var model: MirrorModel
    @State private var period: Stats.Period = .week

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if let s = model.stats?.summary(period) {
                ForEach(Stats.Presentation.groups(s, theme: model.rowTheme)) { group in
                    Section(group.id) {
                        ForEach(group.tiles) { tile in
                            LabeledContent(tile.id) {
                                HStack(spacing: 6) {
                                    Text(tile.value).monospacedDigit()
                                    if let delta = tile.delta {
                                        Text(delta).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
                effortSection("Where the effort went", Stats.Presentation.activityRows(s))
                effortSection("By model", Stats.Presentation.modelRows(s))
                effortSection("By engine", Stats.Presentation.engineRows(s))
                effortSection("By effort", Stats.Presentation.effortRows(s), footer: Stats.Presentation.activityFootnote)
                if let records = model.stats?.tokenRecords {
                    Section(Stats.Presentation.recordTitle(theme: model.rowTheme)) {
                        ForEach(Stats.Presentation.recordLines(records, theme: model.rowTheme), id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ForEach(Stats.Presentation.recordRows(records), id: \.label) { row in
                            LabeledContent(row.label, value: Stats.Presentation.perMinute(row.count, theme: model.rowTheme))
                        }
                    }
                }
                Section("Rhythm") {
                    ForEach(Stats.Presentation.sessionLengthRows(s), id: \.label) { row in
                        LabeledContent(row.label, value: n(row.count))
                    }
                    Text(Stats.Presentation.sessionTimeLine(s))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Section {
                    Text("\(s.from) – \(s.to) · streak \(s.streak) days")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                ThemedPlaceholder(theme: model.rowTheme, key: "empty", plainSymbol: "chart.bar",
                                  description: "The Mac sends them once its first scan finishes.")
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func n(_ v: Int) -> String { v.formatted() }

    private func effortSection(_ title: String, _ rows: [Stats.Presentation.Row], footer: String? = nil) -> some View {
        Section {
            if rows.isEmpty { Text("Nothing yet this period").font(.caption).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                LabeledContent {
                    Text("\(r.usdText) · \(r.minutesText)").monospacedDigit()
                } label: {
                    Text(r.id)
                    Text("\(r.count) stretches · \(r.tokensText) tokens\(r.cachedSuffixText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}
