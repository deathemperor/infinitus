# Team session control — core (PR 2 of #220 phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The engine-independent core of delegated session control: grants, the command/ack envelopes and their store paths, endpoint publishing, replay and rate limiting, the verification pipeline, and the `/team/command` + tail routes as pure functions — all in InfinitusCore with tests, nothing mounted yet.

**Architecture:** Three new files beside the existing Team code: `TeamGrants` (the grantor's local policy, shaped like `TeamShares`), `TeamControl` (bodies, seal/open, verification, replay set, rate limit, endpoints) and `TeamControlRoute` (the HTTP routes as request → response functions, like `TeamNearby.respond`). Every dependency with IO — grants on disk, roster, live sessions, execution, the clock — is injected through an `Endpoint` struct of closures so the whole pipeline is testable without a Mac, a store or git. `TeamKinds` learns the three `control/` path shapes; `TeamDocs.Now` gains two optional hint blocks.

**Tech Stack:** Swift 5.10, swift-crypto (Ed25519, X25519, ChaChaPoly via the existing `Envelope`), XCTest. Builds on macOS and Linux (`swift build --product infinitusctl`, CI `linux` job).

**Spec:** `docs/superpowers/specs/2026-09-07-team-session-control-design.md` (§2 grants, §3 envelopes, §4 verification, §5.1 endpoints, §5.2 routes, §8 threat model, §9 tests). Correction to §3 folded in here: ack outcomes reuse `SessionInput.Reply.outcome` as it actually is — `delivered | running | captured | noSurface | noChannel | rejected` — plus the refusals.

## Global Constraints

- Everything is Swift; InfinitusCore compiles for macOS AND Linux (no AppKit, no Network.framework, no `os.Logger`). Run `swift build --product infinitusctl` before every commit.
- The grantor's Mac is the only authority: verification reads the LOCAL grants file at execution time; nothing here trusts a `now.json` hint.
- Default off: an empty `grants.json` (or none) makes every command `noGrant` and the route answer 404.
- Session identity is Claude Code's `sessionId`, never a pid; pids are resolved by the injected `liveSessions` closure at execution time.
- Secrets never in argv; nothing in this PR handles a secret except the tunnel token inside a `hostname` envelope body, which stays sealed.
- Surgical changes, existing style (4-space indent, `///` doc comments that say WHY, issue numbers in comments), no speculative abstractions. Every commit message ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the repo hook adds it; verify with `git log -1 --format=%B`).
- Tests are XCTest in `Tests/InfinitusCoreTests`, `@testable import InfinitusCore`, identities via `TeamIdentity.random()`, rosters built with `TeamRoster(id:name:createdAt:leaders:members:rev:)`. Run a single file with `swift test --filter <ClassName>`.
- Idle CPU ~0%: nothing in this PR starts a timer or a thread.

---

## File map

| file | responsibility |
|---|---|
| `Sources/InfinitusCore/Team/TeamGrants.swift` (new) | `Grant`, `TeamGrants` load/save/add/remove/`permits` |
| `Sources/InfinitusCore/Team/TeamControl.swift` (new) | `Command`, `Ack`, `Hostname` bodies; `seal*`/`open*`; `Outcome` strings; `rendezvousKey`; `Endpoints`; `SeenIDs` replay set; `RateLimit`; `Endpoint` (injected deps); `verify`; `execute` |
| `Sources/InfinitusCore/Team/TeamControlRoute.swift` (new) | `commandPath`, `tailPath(sessionId:)`, `tailHeader`, `signTail`/`checkTail`, `respond(_:endpoint:)` |
| `Sources/InfinitusCore/Team/TeamKinds.swift` (modify) | kinds `command`, `ack`, `hostname`; `expected(at:)` shapes under `control/` |
| `Sources/InfinitusCore/Team/TeamDocs.swift` (modify) | `Now.endpoints: Endpoints?`, `Now.grantsTo: [GrantHint]?` |
| `Tests/InfinitusCoreTests/TeamGrantsTests.swift` (new) | Task 1 |
| `Tests/InfinitusCoreTests/TeamControlTests.swift` (new) | Tasks 3–5 |
| `Tests/InfinitusCoreTests/TeamControlRouteTests.swift` (new) | Task 6 |
| `Tests/InfinitusCoreTests/TeamFleetDocTests.swift` (modify) | Task 2 adds path-shape assertions next to the existing `fleet.json` one |

---

