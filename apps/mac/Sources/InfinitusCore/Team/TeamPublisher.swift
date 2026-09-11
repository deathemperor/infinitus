import Foundation
import Crypto

/// Spec §7: turns this machine's Claude Code files into the member's
/// documents and publishes them through `TeamClient`. `collect` is the
/// pure half (Task 4); publishing, chunking state and re-share follow
/// (Task 6).
public struct TeamPublisher {
    /// One transcript file to chunk: the session's own, or one of its
    /// sub-agents'.
    public struct TranscriptSource: Equatable {
        public var session: String
        public var agent: String?
        public var url: URL
        public init(session: String, agent: String?, url: URL) { self.session = session; self.agent = agent; self.url = url }

        /// `<session>` or `<session>/subagents/<agent>` — the cursor key
        /// and the store directory (spec §4.3, `TeamKinds`).
        public var key: String { agent.map { "\(session)/subagents/\($0)" } ?? session }
        public func chunkPath(seq: Int) -> String { "transcripts/\(key)/\(seq).jsonl" }
    }

    /// One session the transcript picker can offer (spec §7): read from
    /// the publisher's own scan cache, never by walking the corpus.
    public struct TranscriptSession: Identifiable, Equatable, Sendable {
        public var id: String
        public var project: String
        public var lastDay: String
        public var bytes: Int
        public init(id: String, project: String, lastDay: String, bytes: Int) {
            self.id = id; self.project = project; self.lastDay = lastDay; self.bytes = bytes
        }
    }

    public struct Collected: Equatable {
        public var days: [String: Stats.Day] = [:]
        public var sessions: [TeamDocs.SessionRow] = []
        public var transcripts: [TranscriptSource] = []
        public init() {}
    }

    /// How far a publish has got, for a UI that must not tick. Fired once
    /// per transcript source chunked and once per batch pushed — never
    /// per chunk: a 9 GB corpus is thousands of chunks and each hop to the
    /// main actor commits a CA transaction. Sealing is not a phase of its
    /// own: `TeamClient.publish` seals and pushes in one call.
    public struct Progress: Equatable, Sendable {
        /// "scan" — a source was chunked; "push" — a batch reached the remote.
        public var phase: String
        /// Transcript sources chunked so far, of `total` this pass will chunk.
        public var done: Int
        public var total: Int
        public init(phase: String, done: Int, total: Int) { self.phase = phase; self.done = done; self.total = total }
    }

