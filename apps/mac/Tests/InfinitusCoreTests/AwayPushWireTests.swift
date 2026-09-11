import XCTest
@testable import InfinitusCore

final class AwayPushWireTests: XCTestCase {
    func testSlackTakesOnlyAnHTTPSURL() {
        XCTAssertEqual(AwayPushWire.slackWebhook(" https://hooks.slack.com/services/T0/B0/x \n")?.absoluteString,
                       "https://hooks.slack.com/services/T0/B0/x")
        XCTAssertNil(AwayPushWire.slackWebhook("http://hooks.slack.com/services/T0/B0/x"))
        XCTAssertNil(AwayPushWire.slackWebhook("not a url"))
        XCTAssertNil(AwayPushWire.slackWebhook(""))
    }

    func testSlackRequestPostsTheTextAsJSON() throws {
        let request = AwayPushWire.slackRequest(webhook: URL(string: "https://hooks.slack.com/services/T0/B0/x")!,
                                                text: "all sessions finished")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["text": "all sessions finished"])
    }

    func testTelegramRequestNamesTheBotAndChat() throws {
        let request = try XCTUnwrap(AwayPushWire.telegramRequest(token: "123456:ABC-def_Ghi", chat: "-1001", text: "hi"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.telegram.org/bot123456:ABC-def_Ghi/sendMessage")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(json, ["chat_id": "-1001", "text": "hi"])
        XCTAssertNotNil(AwayPushWire.telegramRequest(token: "1:a", chat: "@room", text: "hi"))
    }

    func testTelegramRefusesTheWrongShapes() {
        XCTAssertNil(AwayPushWire.telegramRequest(token: "no-colon", chat: "1", text: "hi"))
        XCTAssertNil(AwayPushWire.telegramRequest(token: "abc:def", chat: "1", text: "hi"))
        XCTAssertNil(AwayPushWire.telegramRequest(token: "1:a/b", chat: "1", text: "hi"))
        XCTAssertNil(AwayPushWire.telegramRequest(token: "1:a", chat: "room", text: "hi"))
        XCTAssertNil(AwayPushWire.telegramRequest(token: "1:a", chat: "@", text: "hi"))
    }

    func testMaskedNeverShowsAShortSecret() {
        XCTAssertEqual(AwayPushWire.masked("12345678"), "••••")
        XCTAssertEqual(AwayPushWire.masked("123456:ABCDEF"), "••••CDEF")
    }
}
