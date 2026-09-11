import Foundation

// MARK: - Multicast DNS for `_infinitus._tcp` (spec §6.4, §9)
//
// RFC 6762 (mDNS) + RFC 6763 (DNS-SD), the minimum that lets a Linux box
// advertise and browse the same service the Mac advertises through
// Network.framework. The codec and the responder/collector logic are
// pure and run under `swift test` on every platform; the UDP socket at
// the bottom is fenced to macOS + Linux.

/// A DNS name as labels, so an instance label may contain dots ("Loc's
/// Mac 1.2"): the wire is length-prefixed, only the dotted text is
/// ambiguous.
public struct DNSName: Hashable, Sendable {
    public var labels: [String]

    public init(labels: [String]) { self.labels = labels }

    /// "a.b.c." split on dots (the trailing dot is optional).
    public init(dotted: String) {
        labels = dotted.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    public var dotted: String { labels.map { $0 + "." }.joined() }

    /// DNS names compare case-insensitively (RFC 6762 §16).
    public var key: String { labels.map { $0.lowercased() }.joined(separator: "\u{0}") }

    public func matches(_ other: DNSName) -> Bool { key == other.key }
}

public enum MDNS {
    public static let groupIPv4 = "224.0.0.251"
    /// Declared for a v6 socket later; v1 sends and listens on IPv4 only
    /// (the Mac's mirror listener is v4-only as well).
    public static let groupIPv6 = "ff02::fb"
    public static let port: UInt16 = 5353
    public static let serviceName = DNSName(labels: ["_infinitus", "_tcp", "local"])
    /// RFC 6762 §10: 75 minutes for PTR/TXT, 2 minutes for SRV/A.
    public static let ttlLong: UInt32 = 4500
    public static let ttlShort: UInt32 = 120

    public static let typeA: UInt16 = 1
    public static let typePTR: UInt16 = 12
    public static let typeTXT: UInt16 = 16
    public static let typeSRV: UInt16 = 33
    public static let typeANY: UInt16 = 255
    public static let classIN: UInt16 = 1
    /// Top bit of the class: cache-flush on a record, unicast-reply on a question.
    public static let classFlag: UInt16 = 0x8000
    /// QR + AA.
    public static let flagsResponse: UInt16 = 0x8400
    public static let flagsQuery: UInt16 = 0

    public struct Question: Equatable, Sendable {
        public var name: DNSName
        public var type: UInt16
        /// The raw class, QU bit included.
        public var cls: UInt16

        public init(name: DNSName, type: UInt16, cls: UInt16 = MDNS.classIN) {
            self.name = name; self.type = type; self.cls = cls
        }

        public var unicastResponse: Bool { cls & MDNS.classFlag != 0 }
    }

    public enum RData: Equatable, Sendable {
        case ptr(DNSName)
        case srv(priority: UInt16, weight: UInt16, port: UInt16, target: DNSName)
        case txt([String])
        /// Dotted quad.
        case a(String)
        case other(Data)
    }

    public struct Record: Equatable, Sendable {
        public var name: DNSName
        public var type: UInt16
        public var cacheFlush: Bool
        public var ttl: UInt32
        public var rdata: RData

        public init(name: DNSName, type: UInt16, cacheFlush: Bool, ttl: UInt32, rdata: RData) {
            self.name = name; self.type = type; self.cacheFlush = cacheFlush; self.ttl = ttl; self.rdata = rdata
        }
    }

    public struct Message: Equatable, Sendable {
        public var id: UInt16
        public var flags: UInt16
        public var questions: [Question]
        public var answers: [Record]
        public var authorities: [Record]
        public var additionals: [Record]

        public init(id: UInt16 = 0, flags: UInt16, questions: [Question] = [], answers: [Record] = [],
                    authorities: [Record] = [], additionals: [Record] = []) {
            self.id = id; self.flags = flags; self.questions = questions
            self.answers = answers; self.authorities = authorities; self.additionals = additionals
        }

        public var isResponse: Bool { flags & 0x8000 != 0 }
        public var records: [Record] { answers + authorities + additionals }