    /// The same rule `StatsScanner.scan` walks with: `<project>/<sid>.jsonl`
    /// is a session, `<project>/<sid>/subagents/<agent>.jsonl` one of its
    /// sub-agents. For Codex files the "project dir" is a date; callers
    /// ignore it there.
    public static func transcriptIdentity(_ path: String) -> (session: String, agent: String?, projectDir: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            let sessionDir = parent.deletingLastPathComponent()
            return (sessionDir.lastPathComponent, url.deletingPathExtension().lastPathComponent,
                    sessionDir.deletingLastPathComponent().lastPathComponent)
        }
        return (url.deletingPathExtension().lastPathComponent, nil, parent.lastPathComponent)
    }

    /// Folds the scan's per-file entries minus excluded projects: days
    /// (Stats v2 `+`), one row per session (sub-agents summed in), and
    /// the Claude Code transcript files to chunk. Codex files are
    /// chunked by nobody — only their days and session row travel.
    /// `transcriptFloorDay` (a `Stats.dayKey`): a Claude file with no day
    /// on or after it is folded into days and sessions but not chunked.
    /// Day keys, not `lastAt`: sub-agent files carry days but no session
    /// times, and ISO day keys compare as strings.
    public static func collect(entries: [String: StatsScanner.FileEntry], exclusions: TeamExclusions,
                               transcriptFloorDay: String? = nil) -> Collected {
        var out = Collected()
        var rows: [String: TeamDocs.SessionRow] = [:]
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let identity = transcriptIdentity(path)
            let claude = entry.engine == Stats.Engine.claude.rawValue
            if exclusions.excludes(cwd: entry.cwd, projectDir: claude ? identity.projectDir : nil) { continue }
            let days = entry.daysWithOpenStretch()
            for (key, day) in days { out.days[key] = (out.days[key] ?? Stats.Day()) + day }

            let project = entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var row = rows[identity.session]
                ?? TeamDocs.SessionRow(id: identity.session, project: project ?? String(identity.projectDir.split(separator: "-").last ?? ""), engine: entry.engine)
            // A sub-agent file seen first carries no cwd; the session's own file names the project.
            if let project, identity.agent == nil { row.project = project }
            for t in entry.state.firstAt.values {
                row.startedAt = row.startedAt == 0 ? Int(t) : min(row.startedAt, Int(t))
            }
            for t in entry.state.lastAt.values { row.endedAt = max(row.endedAt, Int(t)) }
            for day in days.values {
                row.waitingMinutes += Int(day.waitingSeconds / 60)
                row.usd += day.usd
                for (label, tally) in day.activities {
                    let minutes = Int(tally.seconds / 60)
                    row.activities[label, default: 0] += minutes
                    row.busyMinutes += minutes
                }
            }
            if identity.agent != nil { row.subagents += 1 }
            rows[identity.session] = row
            let recent = transcriptFloorDay.map { (entry.days.keys.max() ?? "") >= $0 } ?? true
            if claude, recent { out.transcripts.append(TranscriptSource(session: identity.session, agent: identity.agent, url: URL(fileURLWithPath: path))) }
        }
        for key in out.days.keys { out.days[key]!.finalizePeak() }
        out.sessions = rows.values.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        return out
    }

    /// Claude Code sessions with activity on or after the `days` floor,
    /// newest day first — what Settings › Team lists when the member
    /// picks sessions by hand. Reads `scan-cache.json` (tens of MB in
    /// real use), so it runs on the team queue, never the main actor.
    /// Codex files are not chunked by anyone, so they are not offered.
    public static func recentTranscriptSessions(cacheURL: URL, days: Int, exclusions: TeamExclusions = TeamExclusions(),
                                                calendar: Calendar = .current, now: Date = Date()) -> [TranscriptSession] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(StatsScanner.Cache.self, from: data) else { return [] }
        return recentTranscriptSessions(entries: cache.files, days: days, exclusions: exclusions, calendar: calendar, now: now)
    }

    /// The same list off a scan already in hand (`Sources.entries`).
    public static func recentTranscriptSessions(entries: [String: StatsScanner.FileEntry], days: Int,
                                                exclusions: TeamExclusions = TeamExclusions(),
                                                calendar: Calendar = .current, now: Date = Date()) -> [TranscriptSession] {
        let floorDate = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        let floor = Stats.dayKey(floorDate, calendar: calendar)
        var out: [String: TranscriptSession] = [:]
        for (path, entry) in entries {
            guard entry.engine == Stats.Engine.claude.rawValue else { continue }
            let identity = transcriptIdentity(path)
            if exclusions.excludes(cwd: entry.cwd, projectDir: identity.projectDir) { continue }
            // Day keys, not `lastAt`: a sub-agent file carries days but no
            // session times (same rule as `collect`), and ISO day keys
            // compare as strings.
            guard let lastDay = entry.days.keys.max(), lastDay >= floor else { continue }
            let project = entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var row = out[identity.session]
                ?? TranscriptSession(id: identity.session, project: project ?? String(identity.projectDir.split(separator: "-").last ?? ""),
                                     lastDay: lastDay, bytes: 0)
            // A sub-agent file seen first carries no cwd; the session's own file names the project.
            if let project, identity.agent == nil { row.project = project }
            row.lastDay = max(row.lastDay, lastDay)
            row.bytes += entry.size
            out[identity.session] = row
        }
        return out.values.sorted { $0.lastDay == $1.lastDay ? $0.id < $1.id : $0.lastDay > $1.lastDay }
    }

    // MARK: publishing

    /// Everything a publish reads, injected so tests and the CLI point
    /// at any directory. `fleets`/`blockers` come from the app's fleet
    /// view (plan 5); the CLI sends none.
    public struct Sources {
        public var projectsDir: URL
        public var codexDir: URL?
        /// A scan cache of the publisher's OWN (never the app's, which
        /// the app writes concurrently).
        public var cacheURL: URL?
        /// A scan the caller already has (the app's StatsModel, which
        /// scans on its own cadence): set, `publish` scans nothing and
        /// `cacheURL` is left alone (#251 — two scans of one corpus at
        /// once took the app to 5.5 GB). Files without a day inside
        /// `historyDays` are dropped, as the scanner's `maxAge` drops them.
        public var entries: [String: StatsScanner.FileEntry]?
        public var liveSessions: [ClaudeSessionRecord] = []
        public var crashes: [CrashReport] = []
        public var fleets: [TeamDocs.Fleet] = []
        /// Every account of every fleet (`fleet.json`, #221); the CLI,
        /// which has no fleet view, sends none and the file is left alone.
        public var fleetRows: [TeamDocs.FleetDoc.FleetRow] = []
        public var blockers: [String] = []
        /// Team session control (#220): where a driver reaches this
        /// machine and what it lets whom do. Hints only; both optional so
        /// the CLI publisher (no listener) sends neither.
        public var endpoints: TeamControl.Endpoints?
        public var grantsTo: [TeamDocs.GrantHint]?
        public var home: String
        public var includeImages = false
        /// Days of `days/` files published and files scanned (`maxAge`).
        public var historyDays = 30
        /// Transcripts are chunked only from sessions active within this
        /// many days — stats keep `historyDays`. A month of one Mac's
        /// transcripts was 9 GB (2026-09-06): every chunk sealed in memory
        /// and pushed as one commit, past GitHub's 2 GB push cap.
        public static let defaultTranscriptDays = 2
        public var transcriptDays = Sources.defaultTranscriptDays
        /// Sealed bytes pushed per commit; the cursor state is saved after
        /// each, so a killed publish resumes instead of starting over.
        public var batchBytes = 200 << 20
        /// Bytes of a transcript read per pass (`TeamChunker.readCap`).
        /// Injected so a test can drive the catch-up path without a
        /// 64 MB fixture.
        public var readCapBytes = TeamChunker.readCap
        /// Plaintext copies under `published/` (what `reshare` re-wraps)
        /// are the one part of a team dir that grows without bound — a
        /// month of one Mac's transcripts was 9 GB. Above this the oldest
        /// transcript copies go; a later re-share covers what is left.
        public var copiesCapBytes = 1 << 30
        /// Called on the publishing thread (never the main actor); the app
        /// hops once per call.
        public var onProgress: (@Sendable (TeamPublisher.Progress) -> Void)?
        /// Checked once per transcript source, before chunking it: true
        /// flushes what is staged, saves the cursor and returns the report
        /// with `stopped`. A batch already inside `git push` still
        /// finishes — the per-batch state save is what makes a kill safe.
        public var shouldStop: (@Sendable () -> Bool)?
        public var calendar: Calendar = .current
        public init(projectsDir: URL, home: String) { self.projectsDir = projectsDir; self.home = home }
    }

    public struct Report: Equatable, Encodable {
        public var published: [String] = []
        public var transcriptChunks = 0
        /// Whole-object files whose content had not changed.
        public var skipped = 0
        /// Plaintext copies deleted to stay under `Sources.copiesCapBytes`.
        public var prunedCopies = 0
        /// Pre-split chunks (`m/<kid>/transcripts/…`, #414) deleted from
        /// the member branch's tree this pass.
        public var legacyChunksRemoved = 0
        /// True when `Sources.shouldStop` cut the pass short: what the
        /// report lists went out, the cursor is saved, the rest waits.
        public var stopped = false
        /// Bytes of the chosen transcripts this pass did not reach: what
        /// sits past `Sources.readCapBytes` in a big session, plus whole
        /// sources a `shouldStop` cut off. The pane says "catching up,
        /// N MB to go"; the next pass drains it.
        public var remainingBytes = 0
        public init() {}
    }

    public let client: TeamClient
    public let paths: TeamPaths

    public init(client: TeamClient, paths: TeamPaths) { self.client = client; self.paths = paths }

    public var teamDir: URL { paths.teamDir(client.config.id) }
    /// Plaintext copies of what was published (spec §7 "re-share history
    /// re-wraps the local plaintext copies"); grows with the transcripts.
    public var copiesDir: URL { teamDir.appendingPathComponent("published") }

    /// Sealed chunks of the batch being built (spec §7). Each is written
    /// here, pushed from here and deleted after its push, so the heap
    /// holds one chunk instead of a 200 MB batch. Cleared at the start
    /// and the end of every pass.
    public var spoolDir: URL { teamDir.appendingPathComponent("spool") }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        for byte in Crypto.SHA256.hash(data: data) {
            out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }

    /// `Stats.Day` carries two `Set<String>`s whose JSON order follows
    /// Swift's per-process hash seed, so the canonical bytes of an
    /// unchanged day differ between CLI runs; `peakMinute` follows the
    /// same seed on a tie (`finalizePeak` keeps the first maximum met).
    /// The change check hashes this copy instead: the sets emptied,
    /// their members alongside as sorted arrays; `peakMinute` blanked —
    /// it is derived from `minuteTokens`, which stays (a key-sorted
    /// object). Nothing dropped, so a change confined to them still
    /// republishes.
    struct DayDigest: Encodable {
        var doc: TeamDocs.DayDoc
        var sessions: [String]
        var repos: [String]
    }

    static func dayDigestBytes(_ doc: TeamDocs.DayDoc) throws -> Data {
        var copy = doc
        copy.stats.sessions = []
        copy.stats.repos = []
        copy.stats.peakMinute = nil
        return try CanonicalJSON.encode(DayDigest(doc: copy, sessions: doc.stats.sessions.sorted(), repos: doc.stats.repos.sorted()))
    }

    static func dayDigest(_ doc: TeamDocs.DayDoc) throws -> String { hex(try dayDigestBytes(doc)) }

    private func writeCopy(_ path: String, _ data: Data) throws {
        let url = copiesDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Trims `published/` back under `cap`, oldest first, TRANSCRIPT
    /// copies only: the day, session, now and crash copies are kilobytes
    /// and `reshare` needs every one of them. Returns how many went.
    @discardableResult
    func pruneCopies(cap: Int) -> Int { Self.pruneCopies(in: copiesDir, cap: cap) }

    /// One enumerator pass with the three keys it needs, not
    /// `subpathsOfDirectory` plus an `attributesOfItem` per file: that
    /// built a full attribute dictionary for each of a 5,000-copy store's
    /// files on every publish, ~0.8 s of the pass's CPU (#346). The keys
    /// used are the ones corelibs-foundation implements too (the Linux
    /// tests walk the same way in `Residue.size` and `Transcript.agentFiles`).
    static func pruneCopies(in copiesDir: URL, cap: Int) -> Int {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // The enumerator yields canonical paths (a temp dir's /var is
        // /private/var), and `resolvingSymlinksInPath` leaves /var alone
        // — so the root is canonicalised the same way for the prefix test.
        #if os(Windows)
        let root = copiesDir.standardizedFileURL
        #else
        var root = copiesDir
        if let real = realpath(copiesDir.path, nil) {
            root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
            free(real)
        }
        #endif
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        let transcripts = root.appendingPathComponent("transcripts").path + "/"
        var total = 0
        var candidates: [(url: URL, size: Int, at: Date)] = []
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            if url.path.hasPrefix(transcripts) {
                candidates.append((url, size, values.contentModificationDate ?? .distantPast))
            }
        }
        guard total > cap else { return 0 }
        var pruned = 0
        // Over the finite candidate list, not `while total > cap`: a cap
        // below what the non-transcript copies weigh must still terminate.
        for file in candidates.sorted(by: { $0.at == $1.at ? $0.url.path < $1.url.path : $0.at < $1.at }) {
            guard total > cap else { break }
            guard (try? fm.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            pruned += 1
        }
        return pruned
    }

    /// One push (spec §7 cadence is the caller's): days that changed in
    /// the window, the session index and `now.json` every time, the
    /// crash list on change, every new transcript chunk. State advances
    /// only after the push succeeded.
    public func publish(sources: Sources, now: Date = Date()) throws -> Report {
        guard client.isMember else { throw TeamClient.ClientError.notInTeam }
        let shares = TeamShares.load(teamDir: teamDir)
        // A kind shared with nobody is skipped entirely: never staged,
        // never chunked, never copied. `collect` only lists file URLs
        // (the scan itself has to run for the kinds that ARE shared), so
        // short-circuiting the staging is what keeps TeamChunker out of a
        // 9 GB corpus when transcripts are off.
        func off(_ kind: String) -> Bool { shares.target(for: kind) == .off }
        let transcriptsOff = off(TeamKinds.transcripts)
        let exclusions = TeamExclusions.load(paths: paths)
        var state = TeamPublishState.load(teamDir: teamDir)
        let at = Int(now.timeIntervalSince1970)
        let calendar = sources.calendar
        let entries: [String: StatsScanner.FileEntry]
        if let given = sources.entries {
            let floor = calendar.date(byAdding: .day, value: -sources.historyDays, to: calendar.startOfDay(for: now)) ?? .distantPast
            let floorDay = Stats.dayKey(floor, calendar: calendar)
            entries = given.filter { ($0.value.days.keys.max() ?? "") >= floorDay }
        } else {
            entries = StatsScanner.scan(projectsDir: sources.projectsDir, codexDir: sources.codexDir, cacheURL: sources.cacheURL,
                                        calendar: calendar, maxAge: Double(sources.historyDays) * 86_400, now: now).entries
        }
        let transcriptFloor = calendar.date(byAdding: .day, value: -sources.transcriptDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        let collected = Self.collect(entries: entries, exclusions: exclusions,
                                     transcriptFloorDay: Stats.dayKey(transcriptFloor, calendar: calendar))
        let choices = TeamTranscriptChoices.load(teamDir: teamDir)
        let toChunk = transcriptsOff ? [] : collected.transcripts.filter { choices.includes($0.session) }
        var chunked = 0
        func note(_ phase: String) { sources.onProgress?(Progress(phase: phase, done: chunked, total: toChunk.count)) }
        let redact = TeamRedaction.redactor(options: TeamRedaction.Options(home: sources.home, includeImages: sources.includeImages))
        var sealed: [TeamClient.SealedItem] = []
        var spooled = 0
        var pendingBytes = 0
        var report = Report()
        // A pass killed mid-batch leaves spool files behind; they are
        // re-sealed from the plaintext next time, so every pass starts
        // from an empty spool and clears it on the way out.
        try? FileManager.default.removeItem(at: spoolDir)
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        /// Seals one item into the spool. The plaintext is the caller's
        /// last reference to those bytes.
        func spool(_ item: TeamClient.PublishItem) throws {
            spooled += 1
            sealed.append(try client.seal(item, to: spoolDir.appendingPathComponent("\(spooled).bin"), now: at))
            pendingBytes += item.plaintext.count
        }

        // One commit per `batchBytes` of plaintext, state saved behind it:
        // a publish killed mid-way picks up at the last saved cursor.
        func flush() throws {
            guard !sealed.isEmpty else { return }
            report.published += try client.publish(sealed: sealed)
            for item in sealed { try? FileManager.default.removeItem(at: item.file) }
            sealed.removeAll()
            pendingBytes = 0
            try state.save(teamDir: teamDir)
            note("push")
        }

        // `digest` defaults to the canonical bytes; day files pass
        // `dayDigest` because their bytes are not stable across processes.
        func stage(_ kind: String, _ path: String, _ plaintext: Data, digest: String? = nil, always: Bool = false) throws {
            let digest = digest ?? Self.hex(plaintext)
            if !always, state.hashes[path] == digest { report.skipped += 1; return }
            try writeCopy(path, plaintext)
            try spool(TeamClient.PublishItem(kind: kind, path: path, plaintext: plaintext, audience: shares.target(for: kind)))
            state.hashes[path] = digest
        }

        /// What is left after this pass: every chosen source's size minus
        /// the offset its cursor reached (a line still missing its
        /// newline counts until it is complete). Sources a stop never
        /// reached count whole.
        func remaining() -> Int {
            var total = 0
            for source in toChunk {
                // `attributesOfItem`, not `resourceValues`: Core's tests run on Linux.
                let size = (try? FileManager.default.attributesOfItem(atPath: source.url.path))
                    .flatMap { ($0[.size] as? NSNumber)?.intValue } ?? 0
                total += max(0, size - (state.transcripts[source.key]?.offset ?? 0))
            }
            return total
        }

        let floor = calendar.date(byAdding: .day, value: -sources.historyDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        if !off(TeamKinds.stats) {
            for (key, day) in collected.days.sorted(by: { $0.key < $1.key }) {
                guard let date = Stats.date(fromDayKey: key, calendar: calendar), date >= floor else { continue }
                let doc = TeamDocs.DayDoc(day: key, stats: day)
                try stage(TeamKinds.stats, "days/\(key).json", try CanonicalJSON.encode(doc), digest: try Self.dayDigest(doc))
            }
        }
        if !off(TeamKinds.sessions) {
            try stage(TeamKinds.sessions, "sessions/index.json",
                      try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: at, sessions: collected.sessions, fleets: sources.fleets)),
                      always: true)
        }
        let live = sources.liveSessions
            .filter { !exclusions.excludes(cwd: $0.cwd, projectDir: TeamExclusions.slug($0.cwd)) }
            .map { TeamDocs.LiveSession(id: $0.sessionId, project: URL(fileURLWithPath: $0.cwd).lastPathComponent,
                                        status: $0.status ?? "", name: $0.name) }
        let today = calendar.startOfDay(for: now)
        let crashesToday = sources.crashes.filter { $0.at >= today }.count
        if off(TeamKinds.now) {
            // Turned off after a publish that sent one: a stale now.json
            // would keep this member "on" for the team forever. Retire it
            // once — the hash going away is what makes it once.
            if state.hashes.removeValue(forKey: "now.json") != nil { try client.unpublish(path: "now.json") }
        } else {
            var doc = TeamDocs.Now(at: at, sessions: live, fleets: sources.fleets, blockers: sources.blockers,
                                   crashesToday: crashesToday,
                                   // An older client's ShareTarget decoder throws on "off";
                                   // the hint carries only kinds that actually travel.
                                   // Every kind's EFFECTIVE audience, so a reader can tell
                                   // "unset, so leaders" from "off" (#321 fetches by it).
                                   sharesTo: Dictionary(uniqueKeysWithValues: TeamKinds.memberKinds.map { ($0, shares.target(for: $0)) })
                                       .filter { $0.value != .off })
            doc.endpoints = sources.endpoints
            doc.grantsTo = sources.grantsTo
            try stage(TeamKinds.now, "now.json", try CanonicalJSON.encode(doc), always: true)
        }
        if off(TeamKinds.fleet) {
            // Retired once, like now.json: a stale fleet would keep showing
            // accounts the member stopped sharing.
            if state.hashes.removeValue(forKey: "fleet.json") != nil { try client.unpublish(path: "fleet.json") }
        } else if !sources.fleetRows.isEmpty {
            // State, not history: written every pass like now.json, so
            // `at` is a truthful "as of" and the headroom board's 15-min
            // freshness rule reads it the way it reads `now`.
            try stage(TeamKinds.fleet, "fleet.json",
                      try CanonicalJSON.encode(TeamDocs.FleetDoc(at: at, fleets: sources.fleetRows)),
                      always: true)
        }
        if !off(TeamKinds.crashes) {
            try stage(TeamKinds.crashes, "crashes.json",
                      try CanonicalJSON.encode(TeamDocs.Crashes(crashes: sources.crashes.map(\.summary))))
        }

        note("scan")
        for source in toChunk {
            if sources.shouldStop?() == true {
                try flush()
                try state.save(teamDir: teamDir)
                report.stopped = true
                report.remainingBytes = remaining()
                report.prunedCopies = pruneCopies(cap: sources.copiesCapBytes)
                return report
            }
            try drainingPool {
                let cursor = state.transcripts[source.key] ?? TeamPublishState.Cursor()
                // `seq` on its own: mutating `cursor` inside the sink while
                // assigning to it outside would overlap access to it.
                var seq = cursor.seq
                let offset = try TeamChunker.stream(of: source.url, from: cursor.offset,
                                                    readCap: sources.readCapBytes, redact: redact) { chunk in
                    seq += 1
                    let path = source.chunkPath(seq: seq)
                    try writeCopy(path, chunk)
                    try spool(TeamClient.PublishItem(kind: TeamKinds.transcripts, path: path, plaintext: chunk,
                                                     audience: shares.target(for: TeamKinds.transcripts)))
                    report.transcriptChunks += 1
                }
                state.transcripts[source.key] = TeamPublishState.Cursor(seq: seq, offset: offset)
                // Between sources, never inside one: the cursor a flush
                // saves must cover every chunk that flush pushed.
                if pendingBytes >= sources.batchBytes { try flush() }
            }
            chunked += 1
            note("scan")
        }

        try flush()
        try state.save(teamDir: teamDir)
        report.legacyChunksRemoved = try sweepLegacyChunks()
        report.remainingBytes = remaining()
        report.prunedCopies = pruneCopies(cap: sources.copiesCapBytes)
        return report
    }

    /// Transcripts moved to `t/<kid>` (#321) but a store from before the
    /// split kept the old chunks in `m/<kid>`'s tree: 1.3 GB, 8,400
    /// files, fetched by every new member with the routine `m/*` sync
    /// (#414). One ordinary commit drops them from the tip — the
    /// history behind it is #339's explicit compaction. A clean branch
    /// costs one listing per pass.
    func sweepLegacyChunks() throws -> Int {
        let legacy = try client.store.list("m/\(client.identity.kid)/transcripts/")
        guard !legacy.isEmpty else { return 0 }
        var removals: [String: Data?] = [:]
        for entry in legacy { removals.updateValue(nil, forKey: entry.path) }
        try client.store.putAll(removals)
        return legacy.count
    }

    /// Spec §6.5 / §7: re-wraps the local plaintext copies of the last
    /// `days` days to the CURRENT audiences and republishes them — after
    /// a promotion, or an audience change the member wants applied to
    /// history. Day files go by their date, everything else by the
    /// copy's modification time.
    public func reshare(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Report {
        guard client.isMember else { throw TeamClient.ClientError.notInTeam }
        let shares = TeamShares.load(teamDir: teamDir)
        let choices = TeamTranscriptChoices.load(teamDir: teamDir)
        let floor = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        var items: [TeamClient.PublishItem] = []
        let fm = FileManager.default
        // `subpathsOfDirectory` returns paths already relative to
        // `copiesDir` — `FileManager.enumerator(at:)` hands back resolved
        // URLs (macOS's temp dir is a `/var` -> `/private/var` symlink),
        // so counting `copiesDir`'s own `pathComponents` against them
        // drops the wrong prefix and every path fails `TeamKinds.expected`.
        guard let subpaths = try? fm.subpathsOfDirectory(atPath: copiesDir.path) else { return Report() }
        for path in subpaths {
            let url = copiesDir.appendingPathComponent(path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let kind = TeamKinds.expected(at: "m/\(client.identity.kid)/\(path)")?.kind else { continue }
            // Live state is never re-shared: the copy is stale, and it would
            // come back after `quit()` deleted it. The next publish rewraps it.
            if kind == TeamKinds.now { continue }
            // A kind the member turned off is not re-wrapped from the copies either.
            if shares.target(for: kind) == .off { continue }
            if kind == TeamKinds.transcripts {
                // `path` is copies-relative: transcripts/<session>/…
                let session = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                guard choices.includes(session) else { continue }
            }
            if kind == TeamKinds.stats {
                let key = String(url.deletingPathExtension().lastPathComponent)
                guard let date = Stats.date(fromDayKey: key, calendar: calendar), date >= floor else { continue }
            } else {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard mtime >= floor else { continue }
            }
            items.append(TeamClient.PublishItem(kind: kind, path: path, plaintext: try Data(contentsOf: url),
                                                audience: shares.target(for: kind)))
        }
        items.sort { $0.path < $1.path }
        var report = Report()
        report.published = try client.publish(items, now: Int(now.timeIntervalSince1970))
        return report
    }

    /// Spec §7: `now.json` is deleted on quit.
    public func quit() throws { try client.unpublish(path: "now.json") }
}
