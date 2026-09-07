# Team session control — hostnames (PR 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A leader mints a stable Cloudflare named-tunnel hostname for a member from Settings › Team or `infinitusctl team hostname give`, seals the tunnel token to that member as a `hostname` envelope, and the member's Mac starts the tunnel on its next fetch; removal cleans the records up.

**Architecture:** One pure core file (`TeamHostnames`) holds the Cloudflare client (over the existing `TeamControl.Deliver.HTTP` closure so tests inject a fake), the per-Mac `cloudflare.json` ledger (ids only), `give` (four API calls → sealed envelope published under the leader's branch), `inbox` (the member side) and `forget` (removal). `TeamModel` wraps those in `action` calls and hands an applied hostname to `AppModel`, which stores the token and flips the existing named-tunnel settings. The CLI gets `team hostname token|give|list`; nothing in the driver changes (the hostname lane already dials `https://<endpoints.hostname>`).

**Tech Stack:** Swift 6 (InfinitusCore for macOS/Linux, Infinitus app on AppKit/SwiftUI), XCTest, Cloudflare REST API v4.

**Spec:** `docs/superpowers/specs/2026-09-07-team-session-control-design.md` §3 (envelope table, `hostname` kind), §5.1 (endpoints), §5.4 (hostnames), §7.1 (Hostnames section), §7.3 (CLI), §9 (`TeamHostnameTests`), §10 item 5.

## Global Constraints

- Everything is Swift; InfinitusCore + InfinitusCLI must compile on Linux (`#if canImport(FoundationNetworking)` for URLSession in the CLI).
- Secrets travel over stdin or the secrets store, never argv; never printed. The tunnel token rides only inside the sealed envelope and the keychain; `give`/`list` output, the pane, the event log carry the hostname only.
- Bundle id `run.infinitus`; keychain items under `Keychain.teamService` (`run.infinitus.team`) and `Keychain.tunnelService`.
- Event-log icons are SF Symbol names.
- No edits under `Sources/InfinitusUI/` or `ios/`.
- Release notes: one feature, one line, under `## Unreleased` › `### Team (preview)`; README + site updated in the same PR.
- Every commit carries `Co-Authored-By: Claude Code <noreply@anthropic.com>` (hook `tools/githooks/prepare-commit-msg`).
- Idle CPU stays ~0%: nothing here adds a timer; the inbox check rides the existing fetch loop.

## Rulings (decided here; spec silent or contradicted)

1. **Token store**: the Cloudflare API token lives in `TeamSecrets` under the name `cloudflare-api` (keychain `run.infinitus.team` / account `cloudflare-api` on the Mac, `FileSecrets` on the CLI and in `INFINITUS_TEAM_DIR` mode). Zone name and label live in the ledger. Deviation from spec §5.4's `run.infinitus.cloudflare-api` service keyed by zone: `TeamSecrets` is the only store both the CLI and the app read. Cost if wrong: a rename of one keychain item.
2. **CLI `team hostname token <zone> [--label team]`**: the zone is a positional argument, the label a flag defaulting to `team`, the token on stdin. The command verifies the token with `GET /zones?name=<zone>` and caches the account and zone ids.
3. **Hostname shape**: `<slug>.<label>.<zone>`; slug = the member's roster name lowercased, runs of non-alphanumerics → `-`, trimmed; empty → first 8 of the kid; a slug already held by another ledger record gets `-<first 4 of the kid>` appended. Label and zone are validated (`NamedTunnel.normalizeHostname`-style character set) before the first API call.
4. **Partial failure**: the ledger is written after every API step (tunnel id before configure, dns id before the token fetch) so `forget` can clean a half-minted hostname; `give` re-run for a kid with a partial record deletes it first.
5. **Leader check** on the inbox: `roster.isLeader(header.from)` on the current roster plus `TeamKinds.check` path ownership. The roster keeps no leader history, so "leader at `header.at`" cannot be enforced; noted on #220.
6. **Member idempotency**: `<teamDir>/control-hostname.json` = `TeamControl.Handled` keyed by (path, blob version); a blob is applied once. A re-give writes the same path → new version → re-applied. `from == me` is NOT filtered out (give-to-self is a spec path).
7. **Apply on the member Mac**: store the token under `Keychain.tunnelService` (account = hostname), set `mirror_named_tunnel_host`, set `mirror_named_tunnel_enabled = true`, log one event. The LAN listener is not switched on; if it is off the event says so ("turn on the LAN listener to run it"). Turning a listener on behind the user's back is the wrong outcome.
8. **Cloudflare errors**: only `errors[].message` (joined) or the HTTP status reaches the caller, through `TeamGit.masked` in the CLI and `TeamModel.mask` in the app.
9. **Removal**: `TeamModel.remove(kid:)` and CLI `team remove` call `TeamHostnames.forget` after `client.remove`: unpublish the envelope, then delete the DNS record and the tunnel when the token is present; otherwise the ledger record stays and lists as orphaned.
10. **Multi-leader gap**: the ledger is per-Mac; two leaders could both give. Phase-1 limitation, one line on #220.
11. **No e2e step**: spec §9 asks for unit tests plus the Linux compile; `tools/e2e.sh` is untouched.
12. **Delete tunnel** uses `DELETE /accounts/{a}/cfd_tunnel/{id}?cascade=true` so a still-connected tunnel is removed with its connections.

## Cloudflare API shapes (verified against developers.cloudflare.com)

| step | call | body | read |
|---|---|---|---|
| ids | `GET /zones?name=<zone>` | — | `result[0].id`, `result[0].account.id` |
| 1 | `POST /accounts/{a}/cfd_tunnel` | `{"name":"infinitus-<team>-<kid8>","config_src":"cloudflare"}` | `result.id` |
| 2 | `PUT /accounts/{a}/cfd_tunnel/{t}/configurations` | `{"config":{"ingress":[{"hostname":H,"service":"http://localhost:47824"},{"service":"http_status:404"}]}}` | 2xx |
| 3 | `POST /zones/{z}/dns_records` | `{"type":"CNAME","name":H,"content":"<t>.cfargotunnel.com","proxied":true,"ttl":1}` | `result.id` |
| 4 | `GET /accounts/{a}/cfd_tunnel/{t}/token` | — | `result` (string) |
| rm | `DELETE /zones/{z}/dns_records/{d}`, `DELETE /accounts/{a}/cfd_tunnel/{t}?cascade=true` | — | 2xx |

Base `https://api.cloudflare.com/client/v4`, header `Authorization: Bearer <token>`, `Content-Type: application/json`. Every response is `{"success":bool,"errors":[{"code","message"}],"result":…}`.

## File map

- Create `Sources/InfinitusCore/Team/TeamHostnames.swift` — ledger, Cloudflare client, give / inbox / forget.
- Create `Tests/InfinitusCoreTests/TeamHostnameTests.swift`.
- Modify `Sources/Infinitus/TeamModel.swift` — ledger state, token save/forget, give, delete orphan, inbox on load, removal cleanup, `onHostname`.
- Modify `Sources/Infinitus/AppModel.swift` — `onHostname` → keychain + settings + event.
- Modify `Sources/Infinitus/TeamPane.swift` — leader `hostnamesSection`.
- Modify `Sources/InfinitusCLI/TeamControlCommand.swift` (`hostname` sub), `Sources/InfinitusCLI/TeamCommand.swift` (usage + `remove` cleanup).
- Modify `CHANGELOG.md`, `README.md`, `site/public/index.html`, `site/public/llms.txt`.

---

### Task 1: Core — ledger, Cloudflare client, give / inbox / forget

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamHostnames.swift`
- Test: `Tests/InfinitusCoreTests/TeamHostnameTests.swift`

**Interfaces:**
- Consumes: `TeamControl.Deliver.HTTP`, `TeamControl.Hostname`, `TeamControl.sealHostname/openHostname/hostnamePath`, `TeamControl.Handled`, `TeamKinds.hostname`, `TeamClient.publish(kind:path:plaintext:audience:now:)`, `unpublish(path:)`, `readableHeaders()`, `raw(_:)`, `roster`, `identity`, `config.id`.
- Produces:
  - `TeamHostnames.secretName = "cloudflare-api"`
  - `TeamHostnames.Ledger { zone, label, zoneID, accountID, records: [kid: Record] ; load(teamDir:) / save(teamDir:) ; orphans(roster:) }`
  - `TeamHostnames.Record { hostname, tunnelID, dnsID?, at }`
  - `TeamHostnames.Cloudflare(token:http:base:)` with `ids(zone:)`, `mint(...)`, `delete(record:ledger:)`
  - `TeamHostnames.slug(_:)`, `TeamHostnames.hostname(name:kid:label:zone:taken:)`, `TeamHostnames.validName(_:)`
  - `TeamHostnames.give(client:kid:cloudflare:ledger:now:) throws -> Record`
  - `TeamHostnames.inbox(client:handled:) throws -> (hostname: TeamControl.Hostname, from: String)?`
  - `TeamHostnames.forget(client:kid:cloudflare:ledger:) throws -> Bool` (true when Cloudflare records were deleted)
  - `TeamHostnames.HostnameError { notConfigured, badName(String), api(Int, String), unknownMember }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InfinitusCore

final class TeamHostnameTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamhostnames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A recording Cloudflare: every call appended, canned answers by (method, path suffix).
    final class Fake: @unchecked Sendable {
        var calls: [(method: String, path: String, body: [String: Any]?)] = []
        var http: TeamControl.Deliver.HTTP {
            { [self] method, url, headers, body, _ in
                XCTAssertEqual(headers["Authorization"], "Bearer cf-token")
                let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                calls.append((method, url.path + (url.query.map { "?" + $0 } ?? ""), json))
                func ok(_ result: Any) -> (Int, Data) { (200, try! JSONSerialization.data(withJSONObject: ["success": true, "errors": [], "result": result])) }
                switch (method, url.path) {
                case ("GET", "/client/v4/zones"): return ok([["id": "zone1", "account": ["id": "acct1"]]])
                case ("POST", "/client/v4/accounts/acct1/cfd_tunnel"): return ok(["id": "tun-\(calls.count)"])
                case ("PUT", _) where url.path.hasSuffix("/configurations"): return ok([:])
                case ("POST", "/client/v4/zones/zone1/dns_records"): return ok(["id": "dns-\(calls.count)"])
                case ("GET", _) where url.path.hasSuffix("/token"): return ok("tunnel-token-\(calls.count)")
                case ("DELETE", _): return ok([:])
                default: return (404, Data("{\"success\":false,\"errors\":[{\"code\":1,\"message\":\"no route\"}]}".utf8))
                }
            }
        }
    }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }
    func machine(_ name: String) -> (TeamPaths, TeamSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }
    func team() throws -> (leader: TeamClient, bob: TeamClient, dir: URL) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let bob = try TeamClient.request(code: code, name: "Bob Ó", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: bob.identity.kid, now: 1_020)
        _ = try bob.fetch()
        return (leader, bob, lp.teamDir(leader.config.id))
    }

    func testSlugAndHostname() {
        XCTAssertEqual(TeamHostnames.slug("Bob Ó'Neil"), "bob-neil")
        XCTAssertEqual(TeamHostnames.slug("  --  "), "")
        XCTAssertEqual(TeamHostnames.hostname(name: "Ann", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: []), "ann.team.example.com")
        XCTAssertEqual(TeamHostnames.hostname(name: "", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: []), "abcdef01.team.example.com")
        XCTAssertEqual(TeamHostnames.hostname(name: "Ann", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: ["ann.team.example.com"]), "ann-abcd.team.example.com")
        XCTAssertTrue(TeamHostnames.validName("team"))
        XCTAssertFalse(TeamHostnames.validName("te am"))
        XCTAssertFalse(TeamHostnames.validName(""))
    }

    func testGiveMintsInOrderCachesIdsAndSealsToTheMember() throws {
        let (leader, bob, dir) = try team()
        let fake = Fake()
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        let cf = TeamHostnames.Cloudflare(token: "cf-token", http: fake.http)
        let record = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_000)
        XCTAssertEqual(record.hostname, "bob.team.example.com")
        XCTAssertEqual(fake.calls.map(\.method), ["GET", "POST", "PUT", "POST", "GET"])
        XCTAssertEqual(fake.calls[0].path, "/client/v4/zones?name=example.com")
        XCTAssertEqual(fake.calls[1].body?["name"] as? String, "infinitus-\(leader.config.id)-\(bob.identity.kid.prefix(8))")
        XCTAssertEqual(fake.calls[1].body?["config_src"] as? String, "cloudflare")
        let ingress = (fake.calls[2].body?["config"] as? [String: Any])?["ingress"] as? [[String: Any]]
        XCTAssertEqual(ingress?.first?["hostname"] as? String, "bob.team.example.com")
        XCTAssertEqual(ingress?.first?["service"] as? String, "http://localhost:47824")
        XCTAssertEqual(ingress?.last?["service"] as? String, "http_status:404")
        XCTAssertEqual(fake.calls[3].body?["content"] as? String, "\(record.tunnelID).cfargotunnel.com")
        XCTAssertEqual(fake.calls[3].body?["proxied"] as? Bool, true)
        XCTAssertEqual(ledger.zoneID, "zone1"); XCTAssertEqual(ledger.accountID, "acct1")
        XCTAssertEqual(ledger.records[bob.identity.kid]?.dnsID, record.dnsID)
        XCTAssertEqual(TeamHostnames.Ledger.load(teamDir: dir).records.count, 1, "saved after every step")

        // The member reads it once; a second pass is silent.
        _ = try bob.fetch()
        var handled = TeamControl.Handled()
        let got = try XCTUnwrap(TeamHostnames.inbox(client: bob, handled: &handled))
        XCTAssertEqual(got.hostname.hostname, "bob.team.example.com")
        XCTAssertTrue(got.hostname.token.hasPrefix("tunnel-token-"))
        XCTAssertEqual(got.from, leader.identity.kid)
        XCTAssertNil(try TeamHostnames.inbox(client: bob, handled: &handled))

        // A second give (to self) skips the zones lookup.
        fake.calls.removeAll()
        let mine = try TeamHostnames.give(client: leader, kid: leader.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_100)
        XCTAssertEqual(mine.hostname, "papaya.team.example.com")
        XCTAssertEqual(fake.calls.map(\.method), ["POST", "PUT", "POST", "GET"])
        var mineHandled = TeamControl.Handled()
        _ = try leader.fetch()
        XCTAssertEqual(try TeamHostnames.inbox(client: leader, handled: &mineHandled)?.hostname.hostname, "papaya.team.example.com", "give-to-self is read back")
    }

    func testForgetDeletesBothRecordsAndUnpublishes() throws {
        let (leader, bob, _) = try team()
        let fake = Fake()
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        let cf = TeamHostnames.Cloudflare(token: "cf-token", http: fake.http)
        let record = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_000)
        fake.calls.removeAll()
        XCTAssertTrue(try TeamHostnames.forget(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger))
        XCTAssertEqual(fake.calls.map(\.path), ["/client/v4/zones/zone1/dns_records/\(record.dnsID!)",
                                                 "/client/v4/accounts/acct1/cfd_tunnel/\(record.tunnelID)?cascade=true"])
        XCTAssertNil(ledger.records[bob.identity.kid])
        _ = try bob.fetch()
        var handled = TeamControl.Handled()
        XCTAssertNil(try TeamHostnames.inbox(client: bob, handled: &handled), "envelope gone from the store")

        // Without a token the record stays and reads as orphaned once Bob is removed.
        _ = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_200)
        XCTAssertFalse(try TeamHostnames.forget(client: leader, kid: bob.identity.kid, cloudflare: nil, ledger: &ledger))
        XCTAssertNotNil(ledger.records[bob.identity.kid])
        try leader.remove(kid: bob.identity.kid, now: 2_300)
        XCTAssertEqual(ledger.orphans(roster: leader.roster!.doc).map(\.kid), [bob.identity.kid])
    }

    func testApiErrorsCarryOnlyTheMessage() throws {
        let (leader, bob, _) = try team()
        let http: TeamControl.Deliver.HTTP = { _, _, _, _, _ in
            (403, Data("{\"success\":false,\"errors\":[{\"code\":9109,\"message\":\"Unauthorized to access requested resource\"}],\"result\":null}".utf8))
        }
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        XCTAssertThrowsError(try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: .init(token: "cf-token", http: http), ledger: &ledger, now: 1)) { error in
            guard case TeamHostnames.HostnameError.api(let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 403); XCTAssertEqual(message, "Unauthorized to access requested resource")
        }
        XCTAssertTrue(ledger.records.isEmpty, "nothing minted, nothing recorded")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TeamHostnameTests`
Expected: compile error — `TeamHostnames` undefined.

- [ ] **Step 3: Implement `TeamHostnames.swift`**

```swift
import Foundation

