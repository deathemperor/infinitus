#if !os(Linux)   // shares ProxyStubProtocol (URLProtocol stubbing unverified on corelibs)
import XCTest
@testable import InfinitusCore

final class NineRouterEngineTests: XCTestCase {
    static let connections = """
    {"connections":[
      {"id":"c1","provider":"claude","authType":"oauth","name":"Claude Code","email":"one@example.com",
       "priority":2,"isActive":true,"updatedAt":"2026-09-03T01:00:00Z"},
      {"id":"c2","provider":"claude","authType":"oauth","name":"work","email":"two@example.com",
       "priority":1,"isActive":true,"updatedAt":"2026-09-03T01:00:00Z",
       "rateLimitedUntil":"2099-01-01T00:00:00Z"},
      {"id":"c3","provider":"claude","authType":"oauth","email":"three@example.com","priority":3,"isActive":false},
      {"id":"g1","provider":"gemini","authType":"oauth","email":"g@example.com","priority":1,"isActive":true},
      {"id":"k1","provider":"kiro","authType":"oauth","name":"Kiro Power","email":null,"priority":1,"isActive":true,
       "providerSpecificData":{"clientSecret":"never-decoded"}}
    ]}
    """
    static let kiroUsage = """
    {"plan":"KIRO POWER","quotas":{"credit":{"used":2500,"total":10000,"remaining":7500,"resetAt":"2026-10-01T00:00:00.000Z","unlimited":false}}}
    """
    static let usage = """
    {"plan":"Claude Code","extraUsage":null,"quotas":{
      "session (5h)":{"used":63.2,"total":100,"remaining":36.8,"remainingPercentage":36.8,"resetAt":"2026-09-03T10:00:00.000Z","unlimited":false},
      "weekly (7d)":{"used":91,"total":100,"remaining":9,"remainingPercentage":9,"resetAt":"2026-09-08T10:00:00.000Z","unlimited":false},
      "weekly opus (7d)":{"used":40,"total":100,"remaining":60,"remainingPercentage":60,"resetAt":"2026-09-08T10:00:00.000Z","unlimited":false}
    }}
    """

