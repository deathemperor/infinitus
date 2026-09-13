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

    /// The Sync pane's phone switch: every phone route drops its
    /// connection exactly as if nothing were listening while it's off.
    var phoneEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return phone
    }

    func setPhone(_ on: Bool) {
        lock.lock(); phone = on; lock.unlock()
    }
}

/// The `POST /activities/token` handler (alert pushes): the phone's
/// APNs token, handed to AppModel's pusher on the main actor.
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

/// Answers `GET /prefs` (#558): the preference catalog with the
/// install's current values, for a client rendering settings without
/// the Mac's panes.
final class MirrorPrefsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () throws -> PrefCatalog.Reply)?
    private var writer: (@Sendable (PrefCatalog.Write) throws -> PrefCatalog.Pref)?

    func set(_ new: @escaping @Sendable () throws -> PrefCatalog.Reply) {
        lock.lock(); handler = new; lock.unlock()
    }

    func setWrite(_ new: @escaping @Sendable (PrefCatalog.Write) throws -> PrefCatalog.Pref) {
        lock.lock(); writer = new; lock.unlock()
    }

    func call() -> PrefCatalog.Reply? {
        lock.lock(); let current = handler; lock.unlock()
        return try? current?()
    }

    /// `POST /prefs`: nil when nothing answers; a refusal is thrown with
    /// its message, so the response can carry it.
    func write(_ request: PrefCatalog.Write) throws -> PrefCatalog.Pref? {
        lock.lock(); let current = writer; lock.unlock()
        return try current?(request)
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
    /// Answers `POST /activities/token`; set by AppModel once at start.
    let activityTokens = MirrorActivityTokenBox()
    /// Answers `GET /.well-known/infinitus`; set by AppModel once at start.
    let descriptor = MirrorDescriptorBox()
    /// Client-activity leases (#223 phase 5): who is looking at what.
    let leases = LeaseTable()
    let awsLogin = MirrorAwsLoginBox()
    /// Answers `POST /crashes`; set by AppModel once at start.
    let crashes = MirrorCrashBox()
    let prefs = MirrorPrefsBox()
    /// Answers `POST /app/update` (#121); set by AppModel once at start.
    let appUpdate = MirrorAppUpdateBox()
    let accountAction = MirrorAccountActionBox()
    /// Event-log sink (icon, text), set by AppModel.
    var log: ((String, String) -> Void)?
    /// Fires with the bound port once the listener is up — the quick
    /// tunnel can only be pointed at a port that exists.
    var onReady: ((UInt16) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "run.infinitus.mirror-server")

    /// Off: phone routes (snapshot, tails, pairing, the descriptor) drop
    /// their connection while the listener is up.
    var phoneEnabled: Bool {
        get { token.phoneEnabled }
        set { token.setPhone(newValue) }
    }

    func start(machineName: String, token: String) {
        self.token.set(token)
        guard listener == nil else { return }
        // The last export renders immediately: a phone that asks before
        // the first refresh of this launch still gets a fleet.
        if payload.latest == nil,
           let data = try? Data(contentsOf: MirrorExporter.url) {
            payload.set(data)
        }
        status = "starting…"
        listen(on: MirrorTransport.defaultPort, name: machineName)
    }

    var isListening: Bool { listener != nil }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = nil
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
        listener.service = NWListener.Service(name: name, type: MirrorTransport.bonjourType)
        let payload = self.payload
        let token = self.token
        let prefs = self.prefs
        let appUpdate = self.appUpdate
        let accountAction = self.accountAction
        let descriptor = self.descriptor
        let leases = self.leases
        let activityTokens = self.activityTokens
        let awsLogin = self.awsLogin
        let crashes = self.crashes
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
            Self.serve(connection, payload: payload, token: token, descriptor: descriptor, leases: leases,
                       activityTokens: activityTokens, crashes: crashes, prefs: prefs,
                       appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, queue: queue, onServed: served)
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

    private nonisolated static func serve(_ connection: NWConnection,
                                          payload: MirrorPayloadBox,
                                          token: MirrorTokenBox,
                                          descriptor: MirrorDescriptorBox,
                                          leases: LeaseTable,
                                          activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, prefs: MirrorPrefsBox,
                                          appUpdate: MirrorAppUpdateBox,
                                          awsLogin: MirrorAwsLoginBox, accountAction: MirrorAccountActionBox,
                                          queue: DispatchQueue,
                                          onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), payload: payload, token: token, descriptor: descriptor, leases: leases,
               activityTokens: activityTokens, crashes: crashes, prefs: prefs,
               appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, onServed: onServed)
    }

    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox,
                                            token: MirrorTokenBox,
                                            descriptor: MirrorDescriptorBox,
                                            leases: LeaseTable,
                                            activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox, prefs: MirrorPrefsBox,
                                            appUpdate: MirrorAppUpdateBox,
                                            awsLogin: MirrorAwsLoginBox, accountAction: MirrorAccountActionBox,
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
            let wellKnown = head.map { $0.method == "GET" && $0.path == MirrorTransport.wellKnownPath } ?? false
            // Phone switch off (#356): the listener is up for nothing else
            // now, so a phone route gets what it would with no listener —
            // a closed connection, never a 401 that reads as "unpaired"
            // on the phone.
            if head != nil, !token.phoneEnabled {
                connection.cancel()
                return
            }
            if let head, !wellKnown, !MirrorTransport.isAuthorized(head, token: token.current) {
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
                guard token.phoneEnabled else { connection.cancel(); return }   // #356, checked off the head above too
                let response: Data
                if request.method == "GET", request.path == MirrorTransport.wellKnownPath {
                    // Unauthenticated by design (#223 phase 4): what this
                    // Mac supports, read before pairing. No I/O, on the queue.
                    response = descriptor.call().flatMap { try? JSONEncoder().encode($0) }
                        .map(MirrorTransport.jsonResponse) ?? MirrorTransport.unavailableResponse()
                } else if !MirrorTransport.isAuthorized(request, token: token.current) {
                    response = MirrorTransport.unauthorizedResponse()
                } else if request.method == "GET",
                          request.path == MirrorTransport.snapshotPath {
                    response = payload.latest.map(MirrorTransport.snapshotResponse)
                        ?? MirrorTransport.unavailableResponse()
                    onServed(request)
                } else if request.method == "POST", request.path == PrefCatalog.path {
                    guard let write = try? JSONDecoder().decode(PrefCatalog.Write.self, from: request.body) else {
                        connection.send(content: MirrorTransport.badRequestResponse(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Waits on the main actor for the write and reload: off this queue.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let response: Data
                        do {
                            response = try prefs.write(write).flatMap { try? JSONEncoder().encode($0) }
                                .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        } catch let unknown as PrefCatalog.UnknownKey {
                            response = MirrorTransport.errorResponse(status: 404, message: "unknown pref \(unknown.key)")
                        } catch let refused as PrefCatalog.Violation {
                            response = MirrorTransport.errorResponse(status: 400, message: refused.message)
                        } catch {
                            response = MirrorTransport.errorResponse(status: 500, message: "\(error)")
                        }
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
            receive(connection, buffer: buffer, payload: payload, token: token, descriptor: descriptor, leases: leases,
                   activityTokens: activityTokens, crashes: crashes, prefs: prefs,
                   appUpdate: appUpdate, awsLogin: awsLogin, accountAction: accountAction, onServed: onServed)
        }
    }

}
