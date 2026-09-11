# Team Session Control — PR 4: Mac + CLI driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A teammate with a grant drives a session on the grantor's Mac — from the Mac's member detail or `infinitusctl team send|approve|mode|tail` — over LAN, tunnel or rendezvous when the grantor is reachable, and through the team store when it is not.

**Architecture:** `TeamControl.Deliver` (core, pure, injected HTTP) walks the network lanes in spec order; `TeamControl.Drive` seals a command, tries the network, and falls to the store; `TeamControl.Store` is the grantor's per-fetch pass over the commands addressed to it (verify + execute through the SAME `TeamControl.Endpoint` the HTTP route uses, ack sealed back) plus the reaping of stale files. The Mac runs the network lanes on a drive queue (never the team queue), the store lane through the team loop, and shows a remote chat window over `SessionFeedRow`; the CLI does the same single-threaded.

**Tech Stack:** Swift 6 / SwiftPM, XCTest, SwiftUI + AppKit (Mac), `tools/e2e.sh`.

**Spec:** `docs/superpowers/specs/2026-09-07-team-session-control-design.md` §3, §4, §5.3, §7.2, §7.3. PR 3's plan (`2026-09-07-team-control-mac.md`) holds the grantor rulings this one builds on.

## Global Constraints

- Everything is Swift; InfinitusCore builds on Linux (no AppKit, no `OSAllocatedUnfairLock` in core; `NSLock` is fine).
- No edits under `Sources/InfinitusUI/` (Infi3) or `ios/`; `SessionFeedRow` and `FeedRows.pendingPrompt` are used read-only.
- Never read engine internals; only `~/.claude/*` and the team dirs.
- Idle CPU with the pop-out open stays ~0 %: the remote tail polls every 3 s ONLY while its window is open; the store detaches the loop on close (WallWindow's lesson).
- `TeamControl.storeTTL` (600) for the store lane; `verify` refuses `command.at != header.at`, so every store publish passes `now: command.at`.
- Secrets never on argv; command text on stdin; errors masked through `TeamGit.masked`.
- Commit trailer `Co-Authored-By: Claude Code <noreply@anthropic.com>` (hook `tools/githooks`).
- CHANGELOG: one feature, one line, under `## Unreleased` → `### Team (preview)`; README + site/public/index.html + site/public/llms.txt in the same PR.

## Rulings (recorded before Task 1)

1. **Store lane is the e2e driver path.** Mock mode never starts the mirror listener, and a renamed binary would still collide with the real app's mirror port on the same Mac. Network lanes are unit-tested with an injected HTTP closure; the listener-based drive is logged on #220 as a later idea.
2. **One control box, one serial queue.** `MirrorTeamControlBox` owns the `run.infinitus.team-control` queue; both the HTTP route and the store pass run on it, so the replay set and the rate limit never see two writers.
3. **Network lanes never block the team queue.** The Mac walks LAN/hostname/rendezvous and polls tails on `run.infinitus.team-drive`; only the store publish rides `TeamModel.run`.
4. **Driver UI is a chat window opened from the member detail**, not inline in the Form: the detail lists the granted sessions and their controls; the window reuses the Mac chat's surface (feed rows, prompt bar, composer) with capability-gated controls and the lane + outcome line. The spec's "only while on screen" maps to window open/close.
5. **Interrupt = `key esc`** (needs `key`); Approve/Deny = `approve allow|deny` (never a ToolApproval rule, PR 3 ruling 2); a question's numbered option = `key <n>` (needs `key`).
6. **No socket `team-send`.** The CLI drives from its own identity with no IPC (`infinitusctl team send` works against the app's team dir too); the socket only gets its stale `team-status` replyShape fixed.
7. **Refused store commands are acked once.** A `control-handled.json` (path → blob version) beside `control-seen.json` stops a refused command from being re-refused and re-acked every fetch; entries are pruned when the file leaves the store.
8. **Reaping:** the driver deletes its own command once an ack for it is readable or the command is older than `storeTTL + maxFutureSkew`; the grantor deletes its own acks older than `2 × storeTTL`. Only own-branch deletes (TeamGit refuses others).
9. **Any non-2xx or thrown network answer means "this lane did not carry it"** and the next lane is tried; the store is the authoritative fallback. A 2xx with an empty body (the grantor could not seal an ack) is reported as `badRequest — no ack`.
10. **A tail is never served by the store**; when no network lane answers, the window says "no live tail (store only)" and keeps the controls.
11. **`team tail --follow` polls every 3 s** until SIGINT, printing items newer than the last stamp.
12. `MirrorRendezvous.parseLookup` accepts `.trycloudflare.com` only — recorded for PR 5 (a named tunnel under the control key would be dropped silently).
13. **`team send|approve|mode|tail|acks` do not sit on the lock list**: the grantor's Mac enforces the grant; a driver's lock protects nothing extra.

## File map

| File | Responsibility |
|---|---|
| `Sources/InfinitusCore/InterfaceAddresses.swift` (new) | `(address, mask)` pairs of the host's up IPv4 interfaces, Darwin + Glibc; `[]` elsewhere |
| `Sources/InfinitusCore/Team/TeamControlDrive.swift` (new) | `TeamControl.Lane`, `Delivery`, `Interface`, `Deliver` (lane walk, subnet check, rendezvous cache), `newCommandID`, `Drive` (network / store / tail), `Outcome.queued` |
| `Sources/InfinitusCore/Team/TeamControlStore.swift` (new) | `TeamControl.Handled`, `TeamControl.Store.grantorPass`, `driverReap` |
| `Sources/InfinitusCore/Team/TeamClient.swift` | `raw(_:)` — sealed bytes of one store path |
| `Sources/InfinitusCore/Team/TeamReader.swift` | `Member.commands`, `Member.acks`, `TeamReader.ackIDs` |
| `Sources/InfinitusCore/Team/TeamControlRoute.swift` | tail body is `application/json` |
| `Sources/InfinitusCore/ControlProtocol.swift` | `team-status` replyShape gains fleet + controls |
| `Sources/Infinitus/MirrorServer.swift` | box owns the control queue; `storePass(_:)` |
| `Sources/Infinitus/TeamModel.swift` | `onFetched`, `drive`, `tail`, drive queue, URL HTTP, driver reap in `load` |
| `Sources/Infinitus/AppModel.swift` | wires `team.onFetched` into the box |
| `Sources/Infinitus/TeamSessionChatWindow.swift` (new) | `TeamSessionChatWindows`, `TeamSessionChatStore`, `TeamSessionChatRoot` |
| `Sources/Infinitus/TeamMemberPane.swift` | "Drive" section: granted sessions → window |
| `Sources/InfinitusCLI/TeamControlCommand.swift` | `send`, `approve`, `mode`, `tail`, `acks` |
| `Sources/InfinitusCLI/TeamCommand.swift` | usage lines |
| `tools/e2e.sh` | driver step over the store lane |
| `Tests/InfinitusCoreTests/TeamControlDriveTests.swift` (new), `TeamControlStoreTests.swift` (new), `TeamReaderTests.swift` | |
| `CHANGELOG.md`, `README.md`, `site/public/index.html`, `site/public/llms.txt` | one line each |

---

### Task 1: Core driver — interfaces, lanes, `Drive`

**Files:**
- Create: `Sources/InfinitusCore/InterfaceAddresses.swift`
- Create: `Sources/InfinitusCore/Team/TeamControlDrive.swift`
- Modify: `Sources/InfinitusCore/Team/TeamControl.swift` (`Outcome.queued`)
- Test: `Tests/InfinitusCoreTests/TeamControlDriveTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum InterfaceAddresses { public static func ipv4() -> [TeamControl.Interface] }
  extension TeamControl {
      public enum Lane: String, Codable, Sendable { case lan, hostname, rendezvous, store
          public var label: String }   // "via LAN" | "via tunnel" | "via tunnel" | "via store, next fetch"
      public struct Delivery: Codable, Equatable, Sendable { public var id: String; public var lane: Lane; public var outcome: String; public var detail: String? }
      public struct Interface: Equatable, Sendable { public var address: String; public var mask: String }
      public struct Deliver {
          public typealias HTTP = @Sendable (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?, _ timeout: TimeInterval) throws -> (Int, Data)
          public static let lanTimeout: TimeInterval = 2, tunnelTimeout: TimeInterval = 5
          public var http: HTTP; public var interfaces: [Interface]; public var rendezvousBase: String
          public var rendezvous: [String: String]   // kid → tunnel base URL
          public init(http: @escaping HTTP, interfaces: [Interface], rendezvousBase: String = MirrorRendezvous.defaultBase)
          public static func sameSubnet(_ address: String, interfaces: [Interface]) -> Bool
          public mutating func exchange(method: String, path: String, headers: [String: String] = [:], body: Data?, endpoints: Endpoints, kid: String) -> (lane: Lane, status: Int, body: Data)?
      }
      public static func newCommandID() -> String        // "c-" + 16 lower hex
      public enum DriveError: Error, Equatable { case noRoster, unknownKid(String) }
      public enum Drive {
          public static func network(_ command: Command, identity: TeamIdentity, roster: TeamRoster, endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery?
          public static func store(_ command: Command, client: TeamClient) throws -> Delivery
          public static func send(_ command: Command, client: TeamClient, endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery
          public static func tail(kid: String, session: String, since: String?, identity: TeamIdentity, endpoints: Endpoints?, deliver: inout Deliver, now: Date = Date()) throws -> (lane: Lane, body: Data)?
      }
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InfinitusCore

final class TeamControlDriveTests: XCTestCase {
    typealias Call = (method: String, url: String, timeout: TimeInterval)

    func testSameSubnetUsesTheMask() {
        let ifs = [TeamControl.Interface(address: "192.168.1.20", mask: "255.255.255.0"),
                   TeamControl.Interface(address: "10.0.5.7", mask: "255.255.0.0")]
        XCTAssertTrue(TeamControl.Deliver.sameSubnet("192.168.1.99", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("192.168.2.99", interfaces: ifs))
        XCTAssertTrue(TeamControl.Deliver.sameSubnet("10.0.200.1", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("10.1.0.1", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("not-an-ip", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("192.168.1.99", interfaces: []))
    }

    func testLanIsSkippedOffSubnetAndLanesFallThroughInOrder() {
        var calls: [Call] = []
        let http: TeamControl.Deliver.HTTP = { m, url, _, _, t in
            calls.append((m, url.absoluteString, t))
            if url.host == "grantor.example.net" { return (200, Data("ok".utf8)) }
            return (503, Data())
        }
        var d = TeamControl.Deliver(http: http, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        let e = TeamControl.Endpoints(lan: "192.168.7.7:8912", hostname: "grantor.example.net", rendezvous: nil)
        let r = d.exchange(method: "POST", path: "/team/command", body: Data("x".utf8), endpoints: e, kid: "k")
        XCTAssertEqual(r?.lane, .hostname)
        XCTAssertEqual(r?.body, Data("ok".utf8))
        XCTAssertEqual(calls.map(\.url), ["https://grantor.example.net/team/command"], "off-subnet LAN never dialed")
        XCTAssertEqual(calls.first?.timeout, 5)
    }

    func testLanFirstOnSubnetThenHostnameThenRendezvousWithCacheRefresh() throws {
        var answers: [String: Int] = ["http://10.0.0.9:8912/team/command": 500,
                                      "https://h.example.net/team/command": 404]
        var lookups = 0
        var calls: [String] = []
        let http: TeamControl.Deliver.HTTP = { _, url, _, _, _ in
            let s = url.absoluteString
            calls.append(s)
            if s.hasPrefix("https://infinitus.run/rendezvous/") {
                lookups += 1
                let tunnel = lookups == 1 ? "https://old.trycloudflare.com" : "https://new.trycloudflare.com"
                return (200, MirrorRendezvous.publishBody(url: tunnel))
            }
            if s == "https://old.trycloudflare.com/team/command" { throw NSError(domain: "t", code: 1) }
            if s == "https://new.trycloudflare.com/team/command" { return (200, Data("ack".utf8)) }
            return (answers[s] ?? 0, Data())
        }
        var d = TeamControl.Deliver(http: http, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        let key = TeamControl.rendezvousKey(team: "t", kid: "k")
        d.rendezvous["k"] = "https://old.trycloudflare.com"          // stale cache
        let e = TeamControl.Endpoints(lan: "10.0.0.9:8912", hostname: "h.example.net", rendezvous: key)
        let r = d.exchange(method: "POST", path: "/team/command", body: Data(), endpoints: e, kid: "k")
        XCTAssertEqual(r?.lane, .rendezvous)
        XCTAssertEqual(r?.body, Data("ack".utf8))
        XCTAssertEqual(calls.prefix(2).map { $0 }, ["http://10.0.0.9:8912/team/command", "https://h.example.net/team/command"])
        XCTAssertEqual(lookups, 1, "the cached tunnel was tried first, the lookup only after it refused")
        XCTAssertEqual(d.rendezvous["k"], "https://new.trycloudflare.com")
        _ = answers
    }

    func testNoEndpointMeansNoNetworkLane() {
        var dialed = 0
        var d = TeamControl.Deliver(http: { _, _, _, _, _ in dialed += 1; return (200, Data()) }, interfaces: [])
        XCTAssertNil(d.exchange(method: "POST", path: "/x", body: nil, endpoints: TeamControl.Endpoints(), kid: "k"))
        XCTAssertEqual(dialed, 0)
    }

    func testCommandIDsFitTheStorePath() {
        let id = TeamControl.newCommandID()
        XCTAssertEqual(id.count, 18)
        XCTAssertTrue(id.hasPrefix("c-"))
        XCTAssertTrue(id.allSatisfy { "abcdef0123456789-".contains($0) })
        XCTAssertNotEqual(id, TeamControl.newCommandID())
    }

    func testDriveNetworkOpensTheAckAndReportsTheLane() throws {
        let driver = TeamIdentity.random(), grantor = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], removed: [], rev: 2)
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.kid, session: "s1", action: TeamGrants.send, text: "hi", at: 1_000)
        let http: TeamControl.Deliver.HTTP = { _, _, _, body, _ in
            // The grantor opens the command and acks it.
            let (h, c) = try TeamControl.openCommand(body!, as: grantor, senderKey: { $0 == driver.kid ? driver.keys : nil })
            XCTAssertEqual(h.from, driver.kid); XCTAssertEqual(c, cmd)
            let ack = TeamControl.Ack(id: c.id, outcome: TeamControl.Outcome.delivered, detail: nil, at: 1_001)
            return (200, try TeamControl.sealAck(ack, from: grantor, to: driver.keys, at: 1_001))
        }
        var d = TeamControl.Deliver(http: http, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        let out = try TeamControl.Drive.network(cmd, identity: driver, roster: roster,
                                                endpoints: TeamControl.Endpoints(lan: "10.0.0.9:8912"), deliver: &d)
        XCTAssertEqual(out, TeamControl.Delivery(id: cmd.id, lane: .lan, outcome: "delivered", detail: nil))
        // An empty 200: the grantor could not answer.
        var e = TeamControl.Deliver(http: { _, _, _, _, _ in (200, Data()) }, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        XCTAssertEqual(try TeamControl.Drive.network(cmd, identity: driver, roster: roster,
                                                     endpoints: TeamControl.Endpoints(lan: "10.0.0.9:8912"), deliver: &e)?.outcome, "badRequest")
        // No endpoints: nil, the caller goes to the store.
        XCTAssertNil(try TeamControl.Drive.network(cmd, identity: driver, roster: roster, endpoints: nil, deliver: &d))
        XCTAssertThrowsError(try TeamControl.Drive.network(TeamControl.Command(id: "c-0123456789", to: "nobody", session: "s", action: "send", text: "x", at: 1),
                                                           identity: driver, roster: roster, endpoints: nil, deliver: &d))
    }

    func testTailSignsTheHeaderAndUsesGet() throws {
        let driver = TeamIdentity.random()
        var seen: (String, String, [String: String])?
        let http: TeamControl.Deliver.HTTP = { m, url, headers, _, _ in seen = (m, url.absoluteString, headers); return (200, Data("{}".utf8)) }
        var d = TeamControl.Deliver(http: http, interfaces: [])
        let r = try TeamControl.Drive.tail(kid: "k", session: "s1", since: "42", identity: driver,
                                           endpoints: TeamControl.Endpoints(hostname: "h.example.net"), deliver: &d, now: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(r?.lane, .hostname)
        XCTAssertEqual(seen?.0, "GET")
        XCTAssertEqual(seen?.1, "https://h.example.net/team/sessions/s1/tail?since=42")
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1, leaders: [TeamRoster.Member(keys: driver.keys, name: "D", since: 1, founder: true)], members: [], removed: [], rev: 1)
        XCTAssertEqual(TeamControlRoute.checkTail(seen?.2[TeamControlRoute.tailHeader] ?? "", sessionId: "s1", roster: roster, now: Date(timeIntervalSince1970: 130)), driver.kid)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -c error:` — expected: compile errors (`Deliver`, `Drive`, `Interface` undefined).

- [ ] **Step 3: Implement**

`Sources/InfinitusCore/InterfaceAddresses.swift`:
```swift
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The host's up, non-loopback IPv4 interfaces with their netmasks —
/// the driver's "is that LAN address one of my own subnets" check
/// (#220 §5.3). Empty where getifaddrs is not available.
public enum InterfaceAddresses {
    public static func ipv4() -> [TeamControl.Interface] {
        #if canImport(Darwin) || canImport(Glibc)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [TeamControl.Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int(pointer.pointee.ifa_flags)
            guard flags & Int(IFF_UP) == Int(IFF_UP), flags & Int(IFF_LOOPBACK) == 0,
                  let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = pointer.pointee.ifa_netmask,
                  let a = text(address), let m = text(mask) else { continue }
            let entry = TeamControl.Interface(address: a, mask: m)
            if !found.contains(entry) { found.append(entry) }
        }
        return found
        #else
        return []
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
    #endif
}
```

`Sources/InfinitusCore/Team/TeamControlDrive.swift`:
```swift
import Foundation

// The driver's half of #220 §5.3: the lane walk (LAN → hostname →
// rendezvous, then the store), pure over an injected HTTP closure so the
// Mac, the CLI and the tests share one order.
extension TeamControl {
    public enum Lane: String, Codable, Sendable {
        case lan, hostname, rendezvous, store
        public var label: String {
            switch self {
            case .lan: return "via LAN"
            case .hostname, .rendezvous: return "via tunnel"
            case .store: return "via store, next fetch"
            }
        }
    }

    /// What one command came to: the lane that carried it and the
    /// grantor's outcome (or `queued` while the store lane waits).
    public struct Delivery: Codable, Equatable, Sendable {
        public var id: String
        public var lane: Lane
        public var outcome: String
        public var detail: String?
        public init(id: String, lane: Lane, outcome: String, detail: String?) {
            self.id = id; self.lane = lane; self.outcome = outcome; self.detail = detail
        }
    }

    public struct Interface: Equatable, Sendable {
        public var address: String
        public var mask: String
        public init(address: String, mask: String) { self.address = address; self.mask = mask }
    }

    /// `[a-z0-9-]{8,64}` (TeamKinds' path rule): "c-" + 16 lower hex.
    public static func newCommandID() -> String {
        var g = SystemRandomNumberGenerator()
        return "c-" + (0..<16).map { _ in String(Int.random(in: 0..<16, using: &g), radix: 16) }.joined()
    }

    public struct Deliver {
        public typealias HTTP = @Sendable (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?, _ timeout: TimeInterval) throws -> (Int, Data)
        public static let lanTimeout: TimeInterval = 2
        public static let tunnelTimeout: TimeInterval = 5

        public var http: HTTP
        public var interfaces: [Interface]
        public var rendezvousBase: String
        /// kid → tunnel base URL, refreshed on the first refused connection.
        public var rendezvous: [String: String] = [:]

        public init(http: @escaping HTTP, interfaces: [Interface], rendezvousBase: String = MirrorRendezvous.defaultBase) {
            self.http = http; self.interfaces = interfaces; self.rendezvousBase = rendezvousBase
        }

        /// Spec §5.3 step 1: a LAN address is dialed only when it sits in
        /// one of this host's own IPv4 subnets.
        public static func sameSubnet(_ address: String, interfaces: [Interface]) -> Bool {
            guard let a = MirrorPairing.ipv4Octets(address) else { return false }
            return interfaces.contains { i in
                guard let n = MirrorPairing.ipv4Octets(i.address), let m = MirrorPairing.ipv4Octets(i.mask) else { return false }
                return zip(zip(a, n), m).allSatisfy { $0.0 & $1 == $0.1 & $1 }
            }
        }

        /// The walk. nil ⇒ no network lane answered 2xx (the caller falls
        /// to the store). Any throw or non-2xx moves to the next lane
        /// (ruling 9).
        public mutating func exchange(method: String, path: String, headers: [String: String] = [:], body: Data?,
                                      endpoints: Endpoints, kid: String) -> (lane: Lane, status: Int, body: Data)? {
            func attempt(_ base: String, _ timeout: TimeInterval) -> (Int, Data)? {
                guard let url = URL(string: base + path),
                      let r = try? http(method, url, headers, body, timeout), (200..<300).contains(r.0) else { return nil }
                return r
            }
            if let lan = endpoints.lan, let host = lan.split(separator: ":").first, Self.sameSubnet(String(host), interfaces: interfaces),
               let r = attempt("http://\(lan)", Self.lanTimeout) { return (.lan, r.0, r.1) }
            if let hostname = endpoints.hostname, let r = attempt("https://\(hostname)", Self.tunnelTimeout) { return (.hostname, r.0, r.1) }
            if let key = endpoints.rendezvous {
                if let cached = rendezvous[kid], let r = attempt(cached, Self.tunnelTimeout) { return (.rendezvous, r.0, r.1) }
                if let fresh = lookup(key), fresh != rendezvous[kid] {
                    rendezvous[kid] = fresh
                    if let r = attempt(fresh, Self.tunnelTimeout) { return (.rendezvous, r.0, r.1) }
                }
            }
            return nil
        }

        private func lookup(_ key: String) -> String? {
            guard let url = MirrorRendezvous.url(key: key, base: rendezvousBase),
                  let (status, data) = try? http("GET", url, [:], nil, Self.tunnelTimeout), status == 200 else { return nil }
            return MirrorRendezvous.parseLookup(data)
        }
    }

    public enum DriveError: Error, Equatable {
        case noRoster
        case unknownKid(String)
    }

    public enum Drive {
        /// Lanes 1–3. nil when none answered; the caller stores.
        public static func network(_ command: Command, identity: TeamIdentity, roster: TeamRoster,
                                   endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery? {
            guard let grantor = roster.keys(for: command.to, at: command.at) else { throw DriveError.unknownKid(command.to) }
            guard let endpoints else { return nil }
            let sealed = try sealCommand(command, from: identity, to: grantor, at: command.at)
            guard let (lane, _, body) = deliver.exchange(method: "POST", path: TeamControlRoute.commandPath, body: sealed,
                                                         endpoints: endpoints, kid: command.to) else { return nil }
            guard !body.isEmpty else { return Delivery(id: command.id, lane: lane, outcome: Outcome.badRequest, detail: "no ack") }
            let sealedAt = (try? Envelope.header(of: body).at) ?? 0
            let (_, ack) = try openAck(body, as: identity, senderKey: { roster.keys(for: $0, at: sealedAt) })
            return Delivery(id: command.id, lane: lane, outcome: ack.outcome, detail: ack.detail)
        }

        /// Lane 4: the command under my branch, ttl raised to `storeTTL`,
        /// sealed at `command.at` (verify binds the two).
        public static func store(_ command: Command, client: TeamClient) throws -> Delivery {
            var stored = command
            stored.ttl = storeTTL
            try client.publish(kind: TeamKinds.command, path: "control/commands/\(command.id).json",
                               plaintext: try CanonicalJSON.encode(stored), audience: .members([command.to]), now: command.at)
            return Delivery(id: command.id, lane: .store, outcome: Outcome.queued, detail: "next fetch")
        }

        public static func send(_ command: Command, client: TeamClient, endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery {
            guard let roster = client.roster?.doc else { throw DriveError.noRoster }
            if let d = try network(command, identity: client.identity, roster: roster, endpoints: endpoints, deliver: &deliver) { return d }
            return try store(command, client: client)
        }

        /// The tail route over the same lanes; never the store (ruling 10).
        public static func tail(kid: String, session: String, since: String?, identity: TeamIdentity, endpoints: Endpoints?,
                                deliver: inout Deliver, now: Date = Date()) throws -> (lane: Lane, body: Data)? {
            guard let endpoints else { return nil }
            let header = try TeamControlRoute.signTail(sessionId: session, by: identity, now: now)
            let path = TeamControlRoute.tailPath(sessionId: session) + (since.map { "?since=\($0)" } ?? "")
            guard let (lane, _, body) = deliver.exchange(method: "GET", path: path, headers: [TeamControlRoute.tailHeader: header],
                                                         body: nil, endpoints: endpoints, kid: kid) else { return nil }
            return (lane, body)
        }
    }
}
```
In `TeamControl.Outcome` add `public static let queued = "queued"` with the comment "driver-side only: the store lane is waiting on the grantor's fetch".

`MirrorPairing.ipv4Octets` is `static` (internal) — same module, fine.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TeamControlDriveTests 2>&1 | tail -n 5` — expected: 7 tests, 0 failures. Then `swift build` for the whole tree.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/InterfaceAddresses.swift Sources/InfinitusCore/Team/TeamControlDrive.swift Sources/InfinitusCore/Team/TeamControl.swift Tests/InfinitusCoreTests/TeamControlDriveTests.swift
git commit -m "team control: the driver's lane walk — LAN on my subnet, hostname, rendezvous with a per-member cache, then the store (#220 §5.3)"
```

---

### Task 2: Core store lane — handled set, grantor pass, reaping, reader acks

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamControlStore.swift`
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`raw`), `Sources/InfinitusCore/Team/TeamReader.swift` (fold + fields)
- Test: `Tests/InfinitusCoreTests/TeamControlStoreTests.swift`, `Tests/InfinitusCoreTests/TeamReaderTests.swift`

**Interfaces:**
- Consumes: `TeamControl.Endpoint`, `TeamControl.handle`, `TeamClient.publish/unpublish/readableHeaders`, Task 1's `Drive.store`.
- Produces:
  ```swift
  extension TeamClient { public func raw(_ path: String) throws -> Data? }
  extension TeamReader.Member { public var commands: [String]; public var acks: [String: TeamControl.Ack] }
  extension TeamReader { public var ackIDs: Set<String> }
  extension TeamControl {
      public struct Handled: Codable, Equatable, Sendable {
          public var versions: [String: String]
          public static func load(teamDir: URL) -> Handled; public func save(teamDir: URL) throws
          public func contains(_ entry: StoreEntry) -> Bool; public mutating func mark(_ entry: StoreEntry); public mutating func prune(keeping: Set<String>)
      }
      public enum Store {
          public static func grantorPass(client: TeamClient, endpoint: inout Endpoint, handled: inout Handled, now: Int = …) throws -> [Audit]
          public static func driverReap(client: TeamClient, acks: Set<String>, now: Int = …) throws -> Int
      }
  }
  ```

- [ ] **Step 1: Write the failing tests**

Reader (append to `TeamReaderTests`):
```swift
    func testFoldKeepsCommandPathsAndDecodesAcks() throws {
        let g = TeamIdentity.random(), d = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: g.keys, name: "G", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: d.keys, name: "D", since: 2)], removed: [], rev: 2)
        let ack = TeamControl.Ack(id: "c-0123456789", outcome: "delivered", detail: nil, at: 5)
        let docs = ["m/\(g.kid)/control/acks/c-0123456789.json": try CanonicalJSON.encode(ack)]
        let headers = [entry("m/\(d.kid)/control/commands/c-0123456789.json", kind: TeamKinds.command, from: d.kid, at: 4),
                       entry("m/\(g.kid)/control/acks/c-0123456789.json", kind: TeamKinds.ack, from: g.kid, at: 5)]
        let reader = TeamReader.fold(headers: headers, roster: roster) { docs[$0] ?? Data() }
        XCTAssertEqual(reader.members[d.kid]?.commands, ["m/\(d.kid)/control/commands/c-0123456789.json"])
        XCTAssertEqual(reader.members[g.kid]?.acks["c-0123456789"], ack)
        XCTAssertEqual(reader.ackIDs, ["c-0123456789"])
    }
