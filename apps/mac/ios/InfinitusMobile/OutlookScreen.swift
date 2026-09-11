import InfinitusCore
import InfinitusUI
import SwiftUI

/// The forecast in full (user 2026-09-03 "'at this pace' what pace? …
/// need a full detail dashboard"): every window of the active account
/// with its measured pace, ETA to the limit and reset; the fleet-wide
/// all-dead projection; the battle plan's steps; and what the numbers
/// rest on. Everything comes from the Mac's snapshot (`forecast`,
/// `plan`); the Mac's Utilization pane is the long form.
struct OutlookScreen: View {
    @ObservedObject var model: MirrorModel

    var body: some View {
        List {
            if let forecast = model.forecast {
                // Every account with its own measured paces (newer Macs);
                // older ones only project the active account.
                let lines = forecast.accounts ?? forecast.active.map { [$0] } ?? []
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Section {
                        ForEach(Array(line.windows.enumerated()), id: \.offset) { _, window in
                            windowRow(window)
                        }
                        if let binds = line.bindsWindow, let at = line.bindsAt {
                            Text("\(ForecastWords.gaugeName(binds, theme: model.rowTheme)) binds first, \(ForecastClock.label(at))")
                                .font(.caption).foregroundStyle(.orange).monospacedDigit()
                        }
                    } header: {
                        Text("\(accountName(line.number, line.email))"
                             + (line.active ? " · active" : line.disabled ? " · held" : "")
                             + (index == 0 ? " · at this pace" : ""))
                    } footer: {
                        if index == lines.count - 1 { paceFooter }
                    }
                }
                if lines.isEmpty {
                    Section {
                        Text("No projection yet — the Mac needs about an hour of usage samples.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Fleet") {
                    LabeledContent("All accounts out") {
                        Text(forecast.allDeadAt.map { ForecastClock.label($0) } ?? "no weekly pace yet")
                    }
                    if let order = forecast.drainOrder, !order.isEmpty {
                        LabeledContent("Drain order") {
                            Text(order.map { n in
                                model.accounts.first { $0.number == n }.map(LiveActivityBuilder.name(of:)) ?? "#\(n)"
                            }.joined(separator: " → ")).multilineTextAlignment(.trailing)
                        }
                    }
                    if let rate = model.snapshot?.tokenRate, rate.perMinute > 0 {
                        LabeledContent("Output tokens now") {
                            Text("\(rate.label(theme: model.rowTheme)) · peak \(rate.peakPerMinute)/min").monospacedDigit()
                        }
                    }
                    Text(forecast.basis).font(.caption).foregroundStyle(.secondary)
                    Text("computed \(Date(timeIntervalSince1970: forecast.computedAt).formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else {
                Text("No projection yet — the Mac needs about an hour of usage samples.")
                    .foregroundStyle(.secondary)
            }
            if let plan = model.battlePlan {
                Section {
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ForecastClock.label(step.at)).monospacedDigit().font(.subheadline.weight(.semibold))
                                Text(stepTitle(step.action)).font(.subheadline)
                            }
                            Text(step.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Battle plan · binds \(ForecastClock.label(plan.bindAt))")
                }
            }
        }
        .navigationTitle("Outlook")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var paceFooter: some View {
        Text("Pace = measured % per hour of each window, per account: the 5h window "
             + "over the last hour, weekly and per-model windows over the last 24 h. "
             + "ETA assumes the pace holds; a reset that lands first clears the window "
             + "instead. The fleet projection drains weekly headroom account by account "
             + "at the active account's pace.")
    }

    @ViewBuilder private func windowRow(_ window: UsageForecast.Window) -> some View {
        let theme = model.rowTheme
        let label = window.name == "5h" ? (theme.plain ? "5h" : PopupGlyph.text(theme.sessionLabel))
            : window.name == "7d" ? (theme.plain ? "7d" : PopupGlyph.text(theme.weeklyLabel))
            : (theme.plain ? window.name : PopupGlyph.text(theme.scopedPrefix) + theme.modelName(window.name))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text("\(Int(window.pct))% used").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(100, max(0, window.pct)), total: 100)
                .tint(window.pct >= 90 ? .red : window.pct >= 70 ? .orange : .accentColor)
            HStack(spacing: 12) {
                Text(window.ratePctPerHour.map { String(format: "%.1f %%/h", $0) } ?? "pace unknown")
                if let hits = window.hitsAt {
                    Text("out ~\(ForecastClock.label(hits))")
                } else if window.ratePctPerHour != nil {
                    Text("reset lands first")
                }
                if let resets = window.resetsAt {
                    Text("resets \(ForecastClock.label(resets))")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func accountName(_ number: Int, _ email: String) -> String {
        model.accounts.first { $0.number == number }
            .map(LiveActivityBuilder.name(of:)) ?? String(email.prefix(while: { $0 != "@" }))
    }

    private func stepTitle(_ action: WindowPlanner.Action) -> String {
        let name = model.accounts.first { $0.number == action.number }.map(LiveActivityBuilder.name(of:))
            ?? "#\(action.number)"
        switch action {
        case .ignite: return "ignite \(name) (start its 5h clock)"
        case .switchTo: return "switch to \(name)"
        case .hold: return "hold \(name)"
        case .reset: return "\(name)'s window resets"
        }
    }
}
