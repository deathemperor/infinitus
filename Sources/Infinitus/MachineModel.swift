import Foundation
import InfinitusCore

/// The app-side half of the machine-health guardian (#115): owns the
/// last sample, throttles the expensive parts (temp-dir listing every
/// 5 min, tree sizes every hour), and pushes what the core layer flags
/// — once per condition, re-armed when it clears. All the measuring
/// and the rules live in InfinitusCore/Machine/*; this is scheduling,
/// persistence and the notification/action glue.
@MainActor
final class MachineModel: ObservableObject {
    /// The Settings › Machine pane and its background sampling are hidden for
    /// the alpha (`defaults write run.infinitus show_machine_pane -bool YES`
    /// brings them back); `infinitusctl machine*` samples on demand regardless.
    static var paneShown: Bool { UserDefaults.standard.bool(forKey: "show_machine_pane") }

    @Published private(set) var report: MachineReport?
    @Published private(set) var sampling = false
    @Published private(set) var lastSampledAt: Date?
    @Published private(set) var parkedOwners: [String] = []
    @Published var idleHours: Double {
        didSet { UserDefaults.standard.set(idleHours, forKey: "machine_idle_hours") }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "machine_guardian") }
    }
    /// Per-kind mutes for the pushed warnings (user 2026-09-06: "stop the
    /// hook and tmp dir notifications"): the guardian keeps sampling and
    /// the pane keeps listing them; only the notification is skipped.
    @Published var notifyHooks: Bool {
        didSet { UserDefaults.standard.set(notifyHooks, forKey: "machine_notify_hooks") }
    }
    @Published var notifyTemp: Bool {
        didSet { UserDefaults.standard.set(notifyTemp, forKey: "machine_notify_temp") }
    }

    /// AppModel owns this model; reaching back for session names,
    /// last-activity and the push/log channels must never cycle.
    weak var host: AppModel?

    // `nonisolated`: read from the detached (off-MainActor) sampling task.
    nonisolated static let userSettingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    private static let fingerprintKey = "machine_hook_fingerprint"

    private var lastTempCountAt: Date?
    private var lastTempCount: Int?
    private var lastTempByOwner: [String: Int]?
    private var lastTempListSeconds: Double = 0
    private var lastSizesAt: Date?
    private var lastSizes: (transcripts: Int, pluginCache: Int, mem: Int) = (0, 0, 0)
    private var pushedWarnings = Set<String>()
    private var lastPipTarget: String?
    /// Persisted: an app relaunch must not re-announce every long-idle
    /// session (the ship pipeline relaunches several times an evening).
    /// Pids are stable for a session's life; a reused pid is a new
    /// session that goes idle 12 h later at the earliest.
    private static let announcedIdleKey = "machine_idle_announced"
    private var announcedIdle: Set<Int> {
        didSet { UserDefaults.standard.set(Array(announcedIdle), forKey: Self.announcedIdleKey) }
    }

    init() {
        announcedIdle = Set(UserDefaults.standard.array(forKey: Self.announcedIdleKey) as? [Int] ?? [])
        idleHours = UserDefaults.standard.object(forKey: "machine_idle_hours") as? Double ?? 12
        enabled = UserDefaults.standard.object(forKey: "machine_guardian") as? Bool ?? true
        notifyHooks = UserDefaults.standard.object(forKey: "machine_notify_hooks") as? Bool ?? true
        notifyTemp = UserDefaults.standard.object(forKey: "machine_notify_temp") as? Bool ?? true
    }

    /// Called once per `AppModel.refreshSnapshot()` pass; samples at
    /// most every 55 s so an interval change never doubles up.
    func tick() async {
        guard enabled else { return }
        if let last = lastSampledAt, Date().timeIntervalSince(last) < 55 { return }
        await sample()
    }

    func sample() async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }

        let claudeDir = ClaudeSessions.configHome()
        let home = NSHomeDirectory()
        let tempDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let countTemp = lastTempCountAt.map { Date().timeIntervalSince($0) >= 300 } ?? true
        let doSizes = lastSizesAt.map { Date().timeIntervalSince($0) >= 3600 } ?? true
        let previousTempCount = lastTempCount
        let previousTempByOwner = lastTempByOwner
        let previousTempAt = lastTempCountAt
        let previousTempListSeconds = lastTempListSeconds
        let previousSizes = lastSizes
        // Session names/last-activity live on the main actor
        // (SessionProgressModel); read them here, pass the dictionary in.
        let byPid = host?.sessionProgress.byPid ?? [:]

        let (report, fingerprint, tempCount, sizes, parked, rows, pipSpawner, pipTarget) = await Task.detached(priority: .utility) {
            () -> (MachineReport, Set<String>, Int?, (Int, Int, Int), [String], [ProcessRow], String?, String?) in
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            let sessionPids = Set(records.map { Int($0.pid) })
            let cwds = Array(Set(records.map(\.cwd)))
            var (sample, rows) = MachineSampler.collect(sessionPids: sessionPids, tempDir: tempDir, countTemp: countTemp)
            let tempCount: Int?
            if countTemp {
                tempCount = sample.tempEntries
            } else {
                tempCount = previousTempCount
                sample.tempEntries = previousTempCount
                sample.tempListSeconds = previousTempListSeconds
            }

            let liveSessionIds = Set(records.map(\.sessionId))
            let hookRegs = HookInventory.scan(home: home, projectDirs: cwds)
            let hooks = hookRegs.map { reg in
                MachineReport.Hook(registration: reg,
                                   spawnsPerHour: HookInventory.spawnsPerHour(event: reg.event, liveSessions: sessionPids.count),
                                   live: HookInventory.live(of: reg, rows: rows))
            }
            let runaways = Runaways.flagged(rows: rows, sessionPids: sessionPids)

            var residue = MachineReport.ResidueCounts()
            residue.staleSockets = Residue.staleSockets(dir: "/tmp/cc-socks", alive: { kill(pid_t($0), 0) == 0 || errno == EPERM }).count
            residue.staleSessionEnvs = Residue.staleSessionEnvs(dir: home + "/.claude/session-env", liveSessionIds: liveSessionIds).count
            residue.tempEntries = tempCount
            residue.tempByOwner = sample.tempByOwner

            let sizes: (Int, Int, Int) = doSizes
                ? (Residue.size(of: home + "/.claude/projects"),
                   Residue.size(of: home + "/.claude/plugins/cache"),
                   Residue.size(of: home + "/.claude-mem"))
                : previousSizes
            residue.transcriptsBytes = sizes.0
            residue.pluginCacheBytes = sizes.1
            residue.memBytes = sizes.2

            let sessions = SessionHealth.build(
                rows: rows, records: records,
                name: { record in
                    let progress = byPid[Int(record.pid)]
                    return SessionNaming.displayName(name: progress?.name ?? record.name,
                                                     autoName: progress?.autoName, cwd: record.cwd)
                },
                lastActivity: { pid in byPid[pid]?.lastActivityAt })

            let report = MachineReport(sample: sample, hooks: hooks, runaways: runaways,
                                       residue: residue, sessions: sessions, warnings: [])
            let parked = Self.readParkedOwners()
            let pipSpawner = HookInventory.spawner(of: "pip install", rows: rows, registrations: hookRegs)
            let pipTarget = MachineReport.pipInstallTarget(rows: rows)
            return (report, Set(hookRegs.map(\.id)), tempCount, sizes, parked, rows, pipSpawner, pipTarget)
        }.value
        lastRows = rows
        // A retrying install runs a minute in every five: remember the last
        // pip seen so the warning can still name its venv between bursts.
        if let pipTarget { lastPipTarget = pipTarget }

        lastSampledAt = Date()
        // Gate on the ATTEMPT (`countTemp`), not the value: a timed-out
        // listing still counts as this cycle's attempt — `tempCount` is
        // non-nil even when throttled (it carries the previous value
        // forward), so gating on it would count once and never retry.
        var tempGrowth: [String: Double] = [:]
        if countTemp {
            tempGrowth = MachineReport.tempGrowthPerHour(previous: previousTempByOwner, previousAt: previousTempAt,
                                                         current: report.sample.tempByOwner, now: Date())
            if report.sample.tempByOwner != nil { lastTempByOwner = report.sample.tempByOwner }
            lastTempCount = tempCount
            lastTempCountAt = Date()
            lastTempListSeconds = report.sample.tempListSeconds
        }
        if doSizes { lastSizesAt = Date(); lastSizes = sizes }
        parkedOwners = parked

        // Newcomers since the last stored fingerprint. No stored
        // fingerprint at all (the very first sample ever) → store and
        // stay quiet; a change from a real previous fingerprint warns.
        // The set only ever GROWS: `projectDirs` is the live sessions'
        // cwds, so a project's hooks would otherwise drop out of the
        // fingerprint the moment its last session closes and come back
        // as a spurious "new hook" the next time it's reopened.
        let previousFingerprint = UserDefaults.standard.array(forKey: Self.fingerprintKey) as? [String]
        let newcomers = previousFingerprint.map { HookInventory.newcomers(report.hooks.map(\.registration), since: Set($0)) } ?? []
        let remembered = (previousFingerprint.map(Set.init) ?? []).union(fingerprint)
        UserDefaults.standard.set(Array(remembered), forKey: Self.fingerprintKey)

        var finalReport = report
        finalReport.warnings = MachineReport.warnings(sample: report.sample, hooks: report.hooks, newcomers: newcomers,
                                                      tempGrowthPerHour: tempGrowth, pipSpawner: pipSpawner,
                                                      pipTarget: lastPipTarget)
        self.report = finalReport

        // Every warning currently true gets pushed once; dropping out of
        // `currentWarnings` re-arms it for the next time it appears. The
        // identity is the text minus its digits — "oldest 53 min" ticks
        // every sample and must not re-notify.
        let currentWarnings = Set(finalReport.warnings.map(Self.warningKey))
        for warning in finalReport.warnings where !pushedWarnings.contains(Self.warningKey(warning)) && notifies(warning) {
            host?.push(warning)
        }
        pushedWarnings = currentWarnings

        let idleHoursNow = idleHours
        let idleNow = SessionHealth.idle(finalReport.sessions, hours: idleHoursNow, announced: announcedIdle)
        for session in idleNow {
            host?.push("session \(session.name) idle for \(Int(session.idleHours())) h (\(session.rssMB) MB)")
        }
        let stillIdle = Set(finalReport.sessions.filter { $0.idleHours() >= idleHoursNow }.map { $0.pid })
        announcedIdle = announcedIdle.union(idleNow.map { $0.pid }).intersection(stillIdle)
    }

    // MARK: actions

    enum ReclaimKind: String, CaseIterable, Sendable { case sockets, sessionEnvs, temps }

    static func warningKey(_ warning: String) -> String { warning.filter { !$0.isNumber } }

    private func notifies(_ warning: String) -> Bool {
        switch MachineReport.warningKind(warning) {
        case .hooks: return notifyHooks
        case .temp: return notifyTemp
        case .other: return true
        }
    }

    /// Only a pid the last report flagged, and only while `ps` still
    /// shows the flagged command there (pids get reused).
    func killRunaway(pid: Int) async -> String {
        guard pid > 1, let runaway = report?.runaways.first(where: { $0.pid == pid }) else {
            return "pid \(pid) is not a flagged runaway — run `machine` first"
        }
        let sessionPids = report?.sessions.map { $0.pid } ?? []
        let ok = await Task.detached(priority: .utility) { () -> Bool? in
            let now = (try? Subprocess.run("/bin/ps", ["-o", "command=", "-p", String(pid)]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !now.isEmpty, now.hasPrefix(runaway.command.prefix(40)) else { return nil }
            let groups = Set(sessionPids.map { Int(getpgid(pid_t($0))) })
            return Runaways.kill(pid: pid, protectedGroups: groups)
        }.value
        guard let ok else { return "pid \(pid) no longer runs the flagged command — nothing sent" }
        host?.logEvent("other", icon: "wrench.and.screwdriver",
                       ok ? "killed runaway pid \(pid)" : "sent kill to pid \(pid) — still alive")
        await sample()
        return ok ? "pid \(pid) is gone" : "pid \(pid) is still alive"
    }

    func reclaim(kinds: Set<ReclaimKind> = Set(ReclaimKind.allCases)) async -> String {
        let home = NSHomeDirectory()
        let tempDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let liveSessionIds = Set(ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).map(\.sessionId))
        let (removed, failed) = await Task.detached(priority: .utility) { () -> (Int, Int) in
            var items: [Residue.Item] = []
            if kinds.contains(.sockets) {
                items += Residue.staleSockets(dir: "/tmp/cc-socks", alive: { kill(pid_t($0), 0) == 0 || errno == EPERM })
            }
            if kinds.contains(.sessionEnvs) {
                items += Residue.staleSessionEnvs(dir: home + "/.claude/session-env", liveSessionIds: liveSessionIds)
            }
            if kinds.contains(.temps), let openPaths = Residue.openPaths(under: tempDir, timeout: 60) {
                items += Residue.orphanTemps(dir: tempDir, openPaths: openPaths)
            }
            let failures = Residue.reclaim(items)
            return (items.count - failures.count, failures.count)
        }.value
        host?.logEvent("other", icon: "wrench.and.screwdriver",
                       "reclaimed \(removed) item\(removed == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed" : ""))
        await sample()
        return "removed \(removed)" + (failed > 0 ? ", \(failed) failed" : "")
    }

    /// The process rows of the last sample: what a hook-instance kill
    /// targets, so the action hits exactly what the pane showed.
    private var lastRows: [ProcessRow] = []

    /// SIGTERM every live instance of the owner's hooks and their
    /// helpers (never a session's own pid), SIGKILL the survivors.
    func killHookInstances(owner: String) async -> String {
        let regs = (report?.hooks ?? []).map(\.registration).filter { $0.owner == owner }
        let rows = lastRows
        var pids = Set<Int>()
        for reg in regs {
            let (instances, helpers) = HookInventory.instanceRows(of: reg, rows: rows)
            pids.formUnion((instances + helpers).map { $0.pid })
        }
        guard !pids.isEmpty else { return "no live instances of \(owner) in the last sample" }
        let sessions = Set(report?.sessions.map { $0.pid } ?? [])
        let gone = await Task.detached(priority: .utility) {
            Runaways.killAll(pids: Array(pids), never: sessions)
        }.value
        host?.logEvent("other", icon: "wrench.and.screwdriver",
                       "killed \(gone) of \(pids.count) \(owner) hook instances")
        await sample()
        return "\(gone) of \(pids.count) \(owner) instances gone" + (gone < pids.count ? " — the rest are stuck in the kernel (uninterruptible wait) and go when their I/O returns" : "")
    }

    func disableHook(owner: String) async -> String {
        do {
            let (backup, moved) = try await Task.detached(priority: .utility) {
                try HookKillSwitch.apply({ HookKillSwitch.disable(owner: owner, in: $0) }, to: Self.userSettingsURL)
            }.value
            host?.logEvent("other", icon: "wrench.and.screwdriver",
                           "disabled \(owner)'s \(moved) hook registration\(moved == 1 ? "" : "s") (backup \(backup.lastPathComponent))")
            await sample()
            return "moved \(moved) registration\(moved == 1 ? "" : "s") out of settings.json"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    func restoreHook(owner: String) async -> String {
        do {
            let (_, moved) = try await Task.detached(priority: .utility) {
                try HookKillSwitch.apply({ HookKillSwitch.restore(owner: owner, in: $0) }, to: Self.userSettingsURL)
            }.value
            host?.logEvent("other", icon: "wrench.and.screwdriver",
                           "restored \(owner)'s \(moved) hook registration\(moved == 1 ? "" : "s")")
            await sample()
            return "restored \(moved) registration\(moved == 1 ? "" : "s")"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    nonisolated private static func readParkedOwners() -> [String] {
        guard let data = try? Data(contentsOf: userSettingsURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return HookKillSwitch.parkedOwners(in: object)
    }
}
