import ActivityKit
import InfinitusCore
import InfinitusUI
import SwiftUI
import WidgetKit

@main
struct InfinitusWidgets: WidgetBundle {
    var body: some Widget {
        FleetWidget()
        RevivalLiveActivity()
        WorkingLiveActivity()
    }
}

// MARK: - #1 all-dead revival countdown

struct RevivalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RevivalActivity.self) { context in
            RevivalLockScreen(state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(URL(string: "infinitus://sessions"))
        } dynamicIsland: { context in
            let accent = ThemeColor.resolve(context.state.accent)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        if context.state.revived {
                            Text("\(context.state.icon ?? "")\(context.state.reviver) is back").font(.headline)
                        } else {
                            Text("All accounts \(context.state.deadWord)")
                                .font(.caption).foregroundStyle(accent)
                            Text(timerInterval: Date.now...context.state.revivesAt, countsDown: true)
                                .font(.system(.title, design: .rounded).weight(.semibold))
                                .monospacedDigit().multilineTextAlignment(.center)
                            Text("\(context.state.icon ?? "")\(context.state.reviver) \(context.state.reviveWord) · \(waitingLine(context.state))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !context.state.later.isEmpty {
                                Text("then " + context.state.later.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } compactLeading: {
                Text(context.state.icon ?? "⏳")
            } compactTrailing: {
                if context.state.revived {
                    Text("back").font(.caption2)
                } else {
                    Text(timerInterval: Date.now...context.state.revivesAt, countsDown: true)
                        .monospacedDigit().font(.caption2).frame(maxWidth: 52)
                        .foregroundStyle(accent)
                }
            } minimal: {
                Image(systemName: "hourglass").foregroundStyle(accent)
            }
        }
    }
}

private struct RevivalLockScreen: View {
    let state: RevivalActivityState
    var body: some View {
        let accent = ThemeColor.resolve(state.accent)
        HStack(spacing: 14) {
            Text(state.icon ?? "⏳").font(.title)
            VStack(alignment: .leading, spacing: 3) {
                if state.revived {
                    Text("\(state.reviver) is back").font(.headline)
                } else {
                    Text("All accounts \(state.deadWord)").font(.caption).foregroundStyle(accent)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.reviver).font(.headline)
                        Text("\(state.reviveWord) in").font(.caption).foregroundStyle(.secondary)
                        Text(timerInterval: Date.now...state.revivesAt, countsDown: true)
                            .font(.headline).monospacedDigit().foregroundStyle(accent)
                    }
                    Text(waitingLine(state)).font(.caption2).foregroundStyle(.secondary)
                    if !state.later.isEmpty {
                        Text("then " + state.later.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - #2 working sessions

struct WorkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkingActivity.self) { context in
            WorkingLockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
                .widgetURL(URL(string: "infinitus://sessions"))
        } dynamicIsland: { context in
            let state = context.state
            let binding = state.binding.map { state.windows[$0] }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        if let icon = state.icon { Text(icon) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.active).font(.headline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(state.slot)
                                if let plan = state.plan { Text(plan) }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(state.busy) working").font(.headline).monospacedDigit()
                        if let cash = state.cash {
                            Text(cash).font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                            ForEach(Array(state.windows.enumerated()), id: \.offset) { _, window in
                                GridRow { WindowRow(window: window) }
                            }
                            if let tokens = state.tokensPerMinute {
                                GridRow { TokenRow(perMinute: tokens, fraction: state.tokenFraction, icon: state.rateIcon, unit: state.rateLabel) }
                            }
                        }
                        HStack {
                            Text(sessionsLine(state)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let next = state.next {
                                Text(next).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } compactLeading: {
                Text(state.icon ?? "∞")
            } compactTrailing: {
                if let binding {
                    Text("\(binding.label) \(Int(max(0, 100 - binding.pct)))%")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(ThemeColor.resolve(binding.color))
                } else {
                    Text("\(state.busy)").font(.caption2).monospacedDigit()
                }
            } minimal: {
                Text(binding.map { "\(Int(max(0, 100 - $0.pct)))" } ?? "∞")
                    .font(.caption2).monospacedDigit()
            }
        }
    }
}

private struct WorkingLockScreen: View {
    let state: WorkingActivityState
    /// Past the stale date: nothing has reached the card for a while —
    /// the account and the counts are what the Mac last said.
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = state.icon { Text(icon).font(.title3) }
                Text(state.active).font(.headline).lineLimit(1)
                Text(state.slot).font(.caption).foregroundStyle(.secondary)
                if let plan = state.plan {
                    Text(plan).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                Spacer()
                if let cash = state.cash {
                    Text(cash).font(.caption).foregroundStyle(.yellow)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(Array(state.windows.enumerated()), id: \.offset) { _, window in
                    GridRow { WindowRow(window: window) }
                }
                if let tokens = state.tokensPerMinute {
                    GridRow { TokenRow(perMinute: tokens, fraction: state.tokenFraction, icon: state.rateIcon, unit: state.rateLabel) }
                }
            }
            HStack {
                Text(sessionsLine(state)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if stale {
                    Text("out of date").font(.caption2).foregroundStyle(.secondary)
                } else if let next = state.next {
                    Text(next).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}

/// One themed gauge row — "MP ▮▮▮▯ 73% 4h20m·17:49", the popup's cell,
/// as three grid cells so every bar starts on the same column.
struct WindowRow: View {
    let window: ActivityWindow
    var body: some View {
        let color = ThemeColor.resolve(window.color)
        Text(window.label).font(.caption.weight(.semibold)).foregroundStyle(color)
        // GaugeBar draws the remaining % itself, the popup's way
        // (HP left, not damage taken).
        // A flexible width with a floor: a fixed 120 pt clipped the
        // reset text at accessibility sizes.
        GaugeBar(remaining: max(0, 100 - window.pct), color: color, animated: false)
            .frame(minWidth: 60, idealWidth: 120, maxWidth: 160, minHeight: 8, maxHeight: 8)
        Text(window.reset ?? "").font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
    }
}

/// "⚡ ▮▮▯ 1.2k/min" — the popup footer's tokens/minute gauge.
struct TokenRow: View {
    let perMinute: Int
    let fraction: Double
    var icon: String? = nil
    var unit: String? = nil
    var body: some View {
        if let icon {
            Text(icon).font(.caption)
        } else {
            Image(systemName: "bolt.horizontal.fill").font(.caption).foregroundStyle(.yellow)
        }
        TokenRateBar(fraction: fraction)
            .frame(minWidth: 60, idealWidth: 120, maxWidth: 160, minHeight: 6, maxHeight: 6)
        Text(perMinute >= 1000 ? String(format: "%.1fk \(unit ?? "tok/min")", Double(perMinute) / 1000)
                               : "\(perMinute) \(unit ?? "tok/min")")
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }
}

func sessionsLine(_ state: WorkingActivityState) -> String {
    var line = "\(state.busy) working · \(state.total) session\(state.total == 1 ? "" : "s")"
    if state.waiting > 0 { line += " · \(state.waiting) waiting on you" }
    return line
}

/// "4 stopped, waiting to resume · 12 sessions" (or just the count).
private func waitingLine(_ state: RevivalActivityState) -> String {
    state.waiting > 0
        ? "\(state.waiting) stopped, waiting to resume · \(state.sessions) sessions"
        : "\(state.sessions) session\(state.sessions == 1 ? "" : "s")"
}
