import Foundation
import Network
import InfinitusCore

/// The latest encoded snapshot, shared between the exporter actor (which
/// writes it) and the NWConnection handlers on the network queue (which
/// read it). A lock, not an actor: the connection callbacks are
/// synchronous and must answer without hopping executors.
final class MirrorPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    var latest: Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func set(_ new: Data) {
        lock.lock(); data = new; lock.unlock()
    }
}

/// The pairing token, shared the same way for the same reason: the
/// connection handlers read it on the network queue, and "Regenerate"
/// writes it from the main actor without restarting the listener.
final class MirrorTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token = ""
    private var phone = true

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func set(_ new: String) {
        lock.lock(); token = new; lock.unlock()
    }

    /// The Sync pane's phone switch (#356): the listener may be up for
    /// Team Nearby alone, and then every phone route drops its
    /// connection exactly as if nothing were listening.
    var phoneEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return phone
    }

    func setPhone(_ on: Bool) {
        lock.lock(); phone = on; lock.unlock()
    }
}

/// The `/sessions/<pid>/tail` handler (#17 layer 1), boxed the same way
/// as payload/token: AppModel sets it from the main actor, the
/// connection handlers call it from the network queue. The closure does
/// its own file read (`ClaudeSessions.list` + `SessionFeedReader.read`)
/// on that queue — off the main actor, same as every other route here.
final class MirrorSessionFeedBox: @unchecked Sendable {
    /// `rows`: also serve the presented timeline rows (`?rows=1`, the
    /// browser page — it folds client-side).
    typealias Provider = @Sendable (_ pid: Int32, _ limit: Int, _ since: String?, _ wait: TimeInterval, _ rows: Bool) -> Data?
    private let lock = NSLock()
    private var provider: Provider?

    func set(_ new: @escaping Provider) {
        lock.lock(); provider = new; lock.unlock()
    }

    /// May block for up to `wait` seconds (the long-poll) — call it off
    /// the network queue when `wait > 0`.
    func call(_ pid: Int32, _ limit: Int, since: String? = nil, wait: TimeInterval = 0, rows: Bool = false) -> Data? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, limit, since, wait, rows)
    }
}

/// The `POST /activities/token` handler (Live Activity pushes): the
/// phone's APNs tokens, handed to AppModel's pusher on the main actor.
/// The `/sessions/<pid>/images/<id>` handler (phone thumbnails): the
/// image bytes and content type, nil for 404. Reads a transcript tail
/// and scales an image, so the route runs it off the network queue.
final class MirrorSessionImageBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ id: String) -> (data: Data, contentType: String)?
    private let lock = NSLock()
    private var provider: Provider?

    func set(_ new: @escaping Provider) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ id: String) -> (data: Data, contentType: String)? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, id)
    }
}

final class MirrorActivityTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (ActivityPushRegistration) -> Void)?

    func set(_ new: @escaping @Sendable (ActivityPushRegistration) -> Void) {
        lock.lock(); sink = new; lock.unlock()
    }

    func call(_ registration: ActivityPushRegistration) {
        lock.lock(); let current = sink; lock.unlock()
        current?(registration)
    }
}

/// The `POST /crashes` handler: a phone's crash report, handed to
/// AppModel's store on the main actor.
final class MirrorSessionStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SessionStart.Request) -> SessionStart.Reply)?

    func set(_ new: @escaping @Sendable (SessionStart.Request) -> SessionStart.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func call(_ request: SessionStart.Request) -> SessionStart.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return current?(request)
    }
}

/// Answers `GET /sessions/past` (#164): the newest past sessions, live
/// ones flagged, for the phone's Past list and its Resume.
final class MirrorPastSessionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int, String?) -> PastSessions.Reply)?

    func set(_ new: @escaping @Sendable (Int, String?) -> PastSessions.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func call(limit: Int, search: String?) -> PastSessions.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return current?(limit, search)
    }
}

/// Answers `GET /prefs` (#558): the preference catalog with the
/// install's current values, for a client rendering settings without
/// the Mac's panes.
final class MirrorPrefsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () throws -> PrefCatalog.Reply)?

    func set(_ new: @escaping @Sendable () throws -> PrefCatalog.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func call() -> PrefCatalog.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return try? current?()
    }
}

/// Answers a session's checkpoint routes (#167 phase 2): the timeline,
/// one checkpoint's diff, a restore.
final class MirrorCheckpointsBox: @unchecked Sendable {
    struct Handlers: Sendable {
        let list: @Sendable (Int32) -> Checkpoints.Reply?
        let diff: @Sendable (Int32, Int, Int?) -> Checkpoints.Diff?
        let restore: @Sendable (Int32, Int) -> Checkpoints.RestoreReply?
    }
    private let lock = NSLock()
    private var handlers: Handlers?

    func set(_ new: Handlers) {
        lock.lock(); handlers = new; lock.unlock()
    }

    var current: Handlers? {
        lock.lock(); defer { lock.unlock() }
        return handlers
    }
}

/// Answers `POST /app/update` (#121). Async, unlike `MirrorSessionStartBox`:
/// deciding needs live @MainActor state (`AppModel.appUpdateVersion`,
/// `BrewUpdater`), same reason `MirrorAwsLoginBox`'s handlers are async.
final class MirrorAppUpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () async -> AppUpdate.Reply)?

    func set(_ new: @escaping @Sendable () async -> AppUpdate.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func call() async -> AppUpdate.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return await current?()
    }
}

/// Answers `POST /accounts/action`: star/unstar, pause/resume one
/// account of this Mac's fleets. Async like `MirrorAppUpdateBox` — the
/// engine call is a subprocess and the reply waits for it.
final class MirrorAccountActionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AccountAction.Request) async -> AccountAction.Reply)?

    func set(_ new: @escaping @Sendable (AccountAction.Request) async -> AccountAction.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func call(_ request: AccountAction.Request) async -> AccountAction.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return await current?(request)
    }
}

final class MirrorCrashBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (CrashReport) -> Void)?

    func set(_ new: @escaping @Sendable (CrashReport) -> Void) {
        lock.lock(); sink = new; lock.unlock()
    }

    func call(_ report: CrashReport) {
        lock.lock(); let current = sink; lock.unlock()
        current?(report)
    }
}

/// The `POST /sessions/<pid>/input` handler (#17 layer 2), boxed the
/// same way as `sessionFeed`: AppModel sets it once from the main actor,
/// the connection handlers call it from the network queue. `nil` means
/// "no such pid" (404); the closure itself does the PTY/socket delivery
/// and its own logging.
/// AWS sign-in from the phone (AwsLogin.swift): start / code handlers.
final class MirrorAwsLoginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var start: (@Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply)?
    private var code: (@Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply)?
    private var callback: (@Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply)?

    func set(start: @escaping @Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply,
             code: @escaping @Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply,
             callback: @escaping @Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply) {
        lock.lock(); self.start = start; self.code = code; self.callback = callback; lock.unlock()
    }

    private func handlers() -> ((@Sendable (AwsLogin.StartRequest) async -> AwsLogin.Reply)?,
                                (@Sendable (AwsLogin.CodeRequest) async -> AwsLogin.Reply)?,
                                (@Sendable (AwsLogin.CallbackRequest) async -> AwsLogin.Reply)?) {
        lock.lock(); defer { lock.unlock() }
        return (start, code, callback)
    }

    func callCallback(_ r: AwsLogin.CallbackRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().2 else { return nil }
        return await f(r)
    }

    func callStart(_ r: AwsLogin.StartRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().0 else { return nil }
        return await f(r)
    }

    func callCode(_ r: AwsLogin.CodeRequest) async -> AwsLogin.Reply? {
        guard let f = handlers().1 else { return nil }
        return await f(r)
    }
}