```

`Tests/InfinitusCoreTests/TeamControlStoreTests.swift`:
```swift
import XCTest
@testable import InfinitusCore

final class TeamControlStoreTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamcontrolstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

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

    /// Leader = grantor, Bob = driver; a grant to Bob on session s1 for send.
    func team() throws -> (grantor: TeamClient, driver: TeamClient, grantorDir: URL) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: bob.identity.kid, now: 1_020)
        _ = try bob.fetch()
        let dir = lp.teamDir(leader.config.id)
        var grants = TeamGrants()
        _ = grants.add(audience: .members([bob.identity.kid]), sessions: .some(["s1"]), capabilities: [TeamGrants.send], now: 1_030)
        try grants.save(teamDir: dir)
        return (leader, bob, dir)
    }

    func endpoint(_ client: TeamClient, dir: URL, now: Int, executed: @escaping (String, String?) -> Void) -> TeamControl.Endpoint {
        TeamControl.Endpoint(identity: client.identity, roster: { client.roster?.doc }, grants: { TeamGrants.load(teamDir: dir) },
                             liveSessions: { ["s1": 4242] },
                             execute: { action, text, _ in executed(action, text); return SessionInput.Reply(outcome: "delivered", detail: nil) },
                             seen: TeamControl.SeenIDs(), limit: TeamControl.RateLimit(), now: { Date(timeIntervalSince1970: TimeInterval(now)) })
    }

    func testStoreLaneRoundTripsAndAcksOnce() throws {
        let (grantor, driver, dir) = try team()
        let now = 2_000
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.identity.kid, session: "s1", action: TeamGrants.send, text: "hello", at: now)
        var d = TeamControl.Deliver(http: { _, _, _, _, _ in XCTFail("no endpoints, no dial"); return (0, Data()) }, interfaces: [])
        let delivery = try TeamControl.Drive.send(cmd, client: driver, endpoints: nil, deliver: &d)
        XCTAssertEqual(delivery, TeamControl.Delivery(id: cmd.id, lane: .store, outcome: "queued", detail: "next fetch"))

        _ = try grantor.fetch()
        var executed: [(String, String?)] = []
        var ep = endpoint(grantor, dir: dir, now: now + 10) { executed.append(($0, $1)) }
        var handled = TeamControl.Handled.load(teamDir: dir)
        let audits = try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 10)
        XCTAssertEqual(audits.map(\.outcome), ["delivered"])
        XCTAssertEqual(audits.first?.driver, driver.identity.kid)
        XCTAssertEqual(executed.map(\.0), ["send"]); XCTAssertEqual(executed.first?.1, "hello")
        XCTAssertTrue(ep.seen.expiry.keys.contains(cmd.id), "an executed store command spends its id like an HTTP one")
        // A second pass over the same store is a no-op: handled remembers the blob.
        XCTAssertEqual(try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 20).count, 0)
        XCTAssertEqual(executed.count, 1)
        try handled.save(teamDir: dir)
        XCTAssertEqual(TeamControl.Handled.load(teamDir: dir), handled)

        // The driver's next fetch shows the ack, then reaps its command.
        _ = try driver.fetch()
        let reader = try TeamReader.load(client: driver)
        XCTAssertEqual(reader.members[grantor.identity.kid]?.acks[cmd.id]?.outcome, "delivered")
        XCTAssertEqual(try TeamControl.Store.driverReap(client: driver, acks: reader.ackIDs, now: now + 30), 1)
        XCTAssertEqual(try driver.readableHeaders().filter { $0.header.kind == TeamKinds.command }.count, 0)
        // ...and the grantor reaps its ack once it is old.
        _ = try grantor.fetch()
        XCTAssertEqual(try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 3 * TeamControl.storeTTL).count, 0)
        XCTAssertEqual(try grantor.readableHeaders().filter { $0.header.kind == TeamKinds.ack }.count, 0)
        XCTAssertTrue(handled.versions.isEmpty, "pruned with the file")
    }

    func testRefusedStoreCommandIsAckedWithTheRefusal() throws {
        let (grantor, driver, dir) = try team()
        let now = 2_000
        let cmd = TeamControl.Command(id: "c-0123456780", to: grantor.identity.kid, session: "s1", action: TeamGrants.mode, text: "acceptEdits", at: now)
        _ = try TeamControl.Drive.store(cmd, client: driver)
        _ = try grantor.fetch()
        var ep = endpoint(grantor, dir: dir, now: now + 10) { _, _ in XCTFail("not granted") }
        var handled = TeamControl.Handled()
        let audits = try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 10)
        XCTAssertEqual(audits.map(\.outcome), ["noGrant"])
        _ = try driver.fetch()
        XCTAssertEqual(try TeamReader.load(client: driver).members[grantor.identity.kid]?.acks[cmd.id]?.outcome, "noGrant")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head` — expected: `Handled`, `Store`, `raw`, `commands`, `acks`, `ackIDs` undefined.

- [ ] **Step 3: Implement**

`TeamClient`:
```swift
    /// One store file as sealed bytes (for `TeamControl.handle`, which
    /// verifies the envelope itself); nil when the path is not there.
    public func raw(_ path: String) throws -> Data? { try store.get(path) }
