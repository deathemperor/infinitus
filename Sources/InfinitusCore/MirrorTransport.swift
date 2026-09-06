import Foundation

// MARK: - LAN mirror transport (#9)
//
// The phone reads the fleet snapshot off the Mac over the local network:
// one Bonjour-advertised TCP listener speaking the smallest possible
// HTTP/1.1 — `GET /snapshot` → the exact bytes MirrorExporter wrote.
// Network.framework is Apple-only, so only the wire format lives here
// (InfinitusCore also compiles for the Linux tray); the listener is in
// Sources/Infinitus/MirrorServer.swift and the client in ios/.

public enum MirrorTransport {
    /// Bonjour service type both sides agree on.
    public static let bonjourType = "_infinitus._tcp"
    /// The one route the server answers.
    public static let snapshotPath = "/snapshot"
    /// The per-session feed route (#17 layer 1): `GET /sessions/<pid>/tail`.
    public static func sessionTailPath(pid: Int32) -> String { "/sessions/\(pid)/tail" }
    /// The `pid` out of a request path, when it matches
    /// `/sessions/<pid>/tail` exactly — `nil` for anything else,
    /// including a non-numeric pid.
    public static func sessionTailPid(_ path: String) -> Int32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "sessions", parts[2] == "tail" else { return nil }
        return Int32(parts[1])
    }
    /// A user prompt's image as a thumbnail: `GET /sessions/<pid>/images/<id>`,
    /// the id from a feed item's `images` (phone thumbnails, 2026-09-04).
    public static func sessionImagePath(pid: Int32, id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return "/sessions/\(pid)/images/" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)
    }
    /// The `pid` and image id out of a request path, when it matches
    /// `/sessions/<pid>/images/<id>` exactly.
    public static func sessionImageRef(_ path: String) -> (pid: Int32, id: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "sessions", parts[2] == "images",
              let pid = Int32(parts[1]), let id = String(parts[3]).removingPercentEncoding, !id.isEmpty
        else { return nil }
        return (pid, id)
    }
    /// A session's checkpoint timeline (#167 phase 2): `GET /sessions/<pid>/checkpoints`.
    public static func sessionCheckpointsPath(pid: Int32) -> String { "/sessions/\(pid)/checkpoints" }
    /// The `pid` out of `/sessions/<pid>/checkpoints` exactly.
    public static func sessionCheckpointsPid(_ path: String) -> Int32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "sessions", parts[2] == "checkpoints" else { return nil }
        return Int32(parts[1])
    }
    /// One checkpoint's actions: `GET /sessions/<pid>/checkpoints/<n>/diff[?to=<m>]`
    /// (against checkpoint `m`, or the working tree now) and
    /// `POST /sessions/<pid>/checkpoints/<n>/restore`.
    public static func sessionCheckpointPath(pid: Int32, n: Int, action: CheckpointAction) -> String {
        "/sessions/\(pid)/checkpoints/\(n)/\(action.rawValue)"
    }
    public enum CheckpointAction: String, Sendable { case diff, restore }
    /// The pid, checkpoint number and action out of a checkpoint path,
    /// when it matches exactly.
    public static func sessionCheckpointRef(_ path: String) -> (pid: Int32, n: Int, action: CheckpointAction)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0] == "sessions", parts[2] == "checkpoints",
              let pid = Int32(parts[1]), let n = Int(parts[3]), let action = CheckpointAction(rawValue: String(parts[4]))
        else { return nil }
        return (pid, n, action)
    }
    /// Query parameter naming the second checkpoint of a diff.
    public static let checkpointToQueryName = "to"
    /// The per-session input route (#17 layer 2): `POST /sessions/<pid>/input`.
    public static func sessionInputPath(pid: Int32) -> String { "/sessions/\(pid)/input" }
    /// The `pid` out of a request path, when it matches
    /// `/sessions/<pid>/input` exactly.
    public static func sessionInputPid(_ path: String) -> Int32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "sessions", parts[2] == "input" else { return nil }
        return Int32(parts[1])
    }
    /// Query parameter carrying the item limit for the tail route.
    /// `POST /activities/token` — the phone's Live Activity push tokens
    /// (an `ActivityPushRegistration` body; 204 when stored).
    public static let activityTokenPath = "/activities/token"
    /// `POST /crashes`: the phone's MetricKit crash/hang reports.
    public static let crashesPath = "/crashes"
    /// `POST /app/update` (#121): the phone's trigger for this Mac's
    /// own update, empty body.
    public static let appUpdatePath = "/app/update"
    public static let tailLimitQueryName = "n"
    /// Long-poll: `?since=<feed.stamp>&wait=<seconds>` holds the reply until
    /// the transcript's stamp differs from `since`, or `wait` elapses
    /// (capped at `tailWaitMax`) — then answers with the current feed.
    public static let tailSinceQueryName = "since"
    public static let tailWaitQueryName = "wait"
    public static let tailWaitMax: TimeInterval = 25
    /// Query parameter carrying the pairing token when a header can't
    /// (a QR-pasted URL opened in a browser, `curl "…?t=TOKEN"`).
    public static let tokenQueryName = "t"
    /// Preferred listening port — fixed so the phone's manual
    /// `host:port` override has something to guess when mDNS is blocked.
    /// The server falls back to a kernel-assigned port if it's taken.
    public static let defaultPort: UInt16 = 47824
    /// Default body cap for every route except `POST /sessions/*/input`
    /// (`/snapshot` and `/tail` never carry a body worth more than this).
    public static let defaultBodyCap = 16 * 1024
    /// `POST /sessions/<pid>/input` carries up to 4 attachments at 5 MiB
    /// each, base64-inflated — room for that plus the JSON envelope
    /// (2026-09-03 "add features to allow attachments").
    public static let sessionInputBodyCap = 24 * 1024 * 1024

    // MARK: - Server side

    /// Method + path of an HTTP request, from however many bytes have
    /// arrived so far. `nil` while the request line is still incomplete.
    public static func requestTarget(_ data: Data) -> (method: String, path: String)? {
        guard let end = data.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// A whole request head: the request line plus every header, which is
    /// what auth needs (the token may ride in `Authorization`). `nil`
    /// while the head is still arriving — headers land in arbitrary
    /// chunks just like bodies do.
    public struct Request: Sendable, Equatable {
        public let method: String
        /// The raw request target, query string and all.
        public let target: String
        /// Header names lowercased; HTTP says they're case-insensitive.
        public let headers: [String: String]
        /// The request body, once fully received (#17 layer 2's `POST
        /// /sessions/<pid>/input`). Empty for every route that has none.
        public let body: Data

        public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
            self.method = method
            self.target = target
            self.headers = headers
            self.body = body
        }

        /// The target with any `?query` stripped — what routing compares.
        public var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[target.startIndex..<mark])
        }

        /// A percent-decoded query parameter.
        public func query(_ name: String) -> String? {
            guard let mark = target.firstIndex(of: "?") else { return nil }
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard halves.first.map(String.init) == name else { continue }
                let raw = halves.count == 2 ? String(halves[1]) : ""
                return raw.replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? raw
            }
            return nil
        }
    }

    /// The head (request line + headers) and the index where the body
    /// starts, once the head has fully arrived. Shared by `parseRequest`
    /// (which never waits for a body) and `parseRequestWithBody` (which
    /// does).
    private static func parseHead(_ data: Data) -> (Request, Data.Index)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let request = lines.removeFirst().split(separator: " ",
                                                omittingEmptySubsequences: true)
        guard request.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            headers[halves[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                halves[1].trimmingCharacters(in: .whitespaces)
        }
        return (Request(method: String(request[0]), target: String(request[1]), headers: headers),
                split.upperBound)
    }

    public static func parseRequest(_ data: Data) -> Request? {
        parseHead(data)?.0
    }

    /// The body cap a route should use, decided from the request line
    /// alone — the head parses (and so the route is known) well before a
    /// large body has fully arrived. Every route but `POST
    /// /sessions/*/input` keeps the small default.
    public static func bodyCap(method: String, path: String) -> Int {
        method == "POST" && sessionInputPid(path) != nil ? sessionInputBodyCap : defaultBodyCap
    }

    /// A whole request, body included: `nil` while the head or (when
    /// `Content-Length` says there's more) the body is still arriving.
    /// A request with no `Content-Length` is complete as soon as the head
    /// is — GETs never carry a body. `bodyCap` guards a runaway
    /// `Content-Length`: once that many body bytes have arrived the
    /// request is treated as complete, its body silently truncated,
    /// leaving the route's own decode to reject it.
    public static func parseRequestWithBody(_ data: Data, bodyCap: Int = defaultBodyCap) -> Request? {
        guard let (head, bodyStart) = parseHead(data) else { return nil }
        guard let lengthText = head.headers["content-length"], let length = Int(lengthText), length > 0
        else { return head }
        let want = min(length, bodyCap)
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= want else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: want)
        return Request(method: head.method, target: head.target, headers: head.headers,
                       body: data[bodyStart..<bodyEnd])
    }

    // MARK: - Pairing check (#9 remote access)

    /// The token a request carries: `Authorization: Bearer <token>` or,
    /// for URLs pasted from a QR, `?t=<token>`.
    public static func presentedToken(_ request: Request) -> String? {
        if let header = request.headers["authorization"] {
            let parts = header.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1])
            }
        }
        return request.query(tokenQueryName)
    }

    /// Whether a request may read the snapshot. An empty expected token
    /// denies everything: a server without a pairing token is not a
    /// server anyone is allowed to read.
    public static func isAuthorized(_ request: Request, token: String) -> Bool {
        let expected = MirrorPairing.normalize(token)
        guard !expected.isEmpty,
              let presented = presentedToken(request) else { return false }
        return MirrorPairing.matches(MirrorPairing.normalize(presented), expected)
    }

    public static func response(status: Int, reason: String,
                                contentType: String, body: Data,
                                extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    public static func snapshotResponse(_ body: Data) -> Data {
        response(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    /// Any 200 JSON body (#17 layer 2's `SessionInput.Reply`) — same
    /// shape as `snapshotResponse`, named for what it's generically used
    /// for now that there's more than one JSON route.
    public static func jsonResponse(_ body: Data) -> Data {
        response(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    /// An image body (`/sessions/<pid>/images/<id>`); a thumbnail never
    /// changes for its id, so the phone may keep it.
    public static func imageResponse(_ body: Data, contentType: String) -> Data {
        response(status: 200, reason: "OK", contentType: contentType, body: body,
                 extraHeaders: ["Cache-Control": "private, max-age=86400"])
    }

    public static func notFoundResponse() -> Data {
        response(status: 404, reason: "Not Found", contentType: "text/plain",
                 body: Data("no such route\n".utf8))
    }

    /// A `POST` body that didn't parse as the route's expected JSON.
    public static func badRequestResponse() -> Data {
        response(status: 400, reason: "Bad Request", contentType: "text/plain",
                 body: Data("bad request body\n".utf8))
    }

    /// No pairing token, or the wrong one (#9 remote access). The realm
    /// names the app so a browser's prompt says where the token comes from.
    public static func unauthorizedResponse() -> Data {
        response(status: 401, reason: "Unauthorized", contentType: "text/plain",
                 body: Data("pairing token required\n".utf8),
                 extraHeaders: ["WWW-Authenticate": "Bearer realm=\"infinitus\""])
    }

    /// The listener is up but no snapshot has been captured yet.
    public static func unavailableResponse() -> Data {
        response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                 body: Data("no snapshot yet\n".utf8))
    }

    // MARK: - Client side

    public struct HTTPResponse: Sendable, Equatable {
        public let status: Int
        public let body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    /// Parses an accumulating response buffer. `nil` means "keep
    /// receiving" — TCP hands headers and body over in arbitrary chunks.
    public static func parseResponse(_ buffer: Data) -> HTTPResponse? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ",
                                                   omittingEmptySubsequences: true)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var length: Int?
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces)
                      .lowercased() == "content-length" else { continue }
            length = Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }
        // No Content-Length: the body runs to close, which the caller
        // signals by parsing one last time on isComplete.
        let body = buffer[split.upperBound...]
        guard let length else { return HTTPResponse(status: status, body: Data(body)) }
        guard body.count >= length else { return nil }
        return HTTPResponse(status: status, body: Data(body.prefix(length)))
    }

    /// Where the phone should connect: a manual `host:port` as typed by
    /// a human on a network where mDNS doesn't survive, or a whole URL
    /// as carried by a pairing QR (`https://x.trycloudflare.com` →
    /// port 443 over TLS).
    public struct Endpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        /// The connection speaks TLS — true only for an `https://` URL.
        public let useTLS: Bool

        public init(host: String, port: UInt16, useTLS: Bool = false) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }

        /// The `http(s)://host:port` form a QR encodes.
        public var urlText: String {
            let scheme = useTLS ? "https" : "http"
            let bracketed = host.contains(":") ? "[\(host)]" : host
            let implied: UInt16 = useTLS ? 443 : 80
            return port == implied ? "\(scheme)://\(bracketed)"
                : "\(scheme)://\(bracketed):\(port)"
        }
    }

    /// `nil` when the text is empty or nonsense — the caller then stays
    /// on Bonjour.
    public static func parseEndpoint(_ text: String) -> Endpoint? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var tls = false
        var defaultForScheme = defaultPort
        for (scheme, secure) in [("https://", true), ("http://", false)] {
            guard trimmed.lowercased().hasPrefix(scheme) else { continue }
            trimmed = String(trimmed.dropFirst(scheme.count))
            tls = secure
            // A URL without a port means the scheme's own port, not the
            // Bonjour default: tunnels answer on 443.
            defaultForScheme = secure ? 443 : 80
            break
        }
        // A pasted URL can carry a path ("…/snapshot") or a query.
        if let cut = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" }) {
            trimmed = String(trimmed[trimmed.startIndex..<cut])
        }
        guard !trimmed.isEmpty else { return nil }
        // Bracketed IPv6 literal: [::1]:47824
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { return Endpoint(host: host, port: defaultForScheme, useTLS: tls) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return Endpoint(host: host, port: port, useTLS: tls)
        }
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[trimmed.startIndex..<colon])
            let portText = trimmed[trimmed.index(after: colon)...]
            // `host.contains(":")` guards a bare IPv6 literal ("fe80::1"),
            // which has no port and falls through to the bare-host case.
            if !host.isEmpty, !host.contains(":"), let port = UInt16(portText) {
                return Endpoint(host: host, port: port, useTLS: tls)
            }
        }
        return Endpoint(host: trimmed, port: defaultForScheme, useTLS: tls)
    }
}
