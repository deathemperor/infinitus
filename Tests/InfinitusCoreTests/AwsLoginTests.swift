import XCTest
@testable import InfinitusCore

final class AwsLoginTests: XCTestCase {
    func testDetectsTheProfileFromTheBrokerAndCliSignatures() {
        XCTAssertEqual(AwsLogin.profile(in: """
            [aws-cred-broker] could not refresh credentials for 'papaya-login'.
              aws said: aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.
              Fix: aws login --profile papaya-login
            """), "papaya-login")
        XCTAssertEqual(AwsLogin.profile(in: "aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'."), "default")
        XCTAssertEqual(AwsLogin.profile(in: "Error when retrieving token from sso: Token has expired and refresh failed\nRun: aws sso login --profile papaya-dev"), "papaya-dev")
        XCTAssertNil(AwsLogin.profile(in: "aws login --profile x is documented here"), "no failure, no need")
        XCTAssertNil(AwsLogin.profile(in: "all good"))
        XCTAssertEqual(AwsLogin.profile(in: "aws: [ERROR]: The pending authorization to retrieve an SSO token has expired. The login flow to retrieve an SSO token must be restarted."), "default")
        XCTAssertEqual(AwsLogin.profile(in: "aws: [ERROR]: An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired"), "default")
        // The broker's refresh lock is held for >30 s only while the holder
        // sits in the interactive login (2026-09-05, peon-wave-16: nothing
        // shown while `aws login` waited for the browser).
        XCTAssertEqual(AwsLogin.profile(in: "aws: [ERROR]: Error when retrieving credentials from custom-process: [aws-cred-broker] timed out after 30.0s waiting for the refresh lock held by pid 39243. Inspect that process; do not delete /Users/x/.config/banyan/aws-broker/global.lock while it is running.\ntunnel-DOWN"), "default")
        // Quoted, not suffered: a grep hit / Read line / source fixture.
        XCTAssertNil(AwsLogin.profile(in: "99:    let failed = \"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\""))
        XCTAssertNil(AwsLogin.profile(in: "    [aws-cred-broker] ...\n      Fix: aws login --profile papaya-login"))
        // `… 2>&1 | tail -1` keeps only the broker's own two-space "Fix:"
        // line — that indentation is the broker's, not a quote's
        // (2026-09-05 11:02, banyan: nothing shown on the phone).
        XCTAssertEqual(AwsLogin.profile(in: "=== A sts\n  Fix: aws login --profile papaya-login\n=== B refs\ndocs/x.md:33:- rows"), "papaya-login")
        XCTAssertNil(AwsLogin.profile(in: "357:            f\"  Fix: aws login --profile {anchor}\""), "the broker's source, read")
    }

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
        let item = AwsLogin.Item(profile: "papaya-login", flow: .remote, pid: 42, sessionLabel: "banyan",
                                 state: AwsLogin.State(profile: "papaya-login", flow: .remote, phase: .waitingForCode,
                                                       url: "https://x", startedAt: 1, pid: 42))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AwsLogin.Item.self, from: data), item)
        let start = try JSONDecoder().decode(AwsLogin.StartRequest.self, from: Data(#"{"profile":"p"}"#.utf8))
        XCTAssertEqual(start, AwsLogin.StartRequest(profile: "p"))
    }
}

