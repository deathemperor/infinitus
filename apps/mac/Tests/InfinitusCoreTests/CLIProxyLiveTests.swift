import XCTest
@testable import InfinitusCore

/// Live smoke against a real CLIProxyAPI — skipped unless
/// INFINITUS_LIVE_PROXY_KEY is set (the dev proxy on this machine,
/// docs/research/multi-engine.md §6). Prints the mapped fleets so a
/// drift between the installed proxy and the fixtures is visible.
final class CLIProxyLiveTests: XCTestCase {
    func testLiveSnapshot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INFINITUS_LIVE_PROXY_KEY"], !key.isEmpty else {
            throw XCTSkip("INFINITUS_LIVE_PROXY_KEY not set")
        }
        let base = URL(string: env["INFINITUS_LIVE_PROXY_URL"] ?? "http://127.0.0.1:8317")!
        let engine = CLIProxyEngine(baseURL: base, managementKey: key)
        let probe = try await engine.probe()
        print("LIVE probe: \(probe)")
        let fleets = try await engine.snapshot()
        for f in fleets {
            print("LIVE fleet \(f.engineID)/\(f.provider) active=\(String(describing: f.activeNumber)) next=\(String(describing: f.nextCandidate))")
            for a in f.accounts {
                print("  #\(a.number) \(a.email) status=\(a.usageStatus) disabled=\(String(describing: a.disabled)) usage=\(a.usage.map { "5h \($0.fiveHour?.pct ?? -1) 7d \($0.sevenDay?.pct ?? -1)" } ?? "nil") plan=\(a.plan ?? "-") org=\(a.organizationName)")
            }
        }
        XCTAssertFalse(fleets.isEmpty)
        // Raw relay for the first credential: what did Anthropic answer?
        let (_, data) = try await engine.rawGet("auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        if let first = files.first {
            let env = try await engine.apiCall(authIndex: first.authIndex ?? first.id ?? first.name,
                                               url: "https://api.anthropic.com/api/oauth/usage")
            print("LIVE api-call status=\(env.statusCode) body=\(env.body.prefix(200))")
        }
    }

    /// Reversible PATCH round-trip on credential #1: hold → restore,
    /// note → restore. Proves the body shapes the stubs assume
    /// (`{name, disabled}` / `{name, note}`) against the real proxy.
    func testLiveHoldAndNoteRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INFINITUS_LIVE_PROXY_KEY"], !key.isEmpty else {
            throw XCTSkip("INFINITUS_LIVE_PROXY_KEY not set")
        }
        let base = URL(string: env["INFINITUS_LIVE_PROXY_URL"] ?? "http://127.0.0.1:8317")!
        let engine = CLIProxyEngine(baseURL: base, managementKey: key)
        guard let fleet = try await engine.snapshot().first, !fleet.accounts.isEmpty else {
            throw XCTSkip("no credential on the live proxy")
        }
        let provider = fleet.provider
        let target = try await engine.name(provider, 1)
        func fetch() async throws -> ProxyAuthFile {
            let (_, data) = try await engine.rawGet("auth-files")
            let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
            return try XCTUnwrap(files.first { $0.name == target })
        }
        let before = try await fetch()

        try await engine.setHold(fleet: provider, number: 1, held: true)
        let held = try await fetch()
        XCTAssertEqual(held.disabled, true)
        try await engine.setHold(fleet: provider, number: 1, held: before.disabled ?? false)
        let restored = try await fetch()
        XCTAssertEqual(restored.disabled ?? false, before.disabled ?? false)

        try await engine.rename(fleet: provider, number: 1, "infinitus-smoke")
        let noted = try await fetch()
        XCTAssertEqual(noted.note, "infinitus-smoke")
        try await engine.rename(fleet: provider, number: 1, before.note ?? "")
        let cleared = try await fetch()
        XCTAssertEqual(cleared.note ?? "", before.note ?? "")
    }

    /// Reversible switch: #2 goes to the top priority tier, then its
    /// priority is put back. Proves the `{name, priority}` PATCH the
    /// stub assumes lands on the real proxy. Needs two credentials.
    /// Remove stays stub-only: DELETE is not reversible.
    func testLiveSwitchRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INFINITUS_LIVE_PROXY_KEY"], !key.isEmpty else {
            throw XCTSkip("INFINITUS_LIVE_PROXY_KEY not set")
        }
        let base = URL(string: env["INFINITUS_LIVE_PROXY_URL"] ?? "http://127.0.0.1:8317")!
        let engine = CLIProxyEngine(baseURL: base, managementKey: key)
        guard let fleet = try await engine.snapshot().first, fleet.accounts.count >= 2 else {
            throw XCTSkip("needs two credentials on the live proxy")
        }
        let provider = fleet.provider
        let target = try await engine.name(provider, 2)
        func fetchAll() async throws -> [ProxyAuthFile] {
            let (_, data) = try await engine.rawGet("auth-files")
            return try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        }
        let before = try await fetchAll()
        let mine = try XCTUnwrap(before.first { $0.name == target })
        let topBefore = before.map { $0.priority ?? 0 }.max() ?? 0

        try await engine.switchTo(fleet: provider, number: 2)
        let after = try await fetchAll()
        let switched = try XCTUnwrap(after.first { $0.name == target })
        XCTAssertEqual(switched.priority, topBefore + 1)
        XCTAssertEqual(after.map { $0.priority ?? 0 }.max(), switched.priority, "now the top tier")

        try await engine.setPriority(fleet: provider, number: 2, mine.priority ?? 0)
        let restored = try await fetchAll()
        XCTAssertEqual(restored.first { $0.name == target }?.priority ?? 0, mine.priority ?? 0)
    }

    /// Reversible strategy PUT: flip to round-robin and back.
    func testLiveRoutingStrategyRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INFINITUS_LIVE_PROXY_KEY"], !key.isEmpty else {
            throw XCTSkip("INFINITUS_LIVE_PROXY_KEY not set")
        }
        let base = URL(string: env["INFINITUS_LIVE_PROXY_URL"] ?? "http://127.0.0.1:8317")!
        let engine = CLIProxyEngine(baseURL: base, managementKey: key)
        let before = try await engine.probe().strategy ?? "fill-first"
        let other = before == "round-robin" ? "fill-first" : "round-robin"
        try await engine.setRoutingStrategy(other)
        let flipped = try await engine.probe().strategy
        XCTAssertEqual(flipped, other)
        try await engine.setRoutingStrategy(before)
        let restored = try await engine.probe().strategy
        XCTAssertEqual(restored, before)
    }
}