        public static func query(_ name: DNSName, type: UInt16 = MDNS.typePTR) -> Message {
            Message(flags: MDNS.flagsQuery, questions: [Question(name: name, type: type)])
        }

        public static func response(_ answers: [Record]) -> Message {
            Message(flags: MDNS.flagsResponse, answers: answers)
        }

        // MARK: encode

        public func encode() -> Data {
            var out = Data()
            out.appendUInt16(id)
            out.appendUInt16(flags)
            out.appendUInt16(UInt16(questions.count))
            out.appendUInt16(UInt16(answers.count))
            out.appendUInt16(UInt16(authorities.count))
            out.appendUInt16(UInt16(additionals.count))
            for q in questions {
                out.appendName(q.name)
                out.appendUInt16(q.type)
                out.appendUInt16(q.cls)
            }
            for r in answers + authorities + additionals { out.appendRecord(r) }
            return out
        }

        // MARK: decode

        public static func decode(_ data: Data) throws -> Message {
            var r = Reader(bytes: [UInt8](data))
            let id = try r.u16(), flags = try r.u16()
            let qd = try r.u16(), an = try r.u16(), ns = try r.u16(), ar = try r.u16()
            var m = Message(id: id, flags: flags)
            for _ in 0..<qd {
                m.questions.append(Question(name: try r.name(), type: try r.u16(), cls: try r.u16()))
            }
            for _ in 0..<an { m.answers.append(try r.record()) }
            for _ in 0..<ns { m.authorities.append(try r.record()) }
            for _ in 0..<ar { m.additionals.append(try r.record()) }
            return m
        }
    }

    public enum DecodeError: Error, Equatable { case truncated, badPointer, badLabel }

    // MARK: service

    /// One `_infinitus._tcp` instance: what a responder advertises.
    public struct Service: Equatable, Sendable {
        /// The instance label (the machine name, any characters).
        public var instance: String
        /// One label; the host is `<host>.local.`.
        public var host: String
        public var port: UInt16
        public var txt: [String]
        public var ipv4: String

        public init(instance: String, host: String, port: UInt16, txt: [String], ipv4: String) {
            self.instance = instance; self.host = host; self.port = port; self.txt = txt; self.ipv4 = ipv4
        }

        public var instanceName: DNSName { DNSName(labels: [instance] + MDNS.serviceName.labels) }
        public var hostName: DNSName { DNSName(labels: [host, "local"]) }

        /// PTR, SRV, TXT, A — the unique ones with cache-flush set (RFC 6762 §10.2).
        public func records() -> [Record] {
            [Record(name: MDNS.serviceName, type: MDNS.typePTR, cacheFlush: false, ttl: MDNS.ttlLong,
                    rdata: .ptr(instanceName)),
             Record(name: instanceName, type: MDNS.typeSRV, cacheFlush: true, ttl: MDNS.ttlShort,
                    rdata: .srv(priority: 0, weight: 0, port: port, target: hostName)),
             Record(name: instanceName, type: MDNS.typeTXT, cacheFlush: true, ttl: MDNS.ttlLong,
                    rdata: .txt(txt)),
             Record(name: hostName, type: MDNS.typeA, cacheFlush: true, ttl: MDNS.ttlShort,
                    rdata: .a(ipv4))]
        }

        public func announcement() -> Message { .response(records()) }

        /// TTL 0 on the PTR: browsers drop the instance (RFC 6762 §10.1).
        public func goodbye() -> Message {
            .response([Record(name: MDNS.serviceName, type: MDNS.typePTR, cacheFlush: false, ttl: 0,
                              rdata: .ptr(instanceName))])
        }
    }

    /// A host label out of free text: lowercase ASCII letters, digits and
    /// single hyphens (RFC 1123), "infinitus" when nothing survives.
    public static func hostLabel(_ text: String) -> String {
        var out = ""
        var lastHyphen = true
        for ch in text.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch); lastHyphen = false
            } else if !lastHyphen {
                out.append("-"); lastHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "infinitus" : String(out.prefix(63))
    }
}

// MARK: - Wire helpers

private extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xff))
    }

    mutating func appendUInt32(_ v: UInt32) {
        appendUInt16(UInt16(v >> 16)); appendUInt16(UInt16(v & 0xffff))
    }

    /// Uncompressed: our packets are small, and every decoder must follow
    /// pointers anyway (ours does, below).
    mutating func appendName(_ name: DNSName) {
        for label in name.labels {
            let bytes = Data(label.utf8).prefix(63)
            append(UInt8(bytes.count)); append(bytes)
        }
        append(0)
    }

    mutating func appendRecord(_ r: MDNS.Record) {
        appendName(r.name)
        appendUInt16(r.type)
        appendUInt16(MDNS.classIN | (r.cacheFlush ? MDNS.classFlag : 0))
        appendUInt32(r.ttl)
        var rd = Data()
        switch r.rdata {
        case .ptr(let target):
            rd.appendName(target)
        case .srv(let priority, let weight, let port, let target):
            rd.appendUInt16(priority); rd.appendUInt16(weight); rd.appendUInt16(port); rd.appendName(target)
        case .txt(let strings):
            rd = TXTRecord.pack(strings)
        case .a(let ip):
            rd = Data(ip.split(separator: ".").compactMap { UInt8($0) })
        case .other(let bytes):
            rd = bytes
        }
        appendUInt16(UInt16(rd.count))
        append(rd)
    }
}

private struct Reader {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw MDNS.DecodeError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else { throw MDNS.DecodeError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    /// RFC 1035 §4.1.4: labels ending in 0 or in a pointer (0xC0xx) to an
    /// earlier offset; pointers may chain, only backwards, so a packet
    /// can't loop us. `pos` lands after the in-line part.
    mutating func name() throws -> DNSName {
        var labels: [String] = []
        var cursor = pos
        var end: Int? = nil
        var jumps = 0
        while true {
            guard cursor < bytes.count else { throw MDNS.DecodeError.truncated }
            let len = Int(bytes[cursor])
            if len & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { throw MDNS.DecodeError.truncated }
                let target = (len & 0x3F) << 8 | Int(bytes[cursor + 1])
                guard target < cursor, jumps < 32 else { throw MDNS.DecodeError.badPointer }
                if end == nil { end = cursor + 2 }
                cursor = target
                jumps += 1
                continue
            }
            guard len & 0xC0 == 0 else { throw MDNS.DecodeError.badLabel }
            cursor += 1
            if len == 0 {
                if end == nil { end = cursor }
                break
            }
            guard cursor + len <= bytes.count else { throw MDNS.DecodeError.truncated }
            labels.append(String(decoding: bytes[cursor..<cursor + len], as: UTF8.self))
            cursor += len
        }
        pos = end ?? cursor
        return DNSName(labels: labels)
    }

    mutating func record() throws -> MDNS.Record {
        let owner = try name()
        let type = try u16(), cls = try u16(), ttl = try u32()
        let len = Int(try u16())
        guard pos + len <= bytes.count else { throw MDNS.DecodeError.truncated }
        let end = pos + len
        let rdata: MDNS.RData
        switch type {
        case MDNS.typePTR:
            rdata = .ptr(try name())
        case MDNS.typeSRV:
            rdata = .srv(priority: try u16(), weight: try u16(), port: try u16(), target: try name())
        case MDNS.typeTXT:
            rdata = .txt(TXTRecord.unpack(Data(try take(len))))
        case MDNS.typeA where len == 4:
            rdata = .a(try take(4).map { String($0) }.joined(separator: "."))
        default:
            rdata = .other(Data(try take(len)))
        }
        // A name inside rdata may end before `len` (pointers), never after.
        guard pos <= end else { throw MDNS.DecodeError.truncated }
        pos = end
        return MDNS.Record(name: owner, type: type, cacheFlush: cls & MDNS.classFlag != 0, ttl: ttl, rdata: rdata)
    }
}

// MARK: - Responder and browser logic (pure)

