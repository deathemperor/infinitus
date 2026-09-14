import Foundation

// MARK: - Footer-chip state (#9 phase D2)
//
// The two footer chips' portable state, shared by the Mac app, the
// InfinitusUI chips and the Linux tray's panel. The fleet-mirror snapshot
// that once carried them to a phone left with the mirror servers (#1041,
// #1219).

/// The auto-switch engine's state as the footer badge shows it — the
/// portable half of `EngineSupervisor.State`, which can't cross to iOS
/// (the supervisor spawns a subprocess and is `#if !os(iOS)`).
public enum EngineBadge: Codable, Sendable, Equatable {
    case running
    case refused              // another engine holds the mutex
    case backingOff(seconds: Double)
    case schemaMismatch
    case stopped
}

/// Anthropic's status-page indicator, mirrored so the phone's footer
/// chip says what the Mac's `ServiceStatusModel` fetched (the model
/// itself is mac-only: URLSession polling + NSWorkspace).
public struct ServiceStatusSummary: Codable, Sendable, Equatable {
    /// none | minor | major | critical; nil before the first fetch.
    public let indicator: String?

    public init(indicator: String?) {
        self.indicator = indicator
    }

    /// Same wording as ServiceStatusModel.shortText on the mac.
    public var shortText: String {
        switch indicator {
        case "none": return "claude ok"
        case "minor": return "minor outage"
        case "major": return "major outage"
        case "critical": return "critical outage"
        default: return "status"
        }
    }
}
