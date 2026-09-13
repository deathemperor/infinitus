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
    /// One incremental reader per session (#346), keyed by sessionId (a
    /// pid can flip sessions underneath us across refreshes; sessionId
    /// doesn't). A transcript that gained nothing since the last refresh
    /// is a stat; one that grew is parsed for the new lines only — the
    /// watcher below fires once a second while a session streams.
    private var tails: [String: SessionTail] = [:]
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
        let tailsCopy = tails
        let cachedCopy = cached
        Task.detached(priority: .utility) { [weak self] in
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            let pairs = SessionProgress.match(sessions: sessions, records: records)
            var newByPid: [Int: SessionProgress] = [:]
            var newTails: [String: SessionTail] = [:]
            var newCached: [String: SessionProgress] = [:]
            var urls: [String: URL] = [:]
            for (session, record) in pairs {
                let url = Transcript.locate(cwd: record.cwd, sessionId: record.sessionId, claudeDir: claudeDir)
                urls[record.sessionId] = url
                var tail = tailsCopy[record.sessionId] ?? SessionTail(url: url)
                let moved = tail.advance()
                let progress: SessionProgress
                if !moved, let previous = cachedCopy[record.sessionId] {
                    progress = previous
                } else {
                    progress = tail.progress(name: record.name)
                }
                newByPid[session.pid] = progress
                newTails[record.sessionId] = tail
                newCached[record.sessionId] = progress
            }
            await self?.finish(byPid: newByPid, tails: newTails, cached: newCached,
                               transcripts: urls, light: light)
        }
    }

    private func finish(byPid: [Int: SessionProgress], tails: [String: SessionTail],
                        cached: [String: SessionProgress],
                        transcripts: [String: URL], light: Bool) {
        busy = false
        watch(transcripts)
        if rescanWanted { rescanWanted = false; transcriptMoved() }
        self.tails = tails
        self.cached = cached
        if light, Self.awsNeeds(byPid) == Self.awsNeeds(self.byPid) { return }
        scanned = true
        self.byPid = byPid
        let perMinute = TokenRate.perMinute(byPid)
        tokenRate = TokenRate(perMinute: perMinute,
                              peakPerMinute: TokenRate.nextPeak(tokenRate?.peakPerMinute ?? 0,
                                                                seeing: perMinute))
    }

    private static func awsNeeds(_ byPid: [Int: SessionProgress]) -> Set<String> {
        Set(byPid.flatMap { pid, p in [
            p.awsLoginProfile.map { "\(pid)|\($0)|\(p.awsLoginFailedAt?.timeIntervalSince1970 ?? 0)" },
            p.gcloudLoginProfile.map { "\(pid)|gcloud:\($0)|\(p.gcloudLoginFailedAt?.timeIntervalSince1970 ?? 0)" },
        ].compactMap { $0 } })
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

}
