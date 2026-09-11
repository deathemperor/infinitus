import XCTest
@testable import InfinitusCore

final class GcloudLoginTests: XCTestCase {
    func testDetectsTheLapsedSignInFromGcloudsOwnErrors() {
        // gcloud's refresh failure, exactly as the CLI prints it (store.py / exceptions.py).
        let refresh = """
        ERROR: (gcloud.storage.ls) There was a problem refreshing your current auth tokens: ('invalid_grant: Token has been expired or revoked.', {'error': 'invalid_grant'})
        Please run:

          $ gcloud auth login

        to obtain new credentials.
        """
        XCTAssertEqual(GcloudLogin.profile(in: refresh), "default")
        // No account at all (captured 2026-09-09 from an empty CLOUDSDK_CONFIG).
        let none = "ERROR: (gcloud.auth.print-access-token) You do not currently have an active account selected.\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials."
        XCTAssertEqual(GcloudLogin.profile(in: none), "default")
        // Reauth (google-auth's reauth module, through gcloud).
        XCTAssertEqual(GcloudLogin.profile(in: "ERROR: (gcloud.compute.instances.list) Reauthentication failed. cannot prompt during non-interactive execution."), "default")
        // Application Default Credentials — its own remediation, its own "profile".
        let adc = "ERROR: (gcloud.auth.application-default.print-access-token) Your default credentials were not found. To set up Application Default Credentials, see https://cloud.google.com/docs/authentication/external/set-up-adc for more information."
        XCTAssertEqual(GcloudLogin.profile(in: adc), GcloudLogin.adcProfile)
        // The google-auth library, from a Python script the session ran.
        let library = "Traceback (most recent call last):\n  File \"x.py\", line 3, in <module>\ngoogle.auth.exceptions.DefaultCredentialsError: Your default credentials were not found. To set up Application Default Credentials, see https://cloud.google.com/docs/authentication/external/set-up-adc for more information."
        XCTAssertEqual(GcloudLogin.profile(in: library), GcloudLogin.adcProfile)
        let reauthADC = "google.auth.exceptions.RefreshError: Reauthentication is needed. Please run `gcloud auth application-default login` to reauthenticate."
        XCTAssertEqual(GcloudLogin.profile(in: reauthADC), GcloudLogin.adcProfile)
    }

    func testTheSignatureMustOpenALineSoQuotedCopiesDoNotCount() {
        // A Read of this very test file: line-numbered, indented.
        XCTAssertNil(GcloudLogin.profile(in: "    12\t  ERROR: (gcloud.storage.ls) There was a problem refreshing your current auth tokens\n    13\t  $ gcloud auth login"))
        // A grep hit.
        XCTAssertNil(GcloudLogin.profile(in: "Sources/X.swift:4: \"please run: $ gcloud auth login\""))
        // Ordinary output that mentions the command.
        XCTAssertNil(GcloudLogin.profile(in: "Run gcloud auth login first if you have not."))
        XCTAssertNil(GcloudLogin.profile(in: "all good"))
    }

    func testTheAccountComesFromTheFailedCommand() {
        XCTAssertEqual(GcloudLogin.profile(inCommand: "gcloud storage ls --account=me@example.com"), "me@example.com")
        XCTAssertEqual(GcloudLogin.profile(inCommand: "gcloud storage ls --account me@example.com --project p"), "me@example.com")
        XCTAssertEqual(GcloudLogin.profile(inCommand: "CLOUDSDK_CORE_ACCOUNT=ops@example.com gcloud compute instances list"), "ops@example.com")
        XCTAssertNil(GcloudLogin.profile(inCommand: "gcloud storage ls"))
    }

