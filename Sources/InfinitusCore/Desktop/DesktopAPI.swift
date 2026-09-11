import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Infinitus desktop over HTTP (#822): the CLI's `environments`,
/// `projects`, `threads` and `thread …` verbs talk to the desktop app's
/// server on its published port with the bearer session the Mac app
/// keeps for them (DesktopCredential; `desktop-token` hands it over).
/// Blocking and WebSocket-free: the shell snapshot, one thread's detail,
/// the holds read and a dispatched client command are all a verb needs.
/// The transport is a closure so tests answer canned bytes on Linux too.
public struct DesktopAPI {
    public typealias Transport = (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?) throws -> (Int, Data)

    public let origin: URL
    public let token: String
    public var transport: Transport

    public init(origin: URL, token: String, transport: @escaping Transport = DesktopAPI.urlSession) {
        self.origin = origin
        self.token = token
        self.transport = transport
    }

    /// A non-2xx answer, verbatim: the desktop's status and body, never reworded.
    public struct Failure: Error, CustomStringConvertible {
        public let status: Int
        public let body: String
        public var unauthorized: Bool { status == 401 }
        public var description: String {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Infinitus desktop answered \(status)" : "Infinitus desktop answered \(status): \(text)"
        }
    }

    // MARK: wire shapes (the fields the verbs read; the rest is ignored)

    public struct Descriptor: Decodable, Equatable {
        public var environmentId: String
        public var label: String
        public var platform: String?
        public var serverVersion: String?
    }
    public struct Project: Decodable, Equatable {
        public var id: String
        public var title: String
        public var workspaceRoot: String
        public var defaultModelSelection: JSONValue?
    }
    public struct Turn: Decodable, Equatable {
        public var turnId: String
        public var state: String
        public var assistantMessageId: String?
    }
    public struct Session: Decodable, Equatable {
        public var status: String
    }
    public struct ThreadShell: Decodable, Equatable {
        public var id: String
        public var projectId: String
        public var title: String
        public var latestTurn: Turn?
        public var session: Session?
        public var updatedAt: String?
        public var archivedAt: String?
        public var branch: String?
        public var worktreePath: String?
        public var runtimeMode: String?
        public var interactionMode: String?
        public var hasPendingApprovals: Bool?
        public var hasPendingUserInput: Bool?
    }
    public struct Shell: Decodable, Equatable {
        public var projects: [Project]
        public var threads: [ThreadShell]
    }
    public struct Message: Decodable, Equatable {
        public var id: String
        public var role: String
        public var text: String
        public var turnId: String?
        public var createdAt: String?
    }
    public struct Thread: Decodable, Equatable {
        public var id: String
        public var projectId: String
        public var title: String
        public var latestTurn: Turn?
        public var session: Session?
        public var runtimeMode: String?
        public var interactionMode: String?
        public var messages: [Message]
    }
    public struct Hold: Decodable, Equatable {
        public var threadId: String
        public var since: String?
        public var summary: String?
        public var kind: String?
    }
    public struct Release: Decodable, Equatable {
        public var released: Bool
        public var reason: String?
    }

    // MARK: reads

    /// `GET /.well-known/t3/environment`: the one environment the CLI knows.
    public func descriptor() throws -> Descriptor { try decode(get("/.well-known/t3/environment")) }
    /// `GET /api/orchestration/shell`: projects and threads without their messages.
    public func shell() throws -> Shell { try decode(get("/api/orchestration/shell")) }
    /// `GET /api/orchestration/threads/:id?turnLimit=n`: one thread with its last `turnLimit` turns of messages.
    public func thread(_ id: String, turnLimit: Int) throws -> Thread {
        try decode(get("/api/orchestration/threads/\(Self.segment(id))?turnLimit=\(max(1, turnLimit))"))
    }
    /// `GET /api/infinitus/holds`: the threads the desktop holds (#616); a desktop without the route holds nothing.
    public func holds() throws -> [Hold] {
        do { return try decode(get("/api/infinitus/holds")) } catch let failure as Failure where failure.status == 404 { return [] }
    }
    /// `GET /api/auth/session`: does the desktop still accept the token?
    /// The route answers everyone (`{authenticated}`), so a revoked
    /// session reads as `false` there, not as a 401.
    public func sessionAccepted() throws -> Bool {
        do {
            let state = try decode(get("/api/auth/session")) as [String: JSONValue]
            return state["authenticated"] == .bool(true)
        } catch let failure as Failure where failure.unauthorized { return false }
    }

    // MARK: writes

    /// `POST /api/orchestration/dispatch`: one client command; the desktop's sequence number back.
    @discardableResult
    public func dispatch(_ command: JSONValue) throws -> Int {
        let reply = try decode(post("/api/orchestration/dispatch", body: command)) as [String: JSONValue]
        if case .number(let n)? = reply["sequence"] { return Int(n) }
        return 0
    }
    /// `POST /api/infinitus/release-thread`: Run now for a held thread (#616).
    public func releaseThread(_ id: String) throws -> Release {
        try decode(post("/api/infinitus/release-thread", body: .object(["threadId": .string(id)])))
    }

    // MARK: plumbing

    private func get(_ path: String) throws -> Data { try send("GET", path, body: nil) }
    private func post(_ path: String, body: JSONValue) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try send("POST", path, body: enc.encode(body))
    }
    private func send(_ method: String, _ path: String, body: Data?) throws -> Data {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw Failure(status: 0, body: "bad path \(path)") }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let (status, data) = try transport(method, url, headers, body)
        guard (200..<300).contains(status) else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw Failure(status: 0, body: "unreadable reply (\(error.localizedDescription)): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))) ?? id
    }

    /// The real transport: one URLSession exchange, awaited on a semaphore
    /// (the CLI has no reason to be async), 30 s per request.
    public static let urlSession: Transport = { method, url, headers, body in
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: (Int, Data) = (0, Data()); var failure: Error? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { box.failure = error } else { box.result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        if let failure = box.failure { throw failure }
        return box.result
    }
}
