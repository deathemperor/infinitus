import Foundation

/// Windows settings model matching the Mac's `UserDefaults` keys where
/// concepts overlap, plus snake_case keys for Windows-only settings.
///
/// Hand-written `init(from:)` with memberwise fallback: synthesized
/// Decodable fails the entire decode on a single unknown or newly-added
/// key, dropping the whole file. See `Stats.Day` for the same rule.
public struct WinSettings: Codable, Sendable, Equatable {
    // Mac-parity Display / Title prefs
    public var showAccountName: Bool = true
    public var titlePct: String = "both"
    public var titleScoped: Bool = false
    public var titleRemaining: Bool = false
    public var titleReset: String = "countdown"
    public var titleIconOnly: Bool = false
    public var refreshIntervalSeconds: Int = 60
    public var gamificationStyle: String = "off"

    // Mac-parity Push triggers
    public var pushSessionsDone: Bool = true
    public var pushAllDead: Bool = true
    public var pushLastAlive: Bool = true
    public var pushWaiting: Bool = true
    public var pushAwsLogin: Bool = true

    // Tray behaviour
    public var trayBalloonsEnabled: Bool = true
    public var sortByHeadroom: Bool = true
    public var keepAwake: Bool = false
    public var popupLayout: String = "wide" // "wide" | "stacked" | "hstack"

    // Engine toggles
    public var engineCswapEnabled: Bool = true
    public var engineCLIProxyEnabled: Bool = false
    public var engineNineRouterEnabled: Bool = false

    // Updates
    public var updateAutoCheck: Bool = true
    public var updateAutoInstall: Bool = false
    public var appUpdateLastCheck: Double = 0
    public var appUpdateNotifiedVersion: String = ""
    public var updateAttemptedVersion: String = ""

    // Devices
    public var mirrorPort: UInt16 = 47824
    public var autoResume: Bool = false

    // Machine & data panes
    public var machineID: String = ""
    public var statsPeriod: String = "today"
    public var usageDays: Int = 7
    public var utilizationDays: Int = 7

