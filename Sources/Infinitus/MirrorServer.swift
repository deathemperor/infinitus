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

    var current: String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func set(_ new: String) {
        lock.lock(); token = new; lock.unlock()
    }
}

/// The `/sessions/<pid>/tail` handler (#17 layer 1), boxed the same way
/// as payload/token: AppModel sets it from the main actor, the
/// connection handlers call it from the network queue. The closure does
/// its own file read (`ClaudeSessions.list` + `SessionFeedReader.read`)
/// on that queue — off the main actor, same as every other route here.
final class MirrorSessionFeedBox: @unchecked Sendable {
    typealias Provider = @Sendable (_ pid: Int32, _ limit: Int, _ since: String?, _ wait: TimeInterval) -> Data?
    private let lock = NSLock()
    private var provider: Provider?

    func set(_ new: @escaping Provider) {
        lock.lock(); provider = new; lock.unlock()
    }

    /// May block for up to `wait` seconds (the long-poll) — call it off
    /// the network queue when `wait > 0`.
    func call(_ pid: Int32, _ limit: Int, since: String? = nil, wait: TimeInterval = 0) -> Data? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, limit, since, wait)
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

/// Where `POST /sessions/<pid>/input` deliveries run, one at a time.
private let mirrorInputQueue = DispatchQueue(label: "run.infinitus.mirror-input", qos: .userInitiated)

final class MirrorSessionInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?)?

    func set(_ new: @escaping @Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ request: SessionInput.Request) -> SessionInput.Reply? {
        lock.lock(); let current = provider; lock.unlock()
        return current?(pid, request)
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
    /// queue.
    var endpoint: TeamNearby.Endpoint {
        TeamNearby.Endpoint(local: current) { request in
            let paths = TeamPaths.standard()
            return try TeamNearby.Store.save(request, paths: paths, secrets: FileSecrets(dir: paths.secretsDir))
        }
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
    /// Answers `/sessions/<pid>/images/<id>`; set by AppModel once at start.
    let sessionImage = MirrorSessionImageBox()
    let awsLogin = MirrorAwsLoginBox()
    /// Answers `POST /crashes`; set by AppModel once at start.
    let crashes = MirrorCrashBox()
    /// Nearby (spec §6.4): the TXT record and `/team/key` + `/team/request`.
    let team = MirrorTeamBox()
    private var advertisedName = ""
    private var teamDiscoverable = false
    private var defaultsObserver: NSObjectProtocol?
    /// Answers `POST /sessions/start` (#91); set by AppModel once at start.
    let sessionStart = MirrorSessionStartBox()
    /// Answers `GET /sessions/past` (#164); set by AppModel once at start.
    let pastSessions = MirrorPastSessionsBox()
    /// Answers `POST /app/update` (#121); set by AppModel once at start.
    let appUpdate = MirrorAppUpdateBox()
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
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = nil
    }

    /// Reads the switch and, when it changed, rebuilds the standing off
    /// the main actor (it opens the team clones) and re-advertises.
    private func refreshTeamStanding(force: Bool = false) {
        let on = UserDefaults.standard.bool(forKey: TeamNearby.discoverableDefaultsKey)
        guard force || on != teamDiscoverable else { return }
        teamDiscoverable = on
        let name = advertisedName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let paths = TeamPaths.standard()
            let local = TeamNearby.Local.load(name: name, discoverable: on, paths: paths,
                                              secrets: FileSecrets(dir: paths.secretsDir))
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
        let appUpdate = self.appUpdate
        let sessionInput = self.sessionInput
        let sessionImage = self.sessionImage
        let activityTokens = self.activityTokens
        let awsLogin = self.awsLogin
        let crashes = self.crashes
        let team = self.team
        let served: @Sendable (MirrorTransport.Request) -> Void = { [weak self] request in
            let client = MirrorClient(request: request)
            Task { @MainActor in
                guard let self else { return }
                self.lastServed = client.lastSeen
                self.clients = MirrorClient.merge(client, into: self.clients)
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            Self.serve(connection, payload: payload, token: token, sessionFeed: sessionFeed,
                       sessionInput: sessionInput, sessionImage: sessionImage, activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions,
                       team: team, appUpdate: appUpdate, awsLogin: awsLogin, queue: queue, onServed: served)
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
                                            sessionImage: MirrorSessionImageBox,
                                          activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, sessionStart: MirrorSessionStartBox, pastSessions: MirrorPastSessionsBox,
                                          team: MirrorTeamBox, appUpdate: MirrorAppUpdateBox,
                                          awsLogin: MirrorAwsLoginBox,
                                          queue: DispatchQueue,
                                          onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), payload: payload, token: token,
               sessionFeed: sessionFeed, sessionInput: sessionInput, sessionImage: sessionImage,
               activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions,
               team: team, appUpdate: appUpdate, awsLogin: awsLogin, onServed: onServed)
    }

    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox,
                                            token: MirrorTokenBox,
                                            sessionFeed: MirrorSessionFeedBox,
                                            sessionInput: MirrorSessionInputBox,
                                            sessionImage: MirrorSessionImageBox,
                                            activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, sessionStart: MirrorSessionStartBox, pastSessions: MirrorPastSessionsBox,
                                            team: MirrorTeamBox, appUpdate: MirrorAppUpdateBox,
                                            awsLogin: MirrorAwsLoginBox,
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
            let teamRoute = (head.map { $0.path.hasPrefix(TeamNearby.routePrefix) } ?? false)
                && Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
            if let head, !teamRoute, !MirrorTransport.isAuthorized(head, token: token.current) {
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
                let response: Data
                if !MirrorTransport.isAuthorized(request, token: token.current) {
                    response = MirrorTransport.unauthorizedResponse()
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
                    // Off this queue either way: a long-poll sleeps until
                    // the transcript moves, and even the plain form reads
                    // a 256 KiB tail — every connection shares this queue,
                    // so nothing that takes time may run on it.
                    DispatchQueue.global(qos: .utility).async {
                        let data = sessionFeed.call(pid, limit, since: since, wait: wait)
                        let response = data.map(MirrorTransport.snapshotResponse)
                            ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
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
                        let response = sessionInput.call(pid, decoded)
                            .flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
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
                        let response = sessionStart.call(decoded)
                            .flatMap { try? JSONEncoder().encode($0) }
                            .map(MirrorTransport.jsonResponse)
                            ?? MirrorTransport.notFoundResponse()
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
                   sessionFeed: sessionFeed, sessionInput: sessionInput, sessionImage: sessionImage,
                   activityTokens: activityTokens, crashes: crashes, sessionStart: sessionStart, pastSessions: pastSessions,
                   team: team, appUpdate: appUpdate, awsLogin: awsLogin, onServed: onServed)
        }
    }
}
