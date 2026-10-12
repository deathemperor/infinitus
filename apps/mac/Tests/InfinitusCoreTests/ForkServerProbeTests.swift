import XCTest
@testable import InfinitusCore

/// #1137: the app must not follow a `fork_server_port` publish onto a port
/// that serves nothing. #1487: nor one from another environment than the
/// slot's holder while that holder answers. These pin the verdict and the
/// wording; the AppModel guard that calls them is a switch over the verdict.
final class ForkServerProbeTests: XCTestCase {
    private struct Refused: Error {}

    private func transport(_ body: @escaping @Sendable (URL) throws -> Int) -> ForkServerProbe.Transport {
        { url in ForkServerProbe.Answer(status: try body(url)) }
    }

    func testItProbesTheWellKnownRouteOnLoopback() async {
        let seen = SeenURL()
        _ = await ForkServerProbe.answers(port: 3841, using: transport { url in
            seen.value = url
            return 200
        })
        XCTAssertEqual(seen.value?.absoluteString, "http://127.0.0.1:3841/.well-known/t3/environment")
    }

    func testAServerThatAnswersIsFollowed() async {
        let ok = await ForkServerProbe.answers(port: 3773, using: transport { _ in 200 })
        XCTAssertTrue(ok)
        // 204 is still a server; the range is what matters, not the code.
        let noContent = await ForkServerProbe.answers(port: 3773, using: transport { _ in 204 })
        XCTAssertTrue(noContent)
    }

    func testAPortNothingListensOnIsRefused() async {
        // What the incident looked like: connection refused, nothing there.
        let ok = await ForkServerProbe.answers(port: 3841, using: transport { _ in throw Refused() })
        XCTAssertFalse(ok)
    }

    func testSomethingElseOnThePortIsRefused() async {
        // Another app answering is not an Infinitus server: following the
        // publish there is the same defect, not a milder one.
        for status in [301, 401, 404, 500] {
            let ok = await ForkServerProbe.answers(port: 3841, using: transport { _ in status })
            XCTAssertFalse(ok, "status \(status) must not count as answering")
        }
    }

    func testANonsensePortOpensNoSocket() async {
        let opened = Opened()
        for port in [0, -1, 65536, 99999] {
            let ok = await ForkServerProbe.answers(port: port, using: transport { _ in
                opened.value = true
                return 200
            })
            XCTAssertFalse(ok, "port \(port) must be refused")
        }
        XCTAssertFalse(opened.value, "a port outside 1...65535 is refused before any request")
    }

    // MARK: the whole rule

    /// Ports that answer, by number; anything else throws like a refused
    /// connection. `asked` records the probe order. `identities` names the
    /// environment each live port reports (#1487).
    private func fleet(_ alive: Set<Int>, asked: Asked? = nil, identities: [Int: String] = [:]) -> ForkServerProbe.Transport {
        { url in
            let port = url.port ?? 0
            asked?.ports.append(port)
            guard alive.contains(port) else { throw Refused() }
            return ForkServerProbe.Answer(status: 200, environmentId: identities[port])
        }
    }