    // Shell
    public var lastPaneID: String = "display"
    public var windowWidth: Int32 = 0     // 0 = use the default
    public var windowHeight: Int32 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showAccountName = "show_account_name"
        case titlePct = "title_pct"
        case titleScoped = "title_scoped"
        case titleRemaining = "title_remaining"
        case titleReset = "title_reset"
        case titleIconOnly = "title_icon_only"
        case refreshIntervalSeconds = "refresh_interval"
        case gamificationStyle = "gamification_style"
        case pushSessionsDone = "push_sessions_done"
        case pushAllDead = "push_all_dead"
        case pushLastAlive = "push_last_alive"
        case pushWaiting = "push_waiting"
        case pushAwsLogin = "push_aws_login"
        case trayBalloonsEnabled = "tray_balloons"
        case sortByHeadroom = "sort_headroom"
        case keepAwake = "keep_awake"
        case popupLayout = "popup_layout"
        case engineCswapEnabled = "engine_cswap_enabled"
        case engineCLIProxyEnabled = "engine_cliproxy_enabled"
        case engineNineRouterEnabled = "engine_9router_enabled"
        case updateAutoCheck = "update_auto_check"
        case updateAutoInstall = "update_auto_install"
        case appUpdateLastCheck = "app_update_last_check"
        case appUpdateNotifiedVersion = "app_update_notified_version"
        case updateAttemptedVersion = "update_attempted_version"
        case mirrorPort = "mirror_port"
        case autoResume = "auto_resume"
        case machineID = "machine_id"
        case statsPeriod = "stats_period"
        case usageDays = "usage_days"
        case utilizationDays = "utilization_days"
        case lastPaneID = "last_pane"
        case windowWidth = "window_width"
        case windowHeight = "window_height"
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WinSettings()
        showAccountName = try c.decodeIfPresent(Bool.self, forKey: .showAccountName) ?? d.showAccountName
        titlePct = try c.decodeIfPresent(String.self, forKey: .titlePct) ?? d.titlePct
        titleScoped = try c.decodeIfPresent(Bool.self, forKey: .titleScoped) ?? d.titleScoped
        titleRemaining = try c.decodeIfPresent(Bool.self, forKey: .titleRemaining) ?? d.titleRemaining
        titleReset = try c.decodeIfPresent(String.self, forKey: .titleReset) ?? d.titleReset
        titleIconOnly = try c.decodeIfPresent(Bool.self, forKey: .titleIconOnly) ?? d.titleIconOnly
        refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? d.refreshIntervalSeconds
        gamificationStyle = try c.decodeIfPresent(String.self, forKey: .gamificationStyle) ?? d.gamificationStyle
        pushSessionsDone = try c.decodeIfPresent(Bool.self, forKey: .pushSessionsDone) ?? d.pushSessionsDone
        pushAllDead = try c.decodeIfPresent(Bool.self, forKey: .pushAllDead) ?? d.pushAllDead
        pushLastAlive = try c.decodeIfPresent(Bool.self, forKey: .pushLastAlive) ?? d.pushLastAlive
        pushWaiting = try c.decodeIfPresent(Bool.self, forKey: .pushWaiting) ?? d.pushWaiting
        pushAwsLogin = try c.decodeIfPresent(Bool.self, forKey: .pushAwsLogin) ?? d.pushAwsLogin
        trayBalloonsEnabled = try c.decodeIfPresent(Bool.self, forKey: .trayBalloonsEnabled) ?? d.trayBalloonsEnabled
        sortByHeadroom = try c.decodeIfPresent(Bool.self, forKey: .sortByHeadroom) ?? d.sortByHeadroom
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        popupLayout = try c.decodeIfPresent(String.self, forKey: .popupLayout) ?? d.popupLayout
        engineCswapEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineCswapEnabled) ?? d.engineCswapEnabled
        engineCLIProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineCLIProxyEnabled) ?? d.engineCLIProxyEnabled
        engineNineRouterEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineNineRouterEnabled) ?? d.engineNineRouterEnabled
        updateAutoCheck = try c.decodeIfPresent(Bool.self, forKey: .updateAutoCheck) ?? d.updateAutoCheck
        updateAutoInstall = try c.decodeIfPresent(Bool.self, forKey: .updateAutoInstall) ?? d.updateAutoInstall

        var legacyLastCheck: Double? = nil
        var legacyNotified: String? = nil
        if let raw = try? decoder.container(keyedBy: DynamicKey.self) {
            if let k = DynamicKey(stringValue: "update_last_check") {
                legacyLastCheck = try? raw.decodeIfPresent(Double.self, forKey: k)
            }
            if let k = DynamicKey(stringValue: "update_notified_version") {
                legacyNotified = try? raw.decodeIfPresent(String.self, forKey: k)
            }
        }

        appUpdateLastCheck = (try c.decodeIfPresent(Double.self, forKey: .appUpdateLastCheck))
            ?? legacyLastCheck
            ?? d.appUpdateLastCheck
        appUpdateNotifiedVersion = (try c.decodeIfPresent(String.self, forKey: .appUpdateNotifiedVersion))
            ?? legacyNotified
            ?? d.appUpdateNotifiedVersion
        updateAttemptedVersion = try c.decodeIfPresent(String.self, forKey: .updateAttemptedVersion) ?? d.updateAttemptedVersion
        mirrorPort = try c.decodeIfPresent(UInt16.self, forKey: .mirrorPort) ?? d.mirrorPort
        autoResume = try c.decodeIfPresent(Bool.self, forKey: .autoResume) ?? d.autoResume
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? d.machineID
        statsPeriod = try c.decodeIfPresent(String.self, forKey: .statsPeriod) ?? d.statsPeriod
        usageDays = try c.decodeIfPresent(Int.self, forKey: .usageDays) ?? d.usageDays
        utilizationDays = try c.decodeIfPresent(Int.self, forKey: .utilizationDays) ?? d.utilizationDays
        lastPaneID = try c.decodeIfPresent(String.self, forKey: .lastPaneID) ?? d.lastPaneID
        windowWidth = try c.decodeIfPresent(Int32.self, forKey: .windowWidth) ?? d.windowWidth
        windowHeight = try c.decodeIfPresent(Int32.self, forKey: .windowHeight) ?? d.windowHeight
    }
}

public enum WinSettingsStore {
    public static var infinitusHome: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming).appendingPathComponent("Infinitus")
    }

    public static var url: URL {
        infinitusHome.appendingPathComponent("settings.json")
    }

    public static var windowsThemesURL: URL {
        infinitusHome.appendingPathComponent("themes.json")
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: WinSettings?

    /// Formatter for bad settings file quarantine. Never uses named IANA zones per CLAUDE.md.
    private static let badStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()

    public static func load(from url: URL = url) -> WinSettings {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }

        guard FileManager.default.fileExists(atPath: url.path) else {
            let def = WinSettings()
            cache = def
            return def
        }

        guard let data = try? Data(contentsOf: url) else {
            let def = WinSettings()
            cache = def
            return def
        }

        do {
            let decoded = try JSONDecoder().decode(WinSettings.self, from: data)
            cache = decoded
            return decoded
        } catch {
            let stamp = badStampFormatter.string(from: Date())
            let badURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.bad-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: badURL)
            let def = WinSettings()
            cache = def
            return def
        }
    }

    public static func save(_ settings: WinSettings, to url: URL = url) throws {
        lock.lock()
        defer { lock.unlock() }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)

        let tmpURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.tmp")
        try data.write(to: tmpURL, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
        cache = settings
    }

    @discardableResult
    public static func update(at url: URL = url, fileURL: URL? = nil, _ mutate: (inout WinSettings) -> Void) throws -> WinSettings {
        let target = fileURL ?? url
        var current = load(from: target)
        mutate(&current)
        try save(current, to: target)
        return current
    }

    public static func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }

    public static func resetCacheForTests() {
        resetCache()
    }
}
