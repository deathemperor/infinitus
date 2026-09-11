# Team — Sharing controls + publisher robustness (round 4, `team-share`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member can keep a whole kind off the store ("Nobody") and pick which recent sessions' transcripts travel; a publish reports its progress, stops cooperatively on quit, and caps the plaintext copies it keeps on this Mac; a failed `team create` leaves nothing behind; the phone gets the error of the call it made, not an older one; and a git push with chatty progress output can no longer hang the publish.

**Architecture:** `TeamRoster.ShareTarget` gains `.off` — the publisher never chunks, seals, copies or re-shares a kind whose target is `.off`, and the `sharesTo` hint on `now.json` omits it so no `"off"` string ever lands on the store. A new `TeamTranscriptChoices` (per team, local) filters the transcript sources by session id; `TeamPublisher.recentTranscriptSessions` reads the publisher's own scan cache to feed the picker. `TeamPublisher.Sources` grows two `@Sendable` hooks — `onProgress` (fired once per source and once per batch push, never per chunk) and `shouldStop` — plus `copiesCapBytes`; `TeamPublisher.Report` grows `stopped` and `prunedCopies`. `TeamModel.action` returns the masked error of THAT call. `TeamGit` drains stdout and stderr concurrently.

**Tech Stack:** Swift 6 compiler in Swift 5 language mode (`swift-tools-version: 5.9`), Foundation, Dispatch, `os` (`OSAllocatedUnfairLock`, app target only), SwiftUI/AppKit for the pane, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` — §1 (audiences per data kind), §6.1/§6.5 (create, leave), §7 (what a member publishes, cadence, re-share), §7.1 (redaction).

## Global Constraints

- **File ownership (two streams in parallel, both merging into `main`).**
  - This stream MAY edit:
    - `Sources/InfinitusCore/Team/TeamPublisher.swift`, `TeamChunker.swift`, `TeamShares.swift`, `TeamGit.swift`, `TeamPaths.swift`
    - `Sources/InfinitusCore/Team/TeamRoster.swift` — ONLY the `ShareTarget` enum (lines 7–29) and `recipients(for:)` (lines 105–115)
    - `Sources/InfinitusCore/Team/TeamClient.swift` — ONLY `ClientError` (lines 33–49), `create(...)` (lines 85–102) and `publish(_:now:)` (lines 315–331)
    - new `Sources/InfinitusCore/Team/TeamTranscriptChoices.swift`
    - `Sources/InfinitusCLI/TeamCommand.swift` — ONLY the usage text (lines 9–42) and `case "share"` (lines 210–230)
    - `Sources/Infinitus/TeamModel.swift` — everything EXCEPT lines 317–376 (the `// MARK: nearby` block: `scanNearby`, `requestNearby`, `blockingHTTP`, `pullNearbyRequest`) and lines 534–562 (`mintCode`, `mintInvite`), which belong to the other stream
    - `Sources/Infinitus/TeamPane.swift` — the busy overlay in `body` (lines 30–35), `sharingSection` (lines 296–315), `exclusionsSection` (lines 317–334), the `Privacy` section inside `inTeam` (lines 204–218) and the helpers `audienceTag` / `audience(from:)` (lines 353–365). NOT the `Nearby teams` section (lines 101–119), NOT the `Nearby` section (lines 176–194), NOT anything the other stream adds under them, NOT `inviteSection`.
    - `Sources/Infinitus/TeamMirrorHandler.swift` — ONLY the local `func action` closure (lines 14–18)
    - `Sources/Infinitus/AppModel.swift` — ONLY the literal `(5s)` inside the comment on line 1936
    - `Tests/InfinitusCoreTests/TeamPublisherTests.swift`, `TeamGitTests.swift`, `TeamClientTests.swift`, and the new `TeamSharesTests.swift`, `TeamTranscriptChoicesTests.swift`
    - `tools/e2e.sh` — the team section only (lines 321–348)
    - `CHANGELOG.md` — lines under `## 0.4.4 (unreleased)` → `### Team (preview)` (line 45), in the LAST task only
  - This stream MUST NOT edit: anything under `ios/`; `Sources/InfinitusCore/Team/TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`; `Sources/InfinitusCLI/TeamNearbyCommand.swift`; `Sources/InfinitusCLI/main.swift`; `Sources/Infinitus/MirrorServer.swift`; a new `Sources/Infinitus/TeamMirrorNearby.swift`; `Sources/Infinitus/ControlServer.swift`; `Sources/Infinitus/InfinitusApp.swift`; `Tests/InfinitusCoreTests/TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`; `site/`; `README.md`; the TeamModel nearby block (317–376) and mint block (534–562); the TeamPane nearby sections.
  - Every task's **Files** block repeats the forbidden list as "Do not touch:".
- Everything is Swift. InfinitusCore builds on macOS **and Linux**: no AppKit, no Security, no `os` in Core — guard anything platform-specific with `#if canImport(...)`. `OSAllocatedUnfairLock` is app-target only (`Sources/Infinitus`), never in Core or `Tests/InfinitusCoreTests`.
- Never read engine internals (`~/.claude-swap-backup/*`). Claude Code's own files under `~/.claude` are fine.
- Secrets (store token, pairing token) travel over stdin or the keychain, never argv, never plaintext on disk outside `secrets`; shown masked only. The team store token is embedded in every team code and invite link — never log one, never put one in an error string that reaches the UI (`TeamModel.mask` is what makes that safe).
- Idle CPU with the pop-out open stays ~0%: no `TimelineView`, no `repeatForever` animation, no per-chunk main-actor hop. A publish progress callback fires at most once per source and once per batch.
- Team-store I/O runs on `TeamModel.queue` via `run {}` / `action(...)`, never on the main actor. `TeamModel` is `@MainActor`.
- Tests: `swift test --filter <Suite>` per task; the full `swift test` before the final commit. UI tasks gate on `swift build --product Infinitus` (there is no app test target — see the note in Task 5).
- CHANGELOG: one feature = one short line under `### Team (preview)` in `## 0.4.4 (unreleased)`; added in the LAST task only.
- Every commit carries the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (the repo hook appends it; write it anyway). Stage by explicit path. **Never push.**
- Surgical changes, match existing style, no speculative abstractions, no new dependencies. No subagents from implementers.
- Swift 5 language mode still refuses a `var` mutated inside a `@Sendable` closure: tests that count callbacks use a small `final class Box: @unchecked Sendable`, never a captured `var`.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/InfinitusCore/Team/TeamRoster.swift` | + `ShareTarget.off` (encodes/decodes `"off"`), `recipients(for: .off) == []`. |
| `Sources/InfinitusCore/Team/TeamShares.swift` | `parseTarget(["off"])` / `["nobody"]` → `.off`. |
| `Sources/InfinitusCore/Team/TeamTranscriptChoices.swift` (new) | `mode` (`all` / `chosen`) + chosen session ids, `<teamDir>/transcript-choices.json`. |
| `Sources/InfinitusCore/Team/TeamPublisher.swift` | Skips off kinds, honours the session choices, `TranscriptSession` + `recentTranscriptSessions`, `Progress`/`shouldStop`/`copiesCapBytes`, `pruneCopies`, `Report.stopped`/`.prunedCopies`. |
| `Sources/InfinitusCore/Team/TeamClient.swift` | `ClientError.audienceOff`; `create` cleans its directory up on failure. |
| `Sources/InfinitusCore/Team/TeamGit.swift` | `drain(out:err:)` — both pipes at once. |
| `Sources/InfinitusCLI/TeamCommand.swift` | `team share <kind> off`; usage text. |
| `Sources/Infinitus/TeamModel.swift` | Transcript-choice state + actions, `progress`, `stopRequested`, `quitBound` 20 s, `action` returns this call's error. |
| `Sources/Infinitus/TeamPane.swift` | "Nobody" in every audience picker, the session picker, the capped-copies caption, the progress line. |
| `Sources/Infinitus/TeamMirrorHandler.swift` | `ActionReply` carries the error of the call it just made. |
| `tools/e2e.sh` | `team share transcripts off` publishes no chunks. |

---

### Task 1: "Nobody" — `ShareTarget.off`

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamRoster.swift` (the `ShareTarget` enum, `recipients(for:)`)
- Modify: `Sources/InfinitusCore/Team/TeamShares.swift` (`parseTarget`)
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift` (`publish`, `reshare`)
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`ClientError`, `publish(_:now:)`)
- Modify: `Sources/InfinitusCLI/TeamCommand.swift` (usage line 27)
- Modify: `Sources/Infinitus/TeamPane.swift` (`sharingSection` picker, `audienceTag`, `audience(from:)`)
- Modify: `tools/e2e.sh` (team section)
- Test: new `Tests/InfinitusCoreTests/TeamSharesTests.swift`; `Tests/InfinitusCoreTests/TeamPublisherTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift`, `InfinitusApp.swift`, `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**Interfaces:**
- Produces:

