import AppKit
import SwiftUI
import os
import InfinitusCore

/// The app's side of a team (spec §9 Mac Team pane, §7 the loop). Every
/// git or crypto call opens a `TeamClient` on a private serial queue and
/// hands back a Sendable result; the main actor only holds the published
/// snapshot. No timer: `refreshIfStale` rides AppModel's refresh tick
/// (like StatsModel) and does a fetch + publish at most every 300 s.
/// One team per Mac in the pane (several teams stay CLI-only, `--team`).
/// The transcript picker's state, read in one pass on the team queue.
private struct TranscriptPicker: Sendable, Equatable {
    var choices = TeamTranscriptChoices()
    var recent: [TeamPublisher.TranscriptSession] = []
}

@MainActor
final class TeamModel: ObservableObject {
    static let paneTitle = "Team"
    static let loopInterval: TimeInterval = 300

    @Published private(set) var snapshot: TeamSnapshot?
    @Published private(set) var reader: TeamReader?
    /// What a user-initiated action is doing ("Fetching…"); nil when idle.
    /// The background loop never sets it.
    @Published private(set) var busy: String?
    @Published private(set) var lastError: String?
    /// The team code or invite link minted last; shown until the pane closes it.
    @Published private(set) var code: String?
    /// The most recent publish pass's report (loop or `publishNow`); what
    /// `team-publish` replies with.
    @Published private(set) var lastReport: TeamPublisher.Report?
    /// The running publish's progress (spec §7), or nil when nothing is
    /// publishing. Set once per source and once per batch, never per chunk.
    @Published private(set) var progress: TeamPublisher.Progress?
    /// git's latest progress line while a store command runs ("Receiving
    /// objects: 45% (…)", "waiting for the store to answer…"), nil
    /// between commands. Fed by `TeamGit.activity`, at most every ~2 s.
    @Published private(set) var storeActivity: String?
    @Published private(set) var shares = TeamShares()
    /// Team session control (#220): who may drive which of my sessions.
    @Published private(set) var grants = TeamGrants()
    /// Hostnames this leader minted (#220 §5.4): ids only, the token is a secret.
    @Published private(set) var hostnames: TeamHostnames.Ledger?
    @Published private(set) var cloudflareConfigured = false
    /// A leader gave this Mac a hostname: AppModel stores the token and starts the tunnel.
    var onHostname: ((TeamControl.Hostname, _ from: String) -> Void)?
    @Published private(set) var exclusions = TeamExclusions()
    /// Spec §7: which sessions' transcripts travel. `recentTranscripts`
    /// is filled only in `chosen` mode — the scan cache is tens of MB and
    /// decoding it on every reload for a picker nobody opened is pure IO.
    @Published private(set) var transcriptChoices = TeamTranscriptChoices()
    @Published private(set) var recentTranscripts: [TeamPublisher.TranscriptSession] = []
    /// My identity's kid once read (creating it on first use, like the CLI).
    @Published private(set) var kid: String?
    /// From an `infinitus://join/…` link (Task 6): the pane's Join field prefills.
    @Published var pendingCode: String?
    /// `roster/team.json` as last loaded, signed; `nil` outside a team. Set in `load()`.
    @Published private(set) var roster: Signed<TeamRoster>?
    /// A 2 s LAN browse's discoverable results (spec §6.4), on demand only.
    @Published private(set) var nearby: [TeamNearby.Peer] = []
    /// Invitations this Mac has been sent over the LAN (spec §6.4), each
    /// still sealed; the link inside is opened only by `acceptInvite`.
    @Published private(set) var invites: [TeamNearby.Invite] = []
    /// Leaders: LAN requests parked under the team (never reached the requests branch).
    @Published private(set) var pendingNearby: [Signed<TeamRequest>] = []
    @Published private(set) var scanning = false
    /// Nearby discoverability (spec §6.4): kept in `defaults` so
    /// `infinitusctl team-discoverable` and MirrorServer's
    /// `UserDefaults.didChangeNotification` observer see the same flag.
    @Published var discoverable: Bool {
        didSet {
            defaults.set(discoverable, forKey: TeamNearby.discoverableDefaultsKey)
            if discoverable != oldValue { onActed?() }   // the listener follows it (#356)
        }
    }
    /// Approve requests that prove one of this leader's invite nonces
    /// (spec §6.2) without a tap. On by default; the proof is bound to
    /// the requester's kid (#161), so a copied request cannot ride an
    /// invite.
    @Published private(set) var autoApprove: Bool
    static let autoApproveKey = "team.autoApprove"

