# Team publisher + reader (plan 2 of the team design) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member's machine publishes its real data — `Stats.Day` per day, live state, a session index, redacted transcript chunks and crash summaries — to the audiences it picks, honouring per-project exclusions, and a `TeamReader` folds what a leader (or teammate) can read back into the same `Stats`/`SessionFeed` shapes the app already renders; `infinitusctl team share|exclude|members|member|remove|promote|publish|reshare` drives it on macOS and Linux.

**Architecture:** New files in `InfinitusCore/Team/`: `TeamKinds` (path ↔ kind ↔ sender contract), `TeamRedaction` (regex pass over each JSONL line before sealing), `TeamExclusions` + `TeamShares` (local settings, never sent), `TeamDocs` (the schema-1 plaintext documents), `TeamChunker` + `TeamPublishState` (append-only ≤1 MiB transcript chunks with per-session cursors and per-file hashes), `TeamPublisher` (collect from `StatsScanner` entries → documents → one batched `TeamClient.publish`), `TeamReader` (fold readable envelopes per member). `TeamClient` gains `remove`/`promote`, a batched `publish`, `unpublish`, `readableHeaders`, and the four #55 carry-overs (removed-after rule, path cross-check, roster schema check, explicit audiences). `StatsScanner.Result` exposes its per-file entries so exclusions can drop a project's contribution before folding. No app UI (plan 5), no phone (plan 8), no leader insights beyond folding (plan 9).

**Tech Stack:** Swift 5.9 toolchain syntax (6.1 on Linux CI), `swift-crypto` (`Crypto.SHA256` for content hashes), `NSRegularExpression` (already used by `StatsScanner`), the plan-1 `TeamClient`/`TeamGit`/`Envelope` stack, XCTest against a local bare git repo.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` (§1 audiences, §3 envelope acceptance, §4.3 layout, §6.5 remove/promote, §7 + §7.1 publisher and redaction, §8.1 reader, §8.4 members' view, §11 unit + integration tests, §12 step 2). Carry-overs from GitHub issue #55 ("Carry into plan 2").

## Global Constraints

- Worktree /Users/deathemperor/death/limitless-t-publisher, branch team-publisher; stage by explicit path; every commit ends with "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"; push nothing.
- No cswap anywhere; never read engine internals (~/.claude-swap-backup/*, proxy config/auth files, ~/.9router); Claude Code's own files (~/.claude/sessions/*.json, ~/.claude/projects/*/*.jsonl) are fine; never ~/.aws/login or ~/.aws/sso.
- Secrets never in argv or logs; shown masked only.
- Every new InfinitusCore/InfinitusCLI file compiles on Linux: no Darwin imports outside #if canImport(Darwin); no Foundation APIs missing from swift-foundation; Process is unavailable on iOS (fence like TeamGit.run).
- Crypto.SHA256 fully qualified (MirrorRendezvous.swift declares an internal enum SHA256 that shadows it).
- Canonical JSON for every signed document ([.sortedKeys, .withoutEscapingSlashes]); no floating-point fields in signed docs (Int unix seconds).
- kid = base32(SHA-256(enc ‖ sig)[0..16]); TeamKeys.kid(forEncryptionKey:signingKey:).
- Verification is "swift test" only in this worktree (never tools/e2e.sh: three app instances would collide; CI runs it). If the app must ever run, INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock. One --product per swift build invocation.
- Idle CPU stays ~0%: nothing polls on a timer in the app without a documented cadence; no TimelineView/repeatForever animation.
- Implementers spawn no subagents.
- CHANGELOG.md: one feature, one line, under the current unreleased version's "Team (preview)" heading.
- **Envelope plaintext may carry `Double`s** (`Stats.Day.usd`, `seconds`): the envelope signature covers the ciphertext bytes, never a re-encoding, so the no-floats rule applies only to `Signed<…>` documents (roster, request, code). Do not strip `Stats.Day`.
- **Shared-file edits are minimal and named here**: `StatsScanner.swift` changes only by adding `Result.entries` (Task 4); `TeamRoster.swift` and `TeamClient.swift` change only as Task 1 lists; `TeamCommand.swift` gains its new `case`s in ONE contiguous block after `case "read":` (the nearby stream appends one `case "nearby":` line — keep clear of the end of the switch's `default:`). Everything else is a new file.
- **Transcripts leave the machine only from Claude Code's own files** (`~/.claude/projects/**/*.jsonl`, engine `claude`); Codex transcripts contribute to `Stats.Day` only, never as chunks.
- **Publisher cadence is the caller's**: the CLI publishes once per invocation (a systemd/Task Scheduler timer is §9, not this plan); the app's 5-minute timer is plan 5. Nothing in this plan starts a timer.
- Tests inject every path (`projectsDir`, `claudeDir`, `TeamPaths`, `home`); nothing in `InfinitusCore/Team` calls `NSHomeDirectory()` except through a parameter default that the CLI supplies.
- Full suite must stay green: `swift test` on macOS (Linux CI runs the same).

---

## File structure

| file | responsibility |
|---|---|
| `Sources/InfinitusCore/Team/TeamKinds.swift` | kind names; the store path ↔ kind ↔ sender contract readers and writers both check (#55 b) |
| `Sources/InfinitusCore/Team/TeamRoster.swift` (modify) | `schema` check (#55 c), `Removed.keys`, `keys(for:at:)` (#55 a), explicit `recipients(for:)` (#55 d) |
| `Sources/InfinitusCore/Team/TeamClient.swift` (modify) | `remove`, `promote`, batched `publish(_:)`, `unpublish`, `readableHeaders`, path cross-check in `read` |
| `Sources/InfinitusCore/Team/TeamRedaction.swift` | §7.1: secrets, webhooks, `.env` lines, home paths, pasted images — one pass per JSONL line |
| `Sources/InfinitusCore/Team/TeamExclusions.swift` | per-machine excluded project dirs (`<base>/exclusions.json`), cwd + slug matching |
| `Sources/InfinitusCore/Team/TeamShares.swift` | per-team audience per kind (`<teamDir>/shares.json`), default `leaders`, CLI spelling parser |
| `Sources/InfinitusCore/Team/TeamDocs.swift` | schema-1 plaintext documents: `DayDoc`, `Now`, `SessionsIndex`, `SessionRow`, `Fleet`, `Crashes` |
| `Sources/InfinitusCore/StatsScanner.swift` (modify) | `Result.entries` — the per-file `FileEntry`s the scan folded |
| `Sources/InfinitusCore/Team/TeamChunker.swift` | complete lines after a byte offset, redacted, packed into ≤1 MiB chunks |
| `Sources/InfinitusCore/Team/TeamPublishState.swift` | per-session chunk cursors + per-path content hashes (`<teamDir>/publish-state.json`) |
| `Sources/InfinitusCore/Team/TeamPublisher.swift` | collect → documents → copies → one batched publish; `reshare(days:)`; `quit()` |
| `Sources/InfinitusCore/Team/TeamReader.swift` | fold readable envelopes into per-member days / now / sessions / crashes / transcript chunk lists; `summary`, `teamDays`, `transcript` |
| `Sources/InfinitusCLI/TeamCommand.swift` (modify) | `share`, `exclude`, `members`, `member`, `remove`, `promote`, real `publish`, `reshare`; raw form renamed `put` |
| `Tests/InfinitusCoreTests/TeamMembershipTests.swift` | Task 1 |
| `Tests/InfinitusCoreTests/TeamRedactionTests.swift` | Task 2 |
| `Tests/InfinitusCoreTests/TeamSettingsTests.swift` | Task 3 |
| `Tests/InfinitusCoreTests/TeamCollectTests.swift` | Task 4 |
| `Tests/InfinitusCoreTests/TeamChunkerTests.swift` | Task 5 |
| `Tests/InfinitusCoreTests/TeamPublisherTests.swift` | Task 6 |
| `Tests/InfinitusCoreTests/TeamReaderTests.swift` | Task 7 (+ the §11 integration flow) |
| `CHANGELOG.md` | one line (Task 8) |

---

### Task 1: Membership rules — roster schema, explicit audiences, remove/promote, removed-after, path cross-check

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamKinds.swift`
- Modify: `Sources/InfinitusCore/Team/TeamRoster.swift` (`Removed`, `recipients(for:)`, `keys(for:at:)`, `Acceptance.check`, `RosterError`)
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`ClientError`, `remove`, `promote`, `editRoster`, `publish`, `unpublish`, `readableHeaders`, `readable`, `read`)
- Modify: `Tests/InfinitusCoreTests/TeamRosterTests.swift:66` (one assertion)
- Test: `Tests/InfinitusCoreTests/TeamMembershipTests.swift`

**Interfaces:**
- Consumes (plan 1, unchanged): `TeamClient.create/request/approve/fetch/open`, `TeamRoster`, `TeamRoster.ShareTarget`, `Signed`, `Envelope.header(of:)`, `Envelope.open(_:as:senderKey:)`, `StorePath.branch(of:)`, `TeamGit.putAll(_:)`, `TeamGit.GitError.raceLost`.
- Produces:
  - `enum TeamKinds { static let stats, now, sessions, transcripts, crashes, aggregates: String; static let memberKinds: [String]; enum KindError: Error, Equatable { badPath, kindMismatch, senderMismatch }; static func expected(at path: String) -> (from: String?, kind: String)?; static func check(kind: String, from: String, at path: String) throws; static func check(_ header: Envelope.Header, at path: String) throws }`
  - `TeamRoster.Removed { kid: String; at: Int; keys: TeamKeys? }`, `TeamRoster.schemaVersion = 1`, `TeamRoster.RosterError.badSchema`, `func keys(for kid: String, at: Int) -> TeamKeys?`
  - `TeamRoster.recipients(for:)`: `.leaders` → leaders; `.team` → leaders + members; `.members(kids)` → exactly the named kids out of `everyone` (a leader reads a `.members` envelope only when named).
  - `TeamClient.ClientError.unknownMember, .founder, .lastLeader`
  - `TeamClient.remove(kid: String, now: Int = …) throws`, `TeamClient.promote(kid: String, now: Int = …) throws`
  - `struct TeamClient.PublishItem { kind: String; path: String; plaintext: Data; audience: TeamRoster.ShareTarget }`, `@discardableResult func publish(_ items: [PublishItem], now: Int = …) throws -> [String]` (one git push for the batch), `func unpublish(path: String) throws`
  - `func readableHeaders() throws -> [(entry: StoreEntry, header: Envelope.Header)]`; `readable()` now filters through `TeamKinds.check` and `keys(for:at:)`; `read(_:)` too.

