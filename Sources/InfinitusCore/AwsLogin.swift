import Foundation

/// AWS sign-in from the phone (user 2026-09-03: "sessions often need
/// `aws login` for SSO — identify those sessions, let me log in on
/// mobile, the session continues"). Pure parts live here: detecting the
/// need in a transcript, choosing the flow for a profile, reading the
/// CLI's prompts, and the wire shapes phone ↔ Mac. The Mac side runs
/// the CLI (AwsLoginRunner.swift); the phone renders `Item`s from the
/// snapshot and posts `StartRequest` / `CodeRequest`.
///
/// Two CLI flows, both built for exactly this: `aws login --remote`
/// prints a URL and then waits for the authorization code the browser
/// shows after sign-in; `aws sso login --use-device-code --no-browser`
/// prints a URL plus a user code and finishes by itself once the user
/// approves on any device. The code goes phone → Mac over the mirror
/// channel and straight into the CLI's stdin — never logged, never
/// stored. Infinitus never reads `~/.aws/login` or `~/.aws/sso`.
public enum AwsLogin {
    public enum Flow: String, Codable, Sendable {
        /// `aws login --remote`: URL, then a code pasted back.
        case remote
        /// `aws sso login --use-device-code --no-browser`: URL + code, no paste-back.
        case deviceCode
        /// `aws login` with the local browser callback — the Mac's own button.
        case local
        /// `aws login` with its localhost callback, the browser on the
        /// PHONE: the phone's web view intercepts the redirect to
        /// `http://127.0.0.1:<port>/oauth/callback?code=…` and posts it
        /// back; the Mac replays it against the CLI's own listener. No
        /// code to read or type (user 2026-09-03: "can the mobile app
        /// capture the code itself?").
        case relay
    }

    public enum Phase: String, Codable, Sendable {
        case starting, waitingForBrowser, waitingForCode, done, failed
    }

