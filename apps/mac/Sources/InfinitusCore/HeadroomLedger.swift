import Foundation

/// Persists the last headroom verdict across a relaunch (#616 remainder
/// 2). Without it, `FleetState.headroom` starts nil on launch and the
/// first judgement runs with `previous: nil`: an account sitting inside
/// the band — held `low` before the relaunch — reads `abundant` for one
/// poll, so the fork releases every held thread and then holds them
/// again on the next line crossing. One entry per fleet, replaced on
/// every change and removed when the verdict goes nil.
public enum HeadroomLedger {
    public struct Entry: Codable, Sendable, Equatable {
        public let fleetKey: String
        public let email: String
        public let headroom: Headroom

        public init(fleetKey: String, email: String, headroom: Headroom) {
            self.fleetKey = fleetKey
            self.email = email
            self.headroom = headroom
        }
    }

    public static func encode(fleetKey: String, email: String, headroom: Headroom) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Entry(fleetKey: fleetKey, email: email, headroom: headroom))
    }

    /// The stored verdict iff it decodes and both `fleetKey` and `email`
    /// match the caller's — a nil or mismatched email, a mismatched fleet
    /// key, or data that fails to decode all say nothing rather than seed
    /// the wrong account's hysteresis.
    public static func seed(_ data: Data?, fleetKey: String, email: String?) -> Headroom? {
        guard let data, let email,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fleetKey == fleetKey, entry.email == email else { return nil }
        return entry.headroom
    }
}