```swift
public enum ShareTarget: Codable, Equatable, Sendable {
    case off, leaders, team, members([String])   // "off" | "leaders" | "team" | [kid…]
}
extension TeamRoster { public func recipients(for target: ShareTarget) -> [TeamKeys] }  // .off → []
extension TeamShares { public static func parseTarget(_ words: [String]) -> TeamRoster.ShareTarget? }  // "off"/"nobody" → .off
extension TeamClient { public enum ClientError { case audienceOff /* …existing cases… */ } }
```

- [ ] **Step 1: Write the failing tests.** New file `Tests/InfinitusCoreTests/TeamSharesTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

/// The "Nobody" audience (spec §1 audiences, §7 per-kind choice).
final class TeamSharesTests: XCTestCase {
    func testOffRoundTripsAsAStringAndParsesFromTheCLISpelling() throws {
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(TeamRoster.ShareTarget.off), as: UTF8.self), "\"off\"")
        XCTAssertEqual(try CanonicalJSON.decode(TeamRoster.ShareTarget.self, from: Data("\"off\"".utf8)), .off)
        XCTAssertEqual(TeamShares.parseTarget(["off"]), .off)
        XCTAssertEqual(TeamShares.parseTarget(["nobody"]), .off)
        // The other spellings are untouched.
        XCTAssertEqual(TeamShares.parseTarget(["leaders"]), .leaders)
        XCTAssertEqual(TeamShares.parseTarget(["team"]), .team)
        XCTAssertEqual(TeamShares.parseTarget(["k1,k2"]), .members(["k1", "k2"]))
        XCTAssertNil(TeamShares.parseTarget([]))
    }

    func testNobodyIsNobodyEvenWithAFullRoster() {
        let leader = TeamIdentity.random().keys, member = TeamIdentity.random().keys
        let roster = TeamRoster(id: "t", name: "Papaya", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: leader, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: member, name: "Bo", since: 2)], rev: 1)
        XCTAssertEqual(roster.recipients(for: .off), [])
        XCTAssertEqual(roster.recipients(for: .leaders).map(\.kid), [leader.kid])
        XCTAssertEqual(Set(roster.recipients(for: .team).map(\.kid)), [leader.kid, member.kid])
    }

    /// An unset kind still means "leaders" — `.off` is a choice, never a default.
    func testTheDefaultIsStillLeaders() {
        XCTAssertEqual(TeamShares().target(for: TeamKinds.transcripts), .leaders)
    }
}
```

Append to `Tests/InfinitusCoreTests/TeamPublisherTests.swift`:

```swift
    /// Spec §7: a kind shared with Nobody is not chunked, not sealed, not
    /// copied and not hinted at on the store.
    func testAKindSharedWithNobodyNeverLeavesTheMac() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))   // one pass with everything on
        let me = "m/\(t.alice.identity.kid)/"

        var shares = TeamShares()
        shares.byKind[TeamKinds.stats] = .team
        shares.byKind[TeamKinds.transcripts] = .off
        try shares.save(teamDir: teamDir)
        // New lines that WOULD chunk if transcripts were still shared.
        let s1 = projects.appendingPathComponent("-r-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: s1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","timestamp":"2026-09-04T12:00:11.000Z","message":{"id":"a8","model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":1},"content":[{"type":"text","text":"nope"}]}}"#.utf8 + [UInt8(ascii: "\n")]))
        try handle.close()

        let report = try publisher.publish(sources: sources(projects))
        XCTAssertEqual(report.transcriptChunks, 0)
        XCTAssertFalse(report.published.contains { $0.contains("/transcripts/") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.copiesDir.appendingPathComponent("transcripts/s1/2.jsonl").path),
                       "an off kind is not copied to published/ either")
        // The cursor did not move: turning transcripts back on resumes where it stopped.
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["s1"]?.seq, 1)

        // The hint on now.json keeps the real audiences and drops the off one:
        // an older client's decoder would throw on an unknown "off".
        _ = try t.leader.fetch()
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.sharesTo["stats"], .team)
        XCTAssertNil(now.sharesTo["transcripts"])
        // Re-share does not resurrect it from the copies either.
        XCTAssertFalse(try publisher.reshare(days: 10_000).published.contains { $0.contains("/transcripts/") })
        // Defensive: nothing may seal to nobody.
        XCTAssertThrowsError(try t.alice.publish(kind: TeamKinds.stats, path: "days/2026-09-04.json",
                                                 plaintext: Data("{}".utf8), audience: .off)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .audienceOff)
        }
    }

    /// `now` off after a publish would leave this member looking "on"
    /// forever, so the stale now.json is retired once.
    func testNowSharedWithNobodyIsRetiredFromTheStore() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        _ = try t.leader.fetch()
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(me + "now.json"))

        var shares = TeamShares()
        shares.byKind[TeamKinds.now] = .off
        try shares.save(teamDir: teamDir)
        _ = try publisher.publish(sources: sources(projects))
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
        // Idempotent: the second pass has nothing left to delete and must not throw.
        XCTAssertNoThrow(try publisher.publish(sources: sources(projects)))
    }
```

- [ ] **Step 2: Run** `swift test --filter "TeamSharesTests|TeamPublisherTests"` → compile FAIL (`.off` and `.audienceOff` do not exist).

- [ ] **Step 3: `TeamRoster.ShareTarget`.** Replace lines 7–29 of `Sources/InfinitusCore/Team/TeamRoster.swift` with:

```swift
    /// Where a member's files of one kind go (spec §1 audiences).
    public enum ShareTarget: Codable, Equatable, Sendable {
        /// Nobody: the kind stays on this Mac — nothing is chunked,
        /// sealed, copied to `published/` or re-shared, and `now.json`'s
        /// `sharesTo` hint does not mention it. Offered for every member
        /// kind, with consequences worth saying out loud: `now` off makes
        /// this member look offline to the whole team (there is no live
        /// state to read), and `stats` off drops them out of every leader
        /// aggregate and leaderboard.
        case off
        case leaders, team, members([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let kids = try? c.decode([String].self) { self = .members(kids); return }
            switch try c.decode(String.self) {
            case "off": self = .off
            case "leaders": self = .leaders
            case "team": self = .team
            case let other: throw DecodingError.dataCorruptedError(in: c, debugDescription: "share target \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .off: try c.encode("off")
            case .leaders: try c.encode("leaders")
            case .team: try c.encode("team")
            case .members(let kids): try c.encode(kids)
            }
        }
    }
```

and add the case to `recipients(for:)` (line 109):

```swift
        switch target {
        case .off: return []
        case .leaders: return leaders.map(\.keys)
        case .team: return everyone.map(\.keys)
        case .members(let kids): return everyone.filter { kids.contains($0.keys.kid) }.map(\.keys)
        }
```

- [ ] **Step 4: `TeamShares.parseTarget`.** In `Sources/InfinitusCore/Team/TeamShares.swift`, after the `guard !kids.isEmpty else { return nil }` on line 29:

```swift
        if kids == ["off"] || kids == ["nobody"] { return .off }
```

Update the doc comment above `parseTarget` (line 25) to: `/// The CLI / UI spelling: `off` (or `nobody`), `leaders`, `team`, or kids /// separated by commas, or as separate arguments.`

- [ ] **Step 5: `TeamClient`.** Add to `ClientError` (after `case requestsOff`, line 48):

```swift
        /// A caller asked to seal to the "Nobody" audience. `TeamPublisher`
        /// skips those kinds before it gets here; this is the backstop.
        case audienceOff
```

and at the top of the `for item in items` loop in `publish(_:now:)` (line 320):

```swift
        for item in items {
            guard item.audience != .off else { throw ClientError.audienceOff }
```

- [ ] **Step 6: `TeamPublisher.publish`.** In `Sources/InfinitusCore/Team/TeamPublisher.swift`, after `let shares = TeamShares.load(teamDir: teamDir)` (line 187) add:

```swift
        // A kind shared with nobody is skipped entirely: never staged,
        // never chunked, never copied. `collect` only lists file URLs
        // (the scan itself has to run for the kinds that ARE shared), so
        // short-circuiting the staging is what keeps TeamChunker out of a
        // 9 GB corpus when transcripts are off.
        func off(_ kind: String) -> Bool { shares.target(for: kind) == .off }
        let transcriptsOff = off(TeamKinds.transcripts)
```

Then guard each staging site:

```swift
        let floor = calendar.date(byAdding: .day, value: -sources.historyDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        if !off(TeamKinds.stats) {
            for (key, day) in collected.days.sorted(by: { $0.key < $1.key }) {
                guard let date = Stats.date(fromDayKey: key, calendar: calendar), date >= floor else { continue }
                let doc = TeamDocs.DayDoc(day: key, stats: day)
                try stage(TeamKinds.stats, "days/\(key).json", try CanonicalJSON.encode(doc), digest: try Self.dayDigest(doc))
            }
        }
        if !off(TeamKinds.sessions) {
            try stage(TeamKinds.sessions, "sessions/index.json",
                      try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: at, sessions: collected.sessions, fleets: sources.fleets)),
                      always: true)
        }
```

`now` (lines 232–241) keeps its `live` / `crashesToday` computation and becomes:

```swift
        if off(TeamKinds.now) {
            // Turned off after a publish that sent one: a stale now.json
            // would keep this member "on" for the team forever. Retire it
            // once — the hash going away is what makes it once.
            if state.hashes.removeValue(forKey: "now.json") != nil { try client.unpublish(path: "now.json") }
        } else {
            try stage(TeamKinds.now, "now.json",
                      try CanonicalJSON.encode(TeamDocs.Now(at: at, sessions: live, fleets: sources.fleets, blockers: sources.blockers,
                                                            crashesToday: crashesToday,
                                                            // An older client's ShareTarget decoder throws on "off";
                                                            // the hint carries only kinds that actually travel.
                                                            sharesTo: shares.byKind.filter { $0.value != .off })),
                      always: true)
        }
        if !off(TeamKinds.crashes) {
            try stage(TeamKinds.crashes, "crashes.json",
                      try CanonicalJSON.encode(TeamDocs.Crashes(crashes: sources.crashes.map(\.summary))))
        }
```

and the transcript loop (line 245) becomes:

```swift
        for source in (transcriptsOff ? [] : collected.transcripts) {
```

- [ ] **Step 7: `TeamPublisher.reshare`.** After `let shares = TeamShares.load(teamDir: teamDir)` (line 276) nothing changes; inside the loop, after the `if kind == TeamKinds.now { continue }` line (292) add:

```swift
            // A kind the member turned off is not re-wrapped from the copies either.
            if shares.target(for: kind) == .off { continue }
```

- [ ] **Step 8: CLI usage.** In `Sources/InfinitusCLI/TeamCommand.swift`, replace line 27 with:

```
      share <kind> off|leaders|team|<kid>[,<kid>…]  audience for stats|now|sessions|transcripts|crashes ("off" keeps it on this machine; new envelopes — see reshare)
```

No change to `case "share"` itself: `parseTarget` already answers `off`/`nobody`, and the `.members` roster check is untouched. (`put --audience` stays as it is — it is a debugging command and `off` there means a kid named "off"; not worth a special case.)

- [ ] **Step 9: The pane.** In `Sources/Infinitus/TeamPane.swift`, the picker inside `sharingSection` (lines 299–305) gains Nobody first:

```swift
                Picker(kindTitle(kind), selection: Binding(
                    get: { audienceTag(team.shares.target(for: kind)) },
                    set: { tag in Task { await team.setShare(kind: kind, target: audience(from: tag, snap)) } })) {
                    Text("Nobody").tag("off")
                    Text("Leaders").tag("leaders")
                    Text("Whole team").tag("team")
                    ForEach(snap.members.filter { !$0.isMe }) { m in Text("Only \(m.name)").tag("kid:\(m.kid)") }
                }
```

`audienceTag` (line 353) gains `case .off: "off"`; `audience(from:)` (line 361) gains, as its first line, `if tag == "off" { return .off }`.

Add one caption line at the end of `sharingSection`, after the `Button("Re-share last 30 days…")` block (line 313):

```swift
            Text("Nobody keeps a kind on this Mac entirely. Live state off makes you look offline to the team; stats off leaves you out of the leaders' totals.")
                .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 10: e2e.** In `tools/e2e.sh`, insert after line 344 (the CLI publish that expects `transcriptChunks>=1`) and before line 345:

```sh
# "Nobody" (spec §7): the appended line WOULD chunk — the point of the
# assertion is that it does not while transcripts are off. Do not drop it.
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team share transcripts off \
    | expect "d['byKind']['transcripts']=='off'" || fail "team share transcripts off"
printf '%s\n' \
    "{\"type\":\"assistant\",\"timestamp\":\"$NOW\",\"message\":{\"id\":\"e2e-2\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1},\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}" \
    >> "$SOCKDIR/fixture/projects/-tmp-e2e/e2e1.jsonl"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish --projects "$SOCKDIR/fixture/projects" \
    | expect "d['transcriptChunks']==0" || fail "transcripts off must publish no chunks"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team share transcripts leaders \
    | expect "d['byKind']['transcripts']=='leaders'" || fail "restore the transcripts audience"
```

The later assertions stay valid: line 345 reads the chunk published at 343–344 (still on the store, still sealed to the leaders), and line 346–347 are the app's own publish.

- [ ] **Step 11: Run** `swift test --filter "TeamSharesTests|TeamPublisherTests|TeamClientTests|TeamRosterTests"` → PASS. Then `swift build --product Infinitus` and `swift build --product infinitusctl` (one `--product` per invocation) → both succeed.

- [ ] **Step 12: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamRoster.swift Sources/InfinitusCore/Team/TeamShares.swift \
        Sources/InfinitusCore/Team/TeamPublisher.swift Sources/InfinitusCore/Team/TeamClient.swift \
        Sources/InfinitusCLI/TeamCommand.swift Sources/Infinitus/TeamPane.swift tools/e2e.sh \
        Tests/InfinitusCoreTests/TeamSharesTests.swift Tests/InfinitusCoreTests/TeamPublisherTests.swift
git commit -m "team: share a kind with Nobody and it never leaves this Mac

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Per-session transcript choice

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamTranscriptChoices.swift`
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift` (`publish`, `reshare`, + `TranscriptSession`, `recentTranscriptSessions`)
- Modify: `Sources/Infinitus/TeamModel.swift` (`load()`, two actions)
- Modify: `Sources/Infinitus/TeamPane.swift` (`sharingSection`)
- Test: new `Tests/InfinitusCoreTests/TeamTranscriptChoicesTests.swift`; `Tests/InfinitusCoreTests/TeamPublisherTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift`, `InfinitusApp.swift`, `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**Interfaces:**
- Produces:

```swift
public struct TeamTranscriptChoices: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case all, chosen }
    public var mode: Mode
    public var chosen: Set<String>          // session ids
    public init()
    public func includes(_ sessionID: String) -> Bool
    public static func file(teamDir: URL) -> URL
    public static func load(teamDir: URL) -> TeamTranscriptChoices
    public func save(teamDir: URL) throws
}
extension TeamPublisher {
    public struct TranscriptSession: Identifiable, Equatable, Sendable {
        public var id: String       // the session id — TranscriptSource.session
        public var project: String  // basename of the cwd, never a path
        public var lastDay: String  // newest Stats day key the session touched
        public var bytes: Int
    }
    public static func recentTranscriptSessions(cacheURL: URL, days: Int, exclusions: TeamExclusions = TeamExclusions(),
                                                calendar: Calendar = .current, now: Date = Date()) -> [TranscriptSession]
}
extension TeamModel {
    @Published private(set) var transcriptChoices: TeamTranscriptChoices
    @Published private(set) var recentTranscripts: [TeamPublisher.TranscriptSession]
    func setTranscriptMode(_ mode: TeamTranscriptChoices.Mode) async
    func setTranscript(_ id: String, shared: Bool) async
}
```

**The key that identifies a session:** `TeamPublisher.TranscriptSource.session` (TeamPublisher.swift:12), which `transcriptIdentity` (line 34) derives as the file stem for `<project>/<sid>.jsonl` and as the *session directory name* for `<project>/<sid>/subagents/<agent>.jsonl`. So one choice covers a session AND every sub-agent under it — that is the intended behaviour, and the publish test asserts it.

- [ ] **Step 1: Write the failing tests.** New file `Tests/InfinitusCoreTests/TeamTranscriptChoicesTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamTranscriptChoicesTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamchoices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testTheDefaultIsEverySessionAndChosenIsExactlyWhatWasPicked() {
        var c = TeamTranscriptChoices()
        XCTAssertEqual(c.mode, .all)
        XCTAssertTrue(c.includes("anything"))
        c.mode = .chosen
        XCTAssertFalse(c.includes("s1"))
        c.chosen.insert("s1")
        XCTAssertTrue(c.includes("s1"))
        XCTAssertFalse(c.includes("s2"))
    }

    func testRoundTripsOnDisk() throws {
        let teamDir = scratch.appendingPathComponent("team-1")
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), TeamTranscriptChoices())
        var c = TeamTranscriptChoices()
        c.mode = .chosen
        c.chosen = ["s1", "s2"]
        try c.save(teamDir: teamDir)
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), c)
        XCTAssertEqual(TeamTranscriptChoices.file(teamDir: teamDir).lastPathComponent, "transcript-choices.json")
        // Garbage on disk falls back to the default rather than throwing.
        try Data("not json".utf8).write(to: TeamTranscriptChoices.file(teamDir: teamDir))
        XCTAssertEqual(TeamTranscriptChoices.load(teamDir: teamDir), TeamTranscriptChoices())
    }
}
```

