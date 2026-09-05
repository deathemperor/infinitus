import Foundation
#if canImport(Darwin)
import Darwin
private let sysSend = Darwin.send
private let sysSockStream = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let sysSend = Glibc.send
private let sysSockStream = Int32(SOCK_STREAM.rawValue)   // Glibc enum
#endif

/// Claude Code's cross-session inbox: newline-delimited JSON over the
/// session's Unix socket — an auth frame carrying the peer token, then a
/// user-role message whose content is a `<cross-session-message>` envelope.
/// Reverse-engineered from Claude Code's own sender (peerProtocol 1); every
/// failure returns false rather than throwing — the alternative to a failed
/// nudge is an un-resumed session, never a crashed refresh.
public enum PeerSocket {
    public static let protocolVersion = 1
    public static let messageVersion = 1
    /// Not "Infinitus": a Claude session of that name exists on this Mac,
    /// and a receiver that took the phone's message for a peer's replied
    /// to that session instead of answering in its own terminal
    /// (2026-09-04) — see `phonePreface`.
    public static let senderName = "Infinitus app"

    /// Prepended to a phone message on the socket channel. The envelope
    /// makes the text look like a peer session's message, and a receiver
    /// then "replies" with SendMessage — to a sender that has no inbox —
    /// while the user waits on the phone for an answer in the transcript.
    /// The feed strips it back off (`SessionFeedReader.presentableUser`).
    public static let phonePreface = "[Infinitus] The user sent this from their phone. Answer it here in this session, as you would a message typed at the keyboard — the phone reads your reply from this transcript. The sender is the Infinitus app, not a Claude session: it has no inbox, so do not reply with SendMessage.\n\n"

    /// The receiver's envelope parser accepts exactly this set unescaped
    /// in a `from` address; everything else is percent-encoded.
    static let addressSafe: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%:_/.\\-")

    /// This process's peer address. Infinitus binds no inbox, so no real
    /// socket exists (a one-way nudge needs no reply) — but the address must
    /// still parse or the sender renders as "an unidentified session".
    public static func ownAddress(pid: Int32 = getpid()) -> String {
        escapeAddress("/tmp/infinitus-\(pid).sock")
    }

    /// A path as a `uds:` peer address: everything outside `addressSafe`
    /// percent-encoded, so the receiver's envelope parser accepts it.
    /// (The Windows daemon addresses a named pipe the same way.)
    public static func escapeAddress(_ path: String) -> String {
        let escaped = path.map { ch -> String in
            if addressSafe.contains(ch) { return String(ch) }
            return String(ch).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
        return "uds:" + escaped
    }

    /// The envelope the inbox parses. Attribute order (`from`, `from-name`,
    /// `from-mode`) and the NEWLINES around the body are fixed by the
    /// receiver, which re-renders the parse and demands byte equality — a
    /// space instead of a newline is shown as literal text from "an
    /// unidentified session". `from-mode="bypass"` is the value that reaches
    /// a session in either permission mode (the message is a fixed,
    /// non-instructional string the user opted into sending to their own
    /// sessions).
    public static func wrapBody(_ text: String, from address: String, name: String = senderName) -> String {
        // Escape closing-tag lookalikes as Claude Code's own sender does, so
        // a body can never forge an envelope boundary.
        let safe = text.replacingOccurrences(
            of: "</(?=cross-session-message)", with: "<\\\\", options: .regularExpression)
        return "<cross-session-message from=\"\(address)\" from-name=\"\(name)\" from-mode=\"bypass\">\n"
            + safe + "\n</cross-session-message>"
    }

    /// The inbox's auth token, from the `<pid>.<hash>.key` file beside the
    /// session record (mode 0600). Found by prefix; the hash is over the
    /// socket path and never recomputed.
    public static func peerToken(pid: Int32, claudeDir: URL) -> String? {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names where name.hasPrefix("\(pid).") && name.hasSuffix(".key") {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = obj["peerToken"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// The NDJSON payload: auth frame (when a token exists) then the message.
    public static func frames(text: String, token: String?, from address: String,
                              messageId: String = UUID().uuidString.lowercased()) -> Data {
        var frames: [[String: Any]] = []
        if let token { frames.append(["type": "auth", "token": token]) }
        frames.append([
            "msgV": messageVersion,
            "msg_id": messageId,
            "type": "user",
            "from": address,
            "message": ["role": "user", "content": wrapBody(text, from: address)],
            "priority": "next",
        ])
        var out = Data()
        for frame in frames {
            if let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) {
                out.append(data)
                out.append(UInt8(ascii: "\n"))
            }
        }
        return out
    }

    /// Deliver `text` to the session's inbox. True only when the whole
    /// payload was written.
    public static func send(socketPath: String, text: String, pid: Int32, claudeDir: URL,
                            timeout: TimeInterval = 5) -> Bool {
        let payload = frames(text: text, token: peerToken(pid: pid, claudeDir: claudeDir),
                             from: ownAddress())
        return write(payload, to: socketPath, timeout: timeout)
    }

    static func write(_ payload: Data, to socketPath: String, timeout: TimeInterval) -> Bool {
        #if os(Windows)
        return false   // no AF_UNIX here; the daemon writes `frames` to the named pipe instead
        #else
        let fd = socket(AF_UNIX, sysSockStream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval()   // field types differ across libcs
        tv.tv_sec = Int(timeout)
        tv.tv_usec = numericCast(Int((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        var sent = 0
        let bytes = [UInt8](payload)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                sysSend(fd, buf.baseAddress! + sent, bytes.count - sent, 0)
            }
            guard n > 0 else { return false }
            sent += n
        }
        return true
        #endif
    }
}
