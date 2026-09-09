import Foundation

/// gcloud sign-in from the phone (#367, user 2026-09-09: "support gcloud
/// log in like aws"). The second login provider on the AWS machinery:
/// the same `AwsLogin.State` / `Item` / wire shapes, tagged
/// `provider: .gcloud`, the same runner, the same phone screen. What
/// differs lives here: the CLI's own expired-credentials signatures,
/// which credential the failure was about (a user account, or the
/// Application Default Credentials a library reads), the CLI
/// invocation and its prompts.
///
/// Two flows for the phone. `.relay` (#403): plain `gcloud auth login`
/// with the browser suppressed keeps the CLI's own listener on
/// `http://localhost:8085/` (gcloud 552, verified 2026-09-09); the
/// phone's web view is the browser and hands the final redirect to the
/// Mac, which replays it against that listener — one tap plus Google's
/// consent screen. `.remote`: `--no-launch-browser` prints a URL and
/// waits for the verification code the browser shows after sign-in,
/// paste-back. `.local` is the plain command with this Mac's browser.
/// The code goes phone → Mac and straight into the CLI's stdin — never
/// logged, never stored. Infinitus never reads `~/.config/gcloud`.
public enum GcloudLogin {
    /// The "profile" of an Application Default Credentials need
    /// (`gcloud auth application-default login`), beside the user
    /// account ones ("default" = the CLI's active account, or the
    /// account the failed command named).
    public static let adcProfile = "application-default"

    // MARK: detection

    /// What gcloud (core/credentials/exceptions.py, store.py) and the
    /// google-auth library print when the credentials have lapsed or
    /// were never there. Any match means "needs gcloud auth login".
    static let expiredMarkers = [
        "$ gcloud auth login",
        "gcloud auth application-default login",
        "there was a problem refreshing your current auth tokens",
        "reauthentication required",
        "reauthentication is needed",
        "reauthentication failed",
        "you do not currently have an active account selected",
        "your default credentials were not found",
        "could not automatically determine credentials",
    ]

    /// The failure must OPEN an output line (the AWS rule, 2026-09-03):
    /// gcloud's errors and a Python traceback's last line sit at column
    /// 0, the remediation line is indented by exactly two spaces; the
    /// same words quoted from a source file, a grep hit or a Read
    /// (line-numbered, indented) don't match.
    static let expiredLineStarts = [
        "error: (gcloud.",
        "google.auth.exceptions.",
        "reauthentication required",
        "reauthentication is needed",
        "  $ gcloud auth login",
        "  $ gcloud auth application-default login",
    ]

    /// Which needs are about Application Default Credentials rather
    /// than the CLI's user account.
    static let adcMarkers = [
        "application-default login",
        "your default credentials were not found",
        "could not automatically determine credentials",
    ]

    /// The credential a transcript excerpt says needs a login, or nil
    /// when the text carries no lapsed-credentials signature:
    /// `adcProfile`, or "default" — the caller swaps in the account the
    /// failed command named (`profile(inCommand:)`).
    public static func profile(in text: String) -> String? {
        let lower = text.lowercased()
        guard expiredMarkers.contains(where: { lower.contains($0) }),
              lower.split(separator: "\n", omittingEmptySubsequences: true).contains(where: { line in
                  expiredLineStarts.contains { line.hasPrefix($0) }
              }) else { return nil }
        return adcMarkers.contains(where: { lower.contains($0) }) ? adcProfile : "default"
    }

    /// The account the FAILED command addressed — `--account X` or
    /// `CLOUDSDK_CORE_ACCOUNT=X` — for an error that names none. Nil
    /// when the command names none (the CLI's active account, then).
    public static func profile(inCommand command: String) -> String? {
        let pattern = #"(?:--account[ =]|CLOUDSDK_CORE_ACCOUNT=)["']?([A-Za-z0-9._%+@-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 1), in: command) else { return nil }
        return String(command[r])
    }

    // MARK: running

