import XCTest
@testable import InfinitusCore

final class TeamFleetDocTests: XCTestCase {
    func account(_ n: Int, alias: String? = nil, email: String = "secret@example.com", status: String = "ok",
                 five: Double? = nil, seven: Double? = nil, scoped: [(String, Double)] = [],
                 plan: String? = "Max 20x", disabled: Bool? = nil) -> Account {
        let usage = (five == nil && seven == nil && scoped.isEmpty) ? nil : Usage(
            fiveHour: five.map { UsageWindow(pct: $0, resetsAt: "2026-09-06T13:00:00.254457+00:00") },
            sevenDay: seven.map { UsageWindow(pct: $0, resetsAt: "2026-09-08T11:00:00+00:00") },
            scoped: scoped.map { UsageWindow(pct: $0.1, resetsAt: "2026-09-08T11:00:00+00:00", name: $0.0) })
        return Account(number: n, email: email, active: false, usageStatus: status, usage: usage,
                       alias: alias, plan: plan, disabled: disabled)
    }

    func testRowLabelsStatusesAndWindowsAndNeverCarriesTheEmail() throws {
        let fleet = EngineFleet(engineID: "cswap", provider: .claude, accounts: [
            account(1, alias: "ann", five: 42, seven: 10, scoped: [("Fable", 95)]),
            account(2, five: 100, seven: 30),
            account(3, alias: "lee", status: "relogin_required"),
            account(4, alias: "pat", five: 12, disabled: true),
            account(5, alias: "sam", status: "api_key"),
        ], activeNumber: 1, nextCandidate: 5)
        let row = TeamDocs.FleetDoc.row(fleet, tokensPerMinute: 1234.5, lastSwitchAt: 77)
        XCTAssertEqual(row.engine, "cswap")
        XCTAssertEqual(row.active, "ann")
        XCTAssertEqual(row.next, "sam")
        XCTAssertEqual(row.tokensPerMinute, 1234.5)
        XCTAssertEqual(row.lastSwitchAt, 77)
        XCTAssertEqual(row.accounts.map(\.label), ["ann", "#2", "lee", "pat", "sam"])
        XCTAssertEqual(row.accounts.map(\.status), ["limited", "dead", "expiredLogin", "held", "ok"])
        XCTAssertEqual(row.accounts.map(\.active), [true, false, false, false, false])
        XCTAssertEqual(row.accounts[0].windows.map { "\($0.label):\($0.pct)" }, ["5h:42", "7d:10"])
        XCTAssertEqual(row.accounts[0].models.map { "\($0.label):\($0.pct)" }, ["Fable:95"])
        XCTAssertEqual(row.accounts[0].windows[0].resetsAt, 1788699600)
        XCTAssertEqual(row.accounts[0].tier, "Max 20x")
        XCTAssertEqual(row.accounts[4].windows, [])
        let json = String(decoding: try CanonicalJSON.encode(TeamDocs.FleetDoc(at: 1, fleets: [row])), as: UTF8.self)
        XCTAssertFalse(json.contains("example.com"), "the email never travels")
        XCTAssertFalse(json.contains("secret"))
    }

