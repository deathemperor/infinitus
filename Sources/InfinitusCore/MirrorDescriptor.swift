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
        public var files: Bool?
        /// The PTY terminal (#507): true on the Mac since step 3's
        /// `TerminalHost`. The tray answers an explicit `false` — the same
        /// host is portable there but not wired yet — so a phone sees a
        /// considered no rather than a build that predates the field.
        public var terminal: Bool?
        /// `GET /prefs` (#558): the preference catalog with values.
        public var prefs: Bool?
        public init(timeline: Bool? = nil, sequence: Bool? = nil, attention: Bool? = nil, leases: Bool? = nil,
                    ownedSessions: Bool? = nil, checkpoints: Bool? = nil, team: Bool? = nil,
                    pastSessions: Bool? = nil, images: Bool? = nil, files: Bool? = nil, terminal: Bool? = nil,
                    prefs: Bool? = nil) {
            self.timeline = timeline; self.sequence = sequence; self.attention = attention; self.leases = leases
            self.ownedSessions = ownedSessions; self.checkpoints = checkpoints; self.team = team
            self.pastSessions = pastSessions; self.images = images; self.files = files; self.terminal = terminal
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

    /// This build's truth.
    public static func current(machineId: String, label: String, appVersion: String) -> MirrorDescriptor {
        #if os(macOS)
        let platform = "macos"
        // `TerminalHost` (#507 step 3) is in the Mac app target only.
        let terminal = true
        #elseif os(Linux)
        let platform = "linux"
        let terminal = false
        #else
        let platform = "other"
        let terminal = false
        #endif
        return MirrorDescriptor(machineId: machineId, label: label, platform: platform, appVersion: appVersion,
                                capabilities: Capabilities(timeline: true, sequence: true, attention: true, leases: true,
                                                           ownedSessions: true, checkpoints: true, team: true,
                                                           pastSessions: true, images: true, files: true, terminal: terminal,
                                                           prefs: true))
    }

    /// The Linux tray's truth (#486 slice 2, `infinitus-tray serve`):
    /// everything `.current()` claims for the Mac, minus what the tray
    /// doesn't answer yet — `files`, `timeline` and `sequence` are true
    /// (slice 1 gave the tray Files; slice 2 the timeline/sequence route).
    /// `checkpoints` is true since slice 3: the tray listens on a control
    /// socket, so the plugin's `UserPromptSubmit` hook writes a Linux
    /// session's checkpoints through `Checkpoints.snapshot` the way the
    /// Mac's hook path does, and the ladder the tray already served has
    /// something in it. Explicit `false` for the rest, not the nil the
    /// struct also accepts as "unknown", so a phone comparing builds sees a
    /// considered no rather than an older tray that predates the field.
    public static func tray(machineId: String, label: String, appVersion: String) -> MirrorDescriptor {
        MirrorDescriptor(machineId: machineId, label: label, platform: "linux", appVersion: appVersion,
                         capabilities: Capabilities(timeline: true, sequence: true, attention: true, leases: false,
                                                    ownedSessions: false, checkpoints: true, team: false,
                                                    pastSessions: false, images: true, files: true, terminal: false,
                                                    prefs: false))
    }
}
