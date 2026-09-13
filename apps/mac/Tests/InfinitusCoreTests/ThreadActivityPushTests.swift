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
