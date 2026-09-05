import Foundation
import InfinitusCore

/// `GET /snapshot`'s body (docs/plan-windows/02-feed-readonly.md): the
/// same `MirrorSnapshot` the Mac's MirrorExporter writes, built from the
/// only thing this host has — Claude Code's own session records and
/// transcripts. No accounts: Windows runs no swap engine, so the fleet is
/// synthetic and `accounts` is empty; the phone hides such a fleet's
/// account section (04-phone.md) and shows the sessions.
enum Snapshot {
    /// The synthetic fleet's id. `claude-code-` prefixed so the phone can
    /// tell an engine-less host from a Mac's cswap fleet.
    static let engineID = "claude-code-windows"
    /// Synthetic fleet id when Claude Code routes through 9Router.
    static let routedEngineID = "claude-code-windows-9router"

    /// Recompute at most this often — the phone polls `/snapshot` on a
    /// timer and every read walks every live transcript.
    static let cacheSeconds: TimeInterval = 5

    /// Encoder shared with the tail route: `.iso8601` is what the phone
    /// decodes (MirrorExporter.swift:81).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The snapshot for right now. `alive` is injectable so tests can
    /// drive a fixture directory without real processes.
    static func make(claudeDir: URL, now: Date = Date(),
                     alive: (Int32) -> Bool = ClaudeSessions.isAlive) -> MirrorSnapshot {
        let records = ClaudeSessions.list(claudeDir: claudeDir, alive: alive)
            .filter { record in
                WinSessions.procStart(claudeDir: claudeDir, pid: record.pid).map {
                    WinProcess.isAlive(pid: record.pid, procStart: $0)
                } ?? true
            }
        let startedAt = startedAtByPid(claudeDir: claudeDir, records: records)

        // One transcript read per live record: the phone needs a name for
        // every session, not just the six panel rows (the Mac learned this
        // the hard way — MirrorExporter.swift:47).
        var progressByPid: [Int: SessionProgress] = [:]
        for record in records {
            progressByPid[Int(record.pid)] = SessionProgress.read(
                sessionId: record.sessionId, cwd: record.cwd,
                claudeDir: claudeDir, name: record.name)
        }
        let fallbackProgress = SessionProgress()

        // Panel rows: busy/waiting first, busy before waiting, capped at 6
        // — the Mac's selection verbatim (MirrorExporter.swift:39-41).
        let sessions = records
            .filter { $0.status == "busy" || $0.status == "waiting" }
            .sorted { a, _ in a.status == "busy" }
            .prefix(6)
            .map { record in
                SessionPanelRow.make(record: record,
                                     progress: progressByPid[Int(record.pid)] ?? fallbackProgress,
                                     now: now)
            }

        let live = liveSessions(records, startedAt: startedAt)
        // cswap runs on Windows too (PyPI ships a Windows wheel; `uv tool
        // install claude-swap` puts cswap.exe in ~/.local/bin). When it is
        // there the fleet is the REAL one — accounts, quota, active
        // account — exactly as on the Mac. Without it the fleet stays
        // synthetic and account-less, and the phone hides that section.
        //
        // When cswap is absent, check whether Claude Code routes requests
        // via 9Router (ANTHROPIC_BASE_URL in settings.json pointed at port 20128).
        // If routed to 9Router, the synthetic fleet reflects that routing so
        // mirrors and paired devices distinguish routed hosts from unmanaged standalone logins.
        let cswapList = CswapFleet.list()
        let isRouted = ClaudeCodeRouting.isRouted(
            ClaudeCodeRouting.anthropicBaseURL(configHome: claudeDir), to: nil)
        let fallbackEngineID = isRouted ? routedEngineID : engineID

        // Multi-engine check: if routed through 9Router,
        // use live 9Router fleets and account list (wait=true on cold access so snapshot contains real accounts).
        let useNineRouter = isRouted
        let nineRouterFleets = useNineRouter ? NineRouterFleet.fleets(now: now, wait: true) : nil
        let nineRouterList = useNineRouter ? NineRouterFleet.list(now: now, wait: true) : nil

        let activeFleets: [EngineFleet]
        let activeAccountList: AccountList?

        if let nrFleets = nineRouterFleets, !nrFleets.isEmpty {
            // Annotate liveSessions onto the primary Claude fleet
            activeFleets = nrFleets.map { f in
                if f.provider == Provider.claude {
                    return EngineFleet(engineID: f.engineID, provider: f.provider,
                                       accounts: f.accounts, activeNumber: f.activeNumber,
                                       nextCandidate: f.nextCandidate, nextRecovery: f.nextRecovery,
                                       liveSessions: live, raw: f.raw)
                }
                return f
            }
            // `listJSON` keeps a phone older than `fleets` working; it is
            // the PRIMARY fleet, picked by Core's shared rule so the Mac,
            // the tray and this daemon can't disagree about which one it is.
            activeAccountList = nineRouterList
                ?? EngineFleet.primaryList(nrFleets, liveSessions: live)
        } else if let cswap = cswapList, !cswap.accounts.isEmpty {
            let fleet = EngineFleet(engineID: CswapFleet.engineID, provider: Provider.claude,
                                    accounts: cswap.accounts, activeNumber: cswap.activeAccountNumber,
                                    nextCandidate: cswap.nextCandidate, nextRecovery: cswap.nextRecovery,
                                    liveSessions: live)
            activeFleets = [fleet]
            activeAccountList = cswap
        } else {
            let fleet = EngineFleet(engineID: fallbackEngineID, provider: Provider.claude,
                                    accounts: [], liveSessions: live)
            activeFleets = [fleet]
            activeAccountList = nil
        }

        // listJSON keeps a phone older than `fleets` working: it decodes
        // this as the primary fleet and finds the sessions there.
        let listJSON = (try? JSONEncoder().encode(
            AccountList(activeAccountNumber: activeAccountList?.activeAccountNumber,
                        accounts: activeAccountList?.accounts ?? [],
                        nextCandidate: activeAccountList?.nextCandidate,
                        nextRecovery: activeAccountList?.nextRecovery,
                        liveSessions: live))) ?? Data()

        return MirrorSnapshot(
            capturedAt: now,
            machineName: WinProcess.machineName,
            listJSON: listJSON,
            sessions: Array(sessions),
            progressByPid: progressByPid,
            fleets: activeFleets)
    }

