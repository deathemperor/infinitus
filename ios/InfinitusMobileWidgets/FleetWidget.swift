import InfinitusCore
import InfinitusUI
import SwiftUI
import WidgetKit

/// Home-screen and lock-screen widgets in the fleet's theme (#80): the
/// active account's windows as the theme names and colors them, what's
/// waiting, the revival countdown when every account is limited. Drawn
/// from the states the Live Activities use, read from WidgetBridge.
struct FleetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "run.infinitus.mobile.fleet", provider: FleetProvider()) { entry in
            FleetWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "infinitus://sessions"))
        }
        .configurationDisplayName("Fleet")
        .description("The active account's windows in your theme, and what's waiting on you.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct FleetEntry: TimelineEntry {
    let date: Date
    let payload: WidgetBridge.Payload?
    /// Nothing has reached the phone for a while — the numbers are what
    /// the Mac last said.
    var stale: Bool {
        guard let payload else { return false }
        return date.timeIntervalSince(payload.capturedAt) > LiveActivityBuilder.workingStale
    }
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: Date(), payload: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        completion(FleetEntry(date: Date(), payload: WidgetBridge.load() ?? Self.sample))
    }

    /// One entry now and one at the stale mark; the app reloads the
    /// timeline whenever a refresh changed something.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        let now = Date()
        let payload = WidgetBridge.load()
        var entries = [FleetEntry(date: now, payload: payload)]
        if let payload {
            let staleAt = payload.capturedAt.addingTimeInterval(LiveActivityBuilder.workingStale + 1)
            if staleAt > now { entries.append(FleetEntry(date: staleAt, payload: payload)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    /// The gallery's preview: an RPG-themed account mid-quest.
    static let sample = WidgetBridge.Payload(
        working: WorkingActivityState(
            active: "Infinitus", icon: "👑", slot: "P2", plan: "Lv 20x", cash: nil,
            windows: [ActivityWindow(label: "MP", color: "blue", pct: 22, reset: "4h47m"),
                      ActivityWindow(label: "HP", color: "red", pct: 5, reset: "2d12h"),
                      ActivityWindow(label: "Dragon", color: "purple", pct: 4, reset: "2d12h")],
            binding: 0, busy: 3, total: 10, waiting: 1, next: nil,
            tokensPerMinute: 6400, tokenFraction: 0.4, accent: "yellow", plain: false),
        revival: nil, machine: "Mac", capturedAt: Date())
}

struct FleetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FleetEntry

    var body: some View {
        if let payload = entry.payload, let state = payload.working {
            switch family {
            case .systemSmall: SmallFleet(state: state, revival: payload.revival, stale: entry.stale)
            case .accessoryCircular: CircularFleet(state: state)
            case .accessoryRectangular: RectangularFleet(state: state)
            case .accessoryInline: InlineFleet(state: state)
            default: MediumFleet(state: state, revival: payload.revival, stale: entry.stale)
            }
        } else {
            Text("Open Infinitus to pair with your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// The revival line for an all-dead fleet, or the sessions line.
private struct FooterLine: View {
    let state: WorkingActivityState
    let revival: RevivalActivityState?
    let stale: Bool
    var body: some View {
        if let revival, !revival.revived, revival.revivesAt > Date() {
            HStack(spacing: 4) {
                Text(revival.reviveWord)
                Text(timerInterval: Date()...revival.revivesAt, countsDown: true)
                    .monospacedDigit()
            }
            .font(.caption2).foregroundStyle(ThemeColor.resolve(revival.accent))
            .lineLimit(1)
        } else {
            HStack {
                Text(sessionsLine(state)).lineLimit(1)
                Spacer(minLength: 0)
                if stale { Text("out of date") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SmallFleet: View {
    let state: WorkingActivityState
    let revival: RevivalActivityState?
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = state.icon { Text(icon) }
                Text(state.active).font(.headline).lineLimit(1)
                    .foregroundStyle(ThemeColor.resolve(state.accent))
            }
            ForEach(Array(state.windows.prefix(3).enumerated()), id: \.offset) { _, window in
                SmallGauge(window: window, plain: state.plain)
            }
            Spacer(minLength: 0)
            FooterLine(state: state, revival: revival, stale: stale)
        }
    }
}

/// "MP ▮▮▮▯ 78%": label, bar, what's left — or the plain theme's text.
private struct SmallGauge: View {
    let window: ActivityWindow
    let plain: Bool
    var body: some View {
        let color = ThemeColor.resolve(window.color)
        let remaining = max(0, 100 - window.pct)
        HStack(spacing: 6) {
            Text(window.label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                .frame(width: 44, alignment: .leading).lineLimit(1)
            if !plain {
                GaugeBar(remaining: remaining, color: color, animated: false)
                    .frame(height: 7)
            }
            Text("\(Int(remaining))%").font(.caption2).monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
        }
    }
}

private struct MediumFleet: View {
    let state: WorkingActivityState
    let revival: RevivalActivityState?
    let stale: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let icon = state.icon { Text(icon).font(.title) }
                Text(state.active).font(.headline).lineLimit(1)
                    .foregroundStyle(ThemeColor.resolve(state.accent))
                Text(state.slot).font(.caption).foregroundStyle(.secondary)
                if let plan = state.plan {
                    Text(plan).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.fill.secondary, in: Capsule())
                }
                if let cash = state.cash { Text(cash).font(.caption).foregroundStyle(.yellow) }
                Spacer(minLength: 0)
            }
            .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(Array(state.windows.enumerated()), id: \.offset) { _, window in
                        GridRow { WindowRow(window: window) }
                    }
                    if let tokens = state.tokensPerMinute {
                        GridRow { TokenRow(perMinute: tokens, fraction: state.tokenFraction, icon: state.rateIcon, unit: state.rateLabel) }
                    }
                }
                Spacer(minLength: 0)
                FooterLine(state: state, revival: revival, stale: stale)
            }
        }
    }
}

private struct CircularFleet: View {
    let state: WorkingActivityState
    var body: some View {
        let window = state.binding.map { state.windows[$0] } ?? state.windows.first
        let remaining = window.map { max(0, 100 - $0.pct) } ?? 0
        Gauge(value: remaining, in: 0...100) {
            Text(window?.label ?? "").font(.caption2)
        } currentValueLabel: {
            Text("\(Int(remaining))").font(.headline).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
    }
}

private struct RectangularFleet: View {
    let state: WorkingActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon = state.icon { Text(icon) }
                Text(state.active).font(.headline).lineLimit(1)
            }
            ForEach(Array(state.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                let remaining = max(0, 100 - window.pct)
                Gauge(value: remaining, in: 0...100) {
                    Text("\(window.label) \(Int(remaining))%").font(.caption2).monospacedDigit()
                }
                .gaugeStyle(.accessoryLinear)
            }
        }
    }
}

private struct InlineFleet: View {
    let state: WorkingActivityState
    var body: some View {
        let parts = state.windows.prefix(2).map { "\($0.label) \(Int(max(0, 100 - $0.pct)))%" }
            + (state.waiting > 0 ? ["\(state.waiting) waiting"] : [])
        Text("\(state.icon ?? "") \(parts.joined(separator: " · "))")
    }
}
