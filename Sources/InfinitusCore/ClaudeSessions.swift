import Foundation
#if os(Windows)
import WinSDK
#endif

/// A running Claude Code session, from `~/.claude/sessions/<pid>.json`.
/// Claude Code's own bookkeeping (the same records `claude` reads to find
/// its peers) — NOT the engine's; reading it here keeps the engine isolated.
public struct ClaudeSessionRecord: Sendable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let kind: String        // "interactive", "bg", "daemon", …
    public let status: String?     // "busy", "idle", "waiting", "shell"
    /// When `status` last changed (the record's `statusUpdatedAt`, epoch
    /// ms); nil on older builds.
    public let statusUpdatedAt: Date?
    /// When the session started (the record's `startedAt`, epoch ms);
    /// nil from records that predate it.
    public let startedAt: Date?
    /// Unix socket the session listens on for cross-session messages;
    /// empty when the record carries none (older builds, non-messaging
    /// sessions). Never derived from the pid — a stale socket file outlives
    /// the process that bound it.
    public let messagingSocketPath: String
    /// Wire-format version of that socket; 0 when absent.
    public let peerProtocol: Int
    /// The session's name (`/rename`, or Claude Code's own), when it has one.
    public let name: String?
    /// How Claude Code was entered: "cli" for a terminal, "sdk-cli" for a
    /// stream-json host such as `OwnedSessions` (#151); nil on older builds.
    public let entrypoint: String?
    /// A session another host resumes on its own limit stops: the SDK
    /// sessions the app owns (#151, OwnedSessions' resume wire) and the
    /// fork server's threads (#648) both enter as `sdk-cli`, and neither
    /// has a terminal for the nudge path to type into.
    public var resumedElsewhere: Bool { entrypoint == "sdk-cli" }

    public init(pid: Int32, sessionId: String, cwd: String, kind: String = "interactive",
                status: String? = nil, messagingSocketPath: String = "", peerProtocol: Int = 0,
                name: String? = nil, statusUpdatedAt: Date? = nil, entrypoint: String? = nil,
                startedAt: Date? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.status = status
        self.messagingSocketPath = messagingSocketPath
        self.peerProtocol = peerProtocol
        self.name = name
        self.statusUpdatedAt = statusUpdatedAt
        self.startedAt = startedAt
        self.entrypoint = entrypoint
    }

    /// The same record with another status (the owned overlay, #151).
    public func with(status: String?) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: sessionId, cwd: cwd, kind: kind, status: status,
                            messagingSocketPath: messagingSocketPath, peerProtocol: peerProtocol,
                            name: name, statusUpdatedAt: statusUpdatedAt, entrypoint: entrypoint, startedAt: startedAt)
    }
}

public enum ClaudeSessions {
    /// True when the NSNumber is really a JSON boolean. Darwin exposes the
    /// CFBoolean singletons; corelibs-foundation has neither — there the
    /// objCType "c" (Int8/bool storage) is the tell.
    static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return n === kCFBooleanTrue || n === kCFBooleanFalse
        #else
        return String(cString: n.objCType) == "c"
        #endif
    }

    /// Claude Code's config home — `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
    public static func configHome(home: String = NSHomeDirectory(),
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL(fileURLWithPath: "\(home)/.claude")
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
#if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return false }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        return GetExitCodeProcess(handle, &code) && code == 259   // STILL_ACTIVE
#else
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // exists, just not ours
#endif
    }

    /// The session a request names: by id when it carries one (#391 — a
    /// pid reused after a resume belongs to a different session), else
    /// by pid.
    public static func record(pid: Int32, sessionId: String?, in records: [ClaudeSessionRecord]) -> ClaudeSessionRecord? {
        sessionId.flatMap { id in records.first { $0.sessionId == id } } ?? records.first { $0.pid == pid }
    }

    /// Live sessions. A record that cannot be read is skipped — one bad
    /// file must not take out the listing.
    public static func list(claudeDir: URL, alive: (Int32) -> Bool = isAlive) -> [ClaudeSessionRecord] {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [ClaudeSessionRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNumber = obj["pid"] as? NSNumber, !isBool(pidNumber)
            else { continue }
            let pid = pidNumber.int32Value
            guard alive(pid) else { continue }
            let proto = obj["peerProtocol"] as? NSNumber
            out.append(ClaudeSessionRecord(
                pid: pid,
                sessionId: obj["sessionId"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                kind: obj["kind"] as? String ?? "",
                status: obj["status"] as? String,
                messagingSocketPath: obj["messagingSocketPath"] as? String ?? "",
                peerProtocol: proto.map { isBool($0) ? 0 : $0.intValue } ?? 0,
                name: (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                statusUpdatedAt: (obj["statusUpdatedAt"] as? NSNumber)
                    .flatMap { isBool($0) ? nil : Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                entrypoint: obj["entrypoint"] as? String,
                startedAt: (obj["startedAt"] as? NSNumber)
                    .flatMap { isBool($0) ? nil : Date(timeIntervalSince1970: $0.doubleValue / 1000) }))
        }
        return out.sorted { $0.pid < $1.pid }
    }
}