Append to `Tests/InfinitusCoreTests/TeamPublisherTests.swift`:

```swift
    /// Spec §7: the member picks which sessions' transcripts travel; a
    /// session's sub-agents ride its choice.
    func testOnlyChosenSessionsAreChunkedAndThePickerListsTheRecentOnes() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var choices = TeamTranscriptChoices()
        choices.mode = .chosen
        choices.chosen = ["s1"]
        try choices.save(teamDir: teamDir)

        var s = sources(projects)
        let cacheURL = teamDir.appendingPathComponent("scan-cache.json")
        s.cacheURL = cacheURL   // the picker reads what this publish writes
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertEqual(Set(report.published.filter { $0.contains("/transcripts/") }),
                       [me + "transcripts/s1/1.jsonl", me + "transcripts/s1/subagents/agent-a1/1.jsonl"])
        XCTAssertEqual(report.transcriptChunks, 2, "s2 was not picked; s1's sub-agent rides s1's choice")
        // The unchosen session still contributes its day and its row.
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.alice.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id).sorted(), ["s1", "s2"])

        // What the pane's picker offers, off the same cache.
        let recent = TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 10_000)
        XCTAssertEqual(recent.map(\.id).sorted(), ["s1", "s2"])
        let one = try XCTUnwrap(recent.first { $0.id == "s1" })
        XCTAssertEqual(one.project, "app")
        XCTAssertEqual(one.lastDay, "2026-09-04")
        XCTAssertGreaterThan(one.bytes, 0)
        // The day floor: nothing is recent long after the fixture's day.
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 1,
                                                              now: Date(timeIntervalSince1970: 2_000_000_000)), [])
        // An excluded project is not even offered.
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true)
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 10_000, exclusions: ex).map(\.id), ["s1"])
        // No cache yet (a team that never published): an empty list, not a crash.
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: scratch.appendingPathComponent("nope.json"), days: 10_000), [])
    }
```

- [ ] **Step 2: Run** `swift test --filter "TeamTranscriptChoicesTests|TeamPublisherTests"` → compile FAIL.

- [ ] **Step 3: The new type.** `Sources/InfinitusCore/Team/TeamTranscriptChoices.swift`:

```swift
import Foundation

/// Spec §7 transcripts: WHICH sessions' chunks this member publishes.
/// `all` (the default) is every session inside the `transcriptDays`
/// window; `chosen` is exactly the session ids listed — a session's
/// sub-agent transcripts ride their session's choice, since they share
/// its id (`TeamPublisher.TranscriptSource.session`). Per team
/// (`<teamDir>/transcript-choices.json`), local, never sent — same shape
/// and lifetime as `TeamShares`.
public struct TeamTranscriptChoices: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case all, chosen }

    public var mode: Mode = .all
    public var chosen: Set<String> = []

    public init() {}

    public func includes(_ sessionID: String) -> Bool {
        switch mode {
        case .all: return true
        case .chosen: return chosen.contains(sessionID)
        }
    }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("transcript-choices.json") }

    public static func load(teamDir: URL) -> TeamTranscriptChoices {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamTranscriptChoices.self, from: $0) }
            ?? TeamTranscriptChoices()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }
}
```

- [ ] **Step 4: The publisher filter.** In `publish`, next to the `transcriptsOff` line from Task 1 — that is, after `let collected = …` (line 195) and BEFORE `func flush()` (line 204), because Task 4 hangs a local function off `toChunk` and a Swift local function cannot capture a local declared after it:

```swift
        let choices = TeamTranscriptChoices.load(teamDir: teamDir)
        let toChunk = transcriptsOff ? [] : collected.transcripts.filter { choices.includes($0.session) }
```

and replace Task 1's transcript-loop header with:

```swift
        for source in toChunk {
```

In `reshare`, load the choices next to `shares` (line 276) and, inside the loop after the `.off` guard from Task 1:

```swift
            if kind == TeamKinds.transcripts {
                // `path` is copies-relative: transcripts/<session>/…
                let session = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                guard choices.includes(session) else { continue }
            }
```

- [ ] **Step 5: The picker's data.** First give the transcript window one name, so the pane and the publisher cannot drift: in `Sources`, replace line 115 (`public var transcriptDays = 2`) with

```swift
        public static let defaultTranscriptDays = 2
        public var transcriptDays = Sources.defaultTranscriptDays
```

leaving the doc comment above it untouched. Then add to `TeamPublisher`, right after the `TranscriptSource` struct (line 21):

```swift
    /// One session the transcript picker can offer (spec §7): read from
    /// the publisher's own scan cache, never by walking the corpus.
    public struct TranscriptSession: Identifiable, Equatable, Sendable {
        public var id: String
        public var project: String
        public var lastDay: String
        public var bytes: Int
        public init(id: String, project: String, lastDay: String, bytes: Int) {
            self.id = id; self.project = project; self.lastDay = lastDay; self.bytes = bytes
        }
    }
```

and, after `collect` (line 90):

```swift
    /// Claude Code sessions with activity on or after the `days` floor,
    /// newest day first — what Settings › Team lists when the member
    /// picks sessions by hand. Reads `scan-cache.json` (tens of MB in
    /// real use), so it runs on the team queue, never the main actor.
    /// Codex files are not chunked by anyone, so they are not offered.
    public static func recentTranscriptSessions(cacheURL: URL, days: Int, exclusions: TeamExclusions = TeamExclusions(),
                                                calendar: Calendar = .current, now: Date = Date()) -> [TranscriptSession] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(StatsScanner.Cache.self, from: data) else { return [] }
        let floorDate = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        let floor = Stats.dayKey(floorDate, calendar: calendar)
        var out: [String: TranscriptSession] = [:]
        for (path, entry) in cache.files {
            guard entry.engine == Stats.Engine.claude.rawValue else { continue }
            let identity = transcriptIdentity(path)
            if exclusions.excludes(cwd: entry.cwd, projectDir: identity.projectDir) { continue }
            // Day keys, not `lastAt`: a sub-agent file carries days but no
            // session times (same rule as `collect`), and ISO day keys
            // compare as strings.
            guard let lastDay = entry.days.keys.max(), lastDay >= floor else { continue }
            let project = entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var row = out[identity.session]
                ?? TranscriptSession(id: identity.session, project: project ?? String(identity.projectDir.split(separator: "-").last ?? ""),
                                     lastDay: lastDay, bytes: 0)
            // A sub-agent file seen first carries no cwd; the session's own file names the project.
            if let project, identity.agent == nil { row.project = project }
            row.lastDay = max(row.lastDay, lastDay)
            row.bytes += entry.size
            out[identity.session] = row
        }
        return out.values.sorted { $0.lastDay == $1.lastDay ? $0.id < $1.id : $0.lastDay > $1.lastDay }
    }
```

(`StatsScanner.Cache` is internal to InfinitusCore — `struct Cache: Codable { var version = 9; var files: [String: FileEntry] }`, StatsScanner.swift:358 — and `TeamPublisher` is in the same module, so no new API is needed there. Do NOT make it public.)

- [ ] **Step 6: `TeamModel`.** Add next to the other published state (after `exclusions`, line 29):

```swift
    /// Spec §7: which sessions' transcripts travel. `recentTranscripts`
    /// is filled only in `chosen` mode — the scan cache is tens of MB and
    /// decoding it on every reload for a picker nobody opened is pure IO.
    @Published private(set) var transcriptChoices = TeamTranscriptChoices()
    @Published private(set) var recentTranscripts: [TeamPublisher.TranscriptSession] = []
```

Add the carrier type at FILE scope, above `final class TeamModel` (line 13) — a type nested in a `@MainActor` class inherits that isolation, and this one is built inside the `run {}` closure off the main actor:

```swift
/// The transcript picker's state, read in one pass on the team queue.
private struct TranscriptPicker: Sendable, Equatable {
    var choices = TeamTranscriptChoices()
    var recent: [TeamPublisher.TranscriptSession] = []
}
```

In `load()` (line 119), widen the tuple by ONE element (the existing 7 stay in place and order). The window is the publisher's own default: `TeamModel.sources()` is `AppModel.teamSources()` (AppModel.swift:1473), which lists live sessions and crash reports off the disk — calling it on every reload would be main-actor I/O, and the app never overrides `transcriptDays` anyway.

