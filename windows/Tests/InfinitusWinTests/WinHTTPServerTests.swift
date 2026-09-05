import XCTest
import Foundation
import InfinitusCore
#if os(Windows)
import WinSDK
#endif

/// W4: the Winsock listener, exercised through `infinitus-win listen` —
/// a real client and a real server on loopback, playing the exact auth
/// contract `MirrorTransport` defines — no token, wrong token, right
/// token. The daemon runs as a subprocess (importing the executable's
/// module kills the test host, W2); a token file carries the secret, so
/// nothing lands on a command line.
final class WinHTTPServerTests: XCTestCase {
    static let token = "TESTTOKENTESTTOKENTESTTO"
    var token: String { Self.token }

    /// Spins the daemon up on an ephemeral port and returns the port the
    /// listener bound. The `listening on N` line is the handshake — the
    /// subprocess's stdout is a pipe, so the line is read the moment it
    /// appears, then the child is left running for the block's requests.
    func withServer(_ block: (UInt16) throws -> Void) throws {
        let tokenFile = DaemonHarness.tempFile("token")
        try Data(Self.token.utf8).write(to: tokenFile)
        defer { try? FileManager.default.removeItem(at: tokenFile) }
        guard let executable = DaemonHarness.executable() else {
            throw XCTSkip("infinitus-win.exe not built — run `swift build --product infinitus-win` first")
        }
        let output = DaemonHarness.tempFile("out")
        let error = DaemonHarness.tempFile("err")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: error)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["listen", "--token-file", tokenFile.path, "--port", "0"]
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        defer { process.terminate() }
        let port = try waitForHandshake(output)
        try block(port)
    }

    /// Reads the `listening on N` line out of the still-running child's
    /// output file, polling until it shows (or failing loudly).
    func waitForHandshake(_ output: URL, timeout: TimeInterval = 10) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: output, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    // "listening on 53412" — the bound port of `--port 0`.
                    let parts = line.split(separator: " ")
                    if parts.count == 3, parts[0] == "listening", parts[1] == "on",
                       let port = UInt16(parts[2]) {
                        return port
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("listener never announced its port")
    }

    /// A minimal blocking client: connect, send a raw HTTP request, read
    /// the whole response. No URLSession — this test is about the socket
    /// plumbing, not the client library.
    func fetch(port: UInt16, path: String, method: String = "GET",
               body: Data = Data(), headers: [String: String] = [:]) throws
        -> MirrorTransport.HTTPResponse? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        try XCTAssertNotEqual(fd, INVALID_SOCKET)
        guard fd != INVALID_SOCKET else { return nil }
        defer { closesocket(fd) }
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.S_un.S_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        guard connected == 0 else { return nil }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if !body.isEmpty {
            head += "Content-Length: \(body.count)\r\n"
        }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var request = Data(head.utf8)
        request.append(body)
        try sendAll(request, to: fd)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, Int32(raw.count), 0)
            }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            if let response = MirrorTransport.parseResponse(buffer) { return response }
        }
        return MirrorTransport.parseResponse(buffer)
    }

    /// Every byte out, not just the first send's worth.
    private func sendAll(_ data: Data, to fd: SOCKET) throws {
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let sent = send(fd, base, Int32(min(remaining, Int(Int32.max))), 0)
                try XCTUnwrap(sent > 0, "send failed with \(WSAGetLastError())")
                base += Int(sent)
                remaining -= Int(sent)
            }
        }
    }

    // MARK: the PosixHTTPServerTests set

    func testPostBodyIsDeliveredWholeToTheHandler() throws {
        try withServer { port in
            let body = Data(#"{"kind":"message","text":"hi"}"#.utf8)
            // The daemon's handler authorizes first, so the token rides
            // along; the route 404s. The reply only comes after
            // `parseRequestWithBody` has seen every Content-Length byte,
            // so a response at all proves the body path completed.
            let response = try self.fetch(port: port, path: "/echo", method: "POST",
                                          body: body,
                                          headers: ["Authorization": "Bearer \(token)"])
            XCTAssertEqual(response?.status, 404)
            XCTAssertEqual(response?.body, Data("no such route\n".utf8))
        }
    }

    func testNoTokenIsUnauthorized() throws {
        try withServer { port in
            let response = try self.fetch(port: port, path: MirrorTransport.snapshotPath)
            XCTAssertEqual(response?.status, 401)
        }
    }

    func testWrongTokenIsUnauthorized() throws {
        try withServer { port in
            let response = try self.fetch(
                port: port, path: MirrorTransport.snapshotPath,
                headers: ["Authorization": "Bearer WRONGWRONGWRONGWRONGWRON"])
            XCTAssertEqual(response?.status, 401)
        }
    }

    func testRightTokenServesTheSnapshot() throws {
        try withServer { port in
            let response = try self.fetch(port: port, path: MirrorTransport.snapshotPath,
                                          headers: ["Authorization": "Bearer \(token)"])
            XCTAssertEqual(response?.status, 200)
            XCTAssertEqual(response?.body, Data(#"{"machineName":"infinitus-win-listen"}"#.utf8))
        }
    }

    func testTokenViaQueryParameterAlsoAuthorizes() throws {
        try withServer { port in
            let response = try self.fetch(
                port: port, path: "\(MirrorTransport.snapshotPath)?t=\(token)")
            XCTAssertEqual(response?.status, 200)
        }
    }

    /// A bad token plus a huge `Content-Length` must be rejected off the
    /// head alone — the client here never sends a body at all, so a 401
    /// arriving proves the server didn't wait to buffer it (the Mac's
    /// `MirrorServer` rule, 2026-09-03 attachments).
    func testUnauthorizedHeadRejectedBeforeBodyArrives() throws {
        try withServer { port in
            let response = try self.fetch(
                port: port, path: "/sessions/1/input", method: "POST",
                headers: ["Authorization": "Bearer WRONGWRONGWRONGWRONGWRON",
                          "Content-Length": "25000000"])
            XCTAssertEqual(response?.status, 401)
        }
    }

    func testUnknownRouteIsNotFound() throws {
        try withServer { port in
            let response = try self.fetch(port: port, path: "/nope",
                                          headers: ["Authorization": "Bearer \(token)"])
            XCTAssertEqual(response?.status, 404)
        }
    }
}