/// The `POST /sessions/<pid>/attention` handler (#223 phase 3), boxed
/// like `sessionInput`: AppModel sets it once, the network queue calls
/// it. `nil` means "no such pid" (404); the closure resolves the record,
/// the cached timeline and the attention store itself.
final class MirrorAttentionBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ request: SessionAttention.Request) -> SessionAttention.Outcome?
    private let lock = NSLock()
    private var provider: Provider?
    func set(_ new: @escaping Provider) { lock.lock(); provider = new; lock.unlock() }
    func call(_ pid: Int32, _ request: SessionAttention.Request) -> SessionAttention.Outcome? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, request)
    }
}

/// The `GET /sessions/<pid>/timeline` handler (#223 phase 4), boxed like
/// `sessionFeed`; may block for the long-poll — call it off the queue.
final class MirrorTimelineBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ afterSequence: Int?, _ epoch: String?, _ wait: TimeInterval) -> Data?
    private let lock = NSLock()
    private var provider: Provider?
    func set(_ new: @escaping Provider) { lock.lock(); provider = new; lock.unlock() }
    func call(_ pid: Int32, _ afterSequence: Int?, _ epoch: String?, _ wait: TimeInterval) -> Data? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, afterSequence, epoch, wait)
    }
}

/// The `GET /sessions/<pid>/commands` handler (#223, the phone's `/`
/// popover), boxed like `timeline`; reads `.claude/` trees, so call it
/// off the queue. `nil` = no such pid (404).
final class MirrorCommandsBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32) -> Data?
    private let lock = NSLock()
    private var provider: Provider?
    func set(_ new: @escaping Provider) { lock.lock(); provider = new; lock.unlock() }
    func call(_ pid: Int32) -> Data? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid)
    }
}

/// The phone's file browser (#223): `GET /sessions/<pid>/files` and
/// `GET /sessions/<pid>/file?path=<rel>`. Boxed with a `Handlers` struct like
/// `checkpoints` because there are two of them; `nil` = no such pid (404),
/// and every refusal past that is the Core error's own status. Both spawn
/// `git` or walk a tree, so the routes call them off the serving queue.
final class MirrorFilesBox: @unchecked Sendable {
    struct Handlers: Sendable {
        let list: @Sendable (Int32) -> Result<T3ProjectFiles.Listing, T3ProjectFiles.ListError>?
        let read: @Sendable (Int32, String) -> Result<T3ProjectFiles.FileAnswer, T3ProjectFiles.ReadError>?
    }
    private let lock = NSLock()
    private var handlers: Handlers?

    func set(_ new: Handlers) {
        lock.lock(); handlers = new; lock.unlock()
    }

    var current: Handlers? {
        lock.lock(); defer { lock.unlock() }
        return handlers
    }
}

/// The phone's terminal (#507 step 3): the five routes' handlers over
/// `TerminalHost`, boxed with a `Handlers` struct like `files` because there
/// are several of them. `nil` from any handler = no such session or terminal
/// (404); every other refusal is Core's own `T3Terminal` validation, mapped
/// to a status by `MirrorServer.terminalFailure`.
final class MirrorTerminalBox: @unchecked Sendable {
    struct Handlers: Sendable {
        let open: @Sendable (Int32, T3Terminal.OpenRequest) -> Result<TerminalHost.OpenOutcome, TerminalHost.HostError>?
        /// The sink is called on the host's queue, in frame order, starting
        /// with the snapshot (or the ring replay a `since` earned).
        let attach: @Sendable (Int32, String, Int?, @escaping TerminalHost.Sink) -> TerminalHost.Attachment?
        let detach: @Sendable (TerminalHost.Attachment) -> Void
        let write: @Sendable (Int32, String, T3Terminal.WriteRequest) -> Result<Void, TerminalHost.HostError>?
        let resize: @Sendable (Int32, String, T3Terminal.ResizeRequest) -> Result<Void, TerminalHost.HostError>?
        let close: @Sendable (Int32, String) -> Bool
    }
    private let lock = NSLock()
    private var handlers: Handlers?

    func set(_ new: Handlers) {
        lock.lock(); handlers = new; lock.unlock()
    }

    var current: Handlers? {
        lock.lock(); defer { lock.unlock() }
        return handlers
    }
}

/// One attached terminal stream (#507 spec F): the `NWConnection` the mirror
/// would normally answer once and cancel is held instead, and every frame
/// the host emits goes out as one chunk of a chunked NDJSON response that
/// ends only when the terminal does (the zero-length chunk after `closed`).
///
/// Frames arrive on the host's serial queue and send completions on the
/// mirror's — neither is the main actor, and neither is ever blocked here:
/// the only shared state is a byte counter under a lock. A phone that falls
/// more than `pendingCap` behind is dropped with
/// `closed{reason:"backpressure"}` (#507 review ruling 5) and resumes with
/// `since`.
final class MirrorTerminalStream: @unchecked Sendable {
    /// Unsent bytes past which the phone is too far behind to keep.
    static let pendingCap = 1024 * 1024

    private let connection: NWConnection
    private let lock = NSLock()
    private var pending = 0
    private var headSent = false
    private var finished = false
    private var attachment: TerminalHost.Attachment?
    private var detach: (@Sendable (TerminalHost.Attachment) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// The host's fan-out, on the host's queue.
    func deliver(_ frames: [T3Terminal.Frame]) {
        guard !frames.isEmpty else { return }
        var payload = Data()
        var last = false
        for frame in frames {
            guard let line = try? frame.encodeLine() else {
                assertionFailure("a T3Terminal.Frame is Strings and Ints — encoding cannot fail")
                continue
            }
            payload.append(line)
            if case .closed = frame { last = true }
        }
        send(payload, end: last)
    }

    /// Keeps the host's handle so a hang-up can leave the fan-out. If the
    /// stream already gave up while `attach` was still returning, this
    /// detaches at once instead of storing a handle nobody will drop.
    func hold(_ attachment: TerminalHost.Attachment,
              detach: @escaping @Sendable (TerminalHost.Attachment) -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            detach(attachment)
            return
        }
        self.attachment = attachment
        self.detach = detach
        lock.unlock()
        // Three ways a phone goes away, all of them ending in `hangUp`: the
        // connection failing, its read side reporting EOF (`curl -N` killed,
        // the phone backgrounded), and a send that never lands.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.hangUp()
            default: break
            }
        }
        drain()
    }

    /// A refusal decided before anything was streamed — a plain response,
    /// no chunked head.
    func refuse(_ response: Data) {
        lock.lock()
        finished = true
        lock.unlock()
        connection.send(content: response,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    private func send(_ payload: Data, end: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        var out = Data()
        if !headSent {
            headSent = true
            out.append(Self.head)
        }
        if !end, pending + payload.count > Self.pendingCap {
            finished = true
            lock.unlock()
            out.append(Self.chunk(Self.backpressureLine))
            out.append(Self.terminator)
            connection.send(content: out,
                            completion: .contentProcessed { [weak self] _ in self?.hangUp() })
            return
        }
        pending += payload.count
        if end { finished = true }
        lock.unlock()
        out.append(Self.chunk(payload))
        if end { out.append(Self.terminator) }
        connection.send(content: out, completion: .contentProcessed { [weak self] error in
            self?.sent(payload.count, error: error, end: end)
        })
    }

    private func sent(_ bytes: Int, error: NWError?, end: Bool) {
        lock.lock()
        pending -= bytes
        lock.unlock()
        if error != nil || end { hangUp() }
    }

    /// Idempotent: out of the host's fan-out, then the connection goes.
    private func hangUp() {
        lock.lock()
        finished = true
        let attachment = self.attachment
        let detach = self.detach
        self.attachment = nil
        self.detach = nil
        lock.unlock()
        if let attachment, let detach { detach(attachment) }
        connection.cancel()
    }

    /// The client's side of a stream carries nothing — this read only exists
    /// to notice it hanging up.
    private func drain() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.hangUp()
                return
            }
            self.drain()
        }
    }

    private static let head = Data(("HTTP/1.1 200 OK\r\n"
        + "Content-Type: application/x-ndjson\r\n"
        + "Transfer-Encoding: chunked\r\n"
        + "Cache-Control: no-store\r\n"
        + "Connection: close\r\n\r\n").utf8)
    private static let terminator = Data("0\r\n\r\n".utf8)
    private static let backpressureLine: Data =
        (try? T3Terminal.Frame.closed(.init(reason: T3Terminal.closedReasonBackpressure)).encodeLine()) ?? Data()

    /// One HTTP/1.1 chunk: the size in hex, the bytes, CRLF.
    private static func chunk(_ payload: Data) -> Data {
        var out = Data(String(payload.count, radix: 16).utf8)
        out.append(Data("\r\n".utf8))
        out.append(payload)
        out.append(Data("\r\n".utf8))
        return out
    }
}

