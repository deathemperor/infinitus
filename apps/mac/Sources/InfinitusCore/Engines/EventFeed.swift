import Foundation

/// One NDJSON line from `swapd auto --json`.
///
/// Deliberately generic — `kind` plus the raw object — because the engine's
/// vocabulary grows (engine-refused arrived 2026-08-28) and an unknown kind
/// must render as "an event we show generically", never a parse failure
/// (spec §2: unknown kinds are skipped, never fatal).
public struct EngineEvent: Sendable {
    public let kind: String
    public let ts: String?
    public let raw: [String: JSONValue]

    /// Best-effort one-liner for the event log view.
    public var summary: String {
        switch kind {
        case "switch":
            return "switched \(str("from", path: "email")) → \(str("to", path: "email"))"
        case "no-switch":
            return "no switch — \(str("reason").replacingOccurrences(of: "-", with: " "))"
        case "session-resumed":
            return "resumed \(str("sessionId"))"
        case "remote-control-rearmed":
            return "re-armed /rc on \(str("count")) session(s)"
        case "away-notified":
            if case .array(let items)? = raw["channels"] {
                let names = items.compactMap { item -> String? in
                    if case .string(let s) = item { return s }
                    return nil
                }
                if !names.isEmpty { return "pushed switch notice to \(names.joined(separator: ", "))" }
            }
            return "pushed switch notice"
        default:
            return kind.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// SF Symbol for the event-log row; unknown kinds get a plain dot.
    public var icon: String {
        switch kind {
        case "switch": return "arrow.triangle.2.circlepath"
        case "no-switch": return "hand.raised"
        case "poll": return "clock.arrow.circlepath"
        case "session-resumed": return "play.circle"
        case "remote-control-rearmed": return "antenna.radiowaves.left.and.right"
        case "away-notified": return "paperplane"
        case "account-unquarantined": return "arrow.uturn.up"
        case "all-exhausted": return "battery.0percent"
        default: return "circle.fill"
        }
    }

    private func str(_ key: String, path: String? = nil) -> String {
        var v = raw[key]
        if let path, case .object(let o)? = v { v = o[path] }
        if case .string(let s)? = v { return s }
        if case .number(let n)? = v { return String(n) }
        return "?"
    }
}

public enum EventLine: Sendable {
    case event(EngineEvent)
    /// The child speaks a newer schema; stop interpreting, keep it running.
    case schemaMismatch(Int)
    /// Unparseable line (or blank) — log and move on, never fatal.
    case garbage(String)
}

public enum EventFeed {
    public static let supportedSchemaVersion = 1

    public static func decode(line: String) -> EventLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = try? JSONDecoder().decode(
                  [String: JSONValue].self, from: Data(trimmed.utf8))
        else { return .garbage(line) }
        if case .number(let v)? = obj["schemaVersion"],
           Int(v) != supportedSchemaVersion {
            return .schemaMismatch(Int(v))
        }
        guard case .string(let kind)? = obj["event"] else { return .garbage(line) }
        var ts: String?
        if case .string(let t)? = obj["ts"] { ts = t }
        return .event(EngineEvent(kind: kind, ts: ts, raw: obj))
    }
}

/// Restart pacing for the supervised `swapd auto` child (spec §2):
/// exponential 1s→60s, reset by five clean minutes.
public struct SupervisorBackoff: Sendable {
    public init() {}
    private var exponent = 0

    public mutating func nextDelay() -> Double {
        let delay = min(pow(2.0, Double(exponent)), 60.0)
        exponent += 1
        return delay
    }

    public mutating func noteExit(afterCleanSeconds seconds: Double) {
        if seconds >= 300 { exponent = 0 }
    }
}
