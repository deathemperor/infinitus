import Foundation

// MARK: - Fleet mirror seam (#9)
//
// The mobile companion has no access to any machine's `cswap` binary —
// it reads a snapshot some Mac already captured. `listJSON` is the
// verbatim `cswap list --json` payload; consumers re-decode it with the
// existing `AccountList` decoder so the engine's models never need to
// grow Encodable conformance for this one seam.

public struct MirrorSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let machineName: String
    public let listJSON: Data
    public let sessions: [SessionPanelRow]
    /// Display prefs (#9 phase C1: "Follow Mac") — optional so snapshots
    /// captured before this field existed still decode.
    public let prefs: FleetPrefs?
    /// Verbatim `cswap usage --json` bytes (#9 phase D1a), same philosophy
    /// as `listJSON` — consumers re-decode with the existing `UsageReport`
    /// decoder. `nil` when the exporting side has no cash cache yet.
    public let usageJSON: Data?
    /// Footer-chip state (#9 phase D2). Runtime, not prefs — hence
    /// MirrorSnapshot rather than FleetPrefs. All optional: a pre-D2
    /// snapshot simply decodes them as nil and the chips drop out.
    public let serviceStatus: ServiceStatusSummary?
    public let engine: EngineBadge?
    /// Per-pid transcript progress for the sessions card, keyed by the
    /// session record's pid (`SessionDetail.pid` in `listJSON`).
    public let progressByPid: [Int: SessionProgress]?
    /// Every engine's last fleet (#8 multi-engine), in popup order —
    /// `listJSON` stays the primary cswap fleet for older phones; a
    /// phone that knows this field stacks one section per fleet.
    public let fleets: [EngineFleet]?
    /// Output tokens per minute across every live session, with the
    /// host's recent peak for the gauge scale.
    public let tokenRate: TokenRate?
    /// Run-rate projection for the primary fleet (2026-09-03) and the #7
    /// battle plan — both additive optionals; older phones ignore them.
    /// The plan is the view-side `Plan` (not the ctl `Payload`) so the
    /// phone's store hands it straight to the shared BattlePlanLine.
    public let forecast: UsageForecast?
    public let plan: WindowPlanner.Plan?
    /// Sessions whose AWS sign-in lapsed, with any login in flight
    /// (AwsLogin.swift, 2026-09-03). Additive optional.
    public let awsLogins: [AwsLogin.Item]?
    /// The Stats pane's four-period bundle (2026-09-04), day series
    /// dropped and its sets compacted so the whole thing stays small.
    /// Additive optional.
    public let stats: Stats.Bundle?
    /// Folders sessions have run in lately, newest first — the phone's
    /// repository picker for a new session (#91). Additive optional.
    public let recentCwds: [String]?
    /// True when the Mac pushes its alerts to phones over APNs (#86): a
    /// phone that registered an alert token then skips its own local
    /// "swapped to" banner, so the swap arrives once.
    public let pushesAlerts: Bool?
    /// This Mac's own version and update state (#121), so the phone's
    /// Settings can show both apps' versions and trigger the Mac's
    /// update. Additive optional — an old Mac's snapshot decodes nil.
    public let app: AppInfo?
    /// The Mac's team (Settings › Team) for the phone's Team tab (plan 8).
    /// Additive optional — a Mac without a team, or an older Mac, sends nil.
    public let team: TeamSnapshot?
    /// The Mac's saved session profiles (#165) — the phone's Start a
    /// session chips. Additive optional.
    public let profiles: [SessionProfile]?
    /// How Infinitus started each live session, by pid (#163/#165):
    /// profile, permission mode, resumed-from. Additive optional.
    public let births: [Int: SessionBirth]?

    public init(capturedAt: Date, machineName: String, listJSON: Data,
                sessions: [SessionPanelRow], prefs: FleetPrefs? = nil,
                usageJSON: Data? = nil,
                serviceStatus: ServiceStatusSummary? = nil,
                engine: EngineBadge? = nil,
                progressByPid: [Int: SessionProgress]? = nil,
                fleets: [EngineFleet]? = nil,
                tokenRate: TokenRate? = nil,
                forecast: UsageForecast? = nil,
                plan: WindowPlanner.Plan? = nil,
                awsLogins: [AwsLogin.Item]? = nil,
                stats: Stats.Bundle? = nil,
                recentCwds: [String]? = nil, pushesAlerts: Bool? = nil,
                app: AppInfo? = nil, team: TeamSnapshot? = nil, profiles: [SessionProfile]? = nil,
                births: [Int: SessionBirth]? = nil) {
        self.capturedAt = capturedAt
        self.machineName = machineName
        self.listJSON = listJSON
        self.sessions = sessions
        self.prefs = prefs
        self.usageJSON = usageJSON
        self.serviceStatus = serviceStatus
        self.engine = engine
        self.progressByPid = progressByPid
        self.fleets = fleets
        self.tokenRate = tokenRate
        self.forecast = forecast
        self.plan = plan
        self.awsLogins = awsLogins
        self.stats = stats
        self.recentCwds = recentCwds
        self.pushesAlerts = pushesAlerts
        self.app = app
        self.team = team
        self.profiles = profiles
        self.births = births
    }
}

/// This Mac's own version, mirrored so the phone's Settings can show it
/// next to the phone's own build and offer the Mac's update (#121).
public struct AppInfo: Codable, Sendable, Equatable {
    public let version: String
    public let sha: String
    /// The newer version About found, when there is one — the phone's
    /// "Update the Mac" row shows only when this is non-nil.
    public let updateVersion: String?
    /// "source" | "stable" | "nightly" — a source build has no update
    /// path, so the phone shows a note instead of a button.
    public let updateChannel: String
    /// The newest release About's check has found so far, regardless of
    /// whether it beats this Mac's own build — the phone compares it
    /// against ITS OWN version to know when a newer phone build is out.
    public let phoneLatest: String?