/// `GET /.well-known/infinitus` (#223 phase 4): the descriptor, no token.
final class MirrorDescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable () -> MirrorDescriptor)?
    func set(_ new: @escaping @Sendable () -> MirrorDescriptor) { lock.lock(); provider = new; lock.unlock() }
    func call() -> MirrorDescriptor? {
        lock.lock(); let current = provider; lock.unlock()
        return current?()
    }
}

/// Wraps one POST handler in the receipt protocol (#223 phase 4): a known
/// `commandId` replays its 200, conflicts (409), reports in-flight (409)
/// or is gone (410); a fresh one runs `run` and caches a 200 reply. `run`
/// returning nil is the route's 404.
private func withReceipt(_ receipts: Receipts, commandId: String?, target: String, pid: Int32?,
                         run: () -> Data?) -> Data {
    guard let commandId else { return run() ?? MirrorTransport.notFoundResponse() }
    switch receipts.begin(commandId: commandId, target: target, pid: pid) {
    case .hit(let data): return data
    case .conflict: return MirrorTransport.conflictResponse(Data(#"{"error":"commandId reused for another target"}"#.utf8))
    case .inFlight: return MirrorTransport.conflictResponse(Data(#"{"error":"in-flight"}"#.utf8))
    case .tombstoned:
        return MirrorTransport.response(status: 410, reason: "Gone", contentType: "application/json",
                                        body: Data(#"{"error":"tombstoned"}"#.utf8))
    case .miss:
        guard let data = run() else { receipts.abandon(commandId: commandId); return MirrorTransport.notFoundResponse() }
        if data.starts(with: Data("HTTP/1.1 200".utf8)) { receipts.finish(commandId: commandId, reply: data) }
        else { receipts.abandon(commandId: commandId) }
        return data
    }
}

/// Where `POST /sessions/<pid>/input` deliveries run, one at a time.
private let mirrorInputQueue = DispatchQueue(label: "run.infinitus.mirror-input", qos: .userInitiated)

final class MirrorSessionInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?)?
    /// #168: a request the phone's outbox sends twice (it died between
    /// send and reply, or the reply was lost) is answered once; the
    /// repeat gets back the SAME reply the first send got — recording a
    /// synthetic "delivered" instead would turn a lost noSurface/
    /// noChannel reply into a false "Delivered" on the repeat.
    private var dedup = InputDedup()

    func set(_ new: @escaping @Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ request: SessionInput.Request) -> SessionInput.Reply? {
        lock.lock()
        if let requestId = request.requestId, let replayed = dedup.replay(pid: pid, requestId: requestId) {
            lock.unlock()
            return replayed
        }
        let current = provider
        lock.unlock()
        // The provider runs on the serial `mirrorInputQueue` (this is the
        // only caller), so two identical requests never race the
        // remember-after-the-fact below.
        let reply = current?(pid, request)
        if let requestId = request.requestId, let reply {
            lock.lock()
            dedup.remember(pid: pid, requestId: requestId, reply: reply)
            lock.unlock()
        }
        return reply
    }
}

/// Team session control (#220): the grantor's endpoint, boxed like the
/// rest. Rebuilt off main when the team standing changes (`refreshTeamControl`);
/// `respond` (the HTTP lanes) and `storePass` (the store lane) both run
/// under `MirrorTeamControlBox.queue`, so the replay set and the rate
/// limit are mutated by one thread, and execution hops to
/// `mirrorInputQueue` inside the endpoint's `execute`.
final class MirrorTeamControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: TeamControl.Endpoint?
    private var teamDir: URL?
    private var deliverer: (@Sendable (Int32, SessionInput.Request, String) -> SessionInput.Reply)?
    /// Verification, the replay set and the rate limit are single-threaded
    /// here for BOTH lanes (#220); delivery hops to `mirrorInputQueue`.
    static let queue = DispatchQueue(label: "run.infinitus.team-control")
    /// The live feed by session id (the phone's tail, keyed by pid).
    var tail = TeamControlRoute.Tail { _, _ in nil }
    /// Every command, accepted or refused, with the driver's roster name.
    var onAudit: (@Sendable (TeamControl.Audit, String?) -> Void)?

    func set(_ new: TeamControl.Endpoint?, teamDir dir: URL?) {
        lock.lock(); endpoint = new; teamDir = dir; lock.unlock()
    }

    /// The shared input deliverer (AppModel.deliverSessionInput), read at
    /// execute time — the endpoint is first built at `start()`, before
    /// AppModel has wired it (the e2e's "app is shutting down" refusal).
    func setDeliver(_ new: @escaping @Sendable (Int32, SessionInput.Request, String) -> SessionInput.Reply) {
        lock.lock(); deliverer = new; lock.unlock()
    }

    func deliver(_ pid: Int32, _ request: SessionInput.Request, from origin: String) -> SessionInput.Reply {
        lock.lock(); let current = deliverer; lock.unlock()
        guard let current else { return SessionInput.Reply(outcome: "rejected", detail: "app is shutting down") }
        return current(pid, request, origin)
    }

    /// `Self.queue` only.
    func respond(_ request: MirrorTransport.Request) -> Data? {
        lock.lock(); var ep = endpoint; let dir = teamDir; lock.unlock()
        ep?.lastAudit = nil
        let response = TeamControlRoute.respond(request, endpoint: &ep, tail: tail)
        guard let ep else { return response }
        lock.lock()
        endpoint?.seen = ep.seen
        endpoint?.limit = ep.limit
        lock.unlock()
        if let audit = ep.lastAudit {
            if let dir { try? ep.seen.save(teamDir: dir) }
            let name = ep.roster()?.everyone.first { $0.keys.kid == audit.driver }?.name
            onAudit?(audit, name)
        }
        return response
    }

    /// Lane 4 (#220 §5.3): after a fetch, the commands under the store
    /// addressed to me. Called on the team queue; hops onto the control
    /// queue so the HTTP route can't interleave.
    func storePass(_ client: TeamClient) {
        Self.queue.sync {
            lock.lock(); let current = endpoint; let dir = teamDir; lock.unlock()
            guard var ep = current, let dir else { return }
            var handled = TeamControl.Handled.load(teamDir: dir)
            let audits: [TeamControl.Audit]
            do { audits = try TeamControl.Store.grantorPass(client: client, endpoint: &ep, handled: &handled) }
            catch { Lifecycle.log.error("team control store pass: \(TeamGit.masked("\(error)"), privacy: .public)"); return }
            lock.lock(); endpoint?.seen = ep.seen; endpoint?.limit = ep.limit; lock.unlock()
            guard !audits.isEmpty else { return }
            try? ep.seen.save(teamDir: dir)
            try? handled.save(teamDir: dir)
            let roster = ep.roster()
            for audit in audits { onAudit?(audit, roster?.everyone.first { $0.keys.kid == audit.driver }?.name) }
        }
    }
}

/// The Nearby standing (TXT record + `/team/*` routes, spec §6.4), boxed
/// like the rest: the main actor refreshes it when the discoverable
/// switch flips, the connection handlers read it on the network queue.
final class MirrorTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var local: TeamNearby.Local = .hidden

    var current: TeamNearby.Local {
        lock.lock(); defer { lock.unlock() }
        return local
    }

    func set(_ new: TeamNearby.Local) {
        lock.lock(); local = new; lock.unlock()
    }

    /// Where a LAN request lands: pending under the team, then the
    /// requests branch — a git push, so callers run it off the network
    /// queue. An invitation (spec §6.4) is only a file write: it stays
    /// sealed until the Team pane's Accept opens it.
    var endpoint: TeamNearby.Endpoint {
        TeamNearby.Endpoint(local: current, store: { request in
            // The app's secrets store (keychain on a real Mac), never the
            // CLI's file store: a request sealed to the file identity's keys
            // is one the pane can never open.
            let paths = TeamPaths.standard()
            return try TeamNearby.Store.save(request, paths: paths, secrets: TeamSecretsFactory.make(paths: paths)())
        }, storeInvite: { invite in
            try TeamNearby.Store.saveInvite(invite, paths: TeamPaths.standard())
        })
    }
}

/// Answers `/mirror/team/*` for the phone (spec §9 step 8): one async
/// handler set by AppModel, returning the JSON body or nil for 404.
final class MirrorTeamMirrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MirrorTransport.Request) async -> Data?)?
    func set(_ handler: @escaping @Sendable (MirrorTransport.Request) async -> Data?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func call(_ request: MirrorTransport.Request) async -> Data? {
        lock.lock(); let h = handler; lock.unlock()
        guard let h else { return nil }
        return await h(request)
    }
}