    /// Which CLI a login is for (#367). Absent on the wire and in the
    /// ledger means `.aws` — phones and entries from before the field.
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case aws, gcloud
    }

    /// One runner slot per (provider, profile): "default" is a name
    /// both CLIs use.
    public static func runKey(provider: Provider, profile: String) -> String { "\(provider.rawValue):\(profile)" }

    /// One login in flight (or just finished), as the runner reports it.
    public struct State: Codable, Sendable, Equatable {
        public let profile: String
        public let flow: Flow
        public var phase: Phase
        /// The sign-in URL to open on the phone.
        public var url: String?
        /// Device-code flow: the code the page asks for.
        public var userCode: String?
        /// Relay flow: the port of the CLI's localhost callback listener.
        public var callbackPort: Int?
        /// Failure text (sanitized last output line) or the success line.
        public var message: String?
        public let startedAt: Double
        /// The session that needed it, if the login was started for one.
        public let pid: Int?
        /// nil = aws (see `Provider`).
        public let provider: Provider?
        public var providerOrAws: Provider { provider ?? .aws }
        public var runKey: String { AwsLogin.runKey(provider: providerOrAws, profile: profile) }
        public init(profile: String, flow: Flow, phase: Phase = .starting, url: String? = nil,
                    userCode: String? = nil, callbackPort: Int? = nil, message: String? = nil,
                    startedAt: Double, pid: Int?, provider: Provider? = nil) {
            self.profile = profile
            self.flow = flow
            self.phase = phase
            self.url = url
            self.userCode = userCode
            self.callbackPort = callbackPort
            self.message = message
            self.startedAt = startedAt
            self.pid = pid
            self.provider = provider
        }
    }

    /// What the snapshot carries: every session that needs a login,
    /// merged with the runner's state for that profile.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// The aws id is byte-identical to before the provider field —
        /// it is persisted in the announced-pushes set.
        public var id: String { (provider == .gcloud ? "gcloud:" : "") + "\(profile)|\(pid ?? 0)" }
        public let profile: String
        /// The flow the phone would start (`.remote` / `.deviceCode`).
        public let flow: Flow
        public let pid: Int?
        /// The session's display name (record name or repo folder).
        public let sessionLabel: String?
        public let state: State?
        /// When the session's CLI call failed on expired credentials —
        /// the push keys on it, so a fresh failure after a relaunch is
        /// news and a re-failure hours later is news again (#29).
        public let failedAt: Date?
        /// The account id (and IAM user name) the sign-in page asks for,
        /// from the profile's config; nil when the config names none.
        public let account: Account?
        /// nil = aws (see `Provider`).
        public let provider: Provider?
        public var providerOrAws: Provider { provider ?? .aws }
        public var runKey: String { AwsLogin.runKey(provider: providerOrAws, profile: profile) }
        public init(profile: String, flow: Flow, pid: Int?, sessionLabel: String?, state: State?,
                    failedAt: Date? = nil, account: Account? = nil, provider: Provider? = nil) {
            self.profile = profile
            self.flow = flow
            self.pid = pid
            self.sessionLabel = sessionLabel
            self.state = state
            self.failedAt = failedAt
            self.account = account
            self.provider = provider
        }
    }

    /// The login that belongs to a profile's CURRENT need: one still in
    /// flight, or one that finished after the need's CLI call failed. A
    /// finished login older than that failure is history — the ledger
    /// keeps a day of it — not this need's login (a stale "done" made a
    /// fresh need report as signed in, e2e 2026-09-04).
    public static func current(_ state: State?, needFailedAt: Date?) -> State? {
        guard let state else { return nil }
        guard state.phase == .done || state.phase == .failed, let needFailedAt else { return state }
        return needFailedAt.timeIntervalSince1970 > state.startedAt ? nil : state
    }

    /// What the runner keeps across a relaunch (#29: a Mac relaunch
    /// wiped every login it knew about, so a met need came back as
    /// unmet). Finished logins survive as they are; a run in flight for a
    /// session survives as a failure that says why — its CLI died with
    /// the app — while a hand-started run just goes with its CLI.
    public enum Ledger {
        public static let doneMaxAge: TimeInterval = 24 * 3600
        public static let failedMaxAge: TimeInterval = 3600
        public static let relaunchMessage = "the app relaunched mid-login — start it again"

        public static func snapshot(running: [State], finished: [State]) -> [State] {
            finished + running.compactMap { state in
                guard state.pid != nil else { return nil }
                var failed = state
                failed.phase = .failed
                failed.message = relaunchMessage
                failed.url = nil
                failed.userCode = nil
                failed.callbackPort = nil
                return failed
            }
        }

        public static func encode(_ states: [State]) throws -> Data {
            try JSONEncoder().encode(states)
        }

        /// Only outcomes, and only recent ones: a done login older than
        /// a day says nothing about today's credentials.
        public static func decode(_ data: Data, now: Date = Date()) -> [State] {
            guard let states = try? JSONDecoder().decode([State].self, from: data) else { return [] }
            return states.filter { state in
                let age = now.timeIntervalSince1970 - state.startedAt
                switch state.phase {
                case .done: return age < doneMaxAge
                case .failed: return age < failedMaxAge
                default: return false
                }
            }
        }
    }

    /// `POST /aws-login/start`.
    public struct StartRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let pid: Int?
        /// The Mac's own browser flow instead of the phone one.
        public let local: Bool?
        /// Paste-back (`aws login --remote`) instead of the relay — for a
        /// client without an intercepting web view.
        public let remote: Bool?
        /// nil = aws (see `Provider`).
        public let provider: Provider?
        public init(profile: String, pid: Int? = nil, local: Bool? = nil, remote: Bool? = nil, provider: Provider? = nil) {
            self.profile = profile
            self.pid = pid
            self.local = local
            self.remote = remote
            self.provider = provider
        }
    }

    /// `POST /aws-login/code`.
    public struct CodeRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let code: String
        /// nil = aws (see `Provider`).
        public let provider: Provider?
        public init(profile: String, code: String, provider: Provider? = nil) {
            self.profile = profile
            self.code = code
            self.provider = provider
        }
    }

    /// `POST /aws-login/callback`: the redirect the phone's web view
    /// intercepted, verbatim (`http://127.0.0.1:<port>/oauth/callback?…`).
    public struct CallbackRequest: Codable, Sendable, Equatable {
        public let profile: String
        public let url: String
        /// nil = aws (see `Provider`).
        public let provider: Provider?
        public init(profile: String, url: String, provider: Provider? = nil) {
            self.profile = profile
            self.url = url
            self.provider = provider
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public let ok: Bool
        public let state: State?
        public let error: String?
        public init(ok: Bool, state: State? = nil, error: String? = nil) {
            self.ok = ok
            self.state = state
            self.error = error
        }
    }

    public static let startPath = "/aws-login/start"
    public static let codePath = "/aws-login/code"
    public static let callbackPath = "/aws-login/callback"
    /// A login that hasn't finished in this long is abandoned.
    public static let timeout: TimeInterval = 600

    // MARK: detection

    /// Signatures the CLI (and the cred broker in front of it) print when
    /// the sign-in has lapsed. Any match means "needs aws login".
    static let expiredMarkers = [
        "please reauthenticate using 'aws login'",
        "error when retrieving token from sso",
        "the sso session associated with this profile has expired",
        "the sso session has expired",
        "fix: aws login",
        "run: aws login",
        "please run: aws login",
        // A login attempt that lapsed before it finished, and a login-
        // session token past its life (past transcripts, 2026-09-03).
        "pending authorization to retrieve an sso token has expired",
        "the security token included in the request is expired",
        // The cred broker's refresh lock is held past its 30 s wait only
        // while the holder sits in the interactive login; every other
        // caller then fails with this line (peon-wave-16, 2026-09-05).
        "waiting for the refresh lock held by pid",
    ]

    /// The failure must OPEN an output line: the CLI and the broker print
    /// theirs at column 0, while the same words quoted from a source file,
    /// a grep hit or a Read (line-numbered, indented) don't — the sessions
    /// working on this very feature lit up as needing a login (2026-09-03).
    static let expiredLineStarts = [
        "aws: [error]",
        "[aws-cred-broker]",
        "error when retrieving token from sso",
        "the sso session",
        // The broker's advisory line is indented by exactly two spaces;
        // it is all that survives a `| tail -1` (2026-09-05).
        "  fix: aws login",
    ]

    private static let expiredMarkerBytes = expiredMarkers.map { Array($0.utf8) }
    private static let expiredLineStartBytes = expiredLineStarts.map { Array($0.utf8) }

    /// The profile a transcript excerpt says needs a login, or nil when
    /// the text carries no expired-session signature. `default` when the
    /// signature names no profile.
    public static func profile(in text: String) -> String? {
        let lower = ASCIIScan.lowered(text)
        guard expiredMarkerBytes.contains(where: { ASCIIScan.contains(lower, $0) }),
              ASCIIScan.anyLineStarts(lower, with: expiredLineStartBytes) else { return nil }
        let pattern = #"aws (?:sso )?login(?: --remote)?(?: --profile[ =]([A-Za-z0-9._-]+))"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
        return "default"
    }

    /// The profile the FAILED command addressed — `--profile X` or
    /// `AWS_PROFILE=X` in the Bash command — for the CLI's own error,
    /// which names no profile. Nil when the command names none.
    public static func profile(inCommand command: String) -> String? {
        let pattern = #"(?:--profile[ =]|AWS_PROFILE=)["']?([A-Za-z0-9._-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 1), in: command) else { return nil }
        return String(command[r])
    }

    /// Which flow signs a profile in from the phone, from the user's own
    /// `~/.aws/config` text: an SSO profile (`sso_session` /
    /// `sso_start_url`) takes the device-code flow, everything else the
    /// relay (`aws login` with the phone intercepting the callback).
    /// `.remote` stays the paste-back fallback a client may ask for.
    public static func flow(profile: String, configText: String) -> Flow {
        let values = profileValues(profile: profile, configText: configText)
        return values["sso_session"] != nil || values["sso_start_url"] != nil ? .deviceCode : .relay
    }

    /// What the sign-in page asks for and the user can't recall across
    /// accounts (user 2026-09-05: "I can't remember the aws account ids,
    /// I also have multiple"): the account id and, for an IAM user, the
    /// user name — both sit in `~/.aws/config` already (`login_session`
    /// is `arn:aws:iam::<account>:user/<name>`; SSO profiles carry
    /// `sso_account_id`). Never a secret, never `~/.aws/login`.
    public struct Account: Codable, Sendable, Equatable {
        public let accountId: String
        public let userName: String?
        public init(accountId: String, userName: String?) {
            self.accountId = accountId
            self.userName = userName
        }
    }

    public static func account(profile: String, configText: String) -> Account? {
        let values = profileValues(profile: profile, configText: configText)
        if let arn = values["login_session"] {
            let parts = arn.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 6, parts[4].count == 12, parts[4].allSatisfy(\.isNumber) {
                let resource = parts[5...].joined(separator: ":")
                let user = resource.hasPrefix("user/") ? String(resource.dropFirst("user/".count)) : nil
                return Account(accountId: parts[4], userName: user.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        if let id = values["sso_account_id"], !id.isEmpty { return Account(accountId: id, userName: nil) }
        return nil
    }

    /// The `key = value` pairs of one profile section (`[profile X]`, or
    /// `[default]` for "default").
    static func profileValues(profile: String, configText: String) -> [String: String] {
        var inProfile = false
        var values: [String: String] = [:]
        for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces)
                inProfile = name == "profile \(profile)" || (profile == "default" && name == "default")
                continue
            }
            guard inProfile, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    /// JavaScript for the relay web view: fills the sign-in page's empty
    /// account and user-name inputs (several ids, AWS renames them),
    /// through the native value setter so a framework-controlled input
    /// keeps it, and again whenever the single-page flow reveals the
    /// next step. Never a password field, never a click. Values are
    /// JSON-encoded, so nothing in a user name can escape the string.
    public static func fillScript(account: Account?) -> String? {
        guard let account else { return nil }
        func json(_ s: String?) -> String {
            guard let s, let data = try? JSONSerialization.data(withJSONObject: [s]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return String(text.dropFirst().dropLast())   // ["…"] → "…"
        }
        return """
        (function () {
          var A = \(json(account.accountId)), U = \(json(account.userName));
          var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          function fill(sel, v) {
            if (!v) return;
            document.querySelectorAll(sel).forEach(function (el) {
              if (el.type === 'password' || el.value || el.dataset.infinitusFilled) return;
              set.call(el, v);
              el.dataset.infinitusFilled = '1';
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            });
          }
          function run() {
            fill('#resolving_input, #account, input[name="account"], input[name="accountId"]', A);
            fill('#username, input[name="username"]', U);
          }
          run();
          new MutationObserver(run).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
    }

    public static func defaultConfigURL() -> URL {
        // NSHomeDirectory, not homeDirectoryForCurrentUser: Core also
        // builds for iOS, where the latter doesn't exist.
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aws/config")
    }

    // MARK: running

    /// The CLI invocation for a flow. `AWS_PAGER` is cleared by the runner.
    public static func arguments(profile: String, flow: Flow) -> [String] {
        switch flow {
        case .remote: return ["login", "--remote", "--profile", profile]
        case .deviceCode: return ["sso", "login", "--use-device-code", "--no-browser", "--profile", profile]
        case .local, .relay: return ["login", "--profile", profile]
        }
    }

    /// The loopback hosts the CLIs listen on: `aws login` redirects to
    /// `127.0.0.1`, `gcloud auth login` to `localhost` (#403).
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    /// The localhost callback port in a CLI's authorize URL
    /// (`redirect_uri=http%3A%2F%2F127.0.0.1%3A60861%2Foauth%2Fcallback`
    /// for aws, `redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F` for gcloud).
    public static func callbackPort(inURL url: String) -> Int? {
        guard let comps = URLComponents(string: url),
              let redirect = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let r = URLComponents(string: redirect), let host = r.host, loopbackHosts.contains(host)
        else { return nil }
        return r.port
    }

    /// A callback the Mac may replay: plain http to the CLI's own
    /// loopback host, port and path, carrying a code — nothing else is
    /// fetched. aws: `127.0.0.1:<port>/oauth/callback`; gcloud:
    /// `localhost:8085/`.
    public static func isValidCallback(_ url: String, port: Int, provider: Provider = .aws) -> Bool {
        guard let c = URLComponents(string: url), c.scheme == "http", c.port == port,
              c.host == (provider == .aws ? "127.0.0.1" : "localhost"),
              c.path == (provider == .aws ? "/oauth/callback" : "/") || (provider == .gcloud && c.path.isEmpty),
              c.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true
        else { return false }
        return true
    }

    /// What the CLI's output so far tells us.
    public struct Prompt: Equatable, Sendable {
        public var url: String?
        public var userCode: String?
        /// The `--remote` flow is waiting for the pasted code.
        public var wantsCode = false
        /// The CLI printed its success line.
        public var succeeded = false
        /// The CLI is asking whether to rebind the profile to the account
        /// the browser signed into (`Profile X is already configured to
        /// use session <arn>. Do you want to overwrite it … (y/n)`). The
        /// runner answers no — a silent rebind is how a profile ends up
        /// on the wrong account (the user's standing rule) — and fails
        /// the login with this message.
        public var rebindRefusal: String?
        public init() {}
    }

    static func rebindRefusal(line: String) -> String {
        let accounts = (try? NSRegularExpression(pattern: #"arn:aws:iam::(\d+):"#))
            .map { re in re.matches(in: line, range: NSRange(line.startIndex..., in: line))
                .compactMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } } } ?? []
        let profile = line.split(separator: " ").dropFirst().first.map(String.init) ?? "the profile"
        if accounts.count >= 2 {
            return "\(profile) is bound to account \(accounts[0]) but you signed in to \(accounts[1]) — not rebound; sign in to the right account and retry"
        }
        return "\(profile) is bound to another account — not rebound; sign in to the right account and retry"
    }

    public static func parseOutput(_ text: String) -> Prompt {
        var p = Prompt()
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() {
            if p.url == nil, line.hasPrefix("https://") { p.url = line }
            if p.userCode == nil, line.lowercased().hasPrefix("then enter the code") {
                // Device-code flow: the code is the next non-empty line ("XXXX-XXXX").
                if let code = lines[(i + 1)...].first(where: { !$0.isEmpty }), isValidCode(code) {
                    p.userCode = code
                }
            }
            if line.lowercased().hasPrefix("enter the authorization code") { p.wantsCode = true }
            if line.hasPrefix("Updated profile") || line.lowercased().hasPrefix("successfully logged into") {
                p.succeeded = true
            }
            if p.rebindRefusal == nil, line.lowercased().contains("already configured to use session"),
               line.lowercased().contains("overwrite") {
                p.rebindRefusal = rebindRefusal(line: line)
            }
        }
        return p
    }

    /// The `--remote` code is a base64 blob a couple of thousand
    /// characters long with `=` padding (the first real one, 2026-09-03);
    /// the device code is `XXXX-XXXX`. One character class covers both —
    /// anything else never reaches the CLI's stdin.
    public static let maxCodeLength = 8192
    public static func isValidCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= maxCodeLength
            && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_+/=".contains($0)) }
    }

    /// The message the session gets once the login lands (SessionInput
    /// message path, same as the phone's replies).
    /// `released`: the session's own `aws login` was ended by the app
    /// (#275) — say so, or the session reads its state error, runs
    /// `aws login` again and blocks another tool timeout.
    public static func continueMessage(profile: String, fromPhone: Bool, released: Bool = false) -> String {
        "[Infinitus] AWS login for profile \(profile) completed\(fromPhone ? " from the phone" : ""). "
            + (released ? "Your own `aws login` was stopped because the sign-in had already completed; "
                          + "the credentials are in place. " : "")
            + "Retry the command that needed it and continue" + (released ? " — do not run `aws login` again." : ".")
    }

    /// Pids of login wrappers an earlier app instance left behind (#274):
    /// the runner's own `script -q /dev/null <aws> login …`, reparented to
    /// launchd (ppid 1) once that instance died — a relaunch by SIGTERM
    /// never reaches the quit hook that kills them, and one was found
    /// alive 1d 21h later holding the cred broker's refresh lock. `ps` is
    /// `ps -axo pid=,ppid=,command=`; `aws` the CLI path this instance
    /// runs, so a dev instance on its own stub never touches the real
    /// app's logins.
    public static func orphanLogins(ps: String, aws: String) -> [Int32] {
        orphanLogins(ps: ps, marker: "script -q /dev/null \(aws) login")
    }

    /// The same sweep for any wrapped login command line (#367: gcloud's
    /// is `script -q /dev/null <gcloud> auth login`).
    public static func orphanLogins(ps: String, marker: String) -> [Int32] {
        return ps.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] == "1",
                  fields[2].contains(marker) else { return nil }
            return pid
        }
    }

    /// The `aws login` a session started itself and is still waiting on
    /// (#275): every `… aws login …` in `ps -axo pid=,ppid=,command=`
    /// output whose parent chain reaches `sessionPid` and that addresses
    /// `profile` (none named = the CLI's `default`), plus their
    /// descendants — a wrapped login holds its callback port on a child.
    public static func sessionLogins(ps: String, sessionPid: Int32, profile: String) -> [Int32] {
        var parent: [Int32: Int32] = [:], command: [Int32: String] = [:]
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            parent[pid] = ppid
            command[pid] = String(fields[2])
        }
        func under(_ pid: Int32, _ root: Int32) -> Bool {
            var current = pid, hops = 0
            while let p = parent[current], hops < 32 {
                if p == root { return true }
                current = p
                hops += 1
            }
            return false
        }
        let logins = command.filter { under($0.key, sessionPid) && isLogin($0.value, profile: profile) }.map(\.key)
        let subtree = command.keys.filter { pid in logins.contains { under(pid, $0) } }
        return Array(Set(logins + subtree)).sorted()
    }

    static func isLogin(_ command: String, profile: String) -> Bool {
        guard command.range(of: #"(?:^|[ /])aws login(?:\s|$)"#, options: .regularExpression) != nil else { return false }
        return (self.profile(inCommand: command) ?? "default") == profile
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -a -p <pids> -Fpn` output → pid → ports.
    public static func listeningPorts(lsof: String) -> [Int32: [Int]] {
        var out: [Int32: [Int]] = [:]
        var pid: Int32?
        for line in lsof.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let port = Int(line.split(separator: ":").last ?? "") {
                out[pid, default: []].append(port)
            }
        }
        return out
    }
}
