// Sources/Infinitus/StatsModel.swift
import Foundation
import InfinitusCore

/// The Stats tab's state: transcript facts + repo facts + event facts,
/// merged per day and folded into the four periods. Every scan runs off
/// the main actor; the first one backfills from everything on disk.
@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var days: [String: Stats.Day] = [:]
    @Published private(set) var summaries: [Stats.Period: Stats.Summary] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastRefresh: Date?
    /// Set while the transcript chunk loop is running: "scanned X MB of
    /// Y MB (n files left)". The (separate, slower) repo scan doesn't
    /// report into this — see `refresh()`. Task 9's pane renders it.
    @Published private(set) var progress: String?

    /// Set once by `AppModel` (`!mockMode && !isPlayground`) — a mock or
    /// playground instance must never read/write the real App Support
    /// caches under it. `refresh()` no-ops while `false`; `days` simply
    /// stays whatever it already was (empty on a fresh instance), so
    /// `infinitusctl stats` there answers a zero summary instead of
    /// starting a real cold backfill (caught in the e2e mock instance).
    var enabled = true

    let eventStore: EventStore
    private let repoScanner = RepoStatsScanner()
    /// Guards the repo scan against a later `refresh()` starting a second
    /// one while it's still running (git/gh can take minutes on a repo
    /// with a long history).
    private var repoScanRunning = false
    private var transcriptsFinished = false
    /// Rebuilt separately (transcript+event facts vs. repo facts) and
    /// combined into `notes`/`days`/`summaries` — the transcript chunk
    /// loop and the repo scan publish independently and on their own
    /// schedules, so neither may overwrite `days` from scratch: doing
    /// that once silently discarded the other side's already-merged
    /// contribution (a transcript chunk publishing after the repo scan
    /// finished dropped its commits back to 0 — caught live during the
    /// round-2 real-corpus probe).
    private var transcriptNotes: [String] = []
    private var repoNotes: [String] = []
    private var transcriptDays: [String: Stats.Day] = [:]
    private var repoDays: [String: Stats.Day] = [:]
    /// Every live transcript file as of the last finished scan, for the
    /// team publisher (#251: it publishes from this instead of scanning
    /// the same corpus a second time). nil until a scan of this launch
    /// has run to its end.
    private(set) var scanEntries: [String: StatsScanner.FileEntry]?

    /// What the mirror exporter sends: eight folds, two of them
    /// full-year. Built OFF the main actor after every `recomputeDays`
    /// and stored — building it in the exporter's path meant folding a
    /// year twice per refresh tick on the MainActor. nil until the
    /// first scan publishes (a disabled instance never publishes).
    @Published private(set) var bundle: Stats.Bundle?
    private var bundleGeneration = 0

    init(eventStore: EventStore) { self.eventStore = eventStore }

    func loadIfNeeded() { if days.isEmpty, !scanning { refresh() } }

    func refreshIfStale(_ interval: TimeInterval = 300) {
        if lastRefresh.map({ Date().timeIntervalSince($0) > interval }) ?? true { refresh() }
    }

    private func recomputeNotes() { notes = transcriptNotes + repoNotes }

    private func recomputeDays(calendar: Calendar) {
        var merged = transcriptDays
        for (k, d) in repoDays { merged[k] = (merged[k] ?? Stats.Day()) + d }
        days = merged
        summaries = Dictionary(uniqueKeysWithValues: Stats.Period.allCases.map {
            ($0, Stats.fold(days: merged, period: $0, calendar: calendar))
        })
        rebuildBundle(days: merged, calendar: calendar)
    }

    /// The mirrored bundle, rebuilt off the main actor. `generation`
    /// drops a build that finishes after a newer one started (the
    /// transcript chunk loop and the repo scan both land here).
    private func rebuildBundle(days: [String: Stats.Day], calendar: Calendar) {
        bundleGeneration += 1
        let generation = bundleGeneration
        Task.detached(priority: .utility) {
            let built = Stats.Bundle(days: days, calendar: calendar)
            await MainActor.run {
                guard self.bundleGeneration == generation else { return }
                self.bundle = built
            }
        }
    }

    /// Both the transcript loop and the repo scan can finish in either
    /// order; `scanning` only drops once both say they're done.
    private func markTranscriptsDone() {
        transcriptsFinished = true
        if !repoScanRunning { scanning = false }
    }

    private func markRepoScanDone() {
        repoScanRunning = false
        if transcriptsFinished { scanning = false }
    }

    /// Per-chunk transcript read budget (bytes) — `StatsScanner.scan`
    /// stops reading once it's spent this much, however far through any
    /// one file that leaves it (a 654 MB transcript, seen in practice,
    /// gets read across many chunks instead of blocking the first one).
    private static let chunkByteBudget = 64 * 1024 * 1024

    /// Absolute stop on the chunk loop, on top of the no-progress check
    /// below — belt and suspenders against ever spinning forever.
    private static let maxPasses = 500

    private nonisolated static let filesLeftFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private nonisolated static func grouped(_ n: Int) -> String {
        filesLeftFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// A cold backfill (months of transcripts, first launch or an
    /// emptied cache) can take minutes; scanning the whole corpus in one
    /// shot would show nothing until it finished — and a slow repo (a
    /// long git history) must never block that. So this runs two
    /// independent loops:
    ///
    /// - The transcript chunk loop: `StatsScanner.scan` reads up to
    ///   `chunkByteBudget` bytes at a time (newest files first), merging
    ///   in the once-loaded event days and publishing
    ///   `days`/`summaries`/`notes` after every chunk, until nothing's
    ///   left to parse. `progress` carries "scanned X MB of Y MB (n
    ///   files left)" — X accumulates across chunks, Y is fixed at the
    ///   first chunk's total, so it actually counts up instead of
    ///   resetting every chunk. The loop also stops (rather than ever
    ///   spinning) once a pass makes no measurable progress — a file
    ///   that can't be read, or whose only outstanding bytes are an
    ///   unterminated last line, would otherwise keep `remaining` stuck
    ///   above 0 forever (`StatsScanner.scan` now latches `size` on that
    ///   file so it normally won't even get this far, but this is the
    ///   backstop) — and a hard cap at `maxPasses` besides.
    /// - The repo scan: started once, right after the first transcript
    ///   chunk (it needs that chunk's `cwds`), as its own detached task.
    ///   When it finishes — however long that takes — it merges its days
    ///   into whatever `days` currently holds and republishes.
    ///
    /// `scanning` stays true until both are done.
    /// The lease table (#223 phase 5): a scan runs only while some client
    /// — the Mac's own popup counts — holds `stats`; nil scans freely.
    var leases: LeaseTable?

    func refresh() {
        guard enabled, !scanning, leases?.holds(.stats) ?? true else { return }
        scanning = true
        transcriptsFinished = false
        let store = eventStore
        let repos = repoScanner
        Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let projectsDir = TokenRateScanner.defaultProjectsDir()
            let codexDir = StatsScanner.defaultCodexDir()
            let cacheURL = StatsScanner.defaultCacheURL()
            let events = await store.load()
            let eventDays = StatsEvents.days(events, calendar: calendar)
            var firstChunk = true
            var remaining = 1
            var passCount = 0
            var cumulativeConsumed = 0
            var firstBytesTotal: Int?
            var previousBytesRemaining = Int.max
            let cacheHandle = StatsScanner.CacheHandle()   // decoded once per loop, not per pass
            var entries: [String: StatsScanner.FileEntry] = [:]
            while remaining > 0 {
                passCount += 1
                let transcripts = StatsScanner.scan(projectsDir: projectsDir, codexDir: codexDir, cacheURL: cacheURL,
                                                    calendar: calendar, byteBudget: Self.chunkByteBudget,
                                                    handle: cacheHandle)
                remaining = transcripts.remaining
                entries = transcripts.entries
                if firstBytesTotal == nil { firstBytesTotal = transcripts.bytesTotal }
                let consumedThisPass = transcripts.bytesTotal - transcripts.bytesRemaining
                cumulativeConsumed += max(0, consumedThisPass)
                let stuck = consumedThisPass <= 0 || transcripts.bytesRemaining >= previousBytesRemaining
                previousBytesRemaining = transcripts.bytesRemaining

                var merged = transcripts.days
                for (k, d) in eventDays { merged[k] = (merged[k] ?? Stats.Day()) + d }
                var chunkNotes: [String] = ["\(transcripts.files) transcripts"]
                if let first = events.first { chunkNotes.append("switches and limits since \(first.at.formatted(date: .abbreviated, time: .omitted))") }
                let scannedMB = cumulativeConsumed / (1024 * 1024)
                let totalMB = (firstBytesTotal ?? transcripts.bytesTotal) / (1024 * 1024)
                let filesLeft = Self.grouped(remaining)
                await MainActor.run {
                    self.transcriptDays = merged
                    self.recomputeDays(calendar: calendar)
                    self.transcriptNotes = chunkNotes
                    self.recomputeNotes()
                    self.lastRefresh = Date()
                    self.progress = remaining > 0
                        ? "scanned \(scannedMB) MB of \(totalMB) MB (\(filesLeft) files left)"
                        : nil
                }
                if firstChunk {
                    firstChunk = false
                    let cwds = transcripts.cwds
                    let started = await MainActor.run { () -> Bool in
                        guard !self.repoScanRunning else { return false }
                        self.repoScanRunning = true
                        return true
                    }
                    if started {
                        Task.detached(priority: .utility) {
                            let since = calendar.date(byAdding: .day, value: -400, to: Date())!
                            let repoOutcome = await repos.scan(cwds: cwds, since: since)
                            await MainActor.run {
                                self.repoDays = repoOutcome.days
                                self.recomputeDays(calendar: calendar)
                                var built: [String] = ["\(repoOutcome.repos.count) repos"]
                                if !repoOutcome.skipped.isEmpty {
                                    built.append("no user.email — skipped: " + repoOutcome.skipped.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                }
                                if !repoOutcome.timedOut.isEmpty {
                                    built.append("timed out: " + repoOutcome.timedOut.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                }
                                built.append(repoOutcome.ghUsed ? "PRs from GitHub (gh)" : "PRs need gh: install and sign in (`gh auth login`)")
                                built.append(contentsOf: repoOutcome.notes)
                                self.repoNotes = built
                                self.recomputeNotes()
                                self.lastRefresh = Date()
                                self.markRepoScanDone()
                            }
                        }
                    }
                }
                if stuck || passCount >= Self.maxPasses { break }
            }
            await MainActor.run {
                self.progress = nil
                self.scanEntries = entries
                self.markTranscriptsDone()
            }
        }
    }
}