### Task 1: TeamGrants

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamGrants.swift`
- Test: `Tests/InfinitusCoreTests/TeamGrantsTests.swift`

**Interfaces:**
- Consumes: `TeamRoster.ShareTarget` (`.leaders | .team | .members([kid])`), `TeamRoster.recipients(for:) -> [TeamKeys]`, `CanonicalJSON`.
- Produces:
  ```swift
  public struct TeamGrants: Codable, Equatable, Sendable {
      public struct Grant: Codable, Equatable, Sendable, Identifiable {
          public var id: String            // "g-" + 8 lowercase hex, minted by `add`
          public var audience: TeamRoster.ShareTarget
          public var sessions: Sessions     // .all | .some([sessionId])
          public var capabilities: Set<String>   // TeamGrants.capabilities members
          public var since: Int
      }
      public enum Sessions: Codable, Equatable, Sendable { case all, some([String]) }   // JSON: "all" | ["id", …]
      public static let view = "view", send = "send", approve = "approve", mode = "mode", resume = "resume", key = "key"
      public static let capabilities: [String]   // [view, send, approve, mode, resume, key]
      public static let driveCapabilities: [String]   // [send, approve, mode, resume, key]
      public var schema: Int   // 1
      public var grants: [Grant]
      public init()
      public static func file(teamDir: URL) -> URL          // <teamDir>/grants.json
      public static func load(teamDir: URL) -> TeamGrants   // empty when missing/unreadable
      public func save(teamDir: URL) throws
      @discardableResult public mutating func add(audience:sessions:capabilities:now:) -> Grant
      public mutating func remove(id: String) -> Bool
      public func permits(kid: String, session: String, capability: String, roster: TeamRoster) -> Grant?
      public var hints: [TeamDocs.GrantHint]   // for now.json (Task 3 defines GrantHint)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InfinitusCore

final class TeamGrantsTests: XCTestCase {
    let leader = TeamIdentity.random()
    let member = TeamIdentity.random()
    let other = TeamIdentity.random()
    let stranger = TeamIdentity.random()

    func roster(leaders: [TeamIdentity], members: [TeamIdentity]) -> TeamRoster {
        TeamRoster(id: "team-1", name: "Papaya", createdAt: 100,
                   leaders: leaders.map { TeamRoster.Member(keys: $0.keys, name: "L", since: 100, founder: true) },
                   members: members.map { TeamRoster.Member(keys: $0.keys, name: "M", since: 200) },
                   rev: 1)
    }

    func testAudienceFollowsTheRosterAndStrangersNeverMatch() {
        var grants = TeamGrants()
        grants.add(audience: .leaders, sessions: .all, capabilities: [TeamGrants.send], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: leader.kid, session: "s1", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.send, roster: r), "not a leader")
        // The roster moves: a promoted member now matches "leaders" without touching the grant.
        let promoted = roster(leaders: [leader, member], members: [])
        XCTAssertNotNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.send, roster: promoted))
        XCTAssertNil(grants.permits(kid: stranger.kid, session: "s1", capability: TeamGrants.send, roster: promoted))
        // Named kids: only those, whatever their role; a kid no longer in the roster never matches.
        var named = TeamGrants()
        named.add(audience: .members([other.kid]), sessions: .all, capabilities: [TeamGrants.view], now: 300)
        XCTAssertNil(named.permits(kid: other.kid, session: "s1", capability: TeamGrants.view, roster: r), "other is not in this roster")
        XCTAssertNotNil(named.permits(kid: other.kid, session: "s1", capability: TeamGrants.view,
                                      roster: roster(leaders: [leader], members: [member, other])))
        XCTAssertNil(named.permits(kid: leader.kid, session: "s1", capability: TeamGrants.view, roster: r), "leaders only when named")
    }

    func testSessionsAndCapabilitiesAreExactSubsets() {
        var grants = TeamGrants()
        grants.add(audience: .team, sessions: .some(["s1", "s2"]), capabilities: [TeamGrants.send, TeamGrants.view], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: member.kid, session: "s2", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s3", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.approve, roster: r), "send does not imply approve")
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: "reboot", roster: r), "unknown capability never matches")
        // Two grants: the first that permits wins; removing it falls through to none.
        let g = grants.add(audience: .members([member.kid]), sessions: .all, capabilities: [TeamGrants.approve], now: 301)
        XCTAssertEqual(grants.permits(kid: member.kid, session: "s9", capability: TeamGrants.approve, roster: r)?.id, g.id)
        XCTAssertTrue(grants.remove(id: g.id))
        XCTAssertFalse(grants.remove(id: g.id))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s9", capability: TeamGrants.approve, roster: r))
    }

    func testFileRoundTripAndEmptyDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [], "missing file is no grants")
        var grants = TeamGrants()
        grants.add(audience: .members([member.kid]), sessions: .some(["s1"]), capabilities: [TeamGrants.send], now: 300)
        try grants.save(teamDir: dir)
        XCTAssertEqual(TeamGrants.load(teamDir: dir), grants)
        let json = String(decoding: try Data(contentsOf: TeamGrants.file(teamDir: dir)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sessions\":[\"s1\"]"), json)
        XCTAssertTrue(json.contains("\"audience\":[\"\(member.kid)\"]"), json)
        var all = TeamGrants()
        all.add(audience: .team, sessions: .all, capabilities: [TeamGrants.view], now: 1)
        let allJSON = String(decoding: try CanonicalJSON.encode(all), as: UTF8.self)
        XCTAssertTrue(allJSON.contains("\"sessions\":\"all\""), allJSON)
        XCTAssertEqual(try CanonicalJSON.decode(TeamGrants.self, from: Data(allJSON.utf8)), all)
        // Garbage on disk reads as empty, never throws.
        try Data("{".utf8).write(to: TeamGrants.file(teamDir: dir))
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [])
    }

    func testHintsCarryNoIdsAndKeepOrder() {
        var grants = TeamGrants()
        grants.add(audience: .leaders, sessions: .all, capabilities: [TeamGrants.view, TeamGrants.send], now: 1)
        grants.add(audience: .members(["k1"]), sessions: .some(["s1"]), capabilities: [TeamGrants.key], now: 2)
        let hints = grants.hints
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints[0].audience, .leaders)
        XCTAssertEqual(hints[0].capabilities, ["send", "view"], "sorted for a stable now.json")
        XCTAssertEqual(hints[1].sessions, ["s1"])
        XCTAssertNil(hints[0].sessions, "all is nil in the hint")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TeamGrantsTests`
Expected: compile error — `TeamGrants` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Spec #220 §2: who may do what to which of MY sessions. Lives on the
/// grantor's machine only (`<teamDir>/grants.json`) and is read at
/// execution time, so revoking is deleting the entry — nothing to
/// propagate, the next command fails `noGrant`. `hints` is the copy
/// that goes into `now.json` so teammates can draw controls; readers
/// treat it as a hint, this file decides.
public struct TeamGrants: Codable, Equatable, Sendable {
    public static let view = "view"
    public static let send = "send"
    public static let approve = "approve"
    public static let mode = "mode"
    public static let resume = "resume"
    public static let key = "key"
    /// `view` reads the live tail; the rest are `SessionInput.Request.Kind`
    /// names — a grant that lists `send` only cannot answer a prompt.
    public static let driveCapabilities = [send, approve, mode, resume, key]
    public static let capabilities = [view] + driveCapabilities

    /// `"all"` or a list of Claude Code session ids (never pids: the id
    /// is stable for a transcript, the pid is resolved at execution).
    public enum Sessions: Codable, Equatable, Sendable {
        case all
        case some([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let word = try? c.decode(String.self), word == "all" { self = .all; return }
            self = .some(try c.decode([String].self))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .all: try c.encode("all")
            case .some(let ids): try c.encode(ids)
            }
        }
        func contains(_ id: String) -> Bool {
            switch self {
            case .all: return true
            case .some(let ids): return ids.contains(id)
            }
        }
    }

    public struct Grant: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var audience: TeamRoster.ShareTarget
        public var sessions: Sessions
        public var capabilities: Set<String>
        public var since: Int
        public init(id: String, audience: TeamRoster.ShareTarget, sessions: Sessions, capabilities: Set<String>, since: Int) {
            self.id = id; self.audience = audience; self.sessions = sessions; self.capabilities = capabilities; self.since = since
        }
    }

    public var schema = 1
    public var grants: [Grant] = []

    public init() {}

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("grants.json") }

    /// Missing or unreadable is "no grants" — the safe reading (#220: default off).
    public static func load(teamDir: URL) -> TeamGrants {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamGrants.self, from: $0) }
            ?? TeamGrants()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }

    @discardableResult
    public mutating func add(audience: TeamRoster.ShareTarget, sessions: Sessions, capabilities: Set<String>,
                             now: Int = Int(Date().timeIntervalSince1970)) -> Grant {
        let id = "g-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let grant = Grant(id: id, audience: audience, sessions: sessions,
                          capabilities: capabilities.intersection(Self.capabilities), since: now)
        grants.append(grant)
        return grant
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = grants.count
        grants.removeAll { $0.id == id }
        return grants.count != before
    }

    /// The first grant that lets `kid` do `capability` to `session`, or nil.
    /// Audience resolves through the roster AS IT IS NOW: "leaders"
    /// follows promotions, a removed kid never matches, and a named kid
    /// must still be in the roster (spec §2).
    public func permits(kid: String, session: String, capability: String, roster: TeamRoster) -> Grant? {
        grants.first { grant in
            grant.capabilities.contains(capability)
                && grant.sessions.contains(session)
                && roster.recipients(for: grant.audience).contains { $0.kid == kid }
        }
    }

    /// The `now.json` copy: no ids, capabilities sorted, `all` as nil.
    public var hints: [TeamDocs.GrantHint] {
        grants.map { grant in
            let sessions: [String]?
            switch grant.sessions {
            case .all: sessions = nil
            case .some(let ids): sessions = ids
            }
            return TeamDocs.GrantHint(audience: grant.audience, sessions: sessions, capabilities: grant.capabilities.sorted())
        }
    }
}
```

`TeamDocs.GrantHint` is defined in Task 3; for this task to compile alone, add it now to `Sources/InfinitusCore/Team/TeamDocs.swift` inside `enum TeamDocs` (Task 3 wires it into `Now`):

```swift
    /// A grantor's hint of who may drive which sessions (#220 §2); the
    /// grantor's own grants file decides, this only draws controls.
    public struct GrantHint: Codable, Equatable, Sendable {
        public var audience: TeamRoster.ShareTarget
        /// nil = every session.
        public var sessions: [String]?
        public var capabilities: [String]
        public init(audience: TeamRoster.ShareTarget, sessions: [String]?, capabilities: [String]) {
            self.audience = audience; self.sessions = sessions; self.capabilities = capabilities
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TeamGrantsTests`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Linux-safe build and commit**

Run: `swift build --product infinitusctl 2>&1 | grep -E 'error|Build complete'`
Expected: `Build complete!`

```bash
git add Sources/InfinitusCore/Team/TeamGrants.swift Sources/InfinitusCore/Team/TeamDocs.swift Tests/InfinitusCoreTests/TeamGrantsTests.swift
git commit -m "team control: TeamGrants — who may drive which of my sessions, read at execution time (#220)"
```

---