/// Serves the fleet snapshot to the phone (#9): one Bonjour advertised
/// (`_infinitus._tcp`) TCP listener answering `GET /snapshot` with the
/// exact bytes MirrorExporter wrote. Off by default behind the Sync
/// pane's toggle.
///
/// Every request must carry the pairing token — `Authorization: Bearer
/// <token>` or `?t=<token>` — else 401, before routing. That is what
/// makes the same listener safe to reach from a tailnet or a Cloudflare
/// quick tunnel: it binds every interface either way, and the token is
/// the only lock.
@MainActor
final class MirrorServer: ObservableObject {
    /// The bound port, once the listener is ready.
    @Published private(set) var port: UInt16?
    /// One line for the Settings pane.
    @Published private(set) var status: String?
    /// When a phone last fetched with the right token — the walkthrough's
    /// "paired" check. Session-only; a relaunch starts unpaired.
    @Published private(set) var lastServed: Date?
    /// Every phone that fetched with the right token this session, newest
    /// first (user 2026-09-03: "show active/connected devices").
    @Published private(set) var clients: [MirrorClient] = []
    /// The same phones, kept across relaunches (Settings › Devices › Phones).
    let phones = PairedPhoneStore()

    /// Handed to MirrorExporter so every export lands here too.
    let payload = MirrorPayloadBox()
    /// Read by the connection handlers; written by AppModel on regenerate.
    let token = MirrorTokenBox()
    /// Answers `/sessions/<pid>/tail`; set by AppModel once at start.
    let sessionFeed = MirrorSessionFeedBox()
    /// Answers `POST /activities/token`; set by AppModel once at start.
    let activityTokens = MirrorActivityTokenBox()
    /// Answers `POST /sessions/<pid>/input` (#17 layer 2); set by AppModel
    /// once at start.
    let sessionInput = MirrorSessionInputBox()
    /// Answers `POST /sessions/<pid>/attention` (#223 phase 3); set by AppModel once at start.
    let attention = MirrorAttentionBox()
    /// Answers `GET /sessions/<pid>/timeline` (#223 phase 4); set by AppModel once at start.
    let timeline = MirrorTimelineBox()
    /// Answers `GET /sessions/<pid>/commands` (#223); set by AppModel once at start.
    let commands = MirrorCommandsBox()
    /// Answers the file-browser routes (#223); set by AppModel once at start.
    let files = MirrorFilesBox()
    /// Answers the terminal routes (#507); set by AppModel once at start.
    let terminal = MirrorTerminalBox()
    /// Answers `GET /.well-known/infinitus`; set by AppModel once at start.
    let descriptor = MirrorDescriptorBox()
    /// Command receipts for input / start / attention (#223 phase 4).
    let receipts = Receipts()
    /// Client-activity leases (#223 phase 5): who is looking at what.
    let leases = LeaseTable()
    /// Answers `/sessions/<pid>/images/<id>`; set by AppModel once at start.
    let sessionImage = MirrorSessionImageBox()
    let awsLogin = MirrorAwsLoginBox()
    /// Answers `POST /crashes`; set by AppModel once at start.
    let crashes = MirrorCrashBox()
    /// Nearby (spec §6.4): the TXT record and `/team/key` + `/team/request`.
    let team = MirrorTeamBox()
    /// Answers `/mirror/team/*` (spec §9 step 8); set by AppModel once at start.
    let teamMirror = MirrorTeamMirrorBox()
    private var advertisedName = ""
    private var teamDiscoverable = false
    private var defaultsObserver: NSObjectProtocol?
    /// Answers `POST /sessions/start` (#91); set by AppModel once at start.
    let sessionStart = MirrorSessionStartBox()
    /// Answers `GET /sessions/past` (#164); set by AppModel once at start.
    let pastSessions = MirrorPastSessionsBox()
    let prefs = MirrorPrefsBox()
    /// Answers `GET /sessions/<pid>/checkpoints` and friends (#167); set by AppModel once at start.
    let checkpoints = MirrorCheckpointsBox()
    /// Answers `POST /app/update` (#121); set by AppModel once at start.
    let appUpdate = MirrorAppUpdateBox()
    let accountAction = MirrorAccountActionBox()
    /// Team session control (#220): `/team/command` and `/team/sessions/<id>/tail`.
    let teamControl = MirrorTeamControlBox()
    /// Event-log sink (icon, text), set by AppModel.
    var log: ((String, String) -> Void)?
    /// Fires with the bound port once the listener is up — the quick
    /// tunnel can only be pointed at a port that exists.
    var onReady: ((UInt16) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "run.infinitus.mirror-server")
    /// `/team/*` requests only: serialized so concurrent LAN callers can't
    /// race `TeamGit`'s bare-repo push (no in-process lock of its own) and
    /// turn each other's request into an unearned 503.
    private static let teamStoreQueue = DispatchQueue(label: "run.infinitus.team-store")

    /// Off: phone routes (snapshot, tails, pairing, the descriptor) drop
    /// their connection while `/team/*` and session control keep
    /// answering — the listener serves Team Nearby on its own (#356).
    var phoneEnabled: Bool {
        get { token.phoneEnabled }
        set { token.setPhone(newValue) }
    }

