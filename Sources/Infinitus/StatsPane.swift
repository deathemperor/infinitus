// Sources/Infinitus/StatsPane.swift
import SwiftUI
import Charts
import InfinitusCore

/// Settings › Stats: engineering metrics per period (user 2026-09-04).
/// Tiles = value, delta vs the previous period, sparkline of the days —
/// the tile catalogue itself lives in `Stats.Presentation` (fix round 1)
/// so the phone renders the exact same list; this file keeps only what's
/// Mac-specific (picker, scanning line, sparklines, heatmap, session
/// length chart, footnotes, Refresh).
struct StatsPane: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var app: AppModel
    @AppStorage("stats_period", store: AppDefaults.standard) private var periodRaw = Stats.Period.week.rawValue

    private var period: Stats.Period { Stats.Period(rawValue: periodRaw) ?? .week }
    private var summary: Stats.Summary? { model.summaries[period] }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $periodRaw) {
                    ForEach(Stats.Period.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if let s = summary {
                    Text("\(s.from) – \(s.to) · \(s.streak)-day streak")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if model.scanning {
                    HStack { ProgressView().controlSize(.small); Text(model.progress ?? "Scanning…") }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .settingsAnchor("Stats/Period")
            if let s = summary {
                StatsTiles(summary: s, theme: app.rowTheme)
                effort(s)
                if let records = model.bundle?.tokenRecords { recordBook(records) }
                Section("Rhythm") {
                    heatmap(s.total.hours)
                    sessionLengths(s)
                }
                .settingsAnchor("Stats/Rhythm")
            }
            Section {
                Button("Refresh") { model.refresh() }.disabled(model.scanning)
            } header: {
                Text("Scan")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.notes, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: tokens/min records (#89)

    private func recordBook(_ r: Stats.TokenRecords) -> some View {
        Section(Stats.Presentation.recordTitle(theme: app.rowTheme)) {
            ForEach(Stats.Presentation.recordLines(r, theme: app.rowTheme), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if r.dailyPeaks.contains(where: { $0 != 0 }) {
                Chart(Array(r.dailyPeaks.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("day", i), y: .value("peak", v)).foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 40)
            }
            ForEach(Stats.Presentation.recordRows(r), id: \.label) { row in
                LabeledContent(row.label, value: Stats.Presentation.perMinute(row.count, theme: app.rowTheme))
                    .font(.caption).monospacedDigit()
            }
        }
    }

    // MARK: rhythm

    /// One heatmap cell. Its own function with typed locals: inlined,
    /// the fill maths plus three string interpolations was one
    /// expression CI's compiler gave up type-checking (#249).
    private func heatCell(day: String, hour: Int, count: Int, peak: Int) -> some View {
        let alpha: Double = 0.08 + 0.92 * Double(count) / Double(peak)
        let when: String = "\(day) \(hour):00"
        let entries: String = "\(count) entries"
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor.opacity(alpha))
            .frame(height: 12)
            .help("\(when) — \(entries)")
            .accessibilityLabel(when)
            .accessibilityValue(entries)   // the tooltip is mouse-only
    }

    private func heatmap(_ raw: [Int]) -> some View {
        // `model.summaries` is never compacted (that's the exporter's
        // form, which empties `hours`) — but index math on a 168-slot
        // array is not worth a trap if that ever changes.
        let hours = raw.count == 168 ? raw : Array(repeating: 0, count: 168)
        let peak = max(1, hours.max() ?? 1)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return VStack(alignment: .leading, spacing: 3) {
            Text("Activity by hour").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 2) {
                    Text(days[d]).font(.caption2).monospacedDigit().frame(width: 28, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        heatCell(day: days[d], hour: h, count: hours[d * 24 + h], peak: peak)
                    }
                }
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h):00").font(.caption2).foregroundStyle(.tertiary)
                    if h != 18 { Spacer() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionLengths(_ s: Stats.Summary) -> some View {
        let rows = Stats.Presentation.sessionLengthRows(s)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Session lengths").font(.caption).foregroundStyle(.secondary)
            Chart(rows, id: \.label) { row in
                BarMark(x: .value("Sessions", row.count), y: .value("Bucket", row.label))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
            HStack {
                Spacer()
                Text(Stats.Presentation.sessionTimeLine(s))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: effort (Stats v2)

    private func effort(_ s: Stats.Summary) -> some View {
        Section("Where the effort went") {
            rows("Activity", Stats.Presentation.activityRows(s))
            rows("Model", Stats.Presentation.modelRows(s))
            rows("Engine", Stats.Presentation.engineRows(s))
            rows("Effort", Stats.Presentation.effortRows(s))
            Text(Stats.Presentation.activityFootnote).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func rows(_ title: String, _ rows: [Stats.Presentation.Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            // A GridRow can't wear a modifier (it collapses to one cell — CLAUDE.md);
            // the Group inside distributes it to every cell.
            GridRow {
                Group { Text(title); Text("Stretches"); Text("Time"); Text("Tokens"); Text("Cached"); Text("Spend"); Text("Share") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                // Outside a GridRow, sized via CLAUDE.md's Grid fact rather
                // than `.gridCellColumns` (which needs a row to span).
                Text("Nothing yet this period").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridCellUnsizedAxes(.horizontal)
            }
            ForEach(rows) { r in
                GridRow {
                    Text(r.id).lineLimit(1)
                    Text(r.count.formatted()).monospacedDigit()
                    Text(r.minutesText).monospacedDigit()
                    Text(r.tokensText).monospacedDigit()
                    Text(r.cachedPercentText).monospacedDigit()
                    Text(r.usdText).monospacedDigit()
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6))
                            .frame(width: max(2, 80 * r.share), height: 8)
                    }
                    .frame(width: 80, height: 8)
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension StatsPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Stats", section: "Period", label: "Period",
                            keywords: ["week", "month", "year", "period", "streak"], anchor: "Stats/Period"),
        SettingsSearchEntry(pane: "Stats", section: "Rhythm", label: "Rhythm",
                            keywords: ["heatmap", "hours", "session lengths", "rhythm"], anchor: "Stats/Rhythm"),
    ]
}
