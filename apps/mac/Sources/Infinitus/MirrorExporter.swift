import Foundation
import InfinitusCore

/// Writes a `MirrorSnapshot` after every live refresh so the (future)
/// mobile companion has something to read (#9 phase 1). Off the main
/// actor, mirroring UsageHistoryRecorder's shape — this is all file IO
/// plus the same Claude-Code-files-only session read the tray already
/// does (never an engine internal).
actor MirrorExporter {
    private let minInterval: TimeInterval = 30
    private var lastWrite: Date = .distantPast
    /// The LAN server's payload slot (#9), when the phone companion is
    /// on — it serves the very bytes written here, never a re-encode.
    private var payload: MirrorPayloadBox?

    func attach(payload: MirrorPayloadBox) {
        self.payload = payload
    }

    // INFINITUS_MIRROR_SNAPSHOT: a debug/fixture instance's own file, so
    // it never overwrites the real app's mirror snapshot (#474).
    static let url: URL = {
        ProcessInfo.processInfo.environment["INFINITUS_MIRROR_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
            ?? AppSupport.root().appendingPathComponent("mirror-snapshot.json")
    }()

    /// Folders sessions have run in, newest first (#91's repository
    /// picker); kept across launches.
    private var recentCwds: [String] = AppDefaults.standard.stringArray(forKey: "recent_cwds") ?? []
    private static let recentCap = 20

    func record(listJSON: Data, prefs: FleetPrefs,
                serviceStatus: ServiceStatusSummary, engine: EngineBadge,
                fleets: [EngineFleet] = [], forecast: UsageForecast? = nil,
                plan: WindowPlanner.Plan? = nil, awsLogins: [AwsLogin.Item] = [],
                stats: Stats.Bundle? = nil,
                pushesAlerts: Bool = false, app: AppInfo? = nil,
                // A closure, not a value: T3's project list scans past
                // sessions and shells out to git per cwd (T3 clone A, #337) —
                // real work the throttle below must skip.
                projects: @Sendable () -> [ProjectSummary] = { [] },
                now: Bool = false) {
        // `now`: news the phone is waiting on (an AWS-login need that just
        // surfaced) skips the 30 s throttle.
        guard now || Date().timeIntervalSince(lastWrite) > minInterval else { return }
        lastWrite = Date()
        let claudeDir = ClaudeSessions.configHome()
        let allRecords = ClaudeSessions.list(claudeDir: claudeDir)
        let sessionRecords = allRecords
            .filter { $0.status == "busy" || $0.status == "waiting" }
            .sorted { a, _ in a.status == "busy" }
        let now = Date()
        var recent = recentCwds
        for record in sessionRecords.reversed() where !record.cwd.isEmpty {
            recent.removeAll { $0 == record.cwd }
            recent.insert(record.cwd, at: 0)
        }
        if recent.count > Self.recentCap { recent = Array(recent.prefix(Self.recentCap)) }
        if recent != recentCwds {
            recentCwds = recent
            AppDefaults.standard.set(recent, forKey: "recent_cwds")
        }
        // Cash column (#9 phase D1a) was `cswap usage`'s cache; the field
        // stays on the wire, empty, until a native estimate (#756).
        let usageJSON: Data? = nil
        // The engine's rows know pids only; the session records know the
        // ids (#391), so a phone can act on a session by id as well as pid.
        let sessionIds = Dictionary(allRecords.map { (Int($0.pid), $0.sessionId) }, uniquingKeysWith: { a, _ in a })
        let fleets = fleets.map { $0.with(liveSessions: $0.liveSessions?.tagging(sessionIds: sessionIds)) }
        let snapshot = MirrorSnapshot(
            capturedAt: now,
            machineName: MachineName.current(),
            listJSON: listJSON,
            prefs: prefs,
            usageJSON: usageJSON,
            serviceStatus: serviceStatus,
            engine: engine,
            fleets: fleets.isEmpty ? nil : fleets,
            tokenRate: nil,
            forecast: forecast, plan: plan,
            awsLogins: awsLogins.isEmpty ? nil : awsLogins, stats: stats,
            recentCwds: recentCwds.isEmpty ? nil : recentCwds,
            pushesAlerts: pushesAlerts, app: app,
            projects: { let p = projects(); return p.isEmpty ? nil : p }())
        // Encoded once here rather than inside MirrorWriter so the LAN
        // server hands out the same bytes the file holds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        payload?.set(data)
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
