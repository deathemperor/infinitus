import XCTest
@testable import InfinitusCore

final class TeamControlTests: XCTestCase {
    let grantor = TeamIdentity.random()
    let driver = TeamIdentity.random()
    let eve = TeamIdentity.random()

    func lookup(_ kid: String) -> TeamKeys? { [grantor, driver, eve].first { $0.kid == kid }?.keys }

    func command(id: String = "c-0123456789", thread: String = "t1", action: String = TeamGrants.send,
                 text: String? = "hello", project: String? = nil, at: Int = 1_000, ttl: Int = 120) -> TeamControl.Command {
        TeamControl.Command(id: id, to: grantor.kid, thread: thread, action: action, text: text, project: project, at: at, ttl: ttl)
    }

    // MARK: envelopes

    func testCommandSealsToTheGrantorOnlyAndRoundTrips() throws {
        let cmd = command(project: nil)
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
        // Every path the helpers mint is a shape TeamKinds accepts for that kind and sender; nothing else under control/ is.
        XCTAssertNoThrow(try TeamKinds.check(kind: TeamKinds.command, from: "d", at: TeamControl.commandPath(driver: "d", id: "c-0123456789")))
        XCTAssertNoThrow(try TeamKinds.check(kind: TeamKinds.ack, from: "g", at: TeamControl.ackPath(grantor: "g", id: "c-0123456789")))
        XCTAssertNil(TeamKinds.expected(at: "m/d/control/hostnames/x.json"))
        XCTAssertFalse(TeamKinds.memberKinds.contains(TeamKinds.command), "control kinds are not shareable kinds")
    }