    func testTheHeartbeatOnTheLivePortIsNeverProbed() async {
        let asked = Asked()
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3773, using: fleet([3773], asked: asked))
        XCTAssertEqual(verdict, .accept)
        XCTAssertEqual(asked.ports, [], "re-publishing the port in use must cost no exchange")
    }

    func testAMoveOntoALiveServerIsFollowedWithOneProbe() async {
        let asked = Asked()
        let verdict = await ForkServerProbe.verdict(newPort: 3841, currentPort: 3773, using: fleet([3773, 3841], asked: asked))
        XCTAssertEqual(verdict, .accept)
        XCTAssertEqual(asked.ports, [3841], "the port it would leave needs no probe once the new one answers")
    }

    func testTradingAWorkingTargetForASilentOneIsRefused() async {
        // The defect: :3773 is serving, :3841 is not, and the app followed.
        let verdict = await ForkServerProbe.verdict(newPort: 3841, currentPort: 3773, using: fleet([3773]))
        XCTAssertEqual(verdict, .refuse)
    }

    /// #1199: an instance that never published sits on the default port; a
    /// server answering there is another instance's (the installed app's
    /// desktop on a dev Mac), not a target of its own to lose — and no probe
    /// of that port is made at all.
    func testAnInstanceThatNeverPublishedFollowsItsFirstPublish() async {
        let asked = Asked()
        let verdict = await ForkServerProbe.verdict(newPort: 70000, currentPort: nil, using: fleet([3773], asked: asked))
        XCTAssertEqual(verdict, .accept)
        XCTAssertEqual(asked.ports, [])
    }

    func testWithNoWorkingTargetToLoseThePublishGoesThrough() async {
        // The app started before any backend, or the pref holds a stale
        // number: refusing here would wedge the pref and protect nothing.
        let verdict = await ForkServerProbe.verdict(newPort: 3841, currentPort: 3773, using: fleet([]))
        XCTAssertEqual(verdict, .accept)
    }

    func testAnInvalidPortIsNotRefusedWhileNothingIsServing() async {
        // `url(port:)` refuses an out-of-range port before any socket, so
        // storing it costs nothing when there is no live target to displace.
        let verdict = await ForkServerProbe.verdict(newPort: 70000, currentPort: 3773, using: fleet([]))
        XCTAssertEqual(verdict, .accept)
        // With a server actually up, swapping it for an unusable port is the
        // same trade the rule exists to stop.
        let guarded = await ForkServerProbe.verdict(newPort: 70000, currentPort: 3773, using: fleet([3773]))
        XCTAssertEqual(guarded, .refuse)
    }

    // MARK: whose slot it is (#1487)

    private let desktop = ForkServerProbe.Publisher(environmentId: "env-desktop")
    private let sandbox = ForkServerProbe.Publisher(environmentId: "env-sandbox")

    func testAPublishFromAnotherEnvironmentIsHeldWhileTheHolderAnswersAsItself() async {
        // The installed desktop (:3773) publishing while an opted-in dev
        // server (env-sandbox, :3841) holds the slot and is alive.
        let asked = Asked()
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3841, publisher: desktop, holder: "env-sandbox",
                                                   using: fleet([3773, 3841], asked: asked, identities: [3841: "env-sandbox", 3773: "env-desktop"]))
        XCTAssertEqual(verdict, .held("env-sandbox"))
        XCTAssertEqual(asked.ports, [3841], "only the holder's port is asked, once")
    }

    func testTheSlotIsFreeOnceTheHolderIsGone() async {
        // The dev server quit: the desktop's next heartbeat takes the slot.
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3841, publisher: desktop, holder: "env-sandbox",
                                                   using: fleet([3773], identities: [3773: "env-desktop"]))
        XCTAssertEqual(verdict, .accept)
    }

    func testAnotherServerOnTheHoldersPortDoesNotKeepTheSlot() async {
        // The worktree's next dev server lands on the same stable port but
        // never published: the port answers, the holder does not.
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3841, publisher: desktop, holder: "env-sandbox",
                                                   using: fleet([3773, 3841], identities: [3841: "env-other-sandbox", 3773: "env-desktop"]))
        XCTAssertEqual(verdict, .accept)
    }

    func testATakeoverIsFollowedOverALiveHolder() async {
        // The opted-in dev server publishing over the installed desktop.
        let takeover = ForkServerProbe.Publisher(environmentId: "env-sandbox", takeover: true)
        let verdict = await ForkServerProbe.verdict(newPort: 3841, currentPort: 3773, publisher: takeover, holder: "env-desktop",
                                                   using: fleet([3773, 3841], identities: [3773: "env-desktop", 3841: "env-sandbox"]))
        XCTAssertEqual(verdict, .accept)
    }

    func testTheHolderItselfMovingPortIsTheOldRule() async {
        // Same environment, new port (a restart landed elsewhere): no hold,
        // and #1137's probe of the new port decides.
        let moved = await ForkServerProbe.verdict(newPort: 3774, currentPort: 3773, publisher: desktop, holder: "env-desktop",
                                                  using: fleet([3774], identities: [3774: "env-desktop"]))
        XCTAssertEqual(moved, .accept)
        let silent = await ForkServerProbe.verdict(newPort: 3774, currentPort: 3773, publisher: desktop, holder: "env-desktop",
                                                   using: fleet([3773], identities: [3773: "env-desktop"]))
        XCTAssertEqual(silent, .refuse)
    }

    func testAPublishWithoutAnIdentityIsHeldLikeAForeignOne() async {
        // A server that predates the option publishing over a live holder.
        let anonymous = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3841, publisher: ForkServerProbe.Publisher(), holder: "env-sandbox",
                                                      using: fleet([3773, 3841], identities: [3841: "env-sandbox"]))
        XCTAssertEqual(anonymous, .held("env-sandbox"))
    }

    func testWithNoHolderRecordedThereIsNothingToHold() async {
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3841, publisher: desktop, holder: nil,
                                                    using: fleet([3773, 3841], identities: [3841: "env-sandbox"]))
        XCTAssertEqual(verdict, .accept)
    }

    func testTheSamePortIsNeverHeld() async {
        // The pref already names this port: whoever answers there is the
        // target the credential points at, and refusing would wedge a
        // desktop whose home was wiped (a new environment id, same port).
        let asked = Asked()
        let verdict = await ForkServerProbe.verdict(newPort: 3773, currentPort: 3773, publisher: desktop, holder: "env-old-desktop",
                                                    using: fleet([3773], asked: asked))
        XCTAssertEqual(verdict, .accept)
        XCTAssertEqual(asked.ports, [])
    }

    func testTheBodyYieldsTheEnvironmentId() async {
        let body = Data(#"{"environmentId":"env-desktop","serverVersion":"0.5.0"}"#.utf8)
        XCTAssertEqual(ForkServerProbe.environmentId(in: body), "env-desktop")
        XCTAssertNil(ForkServerProbe.environmentId(in: Data("not json".utf8)))
        XCTAssertNil(ForkServerProbe.environmentId(in: Data(#"{"environmentId":""}"#.utf8)))
        let identity = await ForkServerProbe.identity(port: 3773, using: { _ in ForkServerProbe.Answer(status: 200, environmentId: "env-desktop") })
        XCTAssertEqual(identity, "env-desktop")
        // Something else answering with a body is not an Infinitus server.
        let notAServer = await ForkServerProbe.identity(port: 3773, using: { _ in ForkServerProbe.Answer(status: 404, environmentId: "env-desktop") })
        XCTAssertNil(notAServer)
    }

    func testTheHeldReplyOpensWithTheWordsTheServerMatches() {
        let reply = ForkServerProbe.heldReply(port: 3773, holder: "env-sandbox", currentPort: 3841)
        // `HELD_REPLY_PREFIX` in apps/server/src/infinitus/Layers/InfinitusServerPort.ts.
        XCTAssertTrue(reply.hasPrefix("held by environment env-sandbox"))
        XCTAssertTrue(reply.contains("3841"))
        XCTAssertTrue(reply.contains("INFINITUS_PUBLISH_SERVER_PORT=1"))
        XCTAssertEqual(ForkServerProbe.heldLine(port: 3773, holder: "env-sandbox"),
                       "fork server: publish from :3773 held off — environment env-sandbox holds the slot")
    }

    func testTheRefusalNamesThePortAndTheReason() {
        XCTAssertEqual(
            ForkServerProbe.refusalLine(port: 3841),
            "fork server: publish from :3841 refused — not answering",
        )
        XCTAssertTrue(ForkServerProbe.refusalReply(port: 3841).contains("3841"))
        XCTAssertTrue(ForkServerProbe.refusalReply(port: 3841).contains("previous target is kept"))
    }

    func testTheProbeDeadlineStaysOffTheCommandPath() {
        // It runs on the main actor's command path; a long timeout there is
        // a hang, not a slow check.
        XCTAssertLessThanOrEqual(ForkServerProbe.timeoutSeconds, 3)
    }
}

private final class SeenURL: @unchecked Sendable { var value: URL? }
private final class Opened: @unchecked Sendable { var value = false }
private final class Asked: @unchecked Sendable { var ports: [Int] = [] }
