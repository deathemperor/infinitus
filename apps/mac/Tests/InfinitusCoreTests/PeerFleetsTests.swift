import XCTest
@testable import InfinitusCore

/// Other machines' fleets over `peer-sync` (#1545): the desktop's push
/// decodes into the popup's own fleet model, and a row's action waits on
/// the desktop's answer, or gives up.
final class PeerFleetsTests: XCTestCase {
    private let push = #"""
    {"machines":[{"id":"env-1","label":"HyperNovae","connected":true,"fleets":[
      {"key":"swapd/claude","engineID":"swapd","provider":"claude",
       "capabilities":["switch","hold","prefer","autoIgnite","rename","remove","addOAuth","ignite"],
       "activeNumber":2,"nextCandidate":1,
       "accounts":[
        {"number":1,"email":"one@example.com","active":false,"isOrganization":false,"usageStatus":"ok",
         "usage":{"fiveHour":{"pct":12.5,"countdown":"2h"},"sevenDay":{"pct":40}}},
        {"number":2,"alias":"bloody","email":"two@example.com","plan":"Max 20x","active":true,
         "isOrganization":false,"usageStatus":"ok","disabled":false,"preferred":true,"autoIgnite":true}
       ]},
      {"key":"9router/kiro","engineID":"9router","provider":"kiro","capabilities":["switch"],
       "accounts":[{"number":7,"email":"k@example.com","active":true,"isOrganization":false,"usageStatus":"ok"}]}
    ]},{"id":"env-2","label":"Studio","connected":false,"fleets":null}],
     "results":[{"id":"c1","ok":true},{"id":"c2","ok":false,"error":"no account #9"}]}
    """#

    func testAPushDecodesIntoEngineFleets() throws {
        let request = ControlRequest(command: PeerFleets.command, options: ["body": push])
        let body = try ControlBody.decode(PeerFleets.Body.self, from: request)
        XCTAssertEqual(body.machines.map(\.label), ["HyperNovae", "Studio"])
        XCTAssertNil(body.machines[1].fleets)
        XCTAssertEqual(body.results, [.init(id: "c1", ok: true), .init(id: "c2", ok: false, error: "no account #9")])

        let engineID = PeerFleets.engineID(machine: "env-1", remoteEngine: "swapd")
        XCTAssertEqual(engineID, "peer:env-1:swapd")
        XCTAssertTrue(PeerFleets.isPeer(engineID: engineID))
        XCTAssertFalse(PeerFleets.isPeer(engineID: "swapd"))

        let fleet = PeerFleets.engineFleet(body.machines[0].fleets![0], engineID: engineID)
        XCTAssertEqual(fleet.key, "peer:env-1:swapd/claude")
        XCTAssertEqual(PeerFleets.remoteKeys(body.machines[0].fleets!), [.claude: "swapd/claude", .kiro: "9router/kiro"])
        XCTAssertEqual(fleet.provider, .claude)
        XCTAssertEqual(fleet.activeNumber, 2)
        XCTAssertEqual(fleet.accounts.map(\.number), [1, 2])
        XCTAssertEqual(fleet.accounts[0].usage?.fiveHour?.pct, 12.5)
        XCTAssertEqual(fleet.accounts[0].organizationName, "")
        XCTAssertEqual(fleet.accounts[1].alias, "bloody")
        XCTAssertEqual(fleet.accounts[1].preferred, true)
        XCTAssertEqual(fleet.accounts[1].autoIgnite, true)
        XCTAssertEqual(fleet.accounts[1].plan, "Max 20x")
        // Row actions only: adding an account and igniting stay off a peer row.
        XCTAssertEqual(fleet.capabilities, [.switch, .hold, .prefer, .autoIgnite, .rename, .remove])

        let kiro = PeerFleets.engineFleet(body.machines[0].fleets![1],
                                          engineID: PeerFleets.engineID(machine: "env-1", remoteEngine: "9router"))
        XCTAssertEqual(kiro.provider, .kiro)
    }

    func testAnUnknownProviderDrawsAsOtherAndKeepsItsKey() {
        XCTAssertEqual(PeerFleets.provider("mystery"), .other)
        let doc = PeerFleets.FleetDoc(key: "swapd/mystery", engineID: "swapd", provider: "mystery",
                                      capabilities: [], accounts: [])
        XCTAssertEqual(PeerFleets.remoteKeys([doc]), [.other: "swapd/mystery"])
        XCTAssertEqual(PeerFleets.capabilities(named: ["switch", "teleport"]), [.switch])
    }

    func testAQueuedCommandWaitsForItsResult() async throws {
        let queue = PeerCommandQueue(timeout: 5)
        let command = PeerFleets.Command(id: "c1", machine: "env-1", command: "switch", args: ["swapd/claude", "2"])
        let run = Task { try await queue.run(command) }
        // The desktop drains the queue on its next push…
        var drained: [PeerFleets.Command] = []
        while drained.isEmpty { drained = await queue.drain(); await Task.yield() }
        XCTAssertEqual(drained, [command])
        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 1)
        // …and a second drain hands out nothing new while it is in flight.
        let again = await queue.drain()
        XCTAssertEqual(again, [])
        await queue.resolve(.init(id: "c1", ok: true))
        try await run.value
        let after = await queue.pendingCount
        XCTAssertEqual(after, 0)
    }

    func testAFailedResultSurfacesTheMachinesWords() async {
        let queue = PeerCommandQueue(timeout: 5)
        let run = Task { try await queue.run(PeerFleets.Command(id: "c2", machine: "env-1", command: "remove", args: ["swapd/claude", "9"], options: ["yes": "true"])) }
        var drained: [PeerFleets.Command] = []
        while drained.isEmpty { drained = await queue.drain(); await Task.yield() }
        await queue.resolve(.init(id: "c2", ok: false, error: "no account #9"))
        do {
            try await run.value
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual((error as? PeerFleets.Failure)?.message, "no account #9")
        }
    }

    func testAnUnansweredCommandTimesOutAndALateResultIsDropped() async {
        let queue = PeerCommandQueue(timeout: 0.05)
        let run = Task { try await queue.run(PeerFleets.Command(id: "c3", machine: "env-1", command: "hold", args: ["swapd/claude", "1"])) }
        do {
            try await run.value
            XCTFail("should have timed out")
        } catch {
            XCTAssertEqual((error as? PeerFleets.Failure)?.message.hasPrefix("The desktop app did not answer"), true)
        }
        let pending = await queue.pendingCount
        XCTAssertEqual(pending, 0)
        await queue.resolve(.init(id: "c3", ok: true))   // nothing to resume, no crash
        let drained = await queue.drain()
        XCTAssertEqual(drained, [])
    }

    func testTheVerbIsAWriteWithABody() {
        let command = ControlCommand.named(PeerFleets.command)
        XCTAssertEqual(command?.effect, .write)
        XCTAssertEqual(command?.options, ["--body <json>"])
        XCTAssertNil(command?.stdin)
    }
}
