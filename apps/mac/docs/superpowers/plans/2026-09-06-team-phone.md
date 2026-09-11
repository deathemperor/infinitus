# Team — Phone Tab (spec §9 step 8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone gets a Team tab that shows the Mac's team through the mirror — roster, requests, invite, member detail, transcripts, the leaders' aggregates — with approve / decline / join / code from the phone, behind the phone's own biometric lock.

**Architecture:** The phone already receives `TeamSnapshot` inside `MirrorSnapshot.team` (`/snapshot`). Everything else rides a new token-gated route family `/mirror/team/...` on the Mac's MirrorServer (distinct from the LAN-open `/team/*` nearby routes), answered by a new `TeamMirrorHandler` that calls the existing `TeamModel` methods on the main actor. Wire types and paths live in one new core file (`TeamMirror.swift`) shared by Mac and phone. The phone side is two new screens plus a small lock object; existing phone files get one-line touches only.

**Tech Stack:** Swift 6 / SwiftUI, InfinitusCore (shared), Network.framework mirror, LocalAuthentication on iOS, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` — §2.2 (lock), §6.4 last bullet (phone shows Nearby through the mirror: **deferred**, see Global Constraints), §8.4 (members' view), §9 (Phone Team tab), §10 (threat model).

## Global Constraints

- **File ownership (three streams run in parallel on this repo; violating this breaks integration):**
  - This stream MAY edit: `Sources/InfinitusCore/Team/TeamMirror.swift` (new), `Sources/InfinitusCore/RowTheme.swift` (tab tables only), `Sources/Infinitus/TeamMirrorHandler.swift` (new), `Sources/Infinitus/MirrorServer.swift` (one new box + one route branch), `Sources/Infinitus/AppModel.swift` (ONLY an insertion directly after the `mirrorServer.sessionStart.set { … }` block, ~line 1064–1072), `ios/project.yml` (one Info.plist key), `ios/InfinitusMobile/RootView.swift`, `ios/InfinitusMobile/MirrorModel.swift` (one computed property), `ios/InfinitusMobile/NetworkFleetMirror.swift` (wrappers only), `ios/InfinitusMobile/SettingsScreen.swift` (one new Section), new phone files `TeamScreen.swift`, `TeamMemberScreen.swift`, `MobileLock.swift`, tests `Tests/InfinitusCoreTests/TeamMirrorTests.swift` (new) and `RowThemeTests.swift`/`RowThemeLoadingTests.swift` (add an assertion), `CHANGELOG.md` (lines under `## 0.4.4 (unreleased)` → `### Team (preview)`).
  - This stream MUST NOT edit: `Sources/Infinitus/TeamModel.swift`, `TeamPane.swift`, `TeamMemberPane.swift`, `InfinitusApp.swift`, anything under `Sources/InfinitusCore/Team/` other than the new file, `Sources/InfinitusCLI/*`, `tools/e2e.sh`, `site/*`, `README.md`, and Infi3's phone files `ChatHeader.swift`, `SessionFeedScreen.swift`, `SessionsScreen.swift`, `StatsScreen.swift`, anything in `Sources/InfinitusUI/`.
- Engine fully isolated; nothing here touches engine files. Reading Claude Code's own files is fine.
- The pairing token gates every `/mirror/team/*` request (the existing head check already 401s anything outside `/team/*`; the new prefix must NOT start with `/team/`).
- Nothing secret on the wire beyond what the token already protects: team codes/invite links are returned only to a token-holding phone; the identity secret, recovery key and export never cross the mirror.
- Secrets never printed; `TeamSnapshot.remote` is already masked by `TeamSnapshot.maskRemote`.
- Phone lock decision (spec §2.2 says app-wide): **this round locks the Team tab only**, re-locks when the app goes to background, and the join action is disabled until the lock is on. App-wide lock is logged to issue #55 as a follow-up. State this in the CHANGELOG line ("Team tab").
- Nearby lists on the phone (§6.4 last bullet) are **deferred** to the round after the Mac pane's Nearby section lands (#55).
- Never inject test messages into real Claude sessions. No subagents from implementers.
- Every commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commit by explicit path.
- Build gates: `swift build --product Infinitus`, `swift test` (macOS); the phone target is built by the ios CI job (`xcodegen generate` + `xcodebuild`), locally `cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' build` when Xcode is available (skip with a note if not).
- Match existing style (four-space indent, doc comments explaining *why*); no speculative abstractions.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/InfinitusCore/Team/TeamMirror.swift` (new) | Route paths, query parsing, Codable request/reply types shared by Mac and phone. |
| `Sources/Infinitus/TeamMirrorHandler.swift` (new) | `@MainActor` dispatcher: `MirrorTransport.Request` → calls `TeamModel` → JSON `Data?`. |
| `Sources/Infinitus/MirrorServer.swift` | `MirrorTeamMirrorBox` (async handler box) + one route branch for the prefix. |
| `Sources/Infinitus/AppModel.swift` | Sets the box's handler once (after `sessionStart.set`). |
| `ios/InfinitusMobile/NetworkFleetMirror.swift` | `teamGet` / `teamPost` wrappers + typed helpers. |
| `ios/InfinitusMobile/MirrorModel.swift` | `var team: TeamSnapshot?` accessor. |
| `ios/InfinitusMobile/MobileLock.swift` (new) | Face ID / Touch ID lock for the Team tab. |
| `ios/InfinitusMobile/TeamScreen.swift` (new) | Team tab root: locked / not-in-team (join) / in-team (header, requests, members, invite, aggregates). |
| `ios/InfinitusMobile/TeamMemberScreen.swift` (new) | Member detail: period picker, stat tiles, sessions, transcript list. |
| `ios/InfinitusMobile/RootView.swift` | The fourth tab + badge. |
| `ios/InfinitusMobile/SettingsScreen.swift` | Section "Team": lock toggle. |
| `ios/project.yml` | `NSFaceIDUsageDescription`. |
| `Sources/InfinitusCore/RowTheme.swift` | `"team"` in the plain and per-theme tab tables. |

---

### Task 1: `TeamMirror` wire types and paths (core) + tests

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamMirror.swift`
- Test: `Tests/InfinitusCoreTests/TeamMirrorTests.swift`

