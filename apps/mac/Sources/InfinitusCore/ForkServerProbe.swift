import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Is an Infinitus server really listening on this port? (#1137)
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
public enum ForkServerProbe {
    /// One probe exchange: the well-known URL in, the HTTP status out, or a
    /// throw for a connection that never got that far. A closure so tests
    /// answer canned statuses on Linux too.
    public typealias Transport = @Sendable (URL) async throws -> Int

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

    /// True only for a 2xx. A refused connection, a timeout and a non-2xx all
    /// read the same way on purpose: *something* answering on the port is not
    /// the same as an Infinitus server answering, and following a publish
    /// onto another app's port is the defect, not a lesser version of it.
    public static func answers(port: Int, using transport: Transport) async -> Bool {
        guard let url = url(port: port) else { return false }
        do { return (200..<300).contains(try await transport(url)) } catch { return false }
    }

    public enum Verdict: Equatable {
        /// Follow the publish: the new port answers, it is the port already in
        /// use (the live server's own heartbeat), or there is no working target
        /// to lose.
        case accept
        /// Keep the target the app has: it answers and the new one does not.
        case refuse
    }

    /// The whole rule, in probe order so the common case costs one exchange:
    /// a publish onto the port already in use is never probed, one onto a port
    /// that answers is followed, and only a publish that would trade a working
    /// target for a silent one is refused. `currentPort` nil: no publish ever
    /// stored a port here, so there is no target of this instance's to lose.
    public static func verdict(newPort: Int, currentPort: Int?, using transport: Transport) async -> Verdict {
        guard let currentPort else { return .accept }
        if newPort == currentPort { return .accept }
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

    /// The real transport: one `URLSession` exchange with no caching, so a
    /// dead port cannot be masked by an earlier good answer.
    public static let urlSession: Transport = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