**Decision recorded (#55 d):** §1's leader row says leaders read "whatever members share *to leaders*", the brainstorm decision says leaders access transcripts "with option to turn off from members", and §8.4 says a teammate's detail is visible "only if that teammate chose you". So `.members(kids)` wraps to exactly the named kids; leaders are recipients through `.leaders`/`.team` or when named. `TeamClient.publish`'s old comment ("plus every leader") goes.

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamMembershipTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamMembershipTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teammember-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// Leader + one approved member on a fresh bare remote.
    func team() throws -> (leader: TeamClient, member: TeamClient, remote: String) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [],
                                            platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: member.identity.kid, now: 1_020)
        _ = try member.fetch()
        return (leader, member, remote)
    }

    // MARK: roster rules

    func testRosterSchemaIsChecked() throws {
        let leader = TeamIdentity.random()
        var roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: leader.keys, name: "L", since: 1, founder: true)], rev: 1)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(try Signed.make(roster, by: leader), previous: nil))
        roster.schema = 2
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(try Signed.make(roster, by: leader), previous: nil)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .badSchema)
        }
    }

    func testAudiencesAreExplicit() {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "A", since: 2),
                                          TeamRoster.Member(keys: b.keys, name: "B", since: 3)], rev: 1)
        XCTAssertEqual(roster.recipients(for: .leaders).map(\.kid), [l.kid])
        XCTAssertEqual(Set(roster.recipients(for: .team).map(\.kid)), [l.kid, a.kid, b.kid])
        XCTAssertEqual(roster.recipients(for: .members([b.kid])).map(\.kid), [b.kid])          // no implicit leader
        XCTAssertEqual(Set(roster.recipients(for: .members([l.kid, b.kid])).map(\.kid)), [l.kid, b.kid])
        XCTAssertEqual(roster.recipients(for: .members(["nobody"])), [])
    }

    func testRemovedKeysServeOnlyEarlierEnvelopes() {
        let l = TeamIdentity.random(), gone = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                removed: [TeamRoster.Removed(kid: gone.kid, at: 500, keys: gone.keys)], rev: 2)
        XCTAssertEqual(roster.keys(for: gone.kid, at: 499), gone.keys)
        XCTAssertNil(roster.keys(for: gone.kid, at: 500))
        XCTAssertNil(roster.keys(for: gone.kid, at: 501))
        XCTAssertEqual(roster.keys(for: l.kid, at: 999_999), l.keys)
        XCTAssertNil(roster.keys(for: "stranger", at: 0))
        // A removed entry without keys (older roster) serves nothing.
        var legacy = roster; legacy.removed = [TeamRoster.Removed(kid: gone.kid, at: 500)]
        XCTAssertNil(legacy.keys(for: gone.kid, at: 1))
    }

    func testKindsFollowPathShape() {
        func kind(_ p: String) -> String? { TeamKinds.expected(at: p)?.kind }
        XCTAssertEqual(kind("m/k/days/2026-09-05.json"), "stats")
        XCTAssertEqual(kind("m/k/now.json"), "now")
        XCTAssertEqual(kind("m/k/sessions/index.json"), "sessions")
        XCTAssertEqual(kind("m/k/transcripts/s1/3.jsonl"), "transcripts")
        XCTAssertEqual(kind("m/k/transcripts/s1/subagents/agent-a/1.jsonl"), "transcripts")
        XCTAssertEqual(kind("m/k/crashes.json"), "crashes")
        XCTAssertEqual(kind("m/k/aggregates/week.json"), "aggregates")
        XCTAssertEqual(kind("roster/aggregates/week.json"), "aggregates")
        XCTAssertEqual(TeamKinds.expected(at: "m/k/now.json")?.from, "k")
        XCTAssertNil(TeamKinds.expected(at: "roster/aggregates/week.json")?.from)
        XCTAssertNil(kind("m/k/other.json"))
        XCTAssertNil(kind("m/k/days/x/y.json"))
        XCTAssertNil(kind("requests/k.json"))
        XCTAssertNil(kind("m/k/transcripts/s1/3.json"))

        let h = Envelope.Header(v: 1, kind: "now", from: "k", eph: "", to: [], at: 1, nonce: "", sig: nil)
        XCTAssertNoThrow(try TeamKinds.check(h, at: "m/k/now.json"))
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/k/days/2026-09-05.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/other/now.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .senderMismatch)
        }
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/k/nope")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .badPath)
        }
    }

    // MARK: roster edits over the store

    func testPromoteAndRemove() throws {
        let (leader, member, remote) = try team()
        // A second member, to be promoted.
        let (cp, cs) = machine("carol")
        let carol = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_030), name: "Carol", devices: [],
                                           platform: "linux", paths: cp, secrets: cs, now: 1_031)
        _ = try leader.fetch()
        try leader.approve(kid: carol.identity.kid, now: 1_032)
        XCTAssertThrowsError(try leader.promote(kid: "nobody")) { XCTAssertEqual($0 as? TeamClient.ClientError, .unknownMember) }
        try leader.promote(kid: carol.identity.kid, now: 1_040)
        XCTAssertEqual(leader.roster?.doc.rev, 4)
        XCTAssertTrue(leader.roster?.doc.isLeader(carol.identity.kid) ?? false)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])
        XCTAssertThrowsError(try leader.promote(kid: carol.identity.kid)) { XCTAssertEqual($0 as? TeamClient.ClientError, .alreadyLeader) }

        _ = try carol.fetch()
        XCTAssertTrue(carol.isLeader)
        XCTAssertNoThrow(try carol.code(expiresIn: 60, now: 1_041))
        // From now on a leaders-audience envelope wraps to carol too (§6.5).
        _ = try member.fetch()
        let path = try member.publish(kind: "now", path: "now.json", plaintext: Data("{}".utf8), audience: .leaders, now: 1_050)
        _ = try carol.fetch()
        XCTAssertEqual(try carol.read(path).1, Data("{}".utf8))

        // A co-leader cannot remove the founder; the founder removes the co-leader.
        XCTAssertThrowsError(try carol.remove(kid: leader.identity.kid, now: 1_060)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .founder)
        }
        XCTAssertThrowsError(try leader.remove(kid: "nobody", now: 1_060)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .unknownMember)
        }
        _ = try leader.fetch()
        try leader.remove(kid: carol.identity.kid, now: 1_060)
        let roster = try XCTUnwrap(leader.roster?.doc)
        XCTAssertEqual(roster.rev, 5)
        XCTAssertFalse(roster.isLeader(carol.identity.kid))
        XCTAssertEqual(roster.removed, [TeamRoster.Removed(kid: carol.identity.kid, at: 1_060, keys: carol.identity.keys)])
        // Members are not leaders: no roster edits.
        XCTAssertThrowsError(try member.remove(kid: carol.identity.kid)) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
        _ = remote
    }

    /// #55 (a): a removed member's envelopes sealed BEFORE removal stay
    /// readable; those sealed after are ignored, and once the member
    /// fetches the roster it cannot publish at all.
    func testRemovedMembersLaterEnvelopesAreIgnored() throws {
        let (leader, member, _) = try team()
        let before = try member.publish(kind: "stats", path: "days/2026-09-01.json", plaintext: Data("{\"schema\":1}".utf8),
                                        audience: .leaders, now: 1_030)
        _ = try leader.fetch()
        try leader.remove(kid: member.identity.kid, now: 1_040)
        // The member still holds rev 2 and can still push to its branch.
        let after = try member.publish(kind: "stats", path: "days/2026-09-02.json", plaintext: Data("{\"schema\":1}".utf8),
                                       audience: .leaders, now: 1_050)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [before])
        XCTAssertEqual(try leader.read(before).1, Data("{\"schema\":1}".utf8))
        XCTAssertThrowsError(try leader.read(after)) { XCTAssertEqual($0 as? Envelope.EnvelopeError, .unknownSender) }
        _ = try member.fetch()
        XCTAssertFalse(member.isMember)
        XCTAssertThrowsError(try member.publish(kind: "now", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }

    /// #55 (b): the path is outside the signature, so a valid envelope
    /// replayed under another member's branch, or under a path whose
    /// shape names a different kind, is ignored.
    func testEnvelopesAreCheckedAgainstTheirPath() throws {
        let (leader, member, remote) = try team()
        let (cp, cs) = machine("carol")
        let carol = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_030), name: "Carol", devices: [],
                                           platform: "linux", paths: cp, secrets: cs, now: 1_031)
        _ = try leader.fetch(); try leader.approve(kid: carol.identity.kid, now: 1_032); _ = try carol.fetch()

        let good = try member.publish(kind: "now", path: "now.json", plaintext: Data("{}".utf8), audience: .leaders, now: 1_040)
        // Carol replays Bo's envelope under her branch, and writes a
        // "now" envelope of her own under a days/ path.
        let raw = TeamGit(dir: cp.storeDir(leader.config.id), remote: remote, token: nil, author: carol.identity.kid)
        try raw.open(); try raw.sync()
        let bytes = try XCTUnwrap(try raw.get(good))
        try raw.put("m/\(carol.identity.kid)/now.json", bytes)
        let wrongKind = try Envelope.seal(Data("{}".utf8), kind: "now", from: carol.identity, to: [leader.identity.keys], at: 1_041)
        try raw.put("m/\(carol.identity.kid)/days/2026-09-05.json", wrongKind)
        // The client itself refuses a kind/path mismatch on write.
        XCTAssertThrowsError(try carol.publish(kind: "stats", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }

        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [good])
        XCTAssertThrowsError(try leader.read("m/\(carol.identity.kid)/now.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .senderMismatch)
        }
        XCTAssertThrowsError(try leader.read("m/\(carol.identity.kid)/days/2026-09-05.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
    }

    func testBatchedPublishIsOnePushAndUnpublishDeletes() throws {
        let (leader, member, _) = try team()
        let paths = try member.publish([
            TeamClient.PublishItem(kind: "now", path: "now.json", plaintext: Data("n".utf8), audience: .leaders),
            TeamClient.PublishItem(kind: "stats", path: "days/2026-09-05.json", plaintext: Data("d".utf8), audience: .team),
        ], now: 1_030)
        XCTAssertEqual(paths, ["m/\(member.identity.kid)/now.json", "m/\(member.identity.kid)/days/2026-09-05.json"])
        _ = try leader.fetch()
        XCTAssertEqual(Set(try leader.readable().map(\.path)), Set(paths))
        try member.unpublish(path: "now.json")
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [paths[1]])
        XCTAssertEqual(try member.publish([], now: 1_031), [])
    }
}
```

"One push" for the batch is `TeamGit.putAll` semantics (one commit per branch per call; plan 1 tested it), so this test asserts the batch's paths, readability, unpublish and the empty batch only.

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamMembershipTests 2>&1 | tail -3`
Expected: compile errors — `TeamKinds`, `Removed(kid:at:keys:)`, `badSchema`, `promote`, `remove`, `PublishItem` not found.

- [ ] **Step 3: Create `TeamKinds.swift`**

```swift
import Foundation

/// What a store path says about the envelope it holds (spec §4.3). The
/// path is outside the envelope signature, so a valid envelope can be
/// replayed under another member's branch or under a path whose shape
/// names another kind; writers and readers both run `check` (#55).
public enum TeamKinds {
    public static let stats = "stats"
    public static let now = "now"
    public static let sessions = "sessions"
    public static let transcripts = "transcripts"
    public static let crashes = "crashes"
    public static let aggregates = "aggregates"
    /// The kinds a member publishes about itself (§7), in table order.
    public static let memberKinds = [stats, now, sessions, transcripts, crashes]

    public enum KindError: Error, Equatable { case badPath, kindMismatch, senderMismatch }

    /// The kind a path's shape names and, under `m/<kid>/`, the kid that
    /// must have sealed it. `roster/aggregates/…` names no sender: the
    /// caller decides which leaders may write there (plan 9).
    public static func expected(at path: String) -> (from: String?, kind: String)? {
        guard let (branch, rest) = StorePath.branch(of: path) else { return nil }
        let owner: String?
        if branch.hasPrefix("m/") {
            owner = String(branch.dropFirst(2))
        } else if branch == "roster" {
            owner = nil
        } else {
            return nil
        }
        let parts = rest.split(separator: "/").map(String.init)
        switch parts.count {
        case 1 where parts[0] == "now.json":
            return (owner, now)
        case 1 where parts[0] == "crashes.json":
            return (owner, crashes)
        case 2 where parts[0] == "days" && parts[1].hasSuffix(".json"):
            return (owner, stats)
        case 2 where parts[0] == "sessions" && parts[1] == "index.json":
            return (owner, sessions)
        case 2 where parts[0] == "aggregates" && parts[1].hasSuffix(".json"):
            return (owner, aggregates)
        case 3 where parts[0] == "transcripts" && parts[2].hasSuffix(".jsonl"):
            return (owner, transcripts)
        case 5 where parts[0] == "transcripts" && parts[2] == "subagents" && parts[4].hasSuffix(".jsonl"):
            return (owner, transcripts)
        default:
            return nil
        }
    }

    public static func check(kind: String, from: String, at path: String) throws {
        guard let want = expected(at: path) else { throw KindError.badPath }
        guard want.kind == kind else { throw KindError.kindMismatch }
        if let owner = want.from, owner != from { throw KindError.senderMismatch }
    }

    public static func check(_ header: Envelope.Header, at path: String) throws {
        try check(kind: header.kind, from: header.from, at: path)
    }
}
```

- [ ] **Step 4: Edit `TeamRoster.swift`**

Replace `struct Removed`:

```swift
    public struct Removed: Codable, Equatable, Sendable {
        public var kid: String
        public var at: Int
        /// The keys the member had, kept so envelopes sealed BEFORE `at`
        /// still verify (spec §3: only what is published after removal is
        /// rejected). Nil in rosters written before this field existed.
        public var keys: TeamKeys?
        public init(kid: String, at: Int, keys: TeamKeys? = nil) { self.kid = kid; self.at = at; self.keys = keys }
    }
```

After `public var rev: Int` add `public static let schemaVersion = 1` and change the initialiser's `self.schema = 1` to `self.schema = Self.schemaVersion`.

After `keys(for kid:)` add:

```swift
    /// The keys `kid` had at `at`: a current member's, or a removed
    /// member's for an envelope sealed before the removal.
    public func keys(for kid: String, at: Int) -> TeamKeys? {
        if let current = keys(for: kid) { return current }
        guard let gone = removed.first(where: { $0.kid == kid }), at < gone.at else { return nil }
        return gone.keys
    }
```

Replace `recipients(for:)` and its comment:

```swift
    /// `.leaders` wraps to the leaders, `.team` to everyone, `.members`
    /// to exactly the named kids (leaders included only when named —
    /// spec §8.4: a teammate's detail is visible only to who they chose).
    /// The sender is added by `Envelope.seal`.
    public func recipients(for target: ShareTarget) -> [TeamKeys] {
        switch target {
        case .leaders: return leaders.map(\.keys)
        case .team: return everyone.map(\.keys)
        case .members(let kids): return everyone.filter { kids.contains($0.keys.kid) }.map(\.keys)
        }
    }
```

In `RosterError` add `badSchema`: `case lowerRev, notALeader, badSignature, differentTeam, noLeaders, badSchema`. In `Acceptance.check`, as the first line of the body after `let roster = candidate.doc`:

```swift
            guard roster.schema == TeamRoster.schemaVersion else { throw RosterError.badSchema }
```

- [ ] **Step 5: Edit `TeamClient.swift`**

Extend `ClientError`:

```swift
    public enum ClientError: Error, Equatable {
        case notALeader, notInTeam, noRoster, unknownRequest, badCode, alreadyJoined
        /// The kid is already a leader of this roster.
        case alreadyLeader
        /// The kid is already a member under different keys.
        case keyMismatch
        /// Another leader kept winning the roster push race.
        case rosterConflict
        /// The kid is neither a leader nor a member.
        case unknownMember
        /// The founding leader cannot be removed (spec §1 co-leader rule).
        case founder
        /// A team keeps at least one leader.
        case lastLeader
    }
```

After `decline(kid:)` add the roster edits:

```swift
    /// One roster edit with the same race loop as `approve`: recompute
    /// on the other leader's roster rather than overwrite it.
    private func editRoster(_ edit: (TeamRoster) throws -> TeamRoster) throws {
        for _ in 0..<3 {
            guard let current = roster?.doc else { throw ClientError.noRoster }
            guard isLeader else { throw ClientError.notALeader }
            var next = try edit(current)
            next.rev = current.rev + 1
            do {
                try saveRoster(next)
                return
            } catch TeamGit.GitError.raceLost {
                _ = try fetch()
                continue
            }
        }
        throw ClientError.rosterConflict
    }

    /// Spec §6.5: the kid moves to `removed` with its keys and the
    /// removal instant; envelopes it sealed before `now` stay readable,
    /// later ones are ignored, and its next `fetch` ends its membership.
    public func remove(kid: String, now: Int = Int(Date().timeIntervalSince1970)) throws {
        try editRoster { current in
            guard let keys = current.keys(for: kid) else { throw ClientError.unknownMember }
            if let target = current.leaders.first(where: { $0.keys.kid == kid }) {
                guard !target.founder else { throw ClientError.founder }
                guard current.leaders.count > 1 else { throw ClientError.lastLeader }
            }
            var next = current
            next.leaders.removeAll { $0.keys.kid == kid }
            next.members.removeAll { $0.keys.kid == kid }
            next.removed.removeAll { $0.kid == kid }
            next.removed.append(TeamRoster.Removed(kid: kid, at: now, keys: keys))
            return next
        }
    }

    /// Spec §6.5: a member becomes a (non-founder) leader; its key is a
    /// `.leaders` recipient from now on. Re-wrapping history is the
    /// member's choice (`TeamPublisher.reshare`).
    public func promote(kid: String, now: Int = Int(Date().timeIntervalSince1970)) throws {
        try editRoster { current in
            guard !current.isLeader(kid) else { throw ClientError.alreadyLeader }
            guard let member = current.members.first(where: { $0.keys.kid == kid }) else { throw ClientError.unknownMember }
            var next = current
            next.members.removeAll { $0.keys.kid == kid }
            next.leaders.append(member)
            return next
        }
    }
```

Replace the whole `// MARK: files` section (`publish`, `readable`, `read`) with:

