import Foundation

/// Port of `apps/web/src/timestampFormat.ts`'s `formatRelativeTime` +
/// `formatRelativeTimeLabel`, composed with `Sidebar.tsx`'s own
/// `compactSidebarTimeLabel` — the exact chain `threadTimeLabel`/
/// `settledTimeLabel` run for a sidebar row's trailing time: "just now" →
/// "now", "Xm ago" → "Xm", "Xh ago" → "Xh", "Xd ago" → "Xd". Pure elapsed-
/// duration math (`Date.now() - date.getTime()`), no `Intl`/calendar
/// involved, so unlike `T3ThreadSettled.snoozePresets` there is nothing to
/// pin a Calendar/TimeZone against here. Upstream never falls back to an
/// absolute calendar date — days simply keep counting up.
public enum T3RelativeTime {
    public static func label(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }               // covers the clock-skew (negative) case too
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}
