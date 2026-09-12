import Foundation

/// The wait after an ignite (#7). The usage endpoint reports the window a
/// run opened minutes after the run: the forced fetch right behind the
/// igniter saw none on slot 6 (2026-09-12, reply at 23:43:52Z, window first
/// visible at the 23:53:56Z poll), the app guessed "resets now + 5h", and
/// the plan line offered the same account again — "doesn't work" (#338 was
/// the same report). So the app keeps asking for that one account on this
/// schedule until a 5h reset shows, and says it is waiting meanwhile.
public enum IgniteFollowUp {
    /// Seconds before each check: six fetches over ~13 minutes.
    public static let delays: [TimeInterval] = [15, 30, 60, 120, 240, 300]

    public static func waiting(_ name: String) -> String {
        "\(name)'s window started — waiting for its clock to show"
    }
    public static func clock(_ resets: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: resets)
    }
    public static func started(_ name: String, resets: Date) -> String {
        "\(name)'s window started — resets \(clock(resets))"
    }
    public static func unseen(_ name: String) -> String {
        "ignited \(name), but its clock has not shown after \(Int(delays.reduce(0, +)) / 60) min"
    }
}