```swift
    // MARK: files

    public struct PublishItem: Equatable {
        public var kind: String
        public var path: String
        public var plaintext: Data
        public var audience: TeamRoster.ShareTarget
        public init(kind: String, path: String, plaintext: Data, audience: TeamRoster.ShareTarget) {
            self.kind = kind; self.path = path; self.plaintext = plaintext; self.audience = audience
        }
    }

    /// Seals every item to its audience and pushes them under
    /// `m/<my kid>/` as ONE commit (a publish is five-plus files). Each
    /// path's shape must name the item's kind (`TeamKinds`), or readers
    /// would drop it. Returns the store paths in item order.
    @discardableResult
    public func publish(_ items: [PublishItem], now: Int = Int(Date().timeIntervalSince1970)) throws -> [String] {
        guard let roster = roster?.doc, isMember else { throw ClientError.notInTeam }
        var writes: [String: Data?] = [:]
        var paths: [String] = []
        for item in items {
            let storePath = "m/\(identity.kid)/\(item.path)"
            try TeamKinds.check(kind: item.kind, from: identity.kid, at: storePath)
            writes[storePath] = try Envelope.seal(item.plaintext, kind: item.kind, from: identity,
                                                  to: roster.recipients(for: item.audience), at: now)
            paths.append(storePath)
        }
        if !writes.isEmpty { try store.putAll(writes) }
        return paths
    }

    /// One file; see `publish(_:now:)`.
    @discardableResult
    public func publish(kind: String, path: String, plaintext: Data, audience: TeamRoster.ShareTarget,
                        now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        try publish([PublishItem(kind: kind, path: path, plaintext: plaintext, audience: audience)], now: now)[0]
    }

    /// Deletes `m/<my kid>/<path>` (spec §7: `now.json` goes on quit).
    public func unpublish(path: String) throws {
        guard isMember else { throw ClientError.notInTeam }
        try store.delete("m/\(identity.kid)/\(path)")
    }

    /// Envelopes under `m/` that name me as a reader, sit at a path whose
    /// shape matches their kind and sender, and come from someone who
    /// was in the roster when they were sealed. Reads headers only.
    public func readableHeaders() throws -> [(entry: StoreEntry, header: Envelope.Header)] {
        guard let roster = roster?.doc else { return [] }
        var out: [(entry: StoreEntry, header: Envelope.Header)] = []
        for entry in try store.list("m/") {
            guard let data = try store.get(entry.path), let header = try? Envelope.header(of: data),
                  (try? TeamKinds.check(header, at: entry.path)) != nil,
                  roster.keys(for: header.from, at: header.at) != nil,
                  header.to.contains(where: { $0.kid == identity.kid }) else { continue }
            out.append((entry, header))
        }
        return out
    }

    public func readable() throws -> [StoreEntry] { try readableHeaders().map(\.entry) }

    public func read(_ path: String) throws -> (Envelope.Header, Data) {
        guard let roster = roster?.doc else { throw ClientError.noRoster }
        guard let data = try store.get(path) else { throw Envelope.EnvelopeError.malformed }
        let header = try Envelope.header(of: data)
        try TeamKinds.check(header, at: path)
        return try Envelope.open(data, as: identity, senderKey: { roster.keys(for: $0, at: header.at) })
    }
```

- [ ] **Step 6: Update the one plan-1 assertion that encoded the implicit-leader rule**

In `Tests/InfinitusCoreTests/TeamRosterTests.swift` line 66, replace

```swift
        XCTAssertEqual(Set(r.recipients(for: .members([stranger.kid, "nobody"])).map(\.kid)), [leader.kid, stranger.kid])
```

with

```swift
        XCTAssertEqual(r.recipients(for: .members([stranger.kid, "nobody"])).map(\.kid), [stranger.kid])   // #55 (d): leaders only when named
```

- [ ] **Step 7: Run the new tests and the plan-1 team tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter "TeamMembershipTests|TeamClientTests|TeamRosterTests" 2>&1 | tail -5`
Expected: all pass. `TeamClientTests.testCreateRequestApprovePublishRead` still passes: its `now.json` / `aggregates/week.json` paths match `TeamKinds`, and its audiences are `.leaders` / `.team`.

- [ ] **Step 8: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamKinds.swift Sources/InfinitusCore/Team/TeamRoster.swift Sources/InfinitusCore/Team/TeamClient.swift Tests/InfinitusCoreTests/TeamMembershipTests.swift Tests/InfinitusCoreTests/TeamRosterTests.swift && \
git commit -m "team: remove/promote, batched publish, kind↔path check, removed-after rule, explicit audiences, roster schema check (#55)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Redaction

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamRedaction.swift`
- Test: `Tests/InfinitusCoreTests/TeamRedactionTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces: `enum TeamRedaction { struct Options { includeImages: Bool; home: String; init(home: String, includeImages: Bool = false) }; static func redact(_ line: String, options: Options) -> String; static func redact(jsonl: Data, options: Options) -> Data }`

Rules (spec §7.1), applied in this order to every line: `Authorization:` headers, bare `Bearer` tokens, `sk-…` keys, GitHub tokens, AWS access key ids, AWS secret/session values, webhook URLs, `.env`-style `NAME_KEY=value` lines, home paths → `~`, pasted base64 images → empty `data`. Replacements contain only `[a-z-]`, spaces and `~`, so a redacted JSON line is still JSON.

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamRedactionTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamRedactionTests: XCTestCase {
    let options = TeamRedaction.Options(home: "/Users/loc")

    func testFixtures() {
        let cases: [(String, String)] = [
            (#"{"text":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"}"#,
             #"{"text":"Authorization: [redacted]"}"#),
            ("curl -H 'Authorization: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234' x",
             "curl -H 'Authorization: [redacted]' x"),
            ("Bearer eyJhbGciOiJIUzI1NiJ9.abc.def please", "Bearer [redacted] please"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "key [redacted-key]"),
            ("token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "token [redacted-key]"),
            ("pat github_pat_11ABCDEFG0123456789abcdefghijklmnop", "pat [redacted-key]"),
            ("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY_ID=[redacted-aws-key]"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "AWS_SECRET_ACCESS_KEY=[redacted]"),
            (#"{"SessionToken":"FQoGZXIvYXdzEBYaDDDDDDDDDDDDDDDDDD"}"#, #"{"SessionToken":"[redacted]"}"#),
            ("https://hooks.slack.com/services/T000/B000/XXXXXXXX done", "[redacted-webhook] done"),
            ("https://discord.com/api/webhooks/1/abc", "[redacted-webhook]"),
            ("DATABASE_PASSWORD=hunter2 PORT=3000", "DATABASE_PASSWORD=[redacted] PORT=3000"),
            ("cd /Users/loc/death/limitless && ls /home/bob/x /root/y", "cd ~/death/limitless && ls ~/x ~/y"),
            ("swift build", "swift build"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TeamRedaction.redact(input, options: options), expected, input)
        }
    }

    func testImagesAreDroppedUnlessIncluded() {
        let data = String(repeating: "A", count: 300)
        let line = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(data)"}}"#
        XCTAssertEqual(TeamRedaction.redact(line, options: options),
                       #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":""}}"#)
        XCTAssertEqual(TeamRedaction.redact(line, options: TeamRedaction.Options(home: "/Users/loc", includeImages: true)), line)
        // Short base64-ish strings are not images.
        XCTAssertEqual(TeamRedaction.redact(#"{"data":"abcd"}"#, options: options), #"{"data":"abcd"}"#)
    }

    func testRedactedJSONStaysJSON() throws {
        let line = #"{"type":"user","message":{"content":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345 at /Users/loc/x with sk-abcdefghijklmnopqrstuvwxyz"}}"#
        let out = TeamRedaction.redact(line, options: options)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let message = try XCTUnwrap(obj["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Authorization: [redacted] at ~/x with [redacted-key]")
    }

    func testJSONLRedactsEveryLineAndKeepsLineCount() {
        let input = Data("a sk-abcdefghijklmnopqrstuvwxyz\nb\n\nc /home/x/y\n".utf8)
        let out = String(decoding: TeamRedaction.redact(jsonl: input, options: options), as: UTF8.self)
        XCTAssertEqual(out, "a [redacted-key]\nb\n\nc ~/y\n")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamRedactionTests 2>&1 | tail -3`
Expected: compile error, `TeamRedaction` not found.

- [ ] **Step 3: Implement**

Create `Sources/InfinitusCore/Team/TeamRedaction.swift`:

```swift
import Foundation

/// Spec §7.1: what leaves the machine is redacted BEFORE it is sealed.
/// One regex pass per JSONL line; every replacement is plain ASCII
/// without quotes or backslashes, so a JSON line stays JSON. The
/// member's "What my team sees" view renders this same output.
public enum TeamRedaction {
    public struct Options {
        /// The member's home directory, normalised to `~`.
        public var home: String
        /// Pasted images ride as base64 blocks; dropped unless asked for.
        public var includeImages: Bool
        public init(home: String, includeImages: Bool = false) {
            self.home = home; self.includeImages = includeImages
        }
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Order matters: a header rule eats "Bearer …" before the bare
    /// bearer rule sees it; the AWS id rule runs before the `.env` rule
    /// so `AWS_ACCESS_KEY_ID=AKIA…` reads as an AWS key, not a `.env` value.
    private static let rules: [(NSRegularExpression, String)] = [
        (re(#"(?i)authorization:\s*[^\s"'\\]+(?:\s+[^\s"'\\]+)?"#), "Authorization: [redacted]"),
        (re(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#), "Bearer [redacted]"),
        (re(#"\bsk-[A-Za-z0-9_-]{16,}"#), "[redacted-key]"),
        (re(#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "[redacted-key]"),
        (re(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#), "[redacted-aws-key]"),
        (re(#"(?i)(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(\\?"?\s*[=:]\s*\\?"?)[A-Za-z0-9+/=]{16,}"#),
         "$1$2[redacted]"),
        (re(#"https://(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|outlook\.office\.com/webhook)/[^\s"'\\]+"#),
         "[redacted-webhook]"),
        (re(#"\b([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD))=([^\s"'\\]+)"#), "$1=[redacted]"),
        // Any user's home, this machine's included: /Users/<x>, /home/<x>, /root.
        (re(#"(?<![A-Za-z0-9~])/(?:Users|home)/[^/\s"'\\]+|(?<![A-Za-z0-9~])/root(?=/|["'\s\\]|$)"#), "~"),
    ]

    private static let image = re(#""data"\s*:\s*"[A-Za-z0-9+/=]{256,}""#)

    public static func redact(_ line: String, options: Options) -> String {
        var out = line
        if options.home.count > 1 {
            let exact = re(NSRegularExpression.escapedPattern(for: options.home) + #"(?=/|["'\s\\]|$)"#)
            out = exact.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
        }
        for (rule, template) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        if !options.includeImages {
            out = image.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"data\":\"\"")
        }
        return out
    }

    /// Line by line; the trailing newline structure is kept exactly.
    public static func redact(jsonl: Data, options: Options) -> Data {
        let text = String(decoding: jsonl, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return Data(lines.map { redact(String($0), options: options) }.joined(separator: "\n").utf8)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamRedactionTests 2>&1 | tail -3`
Expected: 4 tests pass. If a fixture disagrees by one character, fix the regex, never the fixture's intent (the expected strings are the contract).

- [ ] **Step 5: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamRedaction.swift Tests/InfinitusCoreTests/TeamRedactionTests.swift && \
git commit -m "team: redaction — tokens, AWS keys, webhooks, .env values, home paths, pasted images (§7.1)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Exclusions and shares (local settings)

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamExclusions.swift`, `Sources/InfinitusCore/Team/TeamShares.swift`
- Test: `Tests/InfinitusCoreTests/TeamSettingsTests.swift`

**Interfaces:**
- Consumes: `TeamPaths` (`base`, `teamDir(_:)`), `TeamRoster.ShareTarget`, `CanonicalJSON`.
- Produces:
  - `struct TeamExclusions: Codable, Equatable, Sendable { projects: [String]; init(projects: [String] = []); static func slug(_ cwd: String) -> String; mutating func set(_ project: String, excluded: Bool); func excludes(cwd: String?, projectDir: String?) -> Bool; static func file(paths: TeamPaths) -> URL; static func load(paths: TeamPaths) -> TeamExclusions; func save(paths: TeamPaths) throws }`
  - `struct TeamShares: Codable, Equatable, Sendable { byKind: [String: TeamRoster.ShareTarget]; init(); func target(for kind: String) -> TeamRoster.ShareTarget; static func file(teamDir: URL) -> URL; static func load(teamDir: URL) -> TeamShares; func save(teamDir: URL) throws; static func parseTarget(_ words: [String]) -> TeamRoster.ShareTarget? }`

Exclusions are per machine (`<base>/exclusions.json`) and never published; shares are per team (`<teamDir>/shares.json`). A project excludes a transcript when its `cwd` is the project dir or below it, or — for a file whose cwd is unknown — when its Claude Code project directory name is the excluded dir's slug (the same `Transcript.path` rule: every non-alphanumeric becomes `-`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamSettingsTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamSettingsTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamsettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testExclusionsMatchCwdBelowAndSlug() {
        var ex = TeamExclusions(projects: ["/r/secret/"])
        XCTAssertEqual(ex.projects, ["/r/secret"])
        XCTAssertTrue(ex.excludes(cwd: "/r/secret", projectDir: nil))
        XCTAssertTrue(ex.excludes(cwd: "/r/secret/sub", projectDir: nil))
        XCTAssertFalse(ex.excludes(cwd: "/r/secretive", projectDir: nil))
        XCTAssertFalse(ex.excludes(cwd: "/r/app", projectDir: nil))
        XCTAssertTrue(ex.excludes(cwd: nil, projectDir: "-r-secret"))
        XCTAssertFalse(ex.excludes(cwd: nil, projectDir: "-r-app"))
        XCTAssertFalse(ex.excludes(cwd: nil, projectDir: nil))
        XCTAssertEqual(TeamExclusions.slug("/Users/loc/death/limitless"), "-Users-loc-death-limitless")
        ex.set("/r/app", excluded: true)
        ex.set("/r/app", excluded: true)
        XCTAssertEqual(ex.projects, ["/r/secret", "/r/app"])
        ex.set("/r/secret", excluded: false)
        XCTAssertEqual(ex.projects, ["/r/app"])
        XCTAssertFalse(TeamExclusions().excludes(cwd: "/r/app", projectDir: "-r-app"))
    }

    func testExclusionsRoundTripOnDisk() throws {
        let paths = TeamPaths(base: scratch)
        XCTAssertEqual(TeamExclusions.load(paths: paths), TeamExclusions())
        var ex = TeamExclusions()
        ex.set("/r/secret", excluded: true)
        try ex.save(paths: paths)
        XCTAssertEqual(TeamExclusions.load(paths: paths), ex)
        XCTAssertEqual(TeamExclusions.file(paths: paths).lastPathComponent, "exclusions.json")
    }

    func testSharesDefaultToLeadersAndRoundTrip() throws {
        let teamDir = scratch.appendingPathComponent("team-1")
        var shares = TeamShares.load(teamDir: teamDir)
        XCTAssertEqual(shares.target(for: "stats"), .leaders)
        shares.byKind["stats"] = .team
        shares.byKind["sessions"] = .members(["k1", "k2"])
        try shares.save(teamDir: teamDir)
        let back = TeamShares.load(teamDir: teamDir)
        XCTAssertEqual(back, shares)
        XCTAssertEqual(back.target(for: "sessions"), .members(["k1", "k2"]))
        XCTAssertEqual(back.target(for: "transcripts"), .leaders)
    }

    func testParseTarget() {
        XCTAssertEqual(TeamShares.parseTarget(["leaders"]), .leaders)
        XCTAssertEqual(TeamShares.parseTarget(["team"]), .team)
        XCTAssertEqual(TeamShares.parseTarget(["k1,k2", "k3"]), .members(["k1", "k2", "k3"]))
        XCTAssertNil(TeamShares.parseTarget([]))
        XCTAssertNil(TeamShares.parseTarget([""]))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamSettingsTests 2>&1 | tail -3`
Expected: compile errors, `TeamExclusions` / `TeamShares` not found.

- [ ] **Step 3: Create `TeamExclusions.swift`**

