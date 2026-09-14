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
        public var leases: Bool?
        /// `GET /prefs` (#558): the preference catalog with values.
        public var prefs: Bool?
        public init(leases: Bool? = nil, prefs: Bool? = nil) {
            self.leases = leases
            self.prefs = prefs
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

    /// The Linux tray's truth (#486 slice 2, `infinitus-tray serve`):
    /// explicit `false` for what the tray doesn't answer, not the nil the
    /// struct also accepts as "unknown", so a phone comparing builds sees a
    /// considered no rather than an older tray that predates the field.
    public static func tray(machineId: String, label: String, appVersion: String) -> MirrorDescriptor {
        MirrorDescriptor(machineId: machineId, label: label, platform: "linux", appVersion: appVersion,
                         capabilities: Capabilities(leases: false, prefs: false))
    }
}