    func testNowCarriesEndpointsAndGrantHintsOptionally() throws {
        let plain = TeamDocs.Now(at: 1, machine: "mac", live: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:], desktop: true)
        let bytes = try CanonicalJSON.encode(plain)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("endpoints"), "absent, not null: older readers stay byte-identical")
        var full = plain
        full.endpoints = TeamControl.Endpoints(httpBaseUrl: "http://192.168.1.20:3773", lanHttpBaseUrls: ["http://192.168.1.20:3773"],
                                               tunnel: "https://mac.example.net")
        full.grantsTo = [TeamDocs.GrantHint(audience: .leaders, threads: nil, capabilities: ["send"])]
        let again = try CanonicalJSON.decode(TeamDocs.Now.self, from: try CanonicalJSON.encode(full))
        XCTAssertEqual(again, full)
        // A now.json from before this field decodes with nils.
        XCTAssertNil(try CanonicalJSON.decode(TeamDocs.Now.self, from: bytes).endpoints)
    }

    // MARK: replay set, rate limit

    func testSeenIDsAdmitOnceUntilExpiryThenForget() throws {
        var seen = TeamControl.SeenIDs()
        XCTAssertTrue(seen.admit("c-0000000001", until: 1_120, now: 1_000))
        XCTAssertFalse(seen.admit("c-0000000001", until: 1_120, now: 1_010), "a replay inside the TTL")
        XCTAssertTrue(seen.admit("c-0000000002", until: 1_050, now: 1_010))
        // Past its expiry the id is pruned — a late replay of it is refused by `expired` (verify), not here.
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

    // MARK: verification

    func endpoint(grants: TeamGrants, roster: TeamRoster? = nil, threads: Set<String> = ["t1"],
                  now: Int = 1_010, reply: TeamControl.Reply = .init(outcome: "delivered"),
                  executed: @escaping (TeamControl.Command) -> Void = { _ in }) -> TeamControl.Endpoint {
        let roster = roster ?? TeamRoster(id: "team-1", name: "P", createdAt: 1,
                                          leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                          members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], rev: 1)
        return TeamControl.Endpoint(identity: grantor, roster: { roster }, grants: { grants }, threads: { threads },
                                    execute: { c in executed(c); return reply },
                                    seen: TeamControl.SeenIDs(), limit: TeamControl.RateLimit(),
                                    now: { Date(timeIntervalSince1970: Double(now)) })
    }

    func grant(_ capabilities: Set<String> = [TeamGrants.send], threads: TeamGrants.Threads = .some(["t1"]),
               preauthorized: Set<String> = []) -> TeamGrants {
        var g = TeamGrants()
        g.add(audience: .members([driver.kid]), threads: threads, capabilities: capabilities, preauthorized: preauthorized, now: 900)
        return g
    }

    func sealed(_ cmd: TeamControl.Command, from: TeamIdentity? = nil, to: TeamKeys? = nil) throws -> Data {
        try TeamControl.sealCommand(cmd, from: from ?? driver, to: to ?? grantor.keys, at: cmd.at)
    }

    func testAGrantedCommandExecutesAndAcksTheReply() throws {
        var ran: [TeamControl.Command] = []
        var ep = endpoint(grants: grant()) { ran.append($0) }
        let (ack, audit, keys) = TeamControl.handle(try sealed(command()), endpoint: &ep)
        XCTAssertEqual(ran, [command()])
        XCTAssertEqual(ack, TeamControl.Ack(id: "c-0123456789", outcome: "delivered", detail: nil, at: 1_010))
        XCTAssertEqual(audit, TeamControl.Audit(driver: driver.kid, thread: "t1", action: "send", outcome: "delivered", detail: nil))
        XCTAssertEqual(keys, driver.keys)
        XCTAssertFalse(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011), "the id is now spent")
    }

    func testEveryRefusalInOrder() throws {
        func outcome(_ file: Data, _ ep: inout TeamControl.Endpoint) -> String { TeamControl.handle(file, endpoint: &ep).ack.outcome }
        // 1. not a member (eve) — unknownSender, and no keys to answer.
        var ep = endpoint(grants: grant())
        let fromEve = TeamControl.handle(try sealed(command(), from: eve), endpoint: &ep)
        XCTAssertEqual(fromEve.ack.outcome, "unknownSender"); XCTAssertNil(fromEve.driverKeys)
        // 1b. garbage — badRequest, no keys.
        let garbage = TeamControl.handle(Data("nope".utf8), endpoint: &ep)
        XCTAssertEqual(garbage.ack.outcome, "badRequest"); XCTAssertNil(garbage.driverKeys)
        // 2. addressed to someone else although sealed to me.
        var cmd = command(); cmd.to = eve.kid
        XCTAssertEqual(outcome(try sealed(cmd), &ep), "badRequest")
        // 2b. body clock differs from the envelope's (a backdated header would consult an older roster).
        XCTAssertEqual(outcome(try TeamControl.sealCommand(command(), from: driver, to: grantor.keys, at: 999), &ep), "badRequest")
        // 3. expired / from the future / ttl above the cap.
        XCTAssertEqual(outcome(try sealed(command(at: 800, ttl: 100)), &ep), "expired")
        XCTAssertEqual(outcome(try sealed(command(at: 1_010 + TeamControl.maxFutureSkew + 1)), &ep), "badRequest")
        XCTAssertEqual(outcome(try sealed(command(id: "c-cap-ttl-000", ttl: TeamControl.maxTTL + 1)), &ep), "badRequest", "ttl above the cap")
        // 5. no grant — wrong capability, wrong thread, wrong kid.
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000001", action: "interrupt", text: nil)), &ep), "noGrant")
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000002", thread: "t2")), &ep), "noGrant")
        var none = endpoint(grants: TeamGrants())
        XCTAssertEqual(outcome(try sealed(command()), &none), "noGrant")
        // 5b. an action that is not a capability at all; a thread action naming the Mac; `new` naming a thread or no project.
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000003", action: "reboot")), &ep), "badRequest")
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000004", thread: "-")), &ep), "badRequest")
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000005", thread: "")), &ep), "badRequest")
        var maker = endpoint(grants: grant([TeamGrants.new], preauthorized: [TeamGrants.new]))
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000006", thread: "t1", action: "new", project: "p")), &maker), "badRequest", "new names the Mac")
        XCTAssertEqual(outcome(try sealed(command(id: "c-a000000007", thread: "-", action: "new", project: nil)), &maker), "badRequest", "new needs a project")
        // 6. not live.
        var offline = endpoint(grants: grant(), threads: [])
        XCTAssertEqual(outcome(try sealed(command()), &offline), "notLive")
        // 4. replay: the same id twice (the first executes).
        var twice = endpoint(grants: grant())
        XCTAssertEqual(outcome(try sealed(command()), &twice), "delivered")
        XCTAssertEqual(outcome(try sealed(command()), &twice), "replayed")
        // 7. rate: the sixth distinct command inside the window.
        var busy = endpoint(grants: grant())
        for i in 0..<TeamControl.RateLimit.commands { XCTAssertEqual(outcome(try sealed(command(id: "c-r00000000\(i)")), &busy), "delivered") }
        XCTAssertEqual(outcome(try sealed(command(id: "c-r000000009")), &busy), "rateLimited")
    }

    func testOrderIsProvenByACommandFailingTwoRules() throws {
        // Expired AND unshared: `expired` wins (step 3 before step 5), and the id is not spent.
        var ep = endpoint(grants: TeamGrants())
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 800, ttl: 10)), endpoint: &ep).ack.outcome, "expired")
        XCTAssertTrue(ep.seen.admit("c-0123456789", until: 2_000, now: 1_011), "a refused command does not spend its id")
        // No grant AND not live: `noGrant` wins (step 5 before 6) — a stranger learns nothing about liveness.
        var off = endpoint(grants: TeamGrants(), threads: [])
        XCTAssertEqual(TeamControl.handle(try sealed(command()), endpoint: &off).ack.outcome, "noGrant")
    }

    func testARemovedMemberIsUnknownAfterRemoval() throws {
        // Removed at 950: a command sealed at 1_000 fails unknownSender; one sealed at 940 still verifies (roster keeps its keys).
        let roster = TeamRoster(id: "team-1", name: "P", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                members: [], removed: [TeamRoster.Removed(kid: driver.kid, at: 950, keys: driver.keys)], rev: 2)
        var ep = endpoint(grants: grant(), roster: roster)
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 1_000)), endpoint: &ep).ack.outcome, "unknownSender")
        var early = endpoint(grants: grant(), roster: roster)
        XCTAssertEqual(TeamControl.handle(try sealed(command(at: 940, ttl: 100)), endpoint: &early).ack.outcome,
                       "noGrant", "verifies, but a removed kid is in no audience any more")
    }

    // MARK: scope, the heavy bucket, approvals

    func testNewNamesTheMacAndNeedsNoLiveThread() throws {
        func outcome(_ cmd: TeamControl.Command, _ ep: inout TeamControl.Endpoint) throws -> String {
            TeamControl.handle(try sealed(cmd), endpoint: &ep).ack.outcome
        }
        var ran: [TeamControl.Command] = []
        var off = endpoint(grants: grant([TeamGrants.new], preauthorized: [TeamGrants.new]), threads: [],
                           reply: .init(outcome: "done", detail: "t-new")) { ran.append($0) }
        XCTAssertEqual(try outcome(command(id: "c-s000000005", thread: "-", action: "new", text: "Fix it", project: "Demo"), &off), "done")
        XCTAssertEqual(ran.last?.project, "Demo")
        // `view` is a thread action: needs the thread, answers through the detail.
        var viewer = endpoint(grants: grant([TeamGrants.view]), reply: .init(outcome: "done", detail: "user: hi\\nassistant: hello"))
        let viewed = TeamControl.handle(try sealed(command(id: "c-s000000006", action: "view", text: nil)), endpoint: &viewer)
        XCTAssertEqual(viewed.ack.outcome, "done"); XCTAssertEqual(viewed.ack.detail, "user: hi\\nassistant: hello")
        // The heavy bucket: six a minute, apart from the drive bucket.
        var busy = endpoint(grants: grant([TeamGrants.send, TeamGrants.interrupt], preauthorized: [TeamGrants.interrupt]))
        for i in 0..<TeamControl.RateLimit.heavyCommands {
            XCTAssertEqual(try outcome(command(id: "c-h00000000\(i)", action: "interrupt", text: nil), &busy), "delivered", "interrupt \(i)")
        }
        XCTAssertEqual(try outcome(command(id: "c-h000000009", action: "interrupt", text: nil), &busy), "rateLimited")
        XCTAssertEqual(try outcome(command(id: "c-h000000010", action: "send", text: "still fine"), &busy), "delivered", "the drive bucket is its own")
    }

    func testAnActionTheGrantDidNotPreauthorizeWaitsForTheGrantorsTap() throws {
        var ran: [TeamControl.Command] = []
        var ep = endpoint(grants: grant([TeamGrants.interrupt, TeamGrants.new]), reply: .init(outcome: "done")) { ran.append($0) }
        let first = TeamControl.handle(try sealed(command(id: "c-p000000001", action: "interrupt", text: nil)), endpoint: &ep)
        XCTAssertEqual(first.ack.outcome, "pending"); XCTAssertEqual(first.audit.outcome, "pending"); XCTAssertEqual(first.driverKeys, driver.keys)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(ep.pending["c-p000000001"]?.expires, 1_010 + TeamControl.approvalTTL)
        // The same ask again while one waits; a resend of the first id.
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000002", action: "interrupt", text: nil)), endpoint: &ep).ack.outcome, "alreadyPending")
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000001", action: "interrupt", text: nil)), endpoint: &ep).ack.outcome, "replayed")
        XCTAssertEqual(ep.pending.count, 1)
        // Allow: runs now; the answer goes through the outbox.
        let allowed = try XCTUnwrap(TeamControl.decide("c-p000000001", allow: true, endpoint: &ep))
        XCTAssertEqual(allowed.ack, TeamControl.Ack(id: "c-p000000001", outcome: "done", detail: nil, at: 1_010))
        XCTAssertEqual(allowed.audit.action, "interrupt"); XCTAssertEqual(allowed.driverKeys, driver.keys)
        XCTAssertEqual(ran.map(\.action), ["interrupt"])
        XCTAssertEqual(ep.outbox.entries, [TeamControl.Outbox.Entry(to: driver.kid, ack: allowed.ack)])
        XCTAssertNil(TeamControl.decide("c-p000000001", allow: true, endpoint: &ep), "decided once")
        // Deny.
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000003", thread: "-", action: "new", text: "x", project: "p")), endpoint: &ep).ack.outcome, "pending")
        XCTAssertEqual(TeamControl.decide("c-p000000003", allow: false, endpoint: &ep)?.ack.outcome, "denied")
        XCTAssertEqual(ran.count, 1)
        // Revoked meanwhile: the grant is re-read at the tap.
        var grants = grant([TeamGrants.interrupt])
        var revocable = endpoint(grants: grants) { ran.append($0) }
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000004", action: "interrupt", text: nil)), endpoint: &revocable).ack.outcome, "pending")
        grants = TeamGrants()
        revocable.grants = { grants }
        XCTAssertEqual(TeamControl.decide("c-p000000004", allow: true, endpoint: &revocable)?.ack.outcome, "revoked")
        // Gone meanwhile: the thread is re-read at the tap.
        var dying = endpoint(grants: grant([TeamGrants.interrupt])) { ran.append($0) }
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000005", action: "interrupt", text: nil)), endpoint: &dying).ack.outcome, "pending")
        dying.threads = { [] }
        XCTAssertEqual(TeamControl.decide("c-p000000005", allow: true, endpoint: &dying)?.ack.outcome, "notLive")
        XCTAssertEqual(ran.count, 1)
        // Timed out: dropped, the driver hears `expired` through the outbox.
        var slow = endpoint(grants: grant([TeamGrants.interrupt]))
        XCTAssertEqual(TeamControl.handle(try sealed(command(id: "c-p000000006", action: "interrupt", text: nil)), endpoint: &slow).ack.outcome, "pending")
        slow.now = { Date(timeIntervalSince1970: Double(1_010 + TeamControl.approvalTTL)) }
        XCTAssertNil(TeamControl.decide("c-p000000006", allow: true, endpoint: &slow))
        XCTAssertEqual(slow.outbox.entries.map { "\($0.ack.id)=\($0.ack.outcome)" }, ["c-p000000006=expired"])
        XCTAssertTrue(slow.pending.isEmpty)
    }

    func testOutboxRoundTripsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TeamControl.Outbox.load(teamDir: dir).entries, [])
        var box = TeamControl.Outbox()
        box.entries.append(.init(to: "k1", ack: .init(id: "c-0123456789", outcome: "denied", detail: nil, at: 5)))
        try box.save(teamDir: dir)
        XCTAssertEqual(TeamControl.Outbox.load(teamDir: dir), box)
    }
}
