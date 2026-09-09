import XCTest
@testable import InfinitusCore

final class MirrorTransportTests: XCTestCase {
    func testRequestTargetNeedsAWholeLine() {
        XCTAssertNil(MirrorTransport.requestTarget(Data("GET /snap".utf8)))
        let target = MirrorTransport.requestTarget(
            Data("GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(target?.method, "GET")
        XCTAssertEqual(target?.path, MirrorTransport.snapshotPath)
    }

    func testSnapshotResponseRoundTrips() {
        let body = Data(#"{"machineName":"Test Mac"}"#.utf8)
        let parsed = MirrorTransport.parseResponse(MirrorTransport.snapshotResponse(body))
        XCTAssertEqual(parsed, MirrorTransport.HTTPResponse(status: 200, body: body))
    }

    /// TCP hands headers and body over in arbitrary chunks: the client
    /// must keep receiving until Content-Length is satisfied.
    func testParseResponseWaitsForTheWholeBody() {
        let body = Data(repeating: 0x41, count: 300)
        let whole = MirrorTransport.snapshotResponse(body)
        XCTAssertNil(MirrorTransport.parseResponse(whole.prefix(20)))
        XCTAssertNil(MirrorTransport.parseResponse(whole.dropLast(1)))
        XCTAssertEqual(MirrorTransport.parseResponse(whole)?.body, body)
        // Trailing bytes from a pipelined peer never leak into the body.
        var extra = whole
        extra.append(Data("junk".utf8))
        XCTAssertEqual(MirrorTransport.parseResponse(extra)?.body, body)
    }

    func testParseErrorResponses() {
        XCTAssertEqual(MirrorTransport.parseResponse(
            MirrorTransport.notFoundResponse())?.status, 404)
        XCTAssertEqual(MirrorTransport.parseResponse(
            MirrorTransport.unavailableResponse())?.status, 503)
    }

    // MARK: - Pairing (#9 remote access)

    func testParseRequestNeedsTheWholeHead() {
        let head = "GET /snapshot HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ABCD\r\n"
        XCTAssertNil(MirrorTransport.parseRequest(Data(head.utf8)))
        let request = MirrorTransport.parseRequest(Data((head + "\r\n").utf8))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, MirrorTransport.snapshotPath)
        // Header names are matched lowercased.
        XCTAssertEqual(request?.headers["authorization"], "Bearer ABCD")
    }

    /// A QR-pasted URL carries the token in the query — routing must
    /// still see `/snapshot`, not `/snapshot?t=…`.
    func testPathIgnoresTheQuery() {
        let request = MirrorTransport.parseRequest(Data(
            "GET /snapshot?t=ABCD&x=1 HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(request?.path, MirrorTransport.snapshotPath)
        XCTAssertEqual(request?.query("t"), "ABCD")
        XCTAssertEqual(request?.query("x"), "1")
        XCTAssertNil(request?.query("token"))
    }

    func testAuthorizationAcceptsHeaderAndQuery() {
        func request(_ raw: String) -> MirrorTransport.Request {
            MirrorTransport.parseRequest(Data(raw.utf8))!
        }
        let token = "ABCD2345EFGH6789JKLM"
        let header = request("GET /snapshot HTTP/1.1\r\n"
                             + "Authorization: Bearer \(token)\r\n\r\n")
        XCTAssertTrue(MirrorTransport.isAuthorized(header, token: token))
        // `bearer` in any case, and a token typed with a stray dash.
        let sloppy = request("GET /snapshot HTTP/1.1\r\n"
                             + "authorization: bearer abcd-2345-efgh-6789-jklm\r\n\r\n")
        XCTAssertTrue(MirrorTransport.isAuthorized(sloppy, token: token))
        let query = request("GET /snapshot?t=\(token) HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(MirrorTransport.isAuthorized(query, token: token))
        let none = request("GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertFalse(MirrorTransport.isAuthorized(none, token: token))
        let wrong = request("GET /snapshot?t=NOPE HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertFalse(MirrorTransport.isAuthorized(wrong, token: token))
        // A server with no token of its own admits nobody.
        XCTAssertFalse(MirrorTransport.isAuthorized(header, token: ""))
    }

    func testUnauthorizedResponseCarriesTheChallenge() {
        let raw = MirrorTransport.unauthorizedResponse()
        XCTAssertEqual(MirrorTransport.parseResponse(raw)?.status, 401)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self)
            .contains("WWW-Authenticate: Bearer realm=\"infinitus\""))
    }

    func testParseEndpoint() {
        let host = MirrorTransport.parseEndpoint(" 192.168.1.20:8080 ")
        XCTAssertEqual(host?.host, "192.168.1.20")
        XCTAssertEqual(host?.port, 8080)
        // Bare host falls back to the advertised default port.
        XCTAssertEqual(MirrorTransport.parseEndpoint("mac.local")?.port,
                       MirrorTransport.defaultPort)
        XCTAssertEqual(MirrorTransport.parseEndpoint("[fe80::1]:47824")?.host, "fe80::1")
        XCTAssertEqual(MirrorTransport.parseEndpoint("fe80::1")?.host, "fe80::1")
        XCTAssertNil(MirrorTransport.parseEndpoint("   "))
    }

    /// A QR pasted whole: scheme, no port, maybe a path.
    func testParseEndpointUnderstandsURLs() {
        let tunnel = MirrorTransport.parseEndpoint("https://calm-fox.trycloudflare.com")
        XCTAssertEqual(tunnel?.host, "calm-fox.trycloudflare.com")
        XCTAssertEqual(tunnel?.port, 443)
        XCTAssertEqual(tunnel?.useTLS, true)
        let lan = MirrorTransport.parseEndpoint("http://192.168.1.20:47824/snapshot")
        XCTAssertEqual(lan, MirrorTransport.Endpoint(host: "192.168.1.20", port: 47824))
        // A bare host:port is still plain HTTP on the typed port.
        XCTAssertEqual(MirrorTransport.parseEndpoint("mac.local:9000")?.useTLS, false)
        XCTAssertEqual(tunnel?.urlText, "https://calm-fox.trycloudflare.com")
        XCTAssertEqual(lan?.urlText, "http://192.168.1.20:47824")
    }

    // MARK: - Session feed route (#17 layer 1)

    func testSessionTailPathRoundTrips() {
        XCTAssertEqual(MirrorTransport.sessionTailPath(pid: 123), "/sessions/123/tail")
        XCTAssertEqual(MirrorTransport.sessionTailPid("/sessions/123/tail"), 123)
        let ref = MirrorTransport.sessionImageRef(MirrorTransport.sessionImagePath(pid: 7, id: "t:ab-1:1"))
        XCTAssertEqual(ref?.pid, 7)
        XCTAssertEqual(ref?.id, "t:ab-1:1")
        XCTAssertEqual(MirrorTransport.sessionImageRef("/sessions/7/images/a:x%20y.png")?.id, "a:x y.png")
        XCTAssertNil(MirrorTransport.sessionImageRef("/sessions/7/images"))
        XCTAssertNil(MirrorTransport.sessionImageRef("/sessions/7/images/"))
    }

    func testCheckpointPathsRoundTrip() {
        XCTAssertEqual(MirrorTransport.sessionCheckpointsPath(pid: 9), "/sessions/9/checkpoints")
        XCTAssertEqual(MirrorTransport.sessionCheckpointsPid("/sessions/9/checkpoints"), 9)
        XCTAssertNil(MirrorTransport.sessionCheckpointsPid("/sessions/x/checkpoints"))
        XCTAssertNil(MirrorTransport.sessionCheckpointsPid("/sessions/9/checkpoints/3"))
        let diff = MirrorTransport.sessionCheckpointRef(MirrorTransport.sessionCheckpointPath(pid: 9, n: 3, action: .diff))
        XCTAssertEqual(diff?.pid, 9)
        XCTAssertEqual(diff?.n, 3)
        XCTAssertEqual(diff?.action, .diff)
        XCTAssertEqual(MirrorTransport.sessionCheckpointRef("/sessions/9/checkpoints/3/restore")?.action, .restore)
        XCTAssertNil(MirrorTransport.sessionCheckpointRef("/sessions/9/checkpoints/3/fork"))
        XCTAssertNil(MirrorTransport.sessionCheckpointRef("/sessions/9/checkpoints/three/diff"))
    }

    func testSessionTailPidRejectsNonNumericOrWrongShape() {
        XCTAssertNil(MirrorTransport.sessionTailPid("/sessions/x/tail"))
        XCTAssertNil(MirrorTransport.sessionTailPid("/sessions/123"))
        XCTAssertNil(MirrorTransport.sessionTailPid("/sessions/123/tail/extra"))
        XCTAssertNil(MirrorTransport.sessionTailPid("/snapshot"))
    }

    // MARK: - Session input route (#17 layer 2)

    func testSessionInputPathRoundTrips() {
        XCTAssertEqual(MirrorTransport.sessionInputPath(pid: 123), "/sessions/123/input")
        XCTAssertEqual(MirrorTransport.sessionInputPid("/sessions/123/input"), 123)
        XCTAssertNil(MirrorTransport.sessionInputPid("/sessions/123/tail"))
        XCTAssertNil(MirrorTransport.sessionInputPid("/sessions/x/input"))
    }

    func testSessionAttentionPathRoundTrips() {
        XCTAssertEqual(MirrorTransport.sessionAttentionPath(pid: 123), "/sessions/123/attention")
        XCTAssertEqual(MirrorTransport.sessionAttentionPid("/sessions/123/attention"), 123)
        XCTAssertNil(MirrorTransport.sessionAttentionPid("/sessions/123/input"))
        XCTAssertNil(MirrorTransport.sessionAttentionPid("/sessions/x/attention"))
    }

    func testSessionCommandsPathRoundTrips() {
        XCTAssertEqual(MirrorTransport.sessionCommandsPath(pid: 5), "/sessions/5/commands")
        XCTAssertEqual(MirrorTransport.sessionCommandsPid("/sessions/5/commands"), 5)
        XCTAssertNil(MirrorTransport.sessionCommandsPid("/sessions/5/timeline"))
        XCTAssertNil(MirrorTransport.sessionCommandsPid("/sessions/x/commands"))
        let wire = try? JSONEncoder().encode([SlashCommand(name: "review", description: "Review a PR", source: .projectCommand)])
        let back = wire.flatMap { try? JSONDecoder().decode([SlashCommand].self, from: $0) }
        XCTAssertEqual(back, [SlashCommand(name: "review", description: "Review a PR", source: .projectCommand)])
    }

    func testSessionTimelinePathRoundTrips() {
        XCTAssertEqual(MirrorTransport.sessionTimelinePath(pid: 5), "/sessions/5/timeline")
        XCTAssertEqual(MirrorTransport.sessionTimelinePid("/sessions/5/timeline"), 5)
        XCTAssertNil(MirrorTransport.sessionTimelinePid("/sessions/5/tail"))
        XCTAssertEqual(MirrorTransport.timelineAfterQueryName, "afterSequence")
        XCTAssertEqual(MirrorTransport.timelineEpochQueryName, "epoch")
    }

    func testConflictResponseIs409JSON() {
        let body = Data(#"{"error":"waiting"}"#.utf8)
        XCTAssertEqual(MirrorTransport.parseResponse(MirrorTransport.conflictResponse(body)),
                       MirrorTransport.HTTPResponse(status: 409, body: body))
    }

    func testJsonAndBadRequestResponses() {
        let body = Data(#"{"outcome":"delivered"}"#.utf8)
        let ok = MirrorTransport.parseResponse(MirrorTransport.jsonResponse(body))
        XCTAssertEqual(ok, MirrorTransport.HTTPResponse(status: 200, body: body))
        XCTAssertEqual(MirrorTransport.parseResponse(MirrorTransport.badRequestResponse())?.status, 400)
    }

    // MARK: - Files route responses (#486: the Mac's dispatch and the Linux tray's share these)

    func testFilesListResponseMapsSuccessFailureAndNilPid() {
        let listing = T3ProjectFiles.Listing(cwd: "/repo", entries: [], truncated: false)
        let ok = MirrorTransport.parseResponse(MirrorTransport.filesListResponse(.success(listing)))
        XCTAssertEqual(ok?.status, 200)
        XCTAssertEqual(try? JSONDecoder().decode(T3ProjectFiles.Listing.self, from: ok?.body ?? Data()), listing)
        let failed = MirrorTransport.parseResponse(MirrorTransport.filesListResponse(.failure(.rootGone)))
        XCTAssertEqual(failed?.status, 404)
        let missing = MirrorTransport.parseResponse(MirrorTransport.filesListResponse(nil))
        XCTAssertEqual(missing?.status, 404)
    }

    func testFileReadResponseMapsSuccessFailureAndNilPid() {
        let file = T3ProjectFiles.FileRead(path: "a.swift", contents: "x", byteLength: 1, truncated: false, mime: "text/x-swift")
        let ok = MirrorTransport.parseResponse(MirrorTransport.fileReadResponse(.success(file)))
        XCTAssertEqual(ok?.status, 200)
        XCTAssertEqual(try? JSONDecoder().decode(T3ProjectFiles.FileRead.self, from: ok?.body ?? Data()), file)
        let failed = MirrorTransport.parseResponse(MirrorTransport.fileReadResponse(.failure(.binary)))
        XCTAssertEqual(failed?.status, 415)
        let missing = MirrorTransport.parseResponse(MirrorTransport.fileReadResponse(nil))
        XCTAssertEqual(missing?.status, 404)
    }

    /// #223's image contract: raw bytes under the image's own type, no JSON
    /// envelope, and 413 for one over the cap.
    func testFileAnswerResponseSendsImageBytesRawAndKeepsTextAsJSON() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let image = T3ProjectFiles.ImageRead(path: "logo.png", bytes: bytes, mime: "image/png")
        let raw = MirrorTransport.fileAnswerResponse(.success(.image(image)))
        XCTAssertEqual(MirrorTransport.parseResponse(raw)?.status, 200)
        XCTAssertEqual(MirrorTransport.parseResponse(raw)?.body, bytes)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("Content-Type: image/png\r\n"),
                      String(decoding: raw.prefix(120), as: UTF8.self))
        // A workspace file changes under its path, so nothing may be cached.
        XCTAssertFalse(String(decoding: raw.prefix(200), as: UTF8.self).contains("Cache-Control"))
        // Text is byte-for-byte the envelope the phone already parses.
        let file = T3ProjectFiles.FileRead(path: "a.swift", contents: "x", byteLength: 1,
                                           truncated: false, mime: "text/x-swift")
        XCTAssertEqual(MirrorTransport.fileAnswerResponse(.success(.text(file))),
                       MirrorTransport.fileReadResponse(.success(file)))
        let big = MirrorTransport.parseResponse(MirrorTransport.fileAnswerResponse(.failure(.tooLarge)))
        XCTAssertEqual(big?.status, 413)
        XCTAssertEqual(String(decoding: big?.body ?? Data(), as: UTF8.self), #"{"error":"file too large"}"#)
        XCTAssertEqual(MirrorTransport.parseResponse(MirrorTransport.fileAnswerResponse(nil))?.status, 404)
    }

    // MARK: - Request body parsing (#17 layer 2)

    func testParseRequestWithBodyWaitsForTheWholeBody() {
        let head = "POST /sessions/1/input HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        // Head only, body not arrived yet.
        XCTAssertNil(MirrorTransport.parseRequestWithBody(Data(head.utf8)))
        // Body arriving in pieces.
        XCTAssertNil(MirrorTransport.parseRequestWithBody(Data((head + "12345").utf8)))
        let whole = MirrorTransport.parseRequestWithBody(Data((head + "1234567890").utf8))
        XCTAssertEqual(whole?.body, Data("1234567890".utf8))
        XCTAssertEqual(whole?.method, "POST")
    }

    func testParseRequestWithBodyCompletesImmediatelyWithoutContentLength() {
        let request = MirrorTransport.parseRequestWithBody(
            Data("GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(request?.body, Data())
    }

    func testParseRequestWithBodyTruncatesPastTheCap() {
        let head = "POST /sessions/1/input HTTP/1.1\r\nContent-Length: 100\r\n\r\n"
        let payload = String(repeating: "x", count: 100)
        // With a 10-byte cap, only 10 bytes are ever awaited — the
        // truncated body is returned as complete, leaving the route's
        // JSON decode to reject it.
        let request = MirrorTransport.parseRequestWithBody(Data((head + payload).utf8), bodyCap: 10)
        XCTAssertEqual(request?.body, Data(String(repeating: "x", count: 10).utf8))
    }

    /// `POST /sessions/*/input` gets the big cap (attachments); every
    /// other route stays at the small default (2026-09-03 attachments).
    func testBodyCapIsBigOnlyForSessionInput() {
        XCTAssertEqual(MirrorTransport.bodyCap(method: "POST", path: "/sessions/7/input"),
                       MirrorTransport.sessionInputBodyCap)
        XCTAssertEqual(MirrorTransport.bodyCap(method: "GET", path: MirrorTransport.snapshotPath),
                       MirrorTransport.defaultBodyCap)
        XCTAssertEqual(MirrorTransport.bodyCap(method: "GET", path: "/sessions/7/tail"),
                       MirrorTransport.defaultBodyCap)
        // Wrong verb on the input path doesn't get the big cap either.
        XCTAssertEqual(MirrorTransport.bodyCap(method: "GET", path: "/sessions/7/input"),
                       MirrorTransport.defaultBodyCap)
    }

    /// A body bigger than the small default but within the session-input
    /// cap is honoured when the route says so.
    func testParseRequestWithBodyHonoursTheSessionInputCap() {
        let payload = String(repeating: "x", count: 20_000)
        let head = "POST /sessions/1/input HTTP/1.1\r\nContent-Length: \(payload.count)\r\n\r\n"
        let whole = Data((head + payload).utf8)
        // The default cap truncates well short of the real body.
        XCTAssertEqual(MirrorTransport.parseRequestWithBody(whole)?.body.count,
                       MirrorTransport.defaultBodyCap)
        // The session-input cap is large enough for the whole thing.
        let request = MirrorTransport.parseRequestWithBody(
            whole, bodyCap: MirrorTransport.sessionInputBodyCap)
        XCTAssertEqual(request?.body, Data(payload.utf8))
    }
}