### Task 2: control path shapes in TeamKinds

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamKinds.swift` (constants after `fleet`; two new `case`s in `expected(at:)`)
- Test: `Tests/InfinitusCoreTests/TeamFleetDocTests.swift` (add one test method beside the `fleet.json` assertion)

**Interfaces:**
- Produces: `TeamKinds.command = "command"`, `TeamKinds.ack = "ack"`, `TeamKinds.hostname = "hostname"`, `TeamKinds.controlKinds = [command, ack, hostname]`; `expected(at:)` answers `(owner, command)` for `m/<kid>/control/commands/<id>.json`, `(owner, ack)` for `m/<kid>/control/acks/<id>.json`, `(owner, hostname)` for `m/<kid>/control/hostnames/<kid>.json`.
- Note: these are NOT added to `memberKinds` — that list drives the publisher's share table; control envelopes are addressed, never audience-shared.

- [ ] **Step 1: Write the failing test** (append to `TeamFleetDocTests`)

```swift
    func testControlPathsNameTheirKindAndOwner() {
        XCTAssertEqual(TeamKinds.expected(at: "m/k/control/commands/abc.json")?.kind, TeamKinds.command)
        XCTAssertEqual(TeamKinds.expected(at: "m/k/control/commands/abc.json")?.from, "k")
        XCTAssertEqual(TeamKinds.expected(at: "m/k/control/acks/abc.json")?.kind, TeamKinds.ack)
        XCTAssertEqual(TeamKinds.expected(at: "m/leader/control/hostnames/member.json")?.kind, TeamKinds.hostname)
        XCTAssertNil(TeamKinds.expected(at: "m/k/control/commands/abc.txt"))
        XCTAssertNil(TeamKinds.expected(at: "m/k/control/other/abc.json"))
        XCTAssertNil(TeamKinds.expected(at: "roster/control/commands/abc.json"), "no control under roster/")
        // A command replayed under another member's branch is a sender mismatch, as for every kind.
        XCTAssertThrowsError(try TeamKinds.check(kind: TeamKinds.command, from: "k", at: "m/other/control/commands/abc.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .senderMismatch)
        }
        XCTAssertThrowsError(try TeamKinds.check(kind: TeamKinds.ack, from: "k", at: "m/k/control/commands/abc.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TeamFleetDocTests/testControlPathsNameTheirKindAndOwner`
Expected: compile error — `TeamKinds.command` does not exist.

- [ ] **Step 3: Implement**

In `TeamKinds`, after `public static let fleet = "fleet"`:

```swift
    /// `m/<kid>/control/…` — addressed envelopes for delegated session
    /// control (#220 §3): a driver's commands, a grantor's acks, a
    /// leader's minted hostnames. Not in `memberKinds`: they are sealed
    /// to one reader each, never to an audience.
    public static let command = "command"
    public static let ack = "ack"
    public static let hostname = "hostname"
    public static let controlKinds = [command, ack, hostname]
```

In `expected(at:)`'s `switch parts.count`, before `default:`:

```swift
        case 3 where parts[0] == "control" && parts[2].hasSuffix(".json") && owner != nil:
            switch parts[1] {
            case "commands": return (owner, command)
            case "acks": return (owner, ack)
            case "hostnames": return (owner, hostname)
            default: return nil
            }
```

(`owner != nil` keeps `roster/control/…` unrecognised.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TeamFleetDocTests`
Expected: all pass, including the existing shape tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Team/TeamKinds.swift Tests/InfinitusCoreTests/TeamFleetDocTests.swift
git commit -m "team control: the control/ path shapes — commands, acks, hostnames — are kinds the store checks (#220)"
```

---

### Task 3: envelopes, outcomes, endpoints, rendezvous key

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamControl.swift`
- Modify: `Sources/InfinitusCore/Team/TeamDocs.swift` (`Now` gains `endpoints` and `grantsTo`, both optional with defaults so every existing `Now(...)` call and every older `now.json` still decodes)
- Test: `Tests/InfinitusCoreTests/TeamControlTests.swift`

**Interfaces:**
- Consumes: `Envelope.seal(_:kind:from:to:at:)`, `Envelope.open(_:as:senderKey:)`, `Envelope.header(of:)`, `TeamIdentity`, `TeamKeys`, `SHA256.hex` (internal, in MirrorRendezvous.swift), `TeamGrants`.
- Produces:
  ```swift
  public enum TeamControl {
      public static let defaultTTL = 120, maxTTL = 600, storeTTL = 600, maxFutureSkew = 300
      public struct Command: Codable, Equatable, Sendable { schema=1, id, to, session, action, text: String?, at: Int, ttl: Int }
      public struct Ack: Codable, Equatable, Sendable { schema=1, id, outcome, detail: String?, at }
      public struct Hostname: Codable, Equatable, Sendable { schema=1, hostname, token, at }
      public enum Outcome { static let delivered, running, captured, noSurface, noChannel, rejected,
                            noGrant, notLive, expired, replayed, unknownSender, badRequest, rateLimited: String
                            static let refusals: Set<String> }
      public static func sealCommand(_:from:to:at:) throws -> Data      // Envelope kind "command", sealed to one TeamKeys
      public static func sealAck(_:from:to:at:) throws -> Data
      public static func sealHostname(_:from:to:at:) throws -> Data
      public static func openCommand(_:as:senderKey:) throws -> (Envelope.Header, Command)
      public static func openAck(_:as:senderKey:) throws -> (Envelope.Header, Ack)
      public static func openHostname(_:as:senderKey:) throws -> (Envelope.Header, Hostname)
      public static func commandPath(driver:id:) -> String             // m/<driver>/control/commands/<id>.json
      public static func ackPath(grantor:id:) -> String
      public static func hostnamePath(leader:member:) -> String
      public static func rendezvousKey(team:kid:) -> String            // 64 hex
      public struct Endpoints: Codable, Equatable, Sendable { lan: String?, hostname: String?, rendezvous: String? }
  }
  TeamDocs.Now.endpoints: TeamControl.Endpoints?     // default nil
  TeamDocs.Now.grantsTo: [TeamDocs.GrantHint]?        // default nil
  ```
- `Command.id` is validated by `openCommand` as 8–64 chars of `[a-z0-9-]` (it becomes a store path segment); anything else throws `Envelope.EnvelopeError.malformed`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InfinitusCore

final class TeamControlTests: XCTestCase {
    let grantor = TeamIdentity.random()
    let driver = TeamIdentity.random()
    let eve = TeamIdentity.random()

    func lookup(_ kid: String) -> TeamKeys? { [grantor, driver, eve].first { $0.kid == kid }?.keys }

    func command(id: String = "c-0123456789", session: String = "s1", action: String = TeamGrants.send,
                 text: String? = "hello", at: Int = 1_000, ttl: Int = 120) -> TeamControl.Command {
        TeamControl.Command(id: id, to: grantor.kid, session: session, action: action, text: text, at: at, ttl: ttl)
    }

    // MARK: Task 3

    func testCommandSealsToTheGrantorOnlyAndRoundTrips() throws {
        let cmd = command()
        let file = try TeamControl.sealCommand(cmd, from: driver, to: grantor.keys, at: 1_000)
        let header = try Envelope.header(of: file)
        XCTAssertEqual(header.kind, TeamKinds.command)
        XCTAssertEqual(Set(header.to.map(\.kid)), [driver.kid, grantor.kid])
        let (h, body) = try TeamControl.openCommand(file, as: grantor, senderKey: lookup)
        XCTAssertEqual(h.from, driver.kid)
        XCTAssertEqual(body, cmd)
        XCTAssertThrowsError(try TeamControl.openCommand(file, as: eve, senderKey: lookup)) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .notARecipient)
        }
        // An ack sealed under the command kind is refused by the opener: kinds are not interchangeable.
        let ackFile = try TeamControl.sealAck(TeamControl.Ack(id: cmd.id, outcome: TeamControl.Outcome.delivered, detail: nil, at: 1_001),
                                              from: grantor, to: driver.keys, at: 1_001)
        XCTAssertThrowsError(try TeamControl.openCommand(ackFile, as: driver, senderKey: lookup))
        let (_, ack) = try TeamControl.openAck(ackFile, as: driver, senderKey: lookup)
        XCTAssertEqual(ack.outcome, "delivered")
    }

    func testCommandIdsAreStorePathSafe() throws {
        for bad in ["", "short", "has/slash", "UPPER-0123456", String(repeating: "a", count: 65), "../../x-0123"] {
            let file = try TeamControl.sealCommand(command(id: bad), from: driver, to: grantor.keys, at: 1_000)
            XCTAssertThrowsError(try TeamControl.openCommand(file, as: grantor, senderKey: lookup), bad) {
                XCTAssertEqual($0 as? Envelope.EnvelopeError, .malformed)
            }
        }
        XCTAssertEqual(TeamControl.commandPath(driver: "d", id: "c-0123456789"), "m/d/control/commands/c-0123456789.json")
        XCTAssertEqual(TeamControl.ackPath(grantor: "g", id: "c-0123456789"), "m/g/control/acks/c-0123456789.json")
        XCTAssertEqual(TeamControl.hostnamePath(leader: "l", member: "m"), "m/l/control/hostnames/m.json")
        // Every path the helpers mint is a shape TeamKinds accepts for that kind and sender.
        XCTAssertNoThrow(try TeamKinds.check(kind: TeamKinds.command, from: "d", at: TeamControl.commandPath(driver: "d", id: "c-0123456789")))
        XCTAssertNoThrow(try TeamKinds.check(kind: TeamKinds.hostname, from: "l", at: TeamControl.hostnamePath(leader: "l", member: "m")))
    }

    func testRendezvousKeyIsDerivableAndDistinct() {
        let a = TeamControl.rendezvousKey(team: "team-1", kid: "k1")
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(a, TeamControl.rendezvousKey(team: "team-1", kid: "k1"), "deterministic: any roster member derives it")
        XCTAssertNotEqual(a, TeamControl.rendezvousKey(team: "team-2", kid: "k1"))
        XCTAssertNotEqual(a, TeamControl.rendezvousKey(team: "team-1", kid: "k2"))
        XCTAssertNotEqual(a, MirrorRendezvous.key(token: "team-1|k1"), "never collides with a pairing key")
    }

    func testNowCarriesEndpointsAndGrantHintsOptionally() throws {
        let plain = TeamDocs.Now(at: 1, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:])
        let bytes = try CanonicalJSON.encode(plain)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("endpoints"), "absent, not null: older readers stay byte-identical")
        var full = plain
        full.endpoints = TeamControl.Endpoints(lan: "192.168.1.20:47824", hostname: nil, rendezvous: String(repeating: "a", count: 64))
        full.grantsTo = [TeamDocs.GrantHint(audience: .leaders, sessions: nil, capabilities: ["send"])]
        let again = try CanonicalJSON.decode(TeamDocs.Now.self, from: try CanonicalJSON.encode(full))
        XCTAssertEqual(again, full)
        // A now.json from before this field decodes with nils.
        XCTAssertNil(try CanonicalJSON.decode(TeamDocs.Now.self, from: bytes).endpoints)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TeamControlTests`
Expected: compile error — `TeamControl` does not exist.

- [ ] **Step 3: Implement**

`Sources/InfinitusCore/Team/TeamControl.swift`:

```swift
import Foundation

/// Delegated session control (#220 §3–§4): the envelopes a driver and a
/// grantor exchange, and the pipeline the grantor runs before anything
/// reaches a session. Pure: every dependency with IO is injected
/// through `Endpoint` (Task 5), so the whole thing is tested without a
/// Mac, a store or git, and mounts on the Linux tray unchanged.
public enum TeamControl {
    public static let defaultTTL = 120
    public static let maxTTL = 600
    /// The store lane's TTL: the grantor's fetch cadence (≤ 5 min) must not expire it.
    public static let storeTTL = 600
    /// A command "from the future" beyond this is a bad clock or a forgery.
    public static let maxFutureSkew = 300

    /// One action on one session, sealed by the driver to the grantor.
    public struct Command: Codable, Equatable, Sendable {
        public var schema = 1
        /// Minted by the driver; a store path segment, so `[a-z0-9-]{8,64}`.
        public var id: String
        /// The grantor's kid — sealed AND addressed, so a command sealed to
        /// me but naming someone else is refused.
        public var to: String
        public var session: String
        /// A `TeamGrants.driveCapabilities` member (= `SessionInput.Request.Kind`).
        public var action: String
        public var text: String?
        public var at: Int
        public var ttl: Int
        public init(id: String, to: String, session: String, action: String, text: String?, at: Int, ttl: Int = TeamControl.defaultTTL) {
            self.id = id; self.to = to; self.session = session; self.action = action; self.text = text; self.at = at; self.ttl = ttl
        }
    }

    /// The grantor's answer, sealed to the driver.
    public struct Ack: Codable, Equatable, Sendable {
        public var schema = 1
        public var id: String
        public var outcome: String
        public var detail: String?
        public var at: Int
        public init(id: String, outcome: String, detail: String?, at: Int) {
            self.id = id; self.outcome = outcome; self.detail = detail; self.at = at
        }
    }

    /// A leader's minted tunnel for a member (§5.4), sealed to the member.
    public struct Hostname: Codable, Equatable, Sendable {
        public var schema = 1
        public var hostname: String
        public var token: String
        public var at: Int
        public init(hostname: String, token: String, at: Int) { self.hostname = hostname; self.token = token; self.at = at }
    }

    /// `Ack.outcome`: `SessionInput.Reply.outcome` as it is, plus the refusals.
    public enum Outcome {
        public static let delivered = "delivered"
        public static let running = "running"
        public static let captured = "captured"
        public static let noSurface = "noSurface"
        public static let noChannel = "noChannel"
        public static let rejected = "rejected"
        public static let noGrant = "noGrant"
        public static let notLive = "notLive"
        public static let expired = "expired"
        public static let replayed = "replayed"
        public static let unknownSender = "unknownSender"
        public static let badRequest = "badRequest"
        public static let rateLimited = "rateLimited"
        public static let refusals: Set<String> = [noGrant, notLive, expired, replayed, unknownSender, badRequest, rateLimited]
    }

    // MARK: envelopes

    public static func sealCommand(_ command: Command, from driver: TeamIdentity, to grantor: TeamKeys,
                                   at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(command), kind: TeamKinds.command, from: driver, to: [grantor], at: at)
    }

    public static func sealAck(_ ack: Ack, from grantor: TeamIdentity, to driver: TeamKeys,
                               at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(ack), kind: TeamKinds.ack, from: grantor, to: [driver], at: at)
    }

    public static func sealHostname(_ hostname: Hostname, from leader: TeamIdentity, to member: TeamKeys,
                                    at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(hostname), kind: TeamKinds.hostname, from: leader, to: [member], at: at)
    }

    public static func openCommand(_ file: Data, as me: TeamIdentity,
                                   senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Command) {
        let (header, body) = try open(file, kind: TeamKinds.command, as: me, senderKey: senderKey)
        let command = try decode(Command.self, body)
        guard isPathSafeID(command.id) else { throw Envelope.EnvelopeError.malformed }
        return (header, command)
    }

    public static func openAck(_ file: Data, as me: TeamIdentity,
                               senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Ack) {
        let (header, body) = try open(file, kind: TeamKinds.ack, as: me, senderKey: senderKey)
        return (header, try decode(Ack.self, body))
    }

    public static func openHostname(_ file: Data, as me: TeamIdentity,
                                    senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Hostname) {
        let (header, body) = try open(file, kind: TeamKinds.hostname, as: me, senderKey: senderKey)
        return (header, try decode(Hostname.self, body))
    }

    /// Kinds are not interchangeable: an ack presented as a command is malformed.
    private static func open(_ file: Data, kind: String, as me: TeamIdentity,
                             senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Data) {
        let (header, body) = try Envelope.open(file, as: me, senderKey: senderKey)
        guard header.kind == kind else { throw Envelope.EnvelopeError.malformed }
        return (header, body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do { return try CanonicalJSON.decode(type, from: body) } catch { throw Envelope.EnvelopeError.malformed }
    }

    /// `[a-z0-9-]{8,64}`: the id becomes `…/commands/<id>.json`.
    static func isPathSafeID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" }
    }

    // MARK: store paths

    public static func commandPath(driver: String, id: String) -> String { "m/\(driver)/control/commands/\(id).json" }
    public static func ackPath(grantor: String, id: String) -> String { "m/\(grantor)/control/acks/\(id).json" }
    public static func hostnamePath(leader: String, member: String) -> String { "m/\(leader)/control/hostnames/\(member).json" }

    // MARK: endpoints

    /// Where a grantor's Mac answers (§5.1), published in `now.json` as a
    /// hint. `rendezvous` is the key its quick-tunnel URL sits under on
    /// infinitus.run; any roster member derives it, and the URL alone
    /// opens nothing.
    public struct Endpoints: Codable, Equatable, Sendable {
        public var lan: String?
        public var hostname: String?
        public var rendezvous: String?
        public init(lan: String?, hostname: String?, rendezvous: String?) {
            self.lan = lan; self.hostname = hostname; self.rendezvous = rendezvous
        }
    }

    /// Distinct from the pairing key (`MirrorRendezvous.key(token:)`) by the
    /// label: a team id and kid are public to the roster, a pairing token is not.
    public static func rendezvousKey(team: String, kid: String) -> String {
        SHA256.hex(Array("team-control|\(team)|\(kid)".utf8))
    }
}
```

In `TeamDocs.Now`, after `sharesTo`:

```swift
        /// #220 §5.1 / §2 — hints; absent in docs from before them. Left
        /// out of the memberwise init so every existing caller compiles
        /// and older readers see byte-identical documents.
        public var endpoints: TeamControl.Endpoints?
        public var grantsTo: [GrantHint]?
```

(Swift's synthesized Codable decodes a missing optional as nil and `CanonicalJSON`'s `JSONEncoder` omits nil optionals, which the test asserts.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'TeamControlTests|TeamSnapshotTests|TeamInsightsTests'`
Expected: all pass (the two existing suites prove `Now` still round-trips).

- [ ] **Step 5: Build for the CLI and commit**

Run: `swift build --product infinitusctl 2>&1 | grep -E 'error|Build complete'`

```bash
git add Sources/InfinitusCore/Team/TeamControl.swift Sources/InfinitusCore/Team/TeamDocs.swift Tests/InfinitusCoreTests/TeamControlTests.swift
git commit -m "team control: command, ack and hostname envelopes, store paths, endpoints hint, rendezvous key (#220)"
```

---

### Task 4: replay set and rate limit

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamControl.swift` (append two types)
- Test: `Tests/InfinitusCoreTests/TeamControlTests.swift` (append)

**Interfaces:**
- Produces:
  ```swift
  extension TeamControl {
      public struct SeenIDs: Codable, Equatable, Sendable {
          public var expiry: [String: Int]          // id → unix seconds after which it can be forgotten
          public init()
          public static func file(teamDir: URL) -> URL   // <teamDir>/control-seen.json
          public static func load(teamDir: URL) -> SeenIDs
          public func save(teamDir: URL) throws
          /// true when `id` was NOT seen (and records it until `until`); prunes anything expired at `now`.
          public mutating func admit(_ id: String, until: Int, now: Int) -> Bool
      }
      public struct RateLimit: Equatable, Sendable {
          public static let commands = 5, window: TimeInterval = 10
          public init()
          /// true when `kid` may send one more command at `now`.
          public mutating func allow(kid: String, now: Date) -> Bool
      }
  }
  ```

- [ ] **Step 1: Write the failing tests** (append inside `TeamControlTests`)

```swift
    // MARK: Task 4

    func testSeenIDsAdmitOnceUntilExpiryThenForget() throws {
        var seen = TeamControl.SeenIDs()
        XCTAssertTrue(seen.admit("c-0000000001", until: 1_120, now: 1_000))
        XCTAssertFalse(seen.admit("c-0000000001", until: 1_120, now: 1_010), "a replay inside the TTL")
        XCTAssertTrue(seen.admit("c-0000000002", until: 1_050, now: 1_010))
        // Past its expiry the id is pruned — and a late replay of it is refused anyway by `expired` (Task 5), not here.
        XCTAssertTrue(seen.admit("c-0000000003", until: 1_200, now: 1_130))
        XCTAssertEqual(Set(seen.expiry.keys), ["c-0000000003"], "both earlier ids expired by 1_130")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try seen.save(teamDir: dir)
        XCTAssertEqual(TeamControl.SeenIDs.load(teamDir: dir), seen)
        XCTAssertEqual(TeamControl.SeenIDs.load(teamDir: dir.appendingPathComponent("nope")).expiry, [:])
    }

    func testRateLimitIsPerDriverOverASlidingWindow() {
        var limit = TeamControl.RateLimit()
        let t0 = Date(timeIntervalSince1970: 2_000)
        for i in 0..<TeamControl.RateLimit.commands {
            XCTAssertTrue(limit.allow(kid: "a", now: t0.addingTimeInterval(Double(i))), "command \(i)")
        }
        XCTAssertFalse(limit.allow(kid: "a", now: t0.addingTimeInterval(5)), "the sixth inside 10 s")
        XCTAssertTrue(limit.allow(kid: "b", now: t0.addingTimeInterval(5)), "another driver has its own bucket")
        XCTAssertTrue(limit.allow(kid: "a", now: t0.addingTimeInterval(10.5)), "the first one slid out of the window")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TeamControlTests`
Expected: compile error — `SeenIDs` does not exist.

- [ ] **Step 3: Implement** (append to `TeamControl.swift`)

```swift
extension TeamControl {
    /// Command ids already executed, kept for their TTL (§4 step 4): a
    /// stolen command file replays nowhere. Persisted so a relaunch
    /// inside a TTL does not reopen the window.
    public struct SeenIDs: Codable, Equatable, Sendable {
        public var expiry: [String: Int] = [:]
        public init() {}

        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("control-seen.json") }

        public static func load(teamDir: URL) -> SeenIDs {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(SeenIDs.self, from: $0) } ?? SeenIDs()
        }

        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }

        /// true = not seen before (now recorded until `until`).
        public mutating func admit(_ id: String, until: Int, now: Int) -> Bool {
            expiry = expiry.filter { $0.value > now }
            if expiry[id] != nil { return false }
            expiry[id] = until
            return true
        }
    }

    /// Per-driver token bucket (§4 step 7): `commands` per `window`.
    /// In memory only — a relaunch resets it, which is fine.
    public struct RateLimit: Equatable, Sendable {
        public static let commands = 5
        public static let window: TimeInterval = 10
        private var stamps: [String: [Date]] = [:]
        public init() {}

        public mutating func allow(kid: String, now: Date) -> Bool {
            let recent = (stamps[kid] ?? []).filter { now.timeIntervalSince($0) < Self.window }
            guard recent.count < Self.commands else { stamps[kid] = recent; return false }
            stamps[kid] = recent + [now]
            return true
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TeamControlTests`
Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Team/TeamControl.swift Tests/InfinitusCoreTests/TeamControlTests.swift
git commit -m "team control: single-use command ids for their TTL, five commands per ten seconds per driver (#220)"
```

---

### Task 5: verification pipeline and execution

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamControl.swift` (append `Endpoint`, `Verified`, `verify`, `handle`)
- Test: `Tests/InfinitusCoreTests/TeamControlTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1, 3, 4; `TeamRoster.keys(for:at:)`; `SessionInput.Reply` (outcome/detail).
- Produces:
  ```swift
  extension TeamControl {
      /// Everything the pipeline needs, injected (§4). All closures may run off the main actor.
      public struct Endpoint {
          public var identity: TeamIdentity
          public var roster: () -> TeamRoster?
          public var grants: () -> TeamGrants
          /// sessionId → live pid; empty when nothing is live.
          public var liveSessions: () -> [String: Int32]
          /// Runs the action; only called after every check passed.
          public var execute: (_ action: String, _ text: String?, _ pid: Int32) -> SessionInput.Reply
          public var seen: SeenIDs
          public var limit: RateLimit
          public var now: () -> Date
          public init(identity:roster:grants:liveSessions:execute:seen:limit:now:)
      }
      public struct Verified: Equatable { public var header: Envelope.Header; public var command: Command; public var pid: Int32; public var grant: TeamGrants.Grant }
      public enum Refusal: Error, Equatable { case outcome(String, detail: String?) }
      /// Steps 1–7 of §4 in order; mutates `endpoint.seen` / `.limit`.
      public static func verify(_ file: Data, endpoint: inout Endpoint) -> Result<Verified, Refusal>
      /// verify + execute → the Ack to seal back, and the audit record.
      public struct Audit: Equatable, Sendable { public var driver: String; public var session: String; public var action: String; public var outcome: String; public var detail: String? }
      public static func handle(_ file: Data, endpoint: inout Endpoint) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys?)
  }
  ```
- `handle` returns `driverKeys` nil only for `unknownSender`/malformed input (no one to seal an ack to); the caller then only logs.

- [ ] **Step 1: Write the failing tests** (append inside `TeamControlTests`)

```swift
    // MARK: Task 5

    struct Executed: Equatable { var action: String; var text: String?; var pid: Int32 }

    func endpoint(grants: TeamGrants, roster: TeamRoster? = nil, live: [String: Int32] = ["s1": 4242],
                  now: Int = 1_010, reply: SessionInput.Reply = .init(outcome: "delivered", channel: "pty"),
                  executed: @escaping (Executed) -> Void = { _ in }) -> TeamControl.Endpoint {
        let roster = roster ?? TeamRoster(id: "team-1", name: "P", createdAt: 1,
                                          leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                          members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], rev: 1)
        return TeamControl.Endpoint(identity: grantor, roster: { roster }, grants: { grants }, liveSessions: { live },
                                    execute: { action, text, pid in executed(Executed(action: action, text: text, pid: pid)); return reply },
                                    seen: TeamControl.SeenIDs(), limit: TeamControl.RateLimit(),
                                    now: { Date(timeIntervalSince1970: Double(now)) })
    }

    func sendGrant(_ capabilities: Set<String> = [TeamGrants.send]) -> TeamGrants {
        var g = TeamGrants()
        g.add(audience: .members([driver.kid]), sessions: .some(["s1"]), capabilities: capabilities, now: 900)
        return g
    }

    func sealed(_ cmd: TeamControl.Command, from: TeamIdentity? = nil, to: TeamKeys? = nil) throws -> Data {
        try TeamControl.sealCommand(cmd, from: from ?? driver, to: to ?? grantor.keys, at: cmd.at)
    }

    func testAGrantedCommandExecutesAndAcksTheReply() throws {
        var ran: [Executed] = []
        var ep = endpoint(grants: sendGrant()) { ran.append($0) }
        let (ack, audit, keys) = TeamControl.handle(try sealed(command()), endpoint: &ep)
        XCTAssertEqual(ran, [Executed(action: "send", text: "hello", pid: 4242)])
        XCTAssertEqual(ack, TeamControl.Ack(id: "c-0123456789", outcome: "delivered", detail: nil, at: 1_010))
        XCTAssertEqual(audit, TeamControl.Audit(driver: driver.kid, session: "s1", action: "send", outcome: "delivered", detail: nil))
        XCTAssertEqual(keys, driver.keys)
        XCTAssertFalse(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011), "the id is now spent")
    }

    func testEveryRefusalInOrder() throws {
        func outcome(_ file: Data, _ ep: inout TeamControl.Endpoint) -> String { TeamControl.handle(file, endpoint: &ep).ack.outcome }
        // 1. not a member (eve) — unknownSender, and no keys to answer.
        var ep = endpoint(grants: sendGrant())
        let fromEve = TeamControl.handle(try sealed(command(), from: eve), endpoint: &ep)
        XCTAssertEqual(fromEve.ack.outcome, "unknownSender"); XCTAssertNil(fromEve.driverKeys)
        // 1b. garbage — badRequest, no keys.
        XCTAssertEqual(TeamControl.handle(Data("nope".utf8), endpoint: &ep).ack.outcome, "badRequest")
        // 2. addressed to someone else although sealed to me.
        var cmd = command(); cmd.to = eve.kid
        XCTAssertEqual(outcome(try sealed(cmd), &ep), "badRequest")
        // 3. expired / from the future.
        XCTAssertEqual(outcome(try sealed(command(at: 800, ttl: 100)), &ep), "expired")
        XCTAssertEqual(outcome(try sealed(command(at: 1_010 + TeamControl.maxFutureSkew + 1)), &ep), "badRequest")
        XCTAssertEqual(outcome(try sealed(command(id: "c-cap-ttl-000", ttl: TeamControl.maxTTL + 1)), &ep), "badRequest", "ttl above the cap")
        // 5. no grant — wrong capability, wrong session, wrong kid.
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000001", action: "approve")), &ep), "noGrant")
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000002", session: "s2")), &ep), "noGrant")
        var none = endpoint(grants: TeamGrants())
        XCTAssertEqual(outcome(try sealed(command()), &none), "noGrant")
        // 5b. an action that is not a drive capability at all.
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000003", action: "reboot")), &ep), "badRequest")
        // 6. not live.
        var offline = endpoint(grants: sendGrant(), live: [:])
        XCTAssertEqual(outcome(try sealed(command()), &offline), "notLive")
        // 4. replay: the same id twice (the first executes).
        var twice = endpoint(grants: sendGrant())
        XCTAssertEqual(outcome(try sealed(command()), &twice), "delivered")
        XCTAssertEqual(outcome(try sealed(command()), &twice), "replayed")
        // 7. rate: the sixth distinct command inside the window.
        var busy = endpoint(grants: sendGrant())
        for i in 0..<TeamControl.RateLimit.commands { XCTAssertEqual(outcome(try sealed(command(id: "c-r00000000\(i)")), &busy), "delivered") }
        XCTAssertEqual(outcome(try sealed(command(id: "c-r000000009")), &busy), "rateLimited")
    }

    func testOrderIsProvenByACommandFailingTwoRules() throws {
        // Expired AND unshared: `expired` wins (step 3 before step 5), and the id is not spent.
        var ep = endpoint(grants: TeamGrants())
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 800, ttl: 10)), endpoint: &ep).ack.outcome, "expired")
        XCTAssertTrue(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011), "a refused command does not spend its id")
        // No grant AND not live: `noGrant` wins (step 5 before 6) — a stranger learns nothing about liveness.
        var off = endpoint(grants: TeamGrants(), live: [:])
        XCTAssertEqual(TeamControl.handle(try sealed(command()), endpoint: &off).ack.outcome, "noGrant")
    }

    func testARemovedMemberIsUnknownAfterRemoval() throws {
        // Removed at 950: a command sealed at 1_000 fails unknownSender; one sealed at 940 still verifies (roster keeps its keys).
        let roster = TeamRoster(id: "team-1", name: "P", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                members: [], removed: [TeamRoster.Removed(kid: driver.kid, at: 950, keys: driver.keys)], rev: 2)
        var ep = endpoint(grants: sendGrant(), roster: roster)
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 1_000)), endpoint: &ep).ack.outcome, "unknownSender")
        var early = endpoint(grants: sendGrant(), roster: roster)
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 940, ttl: 100)), endpoint: &early).ack.outcome,
                       "noGrant", "verifies, but a removed kid is in no audience any more")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TeamControlTests`
Expected: compile error — `TeamControl.Endpoint` does not exist.

- [ ] **Step 3: Implement** (append to `TeamControl.swift`)

```swift
extension TeamControl {
    /// What the pipeline needs, injected: the app hands its identity,
    /// roster, grants file, live-session table and `AppModel.send`; the
    /// tests hand closures. The pipeline never touches disk itself
    /// except through `seen` (the caller persists it after `handle`).
    public struct Endpoint {
        public var identity: TeamIdentity
        public var roster: () -> TeamRoster?
        public var grants: () -> TeamGrants
        public var liveSessions: () -> [String: Int32]
        public var execute: (_ action: String, _ text: String?, _ pid: Int32) -> SessionInput.Reply
        public var seen: SeenIDs
        public var limit: RateLimit
        public var now: () -> Date

