#if canImport(Glibc)
import Foundation
import Glibc

// MARK: - Linux control socket (#486 slice 3)
//
// The Mac binds its control socket through NWListener (`ControlServer`);
// there is no Network.framework on Linux, so the tray binds a plain
// POSIX one here — same shape as `PosixHTTPServer` beside it (one accept
// loop on its own thread, one thread per connection, EINTR loops,
// MSG_NOSIGNAL writes). The wire is Core's `ControlProtocol` either way:
// one JSON request line in, one reply line out, per connection.
//
// One difference from `ControlServer` is worth having: `bind` here is
// synchronous, so the socket is chmod 0600 before anything can connect
// — the Mac needs the 0700 directory to close that window because
// NWListener binds asynchronously. This keeps the directory too.

/// A same-user UNIX socket that answers one line per connection. The
/// caller supplies the handler that turns a request line into the reply
/// line to send (`ControlDispatch.replyLine`) — this file only owns the
/// socket.
public final class PosixControlSocket: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data

    public enum ServerError: Error, Sendable {
        case socket, pathTooLong, bind, listen
    }

    /// A request line longer than this is a caller bug, not a command
    /// (the Mac's receive caps at the same 1 MiB); the connection drops.
    public static let requestCap = 1 << 20

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Binds `path` (its directory created 0700, a stale socket unlinked
    /// first — a killed tray leaves an inode nobody answers) and starts
    /// the accept loop on a background thread.
    public func start() throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        unlink(path)

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw ServerError.socket }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { close(fd); throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        guard bound == 0 else { close(fd); throw ServerError.bind }
        // Before `listen`, so no connection can land on a 0666 socket.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw ServerError.listen }
        lock.lock(); listenFD = fd; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.start()
    }

    /// Closes the listener and unlinks the path; a blocked `accept()`
    /// wakes with an error and the loop exits. In-flight connection
    /// threads finish on their own. `serve` never returns, so in practice
    /// the process exit does this — it exists for tests and for whatever
    /// gives the tray a shutdown path later.
    public func stop() {
        lock.lock(); let fd = listenFD; listenFD = -1; lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
        unlink(path)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // listener closed (stop()) or a real socket error
            }
            let thread = Thread { [weak self] in self?.handle(client) }
            thread.start()
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        // A peer that connects and sends nothing must not park this thread
        // forever (same guard as PosixHTTPServer).
        var timeout = timeval()   // field types differ across libcs
        timeout.tv_sec = 5
        timeout.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < Self.requestCap {
            if let end = buffer.firstIndex(of: 0x0A) {
                writeAll(handler(Data(buffer[buffer.startIndex..<end])), to: fd)
                return
            }
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                var got: Int
                repeat {
                    got = read(fd, raw.baseAddress, raw.count)
                } while got < 0 && errno == EINTR
                return got
            }
            guard n > 0 else { break }   // closed, timed out, or errored
            buffer.append(contentsOf: chunk[0..<n])
        }
        // A peer that closed after sending a whole line without its
        // terminator still gets an answer; a truly empty or oversized
        // request is dropped.
        if !buffer.isEmpty, buffer.count < Self.requestCap {
            writeAll(handler(buffer), to: fd)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                // MSG_NOSIGNAL, not plain write(): a CLI that hung up
                // mid-reply must not SIGPIPE the tray — Linux has no
                // per-socket SO_NOSIGPIPE the way Darwin does.
                var sent: Int
                repeat {
                    sent = send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                } while sent < 0 && errno == EINTR
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
#endif