```swift
import Foundation

/// Spec §7: Claude Code project directories this machine keeps private —
/// nothing from them is published (no transcript, no session row, no
/// `Stats.Day` contribution). Local to the machine, never sent; one
/// file for every team (`<base>/exclusions.json`).
public struct TeamExclusions: Codable, Equatable, Sendable {
    /// Absolute project directories, no trailing slash.
    public var projects: [String]

    public init(projects: [String] = []) { self.projects = projects.map(Self.normalise) }

    static func normalise(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Claude Code's project directory name for a cwd — the same rule as
    /// `Transcript.path`: every non-alphanumeric character becomes `-`.
    public static func slug(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public mutating func set(_ project: String, excluded: Bool) {
        let p = Self.normalise(project)
        projects.removeAll { $0 == p }
        if excluded { projects.append(p) }
    }

    /// `cwd` is the transcript's own cwd when it recorded one;
    /// `projectDir` the `~/.claude/projects/<dir>` it sits in (nil for
    /// Codex files, whose directories are dates).
    public func excludes(cwd: String?, projectDir: String?) -> Bool {
        for p in projects {
            if let cwd, cwd == p || cwd.hasPrefix(p + "/") { return true }
            if let projectDir, projectDir == Self.slug(p) { return true }
        }
        return false
    }

    public static func file(paths: TeamPaths) -> URL { paths.base.appendingPathComponent("exclusions.json") }

    public static func load(paths: TeamPaths) -> TeamExclusions {
        (try? Data(contentsOf: file(paths: paths))).flatMap { try? CanonicalJSON.decode(TeamExclusions.self, from: $0) }
            ?? TeamExclusions()
    }

    public func save(paths: TeamPaths) throws {
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(paths: paths), options: .atomic)
    }
}
```

- [ ] **Step 4: Create `TeamShares.swift`**

```swift
import Foundation

/// Spec §7: the audience per data kind, chosen by the member; new
/// envelopes use it, `TeamPublisher.reshare` re-wraps history to it.
/// Per team (`<teamDir>/shares.json`); unset kinds go to the leaders.
public struct TeamShares: Codable, Equatable, Sendable {
    public var byKind: [String: TeamRoster.ShareTarget] = [:]

    public init() {}

    public func target(for kind: String) -> TeamRoster.ShareTarget { byKind[kind] ?? .leaders }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("shares.json") }

    public static func load(teamDir: URL) -> TeamShares {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamShares.self, from: $0) }
            ?? TeamShares()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }

    /// The CLI / UI spelling: `leaders`, `team`, or kids separated by
    /// commas and/or spaces.
    public static func parseTarget(_ words: [String]) -> TeamRoster.ShareTarget? {
        let kids = words.flatMap { $0.split(separator: ",") }.map(String.init).filter { !$0.isEmpty }
        guard !kids.isEmpty else { return nil }
        if kids == ["leaders"] { return .leaders }
        if kids == ["team"] { return .team }
        return .members(kids)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamSettingsTests 2>&1 | tail -3`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamExclusions.swift Sources/InfinitusCore/Team/TeamShares.swift Tests/InfinitusCoreTests/TeamSettingsTests.swift && \
git commit -m "team: per-project exclusions and per-kind audiences, local files never published

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Documents and the collector — `StatsScanner` entries, stats minus excluded projects, session rows, transcript sources

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamDocs.swift`, `Sources/InfinitusCore/Team/TeamPublisher.swift` (the pure half: `Collected`, `TranscriptSource`, `transcriptIdentity`, `collect`)
- Modify: `Sources/InfinitusCore/StatsScanner.swift` (`Result.entries`, one assignment before `return result`)
- Test: `Tests/InfinitusCoreTests/TeamCollectTests.swift`

**Interfaces:**
- Consumes: `StatsScanner.scan(projectsDir:codexDir:cacheURL:calendar:maxAge:now:byteBudget:windowBytes:) -> Result`, `StatsScanner.FileEntry` (`cwd`, `engine`, `state.firstAt/lastAt`, `daysWithOpenStretch()`), `Stats.Day` (`+`, `waitingSeconds`, `usd`, `activities`), `Stats.Engine`, `TeamExclusions.excludes(cwd:projectDir:)`, `TeamRoster.ShareTarget`.
- Produces:
  - `StatsScanner.Result.entries: [String: FileEntry]` — every file the scan folded, keyed by path.
  - `enum TeamDocs` with `DayDoc { schema; day: String; stats: Stats.Day }`, `Window { label; pct: Int; resetsAt: Int? }`, `Fleet { engine: String; account: String?; windows: [Window] }`, `LiveSession { id; project; status; name: String? }`, `Now { schema; at: Int; sessions: [LiveSession]; fleets: [Fleet]; blockers: [String]; crashesToday: Int; sharesTo: [String: TeamRoster.ShareTarget] }`, `SessionRow { id; project; name: String?; engine; startedAt; endedAt; busyMinutes; waitingMinutes; activities: [String: Int]; usd: Double; subagents: Int }`, `SessionsIndex { schema; at; sessions: [SessionRow]; fleets: [Fleet] }`, `Crashes { schema; crashes: [String] }` — all `Codable, Equatable, Sendable`, `schema` defaults to 1.
  - `struct TeamPublisher.TranscriptSource: Equatable { session: String; agent: String?; url: URL; var key: String; func chunkPath(seq: Int) -> String }`
  - `struct TeamPublisher.Collected: Equatable { days: [String: Stats.Day]; sessions: [TeamDocs.SessionRow]; transcripts: [TranscriptSource] }`
  - `static func TeamPublisher.transcriptIdentity(_ path: String) -> (session: String, agent: String?, projectDir: String)`
  - `static func TeamPublisher.collect(entries: [String: StatsScanner.FileEntry], exclusions: TeamExclusions) -> Collected`

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamCollectTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

/// A tiny Claude Code projects dir: two projects, one session each, one
/// sub-agent under the first. Shared by the publisher and reader tests
/// (repeated there — each test file stands alone).
enum TeamFixture {
    static let userLine = #"{"type":"user","cwd":"%CWD%","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"#
    static let assistantLine = #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"%ID%","model":"claude-opus-5","usage":{"input_tokens":%IN%,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#

    static func transcript(cwd: String, id: String, input: Int) -> String {
        userLine.replacingOccurrences(of: "%CWD%", with: cwd) + "\n"
            + assistantLine.replacingOccurrences(of: "%ID%", with: id).replacingOccurrences(of: "%IN%", with: String(input)) + "\n"
    }

    /// Returns the projects dir. `s1` in `/r/app` (10 input tokens) with
    /// sub-agent `agent-a1` (5), `s2` in `/r/secret` (10).
    @discardableResult
    static func write(into root: URL) throws -> URL {
        let projects = root.appendingPathComponent("projects")
        let app = projects.appendingPathComponent("-r-app")
        let secret = projects.appendingPathComponent("-r-secret")
        let sub = app.appendingPathComponent("s1/subagents")
        for dir in [app, secret, sub] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try transcript(cwd: "/r/app", id: "a1", input: 10).write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try transcript(cwd: "/r/app", id: "a2", input: 5).write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try transcript(cwd: "/r/secret", id: "a3", input: 10).write(to: secret.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }
}

final class TeamCollectTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamcollect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testTranscriptIdentity() {
        let main = TeamPublisher.transcriptIdentity("/h/.claude/projects/-r-app/s1.jsonl")
        XCTAssertEqual(main.session, "s1"); XCTAssertNil(main.agent); XCTAssertEqual(main.projectDir, "-r-app")
        let sub = TeamPublisher.transcriptIdentity("/h/.claude/projects/-r-app/s1/subagents/agent-a1.jsonl")
        XCTAssertEqual(sub.session, "s1"); XCTAssertEqual(sub.agent, "agent-a1"); XCTAssertEqual(sub.projectDir, "-r-app")
        let source = TeamPublisher.TranscriptSource(session: "s1", agent: "agent-a1", url: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(source.key, "s1/subagents/agent-a1")
        XCTAssertEqual(source.chunkPath(seq: 3), "transcripts/s1/subagents/agent-a1/3.jsonl")
        XCTAssertEqual(TeamPublisher.TranscriptSource(session: "s1", agent: nil, url: URL(fileURLWithPath: "/x")).chunkPath(seq: 1),
                       "transcripts/s1/1.jsonl")
    }

    func testScanExposesEntriesAndCollectHonoursExclusions() throws {
        let projects = try TeamFixture.write(into: scratch)
        let scan = StatsScanner.scan(projectsDir: projects, cacheURL: nil, calendar: .current, maxAge: 10_000 * 86_400)
        XCTAssertEqual(scan.entries.count, 3)
        XCTAssertEqual(Set(scan.entries.values.compactMap(\.cwd)), ["/r/app", "/r/secret"])

        let all = TeamPublisher.collect(entries: scan.entries, exclusions: TeamExclusions())
        XCTAssertEqual(all.days["2026-09-04"]?.inputTokens, 25)
        XCTAssertEqual(all.sessions.map(\.id).sorted(), ["s1", "s2"])
        XCTAssertEqual(all.transcripts.count, 3)

        let some = TeamPublisher.collect(entries: scan.entries, exclusions: TeamExclusions(projects: ["/r/secret"]))
        XCTAssertEqual(some.days["2026-09-04"]?.inputTokens, 15)
        XCTAssertEqual(some.sessions.map(\.id), ["s1"])
        let s1 = try XCTUnwrap(some.sessions.first)
        XCTAssertEqual(s1.project, "app")
        XCTAssertEqual(s1.engine, "claude")
        XCTAssertEqual(s1.subagents, 1)
        XCTAssertGreaterThanOrEqual(s1.startedAt, 1_788_523_200)   // 2026-09-04T12:00:00Z (noon UTC: one day key in every zone)
        XCTAssertEqual(s1.endedAt, 1_788_523_205)                  // the assistant entry, 12:00:05Z
        XCTAssertLessThanOrEqual(s1.startedAt, s1.endedAt)
        XCTAssertFalse(s1.activities.isEmpty)                      // the open stretch is charged in
        XCTAssertEqual(Set(some.transcripts.map(\.key)), ["s1", "s1/subagents/agent-a1"])
        XCTAssertTrue(some.transcripts.allSatisfy { $0.url.path.contains("-r-app") })

        // A file whose cwd is unknown is still excluded through its project dir's slug.
        var blind = scan.entries
        for (path, var entry) in blind where path.contains("-r-secret") { entry.cwd = nil; blind[path] = entry }
        XCTAssertEqual(TeamPublisher.collect(entries: blind, exclusions: TeamExclusions(projects: ["/r/secret"])).sessions.map(\.id), ["s1"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamCollectTests 2>&1 | tail -3`
Expected: compile errors (`entries`, `TeamPublisher`, `TeamDocs`).

- [ ] **Step 3: Expose the scan's entries**

In `Sources/InfinitusCore/StatsScanner.swift`, inside `public struct Result`, after `public var bytesTotal = 0` add:

```swift
        /// Every file the scan folded, keyed by path — cwd, engine, the
        /// per-day tallies and the session span — so a caller can fold
        /// its own subset (the team publisher drops excluded projects).
        public var entries: [String: FileEntry] = [:]
```

In `scan`, just before the final `return result`, add `result.entries = live`. `StatsModel.swift:169` and every test keep compiling: the field has a default.

- [ ] **Step 4: Create `TeamDocs.swift`**

```swift
import Foundation

/// The plaintext documents a member publishes (spec §7, §4.3). Each
/// carries `schema` so a reader can skip a version it does not know;
/// the envelope's `kind` names which of these is inside. Engine ids and
/// account names are opaque strings (no engine leaks its shape here).
public enum TeamDocs {
    /// `days/<yyyy-mm-dd>.json` — one day's `Stats.Day` (Stats v2 shape).
    public struct DayDoc: Codable, Equatable, Sendable {
        public var schema = 1
        public var day: String
        public var stats: Stats.Day
        public init(day: String, stats: Stats.Day) { self.day = day; self.stats = stats }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        public var pct: Int
        public var resetsAt: Int?
        public init(label: String, pct: Int, resetsAt: Int? = nil) { self.label = label; self.pct = pct; self.resetsAt = resetsAt }
    }

    /// One fleet's health as the app sees it: the active account and
    /// its usage windows. The CLI, which has no fleet view, sends none.
    public struct Fleet: Codable, Equatable, Sendable {
        public var engine: String
        public var account: String?
        public var windows: [Window]
        public init(engine: String, account: String?, windows: [Window] = []) {
            self.engine = engine; self.account = account; self.windows = windows
        }
    }

    public struct LiveSession: Codable, Equatable, Sendable {
        public var id: String
        /// Project directory basename, never the path.
        public var project: String
        public var status: String
        public var name: String?
        public init(id: String, project: String, status: String, name: String? = nil) {
            self.id = id; self.project = project; self.status = status; self.name = name
        }
    }

    /// `now.json` — live state; deleted on quit.
    public struct Now: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [LiveSession]
        public var fleets: [Fleet]
        public var blockers: [String]
        public var crashesToday: Int
        /// The audience hint a leader copies into the roster (§5).
        public var sharesTo: [String: TeamRoster.ShareTarget]
        public init(at: Int, sessions: [LiveSession], fleets: [Fleet], blockers: [String], crashesToday: Int,
                    sharesTo: [String: TeamRoster.ShareTarget]) {
            self.at = at; self.sessions = sessions; self.fleets = fleets; self.blockers = blockers
            self.crashesToday = crashesToday; self.sharesTo = sharesTo
        }
    }

    /// One session in `sessions/index.json`, summed over its transcript
    /// and its sub-agents' transcripts.
    public struct SessionRow: Codable, Equatable, Sendable {
        public var id: String
        public var project: String
        public var name: String?
        public var engine: String
        public var startedAt = 0
        public var endedAt = 0
        /// Minutes the assistant was working (stretch seconds).
        public var busyMinutes = 0
        /// Minutes a finished turn waited for the person.
        public var waitingMinutes = 0
        /// Minutes per `Stats.Activity` raw value.
        public var activities: [String: Int] = [:]
        public var usd = 0.0
        public var subagents = 0
        public init(id: String, project: String, engine: String) { self.id = id; self.project = project; self.engine = engine }
    }

    public struct SessionsIndex: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [SessionRow]
        public var fleets: [Fleet]
        public init(at: Int, sessions: [SessionRow], fleets: [Fleet]) { self.at = at; self.sessions = sessions; self.fleets = fleets }
    }

    /// `crashes.json` — `CrashReport.summary` lines, never the raw report.
    public struct Crashes: Codable, Equatable, Sendable {
        public var schema = 1
        public var crashes: [String]
        public init(crashes: [String]) { self.crashes = crashes }
    }
}
```

- [ ] **Step 5: Create `TeamPublisher.swift` (collector half)**