extension MDNS {
    public enum Responder {
        /// What to send back for `query`, nil when it asks for nothing of
        /// ours. Replies go multicast whatever the QU bit says (RFC 6762
        /// §5.4 allows it); a PTR hit returns the whole announcement so a
        /// browser resolves the peer from one packet.
        public static func answer(_ query: Message, service: Service) -> Message? {
            guard !query.isResponse else { return nil }
            var records: [Record] = []
            for q in query.questions {
                let wants: (UInt16) -> Bool = { q.type == $0 || q.type == MDNS.typeANY }
                if q.name.matches(MDNS.serviceName), wants(MDNS.typePTR) {
                    return service.announcement()
                }
                for r in service.records() where r.name.matches(q.name) && wants(r.type) && !records.contains(r) {
                    records.append(r)
                }
            }
            return records.isEmpty ? nil : .response(records)
        }
    }

    public struct Peer: Equatable, Sendable {
        public var instance: String
        /// The SRV target, dotted (`bo.local.`).
        public var host: String
        public var port: UInt16
        public var txt: [String]
        public var ipv4: String?

        public init(instance: String, host: String, port: UInt16, txt: [String], ipv4: String?) {
            self.instance = instance; self.host = host; self.port = port; self.txt = txt; self.ipv4 = ipv4
        }
    }

    /// Folds datagrams into peers: an instance is a peer once its SRV and
    /// TXT have both arrived; its address is the A record for the SRV
    /// target, else the datagram's sender. A TTL-0 PTR or SRV forgets it.
    public struct Collector: Equatable, Sendable {
        private struct SRV: Equatable, Sendable { var port: UInt16; var target: DNSName }
        private var names: [String: DNSName] = [:]
        private var srv: [String: SRV] = [:]
        private var txt: [String: [String]] = [:]
        /// host key → address
        private var addresses: [String: String] = [:]
        /// instance key → datagram sender
        private var senders: [String: String] = [:]

        public init() {}

        public mutating func ingest(_ message: Message, from sender: String?) {
            guard message.isResponse else { return }
            for r in message.records {
                switch r.rdata {
                case .ptr(let instance) where r.name.matches(MDNS.serviceName):
                    if r.ttl == 0 { forget(instance.key) }
                case .srv(_, _, let port, let target) where isOurs(r.name):
                    if r.ttl == 0 { forget(r.name.key); continue }
                    names[r.name.key] = r.name
                    srv[r.name.key] = SRV(port: port, target: target)
                    if let sender { senders[r.name.key] = sender }
                case .txt(let strings) where isOurs(r.name):
                    names[r.name.key] = r.name
                    txt[r.name.key] = strings
                    if let sender { senders[r.name.key] = sender }
                case .a(let ip):
                    addresses[r.name.key] = ip
                default:
                    break
                }
            }
        }

        /// `<instance>._infinitus._tcp.local.`
        private func isOurs(_ name: DNSName) -> Bool {
            name.labels.count == 4 && DNSName(labels: Array(name.labels.dropFirst())).matches(MDNS.serviceName)
        }

        private mutating func forget(_ key: String) {
            names[key] = nil; srv[key] = nil; txt[key] = nil; senders[key] = nil
        }

        public var peers: [Peer] {
            names.keys.sorted().compactMap { key in
                guard let name = names[key], let s = srv[key], let t = txt[key] else { return nil }
                return Peer(instance: name.labels[0], host: s.target.dotted, port: s.port, txt: t,
                            ipv4: addresses[s.target.key] ?? senders[key])
            }
        }
    }
}

// MARK: - Sockets (macOS + Linux)

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
private let datagramSocketType = SOCK_DGRAM
#else
import Glibc
private let datagramSocketType = Int32(SOCK_DGRAM.rawValue)
#endif

extension MDNS {
    public enum SocketError: Error, Equatable {
        case socket(Int32), bind(Int32), membership(Int32), send(Int32)
    }

    /// One UDP socket on 0.0.0.0:5353 in the 224.0.0.251 group. Bound with
    /// SO_REUSEADDR + SO_REUSEPORT so it sits beside mDNSResponder (macOS)
    /// or avahi (Linux), with multicast loopback on so two sockets in one
    /// process hear each other (the tests; `--discoverable` browsing itself).
    public final class Socket: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var closed = false