    func start(machineName: String, token: String) {
        self.token.set(token)
        guard listener == nil else { return }
        advertisedName = machineName
        // The last export renders immediately: a phone that asks before
        // the first refresh of this launch still gets a fleet.
        if payload.latest == nil,
           let data = try? Data(contentsOf: MirrorExporter.url) {
            payload.set(data)
        }
        if defaultsObserver == nil {
            // Event-driven, never polled: the Team pane (plan 5) or
            // `infinitusctl team-discoverable` flips the default and this
            // re-advertises once per change.
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshTeamStanding() }
            }
        }
        status = "starting…"
        listen(on: MirrorTransport.defaultPort, name: machineName)
        refreshTeamStanding(force: true)
        refreshTeamControl()
    }

    var isListening: Bool { listener != nil }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = nil
    }

    /// Rebuilds the grantor endpoint (#220) off the main actor: at start
    /// and after every TeamModel load (a team created mid-run). Grants,
    /// roster and the replay set are read from disk per request, so
    /// `infinitusctl team grant` takes effect with no IPC. No team, or no
    /// identity this process can read ⇒ no endpoint ⇒ every control route
    /// answers 404.
    func refreshTeamControl() {
        let feed = sessionFeed
        let box = teamControl
        DispatchQueue.global(qos: .utility).async {
            let paths = TeamPaths.standard()
            let secrets = TeamSecretsFactory.make(paths: paths)()
            guard let id = paths.teamIDs().sorted().first,
                  let identity = try? TeamClient.identity(paths: paths, secrets: secrets) else {
                box.set(nil, teamDir: nil); return
            }
            let dir = paths.teamDir(id)
            let live: @Sendable () -> [String: Int32] = {
                Dictionary(ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).map { ($0.sessionId, $0.pid) },
                           uniquingKeysWith: { _, newer in newer })
            }
            let endpoint = TeamControl.Endpoint(
                identity: identity,
                roster: {
                    (try? Data(contentsOf: paths.rosterFile(id)))
                        .flatMap { try? CanonicalJSON.decode(Signed<TeamRoster>.self, from: $0) }?.doc
                },
                grants: { TeamGrants.load(teamDir: dir) },
                liveSessions: live,
                execute: { action, text, pid in
                    guard let request = TeamControl.request(action: action, text: text) else {
                        return SessionInput.Reply(outcome: "rejected", detail: "nothing to run for \(action)")
                    }
                    return mirrorInputQueue.sync { box.deliver(pid, request, from: "team") }
                },
                seen: TeamControl.SeenIDs.load(teamDir: dir), limit: TeamControl.RateLimit())
            box.tail = TeamControlRoute.Tail { sessionId, since in
                guard let pid = live()[sessionId] else { return nil }
                return feed.call(pid, 200, since: since, wait: 0)
            }
            box.set(endpoint, teamDir: dir)
        }
    }

    /// Reads the switch and, when it changed, rebuilds the standing off
    /// the main actor (it opens the team clones) and re-advertises.
    /// `force`: re-read the standing even with the toggle unchanged — after
    /// create/join/leave/approve the role in the TXT record moved (a Mac
    /// that became leader after launch kept advertising `r=none`, user
    /// screenshot 2026-09-07).
    func refreshTeamStanding(force: Bool = false) {
        let on = UserDefaults.standard.bool(forKey: TeamNearby.discoverableDefaultsKey)
        guard force || on != teamDiscoverable else { return }
        teamDiscoverable = on
        let name = advertisedName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The same secrets store as TeamModel (keychain on a real Mac).
            // With the CLI's file store here the advert carried a second,
            // teamless identity: the Mac listed ITSELF as "none · not in
            // this team" and advertised r=none while leading (2026-09-07).
            let paths = TeamPaths.standard()
            let local = TeamNearby.Local.load(name: name, discoverable: on, paths: paths,
                                              secrets: TeamSecretsFactory.make(paths: paths)())
            Task { @MainActor in
                // A newer toggle may have already landed while this one
                // was opening team clones on the concurrent queue — an
                // out-of-order finish must not overwrite the standing
                // with a stale one.
                guard let self, on == self.teamDiscoverable else { return }
                self.team.set(local)
                self.advertise()
                self.log?("📡", on ? "nearby: discoverable as \(name)" : "nearby: hidden")
            }
        }
    }

    /// (Re)registers the Bonjour service with the current TXT record —
    /// setting `service` on a running listener updates the record in
    /// place (nw_listener_set_advertise_descriptor).
    private func advertise() {
        listener?.service = NWListener.Service(name: advertisedName, type: MirrorTransport.bonjourType,
                                               txtRecord: team.current.record.txtData)
    }

    private func listen(on rawPort: UInt16, name: String) {
        let params = NWParameters.tcp
        // Toggling the server off and on shouldn't trip over TIME_WAIT.
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        // IPv4 socket, not the dual-stack IPv6 wildcard: a connection to
        // this Mac's own tailnet address never reached the v6 socket
        // (Tailscale's utun hands IPv4 to IPv4 sockets only — probed
        // 2026-09-02, LAN fine both ways, 100.x only with v4).
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let endpointPort = rawPort == 0 ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: rawPort) ?? .any
        guard let listener = try? NWListener(using: params, on: endpointPort) else {
            status = "couldn't open a port"
            return
        }
        listener.service = NWListener.Service(name: name, type: MirrorTransport.bonjourType,
                                              txtRecord: team.current.record.txtData)
        let payload = self.payload
        let token = self.token
        let sessionFeed = self.sessionFeed
        let sessionStart = self.sessionStart
        let pastSessions = self.pastSessions
        let prefs = self.prefs
        let checkpoints = self.checkpoints
        let appUpdate = self.appUpdate
        let accountAction = self.accountAction
        let sessionInput = self.sessionInput
        let attention = self.attention
        let timeline = self.timeline
        let commands = self.commands
        let files = self.files
        let terminal = self.terminal
        let descriptor = self.descriptor
        let receipts = self.receipts
        let leases = self.leases
        let sessionImage = self.sessionImage
        let activityTokens = self.activityTokens
        let awsLogin = self.awsLogin
        let crashes = self.crashes
        let team = self.team
        let teamMirror = self.teamMirror
        let teamControl = self.teamControl
        let served: @Sendable (MirrorTransport.Request) -> Void = { [weak self] request in
            let client = MirrorClient(request: request)
            Task { @MainActor in
                guard let self else { return }
                self.lastServed = client.lastSeen
                self.clients = MirrorClient.merge(client, into: self.clients)
                self.phones.record(client)
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            Self.serve(connection, payload: payload, token: token, sessionFeed: sessionFeed,
                       sessionInput: sessionInput, attention: attention, timeline: timeline, commands: commands, files: files, terminal: terminal, descriptor: descriptor, receipts: receipts, leases: leases, sessionImage: sessionImage, activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions, prefs: prefs, checkpoints: checkpoints,
                       team: team, teamControl: teamControl, appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, teamMirror: teamMirror, queue: queue, onServed: served)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, wasFixedPort: rawPort != 0, name: name) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func handle(_ state: NWListener.State, wasFixedPort: Bool, name: String) {
        switch state {
        case .ready:
            let bound = listener?.port?.rawValue
            port = bound
            status = "serving \(name) on port \(bound.map(String.init) ?? "?")"
            log?("📱", "phone companion listening on port \(bound.map(String.init) ?? "?")")
            if let bound { onReady?(bound) }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The fixed port is only a convenience for the phone's manual
            // override — if something else holds it, take any port and
            // let Bonjour carry the number.
            if wasFixedPort, case .posix(.EADDRINUSE) = error {
                listen(on: 0, name: name)
            } else {
                port = nil
                status = "failed: \(error.localizedDescription)"
                log?("⚠️", "phone companion failed: \(error.localizedDescription)")
            }
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    // MARK: - Connection handling (network queue)

    /// RFC 1918 / link-local IPv4, or IPv6 link-local / ULA: the addresses
    /// a same-LAN peer can have. Loopback is deliberately excluded — a
    /// machine is never "nearby" to itself, and `cloudflared`'s quick
    /// tunnel proxies every internet request to this listener over
    /// 127.0.0.1, which would otherwise let a tunnel URL reach
    /// `/team/*` with no pairing token. A tailnet client (100.64/10,
    /// public v4, global v6) is never "nearby" either, and `/team/*`
    /// carries no pairing token, so nothing else gets in.
    nonisolated static func isLANPeer(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let v4):
            let b = [UInt8](v4.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let v6):
            let b = [UInt8](v6.rawValue)
            guard b.count == 16 else { return false }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }   // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                     // fc00::/7
            // ::ffff:a.b.c.d — the v4-only listener never yields one, but be exact.
            if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff,
               let v4 = IPv4Address(Data(b[12...])) {
                return isLANPeer(.hostPort(host: .ipv4(v4), port: 0))
            }
            return false
        default:
            return false
        }
    }

    private nonisolated static func serve(_ connection: NWConnection,
                                          payload: MirrorPayloadBox,
                                          token: MirrorTokenBox,
                                          sessionFeed: MirrorSessionFeedBox,
                                          sessionInput: MirrorSessionInputBox,
                                          attention: MirrorAttentionBox,
                                          timeline: MirrorTimelineBox,
                                          commands: MirrorCommandsBox,
                                          files: MirrorFilesBox,
                                          terminal: MirrorTerminalBox,
                                          descriptor: MirrorDescriptorBox,
                                          receipts: Receipts,
                                          leases: LeaseTable,
                                            sessionImage: MirrorSessionImageBox,
                                          activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, sessionStart: MirrorSessionStartBox, pastSessions: MirrorPastSessionsBox, prefs: MirrorPrefsBox, checkpoints: MirrorCheckpointsBox,
                                          team: MirrorTeamBox, teamControl: MirrorTeamControlBox, appUpdate: MirrorAppUpdateBox,
                                          awsLogin: MirrorAwsLoginBox, accountAction: MirrorAccountActionBox,
                                          teamMirror: MirrorTeamMirrorBox,
                                          queue: DispatchQueue,
                                          onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), payload: payload, token: token,
               sessionFeed: sessionFeed, sessionInput: sessionInput, attention: attention, timeline: timeline, commands: commands, files: files, terminal: terminal, descriptor: descriptor, receipts: receipts, leases: leases, sessionImage: sessionImage,
               activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions, prefs: prefs, checkpoints: checkpoints,
               team: team, teamControl: teamControl, appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, teamMirror: teamMirror, onServed: onServed)
    }

    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox,
                                            token: MirrorTokenBox,
                                            sessionFeed: MirrorSessionFeedBox,
                                            sessionInput: MirrorSessionInputBox,
                                          attention: MirrorAttentionBox,
                                          timeline: MirrorTimelineBox,
                                          commands: MirrorCommandsBox,
                                          files: MirrorFilesBox,
                                          terminal: MirrorTerminalBox,
                                          descriptor: MirrorDescriptorBox,
                                          receipts: Receipts,
                                          leases: LeaseTable,
                                            sessionImage: MirrorSessionImageBox,
                                            activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, sessionStart: MirrorSessionStartBox, pastSessions: MirrorPastSessionsBox, prefs: MirrorPrefsBox, checkpoints: MirrorCheckpointsBox,
                                            team: MirrorTeamBox, teamControl: MirrorTeamControlBox, appUpdate: MirrorAppUpdateBox,
                                            awsLogin: MirrorAwsLoginBox, accountAction: MirrorAccountActionBox,
                                            teamMirror: MirrorTeamMirrorBox,
                                            onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            // The head alone (token included — it rides in a header or the
            // query, never the body) is enough to both pick the route's
            // body cap and reject an unpaired caller before buffering a
            // single byte of a body it was never going to be allowed to
            // send — this listener may be tunnel-exposed, and the
            // attachments route's 24 MiB cap is not something to hold open
            // for a caller that was always going to get a 401
            // (2026-09-03 attachments).
            let head = MirrorTransport.parseRequest(buffer)
            // Peers hold no pairing token: `/team/*` from a LAN address is
            // routed on its own (TeamNearby.respond answers 404 while
            // hidden); everything else — including `/team/*` from a
            // tunnel — still needs the token before a body byte is buffered.
            // Team session control (#220): a sealed command or a signed
            // tail header authenticates itself, so neither the pairing
            // token nor the LAN gate applies — a teammate drives over the
            // tunnel too. Without grants the route answers 404.
            let controlRoute = head.map {
                $0.path == TeamControlRoute.commandPath || TeamControlRoute.tailSessionId($0.path) != nil
            } ?? false
            let teamRoute = !controlRoute && (head.map { $0.path.hasPrefix(TeamNearby.routePrefix) } ?? false)
                && Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
            let wellKnown = head.map { $0.method == "GET" && $0.path == MirrorTransport.wellKnownPath } ?? false
            // Phone switch off (#356): the listener is up for the team
            // alone, so a phone route gets what it would with no
            // listener — a closed connection, never a 401 that reads as
            // "unpaired" on the phone.
            if head != nil, !teamRoute, !controlRoute, !token.phoneEnabled {
                connection.cancel()
                return
            }
            if let head, !teamRoute, !controlRoute, !wellKnown, !MirrorTransport.isAuthorized(head, token: token.current) {
                connection.send(content: MirrorTransport.unauthorizedResponse(),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let cap = head.map {
                MirrorTransport.bodyCap(method: $0.method, path: $0.path)
            } ?? MirrorTransport.defaultBodyCap
            // The whole head AND, when there is one, the whole body — the
            // input route's JSON body arrives in arbitrary chunks just
            // like everything else. Auth was already checked off the head
            // above; the check below stays as the route dispatch's own
            // defense in depth (e.g. a token regenerated mid-request).
            if let request = MirrorTransport.parseRequestWithBody(buffer, bodyCap: cap) {
                if request.path == TeamControlRoute.commandPath || TeamControlRoute.tailSessionId(request.path) != nil {
                    MirrorTeamControlBox.queue.async {
                        let response = teamControl.respond(request) ?? MirrorTransport.notFoundResponse()
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
                if request.path.hasPrefix(TeamNearby.routePrefix),
                   Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint) {
                    // Off this queue, and serialized: a stored request
                    // pushes to git, and TeamGit holds no lock of its own.
                    teamStoreQueue.async {
                        let response = TeamNearby.respond(request, endpoint: team.endpoint)
                            ?? MirrorTransport.notFoundResponse()
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
                guard token.phoneEnabled else { connection.cancel(); return }   // #356, checked off the head above too
                let response: Data
                if request.method == "GET", request.path == MirrorTransport.wellKnownPath {
                    // Unauthenticated by design (#223 phase 4): what this
                    // Mac supports, read before pairing. No I/O, on the queue.
                    response = descriptor.call().flatMap { try? JSONEncoder().encode($0) }
                        .map(MirrorTransport.jsonResponse) ?? MirrorTransport.unavailableResponse()
                } else if !MirrorTransport.isAuthorized(request, token: token.current) {
                    response = MirrorTransport.unauthorizedResponse()
                } else if request.method == "GET", request.path == MirrorWebClient.path {
                    // The browser client (#151): Linux/Windows have no app.
                    response = MirrorWebClient.response()
                } else if request.method == "GET",
                          request.path == MirrorTransport.snapshotPath {
                    response = payload.latest.map(MirrorTransport.snapshotResponse)
                        ?? MirrorTransport.unavailableResponse()
                    onServed(request)
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionTailPid(request.path) {
                    let limit = request.query(MirrorTransport.tailLimitQueryName).flatMap(Int.init) ?? 30
                    let since = request.query(MirrorTransport.tailSinceQueryName)
                    let wait = request.query(MirrorTransport.tailWaitQueryName).flatMap(Double.init) ?? 0
                    let rows = request.query(MirrorTransport.tailRowsQueryName) == "1"
                    // Off this queue either way: a long-poll sleeps until
                    // the transcript moves, and even the plain form reads
                    // a 256 KiB tail — every connection shares this queue,
                    // so nothing that takes time may run on it.
                    DispatchQueue.global(qos: .utility).async {
                        let data = sessionFeed.call(pid, limit, since: since, wait: wait, rows: rows)
                        let response = data.map(MirrorTransport.snapshotResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionTimelinePid(request.path) {
                    let after = request.query(MirrorTransport.timelineAfterQueryName).flatMap(Int.init)
                    let epoch = request.query(MirrorTransport.timelineEpochQueryName)
                    let wait = request.query(MirrorTransport.tailWaitQueryName).flatMap(Double.init) ?? 0
                    // A long-poll and a possible transcript parse: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = timeline.call(pid, after, epoch, wait).map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionCommandsPid(request.path) {
                    // Discovery walks .claude/ trees on disk: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = commands.call(pid).map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionFilesPid(request.path) {
                    // `git ls-files` or a tree walk over the whole cwd: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = MirrorTransport.filesListResponse(files.current?.list(pid))
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionFilePid(request.path) {
                    // A missing `path` is refused like any other path outside
                    // the workspace — the Core read decides, not the route.
                    let path = request.query(T3ProjectFiles.pathQueryName) ?? ""
                    // Up to 256 KiB of text, or 8 MB of image, read off disk:
                    // off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = MirrorTransport.fileAnswerResponse(files.current?.read(pid, path))
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET", request.path == PrefCatalog.path {
                    // A defaults read: answered here, like the descriptor.
                    let response = prefs.call()
                        .flatMap { try? JSONEncoder().encode($0) }
                        .map(MirrorTransport.jsonResponse)
                        ?? MirrorTransport.notFoundResponse()
                    onServed(request)
                    connection.send(content: response,
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                } else if request.method == "GET", request.path == PastSessions.path {
                    let limit = request.query(PastSessions.limitQueryName).flatMap(Int.init) ?? 50
                    let search = request.query(PastSessions.searchQueryName)
                    // Lists a directory tree and reads up to `limit`
                    // transcript heads: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        let response = pastSessions.call(limit: limit, search: search)
                            .flatMap { try? encoder.encode($0) }
                            .map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let pid = MirrorTransport.sessionCheckpointsPid(request.path) {
                    // `git for-each-ref` per call: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        let response = checkpoints.current?.list(pid)
                            .flatMap { try? encoder.encode($0) }
                            .map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if let ref = MirrorTransport.sessionCheckpointRef(request.path),
                          request.method == (ref.action == .diff ? "GET" : "POST") {
                    let to = request.query(MirrorTransport.checkpointToQueryName).flatMap(Int.init)
                    // Diffs read trees; a restore rewrites the worktree —
                    // both take a while, neither belongs on this queue (or
                    // on the keystroke queue: a restore must not hold a
                    // send back).
                    DispatchQueue.global(qos: .utility).async {
                        let body: Data?
                        switch ref.action {
                        case .diff: body = checkpoints.current?.diff(ref.pid, ref.n, to).flatMap { try? JSONEncoder().encode($0) }
                        case .restore: body = checkpoints.current?.restore(ref.pid, ref.n).flatMap { try? JSONEncoder().encode($0) }
                        }
                        let response = body.map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "GET",
                          let ref = MirrorTransport.sessionImageRef(request.path) {
                    // A transcript tail read and an image decode: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let response = sessionImage.call(ref.pid, ref.id)
                            .map { MirrorTransport.imageResponse($0.data, contentType: $0.contentType) }
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST",
                          let pid = MirrorTransport.sessionInputPid(request.path) {
                    guard let decoded = try? JSONDecoder().decode(SessionInput.Request.self, from: request.body)
                    else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Delivery spawns `ps` and sleeps through the terminal's
                    // settle waits (a second each) — on this queue that
                    // stalled the phone's own long-poll and the snapshot
                    // behind every send (user 2026-09-04 "sending and
                    // receiving are not responsive"). Its own SERIAL queue,
                    // not the global pool: two sends in a row must land
                    // one after the other, never interleave keystrokes.
                    mirrorInputQueue.async {
                        // A stop tombstones this pid's receipts first: the
                        // interrupted input must not come back on a retry.
                        if decoded.kind == .key, decoded.text == "esc" { receipts.tombstone(pid: pid) }
                        let response = withReceipt(receipts, commandId: decoded.commandId,
                                                   target: request.path + "#" + decoded.kind.rawValue, pid: pid) {
                            sessionInput.call(pid, decoded)
                                .flatMap { try? JSONEncoder().encode($0) }
                                .map(MirrorTransport.jsonResponse)
                        }
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST",
                          let pid = MirrorTransport.sessionAttentionPid(request.path) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    guard let decoded = try? decoder.decode(SessionAttention.Request.self, from: request.body) else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Resolves the record and may parse a transcript tail: off this queue.
                    DispatchQueue.global(qos: .utility).async {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        let response = withReceipt(receipts, commandId: decoded.commandId, target: request.path, pid: pid) {
                            switch attention.call(pid, decoded) {
                            case .applied(let facts)?:
                                return (try? encoder.encode(facts)).map(MirrorTransport.jsonResponse)
                                    ?? MirrorTransport.unavailableResponse()
                            case .refused(let reason)?:
                                return MirrorTransport.conflictResponse(Data(#"{"error":"\#(reason)"}"#.utf8))
                            case .badRequest?:
                                return MirrorTransport.badRequestResponse()
                            case nil:
                                return nil
                            }
                        }
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == ClientActivity.path {
                    guard let decoded = try? JSONDecoder().decode(ClientActivity.Report.self, from: request.body) else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    leases.report(decoded)   // no I/O: stays on the queue
                    let response = MirrorTransport.response(status: 204, reason: "No Content",
                                                            contentType: "application/json", body: Data())
                    onServed(request)
                    connection.send(content: response,
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                } else if request.path.hasPrefix(TeamMirror.prefix + "/") {
                    // The phone's Team tab (spec §9): TeamModel work runs
                    // on its own queue behind the main actor, so off this
                    // queue like the AWS login routes.
                    Task {
                        let response = await teamMirror.call(request)
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST",
                          [AwsLogin.startPath, AwsLogin.codePath, AwsLogin.callbackPath].contains(request.path) {
                    // The code / callback never leaves this path: decoded,
                    // handed to the runner, gone. Async: the reply waits
                    // for the runner actor, so it runs off this queue.
                    let decoder = JSONDecoder()
                    let startBody = request.path == AwsLogin.startPath ? try? decoder.decode(AwsLogin.StartRequest.self, from: request.body) : nil
                    let codeBody = request.path == AwsLogin.codePath ? try? decoder.decode(AwsLogin.CodeRequest.self, from: request.body) : nil
                    let callbackBody = request.path == AwsLogin.callbackPath ? try? decoder.decode(AwsLogin.CallbackRequest.self, from: request.body) : nil
                    guard startBody != nil || codeBody != nil || callbackBody != nil else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    Task {
                        let reply: AwsLogin.Reply?
                        if let startBody { reply = await awsLogin.callStart(startBody) }
                        else if let codeBody { reply = await awsLogin.callCode(codeBody) }
                        else if let callbackBody { reply = await awsLogin.callCallback(callbackBody) }
                        else { reply = nil }
                        let response = reply.flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == SessionStart.path {
                    guard let decoded = try? JSONDecoder().decode(SessionStart.Request.self, from: request.body)
                    else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Opening a terminal and waiting for the session to
                    // register takes seconds — off the connection queue,
                    // and not on the input queue either (a send while a
                    // start waits must not queue behind it).
                    DispatchQueue.global(qos: .userInitiated).async {
                        let response = withReceipt(receipts, commandId: decoded.commandId, target: request.path, pid: nil) {
                            sessionStart.call(decoded)
                                .flatMap { try? JSONEncoder().encode($0) }
                                .map(MirrorTransport.jsonResponse)
                        }
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == AccountAction.path {
                    guard let decoded = try? JSONDecoder().decode(AccountAction.Request.self, from: request.body)
                    else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    Task {
                        let reply = await accountAction.call(decoded)
                        let response = reply.flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == MirrorTransport.appUpdatePath {
                    Task {
                        let reply = await appUpdate.call()
                        let response = reply.flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                } else if request.method == "POST", request.path == MirrorTransport.crashesPath {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if request.body.count <= 2 * CrashReport.rawCap,
                       let report = try? decoder.decode(CrashReport.self, from: request.body) {
                        crashes.call(report)
                        response = MirrorTransport.jsonResponse(Data(#"{"ok":true}"#.utf8))
                        onServed(request)
                    } else {
                        response = MirrorTransport.badRequestResponse()
                    }
                } else if request.method == "POST",
                          request.path == MirrorTransport.activityTokenPath {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let registration = try? decoder.decode(ActivityPushRegistration.self, from: request.body) {
                        activityTokens.call(registration)
                        response = MirrorTransport.jsonResponse(Data(#"{"ok":true}"#.utf8))
                        onServed(request)
                    } else {
                        response = MirrorTransport.badRequestResponse()
                    }
                } else if let route = T3Terminal.parse(method: request.method, request: request) {
                    // The phone's terminal (#507): four short routes plus the
                    // stream, which keeps this connection instead of answering
                    // it once. All of them off this queue — a fork, a pty write
                    // and a never-ending response each.
                    Self.serveTerminal(route, request: request, connection: connection,
                                       terminal: terminal, onServed: onServed)
                    return
                } else {
                    response = MirrorTransport.notFoundResponse()
                }
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // Nothing to answer yet — and nothing ever will be if the peer
            // hung up or is spraying bytes without a request line. Allow a
            // little headroom over the cap for the head itself.
            guard error == nil, !isComplete, buffer.count < cap + 4096 else {
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer, payload: payload, token: token,
                   sessionFeed: sessionFeed, sessionInput: sessionInput, attention: attention, timeline: timeline, commands: commands, files: files, terminal: terminal, descriptor: descriptor, receipts: receipts, leases: leases, sessionImage: sessionImage,
                   activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions, prefs: prefs, checkpoints: checkpoints,
                   team: team, teamControl: teamControl, appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, teamMirror: teamMirror, onServed: onServed)
        }
    }

    // MARK: - Terminal routes (#507 step 3)

    /// One of `T3Terminal`'s five routes onto `TerminalHost`. Every branch
    /// leaves the serving queue first: `open` forks a shell, `write` may wait
    /// on a full pty input buffer (#507 review ruling 4), and the stream never
    /// finishes at all. `nil` from a handler is the route's 404.
    private nonisolated static func serveTerminal(_ route: T3Terminal.Route,
                                                  request: MirrorTransport.Request,
                                                  connection: NWConnection,
                                                  terminal: MirrorTerminalBox,
                                                  onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        let answer: @Sendable (Data) -> Void = { response in
            connection.send(content: response,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard let handlers = terminal.current else {
            answer(MirrorTransport.notFoundResponse())
            return
        }
        let noContent = MirrorTransport.response(status: 204, reason: "No Content",
                                                 contentType: "application/json", body: Data())
        let missing = MirrorTransport.errorResponse(status: 404, message: "no such terminal")
        switch route {
        case .open(let pid):
            guard let body = try? JSONDecoder().decode(T3Terminal.OpenRequest.self, from: request.body) else {
                answer(MirrorTransport.badRequestResponse())
                return
            }
            // forkpty + execve: off this queue, like `POST /sessions/start`.
            DispatchQueue.global(qos: .userInitiated).async {
                let response: Data
                switch handlers.open(pid, body) {
                case .success(let outcome)?:
                    let json = (try? JSONEncoder().encode(outcome.reply)) ?? Data()
                    // Upstream's `terminal.open` reuses a running session
                    // rather than refusing (Manager.ts:152), so a second open
                    // is the existing terminal's reply under a 200, never a 409.
                    response = outcome.created
                        ? MirrorTransport.response(status: 201, reason: "Created",
                                                   contentType: "application/json", body: json)
                        : MirrorTransport.jsonResponse(json)
                case .failure(let error)?:
                    response = terminalFailure(error)
                case nil:
                    response = MirrorTransport.errorResponse(status: 404, message: "no such session")
                }
                onServed(request)
                answer(response)
            }
        case .stream(let pid, let id, let since):
            // Ruling 7: the pairing token rides in `?t=` here because
            // `URLSession.bytes` cannot set a header per chunk — so the only
            // line that ever prints this target masks it.
            Lifecycle.log.notice("terminal \(request.maskedDescription(method: "GET"), privacy: .public)")
            let stream = MirrorTerminalStream(connection: connection)
            // `attach` hands over the snapshot (or the ring replay `since`
            // earned) inline on the host's queue; the chunked head goes out
            // with those first frames, so a 404 is still a plain response.
            DispatchQueue.global(qos: .utility).async {
                guard let attachment = handlers.attach(pid, id, since, { stream.deliver($0) }) else {
                    stream.refuse(missing)
                    return
                }
                onServed(request)
                stream.hold(attachment, detach: handlers.detach)
            }
        case .write(let pid, let id):
            guard let body = try? JSONDecoder().decode(T3Terminal.WriteRequest.self, from: request.body) else {
                answer(MirrorTransport.badRequestResponse())
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let response: Data
                switch handlers.write(pid, id, body) {
                case .success?: response = noContent
                case .failure(let error)?: response = terminalFailure(error)
                case nil: response = missing
                }
                onServed(request)
                answer(response)
            }
        case .resize(let pid, let id):
            guard let body = try? JSONDecoder().decode(T3Terminal.ResizeRequest.self, from: request.body) else {
                answer(MirrorTransport.badRequestResponse())
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let response: Data
                switch handlers.resize(pid, id, body) {
                case .success?: response = noContent
                case .failure(let error)?: response = terminalFailure(error)
                case nil: response = missing
                }
                onServed(request)
                answer(response)
            }
        case .close(let pid, let id):
            // The shell is signalled and this answers; `exited` and `closed`
            // reach the attached streams as the child is reaped.
            DispatchQueue.global(qos: .utility).async {
                let response = handlers.close(pid, id) ? noContent : missing
                onServed(request)
                answer(response)
            }
        }
    }

    /// A host refusal as its status: Core's caps decide, this only names them.
    private nonisolated static func terminalFailure(_ error: TerminalHost.HostError) -> Data {
        switch error {
        case .validation(.colsOutOfRange):
            return MirrorTransport.errorResponse(status: 400, message: "cols outside \(T3Terminal.minCols)…\(T3Terminal.maxCols)")
        case .validation(.rowsOutOfRange):
            return MirrorTransport.errorResponse(status: 400, message: "rows outside \(T3Terminal.minRows)…\(T3Terminal.maxRows)")
        case .validation(.dataTooLarge):
            let body = Data(#"{"error":"write over \#(T3Terminal.maxWriteBytes) bytes"}"#.utf8)
            return MirrorTransport.response(status: 413, reason: "Payload Too Large",
                                            contentType: "application/json", body: body)
        case .validation(.terminalIdInvalid):
            return MirrorTransport.errorResponse(status: 400,
                                                 message: "terminalId must be non-blank and at most \(T3Terminal.maxTerminalIdLength) characters")
        case .validation(.tooManyTerminals):
            // The pid is full (`T3Terminal.maxTerminalsPerSession`): a
            // conflict with the shells already open, not a bad request.
            let body = Data(#"{"error":"too many terminals"}"#.utf8)
            return MirrorTransport.response(status: 409, reason: "Conflict",
                                            contentType: "application/json", body: body)
        case .spawnFailed(let detail):
            return MirrorTransport.errorResponse(status: 500, message: detail)
        }
    }
}