**Interfaces:**
- Produces (used by Tasks 2, 3, 5, 6):

```swift
public enum TeamMirror {
    public static let prefix = "/mirror/team"
    public static let aggregatesPath = "/mirror/team/aggregates"   // GET → [String: TeamDocs.Aggregates]
    public static let memberPath = "/mirror/team/member"           // GET ?kid=&period= → MemberReply
    public static let transcriptPath = "/mirror/team/transcript"   // GET ?kid=&session= → [SessionFeedItem]
    public static let approvePath = "/mirror/team/approve"         // POST KidRequest → ActionReply
    public static let declinePath = "/mirror/team/decline"         // POST KidRequest → ActionReply
    public static let joinPath = "/mirror/team/join"               // POST JoinRequest → ActionReply
    public static let codePath = "/mirror/team/code"               // POST CodeRequest → ActionReply(code:)

    public struct KidRequest: Codable, Equatable, Sendable { public var kid: String }
    public struct JoinRequest: Codable, Equatable, Sendable { public var code: String; public var name: String }
    public struct CodeRequest: Codable, Equatable, Sendable { public var days: Int; public var invite: Bool }
    public struct ActionReply: Codable, Equatable, Sendable { public var ok: Bool; public var error: String?; public var code: String? }
    public struct MemberReply: Codable, Equatable, Sendable {
        public var kid: String; public var name: String
        public var summary: Stats.Summary?
        public var sessions: [TeamDocs.SessionRow]
        public var transcripts: [String]   // session ids that have a transcript
    }
    public static func memberQuery(kid: String, period: Stats.Period) -> String
    public static func transcriptQuery(kid: String, session: String) -> String
}
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class TeamMirrorTests: XCTestCase {
    func testPathsSitOutsideTheNearbyPrefixAndUnderTheirOwn() {
        for p in [TeamMirror.aggregatesPath, TeamMirror.memberPath, TeamMirror.transcriptPath,
                  TeamMirror.approvePath, TeamMirror.declinePath, TeamMirror.joinPath, TeamMirror.codePath] {
            XCTAssertTrue(p.hasPrefix(TeamMirror.prefix + "/"), p)
            XCTAssertFalse(p.hasPrefix(TeamNearby.routePrefix), "\(p) would be token-exempt from the LAN")
        }
    }

    func testQueriesRoundTripThroughTheRequestParser() {
        let q = TeamMirror.memberQuery(kid: "abc", period: .month)
        let r = MirrorTransport.Request(method: "GET", target: TeamMirror.memberPath + "?" + q, headers: [:], body: Data())
        XCTAssertEqual(r.path, TeamMirror.memberPath)
        XCTAssertEqual(r.query("kid"), "abc")
        XCTAssertEqual(r.query("period"), "month")
        let t = MirrorTransport.Request(method: "GET", target: TeamMirror.transcriptPath + "?" + TeamMirror.transcriptQuery(kid: "k", session: "s 1"), headers: [:], body: Data())
        XCTAssertEqual(t.query("session"), "s 1", "percent-encoded on the way out, decoded on the way in")
    }

    func testRepliesAreCodable() throws {
        let reply = TeamMirror.ActionReply(ok: false, error: "Turn on biometric unlock first", code: nil)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.ActionReply.self, from: try JSONEncoder().encode(reply)), reply)
        let m = TeamMirror.MemberReply(kid: "k", name: "Ann", summary: nil, sessions: [], transcripts: ["s1"])
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.MemberReply.self, from: try JSONEncoder().encode(m)), m)
    }
}
```

- [ ] **Step 2: Run it** — `swift test --filter TeamMirrorTests` → FAIL (no `TeamMirror`).

- [ ] **Step 3: Implement** `Sources/InfinitusCore/Team/TeamMirror.swift`:

```swift
import Foundation

/// The phone's view of the Mac's team (spec §9, step 8): a token-gated
/// route family on the mirror, deliberately OUTSIDE `TeamNearby.routePrefix`
/// (`/team/*` answers LAN peers without the pairing token). The Mac side
/// answers from `TeamModel`; the phone side is `NetworkFleetMirror`.
public enum TeamMirror {
    public static let prefix = "/mirror/team"
    public static let aggregatesPath = prefix + "/aggregates"
    public static let memberPath = prefix + "/member"
    public static let transcriptPath = prefix + "/transcript"
    public static let approvePath = prefix + "/approve"
    public static let declinePath = prefix + "/decline"
    public static let joinPath = prefix + "/join"
    public static let codePath = prefix + "/code"

    public struct KidRequest: Codable, Equatable, Sendable {
        public var kid: String
        public init(kid: String) { self.kid = kid }
    }
    public struct JoinRequest: Codable, Equatable, Sendable {
        public var code: String
        public var name: String
        public init(code: String, name: String) { self.code = code; self.name = name }
    }
    public struct CodeRequest: Codable, Equatable, Sendable {
        public var days: Int
        /// true → an invite link (one-time nonce, auto-approved by the leader's Mac); false → a team code.
        public var invite: Bool
        public init(days: Int, invite: Bool) { self.days = days; self.invite = invite }
    }
    public struct ActionReply: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var code: String?
        public init(ok: Bool, error: String? = nil, code: String? = nil) { self.ok = ok; self.error = error; self.code = code }
    }
    public struct MemberReply: Codable, Equatable, Sendable {
        public var kid: String
        public var name: String
        public var summary: Stats.Summary?
        public var sessions: [TeamDocs.SessionRow]
        /// Session ids with a readable transcript.
        public var transcripts: [String]
        public init(kid: String, name: String, summary: Stats.Summary?, sessions: [TeamDocs.SessionRow], transcripts: [String]) {
            self.kid = kid; self.name = name; self.summary = summary; self.sessions = sessions; self.transcripts = transcripts
        }
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    public static func memberQuery(kid: String, period: Stats.Period) -> String {
        "kid=\(encode(kid))&period=\(period.rawValue)"
    }
    public static func transcriptQuery(kid: String, session: String) -> String {
        "kid=\(encode(kid))&session=\(encode(session))"
    }
}
```

Check `MirrorTransport.Request.query(_:)` percent-decodes (read `Sources/InfinitusCore/MirrorTransport.swift` around `func query`); if it does not, decode in `query` is NOT yours to change — instead make `transcriptQuery` test use a session id without spaces (`"s-1"`) and note it in the report. `Stats.Summary` and `TeamDocs.SessionRow` are already `Codable`; confirm with `grep -n "struct Summary" Sources/InfinitusCore/Stats.swift` and `grep -n "struct SessionRow" Sources/InfinitusCore/Team/TeamDocs.swift`.

- [ ] **Step 4: Run** `swift test --filter TeamMirrorTests` → PASS.
- [ ] **Step 5: Commit** `git add Sources/InfinitusCore/Team/TeamMirror.swift Tests/InfinitusCoreTests/TeamMirrorTests.swift && git commit -m "team: TeamMirror wire types and paths for the phone's Team tab (spec §9)"`.

---

### Task 2: Mac handler + mirror route

**Files:**
- Create: `Sources/Infinitus/TeamMirrorHandler.swift`
- Modify: `Sources/Infinitus/MirrorServer.swift` (add a box next to `MirrorTeamBox` ~line 204; add one route branch before the `AwsLogin` branch ~line 596; thread the box through the two `handle…` signatures the way `awsLogin` is threaded, lines ~378–392, ~470–490, ~697)
- Modify: `Sources/Infinitus/AppModel.swift` — insert ONLY after the `mirrorServer.sessionStart.set { … }` block (ends ~line 1072)

**Interfaces:**
- Consumes: Task 1 types; `TeamModel` (read-only use of `snapshot`, `reader`, `lastError`, `code`, `clearCode()`; actions `approve(kid:)`, `decline(kid:)`, `join(code:name:)`, `mintCode(days:)`, `mintInvite(days:)`, `transcript(kid:session:)`). `TeamReader.summary(kid:period:)`, `TeamReader.members[kid]?.sessions / .transcripts / .name`, `TeamReader.aggregates`.
- Produces: `MirrorServer.teamMirror: MirrorTeamMirrorBox` with `set(_ handler: @escaping @Sendable (MirrorTransport.Request) async -> Data?)` and `call(_:) async -> Data?`.

- [ ] **Step 1: The box** (in `MirrorServer.swift`, after `MirrorTeamBox`):

```swift
/// Answers `/mirror/team/*` for the phone (spec §9 step 8): one async
/// handler set by AppModel, returning the JSON body or nil for 404.
final class MirrorTeamMirrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MirrorTransport.Request) async -> Data?)?
    func set(_ handler: @escaping @Sendable (MirrorTransport.Request) async -> Data?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func call(_ request: MirrorTransport.Request) async -> Data? {
        lock.lock(); let h = handler; lock.unlock()
        guard let h else { return nil }
        return await h(request)
    }
}
```

Add `let teamMirror = MirrorTeamMirrorBox()` beside `let team = MirrorTeamBox()` (~line 268) and thread it through the same three places `awsLogin` is threaded (the local `let` before the connection handler, the two static handler signatures, and the recursive call). Then the route branch, placed immediately BEFORE the `AwsLogin` branch:

```swift
                } else if request.path.hasPrefix(TeamMirror.prefix + "/") {
                    // The phone's Team tab (spec §9): TeamModel work runs
                    // on its own queue behind the main actor, so off this
                    // queue like the AWS login routes.
                    Task {
                        let response = await teamMirror.call(request)
                            .map(MirrorTransport.jsonResponse) ?? MirrorTransport.notFoundResponse()
                        onServed(request)
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
```

This branch sits inside the already-authorized region (the `if !MirrorTransport.isAuthorized(request, token: token.current)` check precedes it), so the token is enforced twice like every other route.

- [ ] **Step 2: The handler** `Sources/Infinitus/TeamMirrorHandler.swift`:

```swift
import Foundation
import InfinitusCore

/// Dispatches `/mirror/team/*` (spec §9 step 8) onto TeamModel. Every
/// reply is JSON; nil is a 404. Actions run the same gated TeamModel
/// methods the pane uses, so the biometric gate and error masking apply
/// unchanged — a failure comes back as `ActionReply(ok: false, error:)`
/// from `lastError`, never as a raw git message.
@MainActor
enum TeamMirrorHandler {
    static func reply(_ r: MirrorTransport.Request, team: TeamModel) async -> Data? {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T) -> Data? { try? encoder.encode(v) }
        func action(_ body: () async -> Void) async -> Data? {
            team.clearError()
            await body()
            return json(TeamMirror.ActionReply(ok: team.lastError == nil, error: team.lastError))
        }
        switch (r.method, r.path) {
        case ("GET", TeamMirror.aggregatesPath):
            return json(team.reader?.aggregates ?? [:])
        case ("GET", TeamMirror.memberPath):
            guard let kid = r.query("kid"), let reader = team.reader, let m = reader.members[kid] else { return nil }
            let period = r.query("period").flatMap(Stats.Period.init(rawValue:)) ?? .week
            return json(TeamMirror.MemberReply(kid: kid, name: m.name, summary: reader.summary(kid: kid, period: period),
                                               sessions: m.sessions, transcripts: Array(m.transcripts.keys).sorted()))
        case ("GET", TeamMirror.transcriptPath):
            guard let kid = r.query("kid"), let session = r.query("session") else { return nil }
            return json(await team.transcript(kid: kid, session: session))
        case ("POST", TeamMirror.approvePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            return await action { await team.approve(kid: body.kid) }
        case ("POST", TeamMirror.declinePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            return await action { await team.decline(kid: body.kid) }
        case ("POST", TeamMirror.joinPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.JoinRequest.self, from: r.body) else { return nil }
            return await action { await team.join(code: body.code, name: body.name) }
        case ("POST", TeamMirror.codePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.CodeRequest.self, from: r.body),
                  (1...30).contains(body.days) else { return nil }
            team.clearError(); team.clearCode()
            if body.invite { await team.mintInvite(days: body.days) } else { await team.mintCode(days: body.days) }
            let code = team.code
            team.clearCode()   // the pane's QR must not pop because the phone asked
            return json(TeamMirror.ActionReply(ok: code != nil, error: team.lastError, code: code))
        default:
            return nil
        }
    }
}
```

`team.transcript(kid:session:)` sets `lastError` on failure and returns `[]` — acceptable; the phone shows "Nothing to show". Confirm `TeamModel.clearError()` / `clearCode()` exist (they do, lines 428–429).

- [ ] **Step 3: Wire it** in `AppModel.swift`, right after the `mirrorServer.sessionStart.set { … }` block:

```swift
        // The phone's Team tab (spec §9 step 8) — every call lands on the
        // main actor, where TeamModel lives.
        mirrorServer.teamMirror.set { [weak self] request in
            await MainActor.run { () -> TeamModel? in self?.team }
                .map { team in await TeamMirrorHandler.reply(request, team: team) } ?? nil
        }
```

If the optional-map-with-await does not compile, write it out:

```swift
        mirrorServer.teamMirror.set { [weak self] request in
            guard let team = await MainActor.run(body: { self?.team }) else { return nil }
            return await TeamMirrorHandler.reply(request, team: team)
        }
```

- [ ] **Step 4: Build** `swift build --product Infinitus` → succeeds. `swift test` → green.
- [ ] **Step 5: Smoke (optional, if a dev instance is convenient):** run the debug binary with `INFINITUS_CONTROL_SOCKET=/tmp/tp.sock`, then `curl -s -H "Authorization: Bearer <token>" http://127.0.0.1:<port>/mirror/team/aggregates` → `{}` (or the aggregates), and without the header → 401. Do NOT run the dev instance without `INFINITUS_CONTROL_SOCKET`. Skip and say so if no token is at hand.
- [ ] **Step 6: Commit** the three files: `git commit -m "mirror: /mirror/team routes answer the phone from TeamModel (spec §9 step 8)"`.

---

### Task 3: Phone transport wrappers + model accessor + theme tab vocabulary

**Files:**
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` (after `awsLoginCode`, ~line 411)
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (beside `var stats`, ~line 33)
- Modify: `Sources/InfinitusCore/RowTheme.swift` lines 148–149 (plain tables) and each per-theme `tabLabels`/`tabIcons` pair (~271–272, 290–291, 309–310, 328–329, 347–348)
- Test: `Tests/InfinitusCoreTests/RowThemeLoadingTests.swift` (add one test)

**Interfaces:**
- Produces:

```swift
// NetworkFleetMirror
func teamAggregates() async throws -> [String: TeamDocs.Aggregates]
func teamMember(kid: String, period: Stats.Period) async throws -> TeamMirror.MemberReply
func teamTranscript(kid: String, session: String) async throws -> [SessionFeedItem]
func teamApprove(kid: String) async throws -> TeamMirror.ActionReply
func teamDecline(kid: String) async throws -> TeamMirror.ActionReply
func teamJoin(code: String, name: String) async throws -> TeamMirror.ActionReply
func teamCode(days: Int, invite: Bool) async throws -> TeamMirror.ActionReply
// MirrorModel
var team: TeamSnapshot? { snapshot?.team }
```

- [ ] **Step 1: RowTheme test first** — add to `RowThemeLoadingTests`:

```swift
    func testEveryBuiltInThemeNamesTheTeamTab() {
        XCTAssertEqual(RowTheme.plainTabLabels["team"], "Team")
        XCTAssertTrue(RowTheme.plainTabIcons["team"]?.hasPrefix("sf:") == true)
        for theme in RowTheme.builtIn where !theme.tabLabels.isEmpty {
            XCTAssertNotNil(theme.tabLabels["team"], "\(theme.id) names sessions/fleet/settings but not team")
            XCTAssertNotNil(theme.tabIcons["team"], "\(theme.id) lacks a team icon")
        }
    }
```

(If the built-in list is not `RowTheme.builtIn`, use whatever `RowThemeLoadingTests` line 9 iterates.) Run → FAIL.

- [ ] **Step 2: RowTheme tables.** Plain: `"team": "Team"` and `"team": "sf:person.2.fill"`. Per theme (labels / icons): RPG `"Guild"` / `"sf:shield.lefthalf.filled"`; Movie/Scenes `"Crew"` / `"sf:person.2.fill"`; Hades/Runs `"Clan"` / `"sf:person.2.fill"`; MGS/Missions `"Unit"` / `"sf:person.2.fill"`; Agent `"Org"` / `"sf:building.2"`. Leave `loadingWords` and everything else untouched. Run the test → PASS. `swift test --filter RowTheme` → green.

- [ ] **Step 3: NetworkFleetMirror wrappers.** Add a private GET helper that copies `sessionImage`'s stored → discovery fallback exactly, then the typed wrappers:

```swift
    // MARK: team (spec §9 step 8) — `/mirror/team/*`, token-gated like everything else

    private func teamGet<R: Decodable>(_ path: String) async throws -> R {
        let token = pairToken()
        let data: Data
        if let stored = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            data = stored
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }

    func teamAggregates() async throws -> [String: TeamDocs.Aggregates] { try await teamGet(TeamMirror.aggregatesPath) }
    func teamMember(kid: String, period: Stats.Period) async throws -> TeamMirror.MemberReply {
        try await teamGet(TeamMirror.memberPath + "?" + TeamMirror.memberQuery(kid: kid, period: period))
    }
    func teamTranscript(kid: String, session: String) async throws -> [SessionFeedItem] {
        try await teamGet(TeamMirror.transcriptPath + "?" + TeamMirror.transcriptQuery(kid: kid, session: session))
    }
    func teamApprove(kid: String) async throws -> TeamMirror.ActionReply { try await postJSON(TeamMirror.approvePath, body: TeamMirror.KidRequest(kid: kid)) }
    func teamDecline(kid: String) async throws -> TeamMirror.ActionReply { try await postJSON(TeamMirror.declinePath, body: TeamMirror.KidRequest(kid: kid)) }
    func teamJoin(code: String, name: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.joinPath, body: TeamMirror.JoinRequest(code: code, name: name), timeout: 60)
    }
    func teamCode(days: Int, invite: Bool) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.codePath, body: TeamMirror.CodeRequest(days: days, invite: invite), timeout: 60)
    }
```

`join` and `code` do a git fetch/push on the Mac: 60 s, not the input timeout. If `JSONDecoder` needs a date strategy for `SessionFeedItem` (check how `decodeFeed` decodes it, ~line 300; if it sets `.iso8601`, use `Self.decodeFeed`-style decoding for the transcript wrapper by adding a `decoder` parameter to `teamGet`).

- [ ] **Step 4: MirrorModel** — next to `var stats`: `var team: TeamSnapshot? { snapshot?.team }`.
- [ ] **Step 5: Build** — `swift build --product Infinitus && swift test --filter RowTheme`; phone build if Xcode is available (see Global Constraints).
- [ ] **Step 6: Commit** the four files: `git commit -m "phone: team transport wrappers, snapshot accessor and the themes' Team tab words"`.

---

### Task 4: `MobileLock` + Settings toggle + Face ID usage string

**Files:**
- Create: `ios/InfinitusMobile/MobileLock.swift`
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` — a new `Section("Team")` inside `SettingsForm.body`, after the `Section("Notifications")` block (~line 172–219; find its closing brace)
- Modify: `ios/project.yml` — under the same `properties:` map that carries `NSCameraUsageDescription` (~line 39): `NSFaceIDUsageDescription: Infinitus unlocks the Team tab with Face ID.`

**Interfaces:**
- Produces:

```swift
@MainActor final class MobileLock: ObservableObject {
    static let shared = MobileLock()
    static let enabledKey = "team_lock"
    @Published var enabled: Bool           // persisted; didSet re-locks when turned on
    @Published private(set) var locked: Bool
    var methodName: String                 // "Face ID" / "Touch ID" / "passcode"
    func unlock() async -> Bool
    func relock()                          // called on scenePhase == .background by TeamScreen
}
```

- [ ] **Step 1: Implement**

```swift
import Foundation
import LocalAuthentication

/// The phone's own biometric switch for the Team tab (spec §2.2, scoped
/// to the tab this round; app-wide is #55). `.deviceOwnerAuthentication`
/// so the passcode is the fallback the OS itself offers. A fresh
/// LAContext per prompt: a reused one answers from its own cache.
@MainActor
final class MobileLock: ObservableObject {
    static let shared = MobileLock()
    static let enabledKey = "team_lock"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            locked = enabled
        }
    }
    @Published private(set) var locked: Bool

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
        enabled = on
        locked = on
    }

    var methodName: String {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return "passcode" }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "passcode"
        }
    }

    func unlock() async -> Bool {
        guard enabled else { locked = false; return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your team")) ?? false
        if ok { locked = false }
        return ok
    }

    func relock() { if enabled { locked = true } }
}
```

- [ ] **Step 2: Settings section** (inside `SettingsForm.body`'s `Form`, after Notifications):

```swift
            Section("Team") {
                Toggle("Lock the Team tab with \(lock.methodName)", isOn: $lock.enabled)
                Text("Joining a team from the phone needs the lock on (the Mac has the same rule).")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

with `@ObservedObject private var lock = MobileLock.shared` added to `SettingsForm`'s properties. Do not touch any other section.

- [ ] **Step 3: project.yml** — add the Face ID key next to the camera key. Run `cd ios && xcodegen generate` locally if xcodegen is installed to confirm the YAML parses (the generated project is untracked; do not commit it).
- [ ] **Step 4: Commit** the three files: `git commit -m "phone: Face ID / Touch ID lock for the Team tab (spec §2.2, tab-scoped)"`.

---

### Task 5: `TeamScreen` (tab root) + the tab in RootView

**Files:**
- Create: `ios/InfinitusMobile/TeamScreen.swift`
- Modify: `ios/InfinitusMobile/RootView.swift` — a fourth tab between fleet and settings (~line 70), badge = pending requests when leader

**Interfaces:**
- Consumes: Task 3 wrappers, `MirrorModel.team`, `MobileLock.shared`, `ThemedPlaceholder(theme:key:plainSymbol:description:)`, `TeamSnapshot` (fields: `name`, `role`, `remote`, `members: [Member{kid,name,role,isMe,founder,lastPublished,kinds,sessionsNow,blockers,crashes,todayUSD,todayMessages,todayCommits}]`, `requests: [Request{kid,name,platform,devices,at}]`, `lastFetch`, `lastPublish`, `lastError`), `TeamDocs.Aggregates` (`period, from, to, at, members, total: Stats.Day, previous: Stats.Day, hours, repos: [Repo{project,usd,minutes,members}], byModel, onNow: [String], perMember: [MemberTotal]?`).
- Produces: `struct TeamScreen: View { @ObservedObject var model: MirrorModel }`; `TeamMemberScreen(model:kid:name:)` is Task 6 — reference it by that exact signature.

- [ ] **Step 1: Implement `TeamScreen.swift`.** Structure (write it fully; this is the shape, not a placeholder):

```swift
import SwiftUI
import InfinitusCore

/// The phone's Team tab (spec §9 step 8): the Mac's team through the
/// mirror. Roster / requests / invite come from the snapshot the phone
/// already polls; aggregates, member detail and actions go over
/// `/mirror/team/*`. Locked behind MobileLock when the switch is on.
struct TeamScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject private var lock = MobileLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var aggregates: [String: TeamDocs.Aggregates] = [:]
    @State private var period: Stats.Period = .week
    @State private var busy: String?
    @State private var error: String?
    @State private var code: String?
    @State private var joinCode = ""
    @State private var joinName = UIDevice.current.name
    @State private var declining: TeamSnapshot.Request?

    var body: some View {
        NavigationStack {
            Group {
                if lock.enabled && lock.locked {
                    lockedView
                } else if let snap = model.team {
                    inTeam(snap)
                } else {
                    notInTeam
                }
            }
            .navigationTitle(model.rowTheme.tabLabel("team"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { lock.relock() } }
        .onChange(of: model.team?.role) { _, _ in Task { await loadAggregates() } }
        .task { await loadAggregates() }
    }
    // lockedView: ThemedPlaceholder(theme: model.rowTheme, key: "empty", plainSymbol: "lock.fill",
    //   description: "Unlock with \(lock.methodName) to see your team.") + Button("Unlock") { Task { _ = await lock.unlock() } }
    // notInTeam: Form with Section("Join a team") { TextField("Team code or invite link", text: $joinCode) .textInputAutocapitalization(.never).autocorrectionDisabled();
    //   TextField("Your name", text: $joinName); Button("Request to join") { … teamJoin … }.disabled(!lock.enabled || joinCode.isEmpty || busy != nil)
    //   if !lock.enabled { Text("Turn on the Team lock in Settings first.").font(.caption).foregroundStyle(.orange) } }
    //   + Section { Text("Create a team on the Mac (Settings › Team).").font(.caption).foregroundStyle(.secondary) } + errorSection
    // inTeam(snap): Form {
    //   header Section: LabeledContent("Team", value: snap.name); LabeledContent("You", value: role · my name); LabeledContent("Store") { Text(snap.remote).font(.caption.monospaced()) }; LabeledContent("Last fetch", value: relative(snap.lastFetch)); LabeledContent("Last publish", value: relative(snap.lastPublish))
    //     if snap.role == "pending" { Text("Waiting for a leader to approve you.") }
    //   if snap.role == "leader", !snap.requests.isEmpty: Section("Requests") rows: name bold, "\(platform) · devices · relative(at)" caption, kid caption2 monospaced; swipeActions: Approve (tint green) / Decline (destructive) → teamApprove/teamDecline then model.refreshNow() (see Step 2)
    //   Section("Members"): ForEach(snap.members) { NavigationLink(destination: TeamMemberScreen(model: model, kid: m.kid, name: m.name)) { memberRow(m) } .disabled(m.kinds.isEmpty) }
    //   if snap.role == "leader": Section("Invite") { Stepper("Valid \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...30); Button("Invite link") { mint(invite: true) }; Button("Team code") { mint(invite: false) }
    //     if let code { Text(code).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3); ShareLink(item: code) { Label("Share", systemImage: "square.and.arrow.up") } } }
    //   aggregatesSection: Section("Team picture") { Picker("Period", selection: $period) { ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
    //     if let a = aggregates[period.rawValue] { LabeledContent("Members", value: "\(a.members)"); LabeledContent("Cost", value: usd(a.total.usd)); LabeledContent("Commits", value: "\(a.total.commits)"); LabeledContent("Messages", value: "\(a.total.humanMessages)"); LabeledContent("On now", value: a.onNow.isEmpty ? "nobody" : a.onNow.joined(separator: ", "))
    //       ForEach(a.repos.prefix(8), id: \.project) { LabeledContent($0.project) { Text("\(usd($0.usd)) · \($0.minutes) min · \($0.members) people").monospacedDigit().font(.caption) } }
    //     } else { Text("The leaders haven't published a team picture for this period yet.").font(.caption).foregroundStyle(.secondary) } }
    //   Section { Text("Sharing, exclusions and identity are managed on the Mac.").font(.caption).foregroundStyle(.secondary) }
    //   errorSection (if let error { Text(error).font(.caption).foregroundStyle(.orange) })
    // }.refreshable { await model.refreshNow(); await loadAggregates() }
    // memberRow(m): HStack { Circle().fill(m.sessionsNow > 0 ? .green : .secondary.opacity(0.3)).frame(width: 8, height: 8); VStack(alignment: .leading, spacing: 2) { HStack(spacing: 6) { Text(m.name).bold(); Text(m.role).font(.caption).foregroundStyle(.secondary); if m.isMe { Text("you").font(.caption2).foregroundStyle(.tertiary) } }
    //   Text(m.kinds.isEmpty ? "nothing readable yet" : "shares \(m.kinds.joined(separator: ", ")) · last \(relative(m.lastPublished))").font(.caption).foregroundStyle(.secondary)
    //   Text("today \(usd(m.todayUSD)) · \(m.todayMessages) msgs · \(m.todayCommits) commits · \(m.sessionsNow) on").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    //   ForEach(m.blockers, id: \.self) { Text("⚠︎ \($0)").font(.caption).foregroundStyle(.orange) } } }
    // helpers: relative(_ t: Int?) -> String ("never" / RelativeDateTimeFormatter named style), usd(_ v: Double) -> String (currency USD 2 fraction digits)
    // loadAggregates(): guard model.team != nil else { aggregates = [:]; return }; aggregates = (try? await NetworkFleetMirror.shared.teamAggregates()) ?? [:]
    // act(_ label: String, _ work: () async throws -> TeamMirror.ActionReply): busy = label; defer busy = nil; do { let r = try await work(); error = r.ok ? nil : (r.error ?? "That didn't work"); return r } catch { error = "\(error.localizedDescription)"; return nil }
}
```

Write the real bodies for every commented line — the comments are the required content, not optional. `Stats.Period.title` exists (used by `TeamMemberPane`). `Stats.Day.humanMessages` exists (see `TeamInsightsTests`). The Approve/Decline swipe actions call `act` then `await model.refreshNow()` so the snapshot's request list updates.

- [ ] **Step 2: `MirrorModel.refreshNow()`** — check for an existing public "fetch the snapshot now" method on `MirrorModel` (grep `func refresh` / `func fetchNow` / `func poll` in `MirrorModel.swift`). Use the existing one; if none is public, expose the existing private one with the name it already has (a one-line access change is within this stream's MirrorModel allowance). Report which.

- [ ] **Step 3: RootView** — between the fleet and settings tabs:

```swift
            TeamScreen(model: model)
                .tabItem { tabLabel("team") }
                .tag("team")
                .badge(model.team?.role == "leader" ? (model.team?.requests.count ?? 0) : 0)
```

- [ ] **Step 4: Build** (phone build if available; otherwise `swift build` for the core parts) and fix warnings in the new file.
- [ ] **Step 5: Commit** `git add ios/InfinitusMobile/TeamScreen.swift ios/InfinitusMobile/RootView.swift ios/InfinitusMobile/MirrorModel.swift && git commit -m "phone: Team tab — roster, requests, invite and the team picture through the mirror (spec §9)"`.

---

### Task 6: `TeamMemberScreen` (member detail + transcript)

**Files:**
- Create: `ios/InfinitusMobile/TeamMemberScreen.swift`

**Interfaces:**
- Consumes: `NetworkFleetMirror.shared.teamMember(kid:period:)`, `teamTranscript(kid:session:)`, `Stats.Presentation.groups(_:)` (`Group{id, tiles: [Tile{id, value, delta}]}`), `Stats.Presentation.activityRows/modelRows` (`Row{id, usdText, minutesText, count, tokensText, cachedSuffixText}`), `TeamDocs.SessionRow` (`id, project, engine, name?, startedAt, usd, busyMinutes`), `SessionFeedItem` (`kind: Kind(rawValue), text`).
- Produces: `struct TeamMemberScreen: View { let model: MirrorModel; let kid: String; let name: String }` (signature used by Task 5).

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import InfinitusCore

/// One teammate on the phone (spec §9): period picker, the same stat
/// tiles StatsScreen draws (via Stats.Presentation — the layout is
/// re-typed here, NOT extracted from StatsScreen, which another stream
/// owns), their session index, and a transcript list.
struct TeamMemberScreen: View {
    let model: MirrorModel
    let kid: String
    let name: String
    @State private var period: Stats.Period = .week
    @State private var reply: TeamMirror.MemberReply?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let s = reply?.summary { Text("\(s.from) – \(s.to)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let s = reply?.summary, s.total != Stats.Day() {
                ForEach(Stats.Presentation.groups(s)) { group in
                    Section(group.id) {
                        ForEach(group.tiles) { tile in
                            LabeledContent(tile.id) {
                                HStack(spacing: 6) {
                                    Text(tile.value).monospacedDigit()
                                    if let delta = tile.delta { Text(delta).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                                }
                            }
                        }
                    }
                }
                effortSection("Where the effort went", Stats.Presentation.activityRows(s))
                effortSection("By model", Stats.Presentation.modelRows(s))
            } else if reply != nil {
                Section { Text("No stats shared for this period.").foregroundStyle(.secondary) }
            }
            if let r = reply, !r.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(r.sessions, id: \.id) { row in
                        if r.transcripts.contains(row.id) {
                            NavigationLink { TeamTranscriptScreen(kid: kid, session: row) } label: { sessionRow(row) }
                        } else {
                            sessionRow(row)
                        }
                    }
                }
            }
            if let error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await load() }
        .overlay { if reply == nil && error == nil { ProgressView() } }
    }

    private func load() async {
        do { reply = try await NetworkFleetMirror.shared.teamMember(kid: kid, period: period); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func sessionRow(_ row: TeamDocs.SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name ?? row.project).bold()
            Text("\(row.project) · \(row.engine) · \(row.busyMinutes) min busy · \(row.usd, format: .currency(code: "USD").precision(.fractionLength(2)))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func effortSection(_ title: String, _ rows: [Stats.Presentation.Row]) -> some View {
        Section(title) {
            if rows.isEmpty { Text("Nothing yet this period").font(.caption).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                LabeledContent {
                    Text("\(r.usdText) · \(r.minutesText)").monospacedDigit()
                } label: {
                    Text(r.id)
                    Text("\(r.count) stretches · \(r.tokensText) tokens\(r.cachedSuffixText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A teammate's shared transcript: plain rows (kind + text). Not
/// SessionFeedScreen's chat rows — those belong to another stream's file.
struct TeamTranscriptScreen: View {
    let kid: String
    let session: TeamDocs.SessionRow
    @State private var items: [SessionFeedItem]?
    @State private var error: String?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to show", systemImage: "text.bubble",
                                           description: Text(error ?? "The transcript is empty or not readable by you."))
                } else {
                    List(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                            Text(item.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session.name ?? session.project)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { items = try await NetworkFleetMirror.shared.teamTranscript(kid: kid, session: session.id) }
            catch { self.error = error.localizedDescription; items = [] }
        }
    }
}
```

Check `SessionFeedItem.text` is the field name (`grep -n "public let text\|public var text" Sources/InfinitusCore/SessionFeed.swift`); use whatever it is.

- [ ] **Step 2: Build** (phone build if available).
- [ ] **Step 3: Commit** `git add ios/InfinitusMobile/TeamMemberScreen.swift && git commit -m "phone: teammate detail and transcript over the mirror (spec §9)"`.

---

### Task 7: CHANGELOG + follow-ups

**Files:**
- Modify: `CHANGELOG.md` — under `## 0.4.4 (unreleased)`, add (or extend) a `### Team (preview)` section AFTER the existing `### Mac` section.

- [ ] **Step 1: Lines** (one feature, one line each):

```
### Team (preview)
- The phone has a Team tab: roster, requests, invite links and team codes, a teammate's stats and sessions, their shared transcripts, and the leaders' team picture — approve, decline and join from the phone.
- The phone's Team tab locks behind Face ID / Touch ID (Settings › Team); joining from the phone needs the lock on.
- Every theme names the Team tab in its own words (Guild, Crew, Clan, Unit, Org).
```

- [ ] **Step 2:** `swift test` green; `swift build --product Infinitus` ok.
- [ ] **Step 3: Commit** `git add CHANGELOG.md && git commit -m "changelog: phone Team tab"`.
- [ ] **Step 4:** Report in the task report (the orchestrator files these on #55, not the implementer): app-wide phone lock; Nearby lists on the phone; the invite QR on the phone (a `Image(uiImage:)` of the code via CoreImage — deferred).

---

## Self-review

- **Spec coverage:** §9 phone tab (Tasks 5–6), approve/request/invite from the phone (Task 5), member detail reusing Stats presentation (Task 6), lock (Task 4, tab-scoped by stated decision), §8.4 members' view via aggregates (Task 5). Nearby on the phone deferred (stated).
- **Type consistency:** `TeamMirror.MemberReply(kid:name:summary:sessions:transcripts:)` used identically in Tasks 1, 2, 3, 6; `TeamMemberScreen(model:kid:name:)` in Tasks 5 and 6; `teamGet` private, typed wrappers public across Tasks 3, 5, 6.
- **No placeholders:** every step names files, signatures and copy.