    /// The status breakdown, counting every live record. `unknown` covers
    /// a record with no status (sdk-cli sessions) so the parts still sum
    /// to `total`.
    static func liveSessions(_ records: [ClaudeSessionRecord],
                             startedAt: [Int32: Double] = [:]) -> LiveSessions {
        var counts: [String: Int] = [:]
        for record in records {
            counts[record.status ?? "unknown", default: 0] += 1
        }
        return LiveSessions(
            busy: counts["busy"] ?? 0, total: records.count,
            idle: counts["idle"] ?? 0, waiting: counts["waiting"] ?? 0,
            shell: counts["shell"] ?? 0, unknown: counts["unknown"] ?? 0,
            sessions: records.map {
                SessionDetail(pid: Int($0.pid), cwd: $0.cwd,
                              status: $0.status ?? "unknown", kind: $0.kind,
                              startedAt: startedAt[$0.pid] ?? 0)
            })
    }

    /// `startedAt` (epoch ms) per pid. Core's record doesn't carry the key,
    /// so read it off the same file `procStart` comes from — one small
    /// JSON parse per live record, the shape the phone's session rows want.
    static func startedAtByPid(claudeDir: URL,
                               records: [ClaudeSessionRecord]) -> [Int32: Double] {
        var out: [Int32: Double] = [:]
        for record in records {
            let url = claudeDir.appendingPathComponent("sessions")
                .appendingPathComponent("\(record.pid).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let started = obj["startedAt"] as? Double
            else { continue }
            out[record.pid] = started
        }
        return out
    }
}

/// Serves `make` behind the 5 s cache the route handler shares.
final class SnapshotCache: @unchecked Sendable {
    private let claudeDir: URL
    private let lock = NSLock()
    private var cached: (data: Data, at: Date)?

    init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    /// Encoded snapshot bytes, recomputed at most every `cacheSeconds`.
    func data(now: Date = Date()) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < Snapshot.cacheSeconds {
            return cached.data
        }
        let snapshot = Snapshot.make(claudeDir: claudeDir, now: now)
        let data = (try? Snapshot.encoder().encode(snapshot)) ?? Data()
        cached = (data, now)
        return data
    }
}