        public init(identity: TeamIdentity, roster: @escaping () -> TeamRoster?, grants: @escaping () -> TeamGrants,
                    liveSessions: @escaping () -> [String: Int32],
                    execute: @escaping (String, String?, Int32) -> SessionInput.Reply,
                    seen: SeenIDs, limit: RateLimit, now: @escaping () -> Date = Date.init) {
            self.identity = identity; self.roster = roster; self.grants = grants; self.liveSessions = liveSessions
            self.execute = execute; self.seen = seen; self.limit = limit; self.now = now
        }
    }

    public struct Verified: Equatable {
        public var header: Envelope.Header
        public var command: Command
        public var pid: Int32
        public var grant: TeamGrants.Grant
    }

    public enum Refusal: Error, Equatable {
        case outcome(String, detail: String?)
    }

    /// Spec §4, first failure wins. Steps: 1 open (signature, roster at
    /// `at`, recipient), 2 addressed to me, 3 ttl/skew, 4 replay, 5 grant,
    /// 6 live, 7 rate. Only a command that passes 1–3 and 5–6 spends its
    /// id and a rate token, so a refused one can be resent.
    public static func verify(_ file: Data, endpoint: inout Endpoint) -> Result<Verified, Refusal> {
        guard let roster = endpoint.roster() else { return .failure(.outcome(Outcome.unknownSender, detail: "no roster")) }
        let header: Envelope.Header
        let command: Command
        do {
            (header, command) = try openCommand(file, as: endpoint.identity,
                                                senderKey: { kid in roster.keys(for: kid, at: (try? Envelope.header(of: file).at) ?? 0) })
        } catch Envelope.EnvelopeError.unknownSender {
            return .failure(.outcome(Outcome.unknownSender, detail: nil))
        } catch {
            return .failure(.outcome(Outcome.badRequest, detail: "\(error)"))
        }
        guard command.to == endpoint.identity.kid else { return .failure(.outcome(Outcome.badRequest, detail: "addressed to another kid")) }
        let nowSec = Int(endpoint.now().timeIntervalSince1970)
        guard (1...maxTTL).contains(command.ttl) else { return .failure(.outcome(Outcome.badRequest, detail: "ttl")) }
        guard command.at <= nowSec + maxFutureSkew else { return .failure(.outcome(Outcome.badRequest, detail: "from the future")) }
        guard nowSec <= command.at + command.ttl else { return .failure(.outcome(Outcome.expired, detail: nil)) }
        guard TeamGrants.driveCapabilities.contains(command.action) else { return .failure(.outcome(Outcome.badRequest, detail: "action")) }
        // Step 4 is checked here but SPENT only after 5–6 pass: a replay of
        // an executed id must say `replayed`, while a refused id stays free.
        if endpoint.seen.expiry[command.id].map({ $0 > nowSec }) == true {
            return .failure(.outcome(Outcome.replayed, detail: nil))
        }
        guard let grant = endpoint.grants().permits(kid: header.from, session: command.session, capability: command.action, roster: roster) else {
            return .failure(.outcome(Outcome.noGrant, detail: nil))
        }
        guard let pid = endpoint.liveSessions()[command.session] else { return .failure(.outcome(Outcome.notLive, detail: nil)) }
        guard endpoint.limit.allow(kid: header.from, now: endpoint.now()) else { return .failure(.outcome(Outcome.rateLimited, detail: nil)) }
        _ = endpoint.seen.admit(command.id, until: command.at + command.ttl, now: nowSec)
        return .success(Verified(header: header, command: command, pid: pid, grant: grant))
    }