    /// False in mock / playground instances: every action is a no-op.
    var enabled = true
    /// After every load: the mirror server rebuilds its control endpoint (#220).
    var onLoaded: (() -> Void)?
    /// After every user action (create/join/leave/approve…): the Bonjour
    /// standing re-advertises with the new role.
    var onActed: (() -> Void)?
    /// False in a mock or playground instance, which never advertises or
    /// scans — the pane says so instead of a silent toggle.
    @Published var nearbyAvailable = true
    /// After every fetch, on the team queue: the grantor's store-lane pass (#220 §5.3).
    var onFetched: (@Sendable (TeamClient) -> Void)?
    /// Set by AppModel: what this Mac publishes (projects dir, live sessions, crashes, fleets, blockers).
    var sources: () -> TeamPublisher.Sources = { TeamPublisher.Sources(projectsDir: URL(fileURLWithPath: "/nonexistent"), home: NSHomeDirectory()) }
    /// Set by AppModel: true when this instance scans its transcripts for
    /// itself (StatsModel), in which case the publisher never scans on
    /// its own (#251) — it publishes from `scanEntries`, and waits a tick
    /// while that is still nil (the first scan after launch).
    var ownsScan: () -> Bool = { false }
    var scanEntries: () -> [String: StatsScanner.FileEntry]? = { nil }
    var showSettings: (() -> Void)?