    private func makeEngine(password: String = "pw", usageTTL: TimeInterval = 0) -> NineRouterEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProxyStubProtocol.self]
        return NineRouterEngine(baseURL: URL(string: "http://router.test:20128")!, password: password,
                                session: URLSession(configuration: config), usageTTL: usageTTL)
    }

    /// Stateful stub: unauthorized until a login with the right password
    /// has been seen (like 9Router's dashboard guard on loopback).
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var loggedIn = false
    }

    private func route(_ gate: Gate, expiredID: String = "none") -> @Sendable (URLRequest, String) -> (Int, String) {
        { req, body in
            let path = req.url!.path
            if path == "/api/auth/login" {
                let ok = body.contains("\"password\":\"pw\"")
                gate.lock.lock(); gate.loggedIn = ok; gate.lock.unlock()
                return ok ? (200, #"{"success":true}"#) : (401, #"{"error":"Invalid password"}"#)
            }
            gate.lock.lock(); let authed = gate.loggedIn; gate.lock.unlock()
            guard authed else { return (401, #"{"error":"Unauthorized"}"#) }
            switch path {
            case "/api/providers": return (200, Self.connections)
            case "/api/usage/\(expiredID)":
                return (200, #"{"message":"Claude connected. Unable to fetch usage: OAuth token expired (401)"}"#)
            case "/api/usage/k1": return (200, Self.kiroUsage)
            case "/api/usage/g1": return (200, #"{"plan":"Gemini","quotas":{}}"#)
            case let p where p.hasPrefix("/api/usage/"): return (200, Self.usage)
            case let p where p.hasPrefix("/api/providers/"): return (200, #"{"success":true}"#)
            default: return (404, "")
            }
        }
    }

    func testSnapshotLogsInOnceAndMapsTheClaudeFleet() async throws {
        let gate = Gate()
        ProxyStubProtocol.reset(handler: route(gate))
        let engine = makeEngine()
        let fleets = try await engine.snapshot()
        XCTAssertEqual(fleets.map(\.provider), [.claude, .gemini, .kiro], "Claude first, then by name")
        let fleet = fleets[0]
        XCTAssertEqual(fleet.engineID, "9router")
        XCTAssertEqual(fleet.provider, .claude)
        // 9Router's pick order: priority 1 (c2) first, then c1, then c3.
        XCTAssertEqual(fleet.accounts.map(\.email), ["two@example.com", "one@example.com", "three@example.com"])
        // c2 is cooling down, so the first connection 9Router would try is c1.
        XCTAssertEqual(fleet.activeNumber, 2)
        XCTAssertEqual(fleet.accounts[0].usageStatus, "error")
        XCTAssertEqual(fleet.accounts[1].usage?.fiveHour?.pct, 63.2)
        XCTAssertEqual(fleet.accounts[1].usage?.sevenDay?.pct, 91)
        XCTAssertEqual(fleet.accounts[1].usage?.scoped?.first?.name, "Opus")
        XCTAssertEqual(fleet.accounts[1].alias, "Claude Code")
        XCTAssertEqual(fleet.accounts[1].plan, "Claude Code")
        XCTAssertEqual(fleet.accounts[1].usage?.fiveHour?.countdown?.isEmpty, false)
        XCTAssertEqual(fleet.accounts[2].disabled, true)
        XCTAssertEqual(fleet.accounts[2].usageStatus, "disabled")
        XCTAssertNil(fleet.accounts[2].usage, "held connections aren't polled")
        let seen = ProxyStubProtocol.seen
        XCTAssertEqual(seen.filter { $0.path == "/api/auth/login" }.count, 1, "one login after the first 401")
        XCTAssertEqual(seen.filter { $0.path.hasPrefix("/api/usage/") }.count, 4, "one usage call per enabled connection")

        // Kiro (2026-09-03): a credit pool on the row's credit gauge, in
        // credits; the plan name rides the subscription tip.
        let kiro = fleets[2]
        XCTAssertEqual(kiro.accounts.map(\.email), ["Kiro Power"])
        XCTAssertEqual(kiro.accounts[0].plan, "Kiro Power")
        XCTAssertEqual(kiro.accounts[0].usage?.spend?.used, 2500)
        XCTAssertEqual(kiro.accounts[0].usage?.spend?.limit, 10000)
        XCTAssertEqual(kiro.accounts[0].usage?.spend?.pct, 25)
        XCTAssertEqual(kiro.accounts[0].usage?.spend?.currency, "credits")
        XCTAssertNil(kiro.accounts[0].usage?.fiveHour)
        XCTAssertEqual(kiro.activeNumber, 1)
        XCTAssertNil(fleets[1].accounts[0].usage, "a provider with no quotas shows a bare row")

        // Actions address each provider's own ordinals.
        try await engine.switchTo(fleet: .kiro, number: 1)
        XCTAssertTrue(ProxyStubProtocol.seen.contains { $0.path == "/api/providers/k1" })
        do {
            try await engine.switchTo(fleet: .kiro, number: 2)
            XCTFail("no second Kiro connection")
        } catch {}
    }

    func testWrongPasswordIsUnauthorized() async {
        let gate = Gate()
        ProxyStubProtocol.reset(handler: route(gate))
        let engine = makeEngine(password: "nope")
        do {
            _ = try await engine.snapshot()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? EngineError, .unauthorized)
        }
    }

    func testExpiredTokenIsReloginAndStickyUntilUsageSucceeds() async throws {
        let gate = Gate()
        ProxyStubProtocol.reset(handler: route(gate, expiredID: "c1"))
        let engine = makeEngine()
        var fleet = try await engine.snapshot()[0]
        XCTAssertEqual(fleet.accounts[1].usageStatus, "relogin_required")
        XCTAssertNil(fleet.accounts[1].usage)
        // Next poll succeeds → back to ok.
        ProxyStubProtocol.reset(handler: route(gate))
        fleet = try await engine.snapshot()[0]
        XCTAssertEqual(fleet.accounts[1].usageStatus, "ok")
    }

    func testActionsHitTheConnectionRoutes() async throws {
        let gate = Gate()
        ProxyStubProtocol.reset(handler: route(gate))
        let engine = makeEngine()
        _ = try await engine.snapshot()
        ProxyStubProtocol.reset(handler: route(gate))
        try await engine.switchTo(fleet: .claude, number: 2)      // c1
        try await engine.setHold(fleet: .claude, number: 1, held: true)   // c2
        try await engine.remove(fleet: .claude, number: 3)        // c3
        let seen = ProxyStubProtocol.seen
        XCTAssertEqual(seen.map { "\($0.method) \($0.path)" },
                       ["PUT /api/providers/c1", "PUT /api/providers/c2", "DELETE /api/providers/c3"])
        XCTAssertTrue(seen[0].body?.contains("\"priority\":0") == true)
        XCTAssertTrue(seen[1].body?.contains("\"isActive\":false") == true)
        do {
            try await engine.switchTo(fleet: .claude, number: 9)
            XCTFail("unknown ordinal must throw")
        } catch {}
    }

    func testUsageIsCachedWithinTTL() async throws {
        let gate = Gate()
        ProxyStubProtocol.reset(handler: route(gate))
        let engine = makeEngine(usageTTL: 300)
        _ = try await engine.snapshot()
        ProxyStubProtocol.reset(handler: route(gate))
        _ = try await engine.snapshot()
        XCTAssertTrue(ProxyStubProtocol.seen.allSatisfy { !$0.path.hasPrefix("/api/usage/") })
    }

    func testUsageParseShapes() {
        if case .ok(let u, let plan) = NineRouterUsage.parse(Data(#"{"plan":"Claude Code","quotas":{}}"#.utf8)) {
            XCTAssertNil(u)
            XCTAssertEqual(plan, "Claude Code")
        } else { XCTFail("empty quotas is ok(nil)") }
        if case .unavailable(let m) = NineRouterUsage.parse(Data(#"{"message":"Claude connected. Usage API requires admin permissions."}"#.utf8)) {
            XCTAssertTrue(m.contains("admin permissions"))
        } else { XCTFail("expected unavailable") }
        if case .unavailable = NineRouterUsage.parse(Data("garbage".utf8)) {} else { XCTFail("garbage is unavailable") }
        if case .expired = NineRouterUsage.parse(Data(#"{"message":"OAuth token expired"}"#.utf8)) {} else { XCTFail("expected expired") }
        if case .ok(let u, _) = NineRouterUsage.parse(Data(Self.usage.utf8)) {
            XCTAssertEqual(u?.scoped?.map(\.name), ["Opus"])
        } else { XCTFail("expected ok") }
    }
}
#endif
