# Team — Leader-initiated LAN invites + phone Nearby (spec §6.4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the second half of spec §6.4. A leader who sees a discoverable Mac that is not in the team taps **Invite**: the invite link is minted the same way the pane's "Invite link" button mints it, sealed to that peer's keys, and POSTed over the LAN. The peer's Team pane grows an **Invitations** section — "Loc invites you to Papaya" · Accept · Ignore — and Accept joins in one tap (the leader's auto-approve already recognises the nonce). The same Nearby lists — peers, pending LAN requests, invitations — reach the phone through `/mirror/team/nearby*`, with Scan / Request / Invite / File / Accept / Ignore from the phone. The CLI gets `team nearby invite`, `team invites`, `team accept`, `team ignore`.

**Architecture:** One new LAN route, `POST /team/invite`, answered by the same pure `TeamNearby.respond(_:endpoint:)` function the Mac's MirrorServer and the Linux `PosixHTTPServer` already mount, so nothing about transport changes. The body is `TeamNearby.Invite` — the sender's `TeamKeys`, a display name, the team name, and an `Envelope` sealing the invite link text. The envelope stays sealed on disk under `<teams base>/invites/<from kid>.json`; only Accept opens it, with this machine's identity out of `secrets`. Minting moves into core as `TeamInvites.mint(client:teamDir:days:now:)` so the pane's Invite-link button, the CLI and a LAN invite all write the same nonce book. On the phone side, one new `@MainActor enum TeamMirrorNearby` answers `/mirror/team/nearby*` off `TeamModel`, hooked into `TeamMirrorHandler`'s `default:` with one line; the wire types live in core `TeamMirror.swift`, which the phone target already gets as the `InfinitusCore` package product.