        public init() throws {
            let fd = socket(AF_INET, datagramSocketType, 0)
            guard fd >= 0 else { throw SocketError.socket(errno) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = MDNS.port.bigEndian
            addr.sin_addr = in_addr(s_addr: in_addr_t(0))   // INADDR_ANY
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { let e = errno; close(fd); throw SocketError.bind(e) }
            var mreq = ip_mreq()
            inet_pton(AF_INET, MDNS.groupIPv4, &mreq.imr_multiaddr)
            mreq.imr_interface = in_addr(s_addr: in_addr_t(0))
            guard setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_ADD_MEMBERSHIP), &mreq,
                             socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                let e = errno; close(fd); throw SocketError.membership(e)
            }
            var ttl: UInt8 = 255
            setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_MULTICAST_TTL), &ttl, 1)
            var loop: UInt8 = 1
            setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_MULTICAST_LOOP), &loop, 1)
            self.fd = fd
        }

        public func send(_ message: Message) throws {
            var to = sockaddr_in()
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = MDNS.port.bigEndian
            inet_pton(AF_INET, MDNS.groupIPv4, &to.sin_addr)
            let bytes = [UInt8](message.encode())
            let sent = withUnsafePointer(to: &to) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == bytes.count else { throw SocketError.send(errno) }
        }

        /// One datagram, or nil after `timeout` (or on an undecodable one).
        public func receive(timeout: TimeInterval) -> (message: Message, sender: String)? {
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, nfds_t(1), Int32(timeout * 1000)) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 9000)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard n > 0, let message = try? Message.decode(Data(buffer[0..<n])) else { return nil }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = from.sin_addr
            inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
            return (message, String(cString: text))
        }

        /// Named so the libc `close(fd)` calls in `init` stay unambiguous
        /// (a method called `close` would shadow them).
        public func tearDown() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            close(fd)
        }

        deinit { tearDown() }
    }

    /// Advertises one service: announces on start and again a second
    /// later (RFC 6762 §8.3), answers queries until `stop()`, which sends
    /// the goodbye. One thread blocked in poll(); nothing runs while the
    /// network is quiet.
    public final class Advertiser: @unchecked Sendable {
        public let service: Service
        private let socket: Socket
        private let lock = NSLock()
        private var stopping = false
        private var thread: Thread?

        public init(service: Service) throws {
            self.service = service
            self.socket = try Socket()
        }

        public func start() throws {
            try socket.send(service.announcement())
            let thread = Thread { [self] in
                var secondAnnouncement: Date? = Date().addingTimeInterval(1)
                while !isStopping {
                    if let received = socket.receive(timeout: 1),
                       let reply = Responder.answer(received.message, service: service) {
                        try? socket.send(reply)
                    }
                    if let due = secondAnnouncement, Date() >= due {
                        try? socket.send(service.announcement())
                        secondAnnouncement = nil
                    }
                }
            }
            self.thread = thread
            thread.start()
        }

        private var isStopping: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopping
        }

        public func stop() {
            lock.lock(); stopping = true; lock.unlock()
            while let t = thread, !t.isFinished { Thread.sleep(forTimeInterval: 0.05) }
            try? socket.send(service.goodbye())
            socket.tearDown()
        }
    }

    /// Sends the PTR query (again after a second) and collects answers
    /// for `seconds`. Blocking — the CLI calls it; the app never does.
    public static func browse(seconds: TimeInterval) throws -> [Peer] {
        let socket = try Socket()
        defer { socket.tearDown() }
        var collector = Collector()
        let deadline = Date().addingTimeInterval(seconds)
        var resend: Date? = Date().addingTimeInterval(1)
        try socket.send(.query(serviceName))
        while Date() < deadline {
            if let received = socket.receive(timeout: 0.25) {
                collector.ingest(received.message, from: received.sender)
            }
            if let due = resend, Date() >= due {
                try socket.send(.query(serviceName))
                resend = nil
            }
        }
        return collector.peers
    }
}
#endif
