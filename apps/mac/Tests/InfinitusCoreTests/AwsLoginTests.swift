import XCTest
@testable import InfinitusCore

final class AwsLoginTests: XCTestCase {
    func testFlowFollowsTheProfileKindInTheConfig() {
        let config = """
        [default]
        credential_process = broker
        [profile papaya-login]
        login_session = papaya
        region = ap-southeast-1
        [sso-session papaya]
        sso_start_url = https://x.awsapps.com/start
        [profile papaya-dev]
        sso_session = papaya
        sso_account_id = 1
        """
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-dev", configText: config), .deviceCode)
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-login", configText: config), .relay)
        XCTAssertEqual(AwsLogin.flow(profile: "default", configText: config), .relay)
        XCTAssertEqual(AwsLogin.flow(profile: "missing", configText: config), .relay)
    }

    func testLedgerKeepsAFailureForTheLoginTimeoutAndASignInForADay() {
        let now = Date()
        func state(_ phase: AwsLogin.Phase, ago: TimeInterval) -> AwsLogin.State {
            AwsLogin.State(profile: "p", flow: .remote, phase: phase, startedAt: now.timeIntervalSince1970 - ago)
        }
        XCTAssertTrue(AwsLogin.Ledger.isCurrent(state(.failed, ago: 500), now: now))
        XCTAssertFalse(AwsLogin.Ledger.isCurrent(state(.failed, ago: 700), now: now))
        XCTAssertTrue(AwsLogin.Ledger.isCurrent(state(.done, ago: 20 * 3600), now: now))
        XCTAssertFalse(AwsLogin.Ledger.isCurrent(state(.done, ago: 25 * 3600), now: now))
        XCTAssertFalse(AwsLogin.Ledger.isCurrent(state(.waitingForCode, ago: 1), now: now))
    }

    func testLoginProfileFollowsTheCredentialProcess() {
        let config = """
        [default]
        credential_process = /x/aws-cred-broker.py  default-login
        [profile papaya]
        credential_process = /x/aws-cred-broker.py papaya-login --quiet
        [profile static]
        credential_process = /x/vault read
        [profile default-login]
        login_session = arn:aws:iam::089192911254:user/me
        [profile papaya-login]
        login_session = arn:aws:iam::089192911254:user/me
        """
        XCTAssertEqual(AwsLogin.loginProfile(profile: "default", configText: config), "default-login")
        XCTAssertEqual(AwsLogin.loginProfile(profile: "papaya", configText: config), "papaya-login")
        XCTAssertEqual(AwsLogin.loginProfile(profile: "static", configText: config), "static")
        XCTAssertEqual(AwsLogin.loginProfile(profile: "papaya-login", configText: config), "papaya-login")
        XCTAssertEqual(AwsLogin.loginProfile(profile: "missing", configText: config), "missing")
    }

    func testAccountComesFromTheProfileConfig() {
        let config = """
            [default]
            region = ap-southeast-1
            [profile papaya-login]
            login_session = arn:aws:iam::089192911254:user/loc+089@papaya.asia
            region = ap-southeast-1
            [profile papaya-dev]
            sso_session = papaya
            sso_account_id = 123456789012
            sso_role_name = Dev
            [profile plain]
            region = us-east-1
            [profile root-login]
            login_session = arn:aws:iam::812652266901:root
            """
        XCTAssertEqual(AwsLogin.account(profile: "papaya-login", configText: config),
                       AwsLogin.Account(accountId: "089192911254", userName: "loc+089@papaya.asia"))
        XCTAssertEqual(AwsLogin.account(profile: "papaya-dev", configText: config),
                       AwsLogin.Account(accountId: "123456789012", userName: nil))
        XCTAssertEqual(AwsLogin.account(profile: "root-login", configText: config),
                       AwsLogin.Account(accountId: "812652266901", userName: nil))
        XCTAssertNil(AwsLogin.account(profile: "plain", configText: config))
        XCTAssertNil(AwsLogin.account(profile: "default", configText: config))
        XCTAssertNil(AwsLogin.account(profile: "missing", configText: config))
        // The refactor kept the flow choice.
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-dev", configText: config), .deviceCode)
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-login", configText: config), .relay)
    }