    /// The CLI invocation. `.remote` is the paste-back prompt; `.relay`
    /// and `.local` keep the localhost listener (the runner suppresses
    /// the browser for the relay); `.deviceCode` is AWS-only and falls
    /// back to the paste-back.
    public static func arguments(profile: String, flow: AwsLogin.Flow) -> [String] {
        var args = profile == adcProfile
            ? ["auth", "application-default", "login"]
            : ["auth", "login"] + (profile == "default" ? [] : [profile])
        switch flow {
        case .remote, .deviceCode: args.append("--no-launch-browser")
        case .relay, .local: break
        }
        return args
    }

    /// Whether the credential works right now, by exit status only —
    /// the command prints a token on success, so the runner keeps its
    /// stdout on the null device.
    public static func probeArguments(profile: String) -> [String] {
        profile == adcProfile
            ? ["auth", "application-default", "print-access-token"]
            : ["auth", "print-access-token"] + (profile == "default" ? [] : ["--account", profile])
    }

    /// The paste-back prompt (SDK 552, 2026-09-09):
    ///   Go to the following link in your browser, and complete the sign-in prompts:
    ///       https://accounts.google.com/o/oauth2/auth?…
    ///   Once finished, enter the verification code provided in your browser:
    /// and the success lines of both commands.
    public static func parseOutput(_ text: String) -> AwsLogin.Prompt {
        var p = AwsLogin.Prompt()
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if p.url == nil, line.hasPrefix("https://") { p.url = line }
            let lower = line.lowercased()
            if lower.hasPrefix("once finished, enter the verification code") { p.wantsCode = true }
            if lower.hasPrefix("you are now logged in as") || lower.hasPrefix("credentials saved to file") {
                p.succeeded = true
            }
        }
        return p
    }

    public static func label(profile: String) -> String {
        profile == adcProfile ? "application default credentials" : profile
    }

    /// The message the session gets once the login lands (same path as
    /// the AWS one).
    public static func continueMessage(profile: String, fromPhone: Bool) -> String {
        "[Infinitus] gcloud login for \(label(profile: profile)) completed\(fromPhone ? " from the phone" : ""). "
            + "Retry the command that needed it and continue."
    }
}

public extension AwsLogin {
    /// The provider a phone body means when it carries none (#367): a
    /// phone from before the field sends `/aws-login/start`, `/code` and
    /// its status poll with the profile alone, so a gcloud item's "Sign
    /// in from this phone" must still run gcloud. The outstanding items
    /// decide — the one for that profile (and pid, when given) — and
    /// only a profile no item knows falls back to aws.
    static func inferProvider(profile: String, pid: Int?, items: [Item]) -> Provider {
        let matching = items.filter { $0.profile == profile }
        if let pid, let hit = matching.first(where: { $0.pid == pid }) { return hit.providerOrAws }
        return matching.first?.providerOrAws ?? .aws
    }
}

/// What differs per CLI, dispatched once here so the runner, the model
/// and the verbs never branch on the provider themselves.
public extension AwsLogin.Provider {
    var cliName: String { self == .aws ? "aws" : "gcloud" }
    /// The e2e gate's stub in place of the real CLI.
    var cliOverrideEnv: String { self == .aws ? "INFINITUS_AWS_CLI" : "INFINITUS_GCLOUD_CLI" }
    /// How the login reads in a line: "AWS login" / "gcloud login".
    var loginLabel: String { self == .aws ? "AWS login" : "gcloud login" }

    func arguments(profile: String, flow: AwsLogin.Flow) -> [String] {
        self == .aws ? AwsLogin.arguments(profile: profile, flow: flow) : GcloudLogin.arguments(profile: profile, flow: flow)
    }

    func parseOutput(_ text: String) -> AwsLogin.Prompt {
        self == .aws ? AwsLogin.parseOutput(text) : GcloudLogin.parseOutput(text)
    }

    /// The phone's flow for a profile: AWS reads the config; gcloud's
    /// listener is always there, so its items offer the relay (the
    /// phone still starts the paste-back by default, `remote: true`).
    func flow(profile: String, configText: String) -> AwsLogin.Flow {
        self == .aws ? AwsLogin.flow(profile: profile, configText: configText) : .relay
    }

    func continueMessage(profile: String, fromPhone: Bool, released: Bool = false) -> String {
        self == .aws ? AwsLogin.continueMessage(profile: profile, fromPhone: fromPhone, released: released)
                     : GcloudLogin.continueMessage(profile: profile, fromPhone: fromPhone)
    }
}