    let paths: TeamPaths
    let makeSecrets: @Sendable () -> TeamSecrets
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "run.infinitus.team", qos: .utility)
    /// Decrypted member docs, reused across loads while their blob version holds (#346).
    private let docCache = TeamReader.DocCache()
    private let scanCache = TeamReader.ScanCache()
    private let headerMemo = TeamClient.HeaderMemo()
    /// Driving a teammate (#220 §5.3): the network lanes and tail polls
    /// never touch the team queue; only the store publish rides `run`.
    private let driveQueue = DispatchQueue(label: "run.infinitus.team-drive", qos: .userInitiated)
    private let deliver = OSAllocatedUnfairLock(initialState: TeamControl.Deliver(http: TeamModel.urlHTTP, interfaces: []))
    private var lastLoop: Date?
    private var loopRunning = false
    private var lastFetchAt: Int?
    private var lastPublishAt: Int?
    /// Set by `quit()`, read by the publisher between transcript sources.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
    /// Set while a user action waits on the team queue: the running
    /// publish yields at its next source instead of making Approve wait
    /// for the whole corpus on a slow store.
    private let yieldRequested = OSAllocatedUnfairLock(initialState: false)

    init(paths: TeamPaths, makeSecrets: @escaping @Sendable () -> TeamSecrets, defaults: UserDefaults) {
        self.paths = paths
        self.makeSecrets = makeSecrets
        self.defaults = defaults
        autoApprove = defaults.object(forKey: Self.autoApproveKey) as? Bool ?? true
        discoverable = defaults.bool(forKey: TeamNearby.discoverableDefaultsKey)
        // Guarded: a hop enqueued as the command ended must not land
        // after the action's `defer` cleared the label.
        TeamGit.activity.set { [weak self] line in
            Task { @MainActor in
                guard let self, self.busy != nil || self.loopRunning else { return }
                // Belt and braces: only the last non-empty segment of
                // whatever git said, whichever line break it used.
                self.storeActivity = line.components(separatedBy: .newlines)
                    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? line
            }
        }
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

    private nonisolated static func today(_ calendar: Calendar = .current) -> String {
        Stats.dayKey(Date(), calendar: calendar)
    }

    /// Same intent as `TeamSnapshot.maskRemote`, for free-text errors:
    /// `TeamGit.GitError.failed` carries git's stderr verbatim, which
    /// echoes a credentialed remote (`https://user:token@host/repo.git`)
    /// on failure. Strips any `scheme://user[:pass]@` fragment rather
    /// than assuming the whole message is a bare URL.
    private nonisolated static func mask(_ error: Error) -> String {
        if (error as? TeamIdentityExport.ExportError) == .badPassphrase { return "wrong passphrase" }
        if let drive = error as? TeamControl.DriveError {
            switch drive {
            case .noRoster: return "not in a team"
            case .unknownKid(let kid): return "no teammate \(kid)"
            }
        }
        if let nearby = error as? TeamNearby.Client.ClientError {
            switch nearby {
            case .notALeader: return "that machine leads no team"
            case .keyMismatch(let s): return "the leader is not answering \(TeamNearby.keyPath) (\(s))"
            case .refused(let s): return "the leader refused the request (\(s))"
            case .unavailable: return "nearby discovery is not built for this platform yet"
            }
        }
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
                                             docs: TeamReader.DocCache, scans: TeamReader.ScanCache) throws -> (TeamSnapshot, TeamReader?, [TeamClient.ReadableHeader]) {
        let status = try client.status()
        // One store scan per tick — none while the store's refs are what
        // the last pass saw (#499): the reader, the driver's reap and the
        // hostname inbox all read these same headers.
        let (headers, reader) = TeamReader.scan(client: client, docs: docs, scans: scans)
        let requests = client.isLeader ? (try? client.requests()) ?? [] : []
        return (TeamSnapshot.make(status: status, roster: client.roster?.doc, reader: reader, requests: requests,
                                  today: today(), lastFetch: lastFetch, lastPublish: lastPublish, lastError: lastError), reader, headers)
    }

    /// Every action ends here: reload the snapshot, settings and the kid.
    /// Returns the reload `Task` so an action can `await` it before
    /// replying — a control command must see the fresh snapshot.
    @discardableResult
    func load() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        let fetch = lastFetchAt, publish = lastPublishAt, err = lastError
        let scan = appScan()
        let docs = docCache, scans = scanCache, memo = headerMemo
        return Task {
            do {
                let result: (TeamSnapshot?, TeamReader?, TeamShares, TeamExclusions, String?, Signed<TeamRoster>?, [Signed<TeamRequest>], TranscriptPicker, TeamGrants, HostnameState) = try await run { paths, secrets in
                    // Non-creating: showing a kid must never mint (and, on
                    // a denied keychain read, clobber) an identity that
                    // exists but the process could not decrypt.
                    let kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                    let exclusions = TeamExclusions.load(paths: paths)
                    guard let client = try Self.openClient(paths, secrets) else { return (nil, nil, TeamShares(), exclusions, kid, nil, [], TranscriptPicker(), TeamGrants(), HostnameState()) }
                    client.headerMemo = memo
                    let dir = paths.teamDir(client.config.id)
                    let (snap, reader, headers) = try Self.snapshot(client, lastFetch: fetch, lastPublish: publish, lastError: err, docs: docs, scans: scans)
                    // Driver side of the store lane (#220): my acked or stale
                    // commands go; a push-free scan when there are none.
                    if let reader { _ = try? TeamControl.Store.driverReap(client: client, acks: reader.ackIDs, headers: headers) }
                    // Member side of §5.4: a hostname a leader sealed to me, applied once per blob.
                    var hostnameState = HostnameState(ledger: TeamHostnames.Ledger.load(teamDir: dir),
                                                      configured: secrets.read(TeamHostnames.secretName) != nil)
                    var applied = TeamControl.Handled.load(teamDir: dir, name: TeamControl.Handled.hostnamesFile)
                    if let fresh = try? TeamHostnames.inbox(client: client, handled: &applied, headers: headers) {
                        hostnameState.fresh = fresh
                        try? applied.save(teamDir: dir, name: TeamControl.Handled.hostnamesFile)
                    }
                    let pendingNearby = client.isLeader ? TeamNearby.Store.pending(team: client.config.id, paths: paths) : []
                    let choices = TeamTranscriptChoices.load(teamDir: dir)
                    let recent: [TeamPublisher.TranscriptSession]
                    if choices.mode != .chosen { recent = [] }
                    else if let entries = scan.entries {
                        recent = TeamPublisher.recentTranscriptSessions(entries: entries, days: TeamPublisher.Sources.defaultTranscriptDays,
                                                                        exclusions: exclusions)
                    } else if scan.owns { recent = [] }   // the app's first scan is still running
                    else {
                        recent = TeamPublisher.recentTranscriptSessions(cacheURL: dir.appendingPathComponent("scan-cache.json"),
                                                                        days: TeamPublisher.Sources.defaultTranscriptDays,
                                                                        exclusions: exclusions)
                    }
                    let picker = TranscriptPicker(choices: choices, recent: recent)
                    return (snap, reader, TeamShares.load(teamDir: dir), exclusions, kid, client.roster, pendingNearby, picker, TeamGrants.load(teamDir: dir), hostnameState)
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    snapshot = result.0; reader = result.1; shares = result.2; exclusions = result.3; kid = result.4
                    roster = result.5; pendingNearby = result.6
                    transcriptChoices = result.7.choices; recentTranscripts = result.7.recent
                    grants = result.8
                    hostnames = result.9.ledger; cloudflareConfigured = result.9.configured
                }
                onLoaded?()
                if let fresh = result.9.fresh { onHostname?(fresh.hostname, fresh.from) }
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
        let sources = self.sources()
        Task {
            defer { loopRunning = false }
            await loop(sources: sources, publish: true)
        }
    }

    /// One fetch (+ publish) pass; errors land in `lastError`, never throw
    /// to the caller. Returns whether the pass succeeded.
    @discardableResult
    private func loop(sources: TeamPublisher.Sources, publish: Bool) async -> Bool {
        let auto = autoApprove
        let aggregatesDue = lastAggregatesAt.map { Int(Date().timeIntervalSince1970) - $0 >= Self.aggregatesInterval } ?? true
        var sources = sources
        let scan = appScan()
        sources.entries = scan.entries
        // The app's own scan has not finished since launch: fetch now,
        // publish next tick — never scan the corpus a second time.
        let publish = publish && (scan.entries != nil || !scan.owns)
        let stop = stopRequested, fetchedHook = onFetched
        sources.onProgress = { [weak self] p in Task { @MainActor in self?.progress = p } }
        // A user action queued behind this pass asks the publisher to
        // cut at the next source (`yieldRequested`); the pass then
        // resumes on the next tick, not after `loopInterval`.
        let yield = yieldRequested
        sources.shouldStop = { stop.withLock { $0 } || yield.withLock { $0 } }
        defer { progress = nil; storeActivity = nil }
        let memo = headerMemo
        do {
            let (fetched, published, report, aggregated) = try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { return (nil as Int?, nil as Int?, nil as TeamPublisher.Report?, false) }
                client.headerMemo = memo
                // Pending: roster and requests only, until the roster admits
                // us — the member branches carry the transcripts (#321).
                _ = try client.fetch(branches: client.isMember ? nil : TeamClient.joinBranches)
                let fetched = Int(Date().timeIntervalSince1970)
                fetchedHook?(client)
                if auto { try Self.autoApprove(client, paths: paths) }
                var published: Int?
                var report: TeamPublisher.Report?
                var aggregated = false
                if publish, client.isMember {
                    var s = sources
                    if s.entries == nil { s.cacheURL = paths.teamDir(client.config.id).appendingPathComponent("scan-cache.json") }
                    report = try TeamPublisher(client: client, paths: paths).publish(sources: s)
                    published = Int(Date().timeIntervalSince1970)
                    if aggregatesDue, client.isLeader {
                        // Don't let an aggregates-only failure erase the
                        // publish that just succeeded; retry next tick
                        // since `aggregated` stays false.
                        do { try Self.publishAggregates(client); aggregated = true }
                        catch { Lifecycle.log.error("aggregates publish: \(Self.mask(error), privacy: .public)") }
                    }
                }
                return (fetched, published, report, aggregated)
            }
            if let fetched { lastFetchAt = fetched }
            if let published { lastPublishAt = published }
            if let report {
                lastReport = report
                if report.stopped, !stop.withLock({ $0 }) { lastLoop = nil }
            }
            if aggregated { lastAggregatesAt = Int(Date().timeIntervalSince1970) }
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

    // MARK: insights (spec §8.3/§8.4)

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

    func sharedWithMe() -> [TeamInsights.ShareRow] {
        guard let reader, let roster, let kid else { return [] }
        return TeamInsights.sharedWithMe(reader, roster: roster.doc, me: kid)
    }

    // MARK: nearby (spec §6.4)

    /// A 2 s mDNS browse on the team queue (spec §6.4). On demand only —
    /// the section's Scan button and its first appearance — never a timer.
    func scanNearby() async {
        guard enabled, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            // My kid read beside the browse, not from `kid` (nil until the
            // first load() lands — the pane's scan can run first, and nil
            // matched nothing, so the Mac listed itself). Non-creating.
            let (peers, me) = try await run { _, secrets -> ([TeamNearby.Peer], String?) in
                let me = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                return (try TeamNearby.Client.browse(seconds: 2), me)
            }
            nearby = peers.filter { $0.discoverable && $0.kid != me }
        } catch { lastError = Self.mask(error) }
        await loadInvites()
    }

    /// An invitation can land while the pane sits open and nothing else
    /// reads that directory, so the Nearby scan refreshes it too. A file
    /// read on the team queue, no network.
    func loadInvites() async {
        guard enabled else { return }
        do { invites = try await run { paths, _ in TeamNearby.Store.invites(paths: paths) } }
        catch { lastError = Self.mask(error) }
    }

    /// A join request to a leader typed as `host[:port]` (#355): the
    /// key route resolves who is there, then the request goes exactly
    /// as it would to a discovered peer.
    func requestNearby(address: String, name: String) async {
        guard let (host, port) = TeamNearby.Client.parseAddress(address) else {
            lastError = "that is not an address — use host or host:port"; return
        }
        let device = Host.current().localizedName ?? "Mac"
        await action("Asking \(host) to join…") { paths, secrets in
            let peer = try TeamNearby.Client.peer(host: host, port: port, http: Self.blockingHTTP)
            _ = try TeamNearby.Client.request(to: peer, name: name, devices: [device], platform: "macos",
                                              paths: paths, secrets: secrets, http: Self.blockingHTTP)
        }
    }

    func requestNearby(_ peer: TeamNearby.Peer, name: String) async {
        let device = Host.current().localizedName ?? "Mac"
        await action("Asking \(peer.name) to join…") { paths, secrets in
            _ = try TeamNearby.Client.request(to: peer, name: name, devices: [device], platform: "macos",
                                              paths: paths, secrets: secrets, http: Self.blockingHTTP)
        }
    }

    /// One blocking exchange with a LAN peer, run on the team queue (the
    /// same shape the CLI uses; a 10 s cap so a vanished peer can't hang
    /// the queue).
    private nonisolated static let blockingHTTP: TeamNearby.Client.HTTP = { method, host, port, path, body in
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(bracketed):\(port)\(path)") else {
            throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad peer address \(host):\(port)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
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

    /// Leader: a LAN request that stayed pending (the joiner had no store
    /// credential) is pushed into the requests branch so Approve works on
    /// it like any other (spec §6.4).
    func pullNearbyRequest(_ signed: Signed<TeamRequest>) async {
        await action("Filing the request…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            try TeamNearby.Store.writeToRequestsBranch(team: client.config.id, signed: signed, paths: paths, secrets: secrets)
            let pendingFile = TeamNearby.Store.pendingDir(team: client.config.id, paths: paths).appendingPathComponent("\(signed.doc.keys.kid).json")
            try? FileManager.default.removeItem(at: pendingFile)
        }
    }

    /// Leader: seal an invite link to a discoverable peer and POST it
    /// (spec §6.4). Not gated — minting an invite is not gated either
    /// (`mintInvite`); the pane disables the button when the lock is off,
    /// the same shape the Invite section uses.
    func inviteNearby(_ peer: TeamNearby.Peer) async {
        let machine = Host.current().localizedName ?? "Mac"
        await action("Inviting \(peer.name)…") { paths, secrets in
            _ = try TeamNearby.Client.invite(to: peer, fromName: machine, paths: paths, secrets: secrets,
                                             http: Self.blockingHTTP)
        }
    }

    /// Accepting an invitation IS joining (spec §2.2 gate): open the
    /// sealed link with this machine's identity, request with the text
    /// exactly as sealed, then drop the invitation file. The leader
    /// auto-approves it — the nonce is one it minted.
    func acceptInvite(_ invite: TeamNearby.Invite, name: String) async {
        let device = Host.current().localizedName ?? "Mac"
        await action("Accepting…") { paths, secrets in
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let opened = try TeamNearby.openInvite(invite, identity: me)
            _ = try TeamClient.request(code: opened.text, name: name, devices: [device], platform: "macos",
                                       paths: paths, secrets: secrets)
            try TeamNearby.Store.removeInvite(from: invite.from.kid, paths: paths)
        }
        await loadInvites()
    }

    func ignoreInvite(_ invite: TeamNearby.Invite) async {
        await action("Ignoring…") { paths, _ in
            try TeamNearby.Store.removeInvite(from: invite.from.kid, paths: paths)
        }
        await loadInvites()
    }

    // MARK: policy + aggregates (spec §8.3)

    func setPolicy(requests: String, membersSeeEachOther: Bool) async {
        await action("Saving policy…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.setPolicy(TeamRoster.Policy(requests: requests, membersSeeEachOther: membersSeeEachOther))
        }
    }

    private var lastAggregatesAt: Int?
    static let aggregatesInterval = 3_600

    /// Leaders publish `roster/aggregates/<period>.json` (spec §8.3) —
    /// hourly from the loop, or now from the pane. All four periods in
    /// one push.
    private nonisolated static func publishAggregates(_ client: TeamClient) throws {
        guard client.isLeader, let roster = client.roster?.doc else { return }
        let reader = try TeamReader.load(client: client)
        var docs: [String: Data] = [:]
        for p in Stats.Period.allCases {
            docs[p.rawValue] = try CanonicalJSON.encode(TeamInsights.aggregates(reader, roster: roster, period: p))
        }
        _ = try client.publishAggregates(docs)
    }

    func publishAggregatesNow() async {
        var ok = false
        await action("Publishing the team picture…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try Self.publishAggregates(client)
            ok = true
        }
        if ok { lastAggregatesAt = Int(Date().timeIntervalSince1970) }
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

    func exportIdentity(passphrase: String, to url: URL) async -> Bool {
        guard enabled, passphrase.count >= 8 else { lastError = "the passphrase needs at least 8 characters"; return false }
        var ok = false
        await action("Exporting…") { paths, secrets in
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            try TeamIdentityExport.write(try TeamIdentityExport.export(secret: me.secret, passphrase: passphrase), to: url)
            ok = true
        }
        return ok
    }

    /// Replacing the identity while in a team would orphan the membership
    /// (the roster names the old kid) — refuse; Leave first.
    private func importable() -> Bool {
        if inTeam { lastError = "leave the team before replacing this Mac's identity"; return false }
        return true
    }

    func importIdentity(recoveryKey text: String) async -> Bool {
        guard enabled, importable() else { return false }
        guard let secret = RecoveryKey.decode(text) else { lastError = "that is not a recovery key"; return false }
        var ok = false
        await action("Importing…") { _, secrets in try secrets.write(TeamClient.identitySecretName, secret); ok = true }
        return ok
    }

    func importIdentity(file url: URL, passphrase: String) async -> Bool {
        guard enabled, importable() else { return false }
        var ok = false
        await action("Importing…") { _, secrets in
            let secret = try TeamIdentityExport.import(try Data(contentsOf: url), passphrase: passphrase)
            try secrets.write(TeamClient.identitySecretName, secret)
            ok = true
        }
        return ok
    }

    // MARK: user actions

    /// Wraps a user action: busy label, error capture, reload. Returns
    /// THIS call's error, nil when it worked — `lastError` may already
    /// hold an older one when the call starts, and the reload afterwards
    /// can put a different one there, so a caller answering one request
    /// (the phone's `ActionReply`) must use the return value.
    @discardableResult
    private func action(_ label: String, _ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> Void) async -> String? {
        guard enabled else { lastError = "team is disabled in this instance"; return lastError }
        busy = label
        yieldRequested.withLock { $0 = true }
        defer { busy = nil; storeActivity = nil; yieldRequested.withLock { $0 = false } }
        var failure: String?
        do {
            try await run(work)
            lastError = nil
        } catch {
            failure = Self.mask(error)
            lastError = failure
        }
        await load().value
        onActed?()
        return failure
    }

    // MARK: driving a teammate's session (#220 §5.3, §7.2)

    /// One exchange with a grantor's endpoint (LAN, hostname or tunnel);
    /// the lane's own timeout caps a vanished peer.
    private nonisolated static let urlHTTP: TeamControl.Deliver.HTTP = { method, url, headers, body, timeout in
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
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

    /// The capabilities `kid` granted me, from their published hint.
    func controls(grantedBy kid: String) -> Set<String> {
        Set(snapshot?.members.first { $0.kid == kid }?.controls ?? [])
    }

    /// The sessions of `kid` at least one of their grants to me names
    /// (a grant without a session list covers every session).
    func drivableSessions(of kid: String) -> [TeamDocs.LiveSession] {
        guard let me = self.kid, let roster, let now = reader?.members[kid]?.now else { return [] }
        return now.sessions.filter { TeamSnapshot.controls(hints: now.grantsTo, roster: roster.doc, me: me, session: $0.id) != nil }
    }

    private func onDriveQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            driveQueue.async {
                do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// One command to a teammate's session: the network lanes first, the
    /// store when none answers. nil ⇒ `lastError` says why.
    func drive(kid: String, session: String, action: String, text: String?) async -> TeamControl.Delivery? {
        guard enabled, inTeam else { lastError = "not in a team"; return nil }
        let endpoints = reader?.members[kid]?.now?.endpoints
        let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, session: session, action: action, text: text,
                                          at: Int(Date().timeIntervalSince1970))
        let paths = self.paths, makeSecrets = self.makeSecrets, deliver = self.deliver
        do {
            let network = try await onDriveQueue { () -> TeamControl.Delivery? in
                guard let client = try Self.openClient(paths, makeSecrets()), let roster = client.roster?.doc else {
                    throw TeamControl.DriveError.noRoster
                }
                return try deliver.withLock { d in
                    d.interfaces = InterfaceAddresses.ipv4()
                    return try TeamControl.Drive.network(command, identity: client.identity, roster: roster, endpoints: endpoints, deliver: &d)
                }
            }
            if let network { return network }
            return try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { throw TeamControl.DriveError.noRoster }
                return try TeamControl.Drive.store(command, client: client)
            }
        } catch {
            lastError = Self.mask(error)
            return nil
        }
    }

    /// My identity for the tail poll, read from the secrets store once per
    /// kid rather than per 3 s tick (a keychain read + roster load each time
    /// a driver window is open, otherwise).
    private let tailIdentity = OSAllocatedUnfairLock<TeamIdentity?>(initialState: nil)

    private nonisolated static func identity(_ secrets: TeamSecrets, cache: OSAllocatedUnfairLock<TeamIdentity?>, kid: String?) -> TeamIdentity? {
        if let cached = cache.withLock({ $0 }), cached.kid == kid { return cached }
        guard let secret = secrets.read(TeamClient.identitySecretName), let fresh = try? TeamIdentity(secret: secret) else { return nil }
        cache.withLock { $0 = fresh }
        return fresh
    }

    /// The session's feed off the grantor's tail route; nil when no
    /// network lane answers (the store never carries a tail).
    func tail(kid: String, session: String, since: String?) async -> (lane: TeamControl.Lane, feed: SessionFeed)? {
        guard enabled, inTeam else { return nil }
        let endpoints = reader?.members[kid]?.now?.endpoints
        let makeSecrets = self.makeSecrets, deliver = self.deliver, cache = self.tailIdentity, me = self.kid
        return try? await onDriveQueue { () -> (lane: TeamControl.Lane, feed: SessionFeed)? in
            guard let identity = Self.identity(makeSecrets(), cache: cache, kid: me) else { return nil }
            guard let (lane, body) = try deliver.withLock({ d in
                d.interfaces = InterfaceAddresses.ipv4()
                return try TeamControl.Drive.tail(kid: kid, session: session, since: since, identity: identity,
                                                  endpoints: endpoints, deliver: &d)
            }) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let feed = try? decoder.decode(SessionFeed.self, from: body) else { return nil }
            return (lane, feed)
        }
    }

    /// A teammate's session as chat items (decrypted now, off the main actor).
    func transcript(kid: String, session: String) async -> [SessionFeedItem] {
        guard enabled else { return [] }
        do {
            return try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { return [] }
                // The sender's transcript branch is not part of the routine
                // sync (#321); pull it now, and read what is local if the
                // store is unreachable.
                try? client.fetchTranscripts(from: kid)
                return try TeamReader.load(client: client).transcript(kid: kid, session: session, client: client, limit: 400)
            }
        } catch {
            lastError = Self.mask(error)
            return []
        }
    }

    func fetchNow() async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        guard inTeam else { lastError = "not in a team"; return }
        busy = "Fetching…"; defer { busy = nil }
        await loop(sources: sources(), publish: false)
    }

    func publishNow() async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        guard inTeam else { lastError = "not in a team"; return }
        busy = "Publishing…"; defer { busy = nil }
        await loop(sources: sources(), publish: true)
        let scan = appScan()
        if scan.owns, scan.entries == nil, lastError == nil { lastError = "publishing waits for this Mac's transcript scan to finish" }
    }

    /// (owns, entries): what the publisher works from in this instance.
    private func appScan() -> (owns: Bool, entries: [String: StatsScanner.FileEntry]?) {
        let owns = ownsScan()
        return (owns, owns ? scanEntries() : nil)
    }

    func create(name: String, remote: String, token: String?, leaderName: String) async {
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        await action("Creating team…") { paths, secrets in
            _ = try TeamClient.create(name: name, remote: remote, token: token, leaderName: leaderName, paths: paths, secrets: secrets)
        }
        lastLoop = Date()
    }

    @discardableResult
    func join(code: String, name: String) async -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Host.current().localizedName ?? "Mac"
        let failure = await action("Requesting to join…") { paths, secrets in
            _ = try TeamClient.request(code: code, name: name, devices: [device], platform: "macos", paths: paths, secrets: secrets)
        }
        pendingCode = nil
        return failure
    }

    /// A team code (spec §6.3): no nonce, `days` of validity.
    func mintCode(days: Int) async {
        var minted: String?
        await action("Making a code…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            minted = try client.code(expiresIn: days * 86_400)
        }
        if let minted { code = minted }
    }

    /// An invite link (spec §6.2): a code with a one-time nonce this
    /// leader remembers and auto-approves. `TeamInvites.mint` is the same
    /// call a LAN invite makes (spec §6.4), so both write one book.
    func mintInvite(days: Int) async {
        var minted: String?
        await action("Making an invite…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            minted = try TeamInvites.mint(client: client, teamDir: paths.teamDir(client.config.id), days: days)
        }
        if let minted { code = minted }
    }

    @discardableResult
    func approve(kid: String) async -> String? {
        await action("Approving…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.approve(kid: kid)
        }
    }

    @discardableResult
    func decline(kid: String) async -> String? {
        await action("Declining…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.decline(kid: kid)
        }
    }

    func remove(kid: String) async {
        await action("Removing…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.remove(kid: kid)
            // Their hostname goes with them when the token is at hand (#220 §5.4), else it lists as orphaned.
            if var ledger = TeamHostnames.Ledger.load(teamDir: client.teamDir) {
                _ = try TeamHostnames.forget(client: client, kid: kid, cloudflare: Self.cloudflare(secrets), ledger: &ledger)
                try ledger.save(teamDir: client.teamDir)
            }
        }
    }

    // MARK: hostnames (#220 §5.4)

    struct HostnameState: Sendable {
        var ledger: TeamHostnames.Ledger?
        var configured = false
        var fresh: (hostname: TeamControl.Hostname, from: String)?
    }

    private nonisolated static func cloudflare(_ secrets: TeamSecrets) -> TeamHostnames.Cloudflare? {
        secrets.read(TeamHostnames.secretName).flatMap { String(data: $0, encoding: .utf8) }.map { .init(token: $0, http: urlHTTP) }
    }

    func hostname(of kid: String) -> String? { hostnames?.records[kid]?.hostname }

    /// The token is checked against the zone before it is kept; ids cached, records of the same zone carried over.
    func saveCloudflare(zone: String, label: String, token: String) async {
        await action("Checking the token…") { paths, secrets in
            guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(team)
            var ledger = try TeamHostnames.ledger(zone: zone, label: label, teamDir: dir)
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try TeamHostnames.Cloudflare(token: trimmed, http: Self.urlHTTP).ids(ledger: &ledger)
            try secrets.write(TeamHostnames.secretName, Data(trimmed.utf8))
            try ledger.save(teamDir: dir)
        }
    }

    func forgetCloudflare() async {
        await action("Forgetting…") { _, secrets in secrets.delete(TeamHostnames.secretName) }
    }

    func giveHostname(kid: String) async {
        await action("Minting…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            guard var ledger = TeamHostnames.Ledger.load(teamDir: client.teamDir), let cf = Self.cloudflare(secrets) else {
                throw TeamHostnames.HostnameError.notConfigured
            }
            _ = try client.fetch()
            _ = try TeamHostnames.give(client: client, kid: kid, cloudflare: cf, ledger: &ledger)
            try ledger.save(teamDir: client.teamDir)
        }
    }

    /// An orphaned record (its member gone) once a token is present.
    func deleteHostname(kid: String) async {
        await action("Deleting…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            guard var ledger = TeamHostnames.Ledger.load(teamDir: client.teamDir), let cf = Self.cloudflare(secrets) else {
                throw TeamHostnames.HostnameError.notConfigured
            }
            _ = try TeamHostnames.forget(client: client, kid: kid, cloudflare: cf, ledger: &ledger)
            try ledger.save(teamDir: client.teamDir)
        }
    }

    func promote(kid: String) async {
        await action("Promoting…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.promote(kid: kid)
        }
    }

    /// Local setting (never sent): where one kind goes. Applies to the
    /// next publish; `reshare(days:)` re-wraps history on request.
    /// Team session control (#220): who may drive which of my sessions.
    func addGrant(audience: TeamRoster.ShareTarget, sessions: TeamGrants.Sessions, capabilities: Set<String>) async {
        await action("Saving…") { paths, _ in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var grants = TeamGrants.load(teamDir: dir)
            grants.add(audience: audience, sessions: sessions, capabilities: capabilities, now: Int(Date().timeIntervalSince1970))
            try grants.save(teamDir: dir)
        }
    }

    func revokeGrant(id: String) async {
        await action("Saving…") { paths, _ in
            guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(team)
            var grants = TeamGrants.load(teamDir: dir)
            _ = grants.remove(id: id)
            try grants.save(teamDir: dir)
        }
    }

    func setShare(kind: String, target: TeamRoster.ShareTarget) async {
        await action("Saving…") { paths, secrets in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var shares = TeamShares.load(teamDir: dir)
            shares.byKind[kind] = target
            try shares.save(teamDir: dir)
        }
    }

    /// Local setting (never sent): all recent sessions, or only the picked
    /// ones. Applies to the next publish; already-published chunks stay.
    func setTranscriptMode(_ mode: TeamTranscriptChoices.Mode) async {
        await action("Saving…") { paths, _ in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var choices = TeamTranscriptChoices.load(teamDir: dir)
            choices.mode = mode
            try choices.save(teamDir: dir)
        }
    }

    func setTranscript(_ id: String, shared: Bool) async {
        await action("Saving…") { paths, _ in
            guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(team)
            var choices = TeamTranscriptChoices.load(teamDir: dir)
            if shared { choices.chosen.insert(id) } else { choices.chosen.remove(id) }
            try choices.save(teamDir: dir)
        }
    }

    func setExcluded(_ project: String, on: Bool) async {
        let path = URL(fileURLWithPath: project).standardizedFileURL.path
        await action("Saving…") { paths, _ in
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(path, excluded: on)
            try exclusions.save(paths: paths)
        }
    }

    /// #339: rewrite my member branch to one commit (the only force-push
    /// the spec allows, on an explicit ask), then fetch so the mirror
    /// and the snapshot follow.
    func compact() async {
        await action("Compacting…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            _ = try client.compactOwnBranch()
            _ = try client.fetch()
        }
    }

    func reshare(days: Int) async {
        await action("Re-sharing…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            _ = try TeamPublisher(client: client, paths: paths).reshare(days: days)
        }
    }

    /// Spec §6.5: delete my files on the store, leave a note, forget the
    /// team locally (dir + token). The identity stays.
    func leave() async {
        await action("Leaving…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            // Withdrawing a pending request must not first pull every branch (#321).
            _ = try? client.fetch(branches: client.isMember ? nil : TeamClient.joinBranches)
            try client.leave()
            secrets.delete(TeamClient.tokenName(client.config.id))
            try FileManager.default.removeItem(at: paths.teamDir(client.config.id))
        }
        code = nil
    }

    func clearCode() { code = nil }
    func clearError() { lastError = nil }

    /// `infinitus://join/<payload>` (spec §6.2): verified at request time
    /// by `TeamCode.decode`; here the pane just gets it prefilled. False
    /// for any other URL. Already in a team (the pane has no Join field
    /// then): says so instead of prefilling nothing — best effort, since
    /// a cold-launch replay lands before the first `load()`.
    @discardableResult
    func open(url: URL) -> Bool {
        let text = url.absoluteString
        guard text.hasPrefix(TeamCode.prefix) else { return false }
        if inTeam { lastError = "already in a team; leave it first to join another" } else { pendingCode = text }
        revealSetting()
        return true
    }

    /// Opens Settings on the Team pane (the join link lands here).
    func revealSetting() {
        showSettings?()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("infinitus.selectPane"), object: TeamModel.paneTitle)
        }
    }
}
