#if canImport(Glibc)
import Foundation
import Glibc

// MARK: - Linux phone-companion listener (#9 parity)
//
// Network.framework doesn't exist on Linux, so the mirror listener there
// is a small POSIX-socket HTTP/1.1 server instead: one accept loop, one
// thread per connection, plain sockets. It answers with exactly the same
// bytes `MirrorTransport` builds on the Mac (`snapshotResponse`,
// `unauthorizedResponse`, …) — the wire contract is shared, only the
// listener plumbing differs.

/// Minimal POSIX `GET /snapshot` server. The caller supplies a handler
/// that turns a parsed `MirrorTransport.Request` into the exact response
/// bytes to send — auth and routing stay in `MirrorTransport`, this file
/// only owns the socket.
public final class PosixHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (MirrorTransport.Request) -> Data
    public typealias Authorizer = @Sendable (MirrorTransport.Request) -> Bool

    public enum ServerError: Error, Sendable {
        case socket, setsockopt, bind, listen
    }

    private let handler: Handler
    /// Checked off the head alone, before a single body byte is read
    /// (mirrors MirrorServer.receive on the Mac, 2026-09-03 attachments):
    /// an unpaired caller must not be able to make this thread buffer up
    /// to the attachments route's 24 MiB cap. `nil` skips the check, same
    /// as before this existed.
    private let authorize: Authorizer?
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false

    public init(authorize: Authorizer? = nil, handler: @escaping Handler) {
        self.authorize = authorize
        self.handler = handler
    }

    /// Binds `0.0.0.0:port` (port 0 picks an ephemeral one) and starts the
    /// accept loop on a background thread. Returns the bound port.
    @discardableResult
    public func start(port: UInt16) throws -> UInt16 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw ServerError.socket }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                        socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd); throw ServerError.setsockopt
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))   // INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw ServerError.bind }
        guard listen(fd, 16) == 0 else { close(fd); throw ServerError.listen }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.start()
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Closes the listener; blocked `accept()` wakes with an error and the
    /// loop exits. In-flight connection threads finish on their own.
    public func stop() {
        lock.lock(); stopped = true; let fd = listenFD; listenFD = -1; lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }   // a child's SIGCHLD, not a real error
                return   // listener closed (stop()) or a real socket error
            }
            let thread = Thread { [weak self] in self?.handle(client) }
            thread.start()
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        // A peer that connects and never sends anything must not park this
        // thread forever (same pattern as PeerSocket.write's send timeout).
        var timeout = timeval()   // field types differ across libcs
        timeout.tv_sec = 5
        timeout.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        // The route decides the body cap (24 MiB for POST
        // /sessions/*/input's attachments, 16 KiB for everything else —
        // same split as the Mac's MirrorServer); head allowance on top,
        // same as before.
        var bodyCap = MirrorTransport.defaultBodyCap
        var readCap = bodyCap + 4096
        while buffer.count < readCap {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                var got: Int
                repeat {
                    got = read(fd, raw.baseAddress, raw.count)
                } while got < 0 && errno == EINTR
                return got
            }
            guard n > 0 else { return }   // closed, timed out, or errored
            buffer.append(contentsOf: chunk[0..<n])
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

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                // MSG_NOSIGNAL, not plain write(): a peer that hung up
                // mid-response must not SIGPIPE this process — Linux has
                // no per-socket SO_NOSIGPIPE the way Darwin does.
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

// MARK: - Interface addresses (#9 pairing, Linux side)
//
// The Mac's `LocalAddresses.ipv4()` (Sources/Infinitus/MirrorPairingCenter.swift)
// does the same getifaddrs walk; this is the Linux-tray copy so `pair`
// can offer a LAN and/or tailnet endpoint without linking AppKit.

public enum PosixInterfaceAddresses {
    /// Every up, non-loopback IPv4 address on this host, in interface order.
    public static func ipv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            // IFF_UP/IFF_LOOPBACK import as differently-sized integer
            // types across libcs — Int is the common ground.
            let flags = Int(pointer.pointee.ifa_flags)
            guard flags & Int(IFF_UP) == Int(IFF_UP), flags & Int(IFF_LOOPBACK) == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !found.contains(text) { found.append(text) }
        }
        return found
    }
}
#endif
