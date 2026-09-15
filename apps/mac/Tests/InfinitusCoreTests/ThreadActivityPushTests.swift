import Foundation
import XCTest
@testable import InfinitusCore

/// #1047: the desktop's thread card state on the `push` verb.
final class ThreadActivityPushTests: XCTestCase {
    private let state = """
    {"kind":"thread.activity","state":{"title":"2 threads working","subtitle":"limitless","activeCount":2,
     "updatedAt":"2026-09-13T10:00:00Z","activities":[{"threadId":"t1","threadTitle":"Nightly track","phase":"running",
     "status":"Working","updatedAt":"2026-09-13T10:00:00Z","deepLink":"/e/t1","projectTitle":"limitless","modelTitle":"Fable"}]}}
    """

    func testAStateParsesWithSortedPropsAndTheHeadline() throws {
        guard case .show(let parsed)? = ThreadActivityPush.parse(state) else { return XCTFail("expected a card") }
        XCTAssertEqual(parsed.title, "2 threads working")
        XCTAssertEqual(parsed.subtitle, "limitless")
        XCTAssertTrue(parsed.props.hasPrefix("{\"activeCount\":2,\"activities\":[{"))
        // The same state in another key order is the same string.
        let reordered = state.replacingOccurrences(of: "\"title\":\"2 threads working\",\"subtitle\":\"limitless\",",
                                                   with: "\"subtitle\":\"limitless\",\"title\":\"2 threads working\",")
        guard case .show(let again)? = ThreadActivityPush.parse(reordered) else { return XCTFail("expected a card") }
        XCTAssertEqual(again, parsed)
    }

    /// #1041 d6: `activeCount` survives parse — it is the desktop's busy
    /// signal for `WindowPlanner` now that the terminal session count is gone.
    func testActiveCountSurvivesParse() throws {
        guard case .show(let parsed)? = ThreadActivityPush.parse(state) else { return XCTFail("expected a card") }
        XCTAssertEqual(parsed.activeCount, 2)
    }

