import Foundation
import InfinitusCore
import WinSDK

/// Process-level liveness for Claude Code sessions on Windows, plus the
/// machine name the phone shows (docs/plan-windows/02-feed-readonly.md).
/// `ClaudeSessions.isAlive` answers "is there a process with this pid";
/// the FILETIME match here answers "is it still the same process" — a
/// stale record whose pid something else reused must not come back as a
/// session.
enum WinProcess {
    /// `GetComputerNameExW(ComputerNameDnsHostname)` — the DNS host name
    /// the phone shows for this host, e.g. `BM-PC`.
    static var machineName: String {
        var size: DWORD = 0
        GetComputerNameExW(ComputerNameDnsHostname, nil, &size)
        guard size > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(size))
        guard GetComputerNameExW(ComputerNameDnsHostname, &buffer, &size) else { return "" }
        return String(decoding: buffer.prefix(Int(size) - 1), as: UTF16.self)
    }

    /// The process's creation time as a FILETIME `(hi << 32) | lo` — the
    /// same decimal string a session record's `procStart` carries
    /// (confirmed equal on all live sessions, 2026-09-04).
    static func creationFiletime(pid: Int32) -> UInt64? {
        guard pid > 1,
              let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
                                       false, DWORD(UInt32(bitPattern: pid)))
        else { return nil }
        defer { CloseHandle(handle) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &created, &exited, &kernel, &user) else { return nil }
        return (UInt64(created.dwHighDateTime) << 32) | UInt64(created.dwLowDateTime)
    }

    /// Alive AND still the process the record was written for. An absent
    /// `procStart` (older builds) falls back to the pid-only check.
    static func isAlive(pid: Int32, procStart: String?) -> Bool {
        guard ClaudeSessions.isAlive(pid) else { return false }
        guard let procStart = procStart.flatMap(UInt64.init), procStart > 0 else { return true }
        return creationFiletime(pid: pid) == procStart
    }
}

/// One row of `infinitus-win sessions` — the phone-facing subset of a
/// session record plus both liveness signals.
struct WinSessionRow: Encodable {
    let pid: Int32
    let name: String?
    let kind: String
    let status: String?
    let cwd: String
    let messagingSocketPath: String
    /// Process alive and still the one the record was written for.
    let alive: Bool
    /// A server is listening on the messaging pipe (the canMessage
    /// signal — W9 feeds it to `SessionFeed.canMessage`).
    let pipe: Bool
}

/// `infinitus-win sessions`'s source: core's parse of
/// `~/.claude/sessions/<pid>.json`, then the pid-reuse guard.
enum WinSessions {
    /// Live sessions only, sorted by pid (core's order). The pipe probe is
    /// reported, never used as a filter — a `--print` session may have no
    /// pipe and still be alive.
    static func list(claudeDir: URL,
                     alive: (Int32) -> Bool = ClaudeSessions.isAlive) -> [WinSessionRow] {
        ClaudeSessions.list(claudeDir: claudeDir, alive: alive).compactMap { record in
            guard WinProcess.isAlive(pid: record.pid,
                                     procStart: procStart(claudeDir: claudeDir, pid: record.pid))
            else { return nil }
            return WinSessionRow(
                pid: record.pid, name: record.name, kind: record.kind, status: record.status,
                cwd: record.cwd, messagingSocketPath: record.messagingSocketPath,
                alive: true, pipe: NamedPipe.isListening(record.messagingSocketPath))
        }
    }

    /// The record's `procStart` — a decimal FILETIME string
    /// (`"134329680413080134"`); nil when the file is gone or the key
    /// absent. Core doesn't carry the key (its records predate it), so
    /// this is a second, tiny read per live record.
    static func procStart(claudeDir: URL, pid: Int32) -> String? {
        let url = claudeDir.appendingPathComponent("sessions")
            .appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["procStart"] as? String
    }
}
