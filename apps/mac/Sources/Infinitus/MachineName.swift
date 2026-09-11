import Foundation

/// What the phone, the widgets and crash reports call this Mac (#99):
/// Settings › Sync's name when one is typed, else the computer name from
/// System Settings › General › About without the " (7)" macOS appends
/// after Bonjour name collisions.
enum MachineName {
    static let overrideKey = "machine_name"

    static func current(defaults: UserDefaults = .standard) -> String {
        let custom = (defaults.string(forKey: overrideKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? system() : custom
    }

    static func system() -> String {
        stripped(Host.current().localizedName ?? "Mac")
    }

    /// "MacBook Pro (7)" → "MacBook Pro".
    static func stripped(_ name: String) -> String {
        var trimmed = name
        while let suffix = trimmed.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            trimmed.removeSubrange(suffix)
        }
        return trimmed.isEmpty ? name : trimmed
    }
}