    public struct Audit: Equatable, Sendable {
        public var driver: String
        public var session: String
        public var action: String
        public var outcome: String
        public var detail: String?
    }

    /// verify + execute. `driverKeys` is nil when there is nobody to
    /// answer (not a member, or not even an envelope): log and drop.
    public static func handle(_ file: Data, endpoint: inout Endpoint) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys?) {
        let nowSec = Int(endpoint.now().timeIntervalSince1970)
        let header = try? Envelope.header(of: file)
        let driverKeys = header.flatMap { h in endpoint.roster()?.keys(for: h.from, at: h.at) }
        let id = (try? Envelope.header(of: file)).flatMap { _ in try? decodeIDOnly(file, as: endpoint.identity, roster: endpoint.roster()) } ?? ""
        switch verify(file, endpoint: &endpoint) {
        case .success(let v):
            let reply = endpoint.execute(v.command.action, v.command.text, v.pid)
            return (Ack(id: v.command.id, outcome: reply.outcome, detail: reply.detail, at: nowSec),
                    Audit(driver: v.header.from, session: v.command.session, action: v.command.action, outcome: reply.outcome, detail: reply.detail),
                    driverKeys)
        case .failure(.outcome(let outcome, let detail)):
            let unknown = outcome == Outcome.unknownSender || (outcome == Outcome.badRequest && header == nil)
            return (Ack(id: id, outcome: outcome, detail: detail, at: nowSec),
                    Audit(driver: header?.from ?? "?", session: "", action: "", outcome: outcome, detail: detail),
                    unknown ? nil : driverKeys)
        }
    }

    /// The command id for a refusal ack, when the envelope opens at all.
    private static func decodeIDOnly(_ file: Data, as me: TeamIdentity, roster: TeamRoster?) throws -> String {
        guard let roster else { throw Envelope.EnvelopeError.unknownSender }
        let (_, body) = try Envelope.open(file, as: me, senderKey: { kid in roster.keys(for: kid, at: (try? Envelope.header(of: file).at) ?? 0) })
        return (try? CanonicalJSON.decode(Command.self, from: body))?.id ?? ""
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TeamControlTests`
Expected: 10 tests, 0 failures. If `testEveryRefusalInOrder` fails on the `ttl above the cap` line with `expired`, the ttl guard is after the expiry guard — order them as written (ttl, skew, expiry).

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Team/TeamControl.swift Tests/InfinitusCoreTests/TeamControlTests.swift
git commit -m "team control: the verification pipeline — signature, address, ttl, replay, grant, liveness, rate — then execute and ack (#220)"
```

---

### Task 6: the routes as pure functions

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamControlRoute.swift`
- Test: `Tests/InfinitusCoreTests/TeamControlRouteTests.swift`

**Interfaces:**
- Consumes: `MirrorTransport.Request` (`method`, `path`, `headers` lowercased, `body`), `MirrorTransport.response(status:reason:contentType:body:)`, `notFoundResponse()`, `badRequestResponse()`, Task 5's `Endpoint`/`handle`, `TeamGrants.view`, `TeamIdentity.sign`, `TeamKeys.signingKey()`.
- Produces:
  ```swift
  public enum TeamControlRoute {
      public static let commandPath = "/team/command"
      public static func tailPath(sessionId: String) -> String          // "/team/sessions/<id>/tail"
      public static func tailSessionId(_ path: String) -> String?         // inverse, nil for anything else
      public static let tailHeader = "x-infinitus-team"                   // lowercased, as MirrorTransport stores headers
      /// "<kid>.<base64 sig over "tail|<sessionId>|<unix minute>">"
      public static func signTail(sessionId: String, by: TeamIdentity, now: Date) throws -> String
      /// The kid whose signature is valid for this minute or the previous one; nil otherwise.
      public static func checkTail(_ header: String, sessionId: String, roster: TeamRoster, now: Date) -> String?
      public struct Tail { public var read: (_ sessionId: String, _ since: String?) -> Data? }   // the feed bytes, nil when the session is unknown
      /// nil = not a control route (keep routing). 404 when `endpoint` is nil or has no grants.
      public static func respond(_ request: MirrorTransport.Request, endpoint: inout TeamControl.Endpoint?, tail: Tail) -> Data?
  }
  ```
- `POST /team/command` → 200 `application/octet-stream` with the sealed ack, or 200 with an EMPTY body when `driverKeys` is nil (nothing to seal to); 400 on an empty body. The audit record is returned to the caller through `endpoint.lastAudit` — add `public var lastAudit: TeamControl.Audit?` to `Endpoint` (nil until `respond` sets it) so the mounting server logs it.
- `GET /team/sessions/<id>/tail[?since=…]` → 403 `text/plain` without a valid header or without `view` on that session; 404 when the tail reader has no such session; else 200 with the feed bytes as `application/x-ndjson`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InfinitusCore

final class TeamControlRouteTests: XCTestCase {
    let grantor = TeamIdentity.random()
    let driver = TeamIdentity.random()
    let eve = TeamIdentity.random()

    var roster: TeamRoster {
        TeamRoster(id: "team-1", name: "P", createdAt: 1,
                   leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                   members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], rev: 1)
    }

    func endpoint(_ capabilities: Set<String>) -> TeamControl.Endpoint {
        var grants = TeamGrants()
        if !capabilities.isEmpty { grants.add(audience: .members([driver.kid]), sessions: .some(["s1"]), capabilities: capabilities, now: 1) }
        let r = roster
        return TeamControl.Endpoint(identity: grantor, roster: { r }, grants: { grants }, liveSessions: { ["s1": 7] },
                                    execute: { _, _, _ in .init(outcome: "delivered", channel: "pty") },
                                    seen: .init(), limit: .init(), now: { Date(timeIntervalSince1970: 1_000) })
    }

    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()) -> MirrorTransport.Request {
        MirrorTransport.Request(method: method, target: path, headers: headers, body: body)
    }

    let tail = TeamControlRoute.Tail { id, since in id == "s1" ? Data("{\"line\":1,\"since\":\"\(since ?? "")\"}\n".utf8) : nil }

    func status(_ response: Data?) -> Int? {
        response.flatMap { String(decoding: $0.prefix(12), as: UTF8.self).split(separator: " ").dropFirst().first }.flatMap { Int($0) }
    }
    func body(_ response: Data) -> Data {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: marker) else { return Data() }
        return response[range.upperBound...]
    }

    func testNonControlRoutesKeepRoutingAndNoGrantsMeans404() throws {
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        XCTAssertNil(TeamControlRoute.respond(request("GET", "/snapshot"), endpoint: &ep, tail: tail))
        XCTAssertNil(TeamControlRoute.respond(request("GET", "/team/key"), endpoint: &ep, tail: tail), "Nearby's route, not ours")
        var none: TeamControl.Endpoint? = endpoint([])
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command", body: Data("x".utf8)), endpoint: &none, tail: tail)), 404)
        var absent: TeamControl.Endpoint? = nil
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command", body: Data("x".utf8)), endpoint: &absent, tail: tail)), 404)
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", "/team/command"), endpoint: &ep, tail: tail)), 404, "wrong method")
    }

    func testACommandComesBackAsASealedAck() throws {
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.kid, session: "s1", action: "send", text: "hi", at: 1_000)
        let file = try TeamControl.sealCommand(cmd, from: driver, to: grantor.keys, at: 1_000)
        let response = TeamControlRoute.respond(request("POST", "/team/command", body: file), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(response), 200)
        let (_, ack) = try TeamControl.openAck(body(response!), as: driver, senderKey: { [self.grantor, self.driver].first { $0.kid == $0.kid && $0.kid == $0.kid }?.keys ?? nil })
        XCTAssertEqual(ack.outcome, "delivered")
        XCTAssertEqual(ep?.lastAudit, TeamControl.Audit(driver: driver.kid, session: "s1", action: "send", outcome: "delivered", detail: nil))
        // Empty body: 400. A stranger's command: 200 with nothing to read (no ack can be sealed), audit says unknownSender.
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command"), endpoint: &ep, tail: tail)), 400)
        let strangers = try TeamControl.sealCommand(cmd, from: eve, to: grantor.keys, at: 1_000)
        let dropped = TeamControlRoute.respond(request("POST", "/team/command", body: strangers), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(dropped), 200)
        XCTAssertTrue(body(dropped!).isEmpty)
        XCTAssertEqual(ep?.lastAudit?.outcome, "unknownSender")
    }

    func testTailNeedsASignedHeaderAndAViewGrant() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.view])
        let path = TeamControlRoute.tailPath(sessionId: "s1")
        XCTAssertEqual(path, "/team/sessions/s1/tail")
        XCTAssertEqual(TeamControlRoute.tailSessionId(path), "s1")
        XCTAssertNil(TeamControlRoute.tailSessionId("/team/sessions/s1/images"))
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", path), endpoint: &ep, tail: tail)), 403, "no header")
        let header = try TeamControlRoute.signTail(sessionId: "s1", by: driver, now: now)
        XCTAssertEqual(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now), driver.kid)
        XCTAssertEqual(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now.addingTimeInterval(59)), driver.kid, "the previous minute still counts")
        XCTAssertNil(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now.addingTimeInterval(121)), "two minutes on it is stale")
        XCTAssertNil(TeamControlRoute.checkTail(header, sessionId: "s2", roster: roster, now: now), "bound to the session")
        XCTAssertNil(TeamControlRoute.checkTail(try TeamControlRoute.signTail(sessionId: "s1", by: eve, now: now), sessionId: "s1", roster: roster, now: now), "not a member")
        let ok = TeamControlRoute.respond(request("GET", path + "?since=12", headers: [TeamControlRoute.tailHeader: header]), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(ok), 200)
        XCTAssertEqual(String(decoding: body(ok!), as: UTF8.self), "{\"line\":1,\"since\":\"12\"}\n")
        // view on s1 only: s2 is 403 even though the header verifies; an unknown live session with a grant is 404.
        var all: TeamControl.Endpoint? = endpoint([TeamGrants.view])
        let h2 = try TeamControlRoute.signTail(sessionId: "s2", by: driver, now: now)
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", TeamControlRoute.tailPath(sessionId: "s2"), headers: [TeamControlRoute.tailHeader: h2]), endpoint: &all, tail: tail)), 403)
        var sendOnly: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", path, headers: [TeamControlRoute.tailHeader: header]), endpoint: &sendOnly, tail: tail)), 403, "send does not include view")
    }
}
```

(In `testACommandComesBackAsASealedAck`, replace the convoluted `senderKey` closure with `{ kid in [self.grantor, self.driver].first { $0.kid == kid }?.keys }` — write it that way in the file.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TeamControlRouteTests`
Expected: compile error — `TeamControlRoute` does not exist.

- [ ] **Step 3: Implement**

Add to `TeamControl.Endpoint` (Task 5 file), after `now`: `public var lastAudit: TeamControl.Audit? = nil` (a `var` with a default needs no init change).

`Sources/InfinitusCore/Team/TeamControlRoute.swift`:

```swift
import Foundation

/// The two control routes (#220 §5.2) as request → response functions,
/// like `TeamNearby.respond`: the Mac's MirrorServer and the Linux
/// tray's PosixHTTPServer mount the same handler. No pairing token: a
/// command authenticates itself (the envelope), a tail request carries
/// a signature over the session and the minute.
public enum TeamControlRoute {
    public static let commandPath = "/team/command"
    private static let tailPrefix = "/team/sessions/"
    public static func tailPath(sessionId: String) -> String { tailPrefix + sessionId + "/tail" }

    public static func tailSessionId(_ path: String) -> String? {
        guard path.hasPrefix(tailPrefix), path.hasSuffix("/tail") else { return nil }
        let id = path.dropFirst(tailPrefix.count).dropLast("/tail".count)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return String(id)
    }

    /// `MirrorTransport` lowercases header names.
    public static let tailHeader = "x-infinitus-team"

    static func tailMessage(sessionId: String, minute: Int) -> Data { Data("tail|\(sessionId)|\(minute)".utf8) }

    public static func signTail(sessionId: String, by driver: TeamIdentity, now: Date) throws -> String {
        let minute = Int(now.timeIntervalSince1970) / 60
        return driver.kid + "." + (try driver.sign(tailMessage(sessionId: sessionId, minute: minute))).base64EncodedString()
    }

    /// This minute or the previous one, so a request signed at :59 is not
    /// refused at :00. Two minutes on, it is stale.
    public static func checkTail(_ header: String, sessionId: String, roster: TeamRoster, now: Date) -> String? {
        guard let dot = header.firstIndex(of: "."), dot != header.startIndex else { return nil }
        let kid = String(header[..<dot])
        guard let sig = Data(base64Encoded: String(header[header.index(after: dot)...])),
              let keys = roster.keys(for: kid), let key = try? keys.signingKey() else { return nil }
        let minute = Int(now.timeIntervalSince1970) / 60
        for m in [minute, minute - 1] where key.isValidSignature(sig, for: tailMessage(sessionId: sessionId, minute: m)) {
            return kid
        }
        return nil
    }

    /// The live feed for a session, as the phone's tail route serves it.
    public struct Tail {
        public var read: (_ sessionId: String, _ since: String?) -> Data?
        public init(read: @escaping (String, String?) -> Data?) { self.read = read }
    }

    /// nil = not ours, keep routing. No endpoint or no grants ⇒ 404 on
    /// every control route (default off, and a stranger learns nothing).
    public static func respond(_ request: MirrorTransport.Request, endpoint: inout TeamControl.Endpoint?, tail: Tail) -> Data? {
        let isCommand = request.path == commandPath
        let tailId = tailSessionId(request.path)
        guard isCommand || tailId != nil else { return nil }
        guard var ep = endpoint, !ep.grants().grants.isEmpty else { return MirrorTransport.notFoundResponse() }
        defer { endpoint = ep }
        switch (request.method, isCommand, tailId) {
        case ("POST", true, _):
            guard !request.body.isEmpty else { return MirrorTransport.badRequestResponse() }
            let (ack, audit, driverKeys) = TeamControl.handle(request.body, endpoint: &ep)
            ep.lastAudit = audit
            guard let driverKeys, let sealed = try? TeamControl.sealAck(ack, from: ep.identity, to: driverKeys, at: ack.at) else {
                return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/octet-stream", body: Data())
            }
            return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/octet-stream", body: sealed)
        case ("GET", false, let id?):
            guard let roster = ep.roster(), let header = request.headers[tailHeader],
                  let kid = checkTail(header, sessionId: id, roster: roster, now: ep.now()),
                  ep.grants().permits(kid: kid, session: id, capability: TeamGrants.view, roster: roster) != nil else {
                return MirrorTransport.response(status: 403, reason: "Forbidden", contentType: "text/plain", body: Data("no view grant\n".utf8))
            }
            let since = request.target.split(separator: "?", maxSplits: 1).dropFirst().first
                .flatMap { $0.split(separator: "&").first { $0.hasPrefix("since=") } }.map { String($0.dropFirst("since=".count)) }
            guard let bytes = tail.read(id, since) else { return MirrorTransport.notFoundResponse() }
            return MirrorTransport.response(status: 200, reason: "OK", contentType: "application/x-ndjson", body: bytes)
        default:
            return MirrorTransport.notFoundResponse()
        }
    }
}
```

If `MirrorTransport.Request` has no public memberwise `init(method:target:headers:body:)`, add one in `MirrorTransport.swift` next to the struct (`public init(method: String, target: String, headers: [String: String], body: Data)`); check `TeamNearbyTests` first — it builds requests somehow, and that helper is the one to reuse.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'TeamControlRouteTests|TeamControlTests|TeamNearbyTests'`
Expected: all pass; `TeamNearbyTests` proves the existing team routes are untouched.

- [ ] **Step 5: Whole-suite, Linux build, commit**

Run: `swift build --product infinitusctl 2>&1 | grep -E 'error|Build complete'` then `swift test 2>&1 | grep -E 'error:|failed|Executed' | tail -3`
Expected: `Build complete!`, `0 failures`.

```bash
git add Sources/InfinitusCore/Team/TeamControlRoute.swift Sources/InfinitusCore/Team/TeamControl.swift Tests/InfinitusCoreTests/TeamControlRouteTests.swift
git commit -m "team control: POST /team/command and the signed session tail as pure routes for the Mac and the tray (#220)"
```

---

### Task 7: docs line and PR

**Files:**
- Modify: `CHANGELOG.md` (one line under `## Unreleased` › `### Team (preview)`)
- Modify: `docs/superpowers/specs/2026-09-07-team-session-control-design.md` §3 (ack outcomes: replace the `typedUnverified`/`capturedInput` list with `delivered | running | captured | noSurface | noChannel | rejected`)

- [ ] **Step 1: CHANGELOG line**

```
- Team session control, core: grants, sealed command and ack envelopes, the verification pipeline and the control routes land in InfinitusCore with tests; nothing is mounted yet (#220).
```

- [ ] **Step 2: Spec correction** as above, one line.

- [ ] **Step 3: Final checks and commit**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Build complete'`, `swift build --product infinitusctl 2>&1 | grep -E 'error|Build complete'`, `swift test 2>&1 | grep -E 'failed|Executed' | tail -2`, then `INFINITUS_CONTROL_SOCKET=/tmp/ctl.sock tools/e2e.sh` (announce "e2e running" to the other session first) and grep the log for `E2E PASS`.

```bash
git add CHANGELOG.md docs/superpowers/specs/2026-09-07-team-session-control-design.md
git commit -m "team control: changelog line and the ack-outcome correction in the spec (#220)"
```

Then push `control-core` and hand off: "merge control-core at <sha>" with `--merge` (multi-commit), no `ios/` so the ios CI job suffices.

---

## Self-review (done while writing)

- **Spec coverage:** §2 → Task 1; §3 → Tasks 2, 3; §4 → Tasks 4, 5; §5.1 → Task 3 (`Endpoints`, `rendezvousKey`); §5.2 → Task 6; §8 (stranger learns nothing) → Task 5 order test + Task 6 404/403; §9 core tests → all. §5.3 delivery, §5.4 hostnames, §6 audit sink, §7 surfaces are PRs 3–5 by the spec's build order, not this plan.
- **Placeholders:** none; every step carries its code.
- **Type consistency:** `TeamGrants.Sessions.some([String])`, `TeamControl.Endpoint(identity:roster:grants:liveSessions:execute:seen:limit:now:)`, `TeamControl.handle(_:endpoint:) -> (ack:audit:driverKeys:)`, `TeamControlRoute.respond(_:endpoint:tail:)`, `TeamDocs.GrantHint(audience:sessions:capabilities:)`, `TeamControl.Endpoints(lan:hostname:rendezvous:)` are used with the same shapes in every task.
