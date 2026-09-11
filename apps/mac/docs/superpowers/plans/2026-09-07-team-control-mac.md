# Team session control — Mac grantor (PR 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mount the #220 control core in the Mac app as the grantor: the mirror server answers `POST /team/command` and the team tail route, commands execute through the same delivery path as phone input, every command is audited, `now.json` carries the endpoints and grant hints, and grants are managed from Settings › Team and `infinitusctl team grant|revoke|grants`.

**Architecture:** One new lock box in MirrorServer (`MirrorTeamControlBox`) holds a `TeamControl.Endpoint?` rebuilt off-main whenever the team standing or the team model reloads; control routes bypass the pairing token and the LAN gate because a sealed command or a signed tail header authenticates itself. Verification runs on a dedicated serial queue; execution hops to the existing `mirrorInputQueue` so phone and team keystrokes to one pty never interleave. Grants, roster and the replay set are read from disk per request so the CLI's `team grant` takes effect with no IPC. AppModel turns each audit into an event-log line, a 60 s "driven by" caption in the sessions popover and a once-per-hour refusal notification per driver.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14+), Network.framework, XCTest, `/bin/sh` e2e.

**Spec:** `docs/superpowers/specs/2026-09-07-team-session-control-design.md` (§5.1, §5.2 grantor half, §6, §7.1, §7.3 grant/revoke/grants, §9, §10 item 3). Core it mounts: PR 2 (`TeamGrants`, `TeamControl`, `TeamControlRoute`, branch `control-core`, PR #276).

## Global Constraints

- The engine stays isolated: nothing here reads `~/.claude-swap-backup/*`; Claude Code's own files (`~/.claude/sessions/*.json`) are fine.
- Everything is Swift; InfinitusCore + InfinitusCLI must build on Linux (`#if canImport(Glibc)` where needed).
- Event-log icons are SF Symbol names (`person.2`), never emoji: both renderers use `Image(systemName:)`.
- No file under `Sources/InfinitusUI/` or `ios/` changes (Infi3 owns InfinitusUI; `ios/` needs the phone gate). The HUD caption lives in `Sources/Infinitus/MacSessionsPopover.swift`.
- Idle CPU with the pop-out open stays near 0 %: no timers for the 60 s caption (a stored `until` date read at render time; the popover re-renders when the dictionary changes).
- Secrets never on argv; `TeamGit.masked` on every CLI error path (the `fail` helper already does).
- Bundle id `run.infinitus`; new queue labels under `run.infinitus.`.
- One feature = one CHANGELOG line under `## Unreleased › ### Team (preview)`; the same one-liner goes to README and `site/public/index.html` + `site/public/llms.txt`.
- Every commit carries `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the repo hook appends it; `git config core.hooksPath tools/githooks` is set in this worktree).
- Dev/e2e instances run with `INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock`.

## Rulings (recorded before execution; spec is authority, these fill its gaps)

1. **Execute path.** Spec §10 says "execution through `AppModel.send`". `AppModel.send` is async and message-only. The real shared path is the phone lane's synchronous closure (`mirrorServer.sessionInput.set` in AppModel), which handles all five kinds and hops to main for `.mode`. Task 2 extracts it into one deliverer both lanes call. Logged on #220.
2. **Approve mapping.** `team approve … allow|deny`: `allow` → key `1`, `deny` → key `esc` (both in `SessionInput.allowedKeys`). A team approve never adds a session-wide `ToolApproval` rule in phase 1 (the driver sends no rule payload). `key` requires `text ∈ allowedKeys`; `send` requires non-empty text; `mode` requires non-empty text; `resume` takes optional text.
3. **Serialization.** Verification on `run.infinitus.team-control` (serial); delivery via `mirrorInputQueue.sync`. Never `teamStoreQueue` (git pushes would stall commands).
4. **Endpoint rebuild triggers.** `MirrorServer.start` (after `refreshTeamStanding`), and `TeamModel.onLoaded` after every `load()` (a team created or joined mid-run). Grants/roster/seen are re-read from disk per request, so no rebuild is needed for a grant change.
5. **HUD caption.** "driven by <name>" renders in `MacSessionsPopover` under the session card (not in InfinitusUI's `SessionListCard`).
6. **Feed.** A small `TeamControlFeed: ObservableObject` (last 50 audit lines) owned by AppModel, passed to `TeamPane`; `EventEntry` is untouched.
7. **e2e.** No sender exists until PR 4, so the drive step (spec §9) moves to PR 4. PR 3's step: Bo grants → `team grants` lists → Bo publishes → Ann's `team-fetch` shows `controls == ["send"]` on Bo's row → revoke → empty. For PR 4: the mirror listener is OFF in e2e (`mock_mode` + process name `Infinitus` → `applyMirrorLAN` stops it) and `isLANPeer` excludes loopback; PR 4's drive step needs `mirror_lan_allow_mock` and a process-name workaround, or drives via a unit-level route call.
8. **Snapshot.** `TeamSnapshot.Member.controls: [String]?` = the sorted capabilities that member grants *me* (from `now.json` `grantsTo` × `roster.recipients(for:)`), additive and optional so older phones decode. PR 4's driver UI needs exactly this.
9. **TeamGate.** `team grant` and `team revoke` sit on the lock list beside `approve`: delegating control is at least as sensitive as admitting a member.
10. **CLI output.** `team grants` always emits JSON like every other subcommand; `--json` is accepted and ignored (spec §7.3 lists it).
11. **Control routes bypass auth and the LAN gate.** The envelope / signed header is the credential; `TeamControlRoute` answers 404 without grants, so a stranger learns nothing.
12. **Body cap.** `POST /team/command` uses `sessionInputBodyCap` (a sealed prompt can exceed the 16 KiB default).
13. **Refusal notifications.** Once per driver per hour for outcomes `expired`, `replayed`, `notLive`, `rateLimited`, `badRequest` when the sender is a roster member (a name resolved); never for `noGrant` (the spec excludes it) or `unknownSender` (not a member).

---

## File map

| File | Change |
|---|---|
| `Sources/InfinitusCore/MirrorRendezvous.swift` | `url(key:base:)`; `url(token:)` calls it |
| `Sources/InfinitusCore/MirrorTransport.swift` | `bodyCap` case for the command route |
| `Sources/InfinitusCore/Team/TeamControl.swift` | `request(action:text:) -> SessionInput.Request?` |
| `Sources/InfinitusCore/Team/TeamPublisher.swift` | `Sources.endpoints`, `Sources.grantsTo`, set on `now.json` |
| `Sources/InfinitusCore/Team/TeamSnapshot.swift` | `Member.controls` + fold |
| `Sources/Infinitus/AppModel.swift` | shared deliverer, `recordTeamControl`, `drivenBy`, `teamControlFeed`, `teamSources` endpoints/grantsTo, rendezvous under the control key, wiring |
| `Sources/Infinitus/MirrorServer.swift` | `MirrorTeamControlBox`, `controlQueue`, mount in `receive`, `refreshTeamControl()` |
| `Sources/Infinitus/TeamModel.swift` | `grants` published, `addGrant`, `revokeGrant`, `onLoaded` |
| `Sources/Infinitus/TeamPane.swift` | "Session control" section + feed |
| `Sources/Infinitus/TeamGrantSheet.swift` | new: add-grant sheet |
| `Sources/Infinitus/TeamControlFeed.swift` | new: feed model |
| `Sources/Infinitus/MacSessionsPopover.swift` | "driven by" caption |
| `Sources/Infinitus/InfinitusApp.swift` | pass the feed to TeamPane |
| `Sources/InfinitusCLI/TeamControlCommand.swift` | new: grant / revoke / grants |
| `Sources/InfinitusCLI/TeamCommand.swift` | dispatch line + usage + gate list |
| `Tests/InfinitusCoreTests/…` | tests per task |
| `tools/e2e.sh`, `CHANGELOG.md`, `README.md`, `site/public/index.html`, `site/public/llms.txt` | step + one-liners |

---

### Task 1: Core widenings (rendezvous key URL, body cap, action→request, publisher hints, snapshot controls)

**Files:**
- Modify: `Sources/InfinitusCore/MirrorRendezvous.swift:23-26`
- Modify: `Sources/InfinitusCore/MirrorTransport.swift:192-194`
- Modify: `Sources/InfinitusCore/Team/TeamControl.swift` (after `Outcome`)
- Modify: `Sources/InfinitusCore/Team/TeamPublisher.swift:163-203` (Sources) and `:442-448` (now.json)
- Modify: `Sources/InfinitusCore/Team/TeamSnapshot.swift:9-42, 66-80`
- Test: `Tests/InfinitusCoreTests/TeamControlTests.swift`, `Tests/InfinitusCoreTests/TeamPublisherTests.swift`, `Tests/InfinitusCoreTests/MirrorTransportTests.swift` (exists; add one test), `Tests/InfinitusCoreTests/TeamSnapshotTests.swift` (create if absent)

**Interfaces:**
- Produces: `MirrorRendezvous.url(key: String, base: String = defaultBase) -> URL?`; `TeamControl.request(action: String, text: String?) -> SessionInput.Request?`; `TeamPublisher.Sources.endpoints: TeamControl.Endpoints?`, `.grantsTo: [TeamDocs.GrantHint]?`; `TeamSnapshot.Member.controls: [String]?`.

- [ ] **Step 1: Failing tests**

Append to `Tests/InfinitusCoreTests/TeamControlTests.swift` (inside the class):

```swift
    func testActionsMapToSessionInputRequests() {
        XCTAssertEqual(TeamControl.request(action: "send", text: "hi")?.kind, .message)
        XCTAssertEqual(TeamControl.request(action: "send", text: "hi")?.text, "hi")
        XCTAssertNil(TeamControl.request(action: "send", text: ""), "an empty prompt is nothing to type")
        XCTAssertEqual(TeamControl.request(action: "key", text: "esc")?.kind, .key)
        XCTAssertNil(TeamControl.request(action: "key", text: "rm -rf"), "only the allowed keys")
        XCTAssertEqual(TeamControl.request(action: "approve", text: "allow")?.text, "1")
        XCTAssertEqual(TeamControl.request(action: "approve", text: "deny")?.text, "esc")
        XCTAssertEqual(TeamControl.request(action: "approve", text: "deny")?.kind, .key)
        XCTAssertNil(TeamControl.request(action: "approve", text: "maybe"))
        XCTAssertEqual(TeamControl.request(action: "mode", text: "plan")?.kind, .mode)
        XCTAssertNil(TeamControl.request(action: "mode", text: nil))
        XCTAssertEqual(TeamControl.request(action: "resume", text: nil)?.kind, .resume)
        XCTAssertNil(TeamControl.request(action: "reboot", text: "x"))
    }

    func testRendezvousKeyHasAURL() {
        let key = TeamControl.rendezvousKey(team: "team-1", kid: "k1")
        XCTAssertEqual(MirrorRendezvous.url(key: key)?.absoluteString, MirrorRendezvous.defaultBase + "/" + key)
        XCTAssertNil(MirrorRendezvous.url(key: "not-hex"))
        XCTAssertEqual(MirrorTransport.bodyCap(method: "POST", path: TeamControlRoute.commandPath), MirrorTransport.sessionInputBodyCap)
        XCTAssertEqual(MirrorTransport.bodyCap(method: "GET", path: TeamControlRoute.commandPath), MirrorTransport.defaultBodyCap)
    }
```

In `Tests/InfinitusCoreTests/TeamPublisherTests.swift`, find the test that reads `me + "now.json"` (line ~118) and, where its `Sources` is built (search `TeamPublisher.Sources(` in that test's setup), add before `publish`:

```swift
        sources.endpoints = TeamControl.Endpoints(lan: "10.0.0.2:47824", hostname: nil, rendezvous: nil)
        sources.grantsTo = [TeamDocs.GrantHint(audience: .leaders, sessions: nil, capabilities: ["send"])]
```

and after the `now` decode assertions:

```swift
        XCTAssertEqual(now.endpoints?.lan, "10.0.0.2:47824")
        XCTAssertEqual(now.grantsTo?.first?.capabilities, ["send"])
```

(If the sources variable in that test is a `let`, change it to `var`.)

Create `Tests/InfinitusCoreTests/TeamSnapshotControlsTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamSnapshotControlsTests: XCTestCase {
    func testControlsAreWhatAMemberLetsMeDo() throws {
        let ann = TeamIdentity.random(), bo = TeamIdentity.random(), cy = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "P", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: ann.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: bo.keys, name: "Bo", since: 2),
                                          TeamRoster.Member(keys: cy.keys, name: "Cy", since: 3)], rev: 1)
        var now = TeamDocs.Now(at: 10, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:])
        now.grantsTo = [TeamDocs.GrantHint(audience: .leaders, sessions: nil, capabilities: ["view", "send"]),
                        TeamDocs.GrantHint(audience: .members([cy.kid]), sessions: ["s1"], capabilities: ["approve"])]
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: ann.kid), ["send", "view"])
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: cy.kid), ["approve"])
        XCTAssertNil(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: bo.kid), "nothing granted reads as nil")
        XCTAssertNil(TeamSnapshot.controls(hints: nil, roster: roster, me: ann.kid))
    }
}
```

- [ ] **Step 2: Run, expect compile failures**

Run: `swift test --filter 'TeamControlTests|TeamSnapshotControlsTests|TeamPublisherTests' 2>&1 | grep -E 'error:' | head`
Expected: errors naming `request(action:`, `url(key:`, `endpoints`, `controls(hints:`.

- [ ] **Step 3: Implement**

`Sources/InfinitusCore/MirrorRendezvous.swift`, replace `url(token:base:)`:

```swift
    public static func url(token: String, base: String = defaultBase) -> URL? {
        guard let key = key(token: token) else { return nil }
        return url(key: key, base: base)
    }

    /// A slot addressed by an already-derived key (the team control key,
    /// `TeamControl.rendezvousKey`): 64 lower-case hex or nothing.
    public static func url(key: String, base: String = defaultBase) -> URL? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return URL(string: "\(base)/\(key)")
    }
```

`Sources/InfinitusCore/MirrorTransport.swift`, `bodyCap`:

```swift
    public static func bodyCap(method: String, path: String) -> Int {
        guard method == "POST" else { return defaultBodyCap }
        // A sealed team command carries a prompt (#220) — the input cap.
        return sessionInputPid(path) != nil || path == TeamControlRoute.commandPath ? sessionInputBodyCap : defaultBodyCap
    }
```

`Sources/InfinitusCore/Team/TeamControl.swift`, after the `Outcome` enum:

```swift
    /// A verified command as the input the session lane understands
    /// (ruling 2 of the Mac grantor plan): `approve` is the prompt's Yes
    /// or Esc, never a session-wide ToolApproval rule; `key` only the
    /// allowed keys; `send` and `mode` need text. nil = nothing to run.
    public static func request(action: String, text: String?) -> SessionInput.Request? {
        let text = text ?? ""
        switch action {
        case TeamGrants.send: return text.isEmpty ? nil : SessionInput.Request(kind: .message, text: text)
        case TeamGrants.key: return SessionInput.allowedKeys.contains(text) ? SessionInput.Request(kind: .key, text: text) : nil
        case TeamGrants.approve:
            switch text {
            case "allow": return SessionInput.Request(kind: .key, text: "1")
            case "deny": return SessionInput.Request(kind: .key, text: "esc")
            default: return nil
            }
        case TeamGrants.mode: return text.isEmpty ? nil : SessionInput.Request(kind: .mode, text: text)
        case TeamGrants.resume: return SessionInput.Request(kind: .resume, text: text)
        default: return nil
        }
    }
```

`Sources/InfinitusCore/Team/TeamPublisher.swift`, in `Sources` after `blockers`:

```swift
        /// Team session control (#220): where a driver reaches this
        /// machine and what it lets whom do. Hints only; both optional so
        /// the CLI publisher (no listener) sends neither.
        public var endpoints: TeamControl.Endpoints?
        public var grantsTo: [TeamDocs.GrantHint]?
```

and the `now.json` staging (`:442-448`) becomes:

```swift
            var doc = TeamDocs.Now(at: at, sessions: live, fleets: sources.fleets, blockers: sources.blockers,
                                   crashesToday: crashesToday,
                                   // An older client's ShareTarget decoder throws on "off";
                                   // the hint carries only kinds that actually travel.
                                   sharesTo: shares.byKind.filter { $0.value != .off })
            doc.endpoints = sources.endpoints
            doc.grantsTo = sources.grantsTo
            try stage(TeamKinds.now, "now.json", try CanonicalJSON.encode(doc), always: true)
```

`Sources/InfinitusCore/Team/TeamSnapshot.swift`: in `Member` after `fleet`:

```swift
        /// What this member lets ME do to their sessions (#220), sorted;
        /// nil when nothing. Additive, so an older phone decodes without it.
        public var controls: [String]?
```

(the memberwise `init` is unchanged; `controls` is assigned after). In `make`'s `row`, after `out.fleet = r.fleet`:

```swift
                out.controls = TeamSnapshot.controls(hints: r.now?.grantsTo, roster: roster, me: status.kid)
```

and add the static helper below `make`:

```swift
    /// The union of every hint whose audience names `me`, sorted; nil
    /// when no hint does (the row reads as "cannot drive").
    public static func controls(hints: [TeamDocs.GrantHint]?, roster: TeamRoster?, me: String) -> [String]? {
        guard let hints, let roster else { return nil }
        var out = Set<String>()
        for hint in hints where roster.recipients(for: hint.audience).contains(where: { $0.kid == me }) {
            out.formUnion(hint.capabilities)
        }
        return out.isEmpty ? nil : out.sorted()
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter 'TeamControlTests|TeamSnapshotControlsTests|TeamPublisherTests|MirrorTransportTests|MirrorRendezvousTests'`
Expected: all pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore Tests/InfinitusCoreTests
git commit -m "team control: the core widenings the Mac grantor mounts — rendezvous key URL, the command route's body cap, action→input mapping, endpoints and grant hints in now.json, a member's controls in the snapshot (#220)"
```

---

### Task 2: One delivery path for phone and team input

**Files:**
- Modify: `Sources/Infinitus/AppModel.swift:1393-1450` (the `mirrorServer.sessionInput.set` closure)

**Interfaces:**
- Produces: `AppModel.makeInputDeliverer() -> @Sendable (_ pid: Int32, _ request: SessionInput.Request, _ origin: String) -> SessionInput.Reply` (main-actor factory; the closure runs on `mirrorInputQueue`); `mirrorServer.teamControlDeliver` (Task 3) receives the same closure.

- [ ] **Step 1: Extract**

Replace the whole `mirrorServer.sessionInput.set { [weak self] pid, request in … }` block (ends with `return reply\n        }` just before `applyQuickTunnel()`) with:

```swift
        let deliver = makeInputDeliverer()
        mirrorServer.sessionInput.set { pid, request in deliver(pid, request, "phone") }
        mirrorServer.teamControlDeliver = deliver
```

and add the factory as a new method in the same extension/section:

```swift
    /// The one path for input from outside the terminal: the phone lane
    /// and the team lane (#220) both run it on `mirrorInputQueue`, so
    /// keystrokes to one pty never interleave. `origin` is the log's
    /// "phone" or "team Bo"; a team approve arrives already mapped to a
    /// key (TeamControl.request), so the ToolApproval branch is phone-only.
    func makeInputDeliverer() -> @Sendable (Int32, SessionInput.Request, String) -> SessionInput.Reply {
        { [weak self] pid, request, origin in
            let claudeDir = ClaudeSessions.configHome()
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            // #168: a queued request may name a pid from before a reboot —
            // the session lives on under a new one; its id does not change.
            guard let record = records.first(where: { $0.pid == pid })
                    ?? request.sessionId.flatMap({ id in records.first { $0.sessionId == id } })
            else {
                Task { @MainActor in self?.logMirrorInput("⚠️", "\(origin) input not delivered: unknown session") }
                return SessionInput.Reply(outcome: "rejected", detail: "session ended")
            }
            // A mode change never reaches the terminal: it is the Mac's
            // own state, decided on the main actor (the births live
            // there). This queue never blocks main, so a hop is safe.
            if request.kind == .mode {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self?.setSessionMode(request.text, pid: Int(pid), record: record)
                            ?? SessionInput.Reply(outcome: "rejected", detail: "app is shutting down")
                    }
                }
            }
            // "Allow for this session": remember the rule for the plugin's
            // PreToolUse hook, then answer the prompt on screen with Yes.
            var request = request
            if request.kind == .approve {
                if let rule = ToolApproval.decode(request.text) {
                    self?.toolApprovals.add(rule, sessionId: record.sessionId)
                    Task { @MainActor in self?.logMirrorInput("🛡️", "\(origin) allows \(rule.label) for the rest of session \(pid)") }
                }
                request = SessionInput.Request(kind: .key, text: "1")
            }
            let reply = SessionInput.deliver(request: request, record: record,
                                             hosts: PtyHosts.available(), claudeDir: claudeDir)
            let label = URL(fileURLWithPath: record.cwd).lastPathComponent
            Task { @MainActor in
                if reply.outcome == "delivered" {
                    let preview = String(request.text.prefix(60))
                    self?.logMirrorInput("📲", "\(origin) → \(label): \"\(preview)\" (\(reply.channel ?? "?"))")
                } else {
                    let why = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                    self?.logMirrorInput("⚠️", "\(origin) input not delivered: \(why)")
                }
                if origin == "phone", request.queuedAt != nil, ["delivered", "running", "captured"].contains(reply.outcome) {
                    // The phone queued this while the Mac was away; the
                    // push reaches it even when the app is closed.
                    self?.liveActivityPusher.pushAlert(title: "Delivered to \(label)",
                                                       body: String(request.text.prefix(80)))
                }
            }
            return reply
        }
    }
```

(The body is the old closure verbatim except: `origin` replaces the literal "phone" in the four log strings, and the queued-push branch is gated on `origin == "phone"`.)

- [ ] **Step 2: Build**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Compiling|Build complete' | tail -n 3`
Expected: `Build complete!` (the `teamControlDeliver` property does not exist until Task 3 — add it now as a stub on MirrorServer to keep the build green: `var teamControlDeliver: (@Sendable (Int32, SessionInput.Request, String) -> SessionInput.Reply)?` next to `var log`).

- [ ] **Step 3: Commit**

```bash
git add Sources/Infinitus/AppModel.swift Sources/Infinitus/MirrorServer.swift
git commit -m "mirror input: phone and team input share one deliverer, run on the input queue (#220)"
```

---

### Task 3: Mount the control routes in MirrorServer

**Files:**
- Modify: `Sources/Infinitus/MirrorServer.swift` (box after `MirrorTeamBox` ~`:303`; properties ~`:360-388`; `start` `:410`; `serve`/`receive` params `:567-599`; routing `:618-648`)

**Interfaces:**
- Consumes: `TeamControlRoute.respond(_:endpoint:tail:)`, `TeamControl.Endpoint`, `TeamControl.SeenIDs.load/save(teamDir:)`, `TeamControl.request(action:text:)`, `TeamClient.identity(paths:secrets:)`, `TeamSecretsFactory.make(paths:)`, `MirrorSessionFeedBox.call(_:_:since:wait:)`.
- Produces: `MirrorServer.teamControl: MirrorTeamControlBox`, `MirrorServer.refreshTeamControl()`, `MirrorTeamControlBox.onAudit: (@Sendable (TeamControl.Audit, String?) -> Void)?`.

- [ ] **Step 1: The box** (after `MirrorTeamBox`):

```swift
/// Team session control (#220): the grantor's endpoint, boxed like the
/// rest. Rebuilt off main when the team standing changes (`refreshTeamControl`);
/// `respond` runs under `MirrorServer.controlQueue` only, so the replay
/// set and the rate limit are mutated by one thread, and execution hops
/// to `mirrorInputQueue` inside the endpoint's `execute`.
final class MirrorTeamControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: TeamControl.Endpoint?
    private var teamDir: URL?
    /// The live feed by session id (the phone's tail, keyed by pid).
    var tail = TeamControlRoute.Tail { _, _ in nil }
    /// Every command, accepted or refused, with the driver's roster name.
    var onAudit: (@Sendable (TeamControl.Audit, String?) -> Void)?

    func set(_ new: TeamControl.Endpoint?, teamDir dir: URL?) {
        lock.lock(); endpoint = new; teamDir = dir; lock.unlock()
    }

    /// `controlQueue` only.
    func respond(_ request: MirrorTransport.Request) -> Data? {
        lock.lock(); var ep = endpoint; let dir = teamDir; lock.unlock()
        ep?.lastAudit = nil
        let response = TeamControlRoute.respond(request, endpoint: &ep, tail: tail)
        guard let ep else { return response }
        lock.lock()
        endpoint?.seen = ep.seen
        endpoint?.limit = ep.limit
        lock.unlock()
        if let audit = ep.lastAudit {
            if let dir { try? ep.seen.save(teamDir: dir) }
            let name = ep.roster()?.everyone.first { $0.keys.kid == audit.driver }?.name
            onAudit?(audit, name)
        }
        return response
    }
}
```

- [ ] **Step 2: Properties and rebuild** — next to `let teamMirror = MirrorTeamMirrorBox()`:

```swift
    /// Team session control (#220): `/team/command` and `/team/sessions/<id>/tail`.
    let teamControl = MirrorTeamControlBox()
    /// The shared input deliverer (AppModel.makeInputDeliverer); set once at start.
    var teamControlDeliver: (@Sendable (Int32, SessionInput.Request, String) -> SessionInput.Reply)?
```

next to `teamStoreQueue`:

```swift
    /// Control commands only: verification, the replay set and the rate
    /// limit are single-threaded here; delivery hops to `mirrorInputQueue`.
    private static let controlQueue = DispatchQueue(label: "run.infinitus.team-control")
```

In `start`, after `refreshTeamStanding(force: true)` add `refreshTeamControl()`, and add the method after `refreshTeamStanding`:

```swift
    /// Rebuilds the grantor endpoint off the main actor: at start and
    /// after every TeamModel load (a team created mid-run). Grants, roster
    /// and the replay set are read from disk per request, so `infinitusctl
    /// team grant` takes effect with no IPC. No team, or no identity this
    /// process can read ⇒ no endpoint ⇒ every control route answers 404.
    func refreshTeamControl() {
        let deliver = teamControlDeliver
        let feed = sessionFeed
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let paths = TeamPaths.standard()
            let secrets = TeamSecretsFactory.make(paths: paths)()
            guard let id = paths.teamIDs().sorted().first,
                  let identity = try? TeamClient.identity(paths: paths, secrets: secrets) else {
                self?.teamControl.set(nil, teamDir: nil); return
            }
            let dir = paths.teamDir(id)
            let live: @Sendable () -> [String: Int32] = {
                Dictionary(ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).map { ($0.sessionId, $0.pid) },
                           uniquingKeysWith: { _, newer in newer })
            }
            let endpoint = TeamControl.Endpoint(
                identity: identity,
                roster: {
                    (try? Data(contentsOf: paths.rosterFile(id)))
                        .flatMap { try? CanonicalJSON.decode(Signed<TeamRoster>.self, from: $0) }?.doc
                },
                grants: { TeamGrants.load(teamDir: dir) },
                liveSessions: live,
                execute: { action, text, pid in
                    guard let request = TeamControl.request(action: action, text: text) else {
                        return SessionInput.Reply(outcome: "rejected", detail: "nothing to run for \(action)")
                    }
                    guard let deliver else { return SessionInput.Reply(outcome: "rejected", detail: "app is shutting down") }
                    return mirrorInputQueue.sync { deliver(pid, request, "team") }
                },
                seen: TeamControl.SeenIDs.load(teamDir: dir), limit: TeamControl.RateLimit(), now: { Date() })
            self?.teamControl.tail = TeamControlRoute.Tail { sessionId, since in
                guard let pid = live()[sessionId] else { return nil }
                return feed.call(pid, 200, since: since, wait: 0)
            }
            self?.teamControl.set(endpoint, teamDir: dir)
        }
    }
```

Note: `TeamControl.Endpoint.init` — check its parameter order in `Sources/InfinitusCore/Team/TeamControl.swift` (`identity, roster, grants, liveSessions, execute, seen, limit, now`) and match it. `origin` for the team lane is the literal "team"; AppModel's audit line carries the driver's name (Task 4), so the input log line does not need it.

- [ ] **Step 3: Thread the box and mount the routes**

Add `teamControl: MirrorTeamControlBox,` to `serve` and `receive` parameter lists right after `team: MirrorTeamBox,` (three places: the `serve` signature, its `receive(` call, the `receive` signature, and the recursive `receive(` call at the bottom of the closure — search `team: team,` and add `teamControl: teamControl,` beside each). In `newConnectionHandler`, pass `teamControl: teamControl`.

In `receive`, replace the `teamRoute` computation and its guard:

```swift
            // Team session control (#220): a sealed command or a signed
            // tail header authenticates itself, so neither the pairing
            // token nor the LAN gate applies — a teammate drives over the
            // tunnel too. Without grants the route answers 404.
            let controlRoute = head.map {
                $0.path == TeamControlRoute.commandPath || TeamControlRoute.tailSessionId($0.path) != nil
            } ?? false
            // Peers hold no pairing token: `/team/*` from a LAN address is
            // routed on its own (TeamNearby.respond answers 404 while
            // hidden); everything else — including `/team/*` from a
            // tunnel — still needs the token before a body byte is buffered.
            let teamRoute = !controlRoute && (head.map { $0.path.hasPrefix(TeamNearby.routePrefix) } ?? false)
                && Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
            if let head, !teamRoute, !controlRoute, !MirrorTransport.isAuthorized(head, token: token.current) {
```

and before the existing `if request.path.hasPrefix(TeamNearby.routePrefix), …` dispatch:

```swift
                if request.path == TeamControlRoute.commandPath || TeamControlRoute.tailSessionId(request.path) != nil {
                    controlQueue.async {
                        let response = teamControl.respond(request) ?? MirrorTransport.notFoundResponse()
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
```

- [ ] **Step 4: Build**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Build complete' | tail -n 5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Infinitus/MirrorServer.swift
git commit -m "mirror server: the team control routes are mounted — self-authenticating, verified on one queue, delivered on the input queue, rebuilt with the team standing (#220)"
```

---

### Task 4: AppModel — audit, driven-by, refusal latch, endpoints and grant hints in now.json, rendezvous under the control key

**Files:**
- Create: `Sources/Infinitus/TeamControlFeed.swift`
- Modify: `Sources/Infinitus/AppModel.swift` (wiring ~`:1189`, `:1276-1290`; `teamSources()` `:1578`; `publishRendezvous` `:1742`)
- Modify: `Sources/Infinitus/TeamModel.swift` (add `onLoaded`)
- Modify: `Sources/Infinitus/MacSessionsPopover.swift:24-27`

**Interfaces:**
- Produces: `TeamControlFeed` (`@Published var lines: [Line]`, `Line {id, at, driver, session, action, outcome, detail}`); `AppModel.teamControlFeed`, `AppModel.drivenBy: [String: (name: String, until: Date)]` (keyed by session id), `AppModel.recordTeamControl(_:driverName:)`, `AppModel.controlEndpoints: TeamControl.Endpoints`; `TeamModel.onLoaded: (() -> Void)?`.

- [ ] **Step 1: Feed model** — `Sources/Infinitus/TeamControlFeed.swift`:

```swift
import Foundation
import InfinitusCore

/// The last 50 team-control audit lines (#220 §6), for Settings › Team.
/// Its own small observable so the pane does not re-render on every
/// AppModel change.
@MainActor
final class TeamControlFeed: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let at = Date()
        let driver: String
        let session: String
        let action: String
        let outcome: String
        let detail: String?
        var text: String {
            let why = detail.map { " — \($0)" } ?? ""
            return "\(driver) · \(action) · \(session) · \(outcome)\(why)"
        }
    }
    @Published private(set) var lines: [Line] = []

    func append(_ line: Line) {
        lines.append(line)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
    }
}
```

- [ ] **Step 2: AppModel state and recorder** — near `eventLog`:

```swift
    /// Team session control (#220): the audit feed and who is driving
    /// which session (by session id) until when — read at render time,
    /// no timer.
    let teamControlFeed = TeamControlFeed()
    @Published var drivenBy: [String: (name: String, until: Date)] = [:]
    /// One "your commands are failing" notification per driver per hour.
    private var controlRefusalNotified: [String: Date] = [:]
    static let drivenByWindow: TimeInterval = 60
    static let executedOutcomes: Set<String> = ["delivered", "running", "captured"]
    static let notifiedRefusals: Set<String> = ["expired", "replayed", "notLive", "rateLimited", "badRequest"]

    func recordTeamControl(_ audit: TeamControl.Audit, driverName: String?) {
        let driver = driverName ?? String(audit.driver.prefix(8))
        let project = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
            .first { $0.sessionId == audit.session }.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? audit.session
        let line = TeamControlFeed.Line(driver: driver, session: project, action: audit.action, outcome: audit.outcome, detail: audit.detail)
        teamControlFeed.append(line)
        logEvent("team-control", icon: "person.2", line.text)
        if Self.executedOutcomes.contains(audit.outcome) {
            drivenBy[audit.session] = (driver, Date().addingTimeInterval(Self.drivenByWindow))
        }
        if driverName != nil, Self.notifiedRefusals.contains(audit.outcome),
           controlRefusalNotified[audit.driver].map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            controlRefusalNotified[audit.driver] = Date()
            notify("\(driver)'s commands are failing: \(audit.outcome)")
        }
    }

    /// Where a teammate reaches this Mac right now (#220 §5.1), for now.json.
    var controlEndpoints: TeamControl.Endpoints {
        var e = TeamControl.Endpoints()
        if let port = mirrorServer.port, let lan = MirrorPairing.lanAddress(in: LocalAddresses.ipv4()) { e.lan = "\(lan):\(port)" }
        if namedTunnel.connected { e.hostname = namedTunnel.hostname }
        if quickTunnel.url != nil, let kid = team.kid, let id = team.paths.teamIDs().sorted().first {
            e.rendezvous = TeamControl.rendezvousKey(team: id, kid: kid)
        }
        return e
    }
```

(`TeamControl.Endpoints` needs a no-argument init: if its `init` is memberwise-only, add `public init(lan: String? = nil, hostname: String? = nil, rendezvous: String? = nil)` in `TeamControl.swift`.)

- [ ] **Step 3: Wiring** — after `mirrorServer.log = …`:

```swift
        mirrorServer.teamControl.onAudit = { [weak self] audit, name in
            Task { @MainActor in self?.recordTeamControl(audit, driverName: name) }
        }
        team.onLoaded = { [weak self] in self?.mirrorServer.refreshTeamControl() }
```

In `TeamModel`, next to `var gate`: `var onLoaded: (() -> Void)?`, and at the end of `load()`'s Task (after the `withAnimation` block, inside `do`): `onLoaded?()`.

In `teamSources()`, after `s.crashes = crashStore.list()`:

```swift
        s.endpoints = controlEndpoints
        if let id = team.paths.teamIDs().sorted().first {
            let hints = TeamGrants.load(teamDir: team.paths.teamDir(id)).hints
            s.grantsTo = hints.isEmpty ? nil : hints
        }
```

`publishRendezvous`: rename the body into `publish(url, at target: URL, label: String)` and call it twice:

```swift
    func publishRendezvous(_ url: String) {
        guard mirrorRendezvousEnabled else { return }
        if let target = MirrorRendezvous.url(token: mirrorPairToken) { publish(url, at: target, label: "tunnel address") }
        // #220: teammates derive this key from the roster alone.
        if let key = controlEndpoints.rendezvous, let target = MirrorRendezvous.url(key: key) {
            publish(url, at: target, label: "team control address")
        }
    }

    private func publish(_ url: String, at target: URL, label: String) {
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = MirrorRendezvous.publishBody(url: url)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if code == 204 {
                    self?.logEvent("other", icon: "mappin", "\(label) published to infinitus.run")
                } else {
                    let why = error?.localizedDescription ?? "HTTP \(code)"
                    self?.logEvent("other", icon: "exclamationmark.triangle", "rendezvous publish failed (\(label)): \(why)")
                }
            }
        }.resume()
    }
```

- [ ] **Step 4: The caption** — `MacSessionsPopover.swift`, right after `SessionListCard(live: live, progress: model.sessionProgress, births: model.sessionBirths)`:

```swift
            let driving = model.drivenBy.filter { $0.value.until > Date() }
            if !driving.isEmpty {
                ForEach(driving.keys.sorted(), id: \.self) { id in
                    let project = live.sessions.first { $0.sessionId == id }.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? id
                    Label("\(driving[id]!.name) is driving \(project)", systemImage: "person.2")
                        .font(PopupFont.caption2).foregroundStyle(.secondary)
                }
            }
```

(`live` is the popover's `LiveSessions`; if its rows expose the id under another name, use that — check `Sources/InfinitusCore/LiveSessions.swift` for the record type; it is `ClaudeSessionRecord` with `sessionId` and `cwd`.)

- [ ] **Step 5: Build + tests**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Build complete' | tail -n 5 && swift test --filter 'TeamPublisherTests' 2>&1 | grep -E 'Executed|error' | tail -n 2`
Expected: `Build complete!`, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Infinitus/TeamControlFeed.swift Sources/Infinitus/AppModel.swift Sources/Infinitus/TeamModel.swift Sources/Infinitus/MacSessionsPopover.swift Sources/InfinitusCore/Team/TeamControl.swift
git commit -m "team control: every command is audited, the sessions popover says who is driving, now.json carries endpoints and grant hints, the tunnel address is published under the team key (#220)"
```

---

### Task 5: Grants in TeamModel and Settings › Team

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift` (`@Published grants`, `load()` tuple, `addGrant`, `revokeGrant`)
- Modify: `Sources/Infinitus/TeamPane.swift` (`controlSection`, `@State showGrant`, `.sheet`)
- Create: `Sources/Infinitus/TeamGrantSheet.swift`
- Modify: `Sources/Infinitus/InfinitusApp.swift:267`

**Interfaces:**
- Consumes: `TeamGrants.load/save/add/remove`, `TeamControlFeed`.
- Produces: `TeamModel.grants: TeamGrants`, `TeamModel.addGrant(audience:sessions:capabilities:) async`, `TeamModel.revokeGrant(id:) async`; `TeamPane(team:lock:feed:)`.

- [ ] **Step 1: TeamModel**

Add `@Published private(set) var grants = TeamGrants()` beside `shares`. In `load()`, the `run` closure's tuple gains a ninth element `TeamGrants` (`TeamGrants.load(teamDir: dir)`, and `TeamGrants()` on the not-in-team early return); assign `grants = result.8` in the `withAnimation` block. Add beside `setShare`:

```swift
    /// Team session control (#220): who may drive which of my sessions.
    func addGrant(audience: TeamRoster.ShareTarget, sessions: TeamGrants.Sessions, capabilities: Set<String>) async {
        await action("Saving…") { paths, secrets in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var grants = TeamGrants.load(teamDir: dir)
            grants.add(audience: audience, sessions: sessions, capabilities: capabilities, now: Int(Date().timeIntervalSince1970))
            try grants.save(teamDir: dir)
        }
    }

    func revokeGrant(id: String) async {
        await action("Saving…") { paths, secrets in
            guard let team = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(team)
            var grants = TeamGrants.load(teamDir: dir)
            _ = grants.remove(id: id)
            try grants.save(teamDir: dir)
        }
    }
```

- [ ] **Step 2: The sheet** — `Sources/Infinitus/TeamGrantSheet.swift`:

```swift
import SwiftUI
import InfinitusCore

/// "Add grant" (#220 §7.1): who, which sessions, what they may do.
struct TeamGrantSheet: View {
    @ObservedObject var team: TeamModel
    let snap: TeamSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var audienceTag = "leaders"
    @State private var pickedKids: Set<String> = []
    @State private var allSessions = true
    @State private var pickedSessions: Set<String> = []
    @State private var capabilities: Set<String> = [TeamGrants.view]
    @State private var live: [(id: String, label: String)] = []

    static let meanings: [(String, String)] = [
        (TeamGrants.view, "read the session's live feed"),
        (TeamGrants.send, "type a prompt into the session"),
        (TeamGrants.approve, "answer a tool prompt with Yes or Esc"),
        (TeamGrants.mode, "switch the session's mode"),
        (TeamGrants.resume, "nudge a stalled session"),
        (TeamGrants.key, "press a single key (y, n, 1–9, enter, esc)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let teammates drive your sessions").font(.headline)
            Picker("Who", selection: $audienceTag) {
                Text("Leaders").tag("leaders")
                Text("Whole team").tag("team")
                Text("Only these members").tag("members")
            }
            if audienceTag == "members" {
                ForEach(snap.members.filter { !$0.isMe }) { m in
                    Toggle(m.name, isOn: Binding(get: { pickedKids.contains(m.kid) },
                                                 set: { on in if on { pickedKids.insert(m.kid) } else { pickedKids.remove(m.kid) } }))
                }
            }
            Picker("Sessions", selection: $allSessions) {
                Text("All sessions, now and later").tag(true)
                Text("Only the ones I pick").tag(false)
            }
            if !allSessions {
                if live.isEmpty { Text("No live sessions right now.").font(.caption).foregroundStyle(.secondary) }
                ForEach(live, id: \.id) { s in
                    Toggle(s.label, isOn: Binding(get: { pickedSessions.contains(s.id) },
                                                  set: { on in if on { pickedSessions.insert(s.id) } else { pickedSessions.remove(s.id) } }))
                }
            }
            Text("What they may do").font(.subheadline)
            ForEach(Self.meanings, id: \.0) { cap, meaning in
                Toggle(isOn: Binding(get: { capabilities.contains(cap) },
                                     set: { on in if on { capabilities.insert(cap) } else { capabilities.remove(cap) } })) {
                    VStack(alignment: .leading) { Text(cap); Text(meaning).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add grant") {
                    Task { await team.addGrant(audience: audience, sessions: sessions, capabilities: capabilities); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            live = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
                .map { ($0.sessionId, ($0.name ?? URL(fileURLWithPath: $0.cwd).lastPathComponent)) }
        }
    }

    private var audience: TeamRoster.ShareTarget {
        switch audienceTag {
        case "team": .team
        case "members": .members(pickedKids.sorted())
        default: .leaders
        }
    }
    private var sessions: TeamGrants.Sessions { allSessions ? .all : .some(pickedSessions.sorted()) }
    private var valid: Bool {
        !capabilities.isEmpty && (audienceTag != "members" || !pickedKids.isEmpty) && (allSessions || !pickedSessions.isEmpty)
    }
}
```

- [ ] **Step 3: The pane** — `TeamPane`: add `@ObservedObject var feed: TeamControlFeed` after `lock`, `@State private var showGrant = false`, `.sheet(isPresented: $showGrant) { if let snap = team.snapshot { TeamGrantSheet(team: team, snap: snap) } }` beside the other sheets, and `controlSection(snap)` right after `sharingSection(snap)` in the section list:

```swift
    private func controlSection(_ snap: TeamSnapshot) -> some View {
        Section("Session control") {
            if team.grants.grants.isEmpty {
                Text("Nobody can drive your sessions.").foregroundStyle(.secondary)
            }
            ForEach(team.grants.grants) { g in
                HStack {
                    Text("\(audienceLabel(g.audience, snap)) · \(sessionsLabel(g.sessions)) · \(g.capabilities.sorted().joined(separator: ", "))")
                    Spacer()
                    Button("Remove") { Task { await team.revokeGrant(id: g.id) } }.controlSize(.small)
                }
            }
            Button("Add grant…") { showGrant = true }
            Text("A grant lets the people named send prompts, answer tool prompts or switch modes on the sessions named — from their Mac or `infinitusctl`. Every command is logged below.")
                .font(.caption).foregroundStyle(.secondary)
            if !feed.lines.isEmpty {
                DisclosureGroup("Recent commands") {
                    ForEach(feed.lines.suffix(50).reversed()) { line in
                        HStack {
                            Text(line.text).font(.caption)
                            Spacer()
                            Text(line.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func audienceLabel(_ t: TeamRoster.ShareTarget, _ snap: TeamSnapshot) -> String {
        switch t {
        case .off: "nobody"
        case .leaders: "leaders"
        case .team: "whole team"
        case .members(let kids): kids.map { kid in snap.members.first { $0.kid == kid }?.name ?? String(kid.prefix(8)) }.joined(separator: ", ")
        }
    }
    private func sessionsLabel(_ s: TeamGrants.Sessions) -> String {
        switch s {
        case .all: "all sessions"
        case .some(let ids): ids.count == 1 ? "1 session" : "\(ids.count) sessions"
        }
    }
```

`TeamGrants.Grant` must be `Identifiable` (`id` exists; add `: Identifiable` to its declaration in `TeamGrants.swift` if missing).

`InfinitusApp.swift:267`: `TeamPane(team: model.team, lock: model.lock, feed: model.teamControlFeed)`. Add `"control"`, `"grant"`, `"drive"` to that tab's `keywords`.

- [ ] **Step 4: Build**

Run: `swift build --product Infinitus 2>&1 | grep -E 'error|Build complete' | tail -n 5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Infinitus/TeamModel.swift Sources/Infinitus/TeamPane.swift Sources/Infinitus/TeamGrantSheet.swift Sources/Infinitus/InfinitusApp.swift Sources/InfinitusCore/Team/TeamGrants.swift
git commit -m "settings › team: a Session control section — grants with an add sheet, remove, the empty state and the recent-commands feed (#220)"
```

---

### Task 6: CLI `team grant | revoke | grants`

**Files:**
- Create: `Sources/InfinitusCLI/TeamControlCommand.swift`
- Modify: `Sources/InfinitusCLI/TeamCommand.swift:9-42` (usage), `:80` (dispatch), `:110` (gate list is inside the new file)

**Interfaces:**
- Produces: `runTeamControl(_ args: [String]) -> Int32?` (nil = not ours), `teamControlUsage() -> String`.

- [ ] **Step 1: The file**

```swift
import Foundation
import InfinitusCore

// `infinitusctl team grant | revoke | grants` (#220 §7.3): who may drive
// which of this machine's sessions. Writes <teamDir>/grants.json, which
// the Mac's grantor endpoint reads per request — no socket needed.

func teamControlUsage() -> String {
    """
           infinitusctl team grant <leaders|team|kid,…> [--sessions a,b] [--view] [--send] [--approve] [--mode] [--resume] [--key] [--team <id>]
               let those people drive the sessions named (default: all) with the capabilities flagged
           infinitusctl team revoke <grant id> [--team <id>]
           infinitusctl team grants [--json] [--team <id>]

    """
}

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(value) else { exit(controlFail("could not encode the result")) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func controlFail(_ message: String, code: Int32 = 1) -> Int32 {
    let text = message.hasPrefix("usage:") ? message : "error: \(TeamGit.masked(message))"
    FileHandle.standardError.write(Data((text + "\n").utf8))
    return code
}

/// nil when `args` is not one of ours.
func runTeamControl(_ args: [String]) -> Int32? {
    guard let sub = args.first, ["grant", "revoke", "grants"].contains(sub) else { return nil }
    let capabilityFlags: Set<String> = [TeamGrants.view, TeamGrants.send, TeamGrants.approve, TeamGrants.mode, TeamGrants.resume, TeamGrants.key]
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if capabilityFlags.contains(key) || key == "json" { flags.insert(key); i += 1; continue }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return controlFail("--\(key) needs a value\n\n\(teamControlUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    if ["grant", "revoke"].contains(sub),
       case .needsLock(let why) = TeamGate.check(lockEnabled: LockSetting.enabledOnThisMachine()) {
        return controlFail("\(why) (Infinitus › Settings › Lock)")
    }
    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)
    do {
        let ids = paths.teamIDs()
        guard let id = options["team"] ?? (ids.count == 1 ? ids[0] : nil) else {
            return controlFail(ids.isEmpty ? "no team on this machine (create or request one)"
                                           : "several teams: pass --team <id> (\(ids.joined(separator: ", ")))")
        }
        guard TeamClient.isPathSegment(id) else { return controlFail("--team takes a team id (one path segment)", code: 2) }
        let client = try TeamClient.open(id: id, paths: paths, secrets: secrets)
        let teamDir = paths.teamDir(id)
        var grants = TeamGrants.load(teamDir: teamDir)
        switch sub {
        case "grant":
            guard let audience = TeamShares.parseTarget(Array(positional.prefix(1))), audience != .off else {
                return controlFail(teamUsage() + teamControlUsage(), code: 2)
            }
            let capabilities = flags.intersection(capabilityFlags)
            guard !capabilities.isEmpty else { return controlFail("pick at least one of --view --send --approve --mode --resume --key", code: 2) }
            if case .members(let kids) = audience {
                let known = Set(client.roster?.doc.everyone.map(\.keys.kid) ?? [])
                for kid in kids where !known.contains(kid) { return controlFail("unknown kid \(kid)", code: 2) }
            }
            let sessions: TeamGrants.Sessions = options["sessions"].map { .some($0.split(separator: ",").map(String.init)) } ?? .all
            let grant = grants.add(audience: audience, sessions: sessions, capabilities: capabilities,
                                   now: Int(Date().timeIntervalSince1970))
            try grants.save(teamDir: teamDir)
            emit(grant)
        case "revoke":
            guard let id = positional.first else { return controlFail(teamUsage() + teamControlUsage(), code: 2) }
            let removed = grants.remove(id: id)
            if removed { try grants.save(teamDir: teamDir) }
            emit(["removed": removed])
        default:
            emit(grants)
        }
        return 0
    } catch {
        return controlFail(error.localizedDescription)
    }
}
```

Check `TeamGrants.add` returns the `Grant` (it does, `@discardableResult`) and that `Grant`, `Sessions` and `TeamGrants` are `Encodable` (they are `Codable`). `.some` sessions: filter empty strings (`.filter { !$0.isEmpty }`).

- [ ] **Step 2: Dispatch and usage**

`TeamCommand.swift` line 80, after the nearby line: `if let code = runTeamControl(args) { return code }   // grant | revoke | grants (TeamControlCommand.swift)`. In `teamUsage()`, append `teamControlUsage()` the way the string ends: change the closing of `teamUsage` so it returns the literal `+ teamControlUsage()` (if `teamNearbyUsage()` is already appended there, add `+ teamControlUsage()` after it; otherwise append at the end of the `"""` string expression).

- [ ] **Step 3: Build both platforms' targets**

Run: `swift build --product infinitusctl 2>&1 | grep -E 'error|Build complete' | tail -n 3`
Expected: `Build complete!`

Smoke (in-process, its own team dir):

```bash
export INFINITUS_TEAM_DIR=/tmp/tc-cli INFINITUS_LOCK_GATE=open
.build/debug/infinitusctl team grants; echo "exit $?"
```
Expected: `error: no team on this machine …`, exit 1.

- [ ] **Step 4: Commit**

```bash
git add Sources/InfinitusCLI/TeamControlCommand.swift Sources/InfinitusCLI/TeamCommand.swift
git commit -m "cli: infinitusctl team grant | revoke | grants write the grants file the Mac's endpoint reads (#220)"
```

---

### Task 7: e2e step, release lines, verification, handoff

**Files:**
- Modify: `tools/e2e.sh:370` (after `echo "team: ok …"`)
- Modify: `CHANGELOG.md` (Unreleased › Team (preview), top bullet), `README.md:141-144`, `site/public/index.html:525-531`, `site/public/llms.txt:22-24`

- [ ] **Step 1: e2e step** (insert after `echo "team: ok (leader Ann, member Bo $KID)"`):

```sh
# --- team control (#220, grantor) ------------------------------------------
# Bo lets leaders send to one session; the hint rides Bo's now.json and
# Ann's snapshot says what Bo lets her do. Driving itself lands with the
# driver PR (the mirror listener is off in mock mode; see the plan).
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grant leaders --sessions s-e2e --send \
    | expect "d['audience']=='leaders' and d['sessions']==['s-e2e'] and d['capabilities']==['send']" || fail "team grant"
GRANT="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grants | json "d['grants'][0]['id']")"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish --projects "$SOCKDIR/fixture/projects" >/dev/null || fail "publish with a grant"
"$CTL" team-fetch | expect "[m for m in d['members'] if m['name']=='Bo'][0].get('controls')==['send']" || fail "the grant hint did not reach the leader's snapshot"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team revoke "$GRANT" | expect "d['removed']" || fail "team revoke"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grants | expect "d['grants']==[]" || fail "revoke left the grant"
echo "team control: ok"
```

If `TeamGrants`' audience encodes `.leaders` differently from the string `"leaders"` (see `TeamRoster.ShareTarget`'s `Codable`), adjust the first `expect` to the real shape (`TeamGrantsTests.testFileRoundTripAndEmptyDefault` shows `"audience":["<kid>"]` for members).

- [ ] **Step 2: Release lines** (one line each)

CHANGELOG, first bullet under `### Team (preview)` in `## Unreleased`:

```
- Team session control on the Mac, grantor side: grant teammates view, send, approve, mode, resume or key on chosen sessions from Settings › Team or `infinitusctl team grant`; commands arrive at the mirror server, every one is audited, and the sessions popover says who is driving (#220).
```

README, after the "Your team identity" bullet (line ~144):

```
- **Team session control (preview)** — grant teammates the right to read, prompt, approve, switch modes or nudge chosen sessions on your Mac; every command is verified against the roster and the grant, audited, and shown as "<name> is driving" while it happens.
```

`site/public/index.html`, inside the Team (preview) card's `<p>` (after "…what it costs per member, repo and model."), one sentence: `Grant a teammate the right to prompt, approve or steer a chosen session on your Mac; every command is verified, audited and shown while it happens.`

`site/public/llms.txt`, a new line after line 24:

```
- Team (preview), session control: a member grants leaders, the whole team or named members the right to view, send, approve, mode, resume or key on all or chosen sessions (Settings › Team or `infinitusctl team grant`); commands are sealed envelopes verified against the roster and the grant on the member's own Mac, every one is audited, and the driven session shows who is driving.
```

- [ ] **Step 3: Verification**

```bash
swift build --product Infinitus 2>&1 | tail -n 1
swift build --product infinitusctl 2>&1 | tail -n 1
swift test 2>&1 | grep -E 'Executed .* tests' | tail -n 1
INFINITUS_CONTROL_SOCKET=/tmp/mac.sock tools/e2e.sh 2>&1 | tail -n 4
```

Expected: two `Build complete!`, `0 failures`, `team control: ok` and `E2E PASS`. Tell Infi "e2e running" before and "e2e done" after.

- [ ] **Step 4: Merge main, push, handoff**

```bash
git fetch -q origin && git merge --no-edit origin/main   # CHANGELOG add/add: keep both
git log --format='%h %(trailers:key=Co-Authored-By,valueonly)' origin/main..HEAD   # every line has the trailer; amend the merge if not
swift build --product Infinitus 2>&1 | tail -n 1 && swift test --filter 'TeamControl|TeamGrants|TeamSnapshot|TeamPublisher' 2>&1 | grep Executed | tail -n 1
git push -u origin control-mac
```

Message Infi: `merge control-mac at <sha> — --merge (multi-commit), no ios/`. PR 2 (#276) must be merged first; if the branch is DIRTY, merge origin/main and re-send.
