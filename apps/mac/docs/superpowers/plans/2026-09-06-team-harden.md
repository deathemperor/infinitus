# Team — Hardening (#161) + Site/README step 10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close #161 (an invite's nonce no longer travels in cleartext in the join request; the request carries a digest bound to the requester's kid, so a copied request cannot be auto-approved under another identity), turn auto-approval of invited requests back on by default, fix the CLI parser's `--remote` flag, and ship spec step 10: the site, README and llms.txt describe Team as it actually is.

**Architecture:** `TeamRequest.nonce` becomes `TeamRequest.proof` = base64 of `SHA256("infinitus-invite-v1" ‖ nonce ‖ 0x00 ‖ kid)`. `TeamInvites.matches` recomputes the digest for every unexpired stored nonce against `request.keys.kid` and returns the matching nonce (so the leader can consume it). `TeamModel.autoApprove` consumes what `matches` returns and defaults to on.

**Tech Stack:** Swift 6, swift-crypto (`Crypto.SHA256`), XCTest; static HTML/Markdown for the docs.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` — §6.2 (invite auto-approve), §10 (threat model: a credential holder "cannot read any content"), §12 step 10. Issue #161.

## Global Constraints

- **File ownership (three streams in parallel):**
  - This stream MAY edit: `Sources/InfinitusCore/Team/TeamRequest.swift`, `TeamInvites.swift`, `TeamClient.swift` (ONLY the `request(code:…)` function, line ~118), `Base32.swift` (one comment line), `Sources/Infinitus/TeamModel.swift` (ONLY lines 36–70 — the `autoApprove` property/init/setter — and lines 211–226 — `static func autoApprove`), `Sources/InfinitusCLI/main.swift`, tests `Tests/InfinitusCoreTests/TeamInvitesTests.swift`, `TeamMembershipTests.swift` (if a nonce assertion needs updating), `site/public/index.html`, `site/public/llms.txt`, `README.md`, `CHANGELOG.md` (lines under `## 0.4.4 (unreleased)` → `### Team (preview)`).
  - This stream MUST NOT edit: any other line of `TeamModel.swift`, `TeamPane.swift` (the switch caption there is the pane stream's), `TeamNearby*.swift`, `TeamIdentityExport.swift`, `TeamCommand.swift`, `MirrorServer.swift`, `AppModel.swift`, `InfinitusApp.swift`, anything under `ios/`, `RowTheme.swift`, `tools/e2e.sh`.
- Fully qualified `Crypto.SHA256` (Foundation has no SHA256, but the module name avoids any ambiguity with CryptoKit on Apple platforms). Canonical JSON for anything signed.
- Nothing about a nonce is ever logged; the proof is the only thing stored.
- No behaviour change for team codes (no nonce → no proof → never auto-approved).
- Never inject test messages into real Claude sessions. No subagents from implementers.
- Every commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commit by explicit path.
- Gates: `swift build --product Infinitus`, `swift build --product infinitusctl`, `swift test`. `tools/e2e.sh` runs at integration (the e2e's team section uses a team code, not an invite — unaffected).
- Docs: one feature, one line in the CHANGELOG; the site and README describe what ships, never internals or workflow.

---

### Task 1: The proof (core) — #161

**Files:**
- Modify: `Sources/InfinitusCore/Team/TeamRequest.swift`
- Modify: `Sources/InfinitusCore/Team/TeamInvites.swift` (`matches`)
- Modify: `Sources/InfinitusCore/Team/TeamClient.swift` line ~118 only
- Modify: `Sources/InfinitusCore/Team/Base32.swift` line 4 comment
- Test: `Tests/InfinitusCoreTests/TeamInvitesTests.swift`

**Interfaces:**
- Produces:

```swift
public struct TeamRequest {  // nonce: String? is REMOVED
    public var proof: String?
    public init(keys: TeamKeys, name: String, devices: [String], platform: String, at: Int, proof: String? = nil)
    /// base64(SHA256("infinitus-invite-v1" ‖ nonce ‖ 0x00 ‖ kid))
    public static func proof(nonce: String, kid: String) -> String
}
public struct TeamInvites {
    /// The stored nonce this request proves it was invited with, or nil.
    public func matches(_ request: TeamRequest, now: Int) -> String?
}
```

- [ ] **Step 1: Rewrite the failing tests** in `TeamInvitesTests`:

```swift
    func testMatchesOnlyUnexpiredIssuedNoncesBoundToTheRequester() {
        var book = TeamInvites()
        book.add(nonce: "n1", expires: 1_000)
        book.add(nonce: "n2", expires: 2_000)
        let ann = TeamIdentity.random().keys, eve = TeamIdentity.random().keys
        func req(_ keys: TeamKeys, _ nonce: String?) -> TeamRequest {
            TeamRequest(keys: keys, name: "x", devices: [], platform: "macos", at: 1,
                        proof: nonce.map { TeamRequest.proof(nonce: $0, kid: keys.kid) })
        }
        XCTAssertEqual(book.matches(req(ann, "n1"), now: 999), "n1")
        XCTAssertNil(book.matches(req(ann, "n1"), now: 1_001), "expired")
        XCTAssertNil(book.matches(req(ann, "n3"), now: 1), "never issued")
        XCTAssertNil(book.matches(req(ann, nil), now: 1), "a team code has no proof")
        // #161: Eve copies Ann's pending request's proof into her own request.
        var stolen = req(eve, nil); stolen.proof = req(ann, "n1").proof
        XCTAssertNil(book.matches(stolen, now: 1), "a proof is bound to the kid that made it")
        book.consume("n2")
        XCTAssertNil(book.matches(req(ann, "n2"), now: 1), "one-time")
        book.add(nonce: "n4", expires: 5)
        book.prune(now: 10)
        XCTAssertEqual(book.nonces, ["n1": 1_000])
    }

    func testProofIsDeterministicAndKidBound() {
        let a = TeamRequest.proof(nonce: "n", kid: "k1")
        XCTAssertEqual(a, TeamRequest.proof(nonce: "n", kid: "k1"))
        XCTAssertNotEqual(a, TeamRequest.proof(nonce: "n", kid: "k2"))
        XCTAssertNotEqual(a, TeamRequest.proof(nonce: "m", kid: "k1"))
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
        XCTAssertFalse(a.contains("n"), "the nonce never appears in the proof")   // 'n' may appear in base64; keep only if the assertion is meaningful — otherwise drop this line
    }
```

Drop the last assertion (base64 output can contain any letter). Keep `testNonceIsRandomBase32`, `testRoundTripsThroughTheTeamDir`, `testCodeCarriesTheNonceAndAutoApprovalIsTheLeadersDecision` unchanged (they test the code, not the request). Add to the last one, after the existing assertions, a request round trip:

```swift
        // The joiner's request carries the proof, never the nonce (#161).
        let joinerPaths = TeamPaths(base: paths.base.appendingPathComponent("joiner"))
        let joinerSecrets = FileSecrets(dir: joinerPaths.secretsDir)
        let joiner = try TeamClient.request(code: text, name: "Bo", devices: [], platform: "linux", paths: joinerPaths, secrets: joinerSecrets, now: 102)
        _ = try client.fetch()
        let pending = try XCTUnwrap(try client.requests().first)
        XCTAssertEqual(pending.doc.proof, TeamRequest.proof(nonce: nonce, kid: joiner.identity.kid))
        var book = TeamInvites(); book.add(nonce: nonce, expires: 700)
        XCTAssertEqual(book.matches(pending.doc, now: 103), nonce)
        XCTAssertFalse(try CanonicalJSON.encode(pending.doc).contains(Data(nonce.utf8)), "nonce not in the stored request")
```

(`joiner.identity` — confirm the property is accessible from tests via `@testable`; else read the kid from `joinerSecrets` as `TeamModel.load` does. `Data.contains(Data)` — if unavailable, compare `String(decoding:as:).contains(nonce)`.)

- [ ] **Step 2: Run** `swift test --filter TeamInvitesTests` → compile FAIL (no `proof`).
- [ ] **Step 3: Implement.** `TeamRequest.swift`:

```swift
import Foundation
import Crypto

/// `requests/<kid>.json` (spec §6.2/6.3): a joiner's keys and name,
/// stored as `Signed<TeamRequest>` by the joiner. `proof` binds the
/// invite's nonce to THIS requester (#161): the leader recomputes it per
/// stored nonce; a copied proof under another kid never matches, and the
/// nonce itself never leaves the invite link. nil for team-code requests.
public struct TeamRequest: Codable, Equatable, Sendable {
    public var keys: TeamKeys
    public var name: String
    public var devices: [String]
    public var platform: String
    public var at: Int
    public var proof: String?

    public init(keys: TeamKeys, name: String, devices: [String], platform: String, at: Int, proof: String? = nil) {
        self.keys = keys; self.name = name; self.devices = devices
        self.platform = platform; self.at = at; self.proof = proof
    }

    static let proofDomain = Data("infinitus-invite-v1".utf8)

    /// base64(SHA256(domain ‖ nonce ‖ 0x00 ‖ kid)) — the separator keeps
    /// (nonce, kid) pairs from colliding by concatenation.
    public static func proof(nonce: String, kid: String) -> String {
        var input = proofDomain
        input.append(contentsOf: Data(nonce.utf8))
        input.append(0)
        input.append(contentsOf: Data(kid.utf8))
        return Data(Crypto.SHA256.hash(data: input)).base64EncodedString()
    }
}
```

`TeamInvites.matches`:

```swift
    /// The stored nonce this request proves it was invited with (unexpired), or nil.
    public func matches(_ request: TeamRequest, now: Int) -> String? {
        guard let proof = request.proof else { return nil }
        return nonces.first { nonce, expires in
            expires > now && TeamRequest.proof(nonce: nonce, kid: request.keys.kid) == proof
        }?.key
    }
```

`TeamClient.request` line 118: `… at: now, proof: code.nonce.map { TeamRequest.proof(nonce: $0, kid: me.kid) })`.

`Base32.swift` line 4: replace "Encode only; nothing decodes a kid." with "`decode` below is the inverse, used by recovery keys."

Grep for any other `.nonce` on a `TeamRequest` (`grep -rn "doc.nonce\|request.nonce\|\.nonce" Sources Tests | grep -iv "envelope\|Nonce()\|TeamCode\|IdentityExport\|nonceData\|header.nonce"`); the only app-side use is `TeamModel.autoApprove` (Task 2).

- [ ] **Step 4:** `swift test --filter "TeamInvites|TeamMembership|TeamClient"` → PASS (Task 2 fixes the app target build).
- [ ] **Step 5: Commit** `git add Sources/InfinitusCore/Team/TeamRequest.swift Sources/InfinitusCore/Team/TeamInvites.swift Sources/InfinitusCore/Team/TeamClient.swift Sources/InfinitusCore/Team/Base32.swift Tests/InfinitusCoreTests/TeamInvitesTests.swift && git commit -m "team: a join request proves its invite with SHA256(nonce ‖ kid), never the nonce (#161)"`.

---

### Task 2: `TeamModel.autoApprove` consumes the matched nonce; default on

**Files:**
- Modify: `Sources/Infinitus/TeamModel.swift` — ONLY: the doc comment + `autoApprove` init (lines ~34–39, 62) and `static func autoApprove` (lines ~211–226).

- [ ] **Step 1:** Init: `autoApprove = defaults.object(forKey: Self.autoApproveKey) as? Bool ?? true`. Replace the doc comment above the property (the #161 caveat) with: `/// Approve requests that prove one of this leader's invite nonces (spec §6.2) without a tap. On by default; the proof is bound to the requester's kid (#161), so a copied request cannot ride an invite.`
- [ ] **Step 2:** The static helper's loop:

```swift
        for request in try client.requests() {
            guard let nonce = book.matches(request.doc, now: now) else { continue }
            do { try client.approve(kid: request.doc.keys.kid, now: now) }
            catch is TeamClient.ClientError { continue }
            book.consume(nonce)
            try book.save(teamDir: dir)
        }
```

- [ ] **Step 3:** `swift build --product Infinitus` ok; `swift test` green.
- [ ] **Step 4: Commit** `git add Sources/Infinitus/TeamModel.swift && git commit -m "team: invited requests auto-approve by default again — the proof binds them to the requester (#161)"`.

---

### Task 3: CLI parser — `--remote <url>` takes its value

**Files:**
- Modify: `Sources/InfinitusCLI/main.swift` lines 59–60

- [ ] **Step 1:** Find why `remote` is flag-only: `grep -rn '"remote"' Sources/Infinitus/ControlServer.swift` — line ~356 reads `r.options["status"]` and a `remote:` argument for another command; check which control command takes a bare `--remote` (grep `options\["remote"\]` in ControlServer). If a command uses bare `--remote` as a boolean, keep it flag-only for that command; the parser already knows `command` (line ~50, `let command = …` — confirm the variable name).

```swift
        // `--remote` is a bare flag for <that command> but carries a URL for
        // team-create (the app's fallback to the second positional stays as a belt).
        let flagOnly = command == "team-create" ? ["yes", "local", "status"] : ["yes", "local", "remote", "status"]
```

If no command uses bare `--remote` at all, just remove `"remote"` from the list and say so in the report.

- [ ] **Step 2:** `swift build --product infinitusctl`; smoke without a socket: `.build/debug/infinitusctl team-create X --remote file:///tmp/x.git` → the error is "connection refused"/no socket, not a usage error (the parse succeeded). Commit `git add Sources/InfinitusCLI/main.swift && git commit -m "infinitusctl: team-create --remote takes its URL"`.

---

### Task 4: Site + README + llms.txt (spec §12 step 10) + CHANGELOG

**Files:**
- Modify: `site/public/index.html` ~line 511 (the "Team fleets" card)
- Modify: `README.md` line ~133 (the Team bullet)
- Modify: `site/public/llms.txt` — `## What it does` list
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Site card** — replace the "Team fleets … via iCloud" card with:

```html
      <div class="card"><h3><span class="dot">●</span>Team (preview)</h3>
        <p>A team on any git remote you already have — GitHub, GitLab, a
        bare repo on a NAS. Members publish stats, sessions and chosen
        transcripts end-to-end encrypted to the people they pick; the
        host sees file names and sizes. Leaders get insights: who's on,
        who's blocked, cost per member, repo and model. Invite links, team
        codes, same-network discovery; the phone has a Team tab; Linux
        and Windows join with <code>infinitusctl team</code>.</p></div>
```

Keep the card markup identical to its neighbours (check whether neighbours use `<code>`; if not, drop the tag).

- [ ] **Step 2: README** — replace the single Team bullet with:

```
- **Team (preview)** — a team on any git remote; members publish stats, sessions and chosen transcripts end-to-end encrypted to the people they pick, and leaders see who's on, who's blocked and what it costs per member, repo and model.
- **Joining a team** — invite links and QR, team codes, `infinitus://join`, and same-network discovery; approve from the Mac or the phone; Linux and Windows members use `infinitusctl team` alone.
- **Your team identity** — a local key behind Touch ID / Face ID, a recovery key, a passphrase-sealed export; the phone's Team tab locks behind Face ID.
```

- [ ] **Step 3: llms.txt** — add to `## What it does`:

```
- Team (preview): a team on any git remote; members publish stats, sessions and chosen transcripts end-to-end encrypted to chosen readers (the host sees names and sizes only); leaders get comparison, blockers, cost and hours insights; join by invite link, team code or same-network discovery; a phone Team tab; `infinitusctl team` on Linux/Windows.
```

- [ ] **Step 4: CHANGELOG** — under `## 0.4.4 (unreleased)` → `### Team (preview)` (create after `### Mac` if absent):

```
- An invite link's request now proves the invite without carrying its secret, so a copied request can't ride someone else's invite; invited requests are approved automatically again.
- `infinitusctl team-create --remote <url>` takes the URL as written.
```

- [ ] **Step 5:** `swift test` green. Commit `git add site/public/index.html site/public/llms.txt README.md CHANGELOG.md && git commit -m "docs: Team as it ships — site card, README, llms (spec step 10)"`.

---

## Self-review

- **#161 coverage:** proof (T1), leader recomputation + consume (T1, T2), default flip (T2), tests for theft and expiry (T1). The pane's switch caption is the pane stream's.
- **Type consistency:** `TeamRequest.proof(nonce:kid:)` and `TeamInvites.matches(_:now:) -> String?` used identically across T1 and T2.
- **Ownership:** TeamModel edits confined to the two hunks; no TeamPane/TeamNearby/TeamCommand edits.