```swift
import Foundation
import Crypto

/// Spec §7: turns this machine's Claude Code files into the member's
/// documents and publishes them through `TeamClient`. `collect` is the
/// pure half (Task 4); publishing, chunking state and re-share follow
/// (Task 6).
public struct TeamPublisher {
    /// One transcript file to chunk: the session's own, or one of its
    /// sub-agents'.
    public struct TranscriptSource: Equatable {
        public var session: String
        public var agent: String?
        public var url: URL
        public init(session: String, agent: String?, url: URL) { self.session = session; self.agent = agent; self.url = url }

        /// `<session>` or `<session>/subagents/<agent>` — the cursor key
        /// and the store directory (spec §4.3, `TeamKinds`).
        public var key: String { agent.map { "\(session)/subagents/\($0)" } ?? session }
        public func chunkPath(seq: Int) -> String { "transcripts/\(key)/\(seq).jsonl" }
    }

    public struct Collected: Equatable {
        public var days: [String: Stats.Day] = [:]
        public var sessions: [TeamDocs.SessionRow] = []
        public var transcripts: [TranscriptSource] = []
        public init() {}
    }

    /// The same rule `StatsScanner.scan` walks with: `<project>/<sid>.jsonl`
    /// is a session, `<project>/<sid>/subagents/<agent>.jsonl` one of its
    /// sub-agents. For Codex files the "project dir" is a date; callers
    /// ignore it there.
    public static func transcriptIdentity(_ path: String) -> (session: String, agent: String?, projectDir: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            let sessionDir = parent.deletingLastPathComponent()
            return (sessionDir.lastPathComponent, url.deletingPathExtension().lastPathComponent,
                    sessionDir.deletingLastPathComponent().lastPathComponent)
        }
        return (url.deletingPathExtension().lastPathComponent, nil, parent.lastPathComponent)
    }

    /// Folds the scan's per-file entries minus excluded projects: days
    /// (Stats v2 `+`), one row per session (sub-agents summed in), and
    /// the Claude Code transcript files to chunk. Codex transcripts
    /// count toward days only — they are not Claude Code's files.
    public static func collect(entries: [String: StatsScanner.FileEntry], exclusions: TeamExclusions) -> Collected {
        var out = Collected()
        var rows: [String: TeamDocs.SessionRow] = [:]
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let identity = transcriptIdentity(path)
            let claude = entry.engine == Stats.Engine.claude.rawValue
            if exclusions.excludes(cwd: entry.cwd, projectDir: claude ? identity.projectDir : nil) { continue }
            let days = entry.daysWithOpenStretch()
            for (key, day) in days { out.days[key] = (out.days[key] ?? Stats.Day()) + day }

            let project = entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var row = rows[identity.session]
                ?? TeamDocs.SessionRow(id: identity.session, project: project ?? identity.projectDir, engine: entry.engine)
            // A sub-agent file seen first carries no cwd; the session's own file names the project.
            if let project, identity.agent == nil { row.project = project }
            for t in entry.state.firstAt.values {
                row.startedAt = row.startedAt == 0 ? Int(t) : min(row.startedAt, Int(t))
            }
            for t in entry.state.lastAt.values { row.endedAt = max(row.endedAt, Int(t)) }
            for day in days.values {
                row.waitingMinutes += Int(day.waitingSeconds / 60)
                row.usd += day.usd
                for (label, tally) in day.activities {
                    let minutes = Int(tally.seconds / 60)
                    row.activities[label, default: 0] += minutes
                    row.busyMinutes += minutes
                }
            }
            if identity.agent != nil { row.subagents += 1 }
            rows[identity.session] = row
            if claude { out.transcripts.append(TranscriptSource(session: identity.session, agent: identity.agent, url: URL(fileURLWithPath: path))) }
        }
        out.sessions = rows.values.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        return out
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter "TeamCollectTests|StatsTests" 2>&1 | tail -3`
Expected: all pass. `startedAt`/`endedAt` come from the fixture's ISO timestamps (`2026-09-04T12:00:00Z` = 1 788 523 200, the assistant entry five seconds later; noon UTC keeps the day key the same in every time zone); `firstAt` may be recorded on the user entry or the first assistant entry depending on `StatsScanner.ingest`, which is why `startedAt` is only bounded.

- [ ] **Step 7: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/StatsScanner.swift Sources/InfinitusCore/Team/TeamDocs.swift Sources/InfinitusCore/Team/TeamPublisher.swift Tests/InfinitusCoreTests/TeamCollectTests.swift && \
git commit -m "team: publish documents and the collector — days, session rows and transcript sources minus excluded projects

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Transcript chunking and publish state

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamChunker.swift`, `Sources/InfinitusCore/Team/TeamPublishState.swift`
- Test: `Tests/InfinitusCoreTests/TeamChunkerTests.swift`

**Interfaces:**
- Consumes: nothing from this plan (redaction arrives as a closure).
- Produces:
  - `enum TeamChunker { static let maxChunkBytes = 1 << 20; static let readCap = 64 << 20; static func chunks(of url: URL, from offset: Int, maxBytes: Int = maxChunkBytes, readCap: Int = readCap, redact: (String) -> String) throws -> (chunks: [Data], offset: Int) }`
  - `struct TeamPublishState: Codable, Equatable { struct Cursor: Codable, Equatable { seq: Int; offset: Int }; transcripts: [String: Cursor]; hashes: [String: String]; init(); static func file(teamDir: URL) -> URL; static func load(teamDir: URL) -> TeamPublishState; func save(teamDir: URL) throws }`

Spec §7: chunks are append-only, ≤ 1 MiB of *new* lines since the last chunk, complete lines only. A single line larger than the cap (a pasted screenshot's tool result) becomes a chunk of its own. At most `readCap` bytes are read per call so a first publish of a huge transcript proceeds in slices across publishes.

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamChunkerTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamChunkerTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamchunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testPacksCompleteLinesIntoBoundedChunks() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "aaaa\nbbbb\ncccc\ndddd\neeee\n".write(to: file, atomically: true, encoding: .utf8)   // 5 lines × 5 bytes
        let (chunks, offset) = try TeamChunker.chunks(of: file, from: 0, maxBytes: 12, redact: { $0 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF8.self) }, ["aaaa\nbbbb\n", "cccc\ndddd\n", "eeee\n"])
        XCTAssertEqual(offset, 25)
        // Nothing new: no chunks, same offset.
        let again = try TeamChunker.chunks(of: file, from: offset, maxBytes: 12, redact: { $0 })
        XCTAssertEqual(again.chunks, [])
        XCTAssertEqual(again.offset, 25)
    }

    func testPartialTrailingLineWaitsAndRedactionApplies() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "one secret\ntwo".write(to: file, atomically: true, encoding: .utf8)
        let first = try TeamChunker.chunks(of: file, from: 0, redact: { $0.replacingOccurrences(of: "secret", with: "[x]") })
        XCTAssertEqual(first.chunks.map { String(decoding: $0, as: UTF8.self) }, ["one [x]\n"])
        XCTAssertEqual(first.offset, 11)   // the unterminated "two" is not consumed
        try FileHandle(forWritingTo: file).seekToEndAndWrite(Data(" done\n".utf8))
        let second = try TeamChunker.chunks(of: file, from: first.offset, redact: { $0 })
        XCTAssertEqual(second.chunks.map { String(decoding: $0, as: UTF8.self) }, ["two done\n"])
        XCTAssertEqual(second.offset, 20)
    }

    func testOversizedLineIsItsOwnChunk() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        let big = String(repeating: "x", count: 40)
        try "ab\n\(big)\ncd\n".write(to: file, atomically: true, encoding: .utf8)
        let (chunks, _) = try TeamChunker.chunks(of: file, from: 0, maxBytes: 10, redact: { $0 })
        XCTAssertEqual(chunks.map { $0.count }, [3, 41, 3])
    }

    func testReadCapSlicesAcrossCalls() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "aaaa\nbbbb\ncccc\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try TeamChunker.chunks(of: file, from: 0, readCap: 7, redact: { $0 })
        XCTAssertEqual(first.chunks.map { String(decoding: $0, as: UTF8.self) }, ["aaaa\n"])
        XCTAssertEqual(first.offset, 5)
        let second = try TeamChunker.chunks(of: file, from: first.offset, readCap: 100, redact: { $0 })
        XCTAssertEqual(second.chunks.map { String(decoding: $0, as: UTF8.self) }, ["bbbb\ncccc\n"])
    }

    func testMissingFileYieldsNothing() throws {
        let r = try TeamChunker.chunks(of: scratch.appendingPathComponent("nope.jsonl"), from: 3, redact: { $0 })
        XCTAssertEqual(r.chunks, []); XCTAssertEqual(r.offset, 3)
    }

    func testPublishStateRoundTrips() throws {
        let teamDir = scratch.appendingPathComponent("team")
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir), TeamPublishState())
        var s = TeamPublishState()
        s.transcripts["s1"] = TeamPublishState.Cursor(seq: 2, offset: 4096)
        s.hashes["days/2026-09-04.json"] = "abc"
        try s.save(teamDir: teamDir)
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir), s)
    }
}

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) throws {
        try seekToEnd()
        try write(contentsOf: data)
        try close()
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamChunkerTests 2>&1 | tail -3`
Expected: compile errors, `TeamChunker` / `TeamPublishState` not found.

- [ ] **Step 3: Create `TeamChunker.swift`**

```swift
import Foundation

/// Spec §7 transcripts: append-only chunks of at most `maxChunkBytes` of
/// NEW complete lines since the last chunk, each line redacted before
/// it is counted. Ciphertext never delta-compresses, so chunks are
/// what keeps the store's growth linear in what was actually written.
public enum TeamChunker {
    public static let maxChunkBytes = 1 << 20
    /// Bytes read per call: a first publish of a hundreds-of-MB
    /// transcript proceeds in slices, one per publish.
    public static let readCap = 64 << 20
    private static let newline = UInt8(ascii: "\n")

    /// Chunks of the complete lines after byte `offset`, and the offset
    /// just past the last line consumed. A line without its newline
    /// waits for the next call; a line above `maxBytes` is its own chunk.
    public static func chunks(of url: URL, from offset: Int, maxBytes: Int = maxChunkBytes,
                              readCap: Int = readCap, redact: (String) -> String) throws -> (chunks: [Data], offset: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: readCap), let lastNewline = data.lastIndex(of: newline) else {
            return ([], offset)
        }
        let complete = data[data.startIndex...lastNewline]
        var chunks: [Data] = []
        var current = Data()
        var start = complete.startIndex
        while start < complete.endIndex {
            let end = complete[start...].firstIndex(of: newline) ?? complete.endIndex
            var line = Data(redact(String(decoding: complete[start..<end], as: UTF8.self)).utf8)
            line.append(newline)
            if !current.isEmpty, current.count + line.count > maxBytes {
                chunks.append(current)
                current = Data()
            }
            current.append(line)
            start = end + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return (chunks, offset + complete.count)
    }
}
```

- [ ] **Step 4: Create `TeamPublishState.swift`**

```swift
import Foundation

/// What this machine has already published for one team
/// (`<teamDir>/publish-state.json`): where each transcript's chunks
/// stand, and the content hash of every whole-object file so an
/// unchanged day or crash list is not re-sealed on every push.
public struct TeamPublishState: Codable, Equatable {
    public struct Cursor: Codable, Equatable {
        /// Last chunk sequence number published (0 = none yet).
        public var seq: Int
        /// Byte offset just past the last line published.
        public var offset: Int
        public init(seq: Int = 0, offset: Int = 0) { self.seq = seq; self.offset = offset }
    }

    /// `TranscriptSource.key` → cursor.
    public var transcripts: [String: Cursor] = [:]
    /// Store-relative path (`days/2026-09-04.json`, `crashes.json`) → hex SHA-256 of the plaintext last published.
    public var hashes: [String: String] = [:]

    public init() {}

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("publish-state.json") }

    public static func load(teamDir: URL) -> TeamPublishState {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamPublishState.self, from: $0) }
            ?? TeamPublishState()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamChunkerTests 2>&1 | tail -3`
Expected: 6 tests pass. On Linux `FileHandle.read(upToCount:)`, `seek(toOffset:)`, `seekToEnd()` and `write(contentsOf:)` all exist in swift-foundation (`StatsScanner.parse` already uses the first two).