    func testArgumentsPerProfileAndFlow() {
        XCTAssertEqual(GcloudLogin.arguments(profile: "default", flow: .remote), ["auth", "login", "--no-launch-browser"])
        XCTAssertEqual(GcloudLogin.arguments(profile: "me@example.com", flow: .remote), ["auth", "login", "me@example.com", "--no-launch-browser"])
        XCTAssertEqual(GcloudLogin.arguments(profile: "default", flow: .local), ["auth", "login"])
        // The relay keeps the CLI's localhost listener; the runner suppresses the browser (#403).
        XCTAssertEqual(GcloudLogin.arguments(profile: "me@example.com", flow: .relay), ["auth", "login", "me@example.com"])
        XCTAssertEqual(GcloudLogin.arguments(profile: GcloudLogin.adcProfile, flow: .relay), ["auth", "application-default", "login"])
        XCTAssertEqual(AwsLogin.Provider.gcloud.flow(profile: "me@example.com", configText: ""), .relay)
        XCTAssertEqual(GcloudLogin.arguments(profile: GcloudLogin.adcProfile, flow: .remote),
                       ["auth", "application-default", "login", "--no-launch-browser"])
        // Never a token on stdout the runner could capture: the probe is exit-status only.
        XCTAssertEqual(GcloudLogin.probeArguments(profile: "me@example.com"), ["auth", "print-access-token", "--account", "me@example.com"])
        XCTAssertEqual(GcloudLogin.probeArguments(profile: GcloudLogin.adcProfile), ["auth", "application-default", "print-access-token"])
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
        let state = AwsLogin.State(profile: "default", flow: .remote, startedAt: 1, pid: 7, provider: .gcloud)
        let back = try JSONDecoder().decode(AwsLogin.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.provider, .gcloud)
        // A ledger entry or a phone body from before the field: aws.
        let old = try JSONDecoder().decode(AwsLogin.State.self, from: Data(#"{"profile":"p","flow":"remote","phase":"done","startedAt":1}"#.utf8))
        XCTAssertNil(old.provider)
        XCTAssertEqual(old.providerOrAws, .aws)
        let start = try JSONDecoder().decode(AwsLogin.StartRequest.self, from: Data(#"{"profile":"me@example.com","provider":"gcloud"}"#.utf8))
        XCTAssertEqual(start.provider, .gcloud)
        // Item ids: the aws one is byte-identical to before (persisted in the announced set); gcloud's is distinct.
        XCTAssertEqual(AwsLogin.Item(profile: "p", flow: .remote, pid: 3, sessionLabel: nil, state: nil).id, "p|3")
        XCTAssertEqual(AwsLogin.Item(profile: "p", flow: .remote, pid: 3, sessionLabel: nil, state: nil, provider: .gcloud).id, "gcloud:p|3")
        XCTAssertEqual(AwsLogin.runKey(provider: .aws, profile: "default"), "aws:default")
        XCTAssertNotEqual(AwsLogin.runKey(provider: .aws, profile: "default"), AwsLogin.runKey(provider: .gcloud, profile: "default"))
    }

    /// A phone from before the field sends no provider: the outstanding
    /// items say which CLI the profile belongs to.
    func testAProviderlessBodyResolvesAgainstTheOutstandingItems() {
        let items = [AwsLogin.Item(profile: "default", flow: .remote, pid: 3, sessionLabel: nil, state: nil, provider: .gcloud),
                     AwsLogin.Item(profile: "default", flow: .relay, pid: 4, sessionLabel: nil, state: nil),
                     AwsLogin.Item(profile: "me@example.com", flow: .remote, pid: nil, sessionLabel: nil, state: nil, provider: .gcloud)]
        XCTAssertEqual(AwsLogin.inferProvider(profile: "default", pid: 3, items: items), .gcloud)
        XCTAssertEqual(AwsLogin.inferProvider(profile: "default", pid: 4, items: items), .aws)
        XCTAssertEqual(AwsLogin.inferProvider(profile: "default", pid: nil, items: items), .gcloud, "first outstanding item for the profile")
        XCTAssertEqual(AwsLogin.inferProvider(profile: "me@example.com", pid: nil, items: items), .gcloud)
        XCTAssertEqual(AwsLogin.inferProvider(profile: "unknown", pid: nil, items: items), .aws)
    }

    func testContinueMessageNamesTheProviderAndTheCredential() {
        XCTAssertTrue(GcloudLogin.continueMessage(profile: "me@example.com", fromPhone: true).contains("gcloud login for me@example.com completed from the phone"))
        XCTAssertTrue(GcloudLogin.continueMessage(profile: GcloudLogin.adcProfile, fromPhone: false).contains("application default credentials"))
    }

    func testSessionProgressReadsTheLapsedCredentialOffTheNewestToolResults() {
        let use = #"{"type":"assistant","timestamp":"2026-09-09T08:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gcloud storage ls --account=me@example.com"}}]}}"#
        let failed = #"{"type":"user","timestamp":"2026-09-09T08:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ERROR: (gcloud.storage.ls) There was a problem refreshing your current auth tokens: invalid_grant\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials."}]}}"#
        let fine = #"{"type":"user","timestamp":"2026-09-09T08:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"ok"}]}]}}"#
        let progress = SessionProgress.parse(lines: [use, failed, fine])
        XCTAssertEqual(progress.gcloudLoginProfile, "me@example.com")
        XCTAssertEqual(progress.gcloudLoginFailedAt, UsageHistory.parseISO("2026-09-09T08:00:01.000Z"))
        XCTAssertNil(progress.awsLoginProfile)
        XCTAssertNil(SessionProgress.parse(lines: [fine]).gcloudLoginProfile)
        let adc = #"{"type":"user","timestamp":"2026-09-09T08:02:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"google.auth.exceptions.DefaultCredentialsError: Your default credentials were not found."}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [adc]).gcloudLoginProfile, GcloudLogin.adcProfile)
        let later = Array(repeating: fine, count: SessionProgress.awsLoginScanEntries * 2)
        XCTAssertNil(SessionProgress.parse(lines: [use, failed] + later).gcloudLoginProfile)
        // Both providers can lapse in one session; each keeps its own need.
        let awsFailed = #"{"type":"user","timestamp":"2026-09-09T08:03:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile papaya"}]}}"#
        let both = SessionProgress.parse(lines: [use, failed, awsFailed])
        XCTAssertEqual(both.gcloudLoginProfile, "me@example.com")
        XCTAssertEqual(both.awsLoginProfile, "papaya")
        let row = SessionPanelRow.make(record: ClaudeSessionRecord(pid: 1, sessionId: "s", cwd: "/p"), progress: both)
        XCTAssertEqual(row.gcloudLoginProfile, "me@example.com")
    }

    func testASubagentsLapsedGcloudSignInIsAttributedToTheParent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("infinitus-gcloud-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = Transcript.path(cwd: "/p", sessionId: "s1", claudeDir: dir)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"user","timestamp":"2026-09-09T08:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#.write(to: transcript, atomically: true, encoding: .utf8)
        let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try #"{"type":"user","timestamp":"2026-09-09T08:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ERROR: (gcloud.auth.print-access-token) You do not currently have an active account selected.\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials."}]}}"#
            .write(to: subagents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)
        let progress = SessionProgress.read(sessionId: "s1", cwd: "/p", claudeDir: dir)
        XCTAssertEqual(progress.gcloudLoginProfile, "default")
        XCTAssertEqual(progress.gcloudLoginFailedAt, UsageHistory.parseISO("2026-09-09T08:00:00.000Z"))
    }
}