```swift
        let fetch = lastFetchAt, publish = lastPublishAt, err = lastError
        return Task {
            do {
                let result: (TeamSnapshot?, TeamReader?, TeamShares, TeamExclusions, String?, Signed<TeamRoster>?, [Signed<TeamRequest>], TranscriptPicker) = try await run { paths, secrets in
                    let kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                    let exclusions = TeamExclusions.load(paths: paths)
                    guard let client = try Self.openClient(paths, secrets) else { return (nil, nil, TeamShares(), exclusions, kid, nil, [], TranscriptPicker()) }
                    let dir = paths.teamDir(client.config.id)
                    let (snap, reader) = try Self.snapshot(client, lastFetch: fetch, lastPublish: publish, lastError: err)
                    let pendingNearby = client.isLeader ? TeamNearby.Store.pending(team: client.config.id, paths: paths) : []
                    let choices = TeamTranscriptChoices.load(teamDir: dir)
                    let picker = TranscriptPicker(choices: choices, recent: choices.mode == .chosen
                        ? TeamPublisher.recentTranscriptSessions(cacheURL: dir.appendingPathComponent("scan-cache.json"),
                                                                 days: TeamPublisher.Sources.defaultTranscriptDays,
                                                                 exclusions: exclusions)
                        : [])
                    return (snap, reader, TeamShares.load(teamDir: dir), exclusions, kid, client.roster, pendingNearby, picker)
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    snapshot = result.0; reader = result.1; shares = result.2; exclusions = result.3; kid = result.4
                    roster = result.5; pendingNearby = result.6
                    transcriptChoices = result.7.choices; recentTranscripts = result.7.recent
                }
            } catch {
                lastError = Self.mask(error)
            }
        }
```

Add the two actions next to `setShare` (after line 607):

```swift
    /// Local setting (never sent): all recent sessions, or only the picked
    /// ones. Applies to the next publish; already-published chunks stay.
    func setTranscriptMode(_ mode: TeamTranscriptChoices.Mode) async {
        await action("Saving…") { paths, _ in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var choices = TeamTranscriptChoices.load(teamDir: dir)
            choices.mode = mode
            try choices.save(teamDir: dir)
        }
    }

    func setTranscript(_ id: String, shared: Bool) async {
        await action("Saving…") { paths, _ in
            guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(team)
            var choices = TeamTranscriptChoices.load(teamDir: dir)
            if shared { choices.chosen.insert(id) } else { choices.chosen.remove(id) }
            try choices.save(teamDir: dir)
        }
    }
```

- [ ] **Step 7: The pane.** In `sharingSection`, between the kinds `ForEach` (ends line 306) and the caption (line 307):

```swift
            if team.shares.target(for: TeamKinds.transcripts) != .off {
                Picker("Which sessions", selection: Binding(
                    get: { team.transcriptChoices.mode },
                    set: { mode in Task { await team.setTranscriptMode(mode) } })) {
                    Text("All recent sessions").tag(TeamTranscriptChoices.Mode.all)
                    Text("Only the ones I pick").tag(TeamTranscriptChoices.Mode.chosen)
                }
                if team.transcriptChoices.mode == .chosen {
                    if team.recentTranscripts.isEmpty {
                        Text("No sessions in the transcript window yet — they appear after the next publish.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(team.recentTranscripts) { session in
                        Toggle(isOn: Binding(get: { team.transcriptChoices.chosen.contains(session.id) },
                                             set: { on in Task { await team.setTranscript(session.id, shared: on) } })) {
                            Text("\(session.project) · \(session.lastDay)")
                        }
                        .controlSize(.small)
                    }
                }
            }
```

- [ ] **Step 8: Run** `swift test --filter "TeamTranscriptChoicesTests|TeamPublisherTests"` → PASS. `swift build --product Infinitus` → succeeds.

- [ ] **Step 9: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamTranscriptChoices.swift Sources/InfinitusCore/Team/TeamPublisher.swift \
        Sources/Infinitus/TeamModel.swift Sources/Infinitus/TeamPane.swift \
        Tests/InfinitusCoreTests/TeamTranscriptChoicesTests.swift Tests/InfinitusCoreTests/TeamPublisherTests.swift
git commit -m "team: pick which recent sessions' transcripts are published

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Cap the `published/` plaintext copies

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift` (`Sources.copiesCapBytes`, `Report.prunedCopies`, `pruneCopies`, end of `publish`)
- Modify: `Sources/Infinitus/TeamPane.swift` (`sharingSection` caption, line 307)
- Test: `Tests/InfinitusCoreTests/TeamPublisherTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift`, `InfinitusApp.swift`, `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**Interfaces:**
- Produces:

```swift
extension TeamPublisher.Sources { public var copiesCapBytes: Int }   // default 1 << 30
extension TeamPublisher.Report { public var prunedCopies: Int }      // default 0
extension TeamPublisher { @discardableResult func pruneCopies(cap: Int) -> Int }
```

- [ ] **Step 1: Failing test** (append to `TeamPublisherTests`):

```swift
    /// `published/` is the only part of a team dir that grows without
    /// bound (a month of transcripts was 9 GB): the oldest transcript
    /// copies go, and only those.
    func testPublishedCopiesArePrunedOldestTranscriptFirst() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        _ = try publisher.publish(sources: s)
        let copies = publisher.copiesDir
        let s1 = copies.appendingPathComponent("transcripts/s1/1.jsonl")
        let agent = copies.appendingPathComponent("transcripts/s1/subagents/agent-a1/1.jsonl")
        let s2 = copies.appendingPathComponent("transcripts/s2/1.jsonl")
        let day = copies.appendingPathComponent("days/2026-09-04.json")
        for url in [s1, agent, s2, day] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
        for (url, at) in [(s1, 1_000.0), (agent, 2_000.0), (s2, 3_000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: url.path)
        }

        s.copiesCapBytes = 1   // everything is over the cap
        let report = try publisher.publish(sources: s)
        XCTAssertEqual(report.prunedCopies, 3)
        for url in [s1, agent, s2] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: day.path), "stats copies stay — reshare needs them")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("sessions/index.json").path))
        // A cap nothing exceeds prunes nothing, and the pass still reports it.
        s.copiesCapBytes = 1 << 30
        XCTAssertEqual(try publisher.publish(sources: s).prunedCopies, 0)
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamPublisherTests/testPublishedCopiesArePruned` → compile FAIL.

- [ ] **Step 3: Implement.** In `Sources`, after `batchBytes` (line 118):

```swift
        /// Plaintext copies under `published/` (what `reshare` re-wraps)
        /// are the one part of a team dir that grows without bound — a
        /// month of one Mac's transcripts was 9 GB. Above this the oldest
        /// transcript copies go; a later re-share covers what is left.
        public var copiesCapBytes = 1 << 30
```

In `Report`, after `skipped` (line 127):

```swift
        /// Plaintext copies deleted to stay under `Sources.copiesCapBytes`.
        public var prunedCopies = 0
```

After `writeCopy` (line 179):

```swift
    /// Trims `published/` back under `cap`, oldest first, TRANSCRIPT
    /// copies only: the day, session, now and crash copies are kilobytes
    /// and `reshare` needs every one of them. Returns how many went.
    @discardableResult
    func pruneCopies(cap: Int) -> Int {
        let fm = FileManager.default
        guard let subpaths = try? fm.subpathsOfDirectory(atPath: copiesDir.path) else { return 0 }
        var total = 0
        var candidates: [(url: URL, size: Int, at: Date)] = []
        for path in subpaths {
            let url = copiesDir.appendingPathComponent(path)
            // `attributesOfItem`, not `resourceValues(forKeys: [.fileSizeKey…])`:
            // InfinitusCore's tests run on Linux too, and corelibs-foundation
            // implements only a subset of the URL resource keys.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            total += size
            if path.hasPrefix("transcripts/") {
                candidates.append((url, size, (attrs[.modificationDate] as? Date) ?? .distantPast))
            }
        }
        guard total > cap else { return 0 }
        var pruned = 0
        // Over the finite candidate list, not `while total > cap`: a cap
        // below what the non-transcript copies weigh must still terminate.
        for file in candidates.sorted(by: { $0.at == $1.at ? $0.url.path < $1.url.path : $0.at < $1.at }) {
            guard total > cap else { break }
            guard (try? fm.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            pruned += 1
        }
        return pruned
    }
```

At the end of `publish`, after `try flush()` / `try state.save(teamDir: teamDir)` (lines 264–265) and before `return report`:

```swift
        report.prunedCopies = pruneCopies(cap: sources.copiesCapBytes)
```

- [ ] **Step 4: The caption.** In `Sources/Infinitus/TeamPane.swift`, replace line 307's text with:

```swift
            Text("Applies from the next publish. Re-share re-wraps the last 30 days of stats and sessions, and the transcripts still on this Mac (the local copies are capped at 1 GB).")
                .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 5: Run** `swift test --filter TeamPublisherTests` → PASS. `swift build --product Infinitus` → succeeds.

- [ ] **Step 6: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamPublisher.swift Sources/Infinitus/TeamPane.swift \
        Tests/InfinitusCoreTests/TeamPublisherTests.swift
git commit -m "team: cap the plaintext publish copies at 1 GB, oldest transcripts first

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Publish progress + cooperative stop

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift` (`Progress`, `Sources.onProgress`/`shouldStop`, `Report.stopped`, `publish`)
- Modify: `Sources/Infinitus/TeamModel.swift` (`progress`, `stopRequested`, `loop`, `quit`, `quitBound`)
- Modify: `Sources/Infinitus/TeamPane.swift` (the busy overlay, lines 30–35, + one helper)
- Modify: `Sources/Infinitus/AppModel.swift` — ONLY the `(5s)` inside the comment on line 1936
- Test: `Tests/InfinitusCoreTests/TeamPublisherTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift`, `InfinitusApp.swift` (its `quitBound` comment names no number — leave it), `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**Interfaces:**
- Produces:

```swift
extension TeamPublisher {
    public struct Progress: Equatable, Sendable {
        public var phase: String   // "scan" | "push"
        public var done: Int       // transcript sources chunked so far
        public var total: Int      // transcript sources this pass will chunk
        public init(phase: String, done: Int, total: Int)
    }
}
extension TeamPublisher.Sources {
    public var onProgress: (@Sendable (TeamPublisher.Progress) -> Void)?
    public var shouldStop: (@Sendable () -> Bool)?
}
extension TeamPublisher.Report { public var stopped: Bool }
extension TeamModel { @Published private(set) var progress: TeamPublisher.Progress? }
```

**Two phases, not three.** `"seal"` is not observable: `TeamClient.publish` seals and pushes inside one call. `"scan"` fires after each transcript source is chunked (plus once at the start, so the UI shows the size immediately) and `"push"` fires after each batch reaches the remote — both carrying the same "sources done / sources total" counter, so the number only ever moves forward.

**What the stop does NOT promise.** `shouldStop` is checked once per source, before chunking it. A batch already inside `git push` finishes (or dies with the process) — the guarantee is only that the cursor state was saved behind the last completed batch, which is what makes a kill safe in the first place.

- [ ] **Step 1: Failing tests** (append to `TeamPublisherTests`):

```swift
    /// Progress is per SOURCE and per BATCH, never per chunk: a 9 GB
    /// corpus is thousands of chunks and every main-actor hop is a CA
    /// transaction (the pop-out must idle at ~0%).
    func testProgressFiresPerSourceAndPerBatchOnly() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        // `publish` is synchronous on this thread and so is the callback,
        // but the closure is @Sendable: a captured `var` will not compile.
        final class Box: @unchecked Sendable { var seen: [TeamPublisher.Progress] = [] }
        let box = Box()
        var s = sources(projects)
        s.batchBytes = 1        // one push per source — the most callbacks this can make
        s.onProgress = { box.seen.append($0) }
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        XCTAssertEqual(report.transcriptChunks, 3)
        XCTAssertFalse(report.stopped)
        XCTAssertLessThanOrEqual(box.seen.count, 3 + 3 + 1, "3 sources + 3 batches + the opening call")
        XCTAssertEqual(box.seen.first, TeamPublisher.Progress(phase: "scan", done: 0, total: 3))
        XCTAssertEqual(box.seen.last?.done, 3)
        XCTAssertEqual(Set(box.seen.map(\.phase)), ["scan", "push"])
        XCTAssertEqual(box.seen.map(\.total), Array(repeating: 3, count: box.seen.count))
        XCTAssertEqual(box.seen.map(\.done), box.seen.map(\.done).sorted(), "the counter only moves forward")
    }

    /// Quit asks the publisher to stop; what it had pushed stays pushed
    /// and the cursor is saved, so the next pass resumes.
    func testStopBetweenSourcesSavesTheCursorAndLeavesTheRestForNextTime() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        final class Box: @unchecked Sendable { var chunked = 0 }
        let box = Box()
        var s = sources(projects)
        s.batchBytes = 1
        s.onProgress = { if $0.phase == "scan" { box.chunked = $0.done } }
        s.shouldStop = { box.chunked >= 1 }      // stop once the first source is done
        let report = try publisher.publish(sources: s)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(report.transcriptChunks, 1)
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertTrue(report.published.contains(me + "transcripts/s1/1.jsonl"))
        XCTAssertFalse(report.published.contains { $0.contains("/s2/") })
        let state = TeamPublishState.load(teamDir: t.alicePaths.teamDir(t.alice.config.id))
        XCTAssertEqual(state.transcripts.count, 1)
        XCTAssertEqual(state.transcripts["s1"]?.seq, 1)
        _ = try t.leader.fetch()
        XCTAssertEqual(try t.leader.readable().map(\.path).filter { $0.contains("/transcripts/") },
                       [me + "transcripts/s1/1.jsonl"])
        // No stop: the rest goes out, nothing is re-chunked.
        var again = sources(projects)
        again.batchBytes = 1
        let second = try publisher.publish(sources: again)
        XCTAssertFalse(second.stopped)
        XCTAssertEqual(second.transcriptChunks, 2)
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamPublisherTests/testProgressFires` → compile FAIL.

- [ ] **Step 3: The publisher.** After the `Collected` struct (line 28) add:

```swift
    /// How far a publish has got, for a UI that must not tick. Fired once
    /// per transcript source chunked and once per batch pushed — never
    /// per chunk: a 9 GB corpus is thousands of chunks and each hop to the
    /// main actor commits a CA transaction. Sealing is not a phase of its
    /// own: `TeamClient.publish` seals and pushes in one call.
    public struct Progress: Equatable, Sendable {
        /// "scan" — a source was chunked; "push" — a batch reached the remote.
        public var phase: String
        /// Transcript sources chunked so far, of `total` this pass will chunk.
        public var done: Int
        public var total: Int
        public init(phase: String, done: Int, total: Int) { self.phase = phase; self.done = done; self.total = total }
    }
```

In `Sources`, after `copiesCapBytes`:

```swift
        /// Called on the publishing thread (never the main actor); the app
        /// hops once per call.
        public var onProgress: (@Sendable (TeamPublisher.Progress) -> Void)?
        /// Checked once per transcript source, before chunking it: true
        /// flushes what is staged, saves the cursor and returns the report
        /// with `stopped`. A batch already inside `git push` still
        /// finishes — the per-batch state save is what makes a kill safe.
        public var shouldStop: (@Sendable () -> Bool)?
```

In `Report`, after `prunedCopies`:

```swift
        /// True when `Sources.shouldStop` cut the pass short: what the
        /// report lists went out, the cursor is saved, the rest waits.
        public var stopped = false
```

In `publish`, immediately after the `toChunk` binding from Task 2 and still ABOVE `func flush()` — `note` reads `toChunk`, and `flush` calls `note`, so the order is `toChunk` → `chunked` → `note` → `flush`:

```swift
        var chunked = 0
        func note(_ phase: String) { sources.onProgress?(Progress(phase: phase, done: chunked, total: toChunk.count)) }
```

`flush()` reports its push — add as its last line (after `try state.save(teamDir: teamDir)`, line 209):

```swift
            note("push")
```

and the transcript loop becomes:

```swift
        note("scan")
        for source in toChunk {
            if sources.shouldStop?() == true {
                try flush()
                try state.save(teamDir: teamDir)
                report.stopped = true
                report.prunedCopies = pruneCopies(cap: sources.copiesCapBytes)
                return report
            }
            try drainingPool {
                …unchanged…
            }
            chunked += 1
            note("scan")
        }
```

(Order matters: `toChunk`, `chunked` and `note` are all declared above `func flush`, or `flush`'s call to `note` — and `note`'s read of `toChunk` — will not compile.)

- [ ] **Step 4: `TeamModel`.** Next to the other published state (after `lastReport`, line 27):

```swift
    /// The running publish's progress (spec §7), or nil when nothing is
    /// publishing. Set once per source and once per batch, never per chunk.
    @Published private(set) var progress: TeamPublisher.Progress?
```

Next to the private stored properties (after `lastPublishAt`, line 69):

```swift
    /// Set by `quit()`, read by the publisher between transcript sources.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