- [ ] **Step 6: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamChunker.swift Sources/InfinitusCore/Team/TeamPublishState.swift Tests/InfinitusCoreTests/TeamChunkerTests.swift && \
git commit -m "team: append-only transcript chunks (≤1 MiB of new complete lines) and the per-team publish state

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `TeamPublisher.publish`, `reshare`, `quit` — audiences, copies, one push

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift` (add `Sources`, `Report`, the instance API)
- Test: `Tests/InfinitusCoreTests/TeamPublisherTests.swift`

**Interfaces:**
- Consumes: Task 1 (`TeamClient.publish(_:now:)`, `PublishItem`, `unpublish`, `isMember`, `config.id`, `identity.kid`), Task 2 (`TeamRedaction`), Task 3 (`TeamExclusions`, `TeamShares`), Task 4 (`collect`, `TeamDocs`, `StatsScanner.Result.entries`), Task 5 (`TeamChunker`, `TeamPublishState`), `StatsScanner.scan`, `ClaudeSessionRecord`, `CrashReport.summary`, `Stats.date(fromDayKey:calendar:)`, `Crypto.SHA256`.
- Produces:
  - `struct TeamPublisher.Sources { projectsDir: URL; codexDir: URL?; cacheURL: URL?; liveSessions: [ClaudeSessionRecord]; crashes: [CrashReport]; fleets: [TeamDocs.Fleet]; blockers: [String]; home: String; includeImages: Bool; historyDays: Int (30); calendar: Calendar; init(projectsDir: URL, home: String) }`
  - `struct TeamPublisher.Report: Equatable, Encodable { published: [String]; transcriptChunks: Int; skipped: Int }`
  - `TeamPublisher(client: TeamClient, paths: TeamPaths)`, `var teamDir: URL`, `var copiesDir: URL`
  - `func publish(sources: Sources, now: Date = Date()) throws -> Report`
  - `func reshare(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Report`
  - `func quit() throws` — deletes `now.json`.

Behaviour: one publish = scan → collect → stage `days/<date>.json` for the last `historyDays` whose hash changed, `sessions/index.json` (every push), `now.json` (every push; `quit` deletes it), `crashes.json` (on change), and every new transcript chunk; every staged plaintext is copied under `<teamDir>/published/<path>` (what `reshare` re-wraps) and the batch goes out as one `TeamClient.publish`. State is saved only after the push succeeds. Audience per kind comes from `TeamShares`; narrowing cannot recall ciphertext already fetched (the CLI says so in Task 8).

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamPublisherTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamPublisherTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teampub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// Same fixture as TeamCollectTests.TeamFixture (repeated: each test
    /// file stands alone). s1 in /r/app (10 tokens) + agent-a1 (5), s2 in
    /// /r/secret (10); the user prompt carries an `sk-ant-…` key.
    func writeProjects(_ root: URL) throws -> URL {
        let user = #"{"type":"user","cwd":"%CWD%","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"#
        let assistant = #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"%ID%","model":"claude-opus-5","usage":{"input_tokens":%IN%,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#
        func transcript(_ cwd: String, _ id: String, _ input: Int) -> String {
            user.replacingOccurrences(of: "%CWD%", with: cwd) + "\n"
                + assistant.replacingOccurrences(of: "%ID%", with: id).replacingOccurrences(of: "%IN%", with: String(input)) + "\n"
        }
        let projects = root.appendingPathComponent("projects")
        let app = projects.appendingPathComponent("-r-app"), secret = projects.appendingPathComponent("-r-secret")
        let sub = app.appendingPathComponent("s1/subagents")
        for dir in [app, secret, sub] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try transcript("/r/app", "a1", 10).write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/app", "a2", 5).write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/secret", "a3", 10).write(to: secret.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    struct Team {
        let leader: TeamClient, alice: TeamClient, bob: TeamClient
        let alicePaths: TeamPaths
    }

    /// Leader + two approved members; alice is the publisher under test.
    func team() throws -> Team {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("alice"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let alice = try TeamClient.request(code: code, name: "Alice", devices: [], platform: "linux", paths: ap, secrets: asec, now: 1_010)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: alice.identity.kid, now: 1_020)
        try leader.approve(kid: bob.identity.kid, now: 1_021)
        _ = try alice.fetch(); _ = try bob.fetch()
        return Team(leader: leader, alice: alice, bob: bob, alicePaths: ap)
    }

    func sources(_ projects: URL) -> TeamPublisher.Sources {
        var s = TeamPublisher.Sources(projectsDir: projects, home: "/Users/alice")
        s.historyDays = 10_000   // the fixture's dates stay in the window whenever this runs
        s.liveSessions = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/r/app", status: "busy"),
                          ClaudeSessionRecord(pid: 2, sessionId: "s2", cwd: "/r/secret", status: "idle")]
        s.crashes = [CrashReport(platform: "mac", device: "Mac", appVersion: "1", osVersion: "26", at: Date(), kind: "crash", reason: "SIGSEGV")]
        s.fleets = [TeamDocs.Fleet(engine: "opaque", account: "acct-1", windows: [TeamDocs.Window(label: "5h", pct: 40)])]
        return s
    }

    func header(_ client: TeamClient, _ path: String) throws -> Envelope.Header {
        try XCTUnwrap(try client.readableHeaders().first { $0.entry.path == path }?.header)
    }

    func testPublishWrapsEachKindToItsAudienceHonoursExclusionsAndRedacts() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var shares = TeamShares()
        shares.byKind["stats"] = .team
        shares.byKind["sessions"] = .members([t.bob.identity.kid])
        try shares.save(teamDir: teamDir)
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true); try ex.save(paths: t.alicePaths)

        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        let report = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "now.json", me + "crashes.json",
            me + "transcripts/s1/1.jsonl", me + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])
        XCTAssertEqual(report.transcriptChunks, 2)

        _ = try t.leader.fetch(); _ = try t.bob.fetch()
        // stats → team: leader and bob read it; sessions → bob only; the rest → leaders.
        let dayHeader = try header(t.leader, me + "days/2026-09-04.json")
        XCTAssertEqual(Set(dayHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid, t.bob.identity.kid])
        XCTAssertEqual(Set(try t.bob.readable().map(\.path)), [me + "days/2026-09-04.json", me + "sessions/index.json"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "sessions/index.json"))
        let chunkHeader = try header(t.leader, me + "transcripts/s1/1.jsonl")
        XCTAssertEqual(Set(chunkHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid])

        // Excluded project: no day contribution, no session row, no transcript, no live session.
        let day = try CanonicalJSON.decode(TeamDocs.DayDoc.self, from: try t.leader.read(me + "days/2026-09-04.json").1)
        XCTAssertEqual(day.day, "2026-09-04")
        XCTAssertEqual(day.stats.inputTokens, 15)
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.bob.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id), ["s1"])
        XCTAssertEqual(index.fleets.first?.account, "acct-1")
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.sessions.map(\.id), ["s1"])
        XCTAssertEqual(now.sessions.first?.project, "app")
        XCTAssertEqual(now.crashesToday, 1)
        XCTAssertEqual(now.sharesTo["stats"], .team)
        let crashes = try CanonicalJSON.decode(TeamDocs.Crashes.self, from: try t.leader.read(me + "crashes.json").1)
        XCTAssertEqual(crashes.crashes, ["Mac · crash · SIGSEGV"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains { $0.contains("/s2/") })

        // Redacted before sealing; the local copy is the redacted text too.
        let chunk = String(decoding: try t.leader.read(me + "transcripts/s1/1.jsonl").1, as: UTF8.self)
        XCTAssertFalse(chunk.contains("sk-ant"))
        XCTAssertTrue(chunk.contains("[redacted-key]"))
        let copy = try String(contentsOf: publisher.copiesDir.appendingPathComponent("transcripts/s1/1.jsonl"), encoding: .utf8)
        XCTAssertEqual(copy, chunk)

        // Nothing changed: only the every-push files go out again, no chunks.
        let second = try publisher.publish(sources: sources(projects))
        XCTAssertEqual(Set(second.published), [me + "sessions/index.json", me + "now.json"])
        XCTAssertEqual(second.transcriptChunks, 0)
        XCTAssertEqual(second.skipped, 2)   // the day and the crash list

        // New lines → the next chunk, seq 2, and the day changes with them.
        let s1 = projects.appendingPathComponent("-r-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: s1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","timestamp":"2026-09-04T12:00:09.000Z","message":{"id":"a9","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":1},"content":[{"type":"text","text":"more"}]}}"#.utf8 + [UInt8(ascii: "\n")]))
        try handle.close()
        let third = try publisher.publish(sources: sources(projects))
        XCTAssertTrue(third.published.contains(me + "transcripts/s1/2.jsonl"))
        XCTAssertTrue(third.published.contains(me + "days/2026-09-04.json"))
        XCTAssertEqual(third.transcriptChunks, 1)
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["s1"]?.seq, 2)

        // quit deletes now.json.
        try publisher.quit()
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
    }

    func testReshareRewrapsHistoryToTheCurrentAudienceAfterPromotion() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        _ = try t.leader.fetch()
        XCTAssertFalse(try header(t.leader, me + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })

        try t.leader.promote(kid: t.bob.identity.kid, now: 2_000)
        _ = try t.alice.fetch()
        let report = try publisher.reshare(days: 10_000)
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "crashes.json",
            me + "transcripts/s1/1.jsonl", me + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])   // never now.json: live state is stale by definition and is gone after quit
        _ = try t.bob.fetch()
        XCTAssertTrue(try header(t.bob, me + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })
        XCTAssertFalse(String(decoding: try t.bob.read(me + "transcripts/s1/1.jsonl").1, as: UTF8.self).contains("sk-ant"))
        // A zero-day window re-shares nothing.
        XCTAssertEqual(try publisher.reshare(days: 0, now: Date(timeIntervalSince1970: 4_000_000_000)).published, [])
    }

    func testPendingMemberCannotPublish() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (pp, ps) = machine("pending")
        let leader = try TeamClient.create(name: "P", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let pending = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "X", devices: [],
                                             platform: "linux", paths: pp, secrets: ps, now: 1_001)
        let projects = try writeProjects(scratch)
        XCTAssertThrowsError(try TeamPublisher(client: pending, paths: pp).publish(sources: sources(projects))) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamPublisherTests 2>&1 | tail -3`
Expected: compile errors (`Sources`, `publish(sources:)`, `reshare`, `quit`, `copiesDir`).

- [ ] **Step 3: Add the publishing half to `TeamPublisher.swift`**

Append inside `public struct TeamPublisher { … }`, after `collect`:

```swift
    // MARK: publishing

    /// Everything a publish reads, injected so tests and the CLI point
    /// at any directory. `fleets`/`blockers` come from the app's fleet
    /// view (plan 5); the CLI sends none.
    public struct Sources {
        public var projectsDir: URL
        public var codexDir: URL?
        /// A scan cache of the publisher's OWN (never the app's, which
        /// the app writes concurrently).
        public var cacheURL: URL?
        public var liveSessions: [ClaudeSessionRecord] = []
        public var crashes: [CrashReport] = []
        public var fleets: [TeamDocs.Fleet] = []
        public var blockers: [String] = []
        public var home: String
        public var includeImages = false
        /// Days of `days/` files published and files scanned (`maxAge`).
        public var historyDays = 30
        public var calendar: Calendar = .current
        public init(projectsDir: URL, home: String) { self.projectsDir = projectsDir; self.home = home }
    }

    public struct Report: Equatable, Encodable {
        public var published: [String] = []
        public var transcriptChunks = 0
        /// Whole-object files whose content had not changed.
        public var skipped = 0
        public init() {}
    }

    public let client: TeamClient
    public let paths: TeamPaths

    public init(client: TeamClient, paths: TeamPaths) { self.client = client; self.paths = paths }

    public var teamDir: URL { paths.teamDir(client.config.id) }
    /// Plaintext copies of what was published (spec §7 "re-share history
    /// re-wraps the local plaintext copies"); grows with the transcripts.
    public var copiesDir: URL { teamDir.appendingPathComponent("published") }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        for byte in Crypto.SHA256.hash(data: data) {
            out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }

    private func writeCopy(_ path: String, _ data: Data) throws {
        let url = copiesDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// One push (spec §7 cadence is the caller's): days that changed in
    /// the window, the session index and `now.json` every time, the
    /// crash list on change, every new transcript chunk. State advances
    /// only after the push succeeded.
    public func publish(sources: Sources, now: Date = Date()) throws -> Report {
        guard client.isMember else { throw TeamClient.ClientError.notInTeam }
        let shares = TeamShares.load(teamDir: teamDir)
        let exclusions = TeamExclusions.load(paths: paths)
        var state = TeamPublishState.load(teamDir: teamDir)
        let at = Int(now.timeIntervalSince1970)
        let calendar = sources.calendar
        let scan = StatsScanner.scan(projectsDir: sources.projectsDir, codexDir: sources.codexDir, cacheURL: sources.cacheURL,
                                     calendar: calendar, maxAge: Double(sources.historyDays) * 86_400, now: now)
        let collected = Self.collect(entries: scan.entries, exclusions: exclusions)
        let redaction = TeamRedaction.Options(home: sources.home, includeImages: sources.includeImages)
        var items: [TeamClient.PublishItem] = []
        var report = Report()

        // The hash is over the canonical bytes. `Stats.Day` carries two
        // `Set<String>`s whose JSON order follows Swift's per-process
        // hash seed, so across CLI runs an unchanged day can hash
        // differently and go out again — a wasted envelope, never a
        // wrong one. Within one process (the app's timer) it is stable.
        func stage(_ kind: String, _ path: String, _ plaintext: Data, always: Bool = false) throws {
            let digest = Self.hex(plaintext)
            if !always, state.hashes[path] == digest { report.skipped += 1; return }
            try writeCopy(path, plaintext)
            items.append(TeamClient.PublishItem(kind: kind, path: path, plaintext: plaintext, audience: shares.target(for: kind)))
            state.hashes[path] = digest
        }

        let floor = calendar.date(byAdding: .day, value: -sources.historyDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        for (key, day) in collected.days.sorted(by: { $0.key < $1.key }) {
            guard let date = Stats.date(fromDayKey: key, calendar: calendar), date >= floor else { continue }
            try stage(TeamKinds.stats, "days/\(key).json", try CanonicalJSON.encode(TeamDocs.DayDoc(day: key, stats: day)))
        }
        try stage(TeamKinds.sessions, "sessions/index.json",
                  try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: at, sessions: collected.sessions, fleets: sources.fleets)),
                  always: true)
        let live = sources.liveSessions
            .filter { !exclusions.excludes(cwd: $0.cwd, projectDir: TeamExclusions.slug($0.cwd)) }
            .map { TeamDocs.LiveSession(id: $0.sessionId, project: URL(fileURLWithPath: $0.cwd).lastPathComponent,
                                        status: $0.status ?? "", name: $0.name) }
        let today = calendar.startOfDay(for: now)
        let crashesToday = sources.crashes.filter { $0.at >= today }.count
        try stage(TeamKinds.now, "now.json",
                  try CanonicalJSON.encode(TeamDocs.Now(at: at, sessions: live, fleets: sources.fleets, blockers: sources.blockers,
                                                        crashesToday: crashesToday, sharesTo: shares.byKind)),
                  always: true)
        try stage(TeamKinds.crashes, "crashes.json",
                  try CanonicalJSON.encode(TeamDocs.Crashes(crashes: sources.crashes.map(\.summary))))

        for source in collected.transcripts {
            var cursor = state.transcripts[source.key] ?? TeamPublishState.Cursor()
            let (chunks, offset) = try TeamChunker.chunks(of: source.url, from: cursor.offset,
                                                          redact: { TeamRedaction.redact($0, options: redaction) })
            for chunk in chunks {
                cursor.seq += 1
                let path = source.chunkPath(seq: cursor.seq)
                try writeCopy(path, chunk)
                items.append(TeamClient.PublishItem(kind: TeamKinds.transcripts, path: path, plaintext: chunk,
                                                    audience: shares.target(for: TeamKinds.transcripts)))
                report.transcriptChunks += 1
            }
            cursor.offset = offset
            state.transcripts[source.key] = cursor
        }

        report.published = try client.publish(items, now: at)
        try state.save(teamDir: teamDir)
        return report
    }

    /// Spec §6.5 / §7: re-wraps the local plaintext copies of the last
    /// `days` days to the CURRENT audiences and republishes them — after
    /// a promotion, or an audience change the member wants applied to
    /// history. Day files go by their date, everything else by the
    /// copy's modification time.
    public func reshare(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Report {
        guard client.isMember else { throw TeamClient.ClientError.notInTeam }
        let shares = TeamShares.load(teamDir: teamDir)
        let floor = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        var items: [TeamClient.PublishItem] = []
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: copiesDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else {
            return Report()
        }
        let baseDepth = copiesDir.pathComponents.count
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            // Relative to the copies dir by components (never by string prefix:
            // macOS hands back /private/var for a /var temp dir).
            let path = url.pathComponents.dropFirst(baseDepth).joined(separator: "/")
            guard let kind = TeamKinds.expected(at: "m/\(client.identity.kid)/\(path)")?.kind else { continue }
            // Live state is never re-shared: the copy is stale, and it would
            // come back after `quit()` deleted it. The next publish rewraps it.
            if kind == TeamKinds.now { continue }
            if kind == TeamKinds.stats {
                let key = String(url.deletingPathExtension().lastPathComponent)
                guard let date = Stats.date(fromDayKey: key, calendar: calendar), date >= floor else { continue }
            } else {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard mtime >= floor else { continue }
            }
            items.append(TeamClient.PublishItem(kind: kind, path: path, plaintext: try Data(contentsOf: url),
                                                audience: shares.target(for: kind)))
        }
        items.sort { $0.path < $1.path }
        var report = Report()
        report.published = try client.publish(items, now: Int(now.timeIntervalSince1970))
        return report
    }

    /// Spec §7: `now.json` is deleted on quit.
    public func quit() throws { try client.unpublish(path: "now.json") }
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamPublisherTests 2>&1 | tail -3`
Expected: 3 tests pass. If `reshare(days: 0, now: 4_000_000_000)` still lists day files, check the `floor` comparison: the day file's date (2026-09-04) must be before `startOfDay(now) − 0 days` in 2096 — it is; a copy's mtime is "now" on the real clock, also before, so nothing is listed.

- [ ] **Step 5: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamPublisher.swift Tests/InfinitusCoreTests/TeamPublisherTests.swift && \
git commit -m "team: publisher — days, now, sessions, redacted chunks and crashes to their audiences in one push; re-share history; quit deletes now.json

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `TeamReader` and the integration flow

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamReader.swift`
- Test: `Tests/InfinitusCoreTests/TeamReaderTests.swift`

**Interfaces:**
- Consumes: Task 1 (`TeamClient.readableHeaders()`, `read(_:)`, `roster`, `remove`), Task 4 (`TeamDocs`), Task 6 (`TeamPublisher`), `Stats.Day` `+`, `Stats.fold(days:period:now:calendar:)`, `Stats.Summary`, `SessionFeedReader.parse(lines:limit:)`, `SessionFeedItem`.
- Produces:
  - `struct TeamReader.Member: Equatable { kid: String; name: String; role: String ("leader"|"member"|"removed"); days: [String: Stats.Day]; now: TeamDocs.Now?; sessions: [TeamDocs.SessionRow]; crashes: [String]; transcripts: [String: [String]] (transcript key → chunk store paths in seq order); lastPublished: Int?; kinds: Set<String> }`
  - `struct TeamReader { members: [String: Member]; static func fold(headers: [(entry: StoreEntry, header: Envelope.Header)], roster: TeamRoster, read: (String) throws -> Data) -> TeamReader; static func load(client: TeamClient) throws -> TeamReader; func summary(kid: String, period: Stats.Period, now: Date = Date(), calendar: Calendar = .current) -> Stats.Summary?; func teamDays() -> [String: Stats.Day]; func transcript(kid: String, session: String, client: TeamClient, limit: Int = 200) throws -> [SessionFeedItem] }`

Spec §8.1: fold every readable `days/` envelope into `Stats.Day` per member per day (`+`), keep `now.json` per member, index sessions, and stream transcript chunks into `SessionFeedReader.parse` so a member's session renders in the phone's chat view. A document with an unknown `schema`, or one that fails to decode, is skipped, never fatal. Transcript chunks are decrypted on demand, not at load. The tests build `Envelope.Header` with its memberwise init, which is internal — `@testable import InfinitusCore` reaches it; do not add a public init for the tests' sake.

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamReaderTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamReaderTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: pure folding

    func entry(_ path: String, kind: String, from: String, at: Int) -> (entry: StoreEntry, header: Envelope.Header) {
        (StoreEntry(path: path, size: 1, version: "v"),
         Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: [], at: at, nonce: "", sig: nil))
    }

    func testFoldGroupsPerMemberSumsDaysAndOrdersChunks() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random(), gone = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "A", since: 2), TeamRoster.Member(keys: b.keys, name: "B", since: 3)],
                                removed: [TeamRoster.Removed(kid: gone.kid, at: 900, keys: gone.keys)], rev: 4)
        var d1 = Stats.Day(); d1.inputTokens = 10; d1.commits = 1
        var d2 = Stats.Day(); d2.inputTokens = 5
        var docs: [String: Data] = [:]
        docs["m/\(a.kid)/days/2026-09-04.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-04", stats: d1))
        docs["m/\(b.kid)/days/2026-09-04.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-04", stats: d2))
        docs["m/\(b.kid)/days/2026-09-03.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-03", stats: d2))
        docs["m/\(a.kid)/now.json"] = try CanonicalJSON.encode(TeamDocs.Now(at: 50, sessions: [], fleets: [], blockers: ["aws"], crashesToday: 0, sharesTo: [:]))
        docs["m/\(a.kid)/crashes.json"] = try CanonicalJSON.encode(TeamDocs.Crashes(crashes: ["Mac · crash · x"]))
        docs["m/\(a.kid)/sessions/index.json"] = try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: 50, sessions: [TeamDocs.SessionRow(id: "s1", project: "app", engine: "claude")], fleets: []))
        docs["m/\(b.kid)/days/2026-09-02.json"] = Data("{\"schema\":9}".utf8)      // unknown schema: skipped
        docs["m/\(gone.kid)/days/2026-09-01.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-01", stats: d2))
        let headers = [
            entry("m/\(a.kid)/days/2026-09-04.json", kind: "stats", from: a.kid, at: 40),
            entry("m/\(b.kid)/days/2026-09-04.json", kind: "stats", from: b.kid, at: 41),
            entry("m/\(b.kid)/days/2026-09-03.json", kind: "stats", from: b.kid, at: 42),
            entry("m/\(b.kid)/days/2026-09-02.json", kind: "stats", from: b.kid, at: 43),
            entry("m/\(a.kid)/now.json", kind: "now", from: a.kid, at: 50),
            entry("m/\(a.kid)/crashes.json", kind: "crashes", from: a.kid, at: 30),
            entry("m/\(a.kid)/sessions/index.json", kind: "sessions", from: a.kid, at: 50),
            entry("m/\(a.kid)/transcripts/s1/10.jsonl", kind: "transcripts", from: a.kid, at: 60),
            entry("m/\(a.kid)/transcripts/s1/2.jsonl", kind: "transcripts", from: a.kid, at: 55),
            entry("m/\(a.kid)/transcripts/s1/subagents/agent-a/1.jsonl", kind: "transcripts", from: a.kid, at: 56),
            entry("m/\(gone.kid)/days/2026-09-01.json", kind: "stats", from: gone.kid, at: 800),
        ]
        var reads: [String] = []
        let reader = TeamReader.fold(headers: headers, roster: roster) { path in
            reads.append(path)
            guard let d = docs[path] else { throw Envelope.EnvelopeError.malformed }
            return d
        }
        XCTAssertEqual(Set(reader.members.keys), [l.kid, a.kid, b.kid, gone.kid])
        XCTAssertEqual(reader.members[l.kid]?.role, "leader")
        XCTAssertEqual(reader.members[a.kid]?.role, "member")
        XCTAssertEqual(reader.members[gone.kid]?.role, "removed")
        XCTAssertEqual(reader.members[a.kid]?.name, "A")
        XCTAssertEqual(reader.members[a.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.members[b.kid]?.days.count, 2)
        XCTAssertEqual(reader.members[a.kid]?.now?.blockers, ["aws"])
        XCTAssertEqual(reader.members[a.kid]?.crashes, ["Mac · crash · x"])
        XCTAssertEqual(reader.members[a.kid]?.sessions.map(\.id), ["s1"])
        XCTAssertEqual(reader.members[a.kid]?.transcripts["s1"],
                       ["m/\(a.kid)/transcripts/s1/2.jsonl", "m/\(a.kid)/transcripts/s1/10.jsonl"])   // numeric seq order
        XCTAssertEqual(reader.members[a.kid]?.transcripts["s1/subagents/agent-a"]?.count, 1)
        XCTAssertEqual(reader.members[a.kid]?.lastPublished, 60)
        XCTAssertEqual(reader.members[a.kid]?.kinds, ["stats", "now", "crashes", "sessions", "transcripts"])
        XCTAssertEqual(reader.members[l.kid]?.kinds, [])
        XCTAssertNil(reader.members[l.kid]?.lastPublished)
        XCTAssertFalse(reads.contains { $0.contains("transcripts/") })   // chunks are read on demand
        XCTAssertEqual(reader.teamDays()["2026-09-04"]?.inputTokens, 15)
        XCTAssertEqual(reader.teamDays()["2026-09-01"]?.inputTokens, 5)   // pre-removal history counts

        let noon = Stats.date(fromDayKey: "2026-09-04")!.addingTimeInterval(12 * 3600)
        let summary = try XCTUnwrap(reader.summary(kid: b.kid, period: .day, now: noon))
        XCTAssertEqual(summary.total.inputTokens, 5)
        XCTAssertEqual(summary.previous.inputTokens, 5)
        XCTAssertNil(reader.summary(kid: "stranger", period: .day, now: noon))
    }

    // MARK: the spec §11 integration flow

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// One project, one session (10 input tokens) whose prompt carries a key.
    func writeProjects(_ root: URL, name: String) throws -> URL {
        let projects = root.appendingPathComponent("\(name)-projects")
        let app = projects.appendingPathComponent("-r-app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let text = #"{"type":"user","cwd":"/r/app","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"# + "\n"
            + #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"# + "\n"
        try text.write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    func testCreateCodeRequestApprovePublishFetchReadThenRemove() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("alice"), (bp, bs) = machine("bob")
        // create → code → request → approve
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let alice = try TeamClient.request(code: code, name: "Alice", devices: ["Mac"], platform: "macos", paths: ap, secrets: asec, now: 1_010)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: alice.identity.kid, now: 1_020)
        try leader.approve(kid: bob.identity.kid, now: 1_021)
        _ = try alice.fetch(); _ = try bob.fetch()

        // publish (two members, same day) → fetch → read
        var s = TeamPublisher.Sources(projectsDir: try writeProjects(scratch, name: "alice"), home: "/Users/alice")
        s.historyDays = 10_000
        _ = try TeamPublisher(client: alice, paths: ap).publish(sources: s)
        var sb = TeamPublisher.Sources(projectsDir: try writeProjects(scratch, name: "bob"), home: "/home/bob")
        sb.historyDays = 10_000
        _ = try TeamPublisher(client: bob, paths: bp).publish(sources: sb)
        _ = try leader.fetch()
        let reader = try TeamReader.load(client: leader)
        XCTAssertEqual(reader.members[alice.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.members[bob.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.teamDays()["2026-09-04"]?.inputTokens, 20)
        XCTAssertEqual(reader.members[alice.identity.kid]?.sessions.map(\.project), ["app"])
        let items = try reader.transcript(kid: alice.identity.kid, session: "s1", client: leader)
        XCTAssertEqual(items.map(\.kind), [.user, .result])
        XCTAssertEqual(items[0].text, "use [redacted-key] please")
        XCTAssertEqual(items[1].text, "sure")
        XCTAssertEqual(try reader.transcript(kid: alice.identity.kid, session: "nope", client: leader), [])

        // Members see nothing of each other by default (leaders audience).
        _ = try bob.fetch()
        XCTAssertEqual(try TeamReader.load(client: bob).members[alice.identity.kid]?.kinds, [])

        // remove → a later publish is ignored; what came before stays.
        // Times are real-clock relative: the envelopes above were sealed
        // at Date(), so the removal instant must sit after them.
        let removedAt = Int(Date().timeIntervalSince1970) + 10
        try leader.remove(kid: bob.identity.kid, now: removedAt)
        _ = try TeamPublisher(client: bob, paths: bp).publish(sources: sb,
                                                              now: Date(timeIntervalSince1970: Double(removedAt + 10)))   // bob still holds rev 3
        _ = try leader.fetch()
        let after = try TeamReader.load(client: leader)
        XCTAssertEqual(after.members[bob.identity.kid]?.role, "removed")
        XCTAssertEqual(after.members[bob.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)   // sealed before removal
        XCTAssertNil(after.members[bob.identity.kid]?.now)                                    // now.json was re-sealed after removal
        _ = try bob.fetch()
        XCTAssertThrowsError(try TeamPublisher(client: bob, paths: bp).publish(sources: sb)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamReaderTests 2>&1 | tail -3`
Expected: compile error, `TeamReader` not found.

- [ ] **Step 3: Create `TeamReader.swift`**

```swift
import Foundation

/// Spec §8.1: what this identity can read, folded per member into the
/// shapes the app already renders — `Stats.Day` per day (Stats v2 `+`),
/// the latest `now.json`, the session index, crash summaries, and the
/// transcript chunks a session has (decrypted on demand through
/// `transcript`, then `SessionFeedReader.parse` like a live session).
public struct TeamReader {
    public struct Member: Equatable {
        public var kid: String
        public var name: String
        /// "leader" | "member" | "removed" (pre-removal history still readable).
        public var role: String
        public var days: [String: Stats.Day] = [:]
        public var now: TeamDocs.Now?
        public var sessions: [TeamDocs.SessionRow] = []
        public var crashes: [String] = []
        /// `TeamPublisher.TranscriptSource.key` → chunk store paths in seq order.
        public var transcripts: [String: [String]] = [:]
        public var lastPublished: Int?
        public var kinds: Set<String> = []
        public init(kid: String, name: String, role: String) { self.kid = kid; self.name = name; self.role = role }
    }

    public private(set) var members: [String: Member] = [:]

    public init() {}

    /// Pure: `read` returns an envelope's plaintext (the client's `read`
    /// in practice). A document that fails to decode or carries a
    /// schema this build does not know is skipped.
    public static func fold(headers: [(entry: StoreEntry, header: Envelope.Header)], roster: TeamRoster,
                            read: (String) throws -> Data) -> TeamReader {
        var reader = TeamReader()
        for m in roster.everyone {
            reader.members[m.keys.kid] = Member(kid: m.keys.kid, name: m.name, role: roster.isLeader(m.keys.kid) ? "leader" : "member")
        }
        func decode<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
            guard let data = try? read(path) else { return nil }
            return try? CanonicalJSON.decode(type, from: data)
        }
        for (entry, header) in headers {
            var member = reader.members[header.from] ?? Member(kid: header.from, name: header.from, role: "removed")
            member.kinds.insert(header.kind)
            member.lastPublished = max(member.lastPublished ?? 0, header.at)
            switch header.kind {
            case TeamKinds.stats:
                if let doc = decode(TeamDocs.DayDoc.self, entry.path), doc.schema == 1 {
                    member.days[doc.day] = (member.days[doc.day] ?? Stats.Day()) + doc.stats
                }
            case TeamKinds.now:
                if let doc = decode(TeamDocs.Now.self, entry.path), doc.schema == 1 { member.now = doc }
            case TeamKinds.sessions:
                if let doc = decode(TeamDocs.SessionsIndex.self, entry.path), doc.schema == 1 { member.sessions = doc.sessions }
            case TeamKinds.crashes:
                if let doc = decode(TeamDocs.Crashes.self, entry.path), doc.schema == 1 { member.crashes = doc.crashes }
            case TeamKinds.transcripts:
                // m/<kid>/transcripts/<key…>/<seq>.jsonl
                let parts = entry.path.split(separator: "/").map(String.init)
                if parts.count >= 5 {
                    let key = parts[3..<(parts.count - 1)].joined(separator: "/")
                    member.transcripts[key, default: []].append(entry.path)
                }
            default:
                break
            }
            reader.members[header.from] = member
        }
        for kid in reader.members.keys {
            reader.members[kid]?.transcripts = reader.members[kid]!.transcripts.mapValues { paths in
                paths.sorted { Self.seq($0) < Self.seq($1) }
            }
        }
        return reader
    }

    static func seq(_ path: String) -> Int {
        Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) ?? 0
    }

    public static func load(client: TeamClient) throws -> TeamReader {
        guard let roster = client.roster?.doc else { throw TeamClient.ClientError.noRoster }
        return fold(headers: try client.readableHeaders(), roster: roster) { try client.read($0).1 }
    }

    /// One member's period summary in the app's own shape (`Stats.fold`).
    public func summary(kid: String, period: Stats.Period, now: Date = Date(), calendar: Calendar = .current) -> Stats.Summary? {
        guard let member = members[kid] else { return nil }
        return Stats.fold(days: member.days, period: period, now: now, calendar: calendar)
    }

    /// Every member's days summed (Stats v2 `+`) — the team picture.
    public func teamDays() -> [String: Stats.Day] {
        var out: [String: Stats.Day] = [:]
        for member in members.values {
            for (key, day) in member.days { out[key] = (out[key] ?? Stats.Day()) + day }
        }
        return out
    }

    /// A member's session as chat items: every chunk of the session's own
    /// transcript in order, decrypted now, through the same parser the
    /// phone uses for live sessions. Sub-agent chunks are listed under
    /// `transcripts["<session>/subagents/<agent>"]` for a later view.
    public func transcript(kid: String, session: String, client: TeamClient, limit: Int = 200) throws -> [SessionFeedItem] {
        guard let paths = members[kid]?.transcripts[session], !paths.isEmpty else { return [] }
        var lines: [String] = []
        for path in paths {
            let text = String(decoding: try client.read(path).1, as: UTF8.self)
            lines += text.split(separator: "\n").map(String.init)
        }
        return SessionFeedReader.parse(lines: lines, limit: limit)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test --filter TeamReaderTests 2>&1 | tail -3`
Expected: 2 tests pass. In the integration test, bob's second publish (after removal, `now: 6_000 > 5_000`) re-seals `days/2026-09-04.json` too — its hash is unchanged so it is *skipped*, which is why the pre-removal day file survives while `now.json` (always re-sealed) disappears from the leader's view.

- [ ] **Step 5: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCore/Team/TeamReader.swift Tests/InfinitusCoreTests/TeamReaderTests.swift && \
git commit -m "team: TeamReader folds what I can read per member — days, now, sessions, crashes, transcript chunks into SessionFeed; the §11 integration flow

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `infinitusctl team share|exclude|members|member|remove|promote|publish|reshare` and the release line

**Files:**
- Modify: `Sources/InfinitusCLI/TeamCommand.swift`
- Modify: `CHANGELOG.md` (one line under `### Team (preview)`)

**Interfaces:**
- Consumes: Task 1 (`remove`, `promote`), Task 3 (`TeamShares`, `TeamExclusions`), Task 6 (`TeamPublisher`), Task 7 (`TeamReader`), `ClaudeSessions.configHome()`, `ClaudeSessions.list(claudeDir:)`, `StatsScanner.defaultCodexDir()`, `Stats.Period(rawValue:)`, `Stats.Summary.compacted()`, `TeamKinds.memberKinds`.
- Produces: the subcommands below. The raw opaque-bytes form of `publish` becomes `put` (nothing in `tools/e2e.sh` or CI uses the old spelling — checked with `grep -n "team publish\|--kind" tools/e2e.sh .github/workflows/ci.yml`).

There is no CLI test target; the verification is the build plus a scripted run against a bare repo under `INFINITUS_TEAM_DIR` (Step 4), then the full suite.

- [ ] **Step 1: Update the usage text**

Replace the body of `teamUsage()` with:

```swift
    """
    usage: infinitusctl team <subcommand> [args] [--option value]

      create <name> --remote <url> [--token -]     create a team on an empty git remote (token from stdin)
      code [--days N]                              team code for joiners (default 7 days)
      request - --name <n> [--devices a,b]         ask to join; the code on stdin (argv only if it carries no credential)
      status [--team <id>]                         this machine's team(s)
      requests                                     pending join requests (leaders)
      approve <kid> | decline <kid>                answer a request (leaders)
      remove <kid> | promote <kid>                 roster edits (leaders; the founder cannot be removed)
      fetch                                        pull the store and accept the roster
      members                                      the roster with what each member shares to me and when
      member <kid> [--period day|week|month|year]  one member's Stats summary (default week)
      share <kind> leaders|team|<kid>[,<kid>…]     audience for stats|now|sessions|transcripts|crashes (new envelopes; see reshare)
      exclude <project-dir> [--off]                keep a Claude Code project private (local, never sent)
      publish [--projects <dir>] [--days N]        publish stats, now, sessions, redacted transcripts, crashes (default 30 days)
      reshare [--days N]                           re-wrap the last N days (default 30) to the current audiences
      put --kind <k> --path <p> --file <f> [--audience leaders|team|<kid,kid>]   one opaque file (debugging)
      list                                         envelopes addressed to me
      read <path> [--out <file>]                   decrypt one envelope

    Narrowing an audience cannot recall ciphertext teammates already fetched.

    """
```

- [ ] **Step 2: Accept the one bare flag**

In `runTeam`, replace the option loop's `--` branch with:

```swift
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if bareFlags.contains(key) { flags.insert(key); i += 1; continue }
            // Every other team option takes a value; a bare flag is a typo,
            // not a boolean (`read --out` must never write to a file named "true").
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
```

and declare, next to `var options`:

```swift
    let bareFlags: Set<String> = ["off"]
    var flags: Set<String> = []
```

- [ ] **Step 3: Add the subcommands**

Rename the existing `case "publish":` to `case "put":` (body unchanged). Then insert, directly after the `case "read":` block and before `default:`, this contiguous block:

```swift
        case "remove":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.remove(kid: kid); emit(try c.status())
        case "promote":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.promote(kid: kid); emit(try c.status())
        case "share":
            guard positional.count >= 2 else { return fail(teamUsage(), code: 2) }
            let kind = positional[0]
            guard TeamKinds.memberKinds.contains(kind) else {
                return fail("kind must be one of \(TeamKinds.memberKinds.joined(separator: ", "))", code: 2)
            }
            guard let target = TeamShares.parseTarget(Array(positional.dropFirst())) else { return fail(teamUsage(), code: 2) }
            let c = try client()
            let teamDir = paths.teamDir(c.config.id)
            var shares = TeamShares.load(teamDir: teamDir)
            shares.byKind[kind] = target
            try shares.save(teamDir: teamDir)
            emit(shares)
        case "exclude":
            guard let project = positional.first else { return fail(teamUsage(), code: 2) }
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(project, excluded: !flags.contains("off"))
            try exclusions.save(paths: paths)
            emit(exclusions)
        case "members":
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            emit(reader.members.values.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }.map { m in
                MemberRow(kid: m.kid, name: m.name, role: m.role, lastPublished: m.lastPublished,
                          shares: m.kinds.sorted(), sessionsNow: m.now?.sessions.count ?? 0,
                          blockers: m.now?.blockers ?? [], crashes: m.crashes.count)
            })
        case "member":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            guard let summary = try TeamReader.load(client: c).summary(kid: kid, period: period) else {
                return fail("nothing readable from \(kid)")
            }
            emit(summary.compacted())
        case "publish":
            let c = try client(); _ = try c.fetch()
            let claudeDir = ClaudeSessions.configHome()
            var sources = TeamPublisher.Sources(
                projectsDir: options["projects"].map { URL(fileURLWithPath: $0) } ?? claudeDir.appendingPathComponent("projects"),
                home: NSHomeDirectory())
            // `--projects` points at a fixture: no Codex scan then, or a
            // smoke run would fold this machine's real Codex days in.
            sources.codexDir = options["projects"] == nil ? StatsScanner.defaultCodexDir() : nil
            sources.cacheURL = paths.teamDir(c.config.id).appendingPathComponent("scan-cache.json")
            sources.liveSessions = ClaudeSessions.list(claudeDir: claudeDir)
            sources.crashes = CrashStore(directory: CrashStore.defaultDirectory()).list()
            if let days = options["days"].flatMap(Int.init) { sources.historyDays = days }
            emit(try TeamPublisher(client: c, paths: paths).publish(sources: sources))
        case "reshare":
            let c = try client(); _ = try c.fetch()
            let days = options["days"].flatMap(Int.init) ?? 30
            emit(try TeamPublisher(client: c, paths: paths).reshare(days: days))
```

and next to `ReadableEntry` add:

```swift
private struct MemberRow: Encodable {
    var kid: String; var name: String; var role: String; var lastPublished: Int?
    var shares: [String]; var sessionsNow: Int; var blockers: [String]; var crashes: Int
}
```

`TeamShares`, `TeamExclusions` and `TeamPublisher.Report` are `Encodable`, so `emit` prints them as-is.

- [ ] **Step 4: Build and run the CLI against a bare repo**

Run:

```bash
cd /Users/deathemperor/death/limitless-t-publisher && swift build --product infinitusctl 2>&1 | tail -3
D=$(mktemp -d /tmp/tpub.XXXX); git init --bare -q $D/remote.git
CTL=.build/debug/infinitusctl
INFINITUS_TEAM_DIR=$D/leader $CTL team create Papaya --remote file://$D/remote.git | head -3
CODE=$(INFINITUS_TEAM_DIR=$D/leader $CTL team code | sed -n 's/.*"code" *: *"\(.*\)".*/\1/p')
echo "$CODE" | INFINITUS_TEAM_DIR=$D/member $CTL team request - --name Bo > /dev/null
KID=$(INFINITUS_TEAM_DIR=$D/member $CTL team status | sed -n 's/.*"kid" *: *"\(.*\)".*/\1/p')
INFINITUS_TEAM_DIR=$D/leader $CTL team approve $KID > /dev/null
mkdir -p $D/projects/-r-app && printf '%s\n%s\n' \
 '{"type":"user","cwd":"/r/app","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"hi sk-ant-api03-abcdefghijklmnopqrstuvwxyz"}}' \
 '{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}' \
 > $D/projects/-r-app/s1.jsonl
INFINITUS_TEAM_DIR=$D/member $CTL team share stats team
INFINITUS_TEAM_DIR=$D/member $CTL team exclude /r/other
INFINITUS_TEAM_DIR=$D/member $CTL team exclude /r/other --off
INFINITUS_TEAM_DIR=$D/member $CTL team publish --projects $D/projects --days 10000
INFINITUS_TEAM_DIR=$D/leader $CTL team members
INFINITUS_TEAM_DIR=$D/leader $CTL team member $KID --period year | grep -c inputTokens
INFINITUS_TEAM_DIR=$D/leader $CTL team read m/$KID/transcripts/s1/1.jsonl | grep -c redacted-key
INFINITUS_TEAM_DIR=$D/member $CTL team reshare --days 10000 | grep -c jsonl
INFINITUS_TEAM_DIR=$D/leader $CTL team remove $KID | grep '"members"'
rm -rf $D
```

Expected: `publish` lists `m/<kid>/days/2026-09-04.json`, `sessions/index.json`, `now.json`, `crashes.json` and `transcripts/s1/1.jsonl`; `members` shows Bo with the five kinds under `shares` (`sessionsNow` counts whatever live Claude Code sessions this machine has — reading `~/.claude/sessions` is allowed); `member … --period year | grep -c inputTokens` prints a positive count; `read … | grep -c redacted-key` prints `1`; `reshare … | grep -c jsonl` prints a positive count; `remove` shows `"members" : 0`. Nothing printed contains `sk-ant`. (`emit` pretty-prints with a space before the colon on macOS; the `sed`s allow it.)

- [ ] **Step 5: The release line**

In `CHANGELOG.md`, under `### Team (preview)` (line ~55), add after the existing bullet:

```markdown
- Members publish their stats, live state, session index, redacted transcripts and crash summaries to the audiences they pick, with per-project exclusions (`infinitusctl team share|exclude|publish|members|member`).
```

- [ ] **Step 6: Full suite**

Run: `cd /Users/deathemperor/death/limitless-t-publisher && swift test 2>&1 | tail -3`
Expected: every test passes (the plan-1 count plus this plan's 29).

- [ ] **Step 7: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-publisher && git add Sources/InfinitusCLI/TeamCommand.swift CHANGELOG.md && \
git commit -m "team: infinitusctl team share|exclude|members|member|remove|promote|publish|reshare; publish publishes real kinds

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage**
- §7 table: stats (`days/<date>.json`, `Stats.Day`, minus excluded projects — Tasks 4, 6), now (sessions by status, fleets with opaque engine ids, blockers, crashes today, `sharesTo` — Task 6; deleted on quit — `quit()`), sessions (id, project basename, start/end, busy/waiting minutes, activity mix, $, fleet health — Tasks 4, 6), transcripts (redacted, append-only ≤1 MiB chunks, sub-agents under the same session — Tasks 5, 6), crashes (`CrashReport.summary` list, on change — Task 6). Cadence: documented as the caller's (Global Constraints); day files re-sealed only when the day changed (hash), the index and `now.json` on every push.
- §7 audiences per kind, applied to new envelopes; "Re-share history" (`reshare(days:)`, default 30 in the CLI); "narrowing cannot recall" said in the CLI usage — Tasks 3, 6, 8.
- §7.1 redaction: bearer tokens, `sk-…`, AWS access keys / session tokens, webhook URLs, `.env` dumps, `Authorization:` headers, home paths → `~`, images dropped unless included — Task 2. "The patterns the app already masks in logs": the app masks whole tokens (`MirrorPairing.mask`), which these rules subsume.
- §8.1 `TeamReader`: folds `days/` per member per day with `+`, keeps `now.json`, indexes sessions, streams chunks into `SessionFeedReader.parse` — Task 7.
- §8.4 members' view: a member reads only what teammates chose to share to it (explicit `.members`), tested in Tasks 1, 6, 7. `membersSeeEachOther` re-publication is leader-side (plan 9).
- §11 unit items: audience wrapping incl. promotion re-wrap (Tasks 1, 6), per-project exclusion in the publisher (Tasks 4, 6), redaction fixtures (Task 2), transcript chunking (Task 5), `TeamReader` folding (Task 7). Integration: two identities, local bare repo, create → code → request → approve → publish → fetch → read; remove → publish is ignored (Tasks 1, 7). "Leave" is §6.5 and not in this stream.
- #55 carry-overs: (a) `keys(for:at:)` + `Removed.keys`, `readableHeaders`/`read` (Task 1); (b) `TeamKinds.check` on write and read, including the sender segment (Task 1); (c) `badSchema` (Task 1); (d) explicit audiences, decision recorded in Task 1.

**Placeholder scan**: no TBD/TODO/"similar to Task N"; every code step carries its code (the fixture helper is repeated in Tasks 4, 6 and 7 on purpose so each test file stands alone).

**Known softness, logged for the implementer**: the day-file hash (Task 6) is over canonical bytes that include two `Set<String>`s, so across CLI processes an unchanged day may be re-sealed once per run — harmless; the app's in-process timer (plan 5) is stable. If it proves noisy, hash `day.compacted()` plus `hours` instead and note it on issue #55.

**Type consistency**: `TeamClient.PublishItem(kind:path:plaintext:audience:)` and `publish(_:now:) -> [String]` (Task 1) are what Task 6 calls; `readableHeaders() -> [(entry:header:)]` (Task 1) is what Task 7's `fold` takes; `TeamPublisher.TranscriptSource.key/chunkPath` (Task 4) match `TeamPublishState.transcripts` keys (Task 5) and the reader's transcript keys (Task 7); `TeamDocs.DayDoc.day`/`stats`, `Now.sessions/blockers/crashesToday/sharesTo`, `SessionsIndex.sessions/fleets`, `Crashes.crashes` are used with the same names in Tasks 6, 7 and 8; `TeamShares.target(for:)`, `TeamExclusions.excludes(cwd:projectDir:)` and `slug(_:)` are used as defined in Task 3; `Report.published/transcriptChunks/skipped` as defined in Task 6.
