import XCTest
@testable import InfinitusCore

/// #1137: the app must not follow a `fork_server_port` publish onto a port
/// that serves nothing. These pin the verdict and the wording; the AppModel
/// guard that calls them is five lines over `answers`.
final class ForkServerProbeTests: XCTestCase {
    private struct Refused: Error {}

    private func transport(_ body: @escaping @Sendable (URL) throws -> Int) -> ForkServerProbe.Transport {
        { url in try body(url) }
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
    /// connection. `asked` records the probe order.
    private func fleet(_ alive: Set<Int>, asked: Asked? = nil) -> ForkServerProbe.Transport {
        { url in
            let port = url.port ?? 0
            asked?.ports.append(port)
            guard alive.contains(port) else { throw Refused() }
            return 200
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

    func testWithNoWorkingTargetToLoseThePublishGoesThrough() async {
        // The app started before any backend, or the pref holds a stale
        // number: refusing here would wedge the pref and protect nothing.
        let verdict = await ForkServerProbe.verdict(newPort: 3841, currentPort: 3773, using: fleet([]))
        XCTAssertEqual(verdict, .accept)
    }

    func testAnInvalidPortIsNotRefusedWhileNothingIsServing() async {
        // `ForkTunnelStatus` reports an out-of-range port as invalidPort and
        // runs no tunnel on it, so storing it costs nothing when there is no
        // live target to displace.
        let verdict = await ForkServerProbe.verdict(newPort: 70000, currentPort: 3773, using: fleet([]))
        XCTAssertEqual(verdict, .accept)
        // With a server actually up, swapping it for an unusable port is the
        // same trade the rule exists to stop.
        let guarded = await ForkServerProbe.verdict(newPort: 70000, currentPort: 3773, using: fleet([3773]))
        XCTAssertEqual(guarded, .refuse)
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
