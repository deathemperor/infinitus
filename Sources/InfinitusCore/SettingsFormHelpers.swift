import Foundation

/// Pure string helpers for settings forms (cswap config list --json) shared across platforms.
public enum SettingsFormLabels {
    public static func sectionTitle(_ prefix: String) -> String {
        switch prefix {
        case "autoswitch": return "Auto-switch"
        case "ui": return "Interface"
        case "misc": return "Misc"
        default: return prefix.prefix(1).uppercased() + prefix.dropFirst()
        }
    }

    /// "limitScanIntervalSeconds" -> "Limit scan interval seconds"
    /// "autoswitch.limitScanIntervalSeconds" -> "Limit scan interval seconds"
    public static func humanLabel(_ key: String) -> String {
        let tail = key.split(separator: ".").dropFirst().joined(separator: " ")
        let target = tail.isEmpty ? key : tail
        var words = ""
        for ch in target {
            if ch.isUppercase {
                words.append(" ")
                words.append(Character(ch.lowercased()))
            } else {
                words.append(ch)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Explanatory text for CLIProxy routing strategy and session affinity settings.
public enum ProxyRoutingNotes {
    public static func explainer(strategy: String?) -> String {
        switch strategy {
        case "round-robin":
            return "Each request goes to the next credential in turn."
        case "weighted-round-robin":
            return "Requests rotate in proportion to each credential's priority."
        case nil:
            return "Read from the proxy on the next refresh."
        default:
            return "Highest priority wins until it is rate-limited \u{2014} cswap's "
                + "consume-first. Switch in the Accounts tab raises a credential to the top."
        }
    }

    public static func affinityWarning(strategy: String?, affinity: Bool?) -> String? {
        guard strategy != nil, strategy != "fill-first" else { return nil }
        if affinity == nil {
            return "Turn on session-affinity in the proxy's config (this proxy has no "
                + "management route for it yet) so a conversation stays on one "
                + "credential: without it every request lands on a different account "
                + "and the prompt cache misses. Under affinity, Switch only steers "
                + "new sessions."
        } else if affinity == false {
            return "Turn on session affinity so a conversation stays on one credential: "
                + "without it every request lands on a different account and the "
                + "prompt cache misses."
        } else {
            return "Under affinity, Switch only steers new sessions; bound ones keep "
                + "their credential until the TTL lapses."
        }
    }
}
