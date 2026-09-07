import Foundation
import InfinitusCore
import InfinitusUI

/// Feeds the sessions popover's mini progress rows (issue #13 step 2).
/// Reads Claude Code's own session records + transcript tails — same
/// engine-isolation rule as ResumeService (never touches the engine).
@MainActor
final class SessionProgressModel: SessionProgressSource {
    @Published private(set) var byPid: [Int: SessionProgress] = [:]
    /// Fleet-wide output tokens per minute with a slowly decaying peak
    /// (the footer's ⚡ gauge and the phone's Live Activity).
    @Published private(set) var tokenRate: TokenRate?
    /// The exporter's facts for leased sessions (#223 phase 3) — the
    /// sessions card reads the attention dot and word off them. Published
    /// only on change: the exporter ticks every 30 s whether or not a
    /// session moved.
    @Published private(set) var facts: [Int: SessionFacts] = [:]
    func setFacts(_ latest: [Int: SessionFacts]) {
        if latest != facts { facts = latest }
    }
    /// True once a scan has completed — the AWS-login push seeds on it.
    @Published private(set) var scanned = false

    private let claudeDir = ClaudeSessions.configHome()
    private struct Stamp: Equatable { let size: Int; let mtime: Date }
    /// Cheap-skip cache, keyed by sessionId (a pid can flip sessions
    /// underneath us across refreshes; sessionId doesn't). A transcript
    /// whose size+mtime haven't moved since the last refresh is not
    /// re-parsed — the popover ticks every 10s and most sessions are
    /// between turns most of the time.
    private var stamps: [String: Stamp] = [:]
    private var cached: [String: SessionProgress] = [:]
    private var busy = false
    /// One vnode watch per matched transcript (#79 without the plugin):
    /// Claude Code appends every tool result in place, so a write on a
    /// transcript is the earliest sign a session moved — the AWS-login
    /// need used to wait for the next fleet poll, up to a minute. Idle
    /// sessions cost nothing; a burst of writes coalesces into one scan.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var lastSessions: [SessionDetail] = []
    private var rescan: Task<Void, Never>?
    private var rescanWanted = false
    /// Haiku names for unnamed sessions (SessionNamer.swift); nil on
    /// playground/mock instances.
    var namer: SessionNamer? {
        didSet { namer?.onChange = { [weak self] in self?.applyAutoNames() } }
    }
    private var sessionIDByPid: [Int: String] = [:]

    /// `sessions`: the engine's current per-session detail (busy-first,
    /// capped) — only those get matched to a transcript and read.
    /// `light`: a watcher-driven scan (transcriptMoved) — it refreshes the
    /// cache but publishes only when a session's AWS-login need moved: a
    /// streaming session writes every second, and every publish re-lays
    /// the pop-out (38% CPU at one a second, 2026-09-07).
    func refresh(sessions: [SessionDetail], light: Bool = false) {
        guard !busy else { return }
        guard !sessions.isEmpty else {
            byPid = [:]
            tokenRate = nil
            watch([:])
            lastSessions = []
            return
        }
        busy = true
        lastSessions = sessions
        let claudeDir = claudeDir
        let stampsCopy = stamps
        let cachedCopy = cached
        Task.detached(priority: .utility) { [weak self] in
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            let pairs = SessionProgress.match(sessions: sessions, records: records)
            var newByPid: [Int: SessionProgress] = [:]
            var newStamps = stampsCopy
            var newCached = cachedCopy
            var ids: [Int: String] = [:]
            var cwds: [Int: String] = [:]
            var urls: [String: URL] = [:]
            for (session, record) in pairs {
                ids[session.pid] = record.sessionId
                cwds[session.pid] = record.cwd
                let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
                urls[record.sessionId] = url
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? -1
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let stamp = Stamp(size: size, mtime: mtime)
                if stampsCopy[record.sessionId] == stamp, let previous = cachedCopy[record.sessionId] {
                    newByPid[session.pid] = previous
                    continue
                }
                let progress = SessionProgress.read(sessionId: record.sessionId, cwd: record.cwd,
                                                     claudeDir: claudeDir, name: record.name)
                newByPid[session.pid] = progress
                newStamps[record.sessionId] = stamp
                newCached[record.sessionId] = progress
            }
            await self?.finish(byPid: newByPid, stamps: newStamps, cached: newCached, ids: ids, cwds: cwds,
                               transcripts: urls, light: light)
        }
    }

    private func finish(byPid: [Int: SessionProgress], stamps: [String: Stamp],
                        cached: [String: SessionProgress], ids: [Int: String], cwds: [Int: String],
                        transcripts: [String: URL], light: Bool) {
        busy = false
        watch(transcripts)
        if rescanWanted { rescanWanted = false; transcriptMoved() }
        self.stamps = stamps
        self.cached = cached
        if light, Self.awsNeeds(byPid) == Self.awsNeeds(self.byPid) { return }
        sessionIDByPid = ids
        scanned = true
        self.byPid = byPid
        applyAutoNames()
        if let namer {
            namer.consider(byPid.compactMap { pid, p in ids[pid].map { ($0, cwds[pid] ?? "", p) } })
            namer.prune(keeping: Set(ids.values))
        }
        let perMinute = TokenRate.perMinute(byPid)
        tokenRate = TokenRate(perMinute: perMinute,
                              peakPerMinute: TokenRate.nextPeak(tokenRate?.peakPerMinute ?? 0,
                                                                seeing: perMinute))
    }

    private static func awsNeeds(_ byPid: [Int: SessionProgress]) -> Set<String> {
        Set(byPid.compactMap { pid, p in
            p.awsLoginProfile.map { "\(pid)|\($0)|\(p.awsLoginFailedAt?.timeIntervalSince1970 ?? 0)" } })
    }

    /// Watches follow the matched set: a session that left drops its
    /// watch (and its descriptor); one that arrived gets one.
    private func watch(_ transcripts: [String: URL]) {
        for id in watchers.keys where transcripts[id] == nil { watchers.removeValue(forKey: id)?.cancel() }
        for (id, url) in transcripts where watchers[id] == nil {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in self?.transcriptMoved() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[id] = source
        }
    }

    /// A beat after the last write, one scan — the stamp cache makes it
    /// cost one transcript's tail. A scan already running notes the
    /// wish and reruns once when it finishes.
    private func transcriptMoved() {
        guard rescan == nil else { return }
        rescan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            rescan = nil
            if busy { rescanWanted = true } else { refresh(sessions: lastSessions, light: true) }
        }
    }

    /// Stamp Haiku's titles onto the unnamed rows (SessionNamer's
    /// cache is keyed by session id; rows are keyed by pid).
    private func applyAutoNames() {
        guard let namer else { return }
        var changed = false
        var next = byPid
        for (pid, p) in next {
            guard let id = sessionIDByPid[pid], let title = namer.title(for: id), !title.isEmpty,
                  p.autoName != title else { continue }
            next[pid]!.autoName = title
            changed = true
        }
        if changed { byPid = next }
    }
}