    func testANullStateEndsTheCard() {
        XCTAssertEqual(ThreadActivityPush.parse(#"{"kind":"thread.activity","state":null}"#), .end)
    }

    func testStrayShapesAreRefused() {
        XCTAssertNil(ThreadActivityPush.parse(#"{"kind":"thread.phase","threadId":"t","phase":"failed"}"#))
        XCTAssertNil(ThreadActivityPush.parse(#"{"kind":"thread.activity"}"#))
        XCTAssertNil(ThreadActivityPush.parse(#"{"kind":"thread.activity","state":{"title":"x"}}"#))
        XCTAssertNil(ThreadActivityPush.parse(#"{"kind":"thread.activity","state":{"title":" ","subtitle":"","activeCount":0,"updatedAt":"now","activities":[]}}"#))
        XCTAssertNil(ThreadActivityPush.parse("not json"))
    }

    func testPayloadsCarryTheExpoEnvelopeAndTheEvents() throws {
        guard case .show(let parsed)? = ThreadActivityPush.parse(state) else { return XCTFail("expected a card") }
        let now = Date(timeIntervalSince1970: 1_000_000)
        func aps(_ data: Data) throws -> [String: Any] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["aps"] as? [String: Any])
        }
        let start = try aps(LiveActivityPush.agentActivityStartPayload(parsed, now: now))
        XCTAssertEqual(start["event"] as? String, "start")
        XCTAssertEqual(start["attributes-type"] as? String, "LiveActivityAttributes")
        XCTAssertEqual((start["attributes"] as? [String: Any])?.count, 0)
        XCTAssertEqual(start["input-push-token"] as? Int, 1)
        XCTAssertEqual((start["alert"] as? [String: String])?["title"], "2 threads working")
        XCTAssertEqual(start["stale-date"] as? Int, 1_000_000 + 600)
        let content = try XCTUnwrap(start["content-state"] as? [String: Any])
        XCTAssertEqual(content["name"] as? String, "AgentActivity")
        XCTAssertEqual(content["props"] as? String, parsed.props)

        let update = try aps(LiveActivityPush.agentActivityUpdatePayload(parsed, now: now))
        XCTAssertEqual(update["event"] as? String, "update")
        XCTAssertNil(update["alert"])
        XCTAssertEqual((update["content-state"] as? [String: Any])?["name"] as? String, "AgentActivity")

        let end = try aps(LiveActivityPush.agentActivityEndPayload(parsed, now: now))
        XCTAssertEqual(end["event"] as? String, "end")
        XCTAssertEqual(end["dismissal-date"] as? Int, 1_000_000 + 300)
        XCTAssertNotNil(end["content-state"])
        let bareEnd = try aps(LiveActivityPush.agentActivityEndPayload(nil, now: now))
        XCTAssertEqual(bareEnd["dismissal-date"] as? Int, 1_000_000 + 15)
        XCTAssertNil(bareEnd["content-state"])
    }

    func testTheCardKindsRideTheLiveActivityTopicAndTheAlertDoesNot() {
        XCTAssertTrue(ActivityPushRegistration.Kind.agentActivity.isLiveActivity)
        XCTAssertTrue(ActivityPushRegistration.Kind.agentActivityStart.isLiveActivity)
        XCTAssertFalse(ActivityPushRegistration.Kind.alert.isLiveActivity)
        XCTAssertEqual(LiveActivityPush.topic, "run.infinitus.mobile.push-type.liveactivity")
        XCTAssertEqual(ActivityPushRegistration.Kind(rawValue: "agent-activity-start"), .agentActivityStart)
    }
}

/// The `push` reply says what was addressed (`targets`, `kinds`).
/// #1265: a live card token the phone stopped re-offering is written off
/// once its last update is older than twice the stale window.
final class LiveTokenLapsedTests: XCTestCase {
    private let registered = Date(timeIntervalSince1970: 1_000_000)

    func testAQuietTokenLapsesAfterTwiceTheStaleWindow() {
        let updated = registered.addingTimeInterval(60)
        XCTAssertFalse(LiveActivityPush.liveTokenLapsed(registeredAt: registered, lastUpdateAt: updated,
                                                        now: updated.addingTimeInterval(LiveActivityPush.staleAfter * 2)))
        XCTAssertTrue(LiveActivityPush.liveTokenLapsed(registeredAt: registered, lastUpdateAt: updated,
                                                       now: updated.addingTimeInterval(LiveActivityPush.staleAfter * 2 + 1)))
    }

    func testATokenReOfferedSinceTheUpdateIsKept() {
        let updated = registered.addingTimeInterval(60)
        XCTAssertFalse(LiveActivityPush.liveTokenLapsed(registeredAt: updated.addingTimeInterval(1), lastUpdateAt: updated,
                                                        now: updated.addingTimeInterval(LiveActivityPush.staleAfter * 3)))
    }
}

/// #941 follow-up: a push's outcome is readable from the Mac's event log.
final class PushOutcomeLineTests: XCTestCase {
    func testAStartedOrEndedCardGetsALineAndAnUpdateDoesNot() {
        XCTAssertEqual(LiveActivityPush.outcomeLine(what: "start thread card", device: "iPhone", status: 200, body: "",
                                                    error: nil, tokenDropped: false),
                       "thread card started on iPhone (push-to-start)")
        XCTAssertEqual(LiveActivityPush.outcomeLine(what: "end thread card", device: "iPhone", status: 200, body: "",
                                                    error: nil, tokenDropped: false),
                       "thread card ended on iPhone")
        XCTAssertNil(LiveActivityPush.outcomeLine(what: "update thread card", device: "iPhone", status: 200, body: "",
                                                  error: nil, tokenDropped: false))
        XCTAssertNil(LiveActivityPush.outcomeLine(what: "alert", device: "iPhone", status: 200, body: "",
                                                  error: nil, tokenDropped: false))
    }

    func testAFailureNamesTheKindTheReasonAndADroppedToken() {
        XCTAssertEqual(LiveActivityPush.outcomeLine(what: "update thread card", device: "iPhone", status: 410,
                                                    body: #"{"reason":"Unregistered","timestamp":1}"#,
                                                    error: nil, tokenDropped: true),
                       "update thread card → iPhone failed: HTTP 410 Unregistered — token dropped")
        XCTAssertEqual(LiveActivityPush.outcomeLine(what: "alert", device: "iPhone", status: 0, body: "",
                                                    error: "A server with the specified hostname could not be found.",
                                                    tokenDropped: false),
                       "alert → iPhone failed: A server with the specified hostname could not be found.")
        XCTAssertEqual(LiveActivityPush.outcomeLine(what: "start thread card", device: "iPhone", status: 400,
                                                    body: "not json", error: nil, tokenDropped: false),
                       "start thread card → iPhone failed: HTTP 400 not json")
    }
}

final class PushReachTests: XCTestCase {
    func testNothingSentReadsZero() {
        let reach = PushReach()
        XCTAssertEqual(reach.targets, 0)
        XCTAssertEqual(reach.replyFields, ["targets": .number(0), "kinds": .object([:])])
    }

    func testOnePhoneTwoKindsCountsOneTarget() {
        var reach = PushReach()
        reach.add(device: "phone-a", kind: "agent-activity")
        reach.add(device: "phone-a", kind: "alert")
        reach.add(device: "phone-b", kind: "agent-activity-start")
        XCTAssertEqual(reach.targets, 2)
        XCTAssertEqual(reach.kinds, ["agent-activity": 1, "alert": 1, "agent-activity-start": 1])
        XCTAssertEqual(reach.replyFields["targets"], .number(2))
        XCTAssertEqual(reach.replyFields["kinds"]?["alert"], .number(1))
    }
}
