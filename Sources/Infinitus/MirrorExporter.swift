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

    /// The ⚡ gauge's scale: the highest tokens/minute seen lately.
    private var tokenPeak = 0
    /// The six panel rows' transcripts, read incrementally (#346).
    private var tails: [String: SessionTail] = [:]
    private var tailProgress: [String: SessionProgress] = [:]
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
                profiles: [SessionProfile] = [],
                // A closure, not a value: T3's project list scans past
                // sessions and shells out to git per cwd (T3 clone A, #337) —
                // real work the throttle below must skip, the same
                // reason `facts` below is a closure too.
                projects: @Sendable () -> [ProjectSummary] = { [] },
                births: [Int: SessionBirth] = [:],
                facts: @Sendable ([ClaudeSessionRecord]) -> [Int: SessionFacts] = { _ in [:] },
                sequence: SequenceLog? = nil, now: Bool = false,
                overlay: @Sendable ([ClaudeSessionRecord]) -> [ClaudeSessionRecord] = { $0 }) {
        // `now`: news the phone is waiting on (an AWS-login need that just
        // surfaced) skips the 30 s throttle.
        guard now || Date().timeIntervalSince(lastWrite) > minInterval else { return }
        lastWrite = Date()
        let claudeDir = ClaudeSessions.configHome()
        // `overlay` folds an owned session's live state into the rows; the
        // facts build below keeps the plain records — a "waiting" status
        // there turns the open tool_use into a second approval.
        let plainRecords = ClaudeSessions.list(claudeDir: claudeDir)
        // Same selection as InfinitusTray.swift's panel rows: busy/waiting
        // first, busy before waiting, capped at 6.
        let allRecords = overlay(plainRecords)
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
        let shown = Array(sessionRecords.prefix(6))
        let sessions = shown.map { record -> SessionPanelRow in
            let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
            var tail = tails[record.sessionId] ?? SessionTail(url: url)
            let progress: SessionProgress
            if !tail.advance(), let previous = tailProgress[record.sessionId] {
                progress = previous
            } else {
                progress = tail.progress(name: record.name, now: now)
            }
            tails[record.sessionId] = tail
            tailProgress[record.sessionId] = progress
            progressByPid[Int(record.pid)] = progress
            return SessionPanelRow.make(record: record, progress: progress, now: now)
        }
        let shownIds = Set(shown.map(\.sessionId))
        tails = tails.filter { shownIds.contains($0.key) }
        tailProgress = tailProgress.filter { shownIds.contains($0.key) }
        // Cash column (#9 phase D1a): the cache UsagePane.swift's refresh
        // already writes, verbatim — no new subprocess, no engine call.
        let usageJSON = try? Data(contentsOf: UsageModel.cacheURL)
        let perMinute = TokenRate.perMinute(progressByPid, now: now)
        tokenPeak = TokenRate.nextPeak(tokenPeak, seeing: perMinute)
        // The engine's rows know pids only; the session records know the
        // ids (#391), so a phone can act on a session by id as well as pid.
        let sessionIds = Dictionary(allRecords.map { (Int($0.pid), $0.sessionId) }, uniquingKeysWith: { a, _ in a })
        let fleets = fleets.map { $0.with(liveSessions: $0.liveSessions?.tagging(sessionIds: sessionIds)) }
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
            projects: { let p = projects(); return p.isEmpty ? nil : p }(),
            births: births.isEmpty ? nil
                : SessionBirths.pruned(births, alive: Set(allRecords.map { Int($0.pid) })),
            factsByPid: facts(plainRecords),
            epoch: sequence?.epoch, sequence: sequence?.current)
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