```

In `loop(sources:publish:)` (line 165), before the `do {`:

```swift
        var sources = sources
        let stop = stopRequested
        sources.onProgress = { [weak self] p in Task { @MainActor in self?.progress = p } }
        sources.shouldStop = { stop.withLock { $0 } }
        defer { progress = nil }
```

`quit()` (line 270) sets the flag before its own guard, and the bound grows:

```swift
    /// Spec §7: `now.json` is deleted on quit, so teammates stop seeing
    /// this Mac "on". Only when this run published (nothing else put a
    /// `now.json` there — deleting an absent path would push an empty
    /// commit). Bounded: the team queue is serial, so a loop pass mid-push
    /// could hold this for as long as git does; the stop flag lets that
    /// pass return between transcript sources, termination waits at most
    /// `quitBound` and the child dies with the app.
    static let quitBound: TimeInterval = 20
    func quit() async {
        // Before the guard: a first-ever publish is still in flight when
        // `lastPublishAt` is nil, and it must still see the flag.
        stopRequested.withLock { $0 = true }
        guard enabled, inTeam, lastPublishAt != nil else { return }
```

In `Sources/Infinitus/AppModel.swift` line 1936, change `TeamModel.quitBound (5s)` to `TeamModel.quitBound (20s)` — that literal only.

- [ ] **Step 5: The pane.** Replace the overlay (lines 30–35) with:

```swift
            .overlay(alignment: .top) {
                if let line = statusLine {
                    HStack { ProgressView().controlSize(.small); Text(line) }
                        .font(.caption).padding(6).background(.thinMaterial, in: Capsule()).padding(.top, 6)
                }
            }
```

and add next to the other helpers (before `kindTitle`, line 338):

```swift
    /// The busy label plus how far the publisher is through this Mac's
    /// transcript sources — "Publishing… pushing 3/12". The background
    /// loop sets no busy label, so a big publish shows progress alone
    /// (and never disables the form: `.disabled` stays on `busy`).
    private var statusLine: String? {
        let phase = team.progress.map { "\($0.phase == "push" ? "pushing" : "reading") \($0.done)/\($0.total)" }
        switch (team.busy, phase) {
        case let (busy?, phase?): return "\(busy) \(phase)"
        case let (busy?, nil): return busy
        case let (nil, phase?): return "Publishing… \(phase)"
        case (nil, nil): return nil
        }
    }
```

- [ ] **Step 6: Run** `swift test --filter TeamPublisherTests` → PASS. `swift build --product Infinitus` → succeeds.

- [ ] **Step 7: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamPublisher.swift Sources/Infinitus/TeamModel.swift \
        Sources/Infinitus/TeamPane.swift Sources/Infinitus/AppModel.swift \
        Tests/InfinitusCoreTests/TeamPublisherTests.swift
git commit -m "team: a publish shows its progress and a quit stops it between sources

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Per-call errors, a clean failed `create`, and the team-dir guard

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift` (`action`, `approve`, `decline`, `join`)
- Modify: `Sources/Infinitus/TeamMirrorHandler.swift` (the local `action` closure, lines 14–18)
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` (`create`)
- Test: `Tests/InfinitusCoreTests/TeamClientTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift` (line 611 calls `team.approve` — `@discardableResult` keeps it compiling untouched), `InfinitusApp.swift`, `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `TeamPaths.swift` (see Step 5), `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**No app test target exists.** `Package.swift` declares exactly one test target, `InfinitusCoreTests`; `Tests/InfinitusCoreTests/TeamMirrorTests.swift` covers the core `TeamMirror` paths/replies only and cannot reach `TeamModel` or `TeamMirrorHandler` (they live in the macOS-only `Infinitus` target). Do NOT add a test target for this task. The mirror change is gated by `swift build --product Infinitus` plus the type change that forces it: once `action`'s closure parameter is `() async -> String?`, a handler that ignored the value would not compile against `ActionReply(ok:error:)` as written.

**Interfaces:**
- Produces:

```swift
extension TeamModel {
    @discardableResult private func action(_ label: String, _ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> Void) async -> String?
    @discardableResult func approve(kid: String) async -> String?
    @discardableResult func decline(kid: String) async -> String?
    @discardableResult func join(code: String, name: String) async -> String?
}
```

- [ ] **Step 1: Failing test** (append to `Tests/InfinitusCoreTests/TeamClientTests.swift`):

```swift
    /// A create that dies on the remote used to leave `<base>/<id>/store/`
    /// behind — a config-less directory `teamIDs()` ignores but the user's
    /// disk keeps (one was still on the 2026-09-06 machine).
    func testAFailedCreateLeavesNoHalfMadeTeamBehind() throws {
        let (paths, secrets) = machine("solo")
        XCTAssertThrowsError(try TeamClient.create(name: "Papaya", remote: "file:///nonexistent/nope.git", token: "t0ken",
                                                   paths: paths, secrets: secrets, now: 1_000))
        XCTAssertEqual(paths.teamIDs(), [])
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: paths.base.path)) ?? []).filter { $0 != "secrets" }
        XCTAssertEqual(left, [], "no team directory survives a failed create")
        // The identity is this machine's, not the team's: it stays.
        XCTAssertEqual(secrets.read(TeamClient.identitySecretName)?.count, 32)
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamClientTests/testAFailedCreate` → FAIL (a `store/` dir is left behind).

- [ ] **Step 3: `TeamClient.create`.** Replace lines 85–102 with:

```swift
    public static func create(name: String, remote: String, token: String?, leaderName: String = "Leader",
                              paths: TeamPaths, secrets: TeamSecrets,
                              now: Int = Int(Date().timeIntervalSince1970)) throws -> TeamClient {
        let me = try identity(paths: paths, secrets: secrets)
        let id = UUID().uuidString.lowercased()
        var created = false
        // A create that dies at `store.open()` (a URL that resolves to
        // nothing, no network, a token the remote refuses) would otherwise
        // leave `<base>/<id>/store/` behind: no config, so `teamIDs()`
        // never lists it, and nothing ever cleans it up. The identity is
        // this machine's and stays; the store token was this team's and goes.
        defer {
            if !created {
                try? FileManager.default.removeItem(at: paths.teamDir(id))
                secrets.delete(tokenName(id))
            }
        }
        let config = TeamConfig(id: id, name: name, remote: remote, kid: me.kid, joinedAt: now, leaderKid: me.kid)
        if let token { try secrets.write(tokenName(id), Data(token.utf8)) }
        let store = TeamGit(dir: paths.storeDir(id), remote: remote, token: token, author: me.kid)
        try store.open()
        let roster = TeamRoster(id: id, name: name, createdAt: now,
                                leaders: [TeamRoster.Member(keys: me.keys, name: leaderName, since: now, founder: true)],
                                rev: 1)
        let signed = try Signed.make(roster, by: me)
        try store.put("roster/team.json", try CanonicalJSON.encode(signed))
        let client = TeamClient(config: config, identity: me, roster: signed, paths: paths, secrets: secrets, store: store)
        try client.persist()
        created = true
        return client
    }
```

- [ ] **Step 4: `TeamModel.action` returns this call's error.** Replace lines 473–485 with:

```swift
    /// Wraps a user action: busy label, error capture, reload. Returns
    /// THIS call's error, nil when it worked — `lastError` may already
    /// hold an older one when the call starts, and the reload afterwards
    /// can put a different one there, so a caller answering one request
    /// (the phone's `ActionReply`) must use the return value.
    @discardableResult
    private func action(_ label: String, _ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> Void) async -> String? {
        guard enabled else { lastError = "team is disabled in this instance"; return lastError }
        busy = label
        defer { busy = nil }
        var failure: String?
        do {
            try await run(work)
            lastError = nil
        } catch {
            failure = Self.mask(error)
            lastError = failure
        }
        await load().value
        return failure
    }
```

`approve` (line 564), `decline` (573) and `join` (524) pass it on — nothing else changes in them:

```swift
    @discardableResult
    func approve(kid: String) async -> String? {
        guard gated() else { return lastError }
        return await action("Approving…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.approve(kid: kid)
        }
    }

    @discardableResult
    func decline(kid: String) async -> String? {
        await action("Declining…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.decline(kid: kid)
        }
    }

    @discardableResult
    func join(code: String, name: String) async -> String? {
        guard gated() else { return lastError }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Host.current().localizedName ?? "Mac"
        let failure = await action("Requesting to join…") { paths, secrets in
            _ = try TeamClient.request(code: code, name: name, devices: [device], platform: "macos", paths: paths, secrets: secrets)
        }
        pendingCode = nil
        return failure
    }
```

Everything else that calls `action` (`setPolicy`, `publishAggregatesNow`, `setShare`, `setExcluded`, `reshare`, `leave`, the identity actions, and the other stream's `requestNearby` / `pullNearbyRequest` at lines 332–376) keeps compiling untouched — that is what `@discardableResult` is for. Do not edit those lines.

- [ ] **Step 5: The mirror handler.** In `Sources/Infinitus/TeamMirrorHandler.swift`, replace lines 14–18 with:

```swift
        func action(_ body: () async -> String?) async -> Data? {
            team.clearError()
            // The call's OWN error: `team.lastError` can hold an older
            // failure, or a reload's, and the phone would show that instead.
            let failure = await body()
            return json(TeamMirror.ActionReply(ok: failure == nil, error: failure))
        }
