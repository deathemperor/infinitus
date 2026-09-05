import Foundation
import InfinitusCore
import WinSDK

/// The client half of a session's messaging pipe
/// (`\\.\pipe\LOCAL\cc-msg-<hex>`, the record's `messagingSocketPath`) —
/// the Windows stand-in for `PeerSocket.write`'s AF_UNIX connect. The
/// bytes on the wire are `PeerSocket.frames`' verbatim: the auth frame
/// carrying the session's `peerToken`, then the user frame whose content
/// is the `<cross-session-message>` envelope. Claude Code's own sender is
/// on the other end of that format, so nothing here may reshape it.
enum NamedPipe {
    /// `WaitNamedPipeW(path, 0)`: a server instance exists. Never
    /// connects, never writes a byte — probing is free of side effects on
    /// the session. ERROR_PIPE_BUSY still means the server is there; its
    /// instances are merely busy.
    static func isListening(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let wide = Array(path.utf16) + [0]
        if WaitNamedPipeW(wide, 0) { return true }
        return GetLastError() == DWORD(ERROR_PIPE_BUSY)
    }

    /// Writes the whole payload to the pipe. False on any failure — a
    /// refused delivery is reported to the phone, never retried blindly.
    static func write(_ payload: Data, to path: String,
                      timeout: TimeInterval = 5) -> Bool {
        guard !path.isEmpty, !payload.isEmpty else { return false }
        let wide = Array(path.utf16) + [0]
        // One retry window: an instance may be mid-handoff (ERROR_PIPE_BUSY).
        let deadline = Date().addingTimeInterval(timeout)
        var handle = INVALID_HANDLE_VALUE
        repeat {
            handle = CreateFileW(wide, DWORD(GENERIC_WRITE), 0, nil,
                                 DWORD(OPEN_EXISTING), 0, nil)
            if handle != INVALID_HANDLE_VALUE { break }
            guard GetLastError() == DWORD(ERROR_PIPE_BUSY),
                  WaitNamedPipeW(wide, DWORD(200)) || Date() < deadline
            else { return false }
        } while Date() < deadline
        guard handle != INVALID_HANDLE_VALUE else { return false }
        defer { CloseHandle(handle) }

        var written = 0
        let ok = payload.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while written < buffer.count {
                var wrote: DWORD = 0
                guard WriteFile(handle, base.advanced(by: written),
                                DWORD(buffer.count - written), &wrote, nil),
                      wrote > 0
                else { return false }
                written += Int(wrote)
            }
            return true
        }
        guard ok else { return false }
        FlushFileBuffers(handle)
        return true
    }

    /// Delivers `text` to a session's inbox: `PeerSocket.frames` with the
    /// session's own peer token, written to its pipe. The `from` address
    /// names this daemon — Infinitus binds no inbox (a one-way nudge needs
    /// no reply), but the address must still parse or the sender renders
    /// as "an unidentified session" in the receiving transcript.
    static func send(text: String, record: ClaudeSessionRecord, claudeDir: URL,
                     timeout: TimeInterval = 5) -> Bool {
        let payload = PeerSocket.frames(
            text: text,
            token: PeerSocket.peerToken(pid: record.pid, claudeDir: claudeDir),
            from: ownAddress())
        return write(payload, to: record.messagingSocketPath, timeout: timeout)
    }

    /// This daemon's peer address, pipe-shaped so a Windows transcript's
    /// `from=` reads like every other Windows peer.
    static func ownAddress(pid: Int32 = Int32(GetCurrentProcessId())) -> String {
        PeerSocket.escapeAddress("\\\\.\\pipe\\LOCAL\\infinitus-\(pid)")
    }
}