```

`TeamReader.Member`: add after `transcripts`
```swift
        /// #220 store lane: command envelopes this sender wrote (store paths).
        public var commands: [String] = []
        /// #220 store lane: this sender's acks by command id.
        public var acks: [String: TeamControl.Ack] = [:]
```
`fold`: before `default: break`
```swift
            case TeamKinds.command:
                member.commands.append(entry.path)
            case TeamKinds.ack:
                if let doc = decode(TeamControl.Ack.self, entry.path), doc.schema == 1 { member.acks[doc.id] = doc }
```
and on `TeamReader`:
```swift
    /// Every command id someone acked, whoever the grantor was.
    public var ackIDs: Set<String> { Set(members.values.flatMap { $0.acks.keys }) }
```

`Sources/InfinitusCore/Team/TeamControlStore.swift`:
```swift
import Foundation

// #220 §5.3 lane 4, both sides. The grantor's pass runs after every
// fetch through the SAME Endpoint the HTTP route uses (one replay set,
// one rate limit); the driver reads acks off the reader.
extension TeamControl {
    /// Store commands already answered, by path and blob version, so a
    /// refused command is refused once, not on every fetch (ruling 7).
    /// `<team dir>/control-handled.json`.
    public struct Handled: Codable, Equatable, Sendable {
        public var versions: [String: String] = [:]
        public init() {}
        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("control-handled.json") }
        public static func load(teamDir: URL) -> Handled {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? JSONDecoder().decode(Handled.self, from: $0) } ?? Handled()
        }
        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file(teamDir: teamDir), options: .atomic)
        }
        public func contains(_ entry: StoreEntry) -> Bool { versions[entry.path] == entry.version }
        public mutating func mark(_ entry: StoreEntry) { versions[entry.path] = entry.version }
        public mutating func prune(keeping paths: Set<String>) { versions = versions.filter { paths.contains($0.key) } }
    }

    public enum Store {
        /// Commands addressed to me that no earlier pass answered: verify +
        /// execute, ack under my branch (one commit each; commands are
        /// rare), remember the blob. Acks of mine older than 2 × storeTTL
        /// are deleted here too (ruling 8). Returns the audits for the log.
        public static func grantorPass(client: TeamClient, endpoint: inout Endpoint, handled: inout Handled,
                                       now: Int = Int(Date().timeIntervalSince1970)) throws -> [Audit] {
            let me = client.identity.kid
            let headers = try client.readableHeaders()
            let inbox = headers.filter { $0.header.kind == TeamKinds.command && $0.header.from != me }
            handled.prune(keeping: Set(inbox.map(\.entry.path)))
            var audits: [Audit] = []
            for (entry, _) in inbox where !handled.contains(entry) {
                guard let file = try client.raw(entry.path) else { continue }
                let (ack, audit, driverKeys) = handle(file, endpoint: &endpoint)
                handled.mark(entry)
                audits.append(audit)
                guard let driverKeys, !ack.id.isEmpty else { continue }
                try client.publish(kind: TeamKinds.ack, path: "control/acks/\(ack.id).json", plaintext: try CanonicalJSON.encode(ack),
                                   audience: .members([driverKeys.kid]), now: ack.at)
            }
            for (entry, header) in headers where header.kind == TeamKinds.ack && header.from == me && header.at + 2 * storeTTL < now {
                try client.unpublish(path: String(entry.path.dropFirst("m/\(me)/".count)))
            }
            return audits
        }

        /// The driver deletes its own commands once acked, or once too old
        /// for any grantor to accept. Returns how many went.
        public static func driverReap(client: TeamClient, acks: Set<String>, now: Int = Int(Date().timeIntervalSince1970)) throws -> Int {
            let me = client.identity.kid
            var gone = 0
            for (entry, header) in try client.readableHeaders() where header.kind == TeamKinds.command && header.from == me {
                let id = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
                guard acks.contains(id) || header.at + storeTTL + maxFutureSkew < now else { continue }
                try client.unpublish(path: String(entry.path.dropFirst("m/\(me)/".count)))
                gone += 1
            }
            return gone
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'TeamControlStoreTests|TeamReaderTests|TeamControlTests' 2>&1 | tail -n 5` — expected: all pass. If `readableHeaders` after `unpublish` still lists the file, call `client.fetch()` before asserting (the store is the pushed branch).

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Team/TeamControlStore.swift Sources/InfinitusCore/Team/TeamClient.swift Sources/InfinitusCore/Team/TeamReader.swift Tests/InfinitusCoreTests/TeamControlStoreTests.swift Tests/InfinitusCoreTests/TeamReaderTests.swift
git commit -m "team control: the store lane — a grantor's per-fetch pass through the one endpoint, acks read off the reader, stale files reaped (#220 §5.3)"
```

---

### Task 3: Mac grantor store lane + small route/socket fixes

**Files:**
- Modify: `Sources/Infinitus/MirrorServer.swift` (box owns the queue, `storePass`), `Sources/Infinitus/TeamModel.swift` (`onFetched`, driver reap in `load`), `Sources/Infinitus/AppModel.swift` (wiring), `Sources/InfinitusCore/Team/TeamControlRoute.swift` (content type), `Sources/InfinitusCore/ControlProtocol.swift` (replyShape)

**Interfaces:**
- Produces: `MirrorTeamControlBox.queue` (static serial), `func storePass(_ client: TeamClient)`; `TeamModel.onFetched: (@Sendable (TeamClient) -> Void)?`.

- [ ] **Step 1: Box**

In `MirrorTeamControlBox`:
```swift
    /// Verification, the replay set and the rate limit are single-threaded
    /// here for BOTH lanes (ruling 2); delivery hops to `mirrorInputQueue`.
    static let queue = DispatchQueue(label: "run.infinitus.team-control")
```
Replace `MirrorServer.controlQueue` uses with `MirrorTeamControlBox.queue` and delete the private static. Add:
```swift
    /// Lane 4 (#220 §5.3): after a fetch, the commands under the store
    /// addressed to me. Called on the team queue; hops onto the control
    /// queue so the HTTP route can't interleave.
    func storePass(_ client: TeamClient) {
        Self.queue.sync {
            lock.lock(); var ep = endpoint; let dir = teamDir; lock.unlock()
            guard var ep, let dir else { return }
            var handled = TeamControl.Handled.load(teamDir: dir)
            let audits: [TeamControl.Audit]
            do { audits = try TeamControl.Store.grantorPass(client: client, endpoint: &ep, handled: &handled) }
            catch { Lifecycle.log.error("team control store pass: \(TeamGit.masked("\(error)"), privacy: .public)"); return }
            lock.lock(); endpoint?.seen = ep.seen; endpoint?.limit = ep.limit; lock.unlock()
            guard !audits.isEmpty else { return }
            try? ep.seen.save(teamDir: dir)
            try? handled.save(teamDir: dir)
            let roster = ep.roster()
            for audit in audits { onAudit?(audit, roster?.everyone.first { $0.keys.kid == audit.driver }?.name) }
        }
    }
```
(`endpoint?.seen = ep.seen` must be written after `guard var ep` shadows — name the copy `var copy` to keep `endpoint` addressable.) `Lifecycle.log` is what TeamModel uses; `TeamGit.masked` exists.

- [ ] **Step 2: TeamModel**

Add `var onFetched: (@Sendable (TeamClient) -> Void)?` (documented: "after every fetch, on the team queue — the grantor's store pass"). In `loop`, right after `_ = try client.fetch()` and `let fetched = …`: `onFetched?(client)` — the closure is captured before `run { }` as `let fetched = onFetched`. In `load()`'s run block, after `let (snap, reader) = try Self.snapshot(...)`: 
```swift
                    // Driver side of the store lane: my acked or stale commands go (ruling 8); a no-op push-free scan when there are none.
                    if let reader { _ = try? TeamControl.Store.driverReap(client: client, acks: reader.ackIDs) }
```

- [ ] **Step 3: AppModel**

Next to `team.onLoaded = …`: `team.onFetched = { [mirrorServer] client in mirrorServer.teamControl.storePass(client) }`.

- [ ] **Step 4: Route + protocol**

`TeamControlRoute.respond` tail branch: `contentType: "application/json"` (the body is one `SessionFeed`). `ControlProtocol` `team-status` replyShape: append `, fleet, controls` inside the member braces after `todayCommits`.

- [ ] **Step 5: Build + tests**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|warning: unused' ; swift test --filter 'TeamControl|TeamRoute' 2>&1 | tail -n 3`. Expected: clean build, tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Infinitus/MirrorServer.swift Sources/Infinitus/TeamModel.swift Sources/Infinitus/AppModel.swift Sources/InfinitusCore/Team/TeamControlRoute.swift Sources/InfinitusCore/ControlProtocol.swift
git commit -m "team control: the Mac's grantor answers store commands after every fetch through the same box the HTTP route uses (#220)"
```

---

### Task 4: Mac driver — `TeamModel.drive/tail`, the remote chat window, member detail

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift`, `Sources/Infinitus/TeamMemberPane.swift`
- Create: `Sources/Infinitus/TeamSessionChatWindow.swift`

**Interfaces:**
- Produces:
  ```swift
  extension TeamModel {
      func drive(kid: String, session: String, action: String, text: String?) async -> TeamControl.Delivery?   // nil ⇒ lastError set
      func tail(kid: String, session: String, since: String?) async -> (lane: TeamControl.Lane, feed: SessionFeed)?
      func controls(grantedBy kid: String) -> Set<String>      // snapshot.members[kid].controls
  }
  @MainActor final class TeamSessionChatWindows { static let shared; func open(kid: String, session: TeamDocs.LiveSession, team: TeamModel) }
  ```

- [ ] **Step 1: TeamModel driver API**

```swift
    /// Network lanes and tail polls never touch the team queue (ruling 3).
    private let driveQueue = DispatchQueue(label: "run.infinitus.team-drive", qos: .userInitiated)
    private let deliver = OSAllocatedUnfairLock(initialState: TeamControl.Deliver(http: TeamModel.urlHTTP, interfaces: []))

    private nonisolated static let urlHTTP: TeamControl.Deliver.HTTP = { method, url, headers, body, timeout in
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<(Int, Data, Error?)>(initialState: (0, Data(), nil))
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.withLock { $0 = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), error) }
            done.signal()
        }.resume()
        done.wait()
        let (status, data, failure) = box.withLock { $0 }
        if let failure { throw failure }
        return (status, data)
    }

    func controls(grantedBy kid: String) -> Set<String> {
        Set(snapshot?.members.first { $0.kid == kid }?.controls ?? [])
    }

    private func onDriveQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            driveQueue.async { do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) } }
        }
    }

    func drive(kid: String, session: String, action: String, text: String?) async -> TeamControl.Delivery? {
        guard enabled, inTeam else { lastError = "not in a team"; return nil }
        let endpoints = reader?.members[kid]?.now?.endpoints
        let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, session: session, action: action, text: text,
                                          at: Int(Date().timeIntervalSince1970))
        let paths = self.paths, makeSecrets = self.makeSecrets, deliver = self.deliver
        do {
            let network = try await onDriveQueue { () -> TeamControl.Delivery? in
                guard let client = try Self.openClient(paths, makeSecrets()), let roster = client.roster?.doc else { throw TeamControl.DriveError.noRoster }
                return try deliver.withLock { d in
                    d.interfaces = InterfaceAddresses.ipv4()
                    return try TeamControl.Drive.network(command, identity: client.identity, roster: roster, endpoints: endpoints, deliver: &d)
                }
            }
            if let network { return network }
            return try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { throw TeamControl.DriveError.noRoster }
                return try TeamControl.Drive.store(command, client: client)
            }
        } catch {
            lastError = Self.mask(error)
            return nil
        }
    }

    func tail(kid: String, session: String, since: String?) async -> (lane: TeamControl.Lane, feed: SessionFeed)? {
        guard enabled else { return nil }
        let endpoints = reader?.members[kid]?.now?.endpoints
        let paths = self.paths, makeSecrets = self.makeSecrets, deliver = self.deliver
        return try? await onDriveQueue {
            guard let client = try Self.openClient(paths, makeSecrets()) else { return nil }
            guard let (lane, body) = try deliver.withLock({ d in
                d.interfaces = InterfaceAddresses.ipv4()
                return try TeamControl.Drive.tail(kid: kid, session: session, since: since, identity: client.identity, endpoints: endpoints, deliver: &d)
            }) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            guard let feed = try? dec.decode(SessionFeed.self, from: body) else { return nil }
            return (lane, feed)
        }
    }
```
`mask` gets two lines: `if let drive = error as? TeamControl.DriveError { switch drive { case .noRoster: return "not in a team"; case .unknownKid(let k): return "no teammate \(k)" } }`. (`OSAllocatedUnfairLock.withLock` rethrows; it does in the Mac module.)

- [ ] **Step 2: The window file**

`Sources/Infinitus/TeamSessionChatWindow.swift` — mirror `SessionChatWindow.swift`'s shape, keyed by `"\(kid)/\(session.id)"`:

```swift
import SwiftUI
import AppKit
import Combine
import InfinitusCore
import InfinitusUI

/// Driving a teammate's session (#220 §7.2, ruling 4): the Mac chat's
/// surface over the grantor's tail route, every control gated on the
/// capabilities they granted me, each command's lane + outcome inline.
/// One window per (kid, session), reused; content detached on close so
/// the 3 s tail poll stops with the window.
@MainActor
final class TeamSessionChatWindows: NSObject, NSWindowDelegate {
    static let shared = TeamSessionChatWindows()
    private var windows: [String: NSWindow] = [:]
    private var stores: [String: TeamSessionChatStore] = [:]

    func open(kid: String, session: TeamDocs.LiveSession, team: TeamModel) {
        let key = "\(kid)/\(session.id)"
        if let w = windows[key], w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let store = stores[key] ?? TeamSessionChatStore(kid: kid, session: session, team: team)
        stores[key] = store
        let host = NSHostingController(rootView: TeamSessionChatRoot(store: store, team: team))
        host.sizingOptions = []
        let w = windows[key] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("TeamSessionChat")
            w.center()
            w.delegate = self
            return w
        }()
        let frame = w.frame
        w.contentViewController = host
        if frame.width < 200 { w.setContentSize(NSSize(width: 560, height: 680)); w.center() } else { w.setFrame(frame, display: true) }
        w.title = "\(team.reader?.members[kid]?.name ?? kid) · \(session.name ?? session.project)"
        windows[key] = w
        store.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let key = windows.first(where: { $0.value == w })?.key else { return }
        w.contentViewController = nil
        stores[key]?.stop()
    }
}

@MainActor
final class TeamSessionChatStore: ObservableObject {
    let kid: String
    let session: TeamDocs.LiveSession
    @Published private(set) var feed: SessionFeed?
    @Published private(set) var lane: TeamControl.Lane?
    @Published private(set) var sending = false
    /// The last command's "via LAN · delivered" line, or the error.
    @Published private(set) var note: String?
    /// Store-lane commands waiting on the grantor's fetch, by id.
    @Published private(set) var pending: [String: String] = [:]   // id → action
    private weak var team: TeamModel?
    private var loop: Task<Void, Never>?
    private var acks: AnyCancellable?

    init(kid: String, session: TeamDocs.LiveSession, team: TeamModel) {
        self.kid = kid; self.session = session; self.team = team
    }

    var controls: Set<String> { team?.controls(grantedBy: kid) ?? [] }

    func start() {
        guard loop == nil, let team else { return }
        loop = Task { [weak self] in
            var since: String?
            while !Task.isCancelled {
                if let (lane, feed) = await team.tail(kid: self?.kid ?? "", session: self?.session.id ?? "", since: since) {
                    since = feed.stamp
                    self?.feed = feed; self?.lane = lane
                } else {
                    self?.lane = nil
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        // Store-lane acks arrive with the reader (each fetch).
        acks = team.$reader.receive(on: DispatchQueue.main).sink { [weak self] reader in
            guard let self, let reader, !pending.isEmpty else { return }
            for (id, action) in pending {
                guard let ack = reader.members[kid]?.acks[id] else { continue }
                pending[id] = nil
                note = "\(action) \(TeamControl.Lane.store.label) → \(ack.outcome)\(ack.detail.map { " — \($0)" } ?? "")"
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil; acks = nil }

    func drive(_ action: String, _ text: String? = nil) {
        guard let team, !sending else { return }
        sending = true
        Task {
            let d = await team.drive(kid: kid, session: session.id, action: action, text: text)
            sending = false
            guard let d else { note = team.lastError ?? "failed"; return }
            if d.lane == .store { pending[d.id] = action }
            note = "\(action) \(d.lane.label) → \(d.outcome)\(d.detail.map { " — \($0)" } ?? "")"
        }
    }
}
```
`TeamSessionChatRoot` (private struct): same layout as `SessionChatRoot` —
- header: session name/project, `feed?.status ?? session.status`, `lane == nil ? "no live tail (store only)" : lane.label`, and an **Interrupt** button (`store.drive(TeamGrants.key, "esc")`) `.disabled(!controls.contains("key")).help("needs the key grant")`.
- feed list: `SessionFeedRow(item:expandedPeers:) { _ in Image(systemName: "photo").foregroundStyle(.secondary) }` (images never leave the grantor's Mac).
- prompt bar via `FeedRows.pendingPrompt(store.feed)`: permission → **Deny** (`approve`, "deny") / **Allow** (`approve`, "allow"), gated on `approve`; question → numbered buttons `store.drive(TeamGrants.key, "\(i + 1)")` gated on `key`.
- toolbar row: mode `Menu` over `SessionStart.hookModes` → `store.drive(TeamGrants.mode, mode)` gated on `mode`; **Resume** → `store.drive(TeamGrants.resume, nil)` gated on `resume`.
- composer: TextField + send → `store.drive(TeamGrants.send, text)` gated on `send`, placeholder "Message \(name)'s session…"; the note line above it (`Label(note, systemImage: "arrow.turn.down.right")`, red when the outcome is one of `TeamControl.Outcome.refusals`).
- `.frame(minWidth: 400, minHeight: 360)`; `.reloadOnInjection()`.
Every gated control: `.disabled(!controls.contains(cap)).help(controls.contains(cap) ? "" : "needs the \(cap) grant")`.

- [ ] **Step 3: Member detail**

In `TeamMemberPane.body`, after the fleet section:
```swift
            if let m = member, let sessions = m.now?.sessions, !sessions.isEmpty, !team.controls(grantedBy: kid).isEmpty {
                Section {
                    ForEach(sessions, id: \.id) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name ?? s.project).bold()
                                Text("\(s.project) · \(s.status)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Drive…") { TeamSessionChatWindows.shared.open(kid: kid, session: s, team: team) }
                        }
                    }
                } header: { Text("Drive") } footer: {
                    Text("They let you \(team.controls(grantedBy: kid).sorted().joined(separator: ", ")). Commands go over LAN, a tunnel, or the store.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 4: Build, then a perf sanity**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error' ; echo built`. The e2e's idle gate (Task 5) covers the no-window idle; the window's poll is 1 request / 3 s only while open.

- [ ] **Step 5: Commit**

```bash
git add Sources/Infinitus/TeamModel.swift Sources/Infinitus/TeamSessionChatWindow.swift Sources/Infinitus/TeamMemberPane.swift
git commit -m "team control: drive a teammate's granted session from their detail — a chat window over their tail, every control gated on the grant, lane and outcome inline (#220 §7.2)"
```

---

### Task 5: CLI `send|approve|mode|tail|acks`, e2e drive step, release lines

**Files:**
- Modify: `Sources/InfinitusCLI/TeamControlCommand.swift`, `Sources/InfinitusCLI/TeamCommand.swift`, `tools/e2e.sh`, `CHANGELOG.md`, `README.md`, `site/public/index.html`, `site/public/llms.txt`

- [ ] **Step 1: CLI**

In `runTeamControl`: `guard let sub = args.first, ["grant", "revoke", "grants", "send", "approve", "mode", "tail", "acks"].contains(sub)`; the capability-flag branch becomes `if (sub == "grant" && capabilityFlags.contains(key)) || key == "json" || key == "follow"`. After the client opens, add:

```swift
        case "send", "approve", "mode":
            guard positional.count >= 2 else { return controlFail(teamUsage(), code: 2) }
            let (kid, session) = (positional[0], positional[1])
            let text: String?
            switch sub {
            case "send":
                let stdin = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stdin.isEmpty else { return controlFail("team send: the message comes on stdin", code: 2) }
                text = stdin
            case "approve":
                guard positional.count == 3, ["allow", "deny"].contains(positional[2]) else { return controlFail(teamUsage(), code: 2) }
                text = positional[2]
            default:
                guard positional.count == 3 else { return controlFail(teamUsage(), code: 2) }
                text = positional[2]
            }
            _ = try client.fetch()
            let endpoints = try TeamReader.load(client: client).members[kid]?.now?.endpoints
            var deliver = TeamControl.Deliver(http: controlHTTP, interfaces: InterfaceAddresses.ipv4())
            let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, session: session, action: sub, text: text,
                                              at: Int(Date().timeIntervalSince1970))
            emit(try TeamControl.Drive.send(command, client: client, endpoints: endpoints, deliver: &deliver))
        case "tail":
            guard positional.count >= 2 else { return controlFail(teamUsage(), code: 2) }
            let (kid, session) = (positional[0], positional[1])
            _ = try client.fetch()
            let endpoints = try TeamReader.load(client: client).members[kid]?.now?.endpoints
            var deliver = TeamControl.Deliver(http: controlHTTP, interfaces: InterfaceAddresses.ipv4())
            var since: String?
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            repeat {
                guard let (lane, body) = try TeamControl.Drive.tail(kid: kid, session: session, since: since, identity: client.identity, endpoints: endpoints, deliver: &deliver),
                      let feed = try? dec.decode(SessionFeed.self, from: body) else {
                    return controlFail("no live tail from \(kid) (no reachable endpoint, or no view grant)")
                }
                if since == nil { FileHandle.standardError.write(Data("# \(lane.label) · \(feed.status ?? "?")\n".utf8)) }
                if feed.stamp != since {
                    for item in feed.items { print("\(item.kind.rawValue)\t\(item.text.replacingOccurrences(of: "\n", with: "\n\t"))") }
                    since = feed.stamp
                }
                if flags.contains("follow") { Thread.sleep(forTimeInterval: 3) }
            } while flags.contains("follow")
        case "acks":
            _ = try client.fetch()
            let reader = try TeamReader.load(client: client)
            struct Row: Encodable { var id: String; var from: String; var outcome: String; var detail: String?; var at: Int }
            let rows = reader.members.values.flatMap { m in m.acks.values.map { Row(id: $0.id, from: m.kid, outcome: $0.outcome, detail: $0.detail, at: $0.at) } }
                .sorted { $0.at > $1.at }
            _ = try TeamControl.Store.driverReap(client: client, acks: reader.ackIDs)
            emit(rows)
```
`controlHTTP` — a private `TeamControl.Deliver.HTTP` at file scope, the semaphore shape of `TeamNearbyCommand.http` but taking `URL`, `headers`, `timeout`. `flags` gains `"follow"`. The `TeamGate` check stays on `grant|revoke` only (ruling 13).

Usage lines in `TeamCommand.teamUsage()` after `grants`:
```
      send <kid> <sessionId>                       drive: the message on stdin (LAN, tunnel, or the store on their next fetch)
      approve <kid> <sessionId> allow|deny         answer the prompt their session is showing
      mode <kid> <sessionId> <supervised|acceptEdits|bypassPermissions>
      tail <kid> <sessionId> [--follow]            their session's feed (needs the view grant; --follow polls every 3 s)
      acks                                         answers to my store-lane commands (and forgets the answered ones)
```

- [ ] **Step 2: e2e**

Replace the grantor block's closing `echo "team control: ok"` with the driver step:
```bash
# Driver (store lane, ruling 1): Ann grants Bo `send` on the live session;
# Bo's send finds no endpoint in Ann's now.json (no listener in mock
# mode) and lands in the store; Ann's next fetch executes it into the
# session's peer inbox and acks; Bo reads the ack. A capability Bo was
# NOT given is acked as a refusal.
ANN_KID="$("$CTL" team-status | json "d['kid']")"
"$CTL" team grant "$KID" --sessions e2e-aws --send | expect "d['capabilities']==['send']" || fail "ann grant"
ANN_GRANT="$("$CTL" team grants | json "d['grants'][0]['id']")"
printf 'hello from Bo via the store' | INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team send "$ANN_KID" e2e-aws \
    | expect "d['lane']=='store' and d['outcome']=='queued'" || fail "team send"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team mode "$ANN_KID" e2e-aws acceptEdits | expect "d['lane']=='store'" || fail "team mode"
"$CTL" team-fetch >/dev/null || fail "grantor fetch"
grep -q 'hello from Bo via the store' "$INBOX" || fail "the store command never reached the session (inbox: $(head -c 300 "$INBOX" 2>/dev/null))"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks \
    | expect "sorted(r['outcome'] for r in d)==['delivered','noGrant']" || fail "acks (got: $(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks | head -c 300))"
"$CTL" team revoke "$ANN_GRANT" | expect "d['removed']" || fail "ann revoke"
echo "team control: ok (grantor + store-lane driver)"
```
(`"$CTL" team grant` with no `INFINITUS_TEAM_DIR` override writes the app's team dir — the env is exported for both.)

- [ ] **Step 3: Release lines**

CHANGELOG `### Team (preview)` first bullet: `- Team: drive a teammate's granted session — from their member detail or `infinitusctl team send|approve|mode|tail` — over LAN, a tunnel, or the store on their next fetch.` README (Team section, after the grant bullet): `- **Drive a granted session** from a teammate's detail or the CLI; commands try LAN, then a tunnel, then wait in the store for their next fetch.` Site Team card: one sentence; llms.txt: one line.

- [ ] **Step 4: Verify**

1. `swift build --product infinitusctl && swift build --product Infinitus`
2. `swift test 2>&1 | tail -n 3` — 0 failures.
3. Tell Infi "e2e running (socket /tmp/drv.sock)", run `INFINITUS_CONTROL_SOCKET=/tmp/drv.sock tools/e2e.sh 2>&1 | tail -n 12` → `team control: ok (grantor + store-lane driver)` and `E2E PASS`; tell Infi "e2e done".

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCLI/TeamControlCommand.swift Sources/InfinitusCLI/TeamCommand.swift tools/e2e.sh CHANGELOG.md README.md site/public/index.html site/public/llms.txt
git commit -m "team control: infinitusctl team send|approve|mode|tail|acks, the store-lane drive in e2e, release lines (#220 §7.3)"
```

Then: merge `origin/main`, push `control-drive`, hand off "merge control-drive at <sha> — --merge", log the listener-based e2e idea and ruling 12 on #220.

## Self-review

- Spec coverage: §5.3 order + subnet gate + rendezvous cache + store ttl (Task 1, 2); grantor's store execution and ack on the next fetch (Task 2, 3); §7.2 controls, gating with `.help`, 3 s tail only on screen, lane + outcome (Task 4); §7.3 send/approve/mode/tail (Task 5); "via …" labels (`Lane.label`). Hostnames (§5.4, `team hostname …`) are PR 5. Phone (§7.4) is out of phase 1.
- Type consistency: `Deliver.exchange` returns `(lane, status, body)`; `Drive.network/store/send` return `Delivery`; `Drive.tail` returns `(lane, body)`; `Store.grantorPass` returns `[Audit]`; `Handled.contains/mark(StoreEntry)`; `TeamModel.drive` returns `Delivery?`, `tail` returns `(lane, feed)?` — used identically in Tasks 4–5.
