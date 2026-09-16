# Team Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Team back into the unified Infinitus app: the crypto core and store as they were, the surfaces and transports re-homed on threads, one control-socket API, a web pane, a phone screen, and delegated control last.

**Architecture:** Each slice is one PR against `main`. Slice 1 restores `InfinitusCore/Team` from `4947e663df` (the parent of removal #1061) minus what depended on retired code; slice 2 restores reader/publisher/insights re-typed on desktop-server threads and puts every action behind a `team-*` verb; slices 3–5 are the web pane, the links and the phone; slice 6 is delegated control.

**Tech Stack:** Swift 6 (`apps/mac`, SwiftPM, swift-crypto, system zlib via `CZlib`), TypeScript (Effect Schema contracts, React web, React Native phone).

**Spec:** `apps/mac/docs/superpowers/specs/2026-09-15-team-rebuild-design.md`

## Global Constraints

- PR-only `main`: `gh pr create --base main` then `gh pr merge --squash --auto`. Before arming: `git fetch origin main && git merge-base --is-ancestor origin/main HEAD || echo STALE`.
- Every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Each PR adds `apps/mac/changelog.d/<slug>.md` holding one line `Surface: sentence` (Surface ∈ Mac/Desktop/Phone/Linux).
- Restore old code with `git checkout 4947e663df -- <path>` (web/desktop files: `git checkout d587749289^ -- <path>`). Never paste listings from the old plan files under `apps/mac/docs/superpowers/plans/2026-09-0*` (#55: they carry pre-fix code).
- No `git stash` in this repo. No repo-wide checks (`vp check`, `vp run -r test`); run only the targeted tests named in each task.
- Secrets travel on the request line's `secret` field (stdin for the CLI), never argv; never logged.
- Bundle id `run.infinitus` never changes. Dev instances need `INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock` and `INFINITUS_APP_SUPPORT`. Never `pkill -f`; kill only PIDs captured at spawn.
- Swift builds: one `--product` per `swift build`; the Mac app is `Infinitus`, the CLI `infinitusctl`.
- Spec §5.4 (as amended 2026-09-16): the lock never touches Team; no verb checks it.

---

## Slice 0 (this PR): spec + plan

Files: the spec, this plan, `apps/mac/changelog.d/team-rebuild-plan.md` (`Mac: Team rebuild spec and plan (#1313).`). No code. After the PR is open, comment both paths on #1313.

---

## Slice 1: crypto core, store, client, CLI (PR "feat(mac): restore the Team crypto core and store")

### Task 1.1: `CZlib` target and the pure core files

**Files:**
- Modify: `apps/mac/Package.swift` (the `targets` array head)
- Restore: `apps/mac/Sources/CZlib/module.modulemap`, `apps/mac/Sources/CZlib/shim.h`, `apps/mac/Sources/InfinitusCore/ASCIIScan.swift` (`TeamRedaction` calls `ASCIIScan.lowered`; the helper left with #1155, not #1061 — review note on #1313) and `apps/mac/Tests/InfinitusCoreTests/SkipPOSIX.swift` (`skipOffPOSIX()`, which `TeamMembershipTests` calls; gone the same way)
- Restore under `apps/mac/Sources/InfinitusCore/Team/`: `Base32.swift`, `CanonicalJSON.swift`, `Deflate.swift`, `DrainingPool.swift`, `Envelope.swift`, `PBKDF2.swift`, `RecoveryKey.swift`, `Signed.swift`, `TeamIdentity.swift`, `TeamIdentityExport.swift`, `TeamSecrets.swift`, `TeamPaths.swift`, `TeamCode.swift`, `TeamRequest.swift`, `TeamRoster.swift`, `TeamKinds.swift`, `TeamStore.swift`, `TeamChunker.swift`, `TeamRedaction.swift`, `TeamPublishState.swift`, `TeamShares.swift`, `TeamTranscriptChoices.swift`, `TeamExclusions.swift`, `TeamFleetDoc.swift`, `TeamDocs.swift`
- Restore tests under `apps/mac/Tests/InfinitusCoreTests/`: `PBKDF2Tests.swift`, `RecoveryKeyTests.swift`, `TeamChunkerTests.swift`, `TeamDeflateTests.swift`, `TeamEnvelopeTests.swift`, `TeamIdentityTests.swift`, `TeamIdentityExportTests.swift`, `TeamRosterTests.swift`, `TeamSecretsTests.swift`, `TeamSettingsTests.swift`, `TeamSharesTests.swift`, `TeamTranscriptChoicesTests.swift`, `TeamRedactionTests.swift`, `TeamFleetDocTests.swift` (its `TeamSnapshot`/`TeamReader`/`TeamInsights` cases cut; they return in Task 2.2)

**Interfaces:**
- Produces: `Envelope.seal/open`, `Signed<T>`, `TeamIdentity(secret:)`, `TeamRoster`, `TeamKinds.check/expected/storePath`, `TeamDocs.{DayDoc, Window, Fleet, LiveSession, Now, SessionRow, SessionsIndex, Crashes, Aggregates, FleetDoc}` unchanged except `Now` (below).

- [ ] **Step 1: Restore the files**

```bash
cd apps/mac
git checkout 4947e663df -- Sources/CZlib Sources/InfinitusCore/ASCIIScan.swift Tests/InfinitusCoreTests/SkipPOSIX.swift
for f in Base32 CanonicalJSON Deflate DrainingPool Envelope PBKDF2 RecoveryKey Signed TeamIdentity TeamIdentityExport TeamSecrets TeamPaths TeamCode TeamRequest TeamRoster TeamKinds TeamStore TeamChunker TeamRedaction TeamPublishState TeamShares TeamTranscriptChoices TeamExclusions TeamFleetDoc TeamDocs; do
  git checkout 4947e663df -- "Sources/InfinitusCore/Team/$f.swift"
done
for t in PBKDF2Tests RecoveryKeyTests TeamChunkerTests TeamDeflateTests TeamEnvelopeTests TeamIdentityTests TeamIdentityExportTests TeamRosterTests TeamSecretsTests TeamSettingsTests TeamSharesTests TeamTranscriptChoicesTests TeamRedactionTests TeamFleetDocTests; do
  git checkout 4947e663df -- "Tests/InfinitusCoreTests/$t.swift"
done
```

- [ ] **Step 2: Add the `CZlib` target to `Package.swift`**

Insert as the first element of `targets` and add `"CZlib"` to `InfinitusCore`'s dependencies:

```swift
    // System zlib: the team envelope deflates plaintext before sealing
    // (docs/superpowers/specs/2026-09-05-team-design.md §3). Same bytes
    // on macOS, Linux and iOS; the Apple SDK and the swift docker image
    // both ship zlib.
    .systemLibrary(name: "CZlib", path: "Sources/CZlib", pkgConfig: "zlib",
                   providers: [.apt(["zlib1g-dev"])]),
    .target(name: "InfinitusCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto"), "CZlib"],
            path: "Sources/InfinitusCore"),
```

- [ ] **Step 3: Trim `TeamDocs.Now` and `TeamKinds` of the control symbols**

In `TeamDocs.swift` delete the `GrantHint` struct and, in `Now`, the two lines `public var endpoints: TeamControl.Endpoints?` and `public var grantsTo: [GrantHint]?` together with their doc comment. In `TeamKinds.swift` delete `command`, `ack`, `hostname`, `controlKinds` and their comment (they return in slice 6). Leave `sessions` in place (slice 2 renames it).

- [ ] **Step 4: Build the core and run the restored tests**

```bash
cd apps/mac && swift build --product InfinitusCore 2>&1 | tail -20
swift test --parallel --filter 'PBKDF2Tests|RecoveryKeyTests|TeamChunkerTests|TeamDeflateTests|TeamEnvelopeTests|TeamIdentityTests|TeamIdentityExportTests|TeamRosterTests|TeamSecretsTests|TeamSettingsTests|TeamSharesTests|TeamTranscriptChoicesTests|TeamRedactionTests|TeamFleetDocTests' 2>&1 | tail -15
```
Expected: build succeeds; every listed suite passes. A compile error naming a removed symbol (`TeamControl`, `MirrorSnapshot`, `ClaudeSessions`, `SessionInput`; `ASCIIScan` and `skipOffPOSIX` mean Step 1 missed the two helper files) means a file from the "not restored" list slipped in or a doc field was missed in Step 3: fix that, never add a shim.

- [ ] **Step 5: Commit**

```bash
git add apps/mac/Package.swift apps/mac/Sources/CZlib apps/mac/Sources/InfinitusCore/Team apps/mac/Tests/InfinitusCoreTests
git commit -m "feat(mac): restore the Team crypto core, documents and their tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 1.2: `TeamGit`, `TeamClient`, `TeamInvites` and their tests

**Files:**
- Restore: `Sources/InfinitusCore/Team/TeamGit.swift`, `TeamClient.swift`, `TeamInvites.swift`
- Restore tests: `TeamGitTests.swift`, `TeamClientTests.swift`, `TeamInvitesTests.swift`, `TeamMembershipTests.swift`

**Interfaces:**
- Produces: `TeamClient.create(name:remote:token:leaderName:paths:secrets:)`, `TeamClient.request(code:name:devices:platform:paths:secrets:)`, `TeamClient.open(id:paths:secrets:)`, `.fetch()`, `.status() -> TeamStatus`, `.code(expiresIn:)`, `.approve(kid:)`, `.decline(kid:)`, `.remove(kid:)`, `.promote(kid:)`, `.leave(rotateIdentity:)`, `.setPolicy(_:)`, `.publish(_ items: [PublishItem])`, `.readableHeaders()`, `.read(_:)`, `TeamInvites.mint/consume`.

- [ ] **Step 1: Restore**

```bash
cd apps/mac
for f in TeamGit TeamClient TeamInvites; do git checkout 4947e663df -- "Sources/InfinitusCore/Team/$f.swift"; done
for t in TeamGitTests TeamClientTests TeamInvitesTests TeamMembershipTests; do git checkout 4947e663df -- "Tests/InfinitusCoreTests/$t.swift"; done
```

- [ ] **Step 2: Cut the reader cases from `TeamClientTests` and the Nearby case from `TeamInvitesTests`**

In `TeamClientTests.swift` delete the two test functions that call `TeamReader.scan` (around old lines 205–250). In `TeamInvitesTests.swift` delete the function that references `TeamNearby`. Leave a one-line comment at the top of each: `// The reader scan cases return with TeamReader (team rebuild slice 2).`

- [ ] **Step 3: Build and test**

```bash
cd apps/mac && swift build --product InfinitusCore 2>&1 | tail -5
swift test --parallel --filter 'TeamGitTests|TeamClientTests|TeamInvitesTests|TeamMembershipTests' 2>&1 | tail -15
```
Expected: PASS. `TeamGitTests` spawns git against file-backed bare repos under a temp dir; it is the slow suite (≈ 1–2 min).

- [ ] **Step 4: Commit**

```bash
git add apps/mac/Sources/InfinitusCore/Team apps/mac/Tests/InfinitusCoreTests
git commit -m "feat(mac): restore TeamGit, TeamClient and TeamInvites with their tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 1.3: `infinitusctl team …` in-process CLI

**Files:**
- Restore: `apps/mac/Sources/InfinitusCLI/TeamCommand.swift`
- Modify: `apps/mac/Sources/InfinitusCLI/main.swift` (early dispatch, usage line, `flagOnly`, stdin list)

**Interfaces:**
- Produces: `runTeam(_ args: [String]) -> Int32` with subcommands `create`, `code`, `request`, `status`, `requests`, `approve`, `decline`, `remove`, `promote`, `fetch`, `share`, `exclude`, `leave`, `identity`, `policy`, `put`, `list`, `read`. `publish`, `members`, `member`, `insights`, `aggregates`, `reshare` return in Task 2.4.

- [ ] **Step 1: Restore and cut**

```bash
cd apps/mac && git checkout 4947e663df -- Sources/InfinitusCLI/TeamCommand.swift
```
Then in `TeamCommand.swift`: delete the two lines `if let code = runTeamNearby(args) …` and `if let code = runTeamControl(args) …`; delete the `case "publish"`, `"reshare"`, `"members"`, `"member"`, `"insights"`, `"aggregates"` branches whole; in `case "remove"` delete the `TeamHostnames.Ledger` block (keep `try c.remove(kid: kid)` and `emit(try c.status())`); in `teamUsage()` delete the lines for `grant`…`hostname list`, `send`, `approve <kid> <sessionId>`, `mode`, `drive`, `tail`, `acks`, `publish`, `reshare`, `members`, `member`, `insights`, `aggregates`; in `routeToApp` keep `status`, `fetch`, `code`, `approve`, `decline`, `create` and delete `publish`.

- [ ] **Step 2: Wire `main.swift`**

After the `runDesktopVerbs` block add:
```swift
// `team` runs in-process (TeamCommand.swift) and needs no app.
if args.first == "team" {
    exit(runTeam(Array(args.dropFirst())))
}
```
In `usage()` add before the `environments |` line:
```swift
    out += "  team <subcommand>      teams: create, code, request, approve, share… (`\(programName) team --help`)\n"
```
Change the `flagOnly` line to:
```swift
        let flagOnly = command == "team-create" ? ["yes", "local", "status"] : ["yes", "local", "remote", "status"]
```
Add `"team-create", "team-join"` to the stdin-piped command list, and to the usage line listing stdin verbs.

- [ ] **Step 3: Build the CLI and run a two-identity round by hand**

```bash
cd apps/mac && swift build --product infinitusctl 2>&1 | tail -3
CTL=.build/debug/infinitusctl; D=$(mktemp -d); git init -q --bare "$D/team.git"; git -C "$D/team.git" config uploadpack.allowFilter true
INFINITUS_TEAM_DIR="$D/ann" $CTL team create Papaya --remote "file://$D/team.git" --as Ann | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['role']=='leader'"
CODE=$(INFINITUS_TEAM_DIR="$D/ann" $CTL team code --days 1 | python3 -c "import json,sys; print(json.load(sys.stdin)['code'])")
printf '%s' "$CODE" | INFINITUS_TEAM_DIR="$D/bo" $CTL team request - --name Bo >/dev/null
KID=$(INFINITUS_TEAM_DIR="$D/bo" $CTL team status | python3 -c "import json,sys; print(json.load(sys.stdin)['kid'])")
INFINITUS_TEAM_DIR="$D/ann" $CTL team approve "$KID" | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(m['name']=='Bo' for m in d['members'])"
echo ok
```
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add apps/mac/Sources/InfinitusCLI
git commit -m "feat(mac): infinitusctl team runs the store in-process again

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 1.4: CI, fragment, PR

- [ ] **Step 1: CI** — `mac-linux` (`.github/workflows/ci.yml` ~line 494) builds on `swift:6.1`, which ships zlib; no change. Run `cd apps/mac && swift test --parallel 2>&1 | tail -5` once whole to see the wall time; if it exceeds 25 min, add a `mac-test-team` job as the old CI had (`--skip Team` on `mac-test`, `--filter Team` on the new job) and note the new check name in `apps/mac/CLAUDE.md`'s ruleset line.
- [ ] **Step 2: Fragment** — `apps/mac/changelog.d/team-crypto-core.md`: `Mac: the Team crypto core, store and infinitusctl team CLI are back (#1313).`
- [ ] **Step 3: PR** — `gh pr create --base main --draft`, then the STALE check, `gh pr ready`, `gh pr merge --squash --auto`.

---

## Slice 2: reader, publisher on threads, verbs, contracts, Mac loop (PR "feat(mac): Team verbs over threads")

### Task 2.1: Thread-shaped documents

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamDocs.swift`, `TeamKinds.swift`
- Test: `Tests/InfinitusCoreTests/TeamDocsTests.swift` (new)

**Interfaces:**
- Produces:
```swift
extension TeamDocs {
    /// One thread in `threads/index.json` (spec §4).
    public struct ThreadRow: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// Project directory basename, never the path.
        public var project: String
        public var status: String        // idle | starting | running | failed | archived
        public var createdAt: Int
        public var updatedAt: Int
        public var turns: Int
        public var usage: Usage?
        public struct Usage: Codable, Equatable, Sendable {
            public var inputTokens: Int; public var outputTokens: Int; public var costUsd: Double?; public var models: [String]
        }
    }
    public struct ThreadsIndex: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var threads: [ThreadRow]
        public var fleets: [Fleet]
    }
    /// `now.json`'s `live` rows: threads with a starting or running session.
    public struct LiveThread: Codable, Equatable, Sendable {
        public var id: String; public var title: String; public var project: String
        public var startedAt: Int?; public var activityLine: String?
    }
}
```
`TeamDocs.Now` becomes `at, machine, live: [LiveThread], fleets, blockers, crashesToday, sharesTo, desktop: Bool`. `TeamKinds.sessions` is renamed `threads` (`"threads"`), `memberKinds = [stats, now, threads, transcripts, crashes, fleet]`; `expected(at:)` maps `threads/index.json` to `threads` and no longer names `sessions`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class TeamDocsTests: XCTestCase {
    func testThreadsIndexPathIsAKind() {
        XCTAssertEqual(TeamKinds.expected(at: "m/abc/threads/index.json")?.kind, "threads")
        XCTAssertNil(TeamKinds.expected(at: "m/abc/sessions/index.json"))
    }
    func testNowRoundTripsLiveThreads() throws {
        let now = TeamDocs.Now(at: 1, machine: "mac", live: [.init(id: "t1", title: "Fix", project: "repo", startedAt: 1, activityLine: nil)],
                               fleets: [], blockers: [], crashesToday: 0, sharesTo: [:], desktop: true)
        let back = try CanonicalJSON.decode(TeamDocs.Now.self, from: try CanonicalJSON.encode(now))
        XCTAssertEqual(back, now)
    }
}
```

- [ ] **Step 2: Run it** — `swift test --filter TeamDocsTests` → FAIL (no `threads` kind, no `live`).
- [ ] **Step 3: Implement** the shapes above; delete `LiveSession`, `SessionRow`, `SessionsIndex`; update every `TeamDocs.Now(...)` call in tests.
- [ ] **Step 4: Run** `swift test --parallel --filter 'TeamDocsTests|TeamMembershipTests|TeamFleetDocTests|TeamClientTests'` → PASS.
- [ ] **Step 5: Commit** `feat(mac): Team documents describe threads, not sessions`.

### Task 2.2: `TeamReader`, `TeamInsights`, `TeamSnapshot` on the new rows

**Files:**
- Restore then edit: `Sources/InfinitusCore/Team/TeamReader.swift`, `TeamInsights.swift`, `TeamSnapshot.swift`
- Restore tests: `TeamReaderTests.swift`, `TeamInsightsTests.swift`, `TeamAggregatesTests.swift`, `TeamSnapshotTests.swift`, `TeamSnapshotControlsTests.swift` (cut), the reader cases back into `TeamClientTests.swift`, the cut cases back into `TeamFleetDocTests.swift`

**Interfaces:**
- Produces: `TeamReader.load(client:)`, `.scan(client:docs:scans:)`, `.summary(kid:period:)`, `.aggregates`; `TeamInsights.comparison/blockers/headroom/whoIsOn/aggregates`; `TeamSnapshot` with `Member.threadsNow` (was `sessionsNow`) and new top-level `policy: TeamRoster.Policy?`, `shares: [String: String]`, `exclusions: [String]`, `lockEnabled: Bool`; `Member.controls` and `Member.fleet` kept.

- [ ] **Step 1: Restore** the three sources and the tests; delete `TeamSnapshotControlsTests.swift` (controls return in slice 6); in `TeamReader.swift` delete the `acks` field and the `TeamControl.Ack` decode line; in `TeamReader.Member` rename `sessions: [TeamDocs.SessionRow]` to `threads: [TeamDocs.ThreadRow]`; in `TeamInsights` read `now.live` where it read `now.sessions`, `m.threads` where it read `m.sessions`, and the `waiting` count from `status == "waiting"` on `LiveThread` → from `activityLine?.hasPrefix("Waiting")`; in `TeamSnapshot` rename `sessionsNow` → `threadsNow` and add the four fields with defaults.
- [ ] **Step 2: Build and run** `swift test --parallel --filter 'TeamReaderTests|TeamInsightsTests|TeamAggregatesTests|TeamSnapshotTests|TeamClientTests|TeamFleetDocTests'` → PASS after the fixture rows are re-typed.
- [ ] **Step 3: Commit** `feat(mac): TeamReader, TeamInsights and TeamSnapshot read thread rows`.

### Task 2.3: `TeamPublisher` fed by the desktop server

**Files:**
- Restore then edit: `Sources/InfinitusCore/Team/TeamPublisher.swift`
- Create: `Sources/InfinitusCore/Team/TeamThreadSources.swift`
- Restore tests: `TeamPublisherTests.swift`, `TeamCollectTests.swift`; Create: `TeamThreadSourcesTests.swift`

**Interfaces:**
- `TeamPublisher.Sources` loses `liveSessions`, `endpoints`, `grantsTo`, `projectsDir`, `codexDir`; gains `threads: [TeamDocs.ThreadRow]`, `live: [TeamDocs.LiveThread]`, `desktop: Bool`, `transcripts: [TeamThreadSources.Transcript]`. `publish(sources:now:)` writes `threads/index.json` from `threads`, `now.json` from `live`, and chunks each `Transcript` (rows already flattened) through `TeamRedaction` + `TeamChunker` onto `t/<kid>` as before. `collect(entries:…)` (the jsonl scan for `stats`) is unchanged.
- Produces:
```swift
public enum TeamThreadSources {
    public struct Transcript: Equatable, Sendable { public var threadId: String; public var project: String; public var rows: [TeamRedaction.Row] }
    /// The shells → rows; `updatedAt` ISO → unix seconds; project basename from the shell's project.
    public static func threads(_ shell: DesktopAPI.Shell, now: Int) -> (rows: [TeamDocs.ThreadRow], live: [TeamDocs.LiveThread])
    /// One thread detail → transcript rows (role, text, tool name + first line, at).
    public static func transcript(_ thread: DesktopAPI.Thread, project: String) -> Transcript
}
```

- [ ] **Step 1: Write the failing test** (`TeamThreadSourcesTests.swift`): decode the fixture `Tests/InfinitusCoreTests/Fixtures/desktop-shell.json` (create it from `DesktopAPITests`' shell fixture with two threads, one `running`), assert `threads(_:now:)` yields two rows sorted by `updatedAt` desc, the running one in `live`, and `project` is a basename.
- [ ] **Step 2: Run** `swift test --filter TeamThreadSourcesTests` → FAIL.
- [ ] **Step 3: Implement** `TeamThreadSources`; edit `TeamPublisher.Sources` and `publish` as listed; delete the `ClaudeSessionRecord`→`LiveSession` map (old line ~566) and the transcript source walk over `projectsDir` (`TranscriptSource` now built from `Sources.transcripts`).
- [ ] **Step 4: Run** `swift test --parallel --filter 'TeamThreadSourcesTests|TeamPublisherTests|TeamCollectTests'` → PASS after the publisher tests feed `threads`/`transcripts` instead of a projects dir.
- [ ] **Step 5: Commit** `feat(mac): TeamPublisher publishes threads and transcripts from the desktop server`.

### Task 2.4: CLI `publish`, `members`, `member`, `insights`, `aggregates`, `reshare`

- [ ] **Step 1:** In `TeamCommand.swift` restore those six cases from `git show 4947e663df:apps/mac/Sources/InfinitusCLI/TeamCommand.swift`; `publish` builds `Sources(home:)`, sets `entries` from a `StatsScanner` scan of `--projects` (default `~/.claude/projects`) for `stats`, and fills `threads`/`live`/`transcripts` only when `desktop status` finds a credential (`DesktopCommand.swift`'s `credential()` helper), else `desktop: false`. Restore the usage lines.
- [ ] **Step 2:** `swift build --product infinitusctl`; run the Task 1.3 round plus `INFINITUS_TEAM_DIR="$D/bo" $CTL team publish --projects <fixture>` → JSON with `published`.
- [ ] **Step 3: Commit** `feat(mac): infinitusctl team publish, members, insights`.

### Task 2.5: Headless `TeamModel` and the `team-*` verbs

**Files:**
- Create: `apps/mac/Sources/Infinitus/TeamModel.swift` (from `git show 4947e663df:apps/mac/Sources/Infinitus/TeamModel.swift`, cut to the listed API)
- Restore: `apps/mac/Sources/Infinitus/TeamSecretsKeychain.swift`
- Modify: `AppModel.swift` (the `lazy var team` block and `statsModel.scanFeedsTeam`), `ControlServer.swift` (`teamReply()` and the cases), `ControlProtocol.swift` (manifest entries), `LockModel.swift` (`teamNames()`), `ControlServer.swift`'s `lock off` branch
- Test: `Tests/InfinitusCoreTests/ControlProtocolTests.swift` (manifest lists the verbs and their `stdin`), `apps/mac/tools/e2e.sh`

**Interfaces:**
- `TeamModel` (`@MainActor`, `ObservableObject`): `snapshot: TeamSnapshot?`, `lastError: String?`, `enabled`, `load()`, `refreshIfStale(_:)`, `loop(publish:)`, `quit()`, `fetchNow()`, `publishNow() -> TeamPublisher.Report?`, `create(name:remote:token:leaderName:)`, `join(code:name:) -> String?`, `mintCode(days:) -> String?`, `mintInvite(days:) -> String?`, `approve(kid:)`, `decline(kid:)`, `remove(kid:)`, `promote(kid:)`, `leave()`, `setShare(kind:target:)`, `setExclusion(slug:on:)`, `setPolicy(requests:)`, `insights(period:) -> Insights?`, `recoveryKey()`, `exportIdentity(passphrase:) -> Data?`. Sources come from `AppModel`: `desktopCredential` → `DesktopAPI(origin:token:)` → `shell()` + `thread(id, turnLimit)` on the team queue; `statsModel`'s scan entries as before (`ownsScan`/`scanEntries`/`scanGeneration`).
- Manifest entries (exact `ControlCommand` lines):
```swift
        ControlCommand(name: "team-status", effect: .read,
                       summary: "Settings › Team: the team this Mac is in — members with what they last published, pending requests, shares, exclusions, the loop's last fetch/publish — or null when there is none.",
                       replyShape: "{id, name, remote (masked), kid, role: leader|member|pending, rev, members: [{kid, name, role, isMe, founder, since, lastPublished, kinds, threadsNow, blockers, crashes, todayUSD, todayMessages, todayCommits, fleet}], requests: [{kid, name, platform, devices, at}], policy: {requests}, shares: {kind: audience}, exclusions: [slug], lockEnabled, lastFetch, lastPublish, lastError} | null"),
        ControlCommand(name: "team-create", args: ["<name>"], options: ["--remote <url>", "--as <your name>"], effect: .write, stdin: "secret",
                       summary: "Create a team on an empty git remote; the remote's write token, if it needs one, comes on stdin (empty stdin: none).",
                       replyShape: "team-status"),
        ControlCommand(name: "team-join", args: ["<your name>"], effect: .write, stdin: "secret",
                       summary: "Request to join a team: the team code or invite link on stdin, this Mac's name in the roster as the argument.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-code", options: ["--days <n>", "--invite"], effect: .write,
                       summary: "Mint a team code (leaders; needs the biometric lock on): the code, valid --days (default 7); --invite adds a one-time nonce the leader auto-approves.",
                       replyShape: "{code, expires}"),
        ControlCommand(name: "team-fetch", effect: .write, summary: "Pull the store now and rebuild the snapshot.", replyShape: "team-status"),
        ControlCommand(name: "team-publish", effect: .write, summary: "Publish this Mac's data now (what the 5-minute loop does).", replyShape: "{published: [path], transcriptChunks, skipped}"),
        ControlCommand(name: "team-approve", args: ["<kid>"], effect: .write, summary: "Approve a join request (leaders; needs the biometric lock on).", replyShape: "team-status"),
        ControlCommand(name: "team-decline", args: ["<kid>"], effect: .write, summary: "Decline a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-remove", args: ["<kid>"], effect: .write, summary: "Remove a member (leaders; never the founder).", replyShape: "team-status"),
        ControlCommand(name: "team-promote", args: ["<kid>"], effect: .write, summary: "Make a member a leader.", replyShape: "team-status"),
        ControlCommand(name: "team-leave", options: ["--yes"], effect: .write, summary: "Delete my files on the store, tell the leaders, forget the team here; --yes confirms.", replyShape: "{left}"),
        ControlCommand(name: "team-share", args: ["<kind>", "off|leaders|team"], effect: .write, summary: "Audience for stats|now|threads|transcripts|crashes|fleet.", replyShape: "team-status"),
        ControlCommand(name: "team-exclude", args: ["add|remove", "<project slug>"], effect: .write, summary: "Keep a project private (local, never sent).", replyShape: "team-status"),
        ControlCommand(name: "team-policy", args: ["requests", "open|code|off"], effect: .write, summary: "Who may request to join (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-insights", options: ["--period <day|week|month|year>"], effect: .read, summary: "Blockers, headroom, who is on, the team picture for the period (spend is an estimate).", replyShape: "{period, blockers: [{kid, name, kind, text}], headroom: [{kid, name, state}], onNow: [name], aggregates?}"),
        ControlCommand(name: "team-identity", options: ["--export"], effect: .read, stdin: "secret",
                       summary: "This Mac's team identity kid; with --export, the passphrase on stdin and the sealed identity file in the reply (never logged).", replyShape: "{kid, exported?}"),
```

- [ ] **Step 1: Write the failing test** in `ControlProtocolTests.swift`:
```swift
    func testTeamVerbsAreDeclaredWithTheirSecrets() {
        let byName = Dictionary(uniqueKeysWithValues: ControlCommand.all.map { ($0.name, $0) })
        for name in ["team-status", "team-create", "team-join", "team-code", "team-fetch", "team-publish", "team-approve", "team-decline",
                     "team-remove", "team-promote", "team-leave", "team-share", "team-exclude", "team-policy", "team-insights", "team-identity"] {
            XCTAssertNotNil(byName[name], name)
        }
        XCTAssertEqual(byName["team-create"]?.stdin, "secret"); XCTAssertEqual(byName["team-join"]?.stdin, "secret")
        XCTAssertNil(byName["team-code"]?.stdin)
    }
```
- [ ] **Step 2: Run** `swift test --filter ControlProtocolTests` → FAIL.
- [ ] **Step 3: Implement** the manifest entries; `TeamModel` (copy the old file, delete everything Nearby/control/hostname/drive/tail/transcript-view, replace the `sources` closure with the desktop-fed one from Task 2.3); `AppModel`'s `lazy var team` as the old block (`TeamSecretsFactory.make`, `enabled = !isPlayground && (!mockMode || INFINITUS_TEAM_DIR set)`); `ControlServer` cases modelled on the old `team-status`/`team-create`/`team-join` blocks (the `--remote` positional fallback kept), `team-code`/`team-approve` first checking `guard model.lock.enabled else { throw Fail("turn the biometric lock on first (Settings › Infinitus › Lock)") }`; `LockModel.teamNames()` as the old function; in `lock off`: `if !(r.options["yes"] == "true"), let names = Optional(model.lock.teamNames()), !names.isEmpty { throw Fail("this Mac is in \(names.joined(separator: ", ")): pass --yes to turn the lock off") }`.
- [ ] **Step 4: Build and unit test** `swift build --product Infinitus` and `swift test --parallel --filter 'ControlProtocolTests|LockPolicyTests'` → PASS.
- [ ] **Step 5: e2e** — in `tools/e2e.sh` add after line 43 `export INFINITUS_TEAM_DIR="$SOCKDIR/team-app"` and, before the desktop verbs section, the old team block (`git show 4947e663df:apps/mac/tools/e2e.sh | sed -n 776,827p`) with these edits: drop the jsonl fixture lines and `--projects`; `team publish` asserts `'published' in d`; drop the `transcriptChunks` assertions and the `team-hostname` lines; add `"$CTL" team-code --days 1 2>&1 | grep -q "biometric lock" || fail "team-code must want the lock on"` BEFORE the lock is on — since the e2e never turns the lock on, the CODE line becomes `CODE="$(INFINITUS_TEAM_DIR="$SOCKDIR/team-app" "$CTL" team code --days 1 | json "d['code']")"` (the CLI, in-process, against the app's file-secret team dir); add `"$CTL" lock off 2>&1 | grep -q -- "--yes" || fail "lock off in a team must want --yes"`. Run `/bin/sh tools/e2e.sh` → the team lines print `team: ok`.
- [ ] **Step 6: Commit** `feat(mac): Team verbs, headless TeamModel and the lock gates`.

### Task 2.6: Contracts and the visual fixture

**Files:**
- Modify: `packages/contracts/src/infinitus.ts` (append `InfinitusTeamMember`, `InfinitusTeamRequest`, `InfinitusTeamSnapshot`, `InfinitusTeamInsights`, `InfinitusTeamCode`), `packages/contracts/src/infinitus.test.ts` (or the nearest existing test file)
- Modify: `scripts/fork-visual-fixture.data.json` (manifest gains the `team-status` entry copied from the Swift manifest; a `team-status` canned reply with two members), `scripts/fork-visual-fixture.mjs` (answer `team-status`)

- [ ] **Step 1: Test first**: `decodeUnknownSync(InfinitusTeamSnapshot)` on the fixture reply passes; `null` decodes through `Schema.NullOr`.
- [ ] **Step 2: Schemas** mirror the manifest's reply shape; every non-essential field `Schema.optionalKey`.
- [ ] **Step 3:** `vp test run packages/contracts/src/infinitus.test.ts scripts/fork-visual-fixture.guard.test.ts` → PASS.
- [ ] **Step 4: Commit** `feat(contracts): InfinitusTeamSnapshot and the fixture's team-status`.

### Task 2.7: Fragment + PR — `apps/mac/changelog.d/team-verbs.md`: `Mac: Team publishes threads from Infinitus desktop and answers team-* over the control socket (#1313).`

---

## Slice 3: web pane + desktop join link + site (PR "feat(web): Settings › Infinitus › Team")

### Task 3.1: `team.logic.ts` (restore and re-type)
- Restore `apps/web/src/components/settings/infinitus/team.logic.ts` and `team.logic.test.ts` from `d587749289^`; replace the local `TeamStatus` schema with `InfinitusTeamSnapshot` from `@infinitus/contracts/infinitus`; delete `teamHostnameSupported`; add `TeamAction` cases `remove`, `promote`, `leave`, `share`, `exclude`, `policy`, `code`, and `teamCreateSecretArgs(name, remote, as)` → `{command: "team-create", args: {name}, options: {remote, as}}`. Test: each action's `InfinitusCommandInput`; `parseTeamStatus(null)` → `{team: null}`. Run `vp test run apps/web/src/components/settings/infinitus/team.logic.test.ts`.

### Task 3.2: `InfinitusTeamPanel.tsx` + route
- Restore `InfinitusTeamPanel.tsx` and `apps/web/src/routes/settings.infinitus.team.tsx` from `d587749289^`; delete the Hostnames, Nearby, Grants and Sessions sections; keep Members, Requests, Invite, Sync, Join, Create; add Sharing (select per kind over `team-share`), Exclusions, Policy, Leave (confirm dialog → `team-leave --yes`). Invite button disabled with title "Turn the lock on in Settings › Infinitus › Lock" when `snapshot.lockEnabled` is false; the minted code shown once in a read-only password-style field with Copy and "Copy link" (`https://infinitus.run/join#${encodeURIComponent(code)}`).
- Registration: `settingsSearch.ts` (`"/settings/infinitus/team"` in the union after `/lock`, label `"Team"`, search item `infinitus-team` with `infinitusOnly: true`, the `null` entry in the parent map), `SettingsSidebarNav.tsx` (`UsersIcon`, path in `INFINITUS_SETTINGS_PATHS`), `scripts/fork-visual-routes.ts` (`{ route: "/settings/infinitus/team", label: "Team", marker: "Members" }`), regenerate `routeTree.gen.ts` with `pnpm --filter @infinitus/web exec tsr generate` (never by hand).
- Tests: `vp test run apps/web/src/components/settings/settingsSearch.test.ts scripts/fork-visual-routes.test.ts`.

### Task 3.3: desktop `join` deep link
- `packages/contracts/src/ipc.ts`: add `Schema.Struct({ kind: Schema.Literal("join"), link: Schema.String })` to `DesktopDeepLink`.
- `apps/desktop/src/infinitus/InfinitusDeepLinks.ts`: restore the `join` branch from `d587749289^` (host `join` → `{kind: "join", link: url}`; log the kind only); its test gains `parses join`.
- Restore `apps/web/src/components/deepLinks/pendingTeamJoin.ts`; in `DeepLinkCoordinator.tsx` add `if (link.kind === "join") { usePendingTeamJoinStore.getState().offer(link.link); navigate({ to: "/settings/infinitus/team" }); return; }`; the panel's Join field calls `take()` on mount.
- `apps/mac/make-app.sh`: delete the `CFBundleURLTypes` block for `infinitus://` from the standalone Info.plist.
- Tests: `vp test run apps/desktop/src/infinitus/InfinitusDeepLinks.test.ts apps/web/src/components/deepLinks/deepLink.logic.test.ts`.

### Task 3.4: site `join.html` + AASA
- Create `apps/mac/site/public/join.html` modelled on `pair.html`: read `location.hash`; if non-empty and `navigator.userAgent` is not iOS/Android, `location.replace("infinitus://join/" + hash.slice(1))` and after 1.5 s show the code with a Copy button and "Paste it into Settings › Infinitus › Team"; on a phone show "Open this in the Infinitus app".
- `apple-app-site-association`: add `{ "/": "/join", "comment": "a team invite: infinitus.run/join#<code> (#1313)" }` to `components`.
- `sitemap.xml`/`robots.txt`: `noindex` meta on the page, nothing else. Deploy is by hand later (`npx wrangler deploy` from `apps/mac/site`); note it in the PR body as a follow-up for the owner.

### Task 3.5: Fragment + PR — `apps/mac/changelog.d/team-web-pane.md`: `Desktop: Settings › Infinitus › Team is back — create or join a team, approve requests, mint invite links, choose what you share (#1313).`

---

## Slice 4: phone (PR "feat(mobile): Settings › Team")

### Task 4.1: `apps/mobile/src/features/team/team.logic.ts` (+ test)
- `teamJoinLinkCode(url: string): string | null` — `https://infinitus.run/join#<code>` → the code; anything else null (mirror `universalPairLink.logic.ts`'s host check).
- `teamMacs(configs, presentations)` — reuse `infinitusMacs` from `features/accounts/accountsRoute.logic.ts`.
- `teamStatusSupported(commands)` / `teamJoinSupported(commands)` — same predicates as the web.
- Test: the link parse (good, wrong host, no fragment), the gates.

### Task 4.2: `TeamRouteScreen.tsx`
- One `SettingsSection` per Mac: `useAtomValue(infinitusEnvironment.snapshot(...))` for the manifest gate, `useAtomCommand(infinitusEnvironment.command)` for `team-status`/`team-fetch`/`team-approve`/`team-decline`, `useAtomCommand(infinitusEnvironment.secret)` for `team-join`. Members list (name · role · last seen), Requests with Approve/Deny (leaders), Join form (name + code, `secureTextEntry`), Fetch now. Route param `code?: string` prefills the code.
- Registration: `Stack.tsx` (`SettingsTeam: createNativeStackScreen(...)` after `SettingsAccounts`, link `settings/team`), `settings-sheet-targets.ts` (`"SettingsTeam"`), `SettingsInfinitusSection.tsx` (`<SettingsRow icon="person.3" label="Team" target="SettingsTeam" />` after Accounts), `App.tsx` `rewriteIncomingUrl`: `const teamCode = teamJoinLinkCode(url); if (teamCode !== null) return Linking.createURL("settings/team", { queryParams: { code: teamCode } });` before the pair rewrite, `app.config.ts` intent filter: a second `data` entry with `pathPrefix: "/join"`.
- Tests: `vp test run apps/mobile/src/features/team/team.logic.test.ts`; typecheck `pnpm --filter @infinitus/mobile exec tsc --noEmit`.

### Task 4.3: Fragment + PR — `apps/mac/changelog.d/team-phone.md`: `Phone: Settings › Team joins a team from an invite link and approves requests on your Mac (#1313).` PR body names the site deploy (AASA `/join`) as the prerequisite for the universal link.

---

## Slice 5: transcripts (fold into slice 2 if `TeamThreadSources.transcript` fits in Task 2.3 under 150 lines; else this PR)
- `TeamTranscriptChoices` unchanged; `TeamModel.loop` calls `DesktopAPI.thread(id, turnLimit: choices.turnLimit)` for each thread whose `updatedAt` moved since the last publish (cursor in `TeamPublishState`), only while `shares.transcripts != off`. Test: a publisher test with two transcripts asserts chunk paths on `t/<kid>` and that a `sharesTo.transcripts == off` publishes none.
- Fragment: `Mac: teammates who share transcripts publish their threads' conversations, redacted (#1313).`

---

## Slice 6: delegated control (PR "feat: Team delegated control over threads")

Expanded after slices 1–5 merged (#1327, #1348, #1351, #1352). Spec §8. One PR, several commits, in this order.

**Decisions the spec leaves open, settled here:**
- Capabilities `view | send | interrupt | new`. `view` and `send` never ask (the drive set); `interrupt` and `new` ask unless the grant pre-authorises them. Nothing is `neverPreauthorized`.
- `new` is machine-scoped: `Command.thread` is `-`, `Command.project` names the project (title or id), the grant's thread list is not consulted. The others name a thread.
- "Live" = the thread id is in the desktop's shell right now (`Endpoint.threads()`); `interrupt` on a thread with no running turn is `refused` by the executor, not `notLive` by verify. `view` and `send` need the thread to exist. `new` skips the check.
- `view` answers through the ack's `detail`: the thread's last turn, redacted with `TeamRedaction`, capped at 4 KB. No second reply shape.
- `new` with no default model (`DesktopRows.NoModel`) is `refused` with the message; never a crash.
- Rate: `send`/`view` in the 5-per-10-s bucket, `interrupt`/`new` in the 6-per-minute one.
- Lanes: LAN base URLs (2 s each), then the tunnel (5 s), then the store. The old subnet pre-check is dropped with `MirrorPairing` — a LAN URL is dialed and times out. The desktop's own `httpBaseUrl` is published only when it is not loopback.

### Task 6.1: core restored and re-typed
**Files:** `Sources/InfinitusCore/Team/{TeamGrants,TeamGrantsRouting,TeamControl,TeamControlStore,TeamControlDrive}.swift` from `4947e663df`, re-typed: `sessions`→`threads`, `Sessions`→`Threads`, `Command{id,to,thread,action,text,project?,at,ttl}`, own `Reply{outcome,detail}` (no `SessionInput`), `Endpoint.threads: () -> Set<String>`, `execute: (Command) -> Reply`, `Endpoints{httpBaseUrl?, lanHttpBaseUrls, tunnel?}`, `Deliver` without interfaces/rendezvous, `Drive.network` posting `{envelope: base64}` to `/api/infinitus/team/command` and reading `{ack: base64|null}`. Dropped: `Hostname`, `rendezvousKey`, `LocalVerb`, `verbReply`, `request(action:text:)`, tiers/meanings/expiry choices, `Drive.tail`. `TeamKinds`: `command`, `ack`, `controlKinds`, path shape `control/(commands|acks)/<id>.json`. `TeamDocs`: `GrantHint{audience, threads?, capabilities, approval?, expires?}`, `Now.endpoints?`, `Now.grantsTo?`. `TeamReader.Member`: `commands`, `acks`, `ackIDs`. `TeamSnapshot`: `controls(hints:roster:me:thread:)`, `Member.controls` filled, `grants?`, `pending?`.
**Tests:** `TeamGrantsTests`, `TeamControlTests` (incl. `testEveryRefusalInOrder`, `testOrderIsProvenByACommandFailingTwoRules`), `TeamControlStoreTests`, `TeamControlDriveTests`, `TeamGrantsRoutingTests`, `TeamSnapshotControlsTests`. `swift test --filter 'TeamGrants|TeamControl|TeamSnapshotControls'`.

### Task 6.2: Mac — verbs, endpoint state, executor, publisher
**Files:** `Sources/Infinitus/TeamModel.swift` (control state per team: `seen`/`outbox`/`handled` on disk, `pending` + rate buckets in memory, all touched inside `run {}`; `inbox(_:)`, `grantorPass` after every fetch, `driverReap`, `drive(...)`, `addGrant`/`revokeGrant`, `pending`/`decide`), `Sources/Infinitus/AppModel.swift` (`team.tunnelURL`, endpoints + grant hints into `teamSources()`), `Sources/InfinitusCore/Desktop/DesktopAPI.swift` (`Descriptor.lanHttpBaseUrls`, `alternateHttpBaseUrls`), `Sources/InfinitusCore/Team/TeamPublisher.swift` (`Sources.endpoints`, `Sources.grantsTo`), `Sources/InfinitusCore/ControlProtocol.swift` (`team-inbox` stdin secret, `team-grants`, `team-grant`, `team-revoke`, `team-pending`, `team-allow`, `team-deny`, `team-drive`, `team-acks`), `Sources/Infinitus/ControlServer.swift`, `Sources/InfinitusCLI/main.swift:83` (`team-inbox` in the stdin allowlist), `Sources/InfinitusCLI/TeamCommand.swift` (in-process `grant | grants | revoke | drive | acks`; `pending | allow | deny` app-only; routing through `TeamGrantsRouting`).
`team-inbox` never fails on an unverifiable envelope: `{ack: null}`; a stranger learns nothing.

### Task 6.3: server route + contracts
**Files:** `packages/contracts/src/infinitusTeamControl.ts` (`InfinitusTeamControlHttpApi`, `POST /api/infinitus/team/command`, `{envelope}` ≤ 64 KB → `{ack}`; unauthenticated like `InfinitusPairingHttpApi`), `packages/contracts/package.json` export, `packages/contracts/src/environmentHttp.ts` (`.add`), `packages/contracts/src/infinitus.ts` (`controls`, `grants`, `pending` on the snapshot, all `optionalKey`), `apps/server/src/infinitus/Layers/InfinitusTeamControlHttp.ts` (`control.request({command: "team-inbox", secret: envelope})`; unavailable → 503 with no detail), `apps/server/src/server.ts`, test `InfinitusTeamControlHttp.test.ts` with `Layer.mock(InfinitusControlClient)`.

### Task 6.4: web Grants and Pending
**Files:** `apps/web/src/components/settings/infinitus/team.logic.ts` (`grant`, `revoke`, `allow`, `deny` actions; `teamGrantDraft`), `InfinitusTeamPanel.tsx` (Grants: list + revoke + add form; Pending: allow/deny; `controls` on member rows). No drive UI (spec §8: the phone's "Send to" waits for the lane to work from the web).

### Task 6.5: e2e, docs, fragment, PR
**Files:** `tools/e2e.sh` (store-lane round after the desktop verbs' dispatch assertions, before the credential is replaced: grant send+new → drive send → fetch executes onto `t-idle` (asserted on the demo desktop) → acks `delivered`; `new` → `pending` → `team-allow` → `done`; revoke → `noGrant`; `view` → `done` with the redacted echo), `docs/internals/fork-registration-points.md`, `docs/internals/fork-only-files.md`, `apps/mac/changelog.d/team-control.md`: `Mac: teammates you grant can send to your threads (#1313).`