    public init(version: String, sha: String, updateVersion: String?,
                updateChannel: String, phoneLatest: String?) {
        self.version = version
        self.sha = sha
        self.updateVersion = updateVersion
        self.updateChannel = updateChannel
        self.phoneLatest = phoneLatest
    }
}

/// The auto-switch engine's state as the footer badge shows it — the
/// portable half of `CswapSupervisor.State`, which can't cross to iOS
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

/// The Mac's display preferences, mirrored so "Follow Mac" can render
/// the iOS popup exactly as the Mac shows it (#9 phase C1).
public struct FleetPrefs: Codable, Sendable, Equatable {
    public let themeID: String
    public let compactRows: Bool
    public let popupLayout: String  // "wide" / "stacked" / "hstack"
    public let burnStyle: String
    public let introStyle: String
    public let introTitle: String
    public let introSpeed: Double
    public let customThemes: [RowTheme]
    /// Popup sort + text scale (#9 phase D1a) — same defaults as AppModel's
    /// `sort_headroom` / `popup_text_size`.
    public let sortByHeadroom: Bool
    public let popupTextSize: String
    /// Minutes before an account's reset that its countdown goes live and
    /// the phone's reset alarm fires (`revive_lead_minutes`, default 10).
    public let reviveLeadMinutes: Int

    public init(themeID: String = "off", compactRows: Bool = false,
                popupLayout: String = "wide", burnStyle: String = "ember",
                introStyle: String = "top", introTitle: String = "zoom",
                introSpeed: Double = 1.0, customThemes: [RowTheme] = [],
                sortByHeadroom: Bool = true, popupTextSize: String = "default",
                reviveLeadMinutes: Int = 10) {
        self.themeID = themeID
        self.compactRows = compactRows
        self.popupLayout = popupLayout
        self.burnStyle = burnStyle
        self.introStyle = introStyle
        self.introTitle = introTitle
        self.introSpeed = introSpeed
        self.customThemes = customThemes
        self.sortByHeadroom = sortByHeadroom
        self.popupTextSize = popupTextSize
        self.reviveLeadMinutes = reviveLeadMinutes
    }

    // Custom Decodable: sortByHeadroom/popupTextSize are non-optional, so
    // synthesized decode would throw keyNotFound on a pre-D1a snapshot
    // that lacks them. Encode stays synthesized (Codable = both halves).
    enum CodingKeys: String, CodingKey {
        case themeID, compactRows, popupLayout, burnStyle, introStyle,
             introTitle, introSpeed, customThemes, sortByHeadroom, popupTextSize,
             reviveLeadMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themeID = try c.decode(String.self, forKey: .themeID)
        compactRows = try c.decode(Bool.self, forKey: .compactRows)
        popupLayout = try c.decode(String.self, forKey: .popupLayout)
        burnStyle = try c.decode(String.self, forKey: .burnStyle)
        introStyle = try c.decode(String.self, forKey: .introStyle)
        introTitle = try c.decode(String.self, forKey: .introTitle)
        introSpeed = try c.decode(Double.self, forKey: .introSpeed)
        customThemes = try c.decode([RowTheme].self, forKey: .customThemes)
        sortByHeadroom = try c.decodeIfPresent(Bool.self, forKey: .sortByHeadroom) ?? true
        popupTextSize = try c.decodeIfPresent(String.self, forKey: .popupTextSize) ?? "default"
        reviveLeadMinutes = try c.decodeIfPresent(Int.self, forKey: .reviveLeadMinutes) ?? 10
    }
}

/// Where the mobile companion reads its latest fleet snapshot from.
/// `nil` means "no snapshot yet" (not an error); a decode failure is.
public protocol FleetMirror: Sendable {
    func latest() async throws -> MirrorSnapshot?
}

/// Reads a `MirrorSnapshot` written by `MirrorWriter` — the local
/// App Support copy today, an iCloud/CloudKit-synced copy once #9 lands.
public struct FileFleetMirror: FleetMirror {
    public let url: URL
    public init(url: URL) {
        self.url = url
    }

    public func latest() async throws -> MirrorSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MirrorSnapshot.self, from: data)
    }
}

public enum MirrorWriter {
    public static func write(_ snapshot: MirrorSnapshot, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, not replaceItemAt — this file compiles for the Linux
        // tray and (now) iOS too, where the Darwin-only replacement API
        // isn't available everywhere.
        try data.write(to: url, options: .atomic)
    }

    /// One export per 30s — the tray is a fresh process per poll, so
    /// callers persist `lastWrite` in a sidecar file rather than memory.
    public static func shouldWrite(lastWrite: Date?, now: Date, minInterval: TimeInterval = 30) -> Bool {
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) > minInterval
    }

    /// `$XDG_STATE_HOME/infinitus` (fallback `~/.local/state/infinitus`) —
    /// same layout TrayHistory uses for usage history on Linux.
    public static func linuxStateDir(env: [String: String], home: String) -> URL {
        let base = env["XDG_STATE_HOME"] ?? home + "/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("infinitus")
    }
}

public enum MirrorError: Error, Sendable {
    case notConfigured
}

/// Real implementation waits on the Apple Developer account (#9) —
/// deliberately no `import CloudKit` and no entitlements until then.
public struct CloudKitFleetMirror: FleetMirror {
    public init() {}

    public func latest() async throws -> MirrorSnapshot? {
        throw MirrorError.notConfigured
    }
}
