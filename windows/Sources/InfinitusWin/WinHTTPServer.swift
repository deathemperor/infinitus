import Foundation
import InfinitusCore
import WinSDK

// MARK: - Windows phone-companion listener (W4, PosixHTTPServer parity)
//
// Network.framework doesn't exist on Windows either, so the mirror
// listener here is a Winsock HTTP/1.1 server with the same shape as
// InfinitusCore's PosixHTTPServer: one accept loop, one thread per
// connection (the tail route blocks up to 25 s in long-poll), plain
// sockets. It answers with exactly the bytes `MirrorTransport` builds
// (`snapshotResponse`, `unauthorizedResponse`, …) — the wire contract is
// shared, only the listener plumbing differs.

/// Minimal Winsock HTTP/1.1 server. The caller supplies a handler that
/// turns a parsed `MirrorTransport.Request` into the exact response bytes
/// to send — auth and routing stay in `MirrorTransport`, this file only
/// owns the socket.
public final class WinHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (MirrorTransport.Request) -> Data
    public typealias Authorizer = @Sendable (MirrorTransport.Request) -> Bool

    public enum ServerError: Error, Sendable {
        case startup, socket, setsockopt, bind, listen
    }

    private let handler: Handler
    /// Checked off the head alone, before a single body byte is read
    /// (mirrors MirrorServer.receive on the Mac, 2026-09-03 attachments):
    /// an unpaired caller must not be able to make this thread buffer up
    /// to the attachments route's 24 MiB cap. `nil` skips the check, same
    /// as on the Linux tray.
    private let authorize: Authorizer?
    private let lock = NSLock()
    private var listenSocket: SOCKET = INVALID_SOCKET
    private var stopped = false

    public init(authorize: Authorizer? = nil, handler: @escaping Handler) {
        self.authorize = authorize
        self.handler = handler
    }

    /// Binds `0.0.0.0:port` (port 0 picks an ephemeral one) and starts the
    /// accept loop on a background thread. Returns the bound port.
    @discardableResult
    public func start(port: UInt16) throws -> UInt16 {
        var initData = WSADATA()
        guard WSAStartup(0x0202, &initData) == 0 else { throw ServerError.startup }
        let fd = socket(AF_INET, Int32(SOCK_STREAM), IPPROTO_TCP.rawValue)
        guard fd != INVALID_SOCKET else { throw ServerError.socket }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                        Int32(MemoryLayout<Int32>.size)) == 0 else {
            closesocket(fd); throw ServerError.setsockopt
        }
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.S_un.S_addr = 0   // INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { closesocket(fd); throw ServerError.bind }
        guard listen(fd, 16) == 0 else { closesocket(fd); throw ServerError.listen }
        var boundAddr = sockaddr_in()
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        listenSocket = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.start()
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Closes the listener; blocked `accept()` wakes with an error and the
    /// loop exits. In-flight connection threads finish on their own.
    public func stop() {
        lock.lock(); stopped = true
        let fd = listenSocket; listenSocket = INVALID_SOCKET; lock.unlock()
        guard fd != INVALID_SOCKET else { return }
        shutdown(fd, SD_BOTH)
        closesocket(fd)
    }

    private func acceptLoop(fd: SOCKET) {
        while true {
            let client = accept(fd, nil, nil)
            guard client != INVALID_SOCKET else {
                if WSAGetLastError() == WSAEINTR { continue }   // not a real error
                return   // listener closed (stop()) or a real socket error
            }
            let thread = Thread { [weak self] in self?.handle(client) }
            thread.start()
        }
    }

    private func handle(_ fd: SOCKET) {
        defer { closesocket(fd) }
        // A peer that connects and never sends anything must not park this
        // thread forever (same pattern as PeerSocket.write's send timeout).
        // Winsock's SO_RCVTIMEO is milliseconds, not POSIX's timeval.
        var timeout: DWORD = 5000
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, Int32(MemoryLayout<DWORD>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        // The route decides the body cap (24 MiB for POST
        // /sessions/*/input's attachments, 16 KiB for everything else —
        // same split as the Mac's MirrorServer); head allowance on top,
        // same as before.
        var bodyCap = MirrorTransport.defaultBodyCap
        var readCap = bodyCap + 4096
        while buffer.count < readCap {
            let n = chunk.withUnsafeMutableBytes { raw -> Int32 in
                recv(fd, raw.baseAddress, Int32(raw.count), 0)
            }
            guard n > 0 else { return }   // closed, timed out, or errored
            buffer.append(contentsOf: chunk[0..<Int(n)])
            if let head = MirrorTransport.parseRequest(buffer) {
                bodyCap = MirrorTransport.bodyCap(method: head.method, path: head.path)
                readCap = bodyCap + 4096
                if let authorize, !authorize(head) {
                    writeAll(MirrorTransport.unauthorizedResponse(), to: fd)
                    return
                }
            }
            if let request = MirrorTransport.parseRequestWithBody(buffer, bodyCap: bodyCap) {
                writeAll(handler(request), to: fd)
                return
            }
        }
        // A head (plus, when Content-Length says there's one, a body)
        // that never finished arriving within the cap — nothing sane to
        // answer; let the connection drop.
    }

    private func writeAll(_ data: Data, to fd: SOCKET) {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                // No MSG_NOSIGNAL on Windows — there is no SIGPIPE to die
                // of; a hung-up peer just makes send fail with an error.
                let sent = send(fd, base, Int32(min(remaining, Int(Int32.max))), 0)
                guard sent > 0 else { return }
                base += Int(sent)
                remaining -= Int(sent)
            }
        }
    }
}