    func testFleetPathShapeNamesTheKindAndItsSender() {
        XCTAssertEqual(TeamKinds.expected(at: "m/k/fleet.json")?.kind, "fleet")
    }

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
        XCTAssertEqual(TeamKinds.expected(at: "m/k/fleet.json")?.from, "k")
        XCTAssertNil(TeamKinds.expected(at: "m/k/fleet/1.json"))
        let h = Envelope.Header(v: 1, kind: "fleet", from: "k", eph: "", to: [], at: 1, nonce: "", sig: nil)
        XCTAssertNoThrow(try TeamKinds.check(h, at: "m/k/fleet.json"))
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/k/now.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
        XCTAssertEqual(TeamKinds.memberKinds.last, TeamKinds.fleet, "the share row, after the older kinds")
    }

    func entry(_ path: String, kind: String, from: String, at: Int) -> (entry: StoreEntry, header: Envelope.Header) {
        (StoreEntry(path: path, size: 1, version: "v"),
         Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: [], at: at, nonce: "", sig: nil))
    }

    func doc(at: Int, active: String, used: Int, spare: [String] = [], dead: [String] = []) -> TeamDocs.FleetDoc {
        var rows = [TeamDocs.FleetDoc.AccountRow(label: active, tier: nil, status: "ok", active: true,
                                                 windows: [.init(label: "5h", pct: used), .init(label: "7d", pct: 3)], models: [])]
        rows += spare.map { .init(label: $0, tier: nil, status: "ok", active: false, windows: [], models: []) }
        rows += dead.map { .init(label: $0, tier: nil, status: "dead", active: false, windows: [.init(label: "5h", pct: 100)], models: []) }
        return TeamDocs.FleetDoc(at: at, fleets: [.init(engine: "cswap", active: active, next: spare.first, accounts: rows)])
    }

    func testFoldCarriesTheFleetOntoTheMemberAndTheSnapshotRow() throws {
        let a = TeamIdentity.random(), b = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: b.keys, name: "Bo", since: 2)], removed: [], rev: 2)
        let fleet = doc(at: 500, active: "ann", used: 70, spare: ["pat"])
        var docs: [String: Data] = [:]
        docs["m/\(a.kid)/fleet.json"] = try CanonicalJSON.encode(fleet)
        docs["m/\(b.kid)/fleet.json"] = Data("{\"schema\":2,\"at\":1,\"fleets\":[]}".utf8)   // unknown schema: skipped
        let reader = TeamReader.fold(headers: [entry("m/\(a.kid)/fleet.json", kind: "fleet", from: a.kid, at: 500),
                                               entry("m/\(b.kid)/fleet.json", kind: "fleet", from: b.kid, at: 501)],
                                     roster: roster) { docs[$0] ?? Data() }
        XCTAssertEqual(reader.members[a.kid]?.fleet, fleet)
        XCTAssertNil(reader.members[b.kid]?.fleet)
        XCTAssertEqual(reader.members[a.kid]?.kinds, ["fleet"])
        let status = TeamStatus(id: "t", name: "T", remote: "file:///r", kid: a.kid, role: "leader", rev: 2, leaders: 1, members: 1, requests: 0)
        let snap = TeamSnapshot.make(status: status, roster: roster, reader: reader, requests: [], today: "d",
                                     lastFetch: nil, lastPublish: nil, lastError: nil)
        XCTAssertEqual(snap.members.first { $0.kid == a.kid }?.fleet, fleet)
        XCTAssertNil(snap.members.first { $0.kid == b.kid }?.fleet)
        // Additive: a row encoded before the field decodes without it.
        let old = Data(#"{"kid":"k","name":"N","role":"member","isMe":false,"founder":false,"kinds":[],"sessionsNow":0,"blockers":[],"crashes":0,"todayUSD":0,"todayMessages":0,"todayCommits":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TeamSnapshot.Member.self, from: old).fleet)
    }

    func testHeadroomBoardListsFreshFleetsNearestDryFirst() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let a = TeamIdentity.random(), b = TeamIdentity.random(), l = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: b.keys, name: "Bo", since: 2),
                                          TeamRoster.Member(keys: l.keys, name: "Lee", since: 3)], removed: [], rev: 3)
        let docs: [String: Data] = [
            "m/\(a.kid)/fleet.json": try CanonicalJSON.encode(doc(at: 900, active: "ann", used: 70, spare: ["pat", "sam"], dead: ["old"])),
            "m/\(b.kid)/fleet.json": try CanonicalJSON.encode(doc(at: 950, active: "bo", used: 96)),
            "m/\(l.kid)/fleet.json": try CanonicalJSON.encode(doc(at: 10, active: "lee", used: 99)),   // stale: skipped
        ]
        let reader = TeamReader.fold(headers: docs.keys.map { path in
            entry(path, kind: "fleet", from: String(path.split(separator: "/")[1]), at: 1)
        }, roster: roster) { docs[$0] ?? Data() }
        let board = TeamInsights.headroom(reader, now: now)
        XCTAssertEqual(board.map(\.name), ["Bo", "Ann"])
        XCTAssertEqual(board.map(\.headroom), [4, 30])
        XCTAssertEqual(board[1].spare, 2)
        XCTAssertEqual(board[1].dead, 1)
        XCTAssertEqual(board[0].spare, 0)
    }
}
