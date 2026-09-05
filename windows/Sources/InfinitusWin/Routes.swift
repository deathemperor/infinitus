import Foundation
import InfinitusCore

/// W7: the phone-facing HTTP surface. Every route answers exactly what
/// the Mac's tray answers (`Sources/InfinitusTray/InfinitusTray.swift`),
/// so the phone can't tell a Windows host from a Mac one except by what
/// the snapshot declares.
///
/// Input goes over the named pipe and nothing else: `hosts: []` keeps
/// `SessionInput.deliver`'s terminal fallback out of reach, because
/// Windows Terminal has no send-keys. A `key` press therefore reports
/// `noSurface` rather than pretending.
enum Routes {
    /// Builds the one handler `WinHTTPServer` mounts.
    static func handler(claudeDir: URL, snapshot: SnapshotCache,
                        token: String,
                        log: @escaping @Sendable (String) -> Void = { _ in })
        -> @Sendable (MirrorTransport.Request) -> Data {
        { request in
            guard MirrorTransport.isAuthorized(request, token: token) else {
                return MirrorTransport.unauthorizedResponse()
            }
            if request.method == "GET", request.path == MirrorTransport.snapshotPath {
                let data = snapshot.data()
                return data.isEmpty ? MirrorTransport.unavailableResponse()
                                    : MirrorTransport.snapshotResponse(data)
            }
            if request.method == "GET", let pid = MirrorTransport.sessionTailPid(request.path) {
                return tail(pid: pid, request: request, claudeDir: claudeDir)
            }
            if request.method == "GET", let ref = MirrorTransport.sessionImageRef(request.path) {
                return image(pid: ref.pid, id: ref.id, claudeDir: claudeDir)
            }
            if request.method == "POST", let pid = MirrorTransport.sessionInputPid(request.path) {
                return input(pid: pid, request: request, claudeDir: claudeDir, log: log)
            }
            // The phone posts its push token on launch; Windows has no
            // APNs path, so accept and discard rather than 404 on every
            // launch (02-feed-readonly.md).
            if request.method == "POST", request.path == MirrorTransport.activityTokenPath {
                return MirrorTransport.jsonResponse(Data("{}".utf8))
            }
            return MirrorTransport.notFoundResponse()
        }
    }

    /// `GET /sessions/<pid>/tail?n=&since=&wait=` — the session's feed,
    /// long-polling when `since`/`wait` are given. Blocking is fine: the
    /// listener runs one thread per connection.
    static func tail(pid: Int32, request: MirrorTransport.Request, claudeDir: URL) -> Data {
        let limit = max(0, request.query(MirrorTransport.tailLimitQueryName).flatMap(Int.init) ?? 30)
        SessionFeedReader.waitForChange(
            pid: pid, claudeDir: claudeDir,
            since: request.query(MirrorTransport.tailSinceQueryName),
            wait: request.query(MirrorTransport.tailWaitQueryName).flatMap(Double.init) ?? 0)
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit)
        else {
            return MirrorTransport.notFoundResponse()
        }
        // W9: the phone gates its composer on these. `keys` is false —
        // Windows Terminal exposes no send-keys — so a session whose pipe
        // is gone is honestly uncontrollable rather than silently ignored.
        let annotated = SessionFeed(
            pid: feed.pid, sessionId: feed.sessionId, cwd: feed.cwd, status: feed.status,
            waiting: feed.waiting, items: feed.items, name: feed.name, stamp: feed.stamp,
            canMessage: NamedPipe.isListening(record.messagingSocketPath), keys: false,
            permissionMode: feed.permissionMode)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(annotated) else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.snapshotResponse(encoded)
    }

    /// `GET /sessions/<pid>/images/<id>` — original bytes with the
    /// transcript's media type (WIC downscaling is W16), capped so a
    /// pathological transcript can't hand the phone a 100 MB body.
    static func image(pid: Int32, id: String, claudeDir: URL) -> Data {
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let found = SessionFeedReader.imageData(
                  record: record, id: id, claudeDir: claudeDir,
                  attachmentsDir: SessionInput.defaultAttachmentsDir),
              found.data.count <= maxImageBytes
        else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.imageResponse(found.data, contentType: found.mime)
    }

    /// A pasted screenshot is ~200 KB; a phone attachment is capped at
    /// `SessionInput.maxAttachmentBytes`. 5 MiB covers both.
    static let maxImageBytes = 5 * 1024 * 1024

    /// `POST /sessions/<pid>/input` — a message, a resume, or a key.
    /// Delivery is the named pipe only.
    static func input(pid: Int32, request: MirrorTransport.Request, claudeDir: URL,
                      log: @escaping @Sendable (String) -> Void) -> Data {
        guard let decoded = try? JSONDecoder().decode(SessionInput.Request.self, from: request.body)
        else {
            return MirrorTransport.badRequestResponse()
        }
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid })
        else {
            log("phone input not delivered: unknown session \(pid)")
            return MirrorTransport.notFoundResponse()
        }
        let reply = SessionInput.deliver(
            request: decoded, record: record,
            hosts: [],                       // no pty on Windows: pipe or nothing
            claudeDir: claudeDir,
            ttyOfPid: { _ in nil }, ancestorsOf: { _ in [] },
            socketSend: { record, text in
                NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
            })
        let label = URL(fileURLWithPath: record.cwd).lastPathComponent
        if reply.outcome == "delivered" {
            log("phone -> \(label): \"\(decoded.text.prefix(60))\" (\(reply.channel ?? "?"))")
        } else {
            log("phone input not delivered to \(label): \(reply.outcome)")
        }
        guard let encoded = try? JSONEncoder().encode(reply) else {
            return MirrorTransport.notFoundResponse()
        }
        return MirrorTransport.jsonResponse(encoded)
    }
}
