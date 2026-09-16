import XCTest
@testable import InfinitusCore

final class GcloudLoginTests: XCTestCase {
    func testArgumentsPerProfileAndFlow() {
        XCTAssertEqual(GcloudLogin.arguments(profile: "default", flow: .remote), ["auth", "login", "--no-launch-browser"])
        // A named account gets --force: gcloud would otherwise ask to overwrite its live credentials on a tty nobody answers.
        XCTAssertEqual(GcloudLogin.arguments(profile: "me@example.com", flow: .remote), ["auth", "login", "me@example.com", "--force", "--no-launch-browser"])
        XCTAssertEqual(GcloudLogin.arguments(profile: "default", flow: .local), ["auth", "login"])
        // The relay keeps the CLI's localhost listener; the runner suppresses the browser (#403).
        XCTAssertEqual(GcloudLogin.arguments(profile: "me@example.com", flow: .relay), ["auth", "login", "me@example.com", "--force"])
        XCTAssertEqual(GcloudLogin.arguments(profile: GcloudLogin.adcProfile, flow: .relay), ["auth", "application-default", "login"])
        XCTAssertEqual(AwsLogin.Provider.gcloud.flow(profile: "me@example.com", configText: ""), .relay)
        XCTAssertEqual(GcloudLogin.arguments(profile: GcloudLogin.adcProfile, flow: .remote),
                       ["auth", "application-default", "login", "--no-launch-browser"])
    }

    func testParsesThePasteBackPrompt() {
        // Captured 2026-09-09 from `gcloud auth login --no-launch-browser` (SDK 552).
        let prompt = """
        Go to the following link in your browser, and complete the sign-in prompts:

            https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=x&redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob

        Once finished, enter the verification code provided in your browser:\u{20}
        """
        let p = GcloudLogin.parseOutput(prompt)
        XCTAssertEqual(p.url, "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=x&redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob")
        XCTAssertTrue(p.wantsCode)
        XCTAssertFalse(p.succeeded)
        XCTAssertTrue(GcloudLogin.parseOutput(prompt + "4/0AX4\n\nYou are now logged in as [me@example.com].\nYour current project is [p].").succeeded)
        XCTAssertTrue(GcloudLogin.parseOutput("Credentials saved to file: [/Users/me/.config/gcloud/application_default_credentials.json]").succeeded)
        XCTAssertFalse(GcloudLogin.parseOutput("ERROR: gcloud crashed (EOFError): EOF when reading a line").succeeded)
    }

    func testTheRelayRunPrintsItsURLAndTheCallbackIsGcloudShaped() {
        // Captured 2026-09-09: `BROWSER=/usr/bin/true gcloud auth login` (SDK 552) prints
        // the URL and then waits on http://localhost:8085/ — no code prompt.
        let output = """
        Your browser has been opened to visit:

            https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&scope=openid&state=S&code_challenge=C

        """
        let p = GcloudLogin.parseOutput(output)
        XCTAssertEqual(p.url?.hasPrefix("https://accounts.google.com/o/oauth2/auth?"), true)
        XCTAssertFalse(p.wantsCode)
        XCTAssertEqual(AwsLogin.callbackPort(inURL: p.url ?? ""), 8085)
        let callback = "http://localhost:8085/?state=S&code=4%2F0AX4&scope=openid"
        XCTAssertTrue(AwsLogin.isValidCallback(callback, port: 8085, provider: .gcloud))
        XCTAssertTrue(AwsLogin.isValidCallback("http://localhost:8085?code=c", port: 8085, provider: .gcloud), "no path at all")
        XCTAssertFalse(AwsLogin.isValidCallback(callback, port: 8085), "an aws run takes no gcloud callback")
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:8085/oauth/callback?code=c", port: 8085, provider: .gcloud), "and no aws one for gcloud")
        XCTAssertFalse(AwsLogin.isValidCallback("http://localhost:8086/?code=c", port: 8085, provider: .gcloud), "wrong port")
        XCTAssertFalse(AwsLogin.isValidCallback("http://localhost:8085/?error=access_denied&state=S", port: 8085, provider: .gcloud))
        XCTAssertFalse(AwsLogin.isValidCallback("https://accounts.google.com/?code=c", port: 8085, provider: .gcloud))
    }

    func testProviderRidesTheExistingWireShapesAndOldEntriesStayAws() throws {
        let state = AwsLogin.State(profile: "default", flow: .remote, startedAt: 1, provider: .gcloud)
        let back = try JSONDecoder().decode(AwsLogin.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.provider, .gcloud)
        // A ledger entry or a phone body from before the field: aws.
        let old = try JSONDecoder().decode(AwsLogin.State.self, from: Data(#"{"profile":"p","flow":"remote","phase":"done","startedAt":1}"#.utf8))
        XCTAssertNil(old.provider)
        XCTAssertEqual(old.providerOrAws, .aws)
        let start = try JSONDecoder().decode(AwsLogin.StartRequest.self, from: Data(#"{"profile":"me@example.com","provider":"gcloud"}"#.utf8))
        XCTAssertEqual(start.provider, .gcloud)
        // Item ids: the aws one is byte-identical to before (persisted in the announced set); gcloud's is distinct.
        XCTAssertEqual(AwsLogin.Item(profile: "p", flow: .remote, state: nil).id, "p")
        XCTAssertEqual(AwsLogin.Item(profile: "p", flow: .remote, state: nil, provider: .gcloud).id, "gcloud:p")
        XCTAssertEqual(AwsLogin.runKey(provider: .aws, profile: "default"), "aws:default")
        XCTAssertNotEqual(AwsLogin.runKey(provider: .aws, profile: "default"), AwsLogin.runKey(provider: .gcloud, profile: "default"))
    }

    /// A phone from before the field sends no provider: the outstanding
    /// items say which CLI the profile belongs to.
    func testAProviderlessBodyResolvesAgainstTheOutstandingItems() {
        let items = [AwsLogin.Item(profile: "default", flow: .remote, state: nil, provider: .gcloud),
                     AwsLogin.Item(profile: "me@example.com", flow: .remote, state: nil, provider: .gcloud)]
        XCTAssertEqual(AwsLogin.inferProvider(profile: "default", items: items), .gcloud, "first outstanding item for the profile")
        XCTAssertEqual(AwsLogin.inferProvider(profile: "me@example.com", items: items), .gcloud)
        XCTAssertEqual(AwsLogin.inferProvider(profile: "unknown", items: items), .aws)
    }

}