// #220 §5.4: a leader mints a Cloudflare named tunnel + DNS record for a
// member and seals the tunnel token to them as a `hostname` envelope.
// The API token stays in `TeamSecrets` (`secretName`); `cloudflare.json`
// under the team dir remembers ids only (zone, account, per-member
// tunnel + dns record), never a token.
public enum TeamHostnames {
    public static let secretName = "cloudflare-api"
    public static let defaultLabel = "team"
    static let mirrorPort = 47824
    static let apiBase = URL(string: "https://api.cloudflare.com/client/v4")!

    public enum HostnameError: Error, Equatable {
        case notConfigured
        case badName(String)
        case api(Int, String)
        case unknownMember
    }

    public struct Record: Codable, Equatable, Sendable {
        public var hostname: String
        public var tunnelID: String
        public var dnsID: String?
        public var at: Int
    }

    public struct Ledger: Codable, Equatable, Sendable {
        public var zone: String
        public var label: String
        public var zoneID: String?
        public var accountID: String?
        public var records: [String: Record] = [:]
        public init(zone: String, label: String = TeamHostnames.defaultLabel) { self.zone = zone; self.label = label }

        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("cloudflare.json") }
        public static func load(teamDir: URL) -> Ledger? {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        }
        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }
        public static func delete(teamDir: URL) { try? FileManager.default.removeItem(at: file(teamDir: teamDir)) }

        /// Records whose member left the roster — deletable once a token is present.
        public func orphans(roster: TeamRoster) -> [(kid: String, record: Record)] {
            records.filter { roster.keys(for: $0.key) == nil }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        }
    }

    // MARK: names

    public static func slug(_ name: String) -> String {
        var out = ""; var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) { out.unicodeScalars.append(scalar); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// A DNS label / zone: lowercase alphanumerics, `-` and `.`, non-empty.
    public static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "." }
    }

    public static func hostname(name: String, kid: String, label: String, zone: String, taken: Set<String>) -> String {
        var head = slug(name)
        if head.isEmpty { head = String(kid.prefix(8)) }
        let first = "\(head).\(label).\(zone)"
        return taken.contains(first) ? "\(head)-\(kid.prefix(4)).\(label).\(zone)" : first
    }

    // MARK: Cloudflare

    public struct Cloudflare: Sendable {
        public var token: String
        public var http: TeamControl.Deliver.HTTP
        public var base: URL
        public init(token: String, http: @escaping TeamControl.Deliver.HTTP, base: URL = TeamHostnames.apiBase) {
            self.token = token; self.http = http; self.base = base
        }

        @discardableResult
        func call(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Any? {
            let url = URL(string: base.absoluteString + path)!
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (status, reply) = try http(method, url, ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json"], data, 20)
            let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            let success = json?["success"] as? Bool ?? false
            guard (200..<300).contains(status), success else {
                let messages = (json?["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                throw HostnameError.api(status, messages.isEmpty ? "HTTP \(status)" : messages.joined(separator: "; "))
            }
            return json?["result"]
        }

        /// `GET /zones?name=` once; ids land in the ledger.
        public func ids(ledger: inout Ledger) throws -> (account: String, zone: String) {
            if let a = ledger.accountID, let z = ledger.zoneID { return (a, z) }
            let result = try call("GET", "/zones?name=\(ledger.zone)") as? [[String: Any]]
            guard let zone = result?.first, let zoneID = zone["id"] as? String,
                  let accountID = (zone["account"] as? [String: Any])?["id"] as? String else {
                throw HostnameError.api(200, "no zone named \(ledger.zone) for this token")
            }
            ledger.zoneID = zoneID; ledger.accountID = accountID
            return (accountID, zoneID)
        }

        /// The four calls of §5.4, `progress` after each so a failure leaves a cleanable record.
        func mint(team: String, kid: String, hostname: String, ledger: inout Ledger, now: Int,
                  progress: (Ledger) throws -> Void) throws -> (Record, token: String) {
            let (account, zone) = try ids(ledger: &ledger)
            try progress(ledger)
            let created = try call("POST", "/accounts/\(account)/cfd_tunnel",
                                   body: ["name": "infinitus-\(team)-\(kid.prefix(8))", "config_src": "cloudflare"]) as? [String: Any]
            guard let tunnelID = created?["id"] as? String else { throw HostnameError.api(200, "tunnel created without an id") }
            var record = Record(hostname: hostname, tunnelID: tunnelID, dnsID: nil, at: now)
            ledger.records[kid] = record; try progress(ledger)
            try call("PUT", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/configurations",
                     body: ["config": ["ingress": [["hostname": hostname, "service": "http://localhost:\(TeamHostnames.mirrorPort)"],
                                                   ["service": "http_status:404"]]]])
            let dns = try call("POST", "/zones/\(zone)/dns_records",
                               body: ["type": "CNAME", "name": hostname, "content": "\(tunnelID).cfargotunnel.com", "proxied": true, "ttl": 1]) as? [String: Any]
            guard let dnsID = dns?["id"] as? String else { throw HostnameError.api(200, "dns record created without an id") }
            record.dnsID = dnsID; ledger.records[kid] = record; try progress(ledger)
            guard let token = try call("GET", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/token") as? String, !token.isEmpty else {
                throw HostnameError.api(200, "tunnel token missing")
            }
            return (record, token)
        }

        public func delete(_ record: Record, ledger: inout Ledger) throws {
            let (account, zone) = try ids(ledger: &ledger)
            if let dnsID = record.dnsID { try call("DELETE", "/zones/\(zone)/dns_records/\(dnsID)") }
            try call("DELETE", "/accounts/\(account)/cfd_tunnel/\(record.tunnelID)?cascade=true")
        }
    }

    // MARK: give / inbox / forget

    static func storePath(_ kid: String) -> String { "control/hostnames/\(kid).json" }

    /// Mint for `kid` (a half-minted record is deleted first), seal the
    /// token to them, publish under my branch. Saves the ledger as it goes.
    public static func give(client: TeamClient, kid: String, cloudflare: Cloudflare, ledger: inout Ledger,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> Record {
        guard validName(ledger.zone), validName(ledger.label) else { throw HostnameError.badName("\(ledger.label).\(ledger.zone)") }
        guard let roster = client.roster?.doc, let keys = roster.keys(for: kid) else { throw HostnameError.unknownMember }
        let dir = client.paths.teamDir(client.config.id)
        if let stale = ledger.records[kid] {
            try cloudflare.delete(stale, ledger: &ledger)
            ledger.records[kid] = nil; try ledger.save(teamDir: dir)
        }
        let name = (roster.leaders + roster.members).first { $0.keys.kid == kid }?.name ?? ""
        let taken = Set(ledger.records.values.map(\.hostname))
        let host = hostname(name: name, kid: kid, label: ledger.label, zone: ledger.zone, taken: taken)
        let (record, token) = try cloudflare.mint(team: client.config.id, kid: kid, hostname: host, ledger: &ledger, now: now) { try $0.save(teamDir: dir) }
        let sealed = try TeamControl.sealHostname(.init(hostname: host, token: token, at: now), from: client.identity, to: keys, at: now)
        try client.publish(sealed: [.init(kind: TeamKinds.hostname, path: storePath(kid), file: sealed)])
        return record
    }

    /// The newest `hostname` envelope a current leader sealed to me that
    /// `handled` has not seen; marks it. nil = nothing new.
    public static func inbox(client: TeamClient, handled: inout TeamControl.Handled) throws -> (hostname: TeamControl.Hostname, from: String)? {
        guard let roster = client.roster?.doc else { return nil }
        let me = client.identity.kid
        let candidates = try client.readableHeaders().filter { entry, header in
            header.kind == TeamKinds.hostname && roster.isLeader(header.from)
                && entry.path == TeamControl.hostnamePath(leader: header.from, member: me) && !handled.contains(entry)
        }
        guard let (entry, header) = candidates.max(by: { $0.header.at < $1.header.at }) else { return nil }
        for (other, _) in candidates { handled.mark(other) }
        guard let file = try client.raw(entry.path) else { return nil }
        let (_, hostname) = try TeamControl.openHostname(file, as: client.identity) { roster.keys(for: $0, at: header.at) }
        return (hostname, header.from)
    }

    /// Removal cleanup: the envelope goes; the Cloudflare records go when a
    /// token is at hand (true), else the ledger record stays for the orphan list.
    public static func forget(client: TeamClient, kid: String, cloudflare: Cloudflare?, ledger: inout Ledger) throws -> Bool {
        if try client.raw("m/\(client.identity.kid)/\(storePath(kid))") != nil { try client.unpublish(path: storePath(kid)) }
        guard let record = ledger.records[kid] else { return false }
        guard let cloudflare else { return false }
        try cloudflare.delete(record, ledger: &ledger)
        ledger.records[kid] = nil
        return true
    }
}
```

Note: check `TeamClient.SealedItem`'s memberwise shape (`grep -n 'struct SealedItem' -A 6 Sources/InfinitusCore/Team/TeamClient.swift`) and `client.paths` visibility before compiling; if `paths` is private, add `public var teamDir: URL { paths.teamDir(config.id) }` to TeamClient. If `publish(sealed:)` needs a different item shape, use `publish(kind:path:plaintext:audience:now:)` with `audience: .members([kid])` — `Envelope.seal` adds the sender, so a give-to-self still seals once.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeamHostnameTests`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Team/TeamHostnames.swift Tests/InfinitusCoreTests/TeamHostnameTests.swift
git commit -m "team control: hostnames core — a leader mints a Cloudflare named tunnel + DNS record per member, seals the token to them, and cleans both up on removal (#220)"
```

---

### Task 2: CLI — `team hostname token|give|list`, removal cleanup

**Files:**
- Modify: `Sources/InfinitusCLI/TeamControlCommand.swift` (guard list, new `case "hostname"`)
- Modify: `Sources/InfinitusCLI/TeamCommand.swift` (usage lines; `case "remove"` cleanup)

**Interfaces:**
- Consumes: Task 1's `TeamHostnames` API, file-scope `controlHTTP`, `FileSecrets`, `TeamClient.open`.
- Produces: rows `{kid, name, hostname, at, orphaned}` on `list`; `{kid, hostname}` on `give`; `{zone, label, account, zoneID}` on `token`.

- [ ] **Step 1: Add `"hostname"` to the `runTeamControl` guard list and the `--label` option**

In `runTeamControl`, the sub list becomes `["grant", "revoke", "grants", "send", "approve", "mode", "tail", "acks", "hostname"]`. Options parsing already handles `--label team` (key/value).

- [ ] **Step 2: Add the case**

```swift
case "hostname":
    let verb = positional.first ?? ""
    let dir = paths.teamDir(id)
    func cloudflare() throws -> TeamHostnames.Cloudflare {
        guard let data = secrets.read(TeamHostnames.secretName), let token = String(data: data, encoding: .utf8) else {
            throw TeamHostnames.HostnameError.notConfigured
        }
        return .init(token: token, http: controlHTTP)
    }
    switch verb {
    case "token":
        guard positional.count >= 2 else { return controlFail("usage: infinitusctl team hostname token <zone> [--label team]  # API token on stdin", code: 2) }
        let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return controlFail("no token on stdin", code: 2) }
        var ledger = TeamHostnames.Ledger(zone: positional[1].lowercased(), label: (options["label"] ?? TeamHostnames.defaultLabel).lowercased())
        guard TeamHostnames.validName(ledger.zone), TeamHostnames.validName(ledger.label) else { return controlFail("zone and label are DNS labels", code: 2) }
        if let old = TeamHostnames.Ledger.load(teamDir: dir), old.zone == ledger.zone { ledger.records = old.records }
        let ids = try TeamHostnames.Cloudflare(token: token, http: controlHTTP).ids(ledger: &ledger)
        try secrets.write(TeamHostnames.secretName, Data(token.utf8))
        try ledger.save(teamDir: dir)
        emit(["zone": ledger.zone, "label": ledger.label, "account": ids.account, "zoneID": ids.zone])
    case "give":
        guard positional.count >= 2 else { return controlFail("usage: infinitusctl team hostname give <kid>", code: 2) }
        guard var ledger = TeamHostnames.Ledger.load(teamDir: dir) else { throw TeamHostnames.HostnameError.notConfigured }
        _ = try client.fetch()
        let record = try TeamHostnames.give(client: client, kid: positional[1], cloudflare: try cloudflare(), ledger: &ledger)
        try ledger.save(teamDir: dir)
        emit(["kid": positional[1], "hostname": record.hostname])
    case "list":
        struct Row: Encodable { var kid: String; var name: String?; var hostname: String; var at: Int; var orphaned: Bool }
        let ledger = TeamHostnames.Ledger.load(teamDir: dir)
        let roster = client.roster?.doc
        emit((ledger?.records ?? [:]).map { kid, r in
            Row(kid: kid, name: (roster.map { $0.leaders + $0.members } ?? []).first { $0.keys.kid == kid }?.name,
                hostname: r.hostname, at: r.at, orphaned: roster?.keys(for: kid) == nil)
        }.sorted { $0.hostname < $1.hostname })
    default:
        return controlFail("usage: infinitusctl team hostname <token <zone> [--label team] | give <kid> | list>", code: 2)
    }
```

Add a `HostnameError` arm to the CLI's error masking (`notConfigured` → "no Cloudflare token: run `infinitusctl team hostname token <zone>` first"; `badName` → "not a DNS name: …"; `api(status, msg)` → "Cloudflare: \(msg) (HTTP \(status))"; `unknownMember` → "no teammate …"), wherever `runTeamControl` maps thrown errors today (search `catch` in the file).

- [ ] **Step 3: Usage lines in `TeamCommand.swift`** after the `tail` line:

```
      hostname token <zone> [--label team]   # Cloudflare API token on stdin
      hostname give <kid>
      hostname list
```

- [ ] **Step 4: `case "remove"` cleanup in `TeamCommand.swift`**

```swift
case "remove":
    guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
    let c = try client(); _ = try c.fetch(); try c.remove(kid: kid)
    let dir = c.paths.teamDir(c.config.id)
    if var ledger = TeamHostnames.Ledger.load(teamDir: dir) {
        let cf = secrets.read(TeamHostnames.secretName).flatMap { String(data: $0, encoding: .utf8) }.map { TeamHostnames.Cloudflare(token: $0, http: controlHTTP) }
        _ = try TeamHostnames.forget(client: c, kid: kid, cloudflare: cf, ledger: &ledger)
        try ledger.save(teamDir: dir)
    }
    emit(try c.status())
```

(`controlHTTP` is file-private to TeamControlCommand.swift today: make it `func controlHTTP` at file scope without `private`, or move the closure to a shared `TeamHTTP.swift` in the CLI target.)

- [ ] **Step 5: Build both platforms' CLI target and smoke**

Run: `swift build --product infinitusctl && .build/debug/infinitusctl team hostname 2>&1 | head -2`
Expected: usage line, exit 2.

- [ ] **Step 6: Commit**

```bash
git add Sources/InfinitusCLI/TeamControlCommand.swift Sources/InfinitusCLI/TeamCommand.swift
git commit -m "team control: infinitusctl team hostname token|give|list — the API token on stdin, hostnames minted per member, removal cleans the records (#220)"
```

---

### Task 3: Mac app — TeamModel state + AppModel apply

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift`
- Modify: `Sources/Infinitus/AppModel.swift`

**Interfaces:**
- Produces on `TeamModel`: `@Published private(set) var hostnames: TeamHostnames.Ledger?`, `@Published private(set) var cloudflareConfigured: Bool`, `var onHostname: ((TeamControl.Hostname, _ from: String) -> Void)?`, `func saveCloudflare(zone:label:token:) async`, `func forgetCloudflare() async`, `func giveHostname(kid:) async`, `func deleteHostname(kid:) async`, `func hostname(of kid: String) -> String?`.

- [ ] **Step 1: State + load**

In `load()`'s background tuple add `TeamHostnames.Ledger.load(teamDir: dir)` and `secrets.read(TeamHostnames.secretName) != nil`; assign `hostnames` / `cloudflareConfigured` on the main actor beside `grants`. In the same background closure, after the snapshot, run the inbox:

```swift
var handled = TeamControl.Handled.load(teamDir: hostnameHandledDir(dir))   // file: control-hostname.json — see below
let fresh = try? TeamHostnames.inbox(client: client, handled: &handled)
if fresh != nil { try? handled.save(...) }
```

`TeamControl.Handled` is pinned to `control-handled.json`; add an optional file name: `Handled.load(teamDir:file:)` / `save(teamDir:file:)` with default `"control-handled.json"`, and use `"control-hostname.json"` here. Return `fresh` in the tuple; on the main actor: `if let fresh { onHostname?(fresh.hostname, fresh.from) }`.

- [ ] **Step 2: Actions**

```swift
func saveCloudflare(zone: String, label: String, token: String) async {
    await action("Checking the token…") { paths, secrets in
        guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
        let dir = paths.teamDir(team)
        var ledger = TeamHostnames.Ledger(zone: zone.lowercased(), label: label.lowercased())
        guard TeamHostnames.validName(ledger.zone), TeamHostnames.validName(ledger.label) else { throw TeamHostnames.HostnameError.badName("\(label).\(zone)") }
        if let old = TeamHostnames.Ledger.load(teamDir: dir), old.zone == ledger.zone { ledger.records = old.records }
        _ = try TeamHostnames.Cloudflare(token: token, http: TeamModel.urlHTTP).ids(ledger: &ledger)
        try secrets.write(TeamHostnames.secretName, Data(token.utf8))
        try ledger.save(teamDir: dir)
    }
}

func forgetCloudflare() async {
    await action("Forgetting…") { _, secrets in secrets.delete(TeamHostnames.secretName) }
}

private nonisolated static func cloudflare(_ secrets: TeamSecrets) -> TeamHostnames.Cloudflare? {
    secrets.read(TeamHostnames.secretName).flatMap { String(data: $0, encoding: .utf8) }.map { .init(token: $0, http: urlHTTP) }
}

func giveHostname(kid: String) async {
    await action("Minting…") { paths, secrets in
        guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
        let dir = paths.teamDir(client.config.id)
        guard var ledger = TeamHostnames.Ledger.load(teamDir: dir), let cf = Self.cloudflare(secrets) else { throw TeamHostnames.HostnameError.notConfigured }
        _ = try client.fetch()
        _ = try TeamHostnames.give(client: client, kid: kid, cloudflare: cf, ledger: &ledger)
        try ledger.save(teamDir: dir)
    }
}

/// An orphaned record (member gone) once a token is present.
func deleteHostname(kid: String) async {
    await action("Deleting…") { paths, secrets in
        guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
        let dir = paths.teamDir(client.config.id)
        guard var ledger = TeamHostnames.Ledger.load(teamDir: dir), let cf = Self.cloudflare(secrets) else { throw TeamHostnames.HostnameError.notConfigured }
        _ = try TeamHostnames.forget(client: client, kid: kid, cloudflare: cf, ledger: &ledger)
        try ledger.save(teamDir: dir)
    }
}

func hostname(of kid: String) -> String? { hostnames?.records[kid]?.hostname }
```

`remove(kid:)` gains, after `try client.remove(kid: kid)`:

```swift
let dir = paths.teamDir(client.config.id)
if var ledger = TeamHostnames.Ledger.load(teamDir: dir) {
    _ = try TeamHostnames.forget(client: client, kid: kid, cloudflare: Self.cloudflare(secrets), ledger: &ledger)
    try ledger.save(teamDir: dir)
}
```

`mask` gains the `HostnameError` arms (same wording as the CLI).

- [ ] **Step 3: AppModel apply** next to `team.onLoaded = …`:

```swift
team.onHostname = { [weak self] hostname, from in
    guard let self else { return }
    let host = NamedTunnel.normalizeHostname(hostname.hostname)
    guard !host.isEmpty else { return }
    NamedTunnel.setToken(hostname.token, for: host)
    mirrorNamedTunnelHost = host
    mirrorNamedTunnelEnabled = true
    let who = team.snapshot?.members.first { $0.kid == from }?.name ?? String(from.prefix(8))
    let hint = mirrorLANEnabled ? "" : " — turn on the LAN listener to run it"
    logEvent("team", icon: "network", "\(who) gave this Mac the hostname \(host)\(hint)")
}
```

- [ ] **Step 4: Build the app**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Build complete'`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/Infinitus/TeamModel.swift Sources/Infinitus/AppModel.swift Sources/InfinitusCore/Team/TeamControlStore.swift
git commit -m "team control: a hostname a leader gives this Mac is applied on the next fetch — token to the keychain, named tunnel on, one event line (#220)"
```

---

### Task 4: Settings › Team › Hostnames (leader)

**Files:**
- Modify: `Sources/Infinitus/TeamPane.swift` (`hostnamesSection`, called after `controlSection(snap)` when `snap.role == "leader"`)

- [ ] **Step 1: State**

```swift
@State private var cfZone = ""
@State private var cfLabel = TeamHostnames.defaultLabel
@State private var cfToken = ""
```

- [ ] **Step 2: Section**

```swift
private func hostnamesSection(_ snap: TeamSnapshot) -> some View {
    Section("Hostnames") {
        if team.cloudflareConfigured, let ledger = team.hostnames {
            HStack {
                Text("Cloudflare zone \(ledger.zone), label \(ledger.label)")
                Spacer()
                Button("Forget token") { Task { await team.forgetCloudflare() } }.controlSize(.small)
            }
            ForEach(snap.members) { m in
                HStack {
                    Text(m.name)
                    Spacer()
                    if let host = team.hostname(of: m.kid) {
                        Text(host).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Button("Give hostname") { Task { await team.giveHostname(kid: m.kid) } }.controlSize(.small)
                    }
                }
            }
            let orphans = team.roster.map { ledger.orphans(roster: $0.doc) } ?? []
            if !orphans.isEmpty {
                Text("Orphaned").font(.caption).foregroundStyle(.secondary)
                ForEach(orphans, id: \.kid) { o in
                    HStack {
                        Text(o.record.hostname).font(.caption)
                        Spacer()
                        Button("Delete", role: .destructive) { Task { await team.deleteHostname(kid: o.kid) } }.controlSize(.small)
                    }
                }
            }
        } else {
            TextField("Zone", text: $cfZone, prompt: Text("example.com"))
            TextField("Label", text: $cfLabel, prompt: Text("team"))
            SecureField("Cloudflare API token", text: $cfToken, prompt: Text("Account: Cloudflare Tunnel Edit · Zone: DNS Edit"))
            Button("Save") {
                let token = cfToken; cfToken = ""
                Task { await team.saveCloudflare(zone: cfZone, label: cfLabel, token: token) }
            }.disabled(cfZone.isEmpty || cfLabel.isEmpty || cfToken.isEmpty)
            if let ledger = team.hostnames, !ledger.records.isEmpty {
                Text("\(ledger.records.count) hostname\(ledger.records.count == 1 ? "" : "s") minted earlier; paste the token again to manage them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("A hostname is a Cloudflare named tunnel under your zone (`<name>.<label>.<zone>`), minted per member; their Mac starts it on the next fetch and keeps the same address across restarts.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

`team.roster` is `private(set)` published — readable from the view. If `SettingsSearch` indexes section titles, add "Hostnames" there (grep `"Session control"` in `Sources/Infinitus/SettingsSearch.swift` and mirror).

- [ ] **Step 3: Build, run a dev instance, eyeball**

Run: `swift build --product Infinitus` then `INFINITUS_CONTROL_SOCKET=/tmp/host.sock INFINITUS_TEAM_DIR=<scratch> .build/debug/Infinitus -mock_mode` (kill it after the look). Not a gate; the e2e is unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/TeamPane.swift Sources/Infinitus/SettingsSearch.swift
git commit -m "team control: Settings › Team › Hostnames — the leader's Cloudflare token (keychain), a hostname per member, orphans deletable (#220)"
```

---

### Task 5: Release lines, issue notes, full verification

**Files:**
- Modify: `CHANGELOG.md` (`### Team (preview)` first bullet), `README.md` (after the "Drive a granted session" bullet), `site/public/index.html` (Team card), `site/public/llms.txt`.

- [ ] **Step 1: Lines**

CHANGELOG: `- A leader can give each member a stable hostname — a Cloudflare named tunnel under the team's zone, minted from Settings or \`infinitusctl team hostname give\`, started by their Mac on the next fetch (#220).`

README bullet: `- **Stable hostnames per member** — a leader with a Cloudflare API token mints \`<name>.team.<zone>\` for a member (Settings › Team › Hostnames or \`infinitusctl team hostname give\`); the token travels sealed in the team store, the member's Mac runs the tunnel, and removal deletes the records.`

Site: one sentence in the Team card matching the README; llms.txt: one line.

- [ ] **Step 2: Full verification**

Run: `swift test 2>&1 | grep -E 'Executed|error:' | tail -2` — expected 0 failures.
Run: `tools/e2e.sh` with `INFINITUS_CONTROL_SOCKET=/tmp/host.sock` (announce "e2e running" / "e2e done" to Infi) — expected `E2E PASS`.

- [ ] **Step 3: Issue notes** on #220: rulings 1, 5, 10 (token store deviation, leader-at-`at` not enforceable, per-Mac ledger / multi-leader gap).

- [ ] **Step 4: Commit + push + handoff**

```bash
git add CHANGELOG.md README.md site/public/index.html site/public/llms.txt
git commit -m "team control: release lines for hostnames (#220)"
git push -u origin control-host
```

Handoff to Infi: `merge control-host at <sha> — --merge` (touches nothing under `ios/`).
