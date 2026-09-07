import Foundation

/// This Mac's stable id for the descriptor (#223 phase 4): a UUID minted
/// once and kept in UserDefaults. No Mac-side identity existed before —
/// the multi-Mac mirror's `MacPairing.id` is phone-local.
public enum MachineIdentity {
    public static let defaultsKey = "machine_id"
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: defaultsKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}

/// `GET /.well-known/infinitus` (#223 phase 4), unauthenticated — what
/// this Mac supports, read before pairing, T3's
/// `/.well-known/t3/environment` (`packages/contracts/src/environmentHttp.ts`).
/// Capabilities are optional booleans: absent means unsupported, so a
/// phone hides a feature on version skew instead of failing to decode.
public struct MirrorDescriptor: Codable, Sendable, Equatable {
    public struct Capabilities: Codable, Sendable, Equatable {
        public var timeline: Bool?
        public var sequence: Bool?
        public var attention: Bool?
        public var leases: Bool?
        public var ownedSessions: Bool?
        public var checkpoints: Bool?
        public var team: Bool?
        public var pastSessions: Bool?
        public var images: Bool?
        public init(timeline: Bool? = nil, sequence: Bool? = nil, attention: Bool? = nil, leases: Bool? = nil,
                    ownedSessions: Bool? = nil, checkpoints: Bool? = nil, team: Bool? = nil,
                    pastSessions: Bool? = nil, images: Bool? = nil) {
            self.timeline = timeline; self.sequence = sequence; self.attention = attention; self.leases = leases
            self.ownedSessions = ownedSessions; self.checkpoints = checkpoints; self.team = team
            self.pastSessions = pastSessions; self.images = images
        }
    }
    public let machineId: String
    public let label: String
    public let platform: String
    public let appVersion: String
    public let capabilities: Capabilities

    public init(machineId: String, label: String, platform: String, appVersion: String, capabilities: Capabilities) {
        self.machineId = machineId; self.label = label; self.platform = platform
        self.appVersion = appVersion; self.capabilities = capabilities
    }

    /// This build's truth; `leases` arrives with phase 5.
    public static func current(machineId: String, label: String, appVersion: String) -> MirrorDescriptor {
        #if os(macOS)
        let platform = "macos"
        #elseif os(Linux)
        let platform = "linux"
        #else
        let platform = "other"
        #endif
        return MirrorDescriptor(machineId: machineId, label: label, platform: platform, appVersion: appVersion,
                                capabilities: Capabilities(timeline: true, sequence: true, attention: true,
                                                           ownedSessions: true, checkpoints: true, team: true,
                                                           pastSessions: true, images: true))
    }
}
