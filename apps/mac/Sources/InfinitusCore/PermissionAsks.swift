import Foundation

/// PermissionRequest asks answered from the desktop or the web (#79
/// item 3): a session opted in (`session-remote on`) has the plugin's
/// PermissionRequest hook register each ask here and park on
/// `permission-wait` until someone decides or the window closes; a
/// decision that never comes falls through to the terminal's own prompt —
/// never a silent allow. In memory only, like `ToolApprovals`.
public final class PermissionAsks: @unchecked Sendable {
    public static let window: TimeInterval = 60

    public enum Decision: String, Sendable {
        case allow, deny, ask
    }

    public struct Ask: Equatable, Sendable {
        public let id: String
        public let pid: Int?
        public let sessionId: String
        public let tool: String
        /// A bounded rendering of `tool_input` (`render`), the card's text.
        public let input: String
        public let askedAt: Date
        public let expiresAt: Date
    }

    /// The hook's payload, only what the ask needs.
    public struct Request: Equatable, Sendable {
        public let sessionId: String
        public let tool: String
        public let input: String

        public static func parse(_ json: String) -> Request? {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["hook_event_name"] as? String == "PermissionRequest",
                  let sessionId = object["session_id"] as? String,
                  let tool = object["tool_name"] as? String
            else { return nil }
            return Request(sessionId: sessionId, tool: tool, input: render(tool: tool, input: object["tool_input"]))
        }

        /// Bash shows its command, the file tools their path, anything
        /// else its keys; cut at `limit`. Bounded, not secret-free: a
        /// command can carry a token, so this reaches the card and never
        /// a log.
        public static func render(tool: String, input: Any?, limit: Int = 200) -> String {
            let fields = input as? [String: Any] ?? [:]
            let text: String
            switch tool {
            case "Bash": text = fields["command"] as? String ?? ""
            case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit": text = fields["file_path"] as? String ?? ""
            default: text = fields.keys.sorted().joined(separator: ", ")
            }
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
    }

    private struct Entry {
        var ask: Ask
        var decision: (Decision, String?)?
        var waiter: CheckedContinuation<(Decision, String?), Never>?
    }

    private let lock = NSLock()
    private var remote: Set<String> = []
    private var entries: [String: Entry] = [:]

    public init() {}

    public func setRemote(_ on: Bool, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if on { remote.insert(sessionId) } else { remote.remove(sessionId) }
    }

    public func isRemote(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return remote.contains(sessionId)
    }

    /// Registers an ask and starts its window; expiry resolves it `ask`.
    public func register(_ request: Request, pid: Int?, now: Date = Date(), window: TimeInterval = PermissionAsks.window) -> Ask {
        let ask = Ask(id: UUID().uuidString.lowercased(), pid: pid, sessionId: request.sessionId,
                      tool: request.tool, input: request.input, askedAt: now, expiresAt: now.addingTimeInterval(window))
        lock.lock()
        entries[ask.id] = Entry(ask: ask)
        lock.unlock()
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, window) * 1_000_000_000))
            self?.resolve(ask.id, .ask, message: nil)
        }
        return ask
    }

    /// The asks still open, oldest first.
    public func pending(now: Date = Date()) -> [Ask] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.decision == nil && $0.ask.expiresAt > now }
            .map(\.ask).sorted { $0.askedAt < $1.askedAt }
    }

    /// A decision from the desktop or the web: false when the ask is
    /// gone or already decided.
    @discardableResult
    public func decide(_ id: String, _ decision: Decision, message: String? = nil) -> Bool {
        resolve(id, decision, message: message)
    }

    /// The hook's park: the decision, or `ask` once the window closed or
    /// the id is unknown. Answers at once for an ask already decided.
    public func wait(_ id: String) async -> (decision: Decision, message: String?) {
        lock.lock()
        guard var entry = entries[id] else { lock.unlock(); return (.ask, nil) }
        if let decided = entry.decision {
            entries[id] = nil
            lock.unlock()
            return decided
        }
        if entry.waiter != nil { lock.unlock(); return (.ask, nil) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Decision, String?), Never>) in
            entry.waiter = continuation
            entries[id] = entry
            lock.unlock()
        }
    }

    /// The one removal both the decision and the expiry go through, so
    /// a parked hook is resumed exactly once.
    private func resolve(_ id: String, _ decision: Decision, message: String?) -> Bool {
        lock.lock()
        guard var entry = entries[id], entry.decision == nil else { lock.unlock(); return false }
        if let waiter = entry.waiter {
            entries[id] = nil
            lock.unlock()
            waiter.resume(returning: (decision, message))
            return true
        }
        entry.decision = (decision, message)
        entries[id] = entry
        lock.unlock()
        return true
    }
}