final class AwsLoginProgressTests: XCTestCase {
    func testSessionProgressReadsTheLapsedProfileOffTheNewestToolResults() {
        let failed = #"{"type":"user","timestamp":"2026-09-03T08:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"[aws-cred-broker] could not refresh credentials for 'papaya-login'.\n  aws said: aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile papaya-login"}]}}"#
        let fine = #"{"type":"user","timestamp":"2026-09-03T08:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"ok"}]}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [failed, fine]).awsLoginProfile, "papaya-login")
        XCTAssertEqual(SessionProgress.parse(lines: [failed, fine]).awsLoginFailedAt, UsageHistory.parseISO("2026-09-03T08:00:00.000Z"))
        XCTAssertNil(SessionProgress.parse(lines: [fine]).awsLoginProfile)
        // The CLI's own error names no profile — the failed command does.
        let use = #"{"type":"assistant","timestamp":"2026-09-03T08:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"AWS_PROFILE=papaya-dev aws sts get-caller-identity"}}]}}"#
        let raw = #"{"type":"user","timestamp":"2026-09-03T08:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'."}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [use, raw]).awsLoginProfile, "papaya-dev")
        XCTAssertEqual(AwsLogin.profile(inCommand: "aws s3 ls --profile=banyan"), "banyan")
        XCTAssertNil(AwsLogin.profile(inCommand: "aws s3 ls"))
        // Scrolls out of the scan window once the session moves on.
        let later = Array(repeating: fine, count: SessionProgress.awsLoginScanEntries * 2)
        XCTAssertNil(SessionProgress.parse(lines: [failed] + later).awsLoginProfile)
        // Thinking / text turns between calls don't count.
        let thought = #"{"type":"assistant","timestamp":"2026-09-03T08:02:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"ok"}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [failed] + Array(repeating: thought, count: 30)).awsLoginProfile, "papaya-login")
        // Attachments / hook summaries / turn stats don't eat the window.
        let padding = Array(repeating: #"{"type":"attachment","attachment":{"type":"hook_success"}}"#, count: 20)
            + [#"{"type":"system","subtype":"turn_duration","durationMs":1}"#]
        XCTAssertEqual(SessionProgress.parse(lines: [failed] + padding).awsLoginProfile, "papaya-login")
    }
}

/// #149: the aws command that failed ran in a sub-agent, so the parent's
/// own tail never carries the signature — the need is read off the
/// sub-agent transcript and attributed to the parent.
final class AwsLoginSubagentTests: XCTestCase {
    var dir: URL!
    let failed = #"{"type":"user","timestamp":"2026-09-03T08:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile papaya-login"}]}}"#
    let failedLater = #"{"type":"user","timestamp":"2026-09-03T08:05:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile banyan"}]}}"#
    let fine = #"{"type":"user","timestamp":"2026-09-03T08:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"ok"}]}]}}"#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("infinitus-aws-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ lines: [String], agent: String? = nil, mtime: Date? = nil) throws {
        let transcript = Transcript.path(cwd: "/p", sessionId: "s1", claudeDir: dir)
        var url = transcript
        if let agent {
            let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            url = subagents.appendingPathComponent("agent-\(agent).jsonl")
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
    }

    func testASubagentsLapsedSignInIsAttributedToTheParent() throws {
        try write([fine])
        try write([failed], agent: "a")
        let progress = SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir)
        XCTAssertEqual(progress.awsLoginProfile, "papaya-login")
        XCTAssertEqual(progress.awsLoginFailedAt, UsageHistory.parseISO("2026-09-03T08:00:00.000Z"))
    }

    func testTheNewestSubagentFailureWinsAndTheParentsOwnTailWinsOverAll() throws {
        try write([fine])
        try write([failed], agent: "a")
        try write([failedLater], agent: "b")
        XCTAssertEqual(SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir).awsLoginProfile, "banyan")
        let ownFailure = #"{"type":"user","timestamp":"2026-09-03T08:09:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile parent-prof"}]}}"#
        try write([ownFailure])
        XCTAssertEqual(SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir).awsLoginProfile, "parent-prof")
    }

    func testAStaleAgentTranscriptAndAMovedOnAgentAreIgnored() throws {
        try write([fine])
        try write([failed], agent: "old", mtime: Date().addingTimeInterval(-2 * 60 * 60))
        XCTAssertNil(SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir).awsLoginProfile)
        try write([failed] + Array(repeating: fine, count: SessionProgress.awsLoginScanEntries * 2), agent: "busy")
        XCTAssertNil(SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir).awsLoginProfile)
    }
}
