import Foundation

/// The two control routes (#220 §5.2) as request → response functions,
/// like `TeamNearby.respond`: the Mac's MirrorServer and the Linux
/// tray's PosixHTTPServer mount the same handler. No pairing token: a
/// command authenticates itself (the envelope), a tail request carries
/// a signature over the session and the minute.
public enum TeamControlRoute {
    public static let commandPath = "/team/command"
    private static let tailPrefix = "/team/sessions/"
    public static func tailPath(sessionId: String) -> String { tailPrefix + sessionId + "/tail" }

    public static func tailSessionId(_ path: String) -> String? {
        guard path.hasPrefix(tailPrefix), path.hasSuffix("/tail") else { return nil }
        let id = path.dropFirst(tailPrefix.count).dropLast("/tail".count)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return String(id)
    }

    /// `MirrorTransport` lowercases header names.
    public static let tailHeader = "x-infinitus-team"

    static func tailMessage(sessionId: String, minute: Int) -> Data { Data("tail|\(sessionId)|\(minute)".utf8) }

    public static func signTail(sessionId: String, by driver: TeamIdentity, now: Date) throws -> String {
        let minute = Int(now.timeIntervalSince1970) / 60
        return driver.kid + "." + (try driver.sign(tailMessage(sessionId: sessionId, minute: minute))).base64EncodedString()
    }

    /// This minute or the previous one, so a request signed at :59 is not
    /// refused at :00. Two minutes on, it is stale.
    public static func checkTail(_ header: String, sessionId: String, roster: TeamRoster, now: Date) -> String? {
        guard let dot = header.firstIndex(of: "."), dot != header.startIndex else { return nil }
        let kid = String(header[..<dot])
        guard let sig = Data(base64Encoded: String(header[header.index(after: dot)...])),
              let keys = roster.keys(for: kid), let key = try? keys.signingKey() else { return nil }
        let minute = Int(now.timeIntervalSince1970) / 60
        for m in [minute, minute - 1] where key.isValidSignature(sig, for: tailMessage(sessionId: sessionId, minute: m)) {
            return kid
        }
        return nil
    }

    /// The live feed for a session, as the phone's tail route serves it.
    public struct Tail {
        public var read: (_ sessionId: String, _ since: String?) -> Data?
        public init(read: @escaping (String, String?) -> Data?) { self.read = read }
    }

    /// nil = not ours, keep routing. No endpoint or no grants ⇒ 404 on
    /// every control route (default off, and a stranger learns nothing).
    public static func respond(_ request: MirrorTransport.Request, endpoint: inout TeamControl.Endpoint?, tail: Tail) -> Data? {
        let isCommand = request.path == commandPath
        let tailId = tailSessionId(request.path)
        guard isCommand || tailId != nil else { return nil }
        guard var ep = endpoint, !ep.grants().grants.isEmpty else { return MirrorTransport.notFoundResponse() }
        defer { endpoint = ep }
        switch (request.method, isCommand, tailId) {
        case ("POST", true, _):
            guard !request.body.isEmpty else { return MirrorTransport.badRequestResponse() }
            let (ack, audit, driverKeys) = TeamControl.handle(request.body, endpoint: &ep)
            ep.lastAudit = audit
            guard let driverKeys, let sealed = try? TeamControl.sealAck(ack, from: ep.identity, to: driverKeys, at: ack.at) else {
                return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/octet-stream", body: Data())
            }
            return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/octet-stream", body: sealed)
        case ("GET", false, let id?):
            guard let roster = ep.roster(), let header = request.headers[tailHeader],
                  let kid = checkTail(header, sessionId: id, roster: roster, now: ep.now()),
                  ep.grants().permits(kid: kid, session: id, capability: TeamGrants.view, roster: roster) != nil else {
                return MirrorTransport.response(status: 403, reason: "Forbidden", contentType: "text/plain", body: Data("no view grant\n".utf8))
            }
            let since = request.target.split(separator: "?", maxSplits: 1).dropFirst().first
                .flatMap { $0.split(separator: "&").first { $0.hasPrefix("since=") } }.map { String($0.dropFirst("since=".count)) }
            guard let bytes = tail.read(id, since) else { return MirrorTransport.notFoundResponse() }
            return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/json", body: bytes)
        default:
            return MirrorTransport.notFoundResponse()
        }
    }
}
