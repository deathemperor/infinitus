import SwiftUI
import InfinitusCore
#if os(macOS)
import AppKit
#endif

/// The prediction line (2026-09-03): at the measured pace, when each
/// window of the active account hits its limit and when the fleet is
/// out. Clock times, never a ticking countdown (a per-second text tick
/// is what the heap-growth gate exists for). Gauge names come from the
/// row theme so the RPG face reads "MP"/"HP", not "5h"/"7d". Hidden
/// when nothing is projected. The tooltip carries the pace and basis.
public struct UsageForecastLine<M: FleetModel>: View {
    @ObservedObject var model: M

    public init(model: M) {
        self.model = model
    }

    @ViewBuilder public var body: some View {
        if let f = model.forecast, let text = summary(f) {
            // The line is the door to the dashboard (user 2026-09-03 "link
            // from 'at this pace' to view full" … "nobody knows it's
            // clickable"): a visible link tail, underlined, hand cursor.
            (Text(Image(systemName: "hourglass"))
                .foregroundStyle(.orange)
             + Text(" " + text + "  ")
             + Text("Full forecast ›").foregroundStyle(Color.accentColor).underline())
                .font(PopupFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(help(f) + "\n\nClick for the full forecast.")
                .contentShape(Rectangle())
                .onTapGesture { model.openForecast() }
                .pointingHandCursor()
        }
    }

    private func summary(_ f: UsageForecast) -> String? {
        let clauses = ForecastWords.clauses(f, theme: model.rowTheme)
        guard !clauses.isEmpty else { return nil }
        let paces = ForecastWords.paces(f, theme: model.rowTheme)
        return "At this pace" + (paces.isEmpty ? "" : " (\(paces))") + ": " + clauses.joined(separator: " · ")
    }

    private func help(_ f: UsageForecast) -> String {
        let theme = model.rowTheme
        let paces = (f.active?.windows ?? []).map { w -> String in
            let rate = w.ratePctPerHour.map { ForecastWords.rate($0) } ?? "pace unknown"
            let fate = w.hitsAt == nil && w.ratePctPerHour != nil ? " — resets before it fills" : ""
            return "\(ForecastWords.gaugeName(w.name, theme: theme)): \(Int(w.pct.rounded()))% used, \(rate)\(fate)"
        }
        return (paces + ["Estimate. " + f.basis]).joined(separator: "\n")
    }
}

/// The words behind the forecast line, off the generic view so the pane
/// and the phone can call them without a model type.
public enum ForecastWords {
    public static func gaugeName(_ window: String, theme: RowTheme) -> String {
        window == "5h" ? theme.sessionLabel : window == "7d" ? theme.weeklyLabel : window
    }

    /// "MP 39%/h · HP 4%/h · Fable 4.7%/h" — the paces the line rests on
    /// (user 2026-09-03: "'at this pace' — what pace?").
    public static func paces(_ f: UsageForecast, theme: RowTheme) -> String {
        (f.active?.windows ?? []).compactMap { w in
            w.ratePctPerHour.map { "\(gaugeName(w.name, theme: theme)) \(rate($0))" }
        }.joined(separator: " · ")
    }

    /// Public so the pane and the phone can render the same words.
    public static func clauses(_ f: UsageForecast, theme: RowTheme, now: Date = Date()) -> [String] {
        var out: [String] = []
        for w in f.active?.windows ?? [] {
            guard let at = w.hitsAt else { continue }
            out.append("\(gaugeName(w.name, theme: theme)) out \(ForecastClock.label(at, now: now))")
        }
        if let dead = f.allDeadAt {
            out.append("all accounts out \(ForecastClock.label(dead, now: now))")
        }
        return out
    }

    public static func rate(_ pctPerHour: Double) -> String {
        pctPerHour >= 10 ? String(format: "%.0f%%/h", pctPerHour) : String(format: "%.1f%%/h", pctPerHour)
    }

}

/// "now", "~4:12 PM" today, "~Fri 9:00 AM" inside a week, else a date.
public enum ForecastClock {
    public static func label(_ epoch: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        if date.timeIntervalSince(now) <= 30 { return "now" }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        if Calendar.current.isDate(date, inSameDayAs: now) {
            f.dateStyle = .none
            f.timeStyle = .short
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d jmm")
        }
        return "~" + f.string(from: date)
    }
}

extension View {
    /// The hand cursor a link gets on the Mac; nothing on the phone.
    func pointingHandCursor() -> some View {
        #if os(macOS)
        return onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
        #else
        return self
        #endif
    }
}