```

The three `case` bodies (lines 30–38) are unchanged. Also update the type's doc comment (lines 4–8): replace "a failure comes back as `ActionReply(ok: false, error:)` from `lastError`" with "a failure comes back as `ActionReply(ok: false, error:)` carrying the error of the call that just ran". Leave the `codePath` case alone — `mintCode` / `mintInvite` belong to the other stream this round.

- [ ] **Step 6: The team-dir guard — verify, don't rewrite.** `TeamPaths.teamIDs()` (TeamPaths.swift:34–37) ALREADY filters on `config.json`:

```swift
        return names.filter { FileManager.default.fileExists(atPath: configFile($0).path) }.sorted()
```

and `Tests/InfinitusCoreTests/TeamSecretsTests.swift:39–46` already asserts a config-less sibling directory is not listed. So the leftover `f5b28433-…` dir on the user's Mac is already invisible to `teamID` — `sorted().first` (TeamModel.swift:103) is not surviving "by luck", the filter is doing its job. Run `swift test --filter TeamSecretsTests` to confirm it still holds, change nothing in `TeamPaths.swift`, and note it in the task report. Step 3 is what stops new ones from appearing.

- [ ] **Step 7: Run** `swift test --filter "TeamClientTests|TeamSecretsTests"` → PASS. `swift build --product Infinitus` → succeeds. Manual read-back: `TeamMirrorHandler`'s three action cases now read the closure's value; confirm no `team.lastError` remains inside `func action`.

- [ ] **Step 8: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamClient.swift Sources/Infinitus/TeamModel.swift \
        Sources/Infinitus/TeamMirrorHandler.swift Tests/InfinitusCoreTests/TeamClientTests.swift
git commit -m "team: the phone gets the error of the call it made, and a failed create leaves nothing behind

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `TeamGit` drains both pipes at once

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamGit.swift` (`runOnce`, + `drain`)
- Test: `Tests/InfinitusCoreTests/TeamGitTests.swift`
- Do not touch: `ios/`, `TeamNearby.swift`, `NearbyRecord.swift`, `TeamMirror.swift`, `TeamInvites.swift`, `TeamCode.swift`, `TeamNearbyCommand.swift`, `main.swift`, `MirrorServer.swift`, `TeamMirrorNearby.swift`, `ControlServer.swift`, `InfinitusApp.swift`, `TeamRosterTests.swift`, `TeamSettingsTests.swift`, `TeamNearbyTests.swift`, `TeamMirrorTests.swift`, `site/`, `README.md`, TeamModel lines 317–376 and 534–562, TeamPane's two Nearby sections and `inviteSection`.

**Interfaces:**
- Produces:

```swift
extension TeamGit { static func drain(out: FileHandle, err: FileHandle) -> (out: Data, err: Data) }  // internal, @testable
```

`run` stays private; `drain` is internal so the test can drive it with any process. Same return shape and error text from `runOnce` — only the reading changes.

- [ ] **Step 1: Failing test** (append to `TeamGitTests`):

```swift
    /// Reading stdout to the end first deadlocks as soon as the child
    /// fills its 64 KB stderr pipe — git push writes its progress there
    /// while we block, and neither side ever moves again.
    func testDrainReadsBothPipesAtOnce() throws {
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo ok"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return XCTFail("\(error)") }
            let (stdout, stderr) = TeamGit.drain(out: out.fileHandleForReading, err: err.fileHandleForReading)
            p.waitUntilExit()
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "ok\n")
            XCTAssertEqual(stderr.count, 200_000, "the whole chatty stderr, not one pipe buffer's worth")
            XCTAssertEqual(p.terminationStatus, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
```

- [ ] **Step 2: Run** `swift test --filter TeamGitTests/testDrainReadsBothPipesAtOnce` → compile FAIL (`drain` does not exist).

- [ ] **Step 3: Implement.** In `Sources/InfinitusCore/Team/TeamGit.swift`, next to `runOnce` (before it, after `run`, line 202) and OUTSIDE the `#if os(iOS)…` fence — `FileHandle` and `DispatchGroup` exist on every platform:

```swift
    /// The stderr reader's landing pad; `drain` joins the group before
    /// anyone reads it, so there is nothing to synchronise past that.
    private final class Buffer: @unchecked Sendable { var data = Data() }

    /// stdout and stderr read at the SAME time. Sequentially, a child
    /// that fills the other pipe's 64 KB buffer first never exits: `git
    /// push` writes progress to stderr while we block on stdout, and the
    /// publish hangs (2026-09-06). Same bytes, same order, no timeout.
    static func drain(out: FileHandle, err: FileHandle) -> (out: Data, err: Data) {
        let buffer = Buffer()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { buffer.data = err.readDataToEndOfFile() }
        let stdout = out.readDataToEndOfFile()
        group.wait()
        return (stdout, buffer.data)
    }
```

and in `runOnce`, replace lines 238–240 with:

```swift
        // Both pipes at once (see `drain`), then wait: either one filling
        // up while we read the other would hang the publish.
        let (data, errData) = Self.drain(out: out.fileHandleForReading, err: err.fileHandleForReading)
        p.waitUntilExit()
```

Nothing else in `runOnce` changes — the `guard p.terminationStatus == 0` block and its `GitError.failed(command:status:stderr:)` stay exactly as they are.

- [ ] **Step 4: Run** `swift test --filter TeamGitTests` → PASS (the whole suite, so the real git paths are exercised through the new drain).

- [ ] **Step 5: Commit.**

```sh
git add Sources/InfinitusCore/Team/TeamGit.swift Tests/InfinitusCoreTests/TeamGitTests.swift
git commit -m "team: git's stdout and stderr are drained together, so a chatty push can't hang

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: CHANGELOG and the full gate (last task)

**Files:**
- Modify: `CHANGELOG.md` (under `## 0.4.4 (unreleased)` → `### Team (preview)`, line 45)
- Do not touch: everything in the forbidden list above, `site/`, `README.md`.

- [ ] **Step 1: The lines.** Insert at the TOP of the `### Team (preview)` list (right after line 45, before the existing "Reading the team store remembers…" line), one short sentence each. No `Team:` prefix — the section is already named, and none of the twelve lines under it carries one:

```
- Share a kind with Nobody and it never leaves this Mac (`infinitusctl team share transcripts off`).
- Pick which recent sessions' transcripts are shared.
- A publish shows its progress in Settings › Team, and quitting stops it after the current batch.
- The plaintext copies of what you published are capped at 1 GB, oldest transcripts first.
- A failed team create leaves no half-made team behind.
- A git push with chatty progress output no longer hangs the publish.
```

- [ ] **Step 2: The full gate**, in this order, each from the worktree root:

```sh
swift test
swift build --product Infinitus
swift build --product infinitusctl
```

All three must succeed. (`swift build` takes ONE `--product` per invocation — with two flags SwiftPM builds only the last.) `tools/e2e.sh` is the orchestrator's at integration; this stream only edited its team section.

- [ ] **Step 3: Commit.**

```sh
git add CHANGELOG.md
git commit -m "changelog: team sharing controls and publisher robustness (0.4.4)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Coverage:** "Nobody" end to end — model, store hint, publisher, re-share, CLI, pane, e2e (T1); per-session transcripts with the picker fed off the scan cache (T2); the copies cap (T3); progress + cooperative stop with the quit bound raised to 20 s (T4); per-call errors, a clean failed create, the already-present dir guard verified (T5); the pipe-drain hang (T6); notes and gates (T7).
- **Type consistency:** `ShareTarget.off` is written the same way in `TeamRoster`, `TeamShares.parseTarget`, `TeamPublisher` (`off(_:)`), `TeamClient.publish` and `TeamPane.audienceTag`/`audience(from:)`. `TeamTranscriptChoices.includes(_:)` is keyed on `TranscriptSource.session` in the publisher, in `reshare` (first path component after `transcripts/`) and in the pane (`TranscriptSession.id`). `TeamPublisher.Progress` has one shape across publisher, model and pane.
- **Perf rule:** the only new UI-driving callbacks are per-source and per-batch; nothing added ticks, and `statusLine` is derived, not animated.
- **Ownership:** no edit outside the OWNS list; the TeamModel nearby block (317–376) and mint block (534–562) and both TeamPane Nearby sections are untouched, and every new `action` caller keeps compiling through `@discardableResult` so the other stream's lines need no edit.
