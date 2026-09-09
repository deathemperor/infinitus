import SwiftUI
import Charts
import InfinitusCore
import InfinitusUI

/// The Usage tab (`UsageRouteScreen.tsx` at upstream 6c583620f: ChartCard,
/// ProviderSection, TotalsSection, ModelsSection) over `T3UsageCost.Merged`.
/// Drift the wire forces, on purpose: no period or Cost/Tokens toggles
/// (the engine's `days` is fixed and a day carries no tokens), no cache
/// savings (the price table names no rates), and the Providers card is an
/// Accounts card because one engine report is one provider.
struct T3UsageCostTab: View {
    let merged: T3UsageCost.Merged
    /// One colour per `merged.seriesNames` entry, the chart's stack order.
    let seriesColors: [Color]
    @Environment(\.t3) private var t3

    private static let chartHeight: CGFloat = 180

    var body: some View {
        let p = t3.mobile
        chartCard
        section("Accounts") {
            ForEach(Array(merged.accounts.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle().fill(color(row.series)).frame(width: 10, height: 10)
                            Text(row.name).font(T3Font.mobile(.lg)).foregroundStyle(p.foreground.color).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(T3UsageCost.formatUsd(row.costUsd)).font(T3Font.mobile(.lg)).monospacedDigit()
                            .foregroundStyle(p.foreground.color)
                    }
                    GeometryReader { geo in
                        Capsule().fill(color(row.series)).frame(width: geo.size.width * row.share)
                    }
                    .frame(height: 4)
                    .background(p.subtle.color, in: Capsule())
                    Text("\(T3UsageCost.formatPercent(row.share)) of cost · \(T3UsageCost.formatTokens(Double(row.tokens))) tokens")
                        .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                }
                .padding(16)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(p.borderSubtle.color).frame(height: 1) } }
            }
        }
        section("Totals") {
            let cells = totals
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 0, alignment: .topLeading)], spacing: 0) {
                ForEach(cells, id: \.label) { cell in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.label).font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                        Text(cell.value).font(T3Font.mobile(.xl, .medium)).monospacedDigit().foregroundStyle(p.foreground.color)
                        Text(cell.detail).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
        if !merged.models.isEmpty {
            section("By model") {
                ForEach(Array(merged.models.enumerated()), id: \.element.model) { index, row in
                    HStack(spacing: 12) {
                        Circle().fill(color(0)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.model).font(T3Font.mobile(.base)).foregroundStyle(p.foreground.color).lineLimit(1)
                            Text("\(T3UsageCost.formatPercent(row.share)) of cost · \(T3UsageCost.formatCount(row.messages)) messages")
                                .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(T3UsageCost.formatUsd(row.costUsd)).font(T3Font.mobile(.base)).monospacedDigit()
                            .foregroundStyle(p.foreground.color)
                    }
                    .padding(16)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(p.borderSubtle.color).frame(height: 1) } }
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(merged.caveats, id: \.self) { caveat in
                Text(caveat).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
            }
            Text("An API-price estimate, never a bill.").font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
        }
        .padding(.horizontal, 4)
    }

    private func color(_ series: Int) -> Color {
        seriesColors.indices.contains(series) ? seriesColors[series] : t3.mobile.foreground.color
    }

    /// Headline figure, the daily stack, and the window's edge labels.
    private var chartCard: some View {
        let p = t3.mobile
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Raw token cost · last \(merged.days) days").font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                Text(T3UsageCost.formatUsd(merged.costUsd) + "*").font(T3Font.mobileLiteral(36, .bold)).monospacedDigit()
                    .foregroundStyle(p.foreground.color)
                Text("* if billed at full API rate").font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
            }
            if let daily = merged.daily {
                if merged.hasActivity {
                    Chart {
                        ForEach(daily, id: \.day) { day in
                            ForEach(Array(day.values.enumerated()), id: \.offset) { index, value in
                                BarMark(x: .value("Day", day.day), y: .value("Cost", value))
                                    .foregroundStyle(color(index))
                                    .cornerRadius(2)
                            }
                        }
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                    .frame(height: Self.chartHeight)
                } else {
                    Text("No activity in this window.").font(T3Font.mobile(.base)).foregroundStyle(p.foregroundMuted.color)
                        .frame(maxWidth: .infinity).frame(height: Self.chartHeight)
                }
                HStack(alignment: .center) {
                    Text(daily.first.map { T3UsageCost.formatDayShort($0.day) } ?? "")
                        .font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                    Spacer(minLength: 8)
                    if merged.seriesNames.count > 1 {
                        HStack(spacing: 16) {
                            ForEach(Array(merged.seriesNames.enumerated()), id: \.offset) { index, name in
                                HStack(spacing: 6) {
                                    Circle().fill(color(index)).frame(width: 8, height: 8)
                                    Text(name).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundMuted.color)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    Text(daily.last.map { T3UsageCost.formatDayShort($0.day) } ?? "")
                        .font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                }
            }
        }
        .padding(16)
        .background(p.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private struct Cell { let label: String, value: String, detail: String }

    private var totals: [Cell] {
        let perDay = merged.activeDays == 0 ? 0 : Double(merged.tokens) / Double(merged.activeDays)
        let cachedShare = merged.observedInput == 0 ? 0 : Double(merged.cacheRead) / Double(merged.observedInput)
        var cells = [
            Cell(label: "Processed tokens", value: T3UsageCost.formatTokens(Double(merged.tokens)),
                 detail: merged.daily == nil ? "across \(T3UsageCost.formatCount(merged.messages)) messages"
                                             : "\(T3UsageCost.formatTokens(perDay)) per active day"),
            Cell(label: "Cached input", value: T3UsageCost.formatTokens(Double(merged.cacheRead)),
                 detail: "\(T3UsageCost.formatPercent(cachedShare)) of observed input"),
            Cell(label: "Uncached input", value: T3UsageCost.formatTokens(Double(merged.input)),
                 detail: "\(T3UsageCost.formatTokens(Double(merged.cacheWrite))) cache writes"),
            Cell(label: "Output", value: T3UsageCost.formatTokens(Double(merged.output)),
                 detail: "across \(T3UsageCost.formatCount(merged.messages)) messages"),
        ]
        if let unpriced = merged.unpricedTokens {
            cells.append(Cell(label: "Unpriced", value: T3UsageCost.formatTokens(Double(unpriced)),
                              detail: "tokens excluded from cost"))
        }
        return cells
    }

    /// T3's `SettingsSection card`: a muted label over one card.
    private func section<Rows: View>(_ label: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foregroundMuted.color)
                .padding(.leading, 8)
            VStack(spacing: 0) { rows() }
                .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

/// `SegmentedControl` from `UsageRouteScreen.tsx`: a card-coloured pill,
/// the active thumb in `subtleStrong` sliding under the labels.
struct T3SegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selected: Value
    var compact = false
    @Environment(\.t3) private var t3

    var body: some View {
        let p = t3.mobile
        let height: CGFloat = compact ? 36 : 44
        let index = options.firstIndex { $0.value == selected } ?? 0
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let active = i == index
                Button { selected = option.value } label: {
                    Text(option.label)
                        .font(T3Font.mobile(compact ? .xs : .sm, active ? .medium : .regular))
                        .foregroundStyle(active ? p.foreground.color : p.foregroundMuted.color)
                        .frame(maxWidth: .infinity).frame(height: height)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .background {
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(max(1, options.count))
                Capsule().fill(p.subtleStrong.color)
                    .frame(width: w)
                    .offset(x: w * CGFloat(index))
                    .animation(.easeOut(duration: 0.2), value: index)
            }
        }
        .background(p.card.color, in: Capsule())
        .clipShape(Capsule())
    }
}
