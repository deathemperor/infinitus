import Foundation

/// One line of the app's durable event log (`events.jsonl`) — what the
/// Activity pane shows, kept so Stats can count switches and limits
/// over months.
public struct StatsEvent: Codable, Equatable, Sendable {
    public let at: Date
    public let kind: String
    public let icon: String
    public let text: String
    public init(at: Date, kind: String, icon: String, text: String) {
        self.at = at; self.kind = kind; self.icon = icon; self.text = text
    }
}

public enum StatsEvents {
    /// An all-out span is opened by `limit` and normally closed by the
    /// `revival` that ends it. When the app quits mid-span (or the
    /// revival never got logged) the next one can be days later, so the
    /// span is capped the same way the waiting clock is — 8 h, the
    /// longest stretch anyone credibly sat blocked.
    static let allOutCap = 8.0 * 3600

    public static func days(_ events: [StatsEvent], calendar: Calendar = .current) -> [String: Stats.Day] {
        var days: [String: Stats.Day] = [:]
        var allOutSince: Date?
        for e in events.sorted(by: { $0.at < $1.at }) {
            let key = Stats.dayKey(e.at, calendar: calendar)
            var d = days[key] ?? Stats.Day()
            // Anything that means an account is usable again ends the
            // span, not just `revival`: a switch or an ignite is proof
            // the fleet came back.
            func closeAllOut() {
                guard let since = allOutSince else { return }
                d.minutesLostToLimits += min(allOutCap, max(0, e.at.timeIntervalSince(since))) / 60
                allOutSince = nil
            }
            switch e.kind {
            case "switch":
                d.switches += 1
                closeAllOut()
            case "death": d.limitStops += 1
            // A second `limit` inside an open span is the same outage
            // still going — the span keeps its original start.
            case "limit": if allOutSince == nil { allOutSince = e.at }
            case "revival":
                d.revivals += 1
                closeAllOut()
            case "ignite":
                d.ignites += 1
                closeAllOut()
            case "resume", "nudge": d.resumes += 1
            default: break
            }
            days[key] = d
        }
        return days
    }
}
