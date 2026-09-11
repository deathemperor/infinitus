#if !os(Linux)   // URLProtocol stubbing is unverified on corelibs-foundation
import XCTest
@testable import InfinitusCore

/// Records every request and answers by path — no proxy, no network.
final class ProxyStubProtocol: URLProtocol {
    struct Seen: Sendable { let method: String; let path: String; let query: String?; let auth: String?; let body: String? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, String) -> (Int, String))?
    static let lock = NSLock()

    static func reset(handler: @escaping @Sendable (URLRequest, String) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        seen = []
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        var bodyData = req.httpBody
        if bodyData == nil, let stream = req.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            bodyData = out
        }
        let bodyString = bodyData.map { String(decoding: $0, as: UTF8.self) }
        Self.lock.lock()
        Self.seen.append(Seen(method: req.httpMethod ?? "", path: req.url?.path ?? "",
                              query: req.url?.query,
                              auth: req.value(forHTTPHeaderField: "Authorization"),
                              body: bodyString))
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body) = handler?(req, bodyString ?? "") ?? (500, "")
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CLIProxyEngineTests: XCTestCase {
    static let authFiles = """
    {"files":[
      {"id":"a1","auth_index":"11","name":"one.json","provider":"claude","status":"active",
       "disabled":false,"unavailable":false,"email":"one@example.com","priority":2},
      {"id":"a2","auth_index":"12","name":"two.json","provider":"claude","status":"active",
       "disabled":false,"unavailable":false,"email":"two@example.com"}
    ]}
    """
    static let usageBody = """
    {"five_hour":{"utilization":63.2,"resets_at":"2026-09-03T10:00:00Z"},
     "seven_day":{"utilization":91,"resets_at":"2026-09-08T10:00:00Z"}}
    """

    private func envelope(_ status: Int, _ body: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["status_code": status, "header": [:], "body": body])
        return String(decoding: data, as: UTF8.self)
    }

    /// usageTTL 0 by default: the older tests count one usage call per
    /// snapshot; the cache tests opt in.
    private func makeEngine(usageTTL: TimeInterval = 0) -> CLIProxyEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProxyStubProtocol.self]
        return CLIProxyEngine(baseURL: URL(string: "http://proxy.test:8317")!,
                              managementKey: "sekret", session: URLSession(configuration: config),
                              usageTTL: usageTTL)
    }

    private func route(_ req: URLRequest, body: String, expiredIndex: String = "12") -> (Int, String) {
        let path = req.url!.path
        switch path {
        case "/v0/management/auth-files": return (200, Self.authFiles)
        case "/v0/management/routing/strategy": return (200, #"{"strategy":"fill-first"}"#)
        case "/v0/management/routing/session-affinity": return (200, #"{"enabled":true,"ttl":"1h"}"#)
        case "/v0/management/usage-queue": return (200, "[]")
        case "/v0/management/api-call":
            if body.contains("\"auth_index\":\"\(expiredIndex)\"") {
                return (200, envelope(401, #"{"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired."}}"#))
            }
            if body.contains("oauth/profile") { return (200, envelope(404, "")) }
            return (200, envelope(200, Self.usageBody))
        default: return (404, "")
        }
    }

    func testSnapshotMapsUsageAndExpiredCredential() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let engine = makeEngine()
        let fleets = try await engine.snapshot()
        XCTAssertEqual(fleets.count, 1)
        let fleet = fleets[0]
        XCTAssertEqual(fleet.engineID, "cliproxy")
        XCTAssertEqual(fleet.provider, .claude)
        XCTAssertEqual(fleet.accounts.map(\.number), [1, 2])
        XCTAssertEqual(fleet.accounts[0].email, "one@example.com")
        XCTAssertEqual(fleet.accounts[0].usage?.fiveHour?.pct, 63.2)
        XCTAssertEqual(fleet.activeNumber, 1, "priority 2 beats the default tier")
        XCTAssertEqual(fleet.accounts[1].usageStatus, "relogin_required")
        XCTAssertNil(fleet.accounts[1].usage)
        // Every management call carried the bearer key; the key never rode the URL.
        let seen = ProxyStubProtocol.seen
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0.auth == "Bearer sekret" })
        XCTAssertFalse(seen.contains { ($0.query ?? "").contains("sekret") })
        // The token placeholder is sent verbatim for the proxy to substitute.
        let apiCalls = seen.filter { $0.path.hasSuffix("/api-call") }
        XCTAssertEqual(apiCalls.filter { ($0.body ?? "").contains("oauth/usage") }.count, 2,
                       "one usage call per live claude credential")
        XCTAssertEqual(apiCalls.filter { ($0.body ?? "").contains("oauth/profile") }.count, 1,
                       "profile only for the credential whose token works")
        XCTAssertTrue(apiCalls.allSatisfy { ($0.body ?? "").contains("$TOKEN$") })
        let strategy = await engine.routingStrategy
        XCTAssertEqual(strategy, "fill-first")
        let affinity = await engine.sessionAffinity
        XCTAssertEqual(affinity, true)
    }

    func testSessionAffinityIsNilOnAProxyWithoutTheRouteAndPutsEnabled() async throws {
        ProxyStubProtocol.reset { [self] req, body in
            req.url!.path == "/v0/management/routing/session-affinity" ? (404, "") : route(req, body: body)
        }
        let engine = makeEngine()
        _ = try await engine.snapshot()
        let missing = await engine.sessionAffinity
        XCTAssertNil(missing, "a 404 leaves the knob unknown, not off")
        ProxyStubProtocol.reset { req, _ in
            req.url!.path == "/v0/management/routing/session-affinity" ? (200, #"{"status":"ok"}"#) : (404, "")
        }
        try await engine.setSessionAffinity(true)
        let put = try XCTUnwrap(ProxyStubProtocol.seen.first { $0.method == "PUT" })
        XCTAssertEqual(put.path, "/v0/management/routing/session-affinity")
        XCTAssertEqual(put.body, #"{"enabled":true}"#)
        let now = await engine.sessionAffinity
        XCTAssertEqual(now, true)
    }

    func testExpiredIsStickyThroughA429AndFailedFetchIsNotOk() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let engine = makeEngine()
        _ = try await engine.snapshot()
        // Second pass: Anthropic's usage budget is exhausted for both.
        ProxyStubProtocol.reset { [self] req, body in
            if req.url!.path.hasSuffix("/api-call") { return (200, envelope(429, "{}")) }
            return route(req, body: body)
        }
        let fleet = try await engine.snapshot()[0]
        XCTAssertEqual(fleet.accounts[1].usageStatus, "relogin_required", "401 seen earlier stays")
        XCTAssertEqual(fleet.accounts[0].usageStatus, "usage_unavailable", "429 is not a healthy row")
        XCTAssertNil(fleet.accounts[0].usage)
        XCTAssertNil(fleet.nextCandidate)
        // Third pass, usage back: the healthy row is healthy again.
        // (The 429 backoff holds the credential for 5 minutes, so this
        // pass sees no api-call for it — the row keeps usage_unavailable.)
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let again = try await engine.snapshot()[0]
        XCTAssertEqual(again.accounts[0].usageStatus, "usage_unavailable")
        XCTAssertEqual(again.accounts[1].usageStatus, "relogin_required")
    }

    func testUnauthorizedWithoutKey() async {
        ProxyStubProtocol.reset { _, _ in (401, #"{"error":"unauthorized"}"#) }
        let engine = makeEngine()
        do {
            _ = try await engine.snapshot()
            XCTFail("expected unauthorized")
        } catch let e as EngineError {
            XCTAssertEqual(e, .unauthorized)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testSwitchRaisesPriorityAboveTheTop() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let engine = makeEngine()
        _ = try await engine.snapshot()
        ProxyStubProtocol.reset { _, _ in (200, #"{"status":"ok"}"#) }
        try await engine.switchTo(fleet: .claude, number: 2)
        let patch = ProxyStubProtocol.seen.first { $0.method == "PATCH" }
        XCTAssertEqual(patch?.path, "/v0/management/auth-files/fields")
        let body = try XCTUnwrap(patch?.body)
        XCTAssertTrue(body.contains("\"name\":\"two.json\""), body)
        XCTAssertTrue(body.contains("\"priority\":3"), body)
    }

    func testHoldRenameRemoveHitTheRightRoutes() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let engine = makeEngine()
        _ = try await engine.snapshot()
        ProxyStubProtocol.reset { _, _ in (200, #"{"status":"ok"}"#) }
        try await engine.setHold(fleet: .claude, number: 1, held: true)
        try await engine.rename(fleet: .claude, number: 1, " work ")
        try await engine.remove(fleet: .claude, number: 1)
        let seen = ProxyStubProtocol.seen
        XCTAssertEqual(seen.map(\.method), ["PATCH", "PATCH", "DELETE"])
        XCTAssertEqual(seen[0].path, "/v0/management/auth-files/status")
        XCTAssertTrue(seen[0].body!.contains("\"disabled\":true"))
        XCTAssertTrue(seen[1].body!.contains("\"note\":\"work\""))
        XCTAssertEqual(seen[2].path, "/v0/management/auth-files")
        XCTAssertEqual(seen[2].query, "name=one.json")
    }

    func testUnknownOrdinalIsAnError() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1) }
        let engine = makeEngine()
        _ = try await engine.snapshot()
        do {
            try await engine.setHold(fleet: .claude, number: 9, held: true)
            XCTFail("expected an error")
        } catch let e as EngineError {
            if case .remote = e {} else { XCTFail("wrong error \(e)") }
        }
    }

    func testOAuthAddPollsUntilOk() async throws {
        nonisolated(unsafe) var polls = 0
        ProxyStubProtocol.reset { req, _ in
            switch req.url!.path {
            case "/v0/management/anthropic-auth-url":
                // The callback listener only starts under is_webui.
                XCTAssertEqual(req.url?.query, "is_webui=true")
                return (200, #"{"status":"ok","url":"https://claude.ai/oauth/authorize?x=1","state":"st8"}"#)
            case "/v0/management/get-auth-status":
                polls += 1
                return (200, polls < 2 ? #"{"status":"wait"}"# : #"{"status":"ok"}"#)
            default: return (404, "")
            }
        }
        let engine = makeEngine()
        let url = try await engine.beginOAuthAdd(fleet: .claude)
        XCTAssertEqual(url.host, "claude.ai")
        try await engine.awaitOAuthAdd()
        XCTAssertEqual(polls, 2)
        XCTAssertTrue(ProxyStubProtocol.seen.contains { ($0.query ?? "").contains("state=st8") })
    }

    func testSetRoutingStrategyPutsTheValueBody() async throws {
        ProxyStubProtocol.reset { req, _ in
            req.url!.path == "/v0/management/routing/strategy" ? (200, "{}") : (404, "")
        }
        let engine = makeEngine()
        try await engine.setRoutingStrategy("round-robin")
        let put = try XCTUnwrap(ProxyStubProtocol.seen.first { $0.method == "PUT" })
        XCTAssertEqual(put.path, "/v0/management/routing/strategy")
        XCTAssertEqual(put.body, #"{"value":"round-robin"}"#)
        let strategy = await engine.routingStrategy
        XCTAssertEqual(strategy, "round-robin")
    }

    func testCapabilitiesAreTheProxySet() {
        let engine = makeEngine()
        XCTAssertEqual(engine.capabilities, [.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer])
        XCTAssertFalse(engine.capabilities.contains(.autoSwitch))
    }

    private func usageCalls() -> Int {
        ProxyStubProtocol.seen.filter {
            $0.path.hasSuffix("/api-call") && ($0.body ?? "").contains("oauth/usage")
        }.count
    }

    func testUsageIsCachedBetweenSnapshotsWithinTTL() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1, expiredIndex: "none") }
        let engine = makeEngine(usageTTL: 300)
        _ = try await engine.snapshot()
        _ = try await engine.snapshot()
        let fleets = try await engine.snapshot()
        XCTAssertEqual(usageCalls(), 2, "two credentials, one call each across three refreshes")
        XCTAssertEqual(fleets[0].accounts[1].usage?.fiveHour?.pct, 63.2, "cached usage still shown")
        XCTAssertEqual(fleets[0].accounts[1].usageStatus, "ok")
    }

    func testSharedUsageFromAnotherEngineSkipsTheFetch() async throws {
        ProxyStubProtocol.reset { [self] in route($0, body: $1, expiredIndex: "none") }
        let engine = makeEngine(usageTTL: 300)
        let sharedBody = #"{"five_hour":{"utilization":12.5,"resets_at":"2026-09-03T10:00:00Z"}}"#
        let shared = try XCTUnwrap(OAuthUsage.parse(Data(sharedBody.utf8), now: Date()))
        // cswap already polled one@ this refresh — offered under a
        // different case to prove the match is case-insensitive.
        await engine.offerSharedUsage(["One@Example.com": SharedUsage(usage: shared, at: Date())])
        let fleets = try await engine.snapshot()
        XCTAssertEqual(usageCalls(), 1, "only two@ is fetched")
        XCTAssertEqual(fleets[0].accounts[0].usage?.fiveHour?.pct, 12.5, "one@ shows the shared usage")
        XCTAssertEqual(fleets[0].accounts[1].usage?.fiveHour?.pct, 63.2)
    }

    func testCredentialsSharingAnEmailFetchOnce() async throws {
        let twins = """
        {"files":[
          {"id":"a1","auth_index":"11","name":"one.json","provider":"claude","status":"active",
           "disabled":false,"unavailable":false,"email":"one@example.com"},
          {"id":"a3","auth_index":"13","name":"one-again.json","provider":"claude","status":"active",
           "disabled":false,"unavailable":false,"email":"one@example.com"}
        ]}
        """
        ProxyStubProtocol.reset { [self] req, body in
            req.url!.path == "/v0/management/auth-files" ? (200, twins) : route(req, body: body, expiredIndex: "none")
        }
        let engine = makeEngine(usageTTL: 300)
        let fleets = try await engine.snapshot()
        XCTAssertEqual(usageCalls(), 1, "one email, one call")
        XCTAssertEqual(fleets[0].accounts.map { $0.usage?.fiveHour?.pct }, [63.2, 63.2])
    }
}
#endif
