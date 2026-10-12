import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Is an Infinitus server really listening on this port? (#1137) And whose
/// is it? (#1487)
///
/// The desktop backend publishes its port over the control socket — `prefs
/// set fork_server_port <n>`, then `desktop-credential --origin
/// http://127.0.0.1:<n>` — and the app follows: the CLI's bearer origin is
/// replaced. A publish naming a port nothing serves does not repair itself:
/// `infinitusctl desktop status` reports `reachable: false` with every
/// `thread …` verb refusing, until the app is relaunched.
///
/// So a publish that moves the target is probed first. The well-known route
/// is unauthenticated, so this needs no credential, and it is only ever
/// spoken to loopback.
///
/// What is protected is a *working* target, not the pref: a publish is only
/// refused when the port it would replace answers and the new one does not.
/// With nothing behind either port — the app started before the backend, or
/// the pref still holds a stale number — refusing would wedge the pref for no
/// benefit, so the publish goes through.
///
/// Scope: this refuses a target that is not alive *now*. A target that dies
/// after its publish is the server heartbeat's job (#1146) — the live server
/// re-publishes its own port within the minute and takes the target back. The
/// two together are what make the pair robust.
///
/// The target guarded is one a publish stored (#1199): an instance that never
/// had a publish sits on the default port with nothing of its own behind it,
/// and a server answering there belongs to another instance — the installed
/// app's desktop, on a dev Mac — so `currentPort` is nil until the first
/// publish and such an instance follows its first one. Residual: on a fresh
/// install, in the seconds before the desktop's first publish, a dead
/// publisher could take the default port; the heartbeat corrects it.
///
/// #1487: both verbs name the publishing environment (`--environmentId`), and
/// the app remembers whose the slot is. A publish from another environment is
/// held off while the holder's server still answers *as that environment* —
/// the port alone is not enough, since a worktree's next dev server lands on
/// the same stable port — unless the publisher says `--takeover`, which only a
/// server the user opted in sends. Once the holder is gone the slot is free
/// and the next publish takes it, which is how the installed desktop gets its
/// slot back within a heartbeat of an opted-in dev server quitting.
public enum ForkServerProbe {
    /// What one probe exchange learned: the HTTP status, and the environment
    /// id the route's body names when it decodes (a 2xx from an Infinitus
    /// server always carries one).
    public struct Answer: Sendable, Equatable {
        public var status: Int
        public var environmentId: String?
        public init(status: Int, environmentId: String? = nil) {
            self.status = status
            self.environmentId = environmentId
        }
    }

    /// One probe exchange: the well-known URL in, the answer out, or a throw
    /// for a connection that never got that far. A closure so tests answer
    /// canned statuses on Linux too.
    public typealias Transport = @Sendable (URL) async throws -> Answer

    /// Who a publish says it comes from (#1487): both fields are what the
    /// publishing server put on the request's options, and absent on a
    /// server that predates them.
    public struct Publisher: Sendable, Equatable {
        public var environmentId: String?
        public var takeover: Bool
        public init(environmentId: String? = nil, takeover: Bool = false) {
            self.environmentId = environmentId
            self.takeover = takeover
        }
    }

    /// Short on purpose: this runs on the main actor's command path, and a
    /// server that is up answers loopback in single-digit milliseconds.
    public static let timeoutSeconds: Double = 2

    /// The desktop server's starting port; it scans upward from here, and
    /// `fork_server_port` holds wherever it landed.
    public static let defaultPort = 3773

    /// A port a publish may name at all — a nonsense port is refused before
    /// any socket is opened.
    public static func url(port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/.well-known/t3/environment")
    }

    /// The answer, or nil for a connection that never got a status.
    static func probe(port: Int, using transport: Transport) async -> Answer? {
        guard let url = url(port: port) else { return nil }
        return try? await transport(url)
    }

    /// True only for a 2xx. A refused connection, a timeout and a non-2xx all
    /// read the same way on purpose: *something* answering on the port is not
    /// the same as an Infinitus server answering, and following a publish
    /// onto another app's port is the defect, not a lesser version of it.
    public static func answers(port: Int, using transport: Transport) async -> Bool {
        guard let answer = await probe(port: port, using: transport) else { return false }
        return (200..<300).contains(answer.status)
    }

    /// The environment id an Infinitus server on this port reports, or nil
    /// when nothing of the kind answers.
    public static func identity(port: Int, using transport: Transport) async -> String? {
        guard let answer = await probe(port: port, using: transport), (200..<300).contains(answer.status) else { return nil }
        return answer.environmentId
    }

    public enum Verdict: Equatable {
        /// Follow the publish: the new port answers, it is the port already in
        /// use (the live server's own heartbeat), or there is no working target
        /// to lose.
        case accept
        /// Keep the target the app has: it answers and the new one does not.
        case refuse
        /// Keep the target the app has: another environment's server holds
        /// the slot and still answers as itself (#1487).
        case held(String)
    }

    /// The whole rule, in probe order so the common case costs one exchange:
    /// a publish onto the port already in use is never probed; a publish from
    /// another environment than the holder's is held while the holder still
    /// answers on its port as that environment, unless it takes over; one onto
    /// a port that answers is followed; and only a publish that would trade a
    /// working target for a silent one is refused. `currentPort` nil: no
    /// publish ever stored a port here, so there is no target of this
    /// instance's to lose. `holder` nil: no publish ever named its
    /// environment, so there is no one to hold the slot for.
    public static func verdict(newPort: Int, currentPort: Int?, publisher: Publisher = Publisher(), holder: String? = nil,
                               using transport: Transport) async -> Verdict {
        guard let currentPort else { return .accept }
        if newPort == currentPort { return .accept }
        if let holder, !publisher.takeover, publisher.environmentId != holder {
            if await identity(port: currentPort, using: transport) == holder { return .held(holder) }
            // The holder is gone: whatever answers on its port now is some
            // other server, not a target of ours to keep.
            return .accept
        }
        if await answers(port: newPort, using: transport) { return .accept }
        return await answers(port: currentPort, using: transport) ? .refuse : .accept
    }

    /// The work-log line a refused publish leaves, so the reason is on the
    /// record rather than inferred from a tunnel that points nowhere.
    public static func refusalLine(port: Int) -> String {
        "fork server: publish from :\(port) refused — not answering"
    }

    /// The refusal the publishing server itself reads back over the socket.
    public static func refusalReply(port: Int) -> String {
        "nothing answers /.well-known/t3/environment on :\(port); the previous target is kept"
    }

    /// The work-log line a held-off publish leaves (#1487).
    public static func heldLine(port: Int, holder: String) -> String {
        "fork server: publish from :\(port) held off — environment \(holder) holds the slot"
    }

    /// What a held-off publisher reads back (#1487). Opens with the words
    /// `HELD_REPLY_PREFIX` in the server's `InfinitusServerPort.ts` matches,
    /// so the installed desktop's heartbeat logs it as information: it meets
    /// this once a minute for as long as an opted-in dev server runs.
    public static func heldReply(port: Int, holder: String, currentPort: Int) -> String {
        "held by environment \(holder) on :\(currentPort); it is free once that server quits, or publish from :\(port) with INFINITUS_PUBLISH_SERVER_PORT=1 to take it over"
    }

    /// The real transport: one `URLSession` exchange with no caching, so a
    /// dead port cannot be masked by an earlier good answer. The body is read
    /// for its `environmentId` only; anything else about it is ignored.
    public static let urlSession: Transport = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return Answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, environmentId: environmentId(in: data))
    }

    /// `environmentId` off the well-known route's body, when it is there.
    public static func environmentId(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["environmentId"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