**Tech Stack:** Swift 6, InfinitusCore (macOS + Linux + iOS), swift-crypto through `Envelope`, SwiftUI (Mac pane + phone screen), Network.framework mirror, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` — §6.2 (invite payload and auto-approve), §6.4 (Nearby: the leader's Invite, the peer's Accept, "the phone shows the Mac's Nearby lists through the mirror and can Invite / Request / Approve from there"), §2.2 (the biometric gate on joining), §10 (threat model).

Base: `origin/main` at **bbacd2d**, worktree `~/death/limitless-t-nearby2`, branch `team-nearby2`.

## Global Constraints

- **Everything is Swift; InfinitusCore builds on macOS AND Linux** (and iOS — the phone links it). No AppKit, no Security, no `Process` in anything this plan adds to Core; guard anything platform-shaped with `#if canImport(...)`. Never read engine internals (`~/.claude-swap-backup/*`); Claude Code's own files under `~/.claude` are fine.
- **Secrets travel over stdin/keychain, never argv, never plaintext on disk outside `secrets`; shown masked only.** The team store token is embedded in every team code and invite link — so the invite link never touches argv, never gets logged, never gets written unsealed. The envelope on disk stays sealed; `TeamNearby.openInvite` is the only thing that opens it, in memory, at Accept.
- **Idle CPU with the pop-out open stays ~0%:** no `TimelineView`, no `repeatForever` animation, no per-chunk main-actor hops. Nearby scans stay on demand (a button, or a section's first appearance) — never on a timer.
- **Team-store I/O runs on `TeamModel.queue` via `run {}` / `action(...)`, never on the main actor.** `TeamModel` is `@MainActor`.
- **Tests:** `swift test --filter <Suite>` per task; the full `swift test` before the final commit. UI tasks: `swift build --product Infinitus` must succeed (there are no UI tests, and no app-target test bundle at all — `Tests/` holds only `InfinitusCoreTests`).
- **CHANGELOG:** one feature = one short line under `### Team (preview)` in `## 0.4.4 (unreleased)` (`CHANGELOG.md`, the section at line 45). Add the lines in the LAST task only.
- **Every commit carries `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`** (the repo's `prepare-commit-msg` hook appends it; write it anyway). **Stage by explicit path. Never push.**
- Surgical changes, match existing style (four-space indent, doc comments that say *why*), no speculative abstractions, no new dependencies.
- Never inject test messages into real Claude sessions. **No subagents from implementers.**

## File ownership

The other round-4 stream runs in parallel in another worktree and both merge into main. This stream MAY touch only:

| File | Region |
|---|---|
| `Sources/InfinitusCore/Team/TeamNearby.swift` | whole file |
| `Sources/InfinitusCore/Team/NearbyRecord.swift` | whole file (expected: no change needed) |
| `Sources/InfinitusCore/Team/TeamMirror.swift` | whole file |
| `Sources/InfinitusCore/Team/TeamInvites.swift` | whole file |
| `Sources/InfinitusCore/Team/TeamCode.swift` | whole file (expected: no change needed) |
| `Sources/InfinitusCLI/TeamNearbyCommand.swift` | whole file |
| `Sources/Infinitus/MirrorServer.swift` | ONLY `MirrorTeamBox.endpoint` (lines 254–262) |
| `Sources/Infinitus/TeamModel.swift` | ONLY the `// MARK: nearby (spec §6.4)` block (lines 317–376), `mintInvite` (lines 545–562), and ONE new `@Published` line beside `@Published private(set) var nearby` (line 37) |
| `Sources/Infinitus/TeamPane.swift` | ONLY `Section("Nearby teams")` (lines 101–119), a NEW `Section("Invitations")` directly under it, and the leader's `Section("Nearby")` (lines 176–193) |
| `Sources/Infinitus/TeamMirrorNearby.swift` | new file |
| `Sources/Infinitus/TeamMirrorHandler.swift` | ONE contiguous insertion at the `default:` (lines 49–50) |
| `ios/InfinitusMobile/TeamScreen.swift` | whole file |
| `ios/InfinitusMobile/NetworkFleetMirror.swift` | ONLY the `// MARK: team` block (lines 474–532) |
| `Tests/InfinitusCoreTests/TeamNearbyTests.swift` | whole file |
| `Tests/InfinitusCoreTests/TeamInvitesTests.swift` | whole file |
| `Tests/InfinitusCoreTests/TeamMirrorTests.swift` | NEW test functions only — do not edit the three existing ones |
| `CHANGELOG.md` | lines under `## 0.4.4 (unreleased)` → `### Team (preview)` (line 45) |

**Do not touch** (repeat this list in every task): `TeamPublisher.swift`, `TeamChunker.swift`, `TeamShares.swift`, `TeamRoster.swift`, `TeamGit.swift`, `TeamPaths.swift`, `TeamClient.swift`, `TeamRequest.swift`, `Sources/InfinitusCLI/TeamCommand.swift`, `Sources/InfinitusCLI/main.swift`, any line of `TeamModel.swift` outside the three regions above (in particular `action(_:_:)`, `gated()`, `mask(_:)`, `load`, `loop`, `quit`, `create`, `join`, `mintCode`, `setShare`, `reshare`), any line of `TeamPane.swift` outside the three regions above (sharing / exclusions / privacy / header / Requests / Members), `TeamMirrorHandler`'s existing `switch` cases and its `action` closure, `AppModel.swift`, `InfinitusApp.swift`, any other part of `MirrorServer.swift`, `RowTheme.swift`, `tools/e2e.sh`, `site/*`, `README.md`, and every phone file other than `TeamScreen.swift` and `NetworkFleetMirror.swift`'s team block.

---

## File structure

| File | Responsibility |
|---|---|
| `TeamInvites.swift` | `mint(client:teamDir:days:now:)` — the one place a nonce enters the book and leaves in a link. |
| `TeamNearby.swift` | `Invite` / `InviteReply` wire types, `invitePath`, `Endpoint.storeInvite`, the `POST /team/invite` branch of `respond`, `Store.{invitesDir,saveInvite,invites,removeInvite}`, `openInvite`, `Client.invite`. |
| `TeamNearbyCommand.swift` | `team nearby invite`, `team invites`, `team accept`, `team ignore`; positional arguments in the option parser. |
| `MirrorServer.swift` | `MirrorTeamBox.endpoint` gains the `storeInvite` closure. |
| `TeamModel.swift` | `invites`, `loadInvites()`, `inviteNearby(_:)`, `acceptInvite(_:name:)`, `ignoreInvite(_:)`; `mintInvite` delegates to `TeamInvites.mint`. |
| `TeamPane.swift` | `Section("Invitations")`; an Invite button on the leader's Nearby peers; the new caption. |
| `TeamMirror.swift` | `nearby*` paths and the `NearbyReply` / `PendingRequest` / `InviteSummary` / `NearbyJoinRequest` / `InviteAccept` / `Empty` wire types (shared with the phone). |
| `TeamMirrorNearby.swift` | `@MainActor` dispatcher for `/mirror/team/nearby*` onto `TeamModel`. |
| `NetworkFleetMirror.swift` | `teamNearby*` transport wrappers. |
| `TeamScreen.swift` | "Nearby teams" + "Invitations" (not in a team), "Nearby" (leader). |

---

### Task 1: `TeamInvites.mint` — one path from nonce to link

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamInvites.swift`
- Modify: `Sources/Infinitus/TeamModel.swift` — ONLY `mintInvite` (lines 545–562)
- Test: `Tests/InfinitusCoreTests/TeamInvitesTests.swift`
- Do not touch: everything in the "Do not touch" list above; in this task also leave `TeamNearby.swift` alone.

**Interfaces:**
- Produces (used by Tasks 3, 4, 5):

```swift
public struct TeamInvites {
    /// Mints an invite link (spec §6.2) and remembers its one-time nonce.
    public static func mint(client: TeamClient, teamDir: URL, days: Int,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> String
}
```

- [ ] **Step 1: Write the failing test.** Add to `Tests/InfinitusCoreTests/TeamInvitesTests.swift`, after `testCodeCarriesTheNonceAndAutoApprovalIsTheLeadersDecision`:

```swift
    func testMintAddsOneNonceToTheBookAndTheLinkCarriesIt() throws {
        let paths = TeamPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("mint-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let secrets = FileSecrets(dir: paths.secretsDir)
        let bare = paths.base.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        let client = try TeamClient.create(name: "T", remote: "file://" + bare.path, token: nil, paths: paths, secrets: secrets, now: 100)
        let dir = paths.teamDir(client.config.id)
        // A nonce that expired before this mint is pruned by the same call.
        var stale = TeamInvites(); stale.add(nonce: "old", expires: 50)
        try stale.save(teamDir: dir)

        let link = try TeamInvites.mint(client: client, teamDir: dir, days: 7, now: 100)
        let code = try TeamCode.decode(link, now: 101)
        let nonce = try XCTUnwrap(code.nonce)
        XCTAssertEqual(code.team, client.config.id)
        XCTAssertEqual(code.expires, 100 + 7 * 86_400)
        XCTAssertEqual(TeamInvites.load(teamDir: dir).nonces, [nonce: 100 + 7 * 86_400])
        // A second mint keeps the first: two invites can be outstanding.
        let second = try TeamInvites.mint(client: client, teamDir: dir, days: 1, now: 200)
        let secondNonce = try XCTUnwrap(try TeamCode.decode(second, now: 201).nonce)
        XCTAssertEqual(Set(TeamInvites.load(teamDir: dir).nonces.keys), [nonce, secondNonce])
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamInvitesTests` → compile FAIL (no `TeamInvites.mint`).

- [ ] **Step 3: Implement** in `Sources/InfinitusCore/Team/TeamInvites.swift`, directly after `newNonce()`:

```swift
    /// Mints an invite link (spec §6.2) and remembers its one-time nonce
    /// so this leader's auto-approve recognises the request it comes back
    /// as. The one path from nonce to link: the Mac pane, the CLI and a
    /// LAN invite (spec §6.4) all come through here, so the book and the
    /// link can never disagree about the expiry. Expired nonces are
    /// pruned on the way past — the book is a leader's local file, and
    /// this is the only thing that writes it.
    public static func mint(client: TeamClient, teamDir: URL, days: Int,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        let nonce = newNonce()
        var book = load(teamDir: teamDir)
        book.prune(now: now)
        book.add(nonce: nonce, expires: now + days * 86_400)
        try book.save(teamDir: teamDir)
        return try client.code(expiresIn: days * 86_400, nonce: nonce, now: now)
    }
```

- [ ] **Step 4: Point `TeamModel.mintInvite` at it.** In `Sources/Infinitus/TeamModel.swift`, replace lines 545–562 (the doc comment and the whole `mintInvite` body) with:

```swift
    /// An invite link (spec §6.2): a code with a one-time nonce this
    /// leader remembers and auto-approves. `TeamInvites.mint` is the same
    /// call a LAN invite makes (spec §6.4), so both write one book.
    func mintInvite(days: Int) async {
        var minted: String?
        await action("Making an invite…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            minted = try TeamInvites.mint(client: client, teamDir: paths.teamDir(client.config.id), days: days)
        }
        if let minted { code = minted }
    }
```

Behaviour must not change: same book file (`<team dir>/invites.json`), same prune, same `expires`, same `client.code(expiresIn:nonce:)`.

- [ ] **Step 5: Run** `swift test --filter TeamInvitesTests` → PASS. `swift build --product Infinitus` → succeeds.
- [ ] **Step 6: Commit**

```
git add Sources/InfinitusCore/Team/TeamInvites.swift Sources/Infinitus/TeamModel.swift Tests/InfinitusCoreTests/TeamInvitesTests.swift
git commit -m "team: TeamInvites.mint is the one path from an invite nonce to its link"
```

(with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer.)

---

### Task 2: `POST /team/invite` — the route, the wire type and the sealed store

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamNearby.swift`
- Test: `Tests/InfinitusCoreTests/TeamNearbyTests.swift`
- Do not touch: everything in the "Do not touch" list; in this task also leave `MirrorServer.swift`, `TeamNearbyCommand.swift` and every app/phone file alone.

**Interfaces:**
- Consumes: `Envelope.seal/open/header`, `TeamCode.decode`, `TeamKeys`, `TeamIdentity`, `TeamPaths`.
- Produces (used by Tasks 3, 4, 5, 6):

```swift
public enum TeamNearby {
    public static let invitePath = "/team/invite"
    /// Pending invitations kept on a machine that has no team yet.
    public static let inviteCap = 20

    public struct Invite: Codable, Equatable, Sendable, Identifiable {
        public var from: TeamKeys
        public var fromName: String
        public var teamName: String
        public var envelope: Data
        public var id: String { from.kid }
        /// When the sender sealed it (from the signed envelope header), 0 if unreadable.
        public var at: Int { (try? Envelope.header(of: envelope).at) ?? 0 }
        public init(from: TeamKeys, fromName: String, teamName: String, envelope: Data)
    }
    public struct InviteReply: Codable, Equatable, Sendable { public var ok: Bool; public init(ok: Bool) }

    public enum StoreError: Error, Equatable { case unknownTeam, badKid, full, noInvite }

    public struct Endpoint {
        public var local: Local
        public var store: (Request) throws -> String
        public var storeInvite: (Invite) throws -> Void
        public init(local: Local, store: @escaping (Request) throws -> String,
                    storeInvite: @escaping (Invite) throws -> Void = { _ in throw StoreError.full })
    }

    public enum Store {
        public static func invitesDir(paths: TeamPaths) -> URL
        public static func saveInvite(_ invite: Invite, paths: TeamPaths) throws
        public static func invites(paths: TeamPaths) -> [Invite]
        public static func removeInvite(from kid: String, paths: TeamPaths) throws
    }

    /// The link text as sealed, plus the decoded code it must be.
    public static func openInvite(_ invite: Invite, identity: TeamIdentity,
                                  now: Int = Int(Date().timeIntervalSince1970)) throws -> (text: String, code: TeamCode)
}
```

- [ ] **Step 1: Write the failing tests.** In `Tests/InfinitusCoreTests/TeamNearbyTests.swift`:

First, **fix the one existing assertion this task invalidates** — line 79 of `testRoutesAnswerOnlyWhenDiscoverable` currently reads

```swift
        XCTAssertEqual(status(TeamNearby.respond(http("POST", "/team/invite"), endpoint: endpoint)), 404)
```

and its comment on line 77 says "Wrong method, and step 6's route that isn't here yet." Replace those two lines with:

```swift
        // Wrong method on a real route.
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.requestPath), endpoint: endpoint)), 404)
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.invitePath), endpoint: endpoint)), 404)
        // The invite route exists now: a body that isn't one is a 400, not a 404.
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath), endpoint: endpoint)), 400)
```

(delete the now-duplicated `GET requestPath` line that was already there — keep exactly one of it.)

Then append two new test functions:

```swift
    func testInviteRouteKeepsASealedInviteAndRefusesAnythingItCannotOpen() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let local = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        let endpoint = TeamNearby.Endpoint(local: local, store: { _ in "branch" },
                                           storeInvite: { try TeamNearby.Store.saveInvite($0, paths: jp) })
        let link = try TeamInvites.mint(client: leader, teamDir: lp.teamDir(leader.config.id), days: 7, now: 1_000)
        let sealed = try Envelope.seal(Data(link.utf8), kind: "invite", from: leader.identity, to: [joiner.keys], at: 1_001)
        let invite = TeamNearby.Invite(from: leader.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: sealed)

        let ok = TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: endpoint)
        XCTAssertEqual(status(ok), 200)
        XCTAssertEqual(try body(TeamNearby.InviteReply.self, ok), TeamNearby.InviteReply(ok: true))
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp), [invite])
        XCTAssertEqual(invite.at, 1_001)

        // The envelope's sender must be the `from` the body claims.
        var lying = invite; lying.from = TeamIdentity.random().keys
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(lying)), endpoint: endpoint)), 400)
        // Sealed to someone else: this machine is not among the recipients.
        let elsewhere = try Envelope.seal(Data(link.utf8), kind: "invite", from: leader.identity,
                                          to: [TeamIdentity.random().keys], at: 1_001)
        let notMine = TeamNearby.Invite(from: leader.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: elsewhere)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(notMine)), endpoint: endpoint)), 400)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: Data("nope".utf8)), endpoint: endpoint)), 400)
        // A hidden machine says nothing at all.
        let hidden = TeamNearby.Endpoint(local: .hidden, store: { _ in "branch" })
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: hidden)), 404)
        // A store that refuses is a 503, not a crash — and an endpoint with
        // no invite store wired refuses the same way.
        let unwired = TeamNearby.Endpoint(local: local, store: { _ in "branch" })
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: unwired)), 503)

        // Opening gives the link back verbatim and the code it decodes to.
        let opened = try TeamNearby.openInvite(invite, identity: joiner, now: 1_002)
        XCTAssertEqual(opened.text, link)
        XCTAssertEqual(opened.code.team, leader.config.id)
        XCTAssertNotNil(opened.code.nonce)
        // A forged sender key never opens it, and neither does the wrong identity.
        var wrongSender = invite; wrongSender.from = TeamIdentity.random().keys
        XCTAssertThrowsError(try TeamNearby.openInvite(wrongSender, identity: joiner, now: 1_002))
        XCTAssertThrowsError(try TeamNearby.openInvite(invite, identity: TeamIdentity.random(), now: 1_002))
        // An expired code is refused at open time, not at accept time.
        XCTAssertThrowsError(try TeamNearby.openInvite(invite, identity: joiner, now: 1_000 + 8 * 86_400)) {
            XCTAssertEqual($0 as? TeamCode.CodeError, .expired)
        }

        // Ignoring removes it; twice is an error, never a silent success.
        try TeamNearby.Store.removeInvite(from: leader.identity.kid, paths: jp)
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp), [])
        XCTAssertThrowsError(try TeamNearby.Store.removeInvite(from: leader.identity.kid, paths: jp)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .noInvite)
        }
    }

    func testInvitesLiveBesideTheTeamsAndAreCapped() throws {
        let (jp, _) = machine("joiner")
        func invite(_ from: TeamIdentity, team: String = "T") throws -> TeamNearby.Invite {
            TeamNearby.Invite(from: from.keys, fromName: "L", teamName: team,
                              envelope: try Envelope.seal(Data("x".utf8), kind: "invite", from: from, to: [], at: 1))
        }
        for _ in 0..<TeamNearby.inviteCap {
            try TeamNearby.Store.saveInvite(try invite(TeamIdentity.random()), paths: jp)
        }
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp).count, TeamNearby.inviteCap)
        // The invites dir is beside the team dirs, never inside one, and is
        // not mistaken for a team (no config.json).
        XCTAssertEqual(TeamNearby.Store.invitesDir(paths: jp), jp.base.appendingPathComponent("invites"))
        XCTAssertEqual(jp.teamIDs(), [])
        // Full: a new sender is refused.
        XCTAssertThrowsError(try TeamNearby.Store.saveInvite(try invite(TeamIdentity.random()), paths: jp)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .full)
        }
        // …but a sender already in the book may replace its own invite.
        let first = try XCTUnwrap(TeamNearby.Store.invites(paths: jp).first)
        var again = first; again.teamName = "T2"
        XCTAssertNoThrow(try TeamNearby.Store.saveInvite(again, paths: jp))
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp).count, TeamNearby.inviteCap)
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp).first?.teamName, "T2")
        // A garbled or misnamed file is skipped, not fatal.
        let dir = TeamNearby.Store.invitesDir(paths: jp)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("zzz.json"))
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp).count, TeamNearby.inviteCap)
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamNearbyTests` → compile FAIL (no `invitePath`, no `Invite`).

- [ ] **Step 3: Implement.** In `Sources/InfinitusCore/Team/TeamNearby.swift`:

(a) Update the file's header comment — its last sentence currently says "`POST /team/invite` is step 6's." Replace that sentence with: "`POST /team/invite` is the leader's half of §6.4: an invite link sealed to one peer."

(b) Beside `keyPath` / `requestPath` (lines 10–11) add:

```swift
    public static let invitePath = "/team/invite"
```

(c) After `pendingCap` (line 21) add:

```swift
    /// Invitations a machine will hold at once. An unauthenticated LAN
    /// peer can post one per kid, so the count is bounded the same way
    /// `pendingCap` bounds requests; a sender already in the book may
    /// always replace its own.
    public static let inviteCap = 20
```

(d) After `RequestReply` (line 53) add the wire types:

```swift
    /// `POST /team/invite` body (spec §6.4): the leader's keys and names,
    /// and the invite link (§6.2) sealed to the peer's encryption key.
    /// The link carries the store's write credential, so it exists on the
    /// wire and on disk only as ciphertext; `openInvite` is the only way
    /// back to the text, and it needs this machine's identity.
    public struct Invite: Codable, Equatable, Sendable, Identifiable {
        public var from: TeamKeys
        /// The inviting machine's display name, for "Loc invites you to Papaya".
        public var fromName: String
        public var teamName: String
        /// `Envelope.seal(Data(link.utf8), kind: "invite", …)`.
        public var envelope: Data

        public var id: String { from.kid }
        /// When the sender sealed it — read from the signed envelope
        /// header rather than a field of its own, so nobody can backdate
        /// an invitation without breaking the signature.
        public var at: Int { (try? Envelope.header(of: envelope).at) ?? 0 }

        public init(from: TeamKeys, fromName: String, teamName: String, envelope: Data) {
            self.from = from; self.fromName = fromName; self.teamName = teamName; self.envelope = envelope
        }
    }

    public struct InviteReply: Codable, Equatable, Sendable {
        public var ok: Bool
        public init(ok: Bool) { self.ok = ok }
    }
```

(e) Replace the `Endpoint` struct (lines 110–117) with:

```swift
    /// What the routes need: the local standing, where a request goes
    /// (`store` returns "branch" or "pending") and where an invitation
    /// goes (`storeInvite`).
    public struct Endpoint {
        public var local: Local
        public var store: (Request) throws -> String
        /// Defaulted to a refusal so an endpoint built without one answers
        /// 503 rather than pretending it kept the invitation.
        public var storeInvite: (Invite) throws -> Void

        public init(local: Local, store: @escaping (Request) throws -> String,
                    storeInvite: @escaping (Invite) throws -> Void = { _ in throw StoreError.full }) {
            self.local = local; self.store = store; self.storeInvite = storeInvite
        }
    }
```

The existing trailing-closure call sites (`TeamNearby.Endpoint(local: local) { … }`) keep binding to `store` under Swift's forward-scan trailing-closure matching; the test run in Step 4 proves it.

(f) In `respond`, insert a new case between the `requestPath` case (ends line 155) and `default:`:

```swift
        case ("POST", TeamNearby.invitePath):
            // The peer that sealed this must be the peer the body names,
            // and it must have sealed it to ME: an invitation nobody here
            // can open is refused rather than parked on disk. Everything
            // else about it — team, expiry, leader signature — is checked
            // when it is opened (`openInvite`), on the identity that can
            // actually read it.
            guard let invite = try? CanonicalJSON.decode(Invite.self, from: request.body),
                  Store.isPathSegment(invite.from.kid),
                  let header = try? Envelope.header(of: invite.envelope),
                  header.kind == "invite",
                  header.from == invite.from.kid,
                  header.to.contains(where: { $0.kid == keys.kid }) else {
                return MirrorTransport.badRequestResponse()
            }
            do {
                try endpoint.storeInvite(invite)
                guard let body = try? CanonicalJSON.encode(InviteReply(ok: true)) else {
                    return MirrorTransport.notFoundResponse()
                }
                return MirrorTransport.jsonResponse(body)
            } catch {
                return MirrorTransport.response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                                                body: Data("invite not stored\n".utf8))
            }
```

`keys` is the `let keys = endpoint.local.keys` already unwrapped at line 124, so a hidden endpoint still 404s before this runs.

(g) Add `noInvite` to `StoreError` (line 163):

```swift
    public enum StoreError: Error, Equatable {
        case unknownTeam, badKid, full
        /// `removeInvite` on an invitation that is already gone.
        case noInvite
    }
```

(h) Inside `enum Store`, after `pending(team:paths:)` (ends line 212), add:

```swift
        /// Invitations sit BESIDE the team dirs, not inside one: the
        /// invitee usually has no team yet. `teamIDs()` only counts
        /// directories with a config, so this one is never mistaken for
        /// a team.
        public static func invitesDir(paths: TeamPaths) -> URL {
            paths.base.appendingPathComponent("invites")
        }

        /// `<base>/invites/<from kid>.json`, the invitation exactly as it
        /// arrived — the envelope stays SEALED here. One file per sender,
        /// so a peer can refresh its own invitation but not flood.
        public static func saveInvite(_ invite: Invite, paths: TeamPaths) throws {
            let kid = invite.from.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let dir = invitesDir(paths: paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(kid).json")
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard existing.count < TeamNearby.inviteCap || FileManager.default.fileExists(atPath: file.path) else {
                throw StoreError.full
            }
            try CanonicalJSON.encode(invite).write(to: file)
        }

        /// Unreadable or misnamed files are skipped, like `pending`.
        public static func invites(paths: TeamPaths) -> [Invite] {
            let dir = invitesDir(paths: paths)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name in
                guard name.hasSuffix(".json"),
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let invite = try? CanonicalJSON.decode(Invite.self, from: data),
                      name == "\(invite.from.kid).json" else { return nil }
                return invite
            }
        }

        /// Accept and Ignore both end here. A missing file is `noInvite`,
        /// never a silent success — the phone shows "that invitation is
        /// gone" instead of a green tick over nothing.
        public static func removeInvite(from kid: String, paths: TeamPaths) throws {
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let file = invitesDir(paths: paths).appendingPathComponent("\(kid).json")
            guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.noInvite }
            try FileManager.default.removeItem(at: file)
        }
```

(i) After the `Store` enum's closing brace, still inside `enum TeamNearby` (i.e. before line 230's final `}`), add:

```swift
    /// Opens an invitation with this machine's identity (spec §6.4). The
    /// sender key is pinned to the `from` the body carried, so a stranger
    /// cannot pass its own envelope off as the leader's; `TeamCode.decode`
    /// then checks the leader's signature over the code and its expiry,
    /// which is what makes an opened invitation safe to join with. The
    /// TEXT comes back as sealed — the caller hands that to
    /// `TeamClient.request(code:…)` rather than re-encoding the code,
    /// which would need the leader's key to sign.
    public static func openInvite(_ invite: Invite, identity: TeamIdentity,
                                  now: Int = Int(Date().timeIntervalSince1970)) throws -> (text: String, code: TeamCode) {
        let (_, plaintext) = try Envelope.open(invite.envelope, as: identity,
                                               senderKey: { $0 == invite.from.kid ? invite.from : nil })
        let text = String(decoding: plaintext, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, try TeamCode.decode(text, now: now))
    }
```

- [ ] **Step 4: Run** `swift test --filter "TeamNearby|TeamInvites"` → PASS. `swift build` (all products) → succeeds; if `MirrorServer.swift` or `TeamNearbyCommand.swift` fail to compile, the `Endpoint` default is missing — do NOT edit those files here, fix the default.
- [ ] **Step 5: Commit**

```
git add Sources/InfinitusCore/Team/TeamNearby.swift Tests/InfinitusCoreTests/TeamNearbyTests.swift
git commit -m "team: POST /team/invite keeps a sealed LAN invitation, openable only by its recipient (spec §6.4)"
```

---

### Task 3: `TeamNearby.Client.invite` — the leader's half, and both endpoints wired

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamNearby.swift` (the `Client` enum only)
- Modify: `Sources/Infinitus/MirrorServer.swift` — ONLY `MirrorTeamBox.endpoint`, lines 254–262
- Modify: `Sources/InfinitusCLI/TeamNearbyCommand.swift` — ONLY the `TeamNearby.Endpoint(` construction, line 140
- Test: `Tests/InfinitusCoreTests/TeamNearbyTests.swift`
- Do not touch: everything in the "Do not touch" list; in particular no other line of `MirrorServer.swift`.

**Interfaces:**
- Consumes: Task 1's `TeamInvites.mint`, Task 2's `Invite` / `InviteReply` / `invitePath` / `Store.saveInvite`.
- Produces (used by Tasks 4, 5):

```swift
extension TeamNearby.Client {
    public struct InviteOutcome: Equatable, Sendable {
        public var team: String, teamName: String, to: String, ok: Bool
    }
    public static func invite(to peer: Peer, fromName: String, days: Int = 7, team: String? = nil,
                              paths: TeamPaths, secrets: TeamSecrets, http: HTTP,
                              now: Int = Int(Date().timeIntervalSince1970)) throws -> InviteOutcome
}
```

**No new `ClientError` cases.** `TeamModel.mask` switches over `ClientError` exhaustively at lines 121–128 and that region is not this stream's, so `invite` reuses `.notALeader` (this machine leads no team, or the peer has no kid), `.keyMismatch(status)` (`/team/key` disagrees with the TXT record) and `.refused(status)`.

- [ ] **Step 1: Write the failing test.** Append to `Tests/InfinitusCoreTests/TeamNearbyTests.swift`:

```swift
    func testLeaderInvitesAPeerAndTheOpenedLinkJoinsAndAutoApproves() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let peerLocal = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        let peerEndpoint = TeamNearby.Endpoint(local: peerLocal, store: { _ in "branch" },
                                               storeInvite: { try TeamNearby.Store.saveInvite($0, paths: jp) })
        // An HTTP function that routes into the peer's own `respond` — no sockets.
        let http: TeamNearby.Client.HTTP = { method, _, _, path, body in
            let reply = TeamNearby.respond(MirrorTransport.Request(method: method, target: path, headers: [:],
                                                                   body: body ?? Data()), endpoint: peerEndpoint)
            let parsed = try XCTUnwrap(reply.flatMap(MirrorTransport.parseResponse))
            return (parsed.status, parsed.body)
        }
        let peer = TeamNearby.Peer(name: "Bo", host: "bo.local", port: 1, kid: joiner.kid,
                                   team: nil, role: "none", discoverable: true)

        let out = try TeamNearby.Client.invite(to: peer, fromName: "Loc", days: 7,
                                               paths: lp, secrets: ls, http: http, now: 1_010)
        XCTAssertEqual(out, TeamNearby.Client.InviteOutcome(team: leader.config.id, teamName: "Papaya",
                                                            to: joiner.kid, ok: true))
        let stored = try XCTUnwrap(TeamNearby.Store.invites(paths: jp).first)
        XCTAssertEqual(stored.from, leader.identity.keys)
        XCTAssertEqual(stored.fromName, "Loc")
        XCTAssertEqual(stored.teamName, "Papaya")

        // The nonce is in the leader's own book with the link's expiry.
        let opened = try TeamNearby.openInvite(stored, identity: joiner, now: 1_011)
        let nonce = try XCTUnwrap(opened.code.nonce)
        XCTAssertEqual(TeamInvites.load(teamDir: lp.teamDir(leader.config.id)).nonces[nonce], 1_010 + 7 * 86_400)

        // Accepting with the opened text lands a request the leader's
        // auto-approve recognises (#161's proof).
        let member = try TeamClient.request(code: opened.text, name: "Bo", devices: ["Linux"], platform: "linux",
                                            paths: jp, secrets: js, now: 1_012)
        XCTAssertEqual(member.config.id, leader.config.id)
        _ = try leader.fetch()
        let pending = try XCTUnwrap(try leader.requests().first)
        XCTAssertEqual(TeamInvites.load(teamDir: lp.teamDir(leader.config.id)).matches(pending.doc, now: 1_013), nonce)

        // A peer whose TXT kid is not what /team/key answers: nothing sealed, nothing sent.
        var liar = peer; liar.kid = TeamIdentity.random().kid
        XCTAssertThrowsError(try TeamNearby.Client.invite(to: liar, fromName: "Loc", paths: lp, secrets: ls, http: http)) {
            guard case TeamNearby.Client.ClientError.keyMismatch = $0 else { return XCTFail("\($0)") }
        }
        // A machine that leads no team cannot invite (the joiner is a member at best).
        XCTAssertThrowsError(try TeamNearby.Client.invite(to: peer, fromName: "Bo", paths: jp, secrets: js, http: http)) {
            XCTAssertEqual($0 as? TeamNearby.Client.ClientError, .notALeader)
        }
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamNearbyTests` → compile FAIL (no `Client.invite`).

- [ ] **Step 3: Implement `Client.invite`** in `Sources/InfinitusCore/Team/TeamNearby.swift`, inside `public enum Client`, after `request(to:name:devices:platform:paths:secrets:http:now:)` (ends line 293):

```swift
        public struct InviteOutcome: Equatable, Sendable {
            public var team: String, teamName: String, to: String, ok: Bool
        }

        /// The leader's half of §6.4: mint an invite link, seal it to the
        /// keys `GET /team/key` hands back — checked against the TXT kid
        /// exactly as `request` does, so a peer that lies about who it is
        /// never receives a credential — and POST it. Nothing but
        /// ciphertext crosses the LAN. `team` picks which team when this
        /// machine leads several; nil takes the first it leads.
        public static func invite(to peer: Peer, fromName: String, days: Int = 7, team: String? = nil,
                                  paths: TeamPaths, secrets: TeamSecrets, http: HTTP,
                                  now: Int = Int(Date().timeIntervalSince1970)) throws -> InviteOutcome {
            guard peer.discoverable, let peerKid = peer.kid else { throw ClientError.notALeader }
            var mine: TeamClient?
            for id in team.map({ [$0] }) ?? paths.teamIDs() {
                guard let candidate = try? TeamClient.open(id: id, paths: paths, secrets: secrets),
                      candidate.isLeader else { continue }
                mine = candidate
                break
            }
            guard let client = mine else { throw ClientError.notALeader }
            let (keyStatus, keyBody) = try http("GET", peer.host, peer.port, keyPath, nil)
            guard keyStatus == 200,
                  let reply = try? CanonicalJSON.decode(KeyReply.self, from: keyBody),
                  reply.keys.kid == peerKid else { throw ClientError.keyMismatch(keyStatus) }
            let link = try TeamInvites.mint(client: client, teamDir: paths.teamDir(client.config.id),
                                            days: days, now: now)
            let sealed = try Envelope.seal(Data(link.utf8), kind: "invite", from: client.identity,
                                           to: [reply.keys], at: now)
            let body = try CanonicalJSON.encode(Invite(from: client.identity.keys, fromName: fromName,
                                                       teamName: client.config.name, envelope: sealed))
            let (status, replyBody) = try http("POST", peer.host, peer.port, invitePath, body)
            guard status == 200,
                  let sent = try? CanonicalJSON.decode(InviteReply.self, from: replyBody), sent.ok else {
                throw ClientError.refused(status)
            }
            return InviteOutcome(team: client.config.id, teamName: client.config.name, to: peerKid, ok: true)
        }
```

- [ ] **Step 4: Wire the Mac's endpoint.** In `Sources/Infinitus/MirrorServer.swift`, replace `MirrorTeamBox.endpoint` (lines 254–262) with:

```swift
    /// Where a LAN request lands: pending under the team, then the
    /// requests branch — a git push, so callers run it off the network
    /// queue. An invitation (spec §6.4) is only a file write: it stays
    /// sealed until the Team pane's Accept opens it.
    var endpoint: TeamNearby.Endpoint {
        TeamNearby.Endpoint(local: current, store: { request in
            let paths = TeamPaths.standard()
            return try TeamNearby.Store.save(request, paths: paths, secrets: FileSecrets(dir: paths.secretsDir))
        }, storeInvite: { invite in
            try TeamNearby.Store.saveInvite(invite, paths: TeamPaths.standard())
        })
    }
```

No other line of `MirrorServer.swift` changes: the LAN `/team/*` branch (lines 588–599) already forwards every method and path to `TeamNearby.respond`, and `MirrorTransport.bodyCap(method:path:)` (MirrorTransport.swift line 192) gives `/team/*` the 16 KiB `defaultBodyCap`, which a sealed invite link (a base64 envelope of a ~600-byte link, plus two `TeamKeys`) sits far inside. Confirm that by reading both, and say so in the report; do not change either.

- [ ] **Step 5: Wire the Linux endpoint.** In `Sources/InfinitusCLI/TeamNearbyCommand.swift`, replace line 140 with:

```swift
    let endpoint = TeamNearby.Endpoint(local: local,
                                       store: { try TeamNearby.Store.save($0, paths: paths, secrets: secrets) },
                                       storeInvite: { try TeamNearby.Store.saveInvite($0, paths: paths) })
```

- [ ] **Step 6: Run** `swift test --filter TeamNearbyTests` → PASS. `swift build --product Infinitus` and `swift build --product infinitusctl` (ONE `--product` per invocation) → succeed.
- [ ] **Step 7: Commit**

```
git add Sources/InfinitusCore/Team/TeamNearby.swift Sources/Infinitus/MirrorServer.swift Sources/InfinitusCLI/TeamNearbyCommand.swift Tests/InfinitusCoreTests/TeamNearbyTests.swift
git commit -m "team: a leader invites a discoverable peer over the LAN; both listeners keep the sealed invitation"
```

---

### Task 4: CLI — `team nearby invite`, `team invites`, `team accept`, `team ignore`

**Files:**
- Modify: `Sources/InfinitusCLI/TeamNearbyCommand.swift`
- Do not touch: everything in the "Do not touch" list — in particular `Sources/InfinitusCLI/TeamCommand.swift` and its `teamUsage()`. The new subcommands are documented in `teamNearbyUsage()` only, because `runTeam` (TeamCommand.swift line 67) calls `runTeamNearby(args)` first and this file answers whatever it claims.

**Interfaces:**
- Consumes: Tasks 2 and 3 (`Store.invites`, `Store.removeInvite`, `openInvite`, `Client.invite`).
- Produces: four CLI verbs. No new exported Swift API.

- [ ] **Step 1: Usage text.** Replace `teamNearbyUsage()` (lines 16–28) with:

```swift
func teamNearbyUsage() -> String {
    """
    usage: infinitusctl team nearby [--seconds N]
               list Infinitus machines on this network (default 3 s)
           infinitusctl team nearby invite <kid|name> [--days N] [--seconds N] [--as <n>] [--team <id>]
               (leader) seal an invite link to that discoverable machine and send it over the LAN
           infinitusctl team invites
               invitations sent to this machine (never the link inside)
           infinitusctl team accept <kid> --name <n> [--devices a,b]
               open the invitation from that kid and ask to join its team
           infinitusctl team ignore <kid>
               delete that invitation
           infinitusctl team request --nearby <kid> --name <n> [--devices a,b] [--seconds N]
               send a join request to that leader over the LAN — no code to paste
           infinitusctl team --discoverable [--name <n>] [--port N]
               advertise this machine and answer /team/key + /team/request + /team/invite until Ctrl-C (Linux;
               on the Mac the app advertises: `infinitusctl team-discoverable on`).
               Binds every interface: run it on a LAN you trust, never on a box with a public address.

    """
}
```

- [ ] **Step 2: Claim the new subcommands and parse positionals.** In `runTeamNearby` replace lines 51–70 with:

```swift
    guard let sub = args.first else { return nil }
    let mine = sub == "nearby" || sub == "--discoverable" || sub == "invites" || sub == "accept" || sub == "ignore"
        || (sub == "request" && args.contains("--nearby"))
    guard mine else { return nil }
    if args.contains("--help") || args.contains("-h") {
        print(teamNearbyUsage(), terminator: "")
        return 0
    }
    // Every option takes a value; a bare flag is a typo (same rule as
    // `runTeam`). Positionals name a subcommand's target — `nearby
    // invite <kid>`, `accept <kid>`.
    var options: [String: String] = [:]
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamNearbyUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
```

- [ ] **Step 3: The rows the listing emits.** Add above `runTeamNearby` (after the `fail` helper, line 47):

```swift
/// What `team invites` prints. The sealed envelope — and so the link and
/// its store credential — is never in it.
private struct InviteRow: Encodable {
    var from: String, kid: String, team: String, at: Int
}

private struct InviteSent: Encodable {
    var ok: Bool, team: String, teamName: String, to: String
}

private struct AcceptedInvite: Encodable {
    var team: String, name: String, kid: String
}
```

- [ ] **Step 4: The subcommands.** In the `switch sub` block, replace `case "nearby":` (lines 76–77) with:

```swift
        case "nearby":
            if positional.first == "invite" {
                guard let target = positional.dropFirst().first, positional.count == 2 else {
                    return fail(teamNearbyUsage(), code: 2)
                }
                guard let peer = try TeamNearby.Client.browse(seconds: seconds).first(where: {
                    $0.discoverable && ($0.kid == target || $0.name == target)
                }) else {
                    return fail("no discoverable machine called \(target) answered within \(Int(seconds))s")
                }
                let days = Int(options["days"] ?? "7") ?? 7
                let machine = options["as"] ?? ProcessInfo.processInfo.hostName
                do {
                    let out = try TeamNearby.Client.invite(to: peer, fromName: machine, days: days,
                                                           team: options["team"], paths: paths, secrets: secrets,
                                                           http: { m, h, p, path, body in try http(m, host: h, port: p, path: path, body: body) })
                    emit(InviteSent(ok: out.ok, team: out.team, teamName: out.teamName, to: out.to))
                } catch TeamNearby.Client.ClientError.notALeader {
                    return fail("this machine leads no team (\(peer.name) can only be invited by a leader)")
                } catch TeamNearby.Client.ClientError.keyMismatch(let s) {
                    return fail("\(peer.name) is not answering \(TeamNearby.keyPath) (\(s))")
                } catch TeamNearby.Client.ClientError.refused(let s) {
                    return fail("\(peer.name) refused the invitation (\(s))")
                }
                break
            }
            guard positional.isEmpty else { return fail(teamNearbyUsage(), code: 2) }
            emit(try TeamNearby.Client.browse(seconds: seconds))
        case "invites":
            emit(TeamNearby.Store.invites(paths: paths).map {
                InviteRow(from: $0.fromName, kid: $0.from.kid, team: $0.teamName, at: $0.at)
            })
        case "accept":
            guard let kid = positional.first, positional.count == 1, let name = options["name"] else {
                return fail(teamNearbyUsage(), code: 2)
            }
            // Accepting is joining (spec §2.2), so it takes the same gate
            // `team request` takes in TeamCommand.swift.
            if case .needsLock(let why) = TeamGate.check(lockEnabled: LockSetting.enabledOnThisMachine()) {
                return fail("\(why) (Infinitus › Settings › Lock)")
            }
            guard let invite = TeamNearby.Store.invites(paths: paths).first(where: { $0.from.kid == kid }) else {
                return fail("no invitation from \(kid) (`infinitusctl team invites` lists them)")
            }
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let opened = try TeamNearby.openInvite(invite, identity: me)
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            let joined = try TeamClient.request(code: opened.text, name: name, devices: devices,
                                                platform: nearbyPlatform, paths: paths, secrets: secrets)
            try TeamNearby.Store.removeInvite(from: kid, paths: paths)
            emit(AcceptedInvite(team: joined.config.id, name: joined.config.name, kid: me.kid))
        case "ignore":
            guard let kid = positional.first, positional.count == 1 else { return fail(teamNearbyUsage(), code: 2) }
            try TeamNearby.Store.removeInvite(from: kid, paths: paths)
            emit(["ignored": kid])
```

The invite link never reaches argv or stdout: `accept` prints the team id and name only, and `invites` prints `InviteRow`.

- [ ] **Step 5: Build and smoke.** `swift build --product infinitusctl` → succeeds. Then, against a scratch team dir so nothing real is touched:

```
INFINITUS_TEAM_DIR=/tmp/nb2-cli .build/debug/infinitusctl team invites
INFINITUS_TEAM_DIR=/tmp/nb2-cli .build/debug/infinitusctl team ignore zzz
INFINITUS_TEAM_DIR=/tmp/nb2-cli .build/debug/infinitusctl team nearby --help
```

Expected: `[]` from `invites`; `error: noInvite`-shaped failure (exit 1) from `ignore zzz`; the new usage block from `--help`. `rm -rf /tmp/nb2-cli` afterwards.

- [ ] **Step 6: Commit**

```
git add Sources/InfinitusCLI/TeamNearbyCommand.swift
git commit -m "infinitusctl: team nearby invite, team invites, team accept, team ignore"
```

---

### Task 5: Mac — `TeamModel` invitations and the Team pane's two Nearby sections

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift` — ONE new `@Published` line beside line 37, and the `// MARK: nearby (spec §6.4)` block (lines 317–376)
- Modify: `Sources/Infinitus/TeamPane.swift` — `Section("Nearby teams")` (lines 101–119), a NEW `Section("Invitations")` under it, the leader's `Section("Nearby")` (lines 176–193)
- Do not touch: everything in the "Do not touch" list; no other line of either file.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces (used by Task 6):

```swift
@MainActor final class TeamModel {
    @Published private(set) var invites: [TeamNearby.Invite]
    func loadInvites() async
    func inviteNearby(_ peer: TeamNearby.Peer) async
    func acceptInvite(_ invite: TeamNearby.Invite, name: String) async
    func ignoreInvite(_ invite: TeamNearby.Invite) async
}
```

- [ ] **Step 1: The published list.** In `TeamModel.swift`, immediately after line 37 (`@Published private(set) var nearby: [TeamNearby.Peer] = []`), insert exactly:

```swift
    /// Invitations this Mac has been sent over the LAN (spec §6.4), each
    /// still sealed; the link inside is opened only by `acceptInvite`.
    @Published private(set) var invites: [TeamNearby.Invite] = []
```

- [ ] **Step 2: The nearby block.** Still in `TeamModel.swift`, add `await loadInvites()` as the last statement of `scanNearby()` — replace lines 321–330 with:

```swift
    func scanNearby() async {
        guard enabled, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            let me = kid
            let peers = try await run { _, _ in try TeamNearby.Client.browse(seconds: 2) }
            nearby = peers.filter { $0.discoverable && $0.kid != me }
        } catch { lastError = Self.mask(error) }
        await loadInvites()
    }

    /// An invitation can land while the pane sits open and nothing else
    /// reads that directory, so the Nearby scan refreshes it too. A file
    /// read on the team queue, no network.
    func loadInvites() async {
        guard enabled else { return }
        do { invites = try await run { paths, _ in TeamNearby.Store.invites(paths: paths) } }
        catch { lastError = Self.mask(error) }
    }
```

Then, after `pullNearbyRequest(_:)` (ends line 376) and before the `// MARK: policy + aggregates` line, add:

```swift
    /// Leader: seal an invite link to a discoverable peer and POST it
    /// (spec §6.4). Not gated — minting an invite is not gated either
    /// (`mintInvite`); the pane disables the button when the lock is off,
    /// the same shape the Invite section uses.
    func inviteNearby(_ peer: TeamNearby.Peer) async {
        let machine = Host.current().localizedName ?? "Mac"
        await action("Inviting \(peer.name)…") { paths, secrets in
            _ = try TeamNearby.Client.invite(to: peer, fromName: machine, paths: paths, secrets: secrets,
                                             http: Self.blockingHTTP)
        }
    }

    /// Accepting an invitation IS joining (spec §2.2 gate): open the
    /// sealed link with this machine's identity, request with the text
    /// exactly as sealed, then drop the invitation file. The leader
    /// auto-approves it — the nonce is one it minted.
    func acceptInvite(_ invite: TeamNearby.Invite, name: String) async {
        guard gated() else { return }
        let device = Host.current().localizedName ?? "Mac"
        await action("Accepting…") { paths, secrets in
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let opened = try TeamNearby.openInvite(invite, identity: me)
            _ = try TeamClient.request(code: opened.text, name: name, devices: [device], platform: "macos",
                                       paths: paths, secrets: secrets)
            try TeamNearby.Store.removeInvite(from: invite.from.kid, paths: paths)
        }
        await loadInvites()
    }

    func ignoreInvite(_ invite: TeamNearby.Invite) async {
        await action("Ignoring…") { paths, _ in
            try TeamNearby.Store.removeInvite(from: invite.from.kid, paths: paths)
        }
        await loadInvites()
    }
```

- [ ] **Step 3: The pane's Invitations section.** In `TeamPane.swift`, directly after the `Section("Nearby teams") { … }.task { await team.scanNearby() }` block (lines 101–119) and before `Section("Identity")` (line 120), insert:

```swift
            if !team.invites.isEmpty {
                Section("Invitations") {
                    ForEach(team.invites) { invite in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(invite.fromName) invites you to \(invite.teamName)").bold()
                                Text(invite.from.kid).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Accept") { Task { await team.acceptInvite(invite, name: joinName) } }
                                .disabled(!gateOpen || joinName.isEmpty)
                            Button("Ignore") { Task { await team.ignoreInvite(invite) } }
                        }
                    }
                    Text("The invitation stays sealed on this Mac until you accept; accepting joins straight away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 4: The leader's Nearby peers get Invite.** In `TeamPane.swift`, replace the peer `ForEach` (lines 184–186) with:

```swift
                    ForEach(team.nearby) { peer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peer.name).bold()
                                Text("\(peer.role) · \(peer.team == snap.id ? "in this team" : "not in this team")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.team != snap.id {
                                Button("Invite") { Task { await team.inviteNearby(peer) } }.disabled(!gateOpen)
                            }
                        }
                    }
```

and replace the caption on line 191 with:

```swift
                    Text("Members can request to join from their Team pane, or you can invite a discoverable Mac; either way they appear in Requests once approved.")
                        .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 5: Build.** `swift build --product Infinitus` → succeeds. `swift test` → green (nothing here is covered by a test target; the build IS the gate). Read the diff back and confirm no line outside the four regions moved: `git diff --stat` shows only `TeamModel.swift` and `TeamPane.swift`, and `git diff Sources/Infinitus/TeamPane.swift` touches only lines inside 101–193.
- [ ] **Step 6: Commit**

```
git add Sources/Infinitus/TeamModel.swift Sources/Infinitus/TeamPane.swift
git commit -m "team pane: Invitations on the joining Mac, Invite on the leader's Nearby peers (spec §6.4)"
```

---

### Task 6: `/mirror/team/nearby*` — wire types and the Mac handler

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamMirror.swift`
- Create: `Sources/Infinitus/TeamMirrorNearby.swift`
- Modify: `Sources/Infinitus/TeamMirrorHandler.swift` — ONE contiguous insertion at `default:` (lines 49–50)
- Test: `Tests/InfinitusCoreTests/TeamMirrorTests.swift` — NEW functions only
- Do not touch: everything in the "Do not touch" list; in this task also leave `TeamModel.swift`, `TeamPane.swift`, `MirrorServer.swift` and every `ios/` file alone.

**Interfaces:**
- Consumes: Task 5's `TeamModel` methods, Task 2's `TeamNearby.Invite`.
- Produces (used by Task 7):

```swift
public enum TeamMirror {
    public static let nearbyPath        = "/mirror/team/nearby"          // GET  → NearbyReply
    public static let nearbyScanPath    = "/mirror/team/nearby/scan"     // POST Empty → NearbyReply
    public static let nearbyRequestPath = "/mirror/team/nearby/request"  // POST NearbyJoinRequest → ActionReply
    public static let nearbyInvitePath  = "/mirror/team/nearby/invite"   // POST KidRequest → ActionReply
    public static let nearbyPullPath    = "/mirror/team/nearby/pull"     // POST KidRequest → ActionReply
    public static let nearbyAcceptPath  = "/mirror/team/nearby/accept"   // POST InviteAccept → ActionReply
    public static let nearbyIgnorePath  = "/mirror/team/nearby/ignore"   // POST KidRequest → ActionReply

    public struct Empty: Codable, Equatable, Sendable { public init() }
    public struct PendingRequest: Codable, Equatable, Sendable, Identifiable { public var kid, name, platform: String; public var at: Int }
    public struct InviteSummary: Codable, Equatable, Sendable, Identifiable { public var fromKid, fromName, teamName: String }
    public struct NearbyReply: Codable, Equatable, Sendable {
        public var peers: [TeamNearby.Peer]
        public var pending: [PendingRequest]
        public var invites: [InviteSummary]
        public var team: String?
    }
    public struct NearbyJoinRequest: Codable, Equatable, Sendable { public var kid, name: String }
    public struct InviteAccept: Codable, Equatable, Sendable { public var fromKid, name: String }
}
```

- [ ] **Step 1: Write the failing test.** Append to `Tests/InfinitusCoreTests/TeamMirrorTests.swift` (leave the three existing functions untouched):

```swift
    func testNearbyPathsSitUnderTheTokenGatedPrefix() {
        for p in [TeamMirror.nearbyPath, TeamMirror.nearbyScanPath, TeamMirror.nearbyRequestPath,
                  TeamMirror.nearbyInvitePath, TeamMirror.nearbyPullPath, TeamMirror.nearbyAcceptPath,
                  TeamMirror.nearbyIgnorePath] {
            XCTAssertTrue(p.hasPrefix(TeamMirror.prefix + "/"), p)
            XCTAssertFalse(p.hasPrefix(TeamNearby.routePrefix), "\(p) would be token-exempt from the LAN")
        }
        // The scan path is a sibling of the list path, not a shadow of it.
        XCTAssertNotEqual(TeamMirror.nearbyPath, TeamMirror.nearbyScanPath)
    }

    func testNearbyRepliesTravelAndCarryNothingSecret() throws {
        let reply = TeamMirror.NearbyReply(
            peers: [TeamNearby.Peer(name: "Bo", host: "bo.local", port: 1, kid: "k1",
                                    team: nil, role: "none", discoverable: true)],
            pending: [TeamMirror.PendingRequest(kid: "k2", name: "Ann", platform: "macos", at: 3)],
            invites: [TeamMirror.InviteSummary(fromKid: "k3", fromName: "Loc", teamName: "Papaya")],
            team: "t1")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyReply.self, from: try JSONEncoder().encode(reply)), reply)
        let empty = TeamMirror.NearbyReply(peers: [], pending: [], invites: [], team: nil)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyReply.self, from: try JSONEncoder().encode(empty)), empty)
        // Spec §10: the phone's Nearby view is names and kids, never a
        // code, a token or a sealed invitation.
        let json = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        for secret in ["envelope", "token", "code", "nonce"] {
            XCTAssertFalse(json.contains(secret), "\(secret) must not travel in NearbyReply")
        }
        let accept = TeamMirror.InviteAccept(fromKid: "k3", name: "Bo")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.InviteAccept.self, from: try JSONEncoder().encode(accept)), accept)
        let join = TeamMirror.NearbyJoinRequest(kid: "k1", name: "Bo")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyJoinRequest.self, from: try JSONEncoder().encode(join)), join)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.Empty.self, from: try JSONEncoder().encode(TeamMirror.Empty())),
                       TeamMirror.Empty())
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamMirrorTests` → compile FAIL.

- [ ] **Step 3: Implement the wire types.** In `Sources/InfinitusCore/Team/TeamMirror.swift`, after `codePath` (line 15) add:

```swift
    // Nearby (spec §6.4 last bullet): the Mac's LAN lists on the phone.
    public static let nearbyPath = prefix + "/nearby"
    public static let nearbyScanPath = prefix + "/nearby/scan"
    public static let nearbyRequestPath = prefix + "/nearby/request"
    public static let nearbyInvitePath = prefix + "/nearby/invite"
    public static let nearbyPullPath = prefix + "/nearby/pull"
    public static let nearbyAcceptPath = prefix + "/nearby/accept"
    public static let nearbyIgnorePath = prefix + "/nearby/ignore"
```

and after `MemberReply` (ends line 48) add:

```swift
    /// A POST with nothing to say (`nearby/scan`): the transport always
    /// sends a body, so it sends this one.
    public struct Empty: Codable, Equatable, Sendable {
        public init() {}
    }

    /// A LAN join request the Mac holds but has not filed yet.
    public struct PendingRequest: Codable, Equatable, Sendable, Identifiable {
        public var kid: String
        public var name: String
        public var platform: String
        public var at: Int
        public var id: String { kid }
        public init(kid: String, name: String, platform: String, at: Int) {
            self.kid = kid; self.name = name; self.platform = platform; self.at = at
        }
    }

    /// An invitation as the phone may see it (spec §10): who and which
    /// team, never the sealed envelope the link lives in.
    public struct InviteSummary: Codable, Equatable, Sendable, Identifiable {
        public var fromKid: String
        public var fromName: String
        public var teamName: String
        public var id: String { fromKid }
        public init(fromKid: String, fromName: String, teamName: String) {
            self.fromKid = fromKid; self.fromName = fromName; self.teamName = teamName
        }
    }

    public struct NearbyReply: Codable, Equatable, Sendable {
        public var peers: [TeamNearby.Peer]
        public var pending: [PendingRequest]
        public var invites: [InviteSummary]
        /// This Mac's team id, so the phone can tell "in this team" from
        /// "not in this team" without a second call.
        public var team: String?
        public init(peers: [TeamNearby.Peer], pending: [PendingRequest], invites: [InviteSummary], team: String?) {
            self.peers = peers; self.pending = pending; self.invites = invites; self.team = team
        }
    }

    public struct NearbyJoinRequest: Codable, Equatable, Sendable {
        public var kid: String
        public var name: String
        public init(kid: String, name: String) { self.kid = kid; self.name = name }
    }

    public struct InviteAccept: Codable, Equatable, Sendable {
        public var fromKid: String
        public var name: String
        public init(fromKid: String, name: String) { self.fromKid = fromKid; self.name = name }
    }
```

- [ ] **Step 4: Run** `swift test --filter TeamMirrorTests` → PASS.

- [ ] **Step 5: The Mac handler.** Create `Sources/Infinitus/TeamMirrorNearby.swift`:

```swift
import Foundation
import InfinitusCore

/// The phone's Nearby (spec §6.4 last bullet): `/mirror/team/nearby*`
/// onto the very TeamModel methods the Mac pane's Nearby sections call,
/// so there is one policy and one error path. Its own file to keep
/// TeamMirrorHandler's switch one concern wide; `nil` means "not one of
/// mine" and the handler's `default` turns that into a 404. Every reply
/// is a JSON body — MirrorServer wraps it (`MirrorTransport.jsonResponse`).
@MainActor
enum TeamMirrorNearby {
    static func handle(_ r: MirrorTransport.Request, team: TeamModel) async -> Data? {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T) -> Data? { try? encoder.encode(v) }
        func action(_ body: () async -> Void) async -> Data? {
            team.clearError()
            await body()
            return json(TeamMirror.ActionReply(ok: team.lastError == nil, error: team.lastError))
        }
        func gone() -> Data? { json(TeamMirror.ActionReply(ok: false, error: "that invitation is gone")) }
        /// Names and kids only — no code, no token, no envelope (spec §10).
        func lists() -> TeamMirror.NearbyReply {
            TeamMirror.NearbyReply(
                peers: team.nearby,
                pending: team.pendingNearby.map {
                    TeamMirror.PendingRequest(kid: $0.doc.keys.kid, name: $0.doc.name,
                                              platform: $0.doc.platform, at: $0.doc.at)
                },
                invites: team.invites.map {
                    TeamMirror.InviteSummary(fromKid: $0.from.kid, fromName: $0.fromName, teamName: $0.teamName)
                },
                team: team.snapshot?.id)
        }
        switch (r.method, r.path) {
        case ("GET", TeamMirror.nearbyPath):
            // An invitation can arrive without a scan, so read that
            // directory before answering; peers come from the last browse.
            await team.loadInvites()
            return json(lists())
        case ("POST", TeamMirror.nearbyScanPath):
            // A 2 s mDNS browse on the team queue, then the same lists.
            await team.scanNearby()
            return json(lists())
        case ("POST", TeamMirror.nearbyRequestPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.NearbyJoinRequest.self, from: r.body) else { return nil }
            guard let peer = team.nearby.first(where: { $0.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that machine is no longer on this network"))
            }
            return await action { await team.requestNearby(peer, name: body.name) }
        case ("POST", TeamMirror.nearbyInvitePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            guard let peer = team.nearby.first(where: { $0.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that machine is no longer on this network"))
            }
            return await action { await team.inviteNearby(peer) }
        case ("POST", TeamMirror.nearbyPullPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            guard let signed = team.pendingNearby.first(where: { $0.doc.keys.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that request is gone"))
            }
            return await action { await team.pullNearbyRequest(signed) }
        case ("POST", TeamMirror.nearbyAcceptPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.InviteAccept.self, from: r.body) else { return nil }
            await team.loadInvites()
            guard let invite = team.invites.first(where: { $0.from.kid == body.fromKid }) else { return gone() }
            return await action { await team.acceptInvite(invite, name: body.name) }
        case ("POST", TeamMirror.nearbyIgnorePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            await team.loadInvites()
            guard let invite = team.invites.first(where: { $0.from.kid == body.kid }) else { return gone() }
            return await action { await team.ignoreInvite(invite) }
        default:
            return nil
        }
    }
}
```

- [ ] **Step 6: The one-line hook.** In `Sources/Infinitus/TeamMirrorHandler.swift`, replace lines 49–50

```swift
        default:
            return nil
```

with

```swift
        default:
            // Nearby (spec §6.4) has its own file; nil from there is a real 404.
            return await TeamMirrorNearby.handle(r, team: team)
```

Nothing else in that file changes — the existing cases and the `action` closure stay exactly as they are.

- [ ] **Step 7: Build.** `swift build --product Infinitus` → succeeds. `swift test` → green. The route reaches the handler through the existing branch at `MirrorServer.swift` line 714 (`request.path.hasPrefix(TeamMirror.prefix + "/")`), inside the authorized region — read it and confirm, do not edit it.
- [ ] **Step 8: Commit**

```
git add Sources/InfinitusCore/Team/TeamMirror.swift Sources/Infinitus/TeamMirrorNearby.swift Sources/Infinitus/TeamMirrorHandler.swift Tests/InfinitusCoreTests/TeamMirrorTests.swift
git commit -m "mirror: /mirror/team/nearby answers the phone with the Mac's Nearby lists and actions"
```

---

### Task 7: Phone — transport wrappers and the Team tab's Nearby

**Files:**
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` — ONLY inside the `// MARK: team` block (lines 474–532)
- Modify: `ios/InfinitusMobile/TeamScreen.swift`
- Do not touch: everything in the "Do not touch" list; every other phone file, `ios/project.yml`, and `RowTheme.swift`.

**Interfaces:**
- Consumes: Task 6's `TeamMirror` nearby paths and types (the phone links `InfinitusCore` as a package product — `ios/project.yml` lists `product: InfinitusCore` under `InfinitusMobile.dependencies` — so no type needs copying).
- Produces:

```swift
// NetworkFleetMirror
func teamNearby() async throws -> TeamMirror.NearbyReply
func teamNearbyScan() async throws -> TeamMirror.NearbyReply
func teamNearbyRequest(kid: String, name: String) async throws -> TeamMirror.ActionReply
func teamNearbyInvite(kid: String) async throws -> TeamMirror.ActionReply
func teamNearbyPull(kid: String) async throws -> TeamMirror.ActionReply
func teamNearbyAccept(fromKid: String, name: String) async throws -> TeamMirror.ActionReply
func teamNearbyIgnore(fromKid: String) async throws -> TeamMirror.ActionReply
```

- [ ] **Step 1: The wrappers.** In `ios/InfinitusMobile/NetworkFleetMirror.swift`, after `teamCode(days:invite:)` (line 510) and before `postJSON` (line 512), insert:

```swift
    // Nearby (spec §6.4): the Mac's LAN lists and the actions on them.
    func teamNearby() async throws -> TeamMirror.NearbyReply { try await teamGet(TeamMirror.nearbyPath) }
    // The Mac browses mDNS for 2 s before it answers, so this waits like
    // an action rather than like a read.
    func teamNearbyScan() async throws -> TeamMirror.NearbyReply {
        try await postJSON(TeamMirror.nearbyScanPath, body: TeamMirror.Empty(), timeout: 20)
    }
    // request / invite / accept do a git fetch + push on the Mac: 60 s,
    // like join and approve. pull and ignore are cheaper but share the
    // same serial queue behind them.
    func teamNearbyRequest(kid: String, name: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.nearbyRequestPath, body: TeamMirror.NearbyJoinRequest(kid: kid, name: name), timeout: 60)
    }
    func teamNearbyInvite(kid: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.nearbyInvitePath, body: TeamMirror.KidRequest(kid: kid), timeout: 60)
    }
    func teamNearbyPull(kid: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.nearbyPullPath, body: TeamMirror.KidRequest(kid: kid), timeout: 60)
    }
    func teamNearbyAccept(fromKid: String, name: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.nearbyAcceptPath, body: TeamMirror.InviteAccept(fromKid: fromKid, name: name), timeout: 60)
    }
    func teamNearbyIgnore(fromKid: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.nearbyIgnorePath, body: TeamMirror.KidRequest(kid: fromKid), timeout: 60)
    }
```

- [ ] **Step 2: TeamScreen state.** In `ios/InfinitusMobile/TeamScreen.swift`, after `@State private var declining: TeamSnapshot.Request?` (line 28) add:

```swift
    /// The Mac's Nearby, on demand: a scan is a 2 s mDNS browse over
    /// there, so it never runs on a timer.
    @State private var nearby: TeamMirror.NearbyReply?
    @State private var scanning = false
```

- [ ] **Step 3: Load it with the screen.** Replace line 48 (`.task { await loadAggregates() }`) with:

```swift
        .task {
            await loadAggregates()
            await loadNearby()
        }
```

- [ ] **Step 4: The not-in-team sections.** In `notInTeam` (lines 64–97), between the `Section { Text("Create a team on the Mac…") }` block (lines 91–94) and `statusSection` (line 95), insert:

```swift
            nearbyTeamsSection
            invitationsSection
```

- [ ] **Step 5: The leader's section.** In `inTeam(_:)`, after the `if snap.role == "leader", !snap.requests.isEmpty { requestsSection(snap) }` block (lines 114–116) insert:

```swift
            if snap.role == "leader" { nearbySection(snap) }
```

and extend `.refreshable` (lines 137–140) to:

```swift
        .refreshable {
            await model.refresh()
            await loadAggregates()
            await loadNearby()
        }
```

- [ ] **Step 6: The sections themselves.** Add, after `inviteSection` (ends line 225) and before `aggregatesSection`:

```swift
    // MARK: nearby (spec §6.4) — the Mac's LAN lists, through the mirror

    private var nearbyPeers: [TeamNearby.Peer] { nearby?.peers ?? [] }
    private var nearbyLeaders: [TeamNearby.Peer] { nearbyPeers.filter { $0.role == "leader" } }

    private var nearbyTeamsSection: some View {
        Section("Nearby teams") {
            if scanning {
                Text("Looking…").font(.caption).foregroundStyle(.secondary)
            } else if nearbyLeaders.isEmpty {
                Text("No discoverable Macs on this network.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(nearbyLeaders) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.name).bold()
                    Text("leads a team · \(peer.host)").font(.caption).foregroundStyle(.secondary)
                    Button("Request to join") {
                        Task {
                            _ = await act("Requesting…") {
                                try await NetworkFleetMirror.shared.teamNearbyRequest(kid: peer.kid ?? "", name: joinName)
                            }
                            await loadNearby()
                        }
                    }
                    .disabled(!lock.enabled || joinName.isEmpty || busy != nil)
                }
            }
            Button("Scan") { Task { await scanNearby() } }.disabled(busy != nil || scanning)
            Text("Discoverable Macs show their name, kid and team on this network — nothing secret.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var invitationsSection: some View {
        if let invites = nearby?.invites, !invites.isEmpty {
            Section("Invitations") {
                ForEach(invites) { invite in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(invite.fromName) invites you to \(invite.teamName)").bold()
                        HStack {
                            Button("Accept") {
                                Task {
                                    let reply = await act("Accepting…") {
                                        try await NetworkFleetMirror.shared.teamNearbyAccept(fromKid: invite.fromKid, name: joinName)
                                    }
                                    if reply?.ok == true { await model.refresh() }
                                    await loadNearby()
                                }
                            }
                            .disabled(!lock.enabled || joinName.isEmpty || busy != nil)
                            Button("Ignore", role: .destructive) {
                                Task {
                                    _ = await act("Ignoring…") {
                                        try await NetworkFleetMirror.shared.teamNearbyIgnore(fromKid: invite.fromKid)
                                    }
                                    await loadNearby()
                                }
                            }
                            .disabled(busy != nil)
                        }
                    }
                }
            }
        }
    }

    private func nearbySection(_ snap: TeamSnapshot) -> some View {
        Section("Nearby") {
            ForEach(nearby?.pending ?? []) { request in
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.name).bold()
                    Text("asked over the network · \(request.platform) · \(relative(request.at))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("File for approval") {
                        Task {
                            _ = await act("Filing…") { try await NetworkFleetMirror.shared.teamNearbyPull(kid: request.kid) }
                            await model.refresh()
                            await loadNearby()
                        }
                    }
                    .disabled(busy != nil)
                }
            }
            ForEach(nearbyPeers) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.name).bold()
                    Text("\(peer.role) · \(peer.team == snap.id ? "in this team" : "not in this team")")
                        .font(.caption).foregroundStyle(.secondary)
                    if peer.team != snap.id {
                        Button("Invite") {
                            Task {
                                _ = await act("Inviting \(peer.name)…") {
                                    try await NetworkFleetMirror.shared.teamNearbyInvite(kid: peer.kid ?? "")
                                }
                                await loadNearby()
                            }
                        }
                        .disabled(!lock.enabled || busy != nil)
                    }
                }
            }
            if scanning { Text("Looking…").font(.caption).foregroundStyle(.secondary) }
            Button("Scan") { Task { await scanNearby() } }.disabled(busy != nil || scanning)
            Text("Invite a discoverable Mac, or file a request that reached this Mac over the network — either way they land in Requests.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadNearby() async {
        nearby = try? await NetworkFleetMirror.shared.teamNearby()
    }

    private func scanNearby() async {
        scanning = true
        defer { scanning = false }
        do { nearby = try await NetworkFleetMirror.shared.teamNearbyScan() }
        catch { self.error = error.localizedDescription }
    }
```

No new colors, fonts or images: every row is `Text`/`Button` in the screen's existing Form style, and `lock.enabled` gates the same actions the Join button gates (spec §2.2).

- [ ] **Step 7: Build the phone.** The exact command CI runs (`.github/workflows/ci.yml`, the `ios` job, lines 64–77):

```
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ../.build/ios CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. If neither Xcode nor xcodegen is installed, say so plainly in the report and run `swift build --product Infinitus` plus `swift test` instead — do not guess that it compiles.

- [ ] **Step 8: Commit**

```
git add ios/InfinitusMobile/NetworkFleetMirror.swift ios/InfinitusMobile/TeamScreen.swift
git commit -m "phone: the Team tab shows the Mac's Nearby — scan, request, invite, file, accept, ignore"
```

---

### Task 8: CHANGELOG + the full run

**Files:**
- Modify: `CHANGELOG.md` — under `## 0.4.4 (unreleased)` → `### Team (preview)` (the section beginning at line 45)
- Do not touch: everything in the "Do not touch" list, and no source file.

- [ ] **Step 1: The three lines.** Insert at the TOP of the `### Team (preview)` list (immediately after line 45), one short sentence each:

```
- Team: a leader invites a discoverable Mac over the local network, and the invitee accepts from Invitations.
- Team: the phone's Nearby — scan the network, ask a leader to join, invite a Mac, accept an invitation.
- `infinitusctl team nearby invite`, `team invites`, `team accept` and `team ignore` do the same from a terminal.
```

- [ ] **Step 2: The full run.** All four gates, in this order; each must pass before the commit:

```
swift test
swift build --product Infinitus
swift build --product infinitusctl
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ../.build/ios CODE_SIGNING_ALLOWED=NO build
```

(`swift build` takes ONE `--product` per invocation — with two flags SwiftPM builds only the last.) If the iOS toolchain is absent, report that gate as skipped rather than as passed.

- [ ] **Step 3: Ownership check.** `git diff --stat origin/main...HEAD` must list only: `Sources/InfinitusCore/Team/{TeamNearby,TeamInvites,TeamMirror}.swift`, `Sources/InfinitusCLI/TeamNearbyCommand.swift`, `Sources/Infinitus/{MirrorServer,TeamModel,TeamPane,TeamMirrorHandler,TeamMirrorNearby}.swift`, `ios/InfinitusMobile/{TeamScreen,NetworkFleetMirror}.swift`, `Tests/InfinitusCoreTests/{TeamNearbyTests,TeamInvitesTests,TeamMirrorTests}.swift`, `CHANGELOG.md`, and this plan. Anything else is an ownership violation — revert it.

- [ ] **Step 4: Commit**

```
git add CHANGELOG.md
git commit -m "changelog: LAN invites, the phone's Nearby and the four new team CLI verbs"
```

Never push. The orchestrator merges the stream.

---

## Self-review

- **Spec §6.4 coverage:** leader's Invite (T3 core, T5 pane, T7 phone), the peer's Accept/Ignore (T2 storage, T5 pane, T7 phone), the phone's Nearby lists and every action on them (T6, T7), the CLI equivalents (T4). Discoverability and the TXT record are untouched — `Peer` already carries `team`, `role` and `kid`, so nothing new advertises.
- **Threat model (§10):** the invite link — which carries the store's write credential — exists on the LAN and on disk only as an `Envelope` sealed to one recipient; `respond` refuses anything whose header sender disagrees with the body, or that names someone else as recipient; `openInvite` pins the sender key and then makes `TeamCode.decode` check the leader's signature and expiry, so a forged sender cannot hand over a usable code. `NearbyReply` carries names and kids only, asserted by a test.
- **Type consistency:** `TeamNearby.Invite` is built in T2, produced in T3, listed in T4/T5/T7, summarised (never shipped whole) in T6. `TeamInvites.mint` has one signature used in T1, T3 and T4.
- **Ownership:** `TeamModel` changes stay in the nearby block, `mintInvite`, and one `@Published` line; `TeamPane` in the two Nearby sections plus the new one between them; `MirrorServer` in `MirrorTeamBox.endpoint` alone; `TeamMirrorHandler` in one `default:` insertion. No new `TeamNearby.Client.ClientError` case, because `TeamModel.mask` switches over it exhaustively outside this stream's regions.
