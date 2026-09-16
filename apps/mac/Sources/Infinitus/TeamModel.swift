import Foundation
import os
import InfinitusCore

/// The app's side of a team (spec §7 the loop, §9 the verbs) — headless
/// since #1313: the pane is Infinitus desktop's, over the `team-*`
/// control verbs. Every git or crypto call opens a `TeamClient` on a
/// private serial queue and hands back a Sendable result; the main actor
/// only holds the published snapshot. No timer: `refreshIfStale` rides
/// AppModel's refresh tick (like StatsModel) and does a fetch + publish
/// at most every 300 s. One team per Mac here (several stay CLI-only).
@MainActor
final class TeamModel: ObservableObject {
    nonisolated static let loopInterval: TimeInterval = 300

    @Published private(set) var snapshot: TeamSnapshot?
    @Published private(set) var reader: TeamReader?
    /// What a user-initiated action is doing ("Fetching…"); nil when idle.
    /// The background loop never sets it.
    @Published private(set) var busy: String?
    @Published private(set) var lastError: String?
    /// The team code or invite link minted last.
    @Published private(set) var code: String?
    /// The most recent publish pass's report (loop or `publishNow`); what
    /// `team-publish` replies with.
    @Published private(set) var lastReport: TeamPublisher.Report?
    /// The running publish's progress (spec §7), or nil when nothing is
    /// publishing. Set once per source and once per batch, never per chunk.
    @Published private(set) var progress: TeamPublisher.Progress?
    @Published private(set) var shares = TeamShares()
    @Published private(set) var exclusions = TeamExclusions()
    /// My identity's kid once read (never minted by a read).
    @Published private(set) var kid: String?
    /// `roster/team.json` as last loaded, signed; `nil` outside a team.
    @Published private(set) var roster: Signed<TeamRoster>?
    /// Approve requests that prove one of this leader's invite nonces
    /// (spec §6.2) without a tap. On by default; the proof is bound to
    /// the requester's kid (#161), so a copied request cannot ride an
    /// invite.
    @Published private(set) var autoApprove: Bool
    static let autoApproveKey = "team.autoApprove"

    /// False in mock / playground instances: every action is a no-op.
    var enabled = true
    /// Set by AppModel: what this Mac publishes (crashes, fleets, blockers).
    var sources: () -> TeamPublisher.Sources = { TeamPublisher.Sources(home: NSHomeDirectory(), machine: "Mac") }
    /// Set by AppModel: the desktop credential (#822) the loop reads the
    /// threads and transcripts with; nil publishes `desktop: false`.
    var desktopCredential: () -> (origin: URL, token: String)? = { nil }
    /// Set by AppModel: the Mac's tunnel URL while it is up, one of the
    /// doors a driver reaches this desktop through (spec §8).
    var tunnelURL: () -> String? = { nil }
    /// Delegated control (spec §8): this Mac's grants as last loaded.
    @Published private(set) var grants = TeamGrants()
    /// Drivers' commands waiting for this Mac's tap, as the snapshot lists them.
    @Published private(set) var pendingCommands: [TeamSnapshot.Pending] = []
    /// Set by AppModel: true when this instance scans its transcripts for
    /// itself (StatsModel), in which case the publisher never scans on
    /// its own (#251) — it publishes from `scanEntries`, and waits a tick
    /// while that is still nil (the first scan after launch).
    var ownsScan: () -> Bool = { false }
    var scanEntries: () -> [String: StatsScanner.FileEntry]? = { nil }
    /// The scan's generation, and the two ways back (#499): the table a
    /// fold came from is given back through `scanConsumed`, and a miss
    /// with nothing to fold asks StatsModel for a scan.
    var scanGeneration: () -> Int = { 0 }
    var scanConsumed: (Int) -> Void = { _ in }
    var scanRequested: () -> Void = {}
    /// One line to the app's event log.
    var onLog: ((String) -> Void)?