    func testFillScriptQuotesValuesAndNeverTouchesPasswords() throws {
        XCTAssertNil(AwsLogin.fillScript(account: nil))
        let script = try XCTUnwrap(AwsLogin.fillScript(account: AwsLogin.Account(
            accountId: "089192911254", userName: "o'neil\"</script>+x@y.z")))
        XCTAssertTrue(script.contains(#"var A = "089192911254", U = "o'neil\"<\/script>+x@y.z";"#), script)
        XCTAssertTrue(script.contains("el.type === 'password'"))
        XCTAssertFalse(script.contains(".click()"))
        XCTAssertFalse(script.contains(".submit("))
        let noUser = try XCTUnwrap(AwsLogin.fillScript(account: AwsLogin.Account(accountId: "1", userName: nil)))
        XCTAssertTrue(noUser.contains(#"U = null;"#))
    }

    func testParsesBothCliPrompts() {
        let remote = AwsLogin.parseOutput("""
        Browser will not be automatically opened.
        Please visit the following URL:

        https://signin.aws.amazon.com/oauth?x=1

        Enter the authorization code displayed in your browser: 
        """)
        XCTAssertEqual(remote.url, "https://signin.aws.amazon.com/oauth?x=1")
        XCTAssertTrue(remote.wantsCode)
        XCTAssertNil(remote.userCode)
        XCTAssertFalse(remote.succeeded)

        let device = AwsLogin.parseOutput("Browser will not be automatically opened.\r\nPlease visit the following URL:\r\n\r\nhttps://device.sso.us-east-1.amazonaws.com/\r\n\r\nThen enter the code:\r\n\r\nABCD-EFGH\r\n")
        XCTAssertEqual(device.url, "https://device.sso.us-east-1.amazonaws.com/")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertFalse(device.wantsCode)

        XCTAssertTrue(AwsLogin.parseOutput("Updated profile papaya-login to use arn:aws:sts::1:assumed-role/x credentials.").succeeded)
        // The rebind question (browser signed into another account).
        let rebind = AwsLogin.parseOutput("https://x.signin.aws.amazon.com/v1/authorize?a=b\r\n\r\nProfile papaya-login is already configured to use session arn:aws:iam::089192911254:user/a@b.c. Do you want to overwrite it to use arn:aws:iam::812652266901:user/a@b.c instead? (y/n): ")
        XCTAssertEqual(rebind.rebindRefusal, "papaya-login is bound to account 089192911254 but you signed in to 812652266901 — not rebound; sign in to the right account and retry")
        XCTAssertFalse(rebind.succeeded)
        XCTAssertNil(AwsLogin.parseOutput("Updated profile x").rebindRefusal)
        XCTAssertTrue(AwsLogin.parseOutput("Successfully logged into Start URL: https://x").succeeded)
    }

    func testRelayCallbackPortAndValidation() {
        let authorize = "https://ap-southeast-1.signin.aws.amazon.com/v1/authorize?response_type=code&client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A60861%2Foauth%2Fcallback&code_challenge=y"
        XCTAssertEqual(AwsLogin.callbackPort(inURL: authorize), 60861)
        XCTAssertNil(AwsLogin.callbackPort(inURL: "https://x/authorize?redirect_uri=https%3A%2F%2Fsignin.aws%2Fconfirm"), "the --remote flow has no localhost callback")
        XCTAssertTrue(AwsLogin.isValidCallback("http://127.0.0.1:60861/oauth/callback?code=abc&state=s", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60862/oauth/callback?code=abc", port: 60861), "wrong port")
        XCTAssertFalse(AwsLogin.isValidCallback("http://evil.example/oauth/callback?code=abc", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60861/other?code=abc", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60861/oauth/callback?error=denied", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://localhost:60861/oauth/callback?code=abc", port: 60861), "aws listens on 127.0.0.1, not localhost")
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .relay), ["login", "--profile", "p"])
    }

    func testCodesAreShortAndPlain() {
        // The real --remote code: ~1.8k chars of base64 with padding.
        XCTAssertTrue(AwsLogin.isValidCode(String(repeating: "Y29kZT1leUo2YVhB", count: 110) + "=="))
        XCTAssertFalse(AwsLogin.isValidCode("abc def"))
        XCTAssertFalse(AwsLogin.isValidCode(String(repeating: "a", count: AwsLogin.maxCodeLength + 1)))
        XCTAssertTrue(AwsLogin.isValidCode("ABCD-EFGH"))
        XCTAssertTrue(AwsLogin.isValidCode("a1b2c3"))
        XCTAssertFalse(AwsLogin.isValidCode(""))
        XCTAssertFalse(AwsLogin.isValidCode("abc\n"))
        XCTAssertFalse(AwsLogin.isValidCode("x; rm -rf"))
    }

    func testArgumentsPerFlow() {
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .remote), ["login", "--remote", "--profile", "p"])
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .deviceCode),
                       ["sso", "login", "--use-device-code", "--no-browser", "--profile", "p"])
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .local), ["login", "--profile", "p"])
    }

    func testWireShapesRoundTrip() throws {
        let item = AwsLogin.Item(profile: "papaya-login", flow: .remote,
                                 state: AwsLogin.State(profile: "papaya-login", flow: .remote, phase: .waitingForCode,
                                                       url: "https://x", startedAt: 1))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AwsLogin.Item.self, from: data), item)
        let start = try JSONDecoder().decode(AwsLogin.StartRequest.self, from: Data(#"{"profile":"p"}"#.utf8))
        XCTAssertEqual(start, AwsLogin.StartRequest(profile: "p"))
    }
}

final class AwsLoginSubagentTests: XCTestCase {
    func testOrphanLoginWrappersAreTheLaunchdChildrenRunningThisInstancesAws() {
        let ps = """
            81429     1 /usr/bin/script -q /dev/null /opt/homebrew/bin/aws login --remote --profile papaya-login
            81430 81429 /opt/homebrew/bin/aws login --remote --profile papaya-login
             9001   777 /usr/bin/script -q /dev/null /opt/homebrew/bin/aws login --profile live
             9002     1 /usr/bin/script -q /dev/null /tmp/e2e/aws login --remote --profile e2e-orphan
             9003     1 /opt/homebrew/bin/aws sts get-caller-identity --profile papaya
            """
        // Only the wrapper (its child goes with it), only launchd's, only this aws.
        XCTAssertEqual(AwsLogin.orphanLogins(ps: ps, aws: "/opt/homebrew/bin/aws"), [81429])
        XCTAssertEqual(AwsLogin.orphanLogins(ps: ps, aws: "/tmp/e2e/aws"), [9002])
        XCTAssertEqual(AwsLogin.orphanLogins(ps: "", aws: "/opt/homebrew/bin/aws"), [])
    }
}
