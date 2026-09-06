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

    static let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/mirror-snapshot.json")
    }()

    /// The ⚡ gauge's scale: the highest tokens/minute seen lately.
    private var tokenPeak = 0
    /// Folders sessions have run in, newest first (#91's repository
    /// picker); kept across launches.
    private var recentCwds: [String] = UserDefaults.standard.stringArray(forKey: "recent_cwds") ?? []
    private static let recentCap = 20

    func record(listJSON: Data, prefs: FleetPrefs,
                serviceStatus: ServiceStatusSummary, engine: EngineBadge,
                fleets: [EngineFleet] = [], forecast: UsageForecast? = nil,
                plan: WindowPlanner.Plan? = nil, awsLogins: [AwsLogin.Item] = [],
                progress: [Int: SessionProgress] = [:], stats: Stats.Bundle? = nil,
                pushesAlerts: Bool = false, app: AppInfo? = nil, team: TeamSnapshot? = nil,
                profiles: [SessionProfile] = [], births: [Int: SessionBirth] = [:]) {
        guard Date().timeIntervalSince(lastWrite) > minInterval else { return }
        lastWrite = Date()
        let claudeDir = ClaudeSessions.configHome()
        // Same selection as InfinitusTray.swift's panel rows: busy/waiting
        // first, busy before waiting, capped at 6.
        let allRecords = ClaudeSessions.list(claudeDir: claudeDir)
        let sessionRecords = allRecords
            .filter { $0.status == "busy" || $0.status == "waiting" }
            .sorted { a, _ in a.status == "busy" }
        let now = Date()
        // One transcript read per record feeds both the panel row and the
        // sessions card's per-pid progress (#9 phase D2) — the card's own
        // rows come from listJSON's liveSessions, so a session outside
        // this busy/waiting six simply keeps its single line.
        // `progress` is the app's own scan of EVERY listed session (name,
        // AWS need, token rate) — without it an idle session reached the
        // phone nameless (user 2026-09-03 "idle sessions doesn't have
        // names shown on ios"); the six below overwrite it with a fresh read.
        var progressByPid = progress
        var recent = recentCwds
        for record in sessionRecords.reversed() where !record.cwd.isEmpty {
            recent.removeAll { $0 == record.cwd }
            recent.insert(record.cwd, at: 0)
        }
        if recent.count > Self.recentCap { recent = Array(recent.prefix(Self.recentCap)) }
        if recent != recentCwds {
            recentCwds = recent
            UserDefaults.standard.set(recent, forKey: "recent_cwds")
        }
        let sessions = sessionRecords.prefix(6).map { record -> SessionPanelRow in
            let progress = SessionProgress.read(sessionId: record.sessionId,
                                                cwd: record.cwd, claudeDir: claudeDir,
                                                name: record.name)
            progressByPid[Int(record.pid)] = progress
            return SessionPanelRow.make(record: record, progress: progress, now: now)
        }
        // Cash column (#9 phase D1a): the cache UsagePane.swift's refresh
        // already writes, verbatim — no new subprocess, no engine call.
        let usageJSON = try? Data(contentsOf: UsageModel.cacheURL)
        let perMinute = TokenRate.perMinute(progressByPid, now: now)
        tokenPeak = TokenRate.nextPeak(tokenPeak, seeing: perMinute)
        let snapshot = MirrorSnapshot(
            capturedAt: now,
            machineName: MachineName.current(),
            listJSON: listJSON,
            sessions: sessions,
            prefs: prefs,
            usageJSON: usageJSON,
            serviceStatus: serviceStatus,
            engine: engine,
            progressByPid: progressByPid,
            fleets: fleets.isEmpty ? nil : fleets,
            tokenRate: TokenRate(perMinute: perMinute, peakPerMinute: tokenPeak),
            forecast: forecast, plan: plan,
            awsLogins: awsLogins.isEmpty ? nil : awsLogins, stats: stats,
            recentCwds: recentCwds.isEmpty ? nil : recentCwds,
            pushesAlerts: pushesAlerts, app: app, team: team,
            profiles: profiles.isEmpty ? nil : profiles,
            births: births.isEmpty ? nil
                : SessionBirths.pruned(births, alive: Set(allRecords.map { Int($0.pid) })))
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