    let paths: TeamPaths
    let makeSecrets: @Sendable () -> TeamSecrets
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "run.infinitus.team", qos: .utility)
    /// Decrypted member docs, reused across loads while their blob version holds (#346).
    private let docCache = TeamReader.DocCache()
    private let scanCache = TeamReader.ScanCache()
    private let headerMemo = TeamClient.HeaderMemo()
    private var lastLoop: Date?
    private var loopRunning = false
    private var lastFetchAt: Int?
    private var lastPublishAt: Int?
    private var lastAggregatesAt: Int?
    static let aggregatesInterval = 3_600
    /// What this instance keeps of the app's scan between passes: the
    /// fold, not the table (#499).
    private var scanFold: ScanFold?
    /// Each thread's `updatedAt` when its transcript last went out, so a
    /// steady-state pass fetches nothing from the desktop.
    private var transcriptsFetched: [String: Int] = [:]
    private var loggedNoDesktop = false
    /// Set by `quit()`, read by the publisher between transcript sources.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
    /// Set while a user action waits on the team queue: the running
    /// publish yields at its next source instead of making Approve wait
    /// for the whole corpus on a slow store.
    private let yieldRequested = OSAllocatedUnfairLock(initialState: false)

    /// The control endpoint's in-memory half (spec §8): the waits and the
    /// rate buckets. The replay set, outbox and handled set live on disk
    /// beside `grants.json`. Every path that mutates them — the store
    /// pass after a fetch, `team-inbox` off the desktop route, a tap —
    /// runs on the team queue, so one endpoint at a time.
    private struct ControlMemory: Sendable {
        var pending: [String: TeamControl.PendingCommand] = [:]
        var limit = TeamControl.RateLimit()
        var heavyLimit = TeamControl.RateLimit.heavy
    }
    private let control = OSAllocatedUnfairLock(initialState: ControlMemory())

    private struct ScanFold: Sendable {
        var generation: Int
        var exclusions: TeamExclusions
        var floorDay: String
        var collected: TeamPublisher.Collected
    }

    init(paths: TeamPaths, makeSecrets: @escaping @Sendable () -> TeamSecrets, defaults: UserDefaults) {
        self.paths = paths
        self.makeSecrets = makeSecrets
        self.defaults = defaults
        autoApprove = defaults.object(forKey: Self.autoApproveKey) as? Bool ?? true
    }

    func setAutoApprove(_ on: Bool) {
        autoApprove = on
        defaults.set(on, forKey: Self.autoApproveKey)
    }

    var inTeam: Bool { snapshot != nil }
    var isLeader: Bool { snapshot?.role == "leader" }
    var policy: TeamRoster.Policy? { roster?.doc.policy }

    // MARK: background execution

    /// Runs `work` on the team queue with a fresh secrets store; the
    /// closure must open its own client (TeamClient is not Sendable).
    private func run<T: Sendable>(_ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> T) async throws -> T {
        let paths = self.paths, makeSecrets = self.makeSecrets
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work(paths, makeSecrets())) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// The single team on this Mac, or nil.
    private nonisolated static func teamID(_ paths: TeamPaths) -> String? { paths.teamIDs().sorted().first }

    private nonisolated static func openClient(_ paths: TeamPaths, _ secrets: TeamSecrets) throws -> TeamClient? {
        guard let id = teamID(paths) else { return nil }
        return try TeamClient.open(id: id, paths: paths, secrets: secrets)
    }

    /// Same intent as `TeamSnapshot.maskRemote`, for free-text errors:
    /// `TeamGit.GitError.failed` carries git's stderr verbatim, which
    /// echoes a credentialed remote (`https://user:token@host/repo.git`)
    /// on failure. Strips any `scheme://user[:pass]@` fragment rather
    /// than assuming the whole message is a bare URL.
    nonisolated static func mask(_ error: Error) -> String {
        if (error as? TeamIdentityExport.ExportError) == .badPassphrase { return "wrong passphrase" }
        let message = "\(error)"
        // The userinfo itself may contain "/" (a base64-ish token), so
        // only "@", whitespace and quotes end the match — erring toward
        // masking too much rather than leaking a credential that has one.
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z0-9+.-]*://)[^@\\s'\"]+@") else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, range: range, withTemplate: "$1")
    }

    /// Rebuilds the snapshot from the local clone (no network): status +
    /// reader + (leaders) the request list.
    private nonisolated static func snapshot(_ client: TeamClient, lastFetch: Int?, lastPublish: Int?, lastError: String?,
                                             shares: TeamShares, exclusions: TeamExclusions,
                                             docs: TeamReader.DocCache, scans: TeamReader.ScanCache,
                                             grants: TeamGrants, pending: [TeamSnapshot.Pending]) throws -> (TeamSnapshot, TeamReader?) {
        let status = try client.status()
        // One store scan per tick — none while the store's refs are what
        // the last pass saw (#499).
        let (_, reader) = TeamReader.scan(client: client, docs: docs, scans: scans)
        let requests = client.isLeader ? (try? client.requests()) ?? [] : []
        return (TeamSnapshot.make(status: status, roster: client.roster?.doc, reader: reader, requests: requests,
                                  today: Stats.dayKey(Date(), calendar: .current), lastFetch: lastFetch, lastPublish: lastPublish,
                                  lastError: lastError, shares: shares, exclusions: exclusions,
                                  grants: grants, pending: pending), reader)
    }

    /// The waits as the snapshot lists them: the driver named through the roster.
    private nonisolated static func pendingRows(_ memory: ControlMemory, roster: TeamRoster?) -> [TeamSnapshot.Pending] {
        memory.pending.values.map { entry in
            let c = entry.command
            return TeamSnapshot.Pending(id: c.id, kid: entry.driver, name: roster?.everyone.first { $0.keys.kid == entry.driver }?.name ?? entry.driver,
                                        thread: c.thread, action: c.action, text: c.text, project: c.project, expires: entry.expires)
        }.sorted { $0.expires == $1.expires ? $0.id < $1.id : $0.expires < $1.expires }
    }

    /// Every action ends here: reload the snapshot, settings and the kid.
    /// Returns the reload `Task` so an action can `await` it before
    /// replying — a control command must see the fresh snapshot.
    @discardableResult
    func load() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        let fetch = lastFetchAt, publish = lastPublishAt, err = lastError
        let docs = docCache, scans = scanCache, memo = headerMemo, control = control
        return Task {
            do {
                let result: (TeamSnapshot?, TeamReader?, TeamShares, TeamExclusions, String?, Signed<TeamRoster>?, TeamGrants) = try await run { paths, secrets in
                    // Non-creating: showing a kid must never mint (and, on
                    // a denied keychain read, clobber) an identity that
                    // exists but the process could not decrypt.
                    let kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                    let exclusions = TeamExclusions.load(paths: paths)
                    guard let client = try Self.openClient(paths, secrets) else { return (nil, nil, TeamShares(), exclusions, kid, nil, TeamGrants()) }
                    client.headerMemo = memo
                    let dir = paths.teamDir(client.config.id)
                    let shares = TeamShares.load(teamDir: dir)
                    let grants = TeamGrants.load(teamDir: dir)
                    let pending = Self.pendingRows(control.withLock { $0 }, roster: client.roster?.doc)
                    let (snap, reader) = try Self.snapshot(client, lastFetch: fetch, lastPublish: publish, lastError: err,
                                                          shares: shares, exclusions: exclusions, docs: docs, scans: scans,
                                                          grants: grants, pending: pending)
                    return (snap, reader, shares, exclusions, kid, client.roster, grants)
                }
                snapshot = result.0; reader = result.1; shares = result.2; exclusions = result.3; kid = result.4; roster = result.5
                grants = result.6; pendingCommands = result.0?.pending ?? []
            } catch {
                lastError = Self.mask(error)
            }
        }
    }

    // MARK: the loop (spec §7: fetch + publish, no prompt)

    /// Called from AppModel's refresh tick. Fetches, (leaders) approves
    /// invited requests, publishes, reloads — at most once per 300 s,
    /// never overlapping, never while a user action runs.
    func refreshIfStale(_ interval: TimeInterval = TeamModel.loopInterval) {
        guard enabled, inTeam, !loopRunning, busy == nil else { return }
        if let last = lastLoop, Date().timeIntervalSince(last) < interval { return }
        lastLoop = Date()
        loopRunning = true
        Task {
            defer { loopRunning = false }
            await loop(publish: true)
        }
    }

    /// (owns, entries, generation): what the publisher works from in this instance.
    private func appScan() -> (owns: Bool, entries: [String: StatsScanner.FileEntry]?, generation: Int) {
        let owns = ownsScan()
        return (owns, owns ? scanEntries() : nil, scanGeneration())
    }

    /// One fetch (+ publish) pass; errors land in `lastError`, never throw
    /// to the caller. Returns whether the pass succeeded.
    @discardableResult
    private func loop(publish: Bool) async -> Bool {
        let auto = autoApprove
        let aggregatesDue = lastAggregatesAt.map { Int(Date().timeIntervalSince1970) - $0 >= Self.aggregatesInterval } ?? true
        var prepared = self.sources()
        let scan = appScan()
        let fold = scanFold
        let fetched = transcriptsFetched
        let credential = desktopCredential()
        let tunnel = tunnelURL()
        let control = control
        let home = NSHomeDirectory()
        let stop = stopRequested
        prepared.onProgress = { [weak self] p in Task { @MainActor in self?.progress = p } }
        // A user action queued behind this pass asks the publisher to
        // cut at the next source (`yieldRequested`); the pass then
        // resumes on the next tick, not after `loopInterval`.
        let yield = yieldRequested
        prepared.shouldStop = { stop.withLock { $0 } || yield.withLock { $0 } }
        let sources = prepared
        defer { progress = nil }
        let memo = headerMemo, docs = docCache
        struct Pass: Sendable {
            var fetched: Int?
            var published: Int?
            var report: TeamPublisher.Report?
            var aggregated = false
            var fold: ScanFold?
            var foldBuilt = false
            var scanWanted = false
            var handed: [String: Int] = [:]
            var desktopError: String?
            var audits: [TeamControl.Audit] = []
        }
        do {
            let pass = try await run { paths, secrets -> Pass in
                var pass = Pass()
                guard let client = try Self.openClient(paths, secrets) else { return pass }
                client.headerMemo = memo
                // Pending: roster and requests only, until the roster admits
                // us — the member branches carry the transcripts (#321).
                _ = try client.fetch(branches: client.isMember ? nil : TeamClient.joinBranches)
                pass.fetched = Int(Date().timeIntervalSince1970)
                if auto { try Self.autoApprove(client, paths: paths) }
                guard client.isMember else { return pass }
                // Spec §8, the store lane: commands teammates left for this
                // Mac, and the acks of this Mac's own commands (reaped once read).
                let dir = paths.teamDir(client.config.id)
                pass.audits = try Self.withEndpoint(client: client, teamDir: dir, control: control, credential: credential, home: home) { ep in
                    var handled = TeamControl.Handled.load(teamDir: dir)
                    defer { try? handled.save(teamDir: dir) }
                    return try TeamControl.Store.grantorPass(client: client, endpoint: &ep, handled: &handled)
                }
                if let headers = try? client.readableHeaders(), let reader = try? TeamReader.load(client: client, headers: headers, cache: docs) {
                    _ = try? TeamControl.Store.driverReap(client: client, acks: reader.ackIDs, headers: headers)
                }
                guard publish else { return pass }
                var s = sources
                let hints = TeamGrants.load(teamDir: dir).hints
                s.grantsTo = hints.isEmpty ? nil : hints
                var ready = true
                if scan.owns {
                    // The app's scan, folded once per generation (#499). No
                    // fold and no table — the first scan after launch still
                    // running, or a miss after the table went back — fetch
                    // now, publish next tick: never scan the corpus twice.
                    let exclusions = TeamExclusions.load(paths: paths)
                    let floorDay = TeamPublisher.floorDay(now: Date(), historyDays: s.historyDays, calendar: s.calendar)
                    if let fold, fold.generation == scan.generation, fold.exclusions == exclusions, fold.floorDay == floorDay {
                        s.collected = fold.collected
                        pass.fold = fold
                    } else if let entries = scan.entries {
                        let collected = TeamPublisher.collect(entries: TeamPublisher.inWindow(entries, floorDay: floorDay), exclusions: exclusions)
                        s.collected = collected
                        pass.fold = ScanFold(generation: scan.generation, exclusions: exclusions, floorDay: floorDay, collected: collected)
                        pass.foldBuilt = true
                    } else {
                        ready = false
                        pass.scanWanted = true
                    }
                }
                guard ready else { return pass }
                // Threads and transcripts are the desktop's; without it
                // the index stays as last published and now.json says so.
                if let credential {
                    let api = DesktopAPI(origin: credential.origin, token: credential.token)
                    // Where a driver reaches this desktop (spec §8): only
                    // worth publishing while something is granted.
                    if s.grantsTo != nil, let descriptor = try? api.descriptor() {
                        s.endpoints = TeamControl.Endpoints(httpBaseUrl: credential.origin.absoluteString,
                                                            lanHttpBaseUrls: descriptor.lanHttpBaseUrls, tunnel: tunnel)
                    }
                    do {
                        pass.handed = try TeamThreadSources.desktop(api, into: &s,
                                                                    choices: TeamTranscriptChoices.load(teamDir: dir),
                                                                    exclusions: TeamExclusions.load(paths: paths), fetched: fetched,
                                                                    now: Int(Date().timeIntervalSince1970))
                    } catch {
                        s.desktop = false; s.threads = []; s.live = []; s.transcripts = []
                        pass.desktopError = Self.mask(error)
                    }
                }
                pass.report = try TeamPublisher(client: client, paths: paths).publish(sources: s)
                pass.published = Int(Date().timeIntervalSince1970)
                if aggregatesDue, client.isLeader {
                    // Don't let an aggregates-only failure erase the
                    // publish that just succeeded; retry next tick
                    // since `aggregated` stays false.
                    do { try Self.publishAggregates(client); pass.aggregated = true }
                    catch { Lifecycle.log.error("aggregates publish: \(Self.mask(error), privacy: .public)") }
                }
                return pass
            }
            if let at = pass.fetched { lastFetchAt = at }
            if let at = pass.published { lastPublishAt = at }
            if let report = pass.report {
                lastReport = report
                if report.stopped, !stop.withLock({ $0 }) { lastLoop = nil }
                else { transcriptsFetched.merge(pass.handed) { _, new in new } }
            }
            if pass.aggregated { lastAggregatesAt = Int(Date().timeIntervalSince1970) }
            if let fold = pass.fold { scanFold = fold }
            if pass.foldBuilt { scanConsumed(scan.generation) }
            if pass.scanWanted { scanRequested() }
            if let why = pass.desktopError { onLog?("Infinitus desktop did not answer; threads left as last published (\(why))") }
            for audit in pass.audits { onLog?(Self.auditLine(audit, roster: roster?.doc)) }
            if publish, credential == nil, pass.published != nil, !loggedNoDesktop {
                loggedNoDesktop = true
                onLog?("no Infinitus desktop credential: the team sees this Mac's stats, not its threads")
            }
            lastError = nil
            await load().value
            return true
        } catch {
            lastError = Self.mask(error)
            await load().value
            return false
        }
    }

    /// Leaders: approve every pending request whose nonce is in the
    /// invite book (one round trip, no tap); each nonce is spent once.
    /// The book is saved after the prune and after every consumed nonce
    /// (not once at the end), so one request's failure can't leave an
    /// already-approved member's nonce looking unspent on disk; that
    /// request's error is swallowed (left for a manual Approve) instead
    /// of aborting the rest of the pass.
    private nonisolated static func autoApprove(_ client: TeamClient, paths: TeamPaths) throws {
        guard client.isLeader else { return }
        let dir = paths.teamDir(client.config.id)
        var book = TeamInvites.load(teamDir: dir)
        let now = Int(Date().timeIntervalSince1970)
        let before = book.nonces
        book.prune(now: now)
        if book.nonces != before { try book.save(teamDir: dir) }
        for request in try client.requests() {
            guard let nonce = book.matches(request.doc, now: now) else { continue }
            do { try client.approve(kid: request.doc.keys.kid, now: now) }
            catch is TeamClient.ClientError { continue }
            book.consume(nonce)
            try book.save(teamDir: dir)
        }
    }

    /// Leaders publish `roster/aggregates/<period>.json` (spec §8.3),
    /// hourly from the loop. All four periods in one push.
    private nonisolated static func publishAggregates(_ client: TeamClient) throws {
        guard client.isLeader, let roster = client.roster?.doc else { return }
        let reader = try TeamReader.load(client: client)
        var docs: [String: Data] = [:]
        for p in Stats.Period.allCases {
            docs[p.rawValue] = try CanonicalJSON.encode(TeamInsights.aggregates(reader, roster: roster, period: p))
        }
        _ = try client.publishAggregates(docs)
    }

    /// Spec §7: `now.json` is deleted on quit, so teammates stop seeing
    /// this Mac "on". Only when this run published (nothing else put a
    /// `now.json` there — deleting an absent path would push an empty
    /// commit). Bounded: the team queue is serial, so a loop pass mid-push
    /// could hold this for as long as git does; the stop flag lets that
    /// pass return between transcript sources, termination waits at most
    /// `quitBound` and the child dies with the app.
    static let quitBound: TimeInterval = 20
    func quit() async {
        // Before the guard: a first-ever publish is still in flight when
        // `lastPublishAt` is nil, and it must still see the flag.
        stopRequested.withLock { $0 = true }
        guard enabled, inTeam, lastPublishAt != nil else { return }
        let paths = self.paths, makeSecrets = self.makeSecrets
        let fired = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Whichever comes first resumes; the other finds `fired` set.
            let finish: @Sendable () -> Void = {
                let first = fired.withLock { f -> Bool in if f { return false }; f = true; return true }
                if first { cont.resume() }
            }
            queue.async {
                if let client = try? Self.openClient(paths, makeSecrets()), client.isMember {
                    try? TeamPublisher(client: client, paths: paths).quit()
                }
                finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.quitBound, execute: finish)
        }
    }

    // MARK: insights (spec §8.3)

    struct Insights: Equatable {
        var rows: [TeamInsights.MemberRow]
        var repos: [TeamInsights.RepoRow]
        var cost: TeamInsights.Cost
        var blockers: [TeamInsights.Blocker]
        var headroom: [TeamInsights.Headroom]
        var hours: [Int]
        var onNow: [String]
    }

    /// Leader insights (spec §8.3) over the reader `load()` already
    /// built — a few dictionary folds, fine on the main actor.
    func insights(period: Stats.Period) -> Insights? {
        guard let reader, isLeader else { return nil }
        let rows = TeamInsights.comparison(reader, period: period)
        let repos = TeamInsights.repos(reader, period: period)
        return Insights(rows: rows, repos: repos, cost: TeamInsights.cost(rows, repos: repos),
                        blockers: TeamInsights.blockers(reader), headroom: TeamInsights.headroom(reader),
                        hours: TeamInsights.hours(rows),
                        onNow: TeamInsights.whoIsOn(reader).map(\.name))
    }

    // MARK: identity (spec §2.1) — the secret is shown only as the recovery key, after Touch ID

    func recoveryKey() async -> String? {
        guard enabled else { return nil }
        switch await BiometricLock.authenticate(reason: "show your team identity's recovery key") {
        case .ok: break
        case .cancelled: return nil
        case .failed(let why): lastError = why; return nil
        }
        do {
            return try await run { paths, secrets in RecoveryKey.encode(try TeamClient.identity(paths: paths, secrets: secrets).secret) }
        } catch { lastError = Self.mask(error); return nil }
    }

    /// The identity sealed under `passphrase` (`TeamIdentityExport`), for
    /// the caller to write where it likes; nil ⇒ `lastError` says why.
    func exportIdentity(passphrase: String) async -> Data? {
        guard enabled, passphrase.count >= 8 else { lastError = "the passphrase needs at least 8 characters"; return nil }
        do {
            return try await run { paths, secrets in
                try TeamIdentityExport.export(secret: try TeamClient.identity(paths: paths, secrets: secrets).secret, passphrase: passphrase)
            }
        } catch { lastError = Self.mask(error); return nil }
    }

    // MARK: user actions

    /// Wraps a user action: busy label, error capture, reload. Returns
    /// THIS call's error, nil when it worked — `lastError` may already
    /// hold an older one when the call starts, and the reload afterwards
    /// can put a different one there, so a caller answering one request
    /// must use the return value.
    @discardableResult
    private func action(_ label: String, _ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> Void) async -> String? {
        guard enabled else { lastError = "team is disabled in this instance"; return lastError }
        busy = label
        yieldRequested.withLock { $0 = true }
        defer { busy = nil; yieldRequested.withLock { $0 = false } }
        var failure: String?
        do {
            try await run(work)
            lastError = nil
        } catch {
            failure = Self.mask(error)
            lastError = failure
        }
        await load().value
        return failure
    }

    private nonisolated static func member(_ paths: TeamPaths, _ secrets: TeamSecrets) throws -> TeamClient {
        guard let client = try openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
        return client
    }

    func fetchNow() async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        guard inTeam else { lastError = "not in a team"; return }
        busy = "Fetching…"; defer { busy = nil }
        await loop(publish: false)
    }

    /// This pass's report, nil when nothing was published (`lastError`
    /// says why, or the scan is still running).
    func publishNow() async -> TeamPublisher.Report? {
        guard enabled else { lastError = "team is disabled in this instance"; return nil }
        guard inTeam else { lastError = "not in a team"; return nil }
        busy = "Publishing…"; defer { busy = nil }
        lastReport = nil
        await loop(publish: true)
        if lastReport == nil, lastError == nil, ownsScan(), scanEntries() == nil {
            lastError = "publishing waits for this Mac's transcript scan to finish"
        }
        return lastReport
    }

    func create(name: String, remote: String, token: String?, leaderName: String) async -> String? {
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        let failure = await action("Creating team…") { paths, secrets in
            _ = try TeamClient.create(name: name, remote: remote, token: token, leaderName: leaderName, paths: paths, secrets: secrets)
        }
        lastLoop = Date()
        return failure
    }

    func join(code: String, name: String) async -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Host.current().localizedName ?? "Mac"
        return await action("Requesting to join…") { paths, secrets in
            _ = try TeamClient.request(code: code, name: name, devices: [device], platform: "macos", paths: paths, secrets: secrets)
        }
    }

    /// A team code (spec §6.3): no nonce, `days` of validity.
    func mintCode(days: Int) async -> String? {
        let minted = OSAllocatedUnfairLock<String?>(initialState: nil)
        await action("Making a code…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            let code = try client.code(expiresIn: days * 86_400)
            minted.withLock { $0 = code }
        }
        code = minted.withLock { $0 }
        return code
    }

    /// An invite link (spec §6.2): a code with a one-time nonce this
    /// leader remembers and auto-approves.
    func mintInvite(days: Int) async -> String? {
        let minted = OSAllocatedUnfairLock<String?>(initialState: nil)
        await action("Making an invite…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            let link: String = try TeamInvites.mint(client: client, teamDir: paths.teamDir(client.config.id), days: days)
            minted.withLock { $0 = link }
        }
        code = minted.withLock { $0 }
        return code
    }

    func approve(kid: String) async -> String? {
        await action("Approving…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            try client.approve(kid: kid)
        }
    }

    func decline(kid: String) async -> String? {
        await action("Declining…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            try client.decline(kid: kid)
        }
    }

    func remove(kid: String) async -> String? {
        await action("Removing…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            try client.remove(kid: kid)
        }
    }

    func promote(kid: String) async -> String? {
        await action("Promoting…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            try client.promote(kid: kid)
        }
    }

    /// Local setting (never sent): where one kind goes. Applies to the
    /// next publish; `infinitusctl team reshare` re-wraps history.
    func setShare(kind: String, target: TeamRoster.ShareTarget) async -> String? {
        await action("Saving…") { paths, _ in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var shares = TeamShares.load(teamDir: dir)
            shares.byKind[kind] = target
            try shares.save(teamDir: dir)
        }
    }

    /// Local setting (never sent): a project slug kept off every kind.
    func setExclusion(slug: String, on: Bool) async -> String? {
        await action("Saving…") { paths, _ in
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(slug, excluded: on)
            try exclusions.save(paths: paths)
        }
    }

    func setPolicy(requests: String) async -> String? {
        let seeEachOther = policy?.membersSeeEachOther ?? false
        return await action("Saving policy…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            _ = try client.fetch()
            try client.setPolicy(TeamRoster.Policy(requests: requests, membersSeeEachOther: seeEachOther))
        }
    }

    /// Spec §6.5: delete my files on the store, leave a note, forget the
    /// team locally (dir + token). The identity stays.
    func leave() async -> String? {
        let failure = await action("Leaving…") { paths, secrets in
            let client = try Self.member(paths, secrets)
            // Withdrawing a pending request must not first pull every branch (#321).
            _ = try? client.fetch(branches: client.isMember ? nil : TeamClient.joinBranches)
            try client.leave()
            secrets.delete(TeamClient.tokenName(client.config.id))
            try FileManager.default.removeItem(at: paths.teamDir(client.config.id))
        }
        code = nil
        transcriptsFetched = [:]
        return failure
    }

    // MARK: delegated control (spec §8)

    /// Builds the endpoint over the disk half (replay set, outbox) and the
    /// memory half, runs `body`, writes both back. Team queue only.
    private nonisolated static func withEndpoint<T>(client: TeamClient, teamDir: URL, control: OSAllocatedUnfairLock<ControlMemory>,
                                                    credential: (origin: URL, token: String)?, home: String,
                                                    _ body: (inout TeamControl.Endpoint) throws -> T) rethrows -> T {
        let api = credential.map { DesktopAPI(origin: $0.origin, token: $0.token) }
        let memory = control.withLock { $0 }
        var endpoint = TeamControl.Endpoint(
            identity: client.identity, roster: { client.roster?.doc }, grants: { TeamGrants.load(teamDir: teamDir) },
            threads: { api.map(TeamControlExecutor.threads) ?? [] },
            execute: { command in
                guard let api else { return TeamControl.Reply(outcome: TeamControl.Outcome.refused, detail: "no Infinitus desktop on this Mac") }
                return TeamControlExecutor.execute(command, api: api, home: home)
            },
            seen: TeamControl.SeenIDs.load(teamDir: teamDir), limit: memory.limit)
        endpoint.heavyLimit = memory.heavyLimit
        endpoint.pending = memory.pending
        endpoint.outbox = TeamControl.Outbox.load(teamDir: teamDir)
        defer {
            try? endpoint.seen.save(teamDir: teamDir)
            try? endpoint.outbox.save(teamDir: teamDir)
            control.withLock { $0 = ControlMemory(pending: endpoint.pending, limit: endpoint.limit, heavyLimit: endpoint.heavyLimit) }
        }
        return try body(&endpoint)
    }

    private nonisolated static func auditLine(_ audit: TeamControl.Audit, roster: TeamRoster?) -> String {
        let who = roster?.everyone.first { $0.keys.kid == audit.driver }?.name ?? audit.driver
        let target = audit.thread == TeamControl.machineThread ? "" : " on \(audit.thread)"
        return "\(who): \(audit.action)\(target) → \(audit.outcome)\(audit.detail.map { " (\($0))" } ?? "")"
    }

    /// `team-inbox`: one sealed command off the desktop's route, answered
    /// with the sealed ack, or nil when there is nobody to answer (not a
    /// member, not even an envelope) — a stranger learns nothing.
    func inbox(_ file: Data) async -> Data? {
        guard enabled else { return nil }
        let control = control, credential = desktopCredential(), home = NSHomeDirectory()
        let answered: (ack: Data?, audit: TeamControl.Audit?) = (try? await run { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { return (nil, nil) }
            let dir = paths.teamDir(client.config.id)
            return Self.withEndpoint(client: client, teamDir: dir, control: control, credential: credential, home: home) { ep in
                let (ack, audit, driverKeys) = TeamControl.handle(file, endpoint: &ep)
                guard let driverKeys, !ack.id.isEmpty else { return (nil, audit) }
                return (try? TeamControl.sealAck(ack, from: client.identity, to: driverKeys, at: ack.at), audit)
            }
        }) ?? (nil, nil)
        if let audit = answered.audit, audit.driver != "?" { onLog?(Self.auditLine(audit, roster: roster?.doc)) }
        if answered.audit != nil { load() }
        return answered.ack
    }

    /// The grantor's tap on a waiting command: the answer rides the outbox
    /// to the driver on the next store pass. nil ⇒ no such wait.
    func decide(_ id: String, allow: Bool) async -> TeamControl.Ack? {
        guard enabled else { return nil }
        let control = control, credential = desktopCredential(), home = NSHomeDirectory()
        let decided: (ack: TeamControl.Ack, audit: TeamControl.Audit)? = try? await run { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { return nil }
            return Self.withEndpoint(client: client, teamDir: paths.teamDir(client.config.id), control: control, credential: credential, home: home) { ep in
                TeamControl.decide(id, allow: allow, endpoint: &ep).map { ($0.ack, $0.audit) }
            }
        }
        if let decided { onLog?(Self.auditLine(decided.audit, roster: roster?.doc)) }
        await load().value
        return decided?.ack
    }

    func addGrant(audience: TeamRoster.ShareTarget, threads: TeamGrants.Threads, capabilities: Set<String>,
                  preauthorized: Set<String> = [], expires: Int? = nil) async -> TeamGrants.Grant? {
        let saved = OSAllocatedUnfairLock<TeamGrants.Grant?>(initialState: nil)
        await action("Granting…") { paths, _ in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var grants = TeamGrants.load(teamDir: dir)
            let grant = grants.add(audience: audience, threads: threads, capabilities: capabilities,
                                   preauthorized: preauthorized, expires: expires)
            try grants.save(teamDir: dir)
            saved.withLock { $0 = grant }
        }
        return saved.withLock { $0 }
    }

    func revokeGrant(id: String) async -> Bool {
        let removed = OSAllocatedUnfairLock(initialState: false)
        await action("Revoking…") { paths, _ in
            guard let teamID = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(teamID)
            var grants = TeamGrants.load(teamDir: dir)
            let did = grants.remove(id: id)
            try grants.save(teamDir: dir)
            removed.withLock { $0 = did }
        }
        return removed.withLock { $0 }
    }

    /// One exchange with a grantor's desktop (LAN or tunnel); the lane's
    /// own timeout caps a vanished peer.
    private nonisolated static let urlHTTP: TeamControl.Deliver.HTTP = { method, url, headers, body, timeout in
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<(Int, Data, Error?)>(initialState: (0, Data(), nil))
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.withLock { $0 = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), error) }
            done.signal()
        }.resume()
        done.wait()
        let (status, data, failure) = box.withLock { $0 }
        if let failure { throw failure }
        return (status, data)
    }

    /// One command to a teammate's thread: their desktop's doors first
    /// (as their last now.json hinted them), the store when none answers.
    /// nil ⇒ `lastError` says why.
    func drive(kid: String, thread: String, action: String, text: String?, project: String?) async -> TeamControl.Delivery? {
        guard enabled, inTeam else { lastError = "not in a team"; return nil }
        let endpoints = reader?.members[kid]?.now?.endpoints
        let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, thread: thread, action: action, text: text,
                                          project: project, at: Int(Date().timeIntervalSince1970))
        do {
            let delivery = try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { throw TeamControl.DriveError.noRoster }
                return try TeamControl.Drive.send(command, client: client, endpoints: endpoints, deliver: TeamControl.Deliver(http: Self.urlHTTP))
            }
            lastError = nil
            return delivery
        } catch {
            lastError = Self.mask(error)
            return nil
        }
    }

    struct AckRow: Encodable, Equatable {
        var id: String; var from: String; var outcome: String; var detail: String?; var at: Int
    }

    /// The answers to this Mac's store-lane commands, newest first, off
    /// the reader `load()` built.
    var acks: [AckRow] {
        var rows: [AckRow] = []
        for m in reader?.members.values ?? [:].values {
            for ack in m.acks.values { rows.append(AckRow(id: ack.id, from: m.kid, outcome: ack.outcome, detail: ack.detail, at: ack.at)) }
        }
        return rows.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
    }
}
