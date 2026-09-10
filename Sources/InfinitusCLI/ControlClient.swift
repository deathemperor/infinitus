import Foundation
import InfinitusCore

// Two libc-specific copies of one client: the Darwin socket code below
// (unchanged since it was written), and the Glibc sibling at the bottom
// of this file — Linux has a control socket since #486 slice 3, where
// `infinitus-tray serve` binds it. Windows still has none (exit 3 in
// main.swift).
#if canImport(Darwin)
/// One JSON line to the running app's control socket, one back. Shared
/// by the top-level commands (main.swift), the MCP server and the
/// `team` subcommands that defer to the app on a Mac (#354).
enum ControlClient {
    /// errno of the last failed connect — what "not running" gets to say.
    nonisolated(unsafe) static var lastConnectErrno: Int32 = 0

    /// The app re-binds its socket in ~2 ms when the path went stale
    /// (ControlServer.heal); a call landing in that gap, or on the dead
    /// inode a moment before, said "not running" (#265, an e2e flake twice
    /// in a day). `roundTripRetrying` below retries for a second.
    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard rc == 0 else { lastConnectErrno = errno; close(fd); return nil }
        lastConnectErrno = 0
        return fd
    }

    static func roundTrip(_ req: ControlRequest, path: String) -> ControlReply? {
        guard let fd = connect(path: path) else { return nil }
        defer { close(fd) }
        let out = (try? ControlCodec.encode(req)) ?? Data()
        var sent = 0
        out.withUnsafeBytes { buf in
            while sent < out.count {
                let n = write(fd, buf.baseAddress! + sent, out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if data.last == 0x0A { break }
        }
        return try? ControlCodec.decode(ControlReply.self, from: data)
    }

    /// A connect that lands while the app's listener is half re-bound gets
    /// accepted and then nothing (#265: "no reply" a second before the app
    /// logged the re-bind); the whole round trip gets the retry, not just
    /// the connect.
    static func roundTripRetrying(_ req: ControlRequest, path: String) -> ControlReply? {
        for attempt in 0..<10 {
            if let reply = roundTrip(req, path: path) { return reply }
            guard attempt < 9, lastConnectErrno == 0 || lastConnectErrno == ENOENT || lastConnectErrno == ECONNREFUSED else { return nil }
            usleep(100_000)
        }
        return nil
    }
}
#endif

#if canImport(Glibc)
import Glibc

/// The Glibc sibling of the Darwin client above — same surface
/// (`roundTrip`, `roundTripRetrying`, `lastConnectErrno`), same retry
/// rule, same one-JSON-line wire from Core's `ControlProtocol`. Only the
/// libc differs: `SOCK_STREAM` is not an Int32 here, and the reply is
/// written with `MSG_NOSIGNAL` because Linux has no per-socket
/// SO_NOSIGPIPE — a listener that hung up mid-reply must not SIGPIPE the
/// CLI out of a session's hook (#486 slice 3).
enum ControlClient {
    nonisolated(unsafe) static var lastConnectErrno: Int32 = 0

    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, len) }
        }
        guard rc == 0 else { lastConnectErrno = errno; close(fd); return nil }
        lastConnectErrno = 0
        return fd
    }

    static func roundTrip(_ req: ControlRequest, path: String) -> ControlReply? {
        guard let fd = connect(path: path) else { return nil }
        defer { close(fd) }
        let out = (try? ControlCodec.encode(req)) ?? Data()
        var sent = 0
        out.withUnsafeBytes { buf in
            while sent < out.count {
                let n = send(fd, buf.baseAddress! + sent, out.count - sent, Int32(MSG_NOSIGNAL))
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                sent += n
            }
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            data.append(chunk, count: n)
            if data.last == 0x0A { break }
        }
        return try? ControlCodec.decode(ControlReply.self, from: data)
    }

    static func roundTripRetrying(_ req: ControlRequest, path: String) -> ControlReply? {
        for attempt in 0..<10 {
            if let reply = roundTrip(req, path: path) { return reply }
            guard attempt < 9, lastConnectErrno == 0 || lastConnectErrno == ENOENT || lastConnectErrno == ECONNREFUSED else { return nil }
            usleep(100_000)
        }
        return nil
    }
}
#endif
