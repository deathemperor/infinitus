import XCTest
@testable import InfinitusCore

final class OAuthRedirectRelayTests: XCTestCase {
    private let authURL = URL(string: "https://claude.ai/oauth/authorize?code=true&client_id=abc"
        + "&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"
        + "&scope=org%3Acreate_api_key&state=st%2F1")!

    func testLoopbackPortReadsTheRedirectURI() {
        XCTAssertEqual(OAuthRedirectRelay.loopbackPort(of: authURL), 54545)
    }

    func testNoPortForAHostedOrMissingRedirect() {
        let hosted = URL(string: "https://claude.ai/oauth/authorize?redirect_uri="
            + "https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback")!
        XCTAssertNil(OAuthRedirectRelay.loopbackPort(of: hosted))
        XCTAssertNil(OAuthRedirectRelay.loopbackPort(of: URL(string: "https://claude.ai/oauth")!))
        // A LAN address is not loopback: nothing relays to it.
        let lan = URL(string: "https://x/?redirect_uri=http%3A%2F%2F192.168.1.5%3A54545%2Fcallback")!
        XCTAssertNil(OAuthRedirectRelay.loopbackPort(of: lan))
        // No port spelled: the engine's listener is always on one.
        let bare = URL(string: "https://x/?redirect_uri=http%3A%2F%2Flocalhost%2Fcallback")!
        XCTAssertNil(OAuthRedirectRelay.loopbackPort(of: bare))
    }

    func testReplayKeepsPathAndQueryOnTheListener() {
        let pasted = "  http://localhost:54545/callback?code=abc%2Fdef&state=st%2F1\n"
        XCTAssertEqual(
            OAuthRedirectRelay.replayURL(pasted: pasted, port: 54545)?.absoluteString,
            "http://127.0.0.1:54545/callback?code=abc%2Fdef&state=st%2F1")
        XCTAssertEqual(
            OAuthRedirectRelay.replayURL(pasted: "http://127.0.0.1:54545/callback?code=x", port: 54545)?
                .absoluteString,
            "http://127.0.0.1:54545/callback?code=x")
        XCTAssertEqual(
            OAuthRedirectRelay.replayURL(pasted: "http://[::1]:54545/callback?code=x", port: 54545)?
                .absoluteString,
            "http://127.0.0.1:54545/callback?code=x")
    }

    func testReplayRefusesAnythingButThisSignInsListener() {
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "", port: 54545))
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "not a url", port: 54545))
        // The code alone, or the wrong port, is not the address the browser ended on.
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "abc#st/1", port: 54545))
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "http://localhost:8080/callback?code=x", port: 54545))
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "http://localhost/callback?code=x", port: 54545))
        // Never off this machine, whatever the port says.
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "http://example.com:54545/callback?code=x", port: 54545))
        XCTAssertNil(OAuthRedirectRelay.replayURL(pasted: "https://localhost:54545/callback?code=x", port: 54545))
    }
}
