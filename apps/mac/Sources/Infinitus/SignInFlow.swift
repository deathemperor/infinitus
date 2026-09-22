import SwiftUI
import AuthenticationServices
import InfinitusCore

/// Native account management (user 2026-08-31: "add new account,
/// relogin, delete. do not reuse cswap['s login flow]"). The app hosts
/// `claude auth login` on a PTY — NOT `setup-token`, whose inference-
/// only token can't join an account slot (it minted a junk
/// "setup-token-7@" account, user screenshot 2026-08-31) — shows the
/// OAuth URL in a private sheet/window, takes the pasted code, then
/// runs the engine's blessed pair: `swapd add` captures the new live
/// credential into its slot, `swapd switch <previous>` restores the
/// account that was active, undoing the login's clobber in seconds.
@MainActor final class TokenFlow: ObservableObject {
    /// One app-wide flow: the popup's "re-login needed" note starts it
    /// directly from the list (user 2026-08-31), the Accounts pane
    /// mirrors whatever is in flight.
    static let shared = TokenFlow()

    enum Phase: Equatable {
        case idle
        case launching
        case awaitingLogin      // URL captured; web window is up
        case waitingForToken    // code submitted; CLI finishing
        case registering        // token captured; the engine adopts it
        case done(String)       // masked token tail
        case failed(String)
    }
    @Published var phase: Phase = .idle
    @Published var authURL: URL?
    @Published var code = ""
    /// The CLI's "OAuth error: …" line after a paste, handed back with
    /// the field (nil once a new code goes in).
    @Published var codeError: String?
    /// Why the system sign-in sheet did not come up, when it did not
    /// (a plain cancel is not a failure and leaves this nil).
    @Published var sheetError: String?
    /// Set on the browser route (#1180): the browser that took the sheet
    /// and where the page went. Information, not a failure.
    @Published var browserRoute: (name: String, note: String)?
    /// Which account this flow is for (relogin) — display only; cswap
    /// matches the credential identity itself.
    @Published var reloginTarget: String?
    private var reloginEmail: String?
    private var preEmails: Set<String> = []

    private var process: Process?
    private weak var model: AppModel?
    private var master: FileHandle?
    private var buffer = ""
    /// The CLI's last lines, plain text, shown under "Waiting for the
    /// token" — a stall then says what the CLI is waiting for instead of
    /// spinning mutely (user 2026-09-07, stuck at the spinner again).
    @Published var cliTail = ""
    private var previousActive: Int?
    private var shimDir: URL?
    private var authWindow: NSWindow?
    private var systemSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthAnchorProvider?
    /// Engine-driven variant (`.addOAuth`, the proxy): the poll task,
    /// and whether the companion window needs the paste-code bar.
    private var engineTask: Task<Void, Never>?
    @Published var pasteCode = true
    /// The control verbs' handle on a run (#677): a fresh id per start.
    /// `headless` skips the sheet and the companion window — the desktop
    /// app hosts the OAuth page itself and hands the code back through
    /// `signin-code`. `completedEmail` is the address a finished run
    /// bound (the relogin target, or the one new account).
    private(set) var flowID: String?
    private(set) var headless = false
    private(set) var completedEmail: String?
    /// A headless engine run whose redirect lands on this Mac's loopback:
    /// the port the engine listens on. The caller's browser may be on
    /// another machine, where that redirect goes nowhere — it hands the
    /// address back through `signin-code` and `submitRedirect` replays it
    /// here (`OAuthRedirectRelay`). Nil for the paste-code flow and for a
    /// window run, whose sheet is on this Mac and reaches the listener itself.
    private(set) var redirectPort: Int?

    var running: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    func start(model: AppModel, relogin: Account? = nil, headless: Bool = false) {
        guard !running else { return }
        flowID = UUID().uuidString
        self.headless = headless
        completedEmail = nil
        reloginTarget = relogin.map { ($0.alias?.isEmpty == false ? $0.alias! : $0.email) }
        reloginEmail = relogin?.email
        previousActive = model.activeNumber
        preEmails = Set(model.accounts.map(\.email))
        code = ""
        buffer = ""
        authURL = nil
        redirectPort = nil
        sheetError = nil
        browserRoute = nil
        pasteCode = true
        phase = .launching
        self.model = model
        do { try launch(model: model) } catch {
            phase = .failed("couldn't start claude setup-token: \(error.localizedDescription)")
        }
    }

    func cancel() {
        codeError = nil
        process?.terminate()
        engineTask?.cancel()
        cleanup()
        phase = .idle
    }

    /// The same chooser for an engine that signs accounts in through a
    /// browser (swapd's `add-oauth`, the proxy): the engine hands us the
    /// login URL, the OAuth redirect lands on the engine's own loopback
    /// callback, and we wait until it holds the credential — nothing to
    /// paste. The private sheet / incognito window is the same one. Same
    /// per-account cookie jar as the cswap flow (user 2026-09-02:
    /// "share cookiejar with cswap"): a re-login for an address that
    /// already has a jar opens signed in, whichever engine made it.
    /// `onFinish` gets nil on success or cancel, else the error text.
    func start(model: AppModel, engine: any AccountEngine, provider: Provider,
               relogin: Account? = nil, headless: Bool = false,
               onFinish: @escaping (String?) -> Void) {
        guard !running else { return }
        flowID = UUID().uuidString
        self.headless = headless
        completedEmail = nil
        reloginTarget = relogin.map { ($0.alias?.isEmpty == false ? $0.alias! : $0.email) }
        reloginEmail = relogin?.email
        let fleetEmails = { (model: AppModel) -> Set<String> in
            Set(model.registry.fleets
                .first { $0.engineID == engine.id && $0.provider == provider }?
                .accounts.map(\.email) ?? [])
        }
        preEmails = fleetEmails(model)
        code = ""
        authURL = nil
        redirectPort = nil
        sheetError = nil
        browserRoute = nil
        pasteCode = false
        phase = .launching
        self.model = model
        engineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.beginOAuthAdd(fleet: provider)
                self.authURL = url
                self.redirectPort = headless ? OAuthRedirectRelay.loopbackPort(of: url) : nil
                self.phase = .awaitingLogin
                self.openAuthWindow(url)
                try await engine.awaitOAuthAdd()
                self.phase = .registering
                await model.refreshSnapshot()
                if let email = self.reloginEmail {
                    self.completedEmail = email
                } else {
                    let new = fleetEmails(model).subtracting(self.preEmails)
                    if let email = new.first, new.count == 1 {
                        self.completedEmail = email
                    }
                }
                self.phase = .done("captured")
                onFinish(nil)
            } catch {
                if Task.isCancelled {
                    self.phase = .idle
                    onFinish(nil)
                } else {
                    // swapd's own refusal is a sentence already ("the
                    // sign-in was refused (access_denied)"); the generic
                    // "engine refused that change" would hide it.
                    let msg = (error as? SignInFailure)?.sentence
                        ?? (error as? CLIError)?.message
                        ?? EngineFailure.sentence(error)
                    self.phase = .failed(msg)
                    onFinish(msg)
                }
            }
            self.cleanup()
        }
    }

    /// Paste-back: the code from the OAuth success page goes to the
    /// CLI's tty (CR = tty newline).
    func submitCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer = ""            // only the CLI's answer to this paste matters now
        codeError = nil
        master?.write(Data((trimmed + "\r").utf8))
        phase = .waitingForToken
        closeAuthWindow()
    }

    /// The redirect a browser on another machine ended on, replayed against
    /// the engine's listener here (`OAuthRedirectRelay`): one GET, which is
    /// what the browser would have sent. The engine answers 200 and goes on
    /// to redeem the code — `awaitOAuthAdd` then moves the phase — or 400
    /// for an address that is not this sign-in's. Returns the refusal, or
    /// nil when the listener took it; the pasted value reaches no message.
    func submitRedirect(_ pasted: String) async -> String? {
        guard let port = redirectPort else { return "this sign-in takes no address" }
        guard let url = OAuthRedirectRelay.replayURL(pasted: pasted, port: port) else {
            return "That is not this sign-in's address: paste the whole address the browser ended on (http://localhost:\(port)/…)."
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return "The sign-in did not accept that address (HTTP \(status)); start the sign-in again."
            }
            return nil
        } catch {
            return "The sign-in is no longer waiting for its redirect; start it again."
        }
    }

    // MARK: plumbing

    private static func claudePath() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A failure this window can explain itself; everything else goes
    /// through EngineFailure.sentence.
    private struct SignInFailure: Error { let sentence: String }

    private func launch(model: AppModel) throws {
        guard let claude = Self.claudePath() else {
            throw SignInFailure(sentence: "Infinitus can't find the Claude CLI on this Mac. Install it, then try again.")
        }
        // `open` shim first in the child's PATH: setup-token tries to
        // open the OAuth URL in the default browser itself — the shim
        // swallows that (and stashes the URL as a bonus capture path).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-auth-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("open")
        try "#!/bin/sh\necho \"$@\" > \"\(dir.path)/url\"\nexit 0\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shim.path)
        shimDir = dir

        var m: Int32 = 0
        var s: Int32 = 0
        // 500 columns: at the default 80 the TUI hard-wraps its output,
        // splitting the OAuth URL and the minted token across lines —
        // regex capture then truncates (probed live 2026-08-31).
        var ws = winsize(ws_row: 40, ws_col: 500, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else {
            throw SignInFailure(sentence: "Infinitus couldn't open a terminal for the sign-in. Try again.")
        }
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        let masterFH = FileHandle(fileDescriptor: m, closeOnDealloc: true)
        master = masterFH

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        // The REAL login (full account credential), temporarily taking
        // the live slot; finished() hands it to the engine and switches
        // back. --email prefills the relogin target's address.
        var args = ["auth", "login", "--claudeai"]
        if let email = reloginEmail { args += ["--email", email] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TERM"] = "xterm-256color"
        p.environment = env
        p.standardInput = slave
        p.standardOutput = slave
        p.standardError = slave
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(status: proc.terminationStatus,
                                                      model: model) }
        }
        try p.run()
        close(s)
        process = p

        masterFH.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        // The model reference rides the termination handler; nothing
        // else to do until output arrives.
    }

    /// Strip ANSI control sequences (setup-token is a TUI).
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}",
            with: "", options: .regularExpression)
    }

    private func consume(_ chunk: String) {
        buffer += Self.plain(chunk)
        if buffer.count > 20_000 { buffer = String(buffer.suffix(10_000)) }
        // A half-copied code ("Invalid code. Please make sure the full
        // code was copied" — the CLI wants `code#state`) or a failed
        // exchange comes back as an "OAuth error: …" line plus "Press
        // Enter to try again"; unsurfaced, the flow spun at "Waiting for
        // the token" forever (user 2026-09-07). Hand the field back.
        cliTail = buffer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("https://") }
            .suffix(3).joined(separator: "\n")
        if case .waitingForToken = phase {
            // "OAuth error: …" is the CLI's wording; "Invalid code" /
            // "Login failed" / "Error: …" cover the rest of its vocabulary.
            let rejection: String? = {
                if let r = buffer.range(of: "OAuth error: ") {
                    return buffer[r.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init)
                }
                return buffer.split(whereSeparator: \.isNewline).map(String.init).last {
                    $0.range(of: #"(?i)(invalid|failed|error)"#, options: .regularExpression) != nil
                }
            }()
            if let rejection {
                codeError = rejection.trimmingCharacters(in: .whitespaces)
                code = ""
                phase = .awaitingLogin
                master?.write(Data("\r".utf8))    // back to the paste prompt
                buffer = ""
            }
        }
        // OAuth URL: the shim's stash first — it gets the exact argv
        // URL with no tty wrapping risk; stdout regex is the fallback.
        if authURL == nil {
            var found: String?
            if let dir = shimDir,
               let stash = try? String(contentsOf: dir.appendingPathComponent("url"),
                                       encoding: .utf8),
               !stash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found = stash.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if found == nil, let r = buffer.range(
                of: #"https://[A-Za-z0-9./?#=&%_+~:-]+"#,
                options: .regularExpression) {
                found = String(buffer[r])
            }
            if let found, found.contains("oauth") || found.contains("claude.ai")
                || found.contains("anthropic.com"),
               let url = URL(string: found) {
                authURL = url
                phase = .awaitingLogin
                openAuthWindow(url)
            }
        }
    }

    private func finished(status: Int32, model: AppModel) {
        master?.readabilityHandler = nil
        guard status == 0 else {
            let tail = buffer.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = tail.isEmpty ? "claude auth login exited \(status)"
                                   : String(tail)
            phase = .failed(msg)
            model.lastError = "relogin: \(msg.prefix(120))"
            cleanup()
            return
        }
        phase = .registering
        let restoreTo = previousActive
        Task {
            do {
                guard let engine = model.currentLoginEngine else {
                    throw SignInFailure(sentence: "The engine isn't running. Start it under Engines, then try again.")
                }
                // The blessed pair: capture the fresh credential into
                // its slot, then restore whoever was active before.
                try await engine.addCurrent()
                if let n = restoreTo {
                    try? await engine.switchTo(fleet: .claude, number: n)
                }
                await model.refreshSnapshot()
                // The account this flow signed in: the relogin target,
                // or the one new email.
                if let email = self.reloginEmail {
                    self.completedEmail = email
                } else {
                    let new = Set(model.accounts.map(\.email))
                        .subtracting(self.preEmails)
                    if let email = new.first, new.count == 1 {
                        self.completedEmail = email
                    }
                }
                self.phase = .done("captured")
            } catch {
                self.phase = .failed((error as? SignInFailure)?.sentence ?? EngineFailure.sentence(error))
            }
            self.cleanup()
        }
    }

    private func cleanup() {
        closeAuthWindow()
        if let dir = shimDir { try? FileManager.default.removeItem(at: dir) }
        shimDir = nil
        process = nil
        master = nil
        engineTask = nil
    }

    // MARK: login windows

    /// Sheet-first (user 2026-08-31 — the footer-link version was
    /// rejected): capturing the OAuth URL immediately opens the SYSTEM
    /// sign-in sheet, where passkeys, Touch ID and Google all just
    /// work, anchored to a compact companion window holding the
    /// paste-code bar.
    private func openAuthWindow(_ url: URL) {
        // A headless run (#677) shows nothing here: the desktop app
        // opened `url` in its own window and pastes the code back.
        guard !headless else { return }
        let host = NSHostingController(rootView: AuthWindowRoot(flow: self))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = reloginTarget.map { "Re-login \u{2014} \($0)" }
            ?? "Add Claude account"
        w.contentViewController = host
        w.setContentSize(NSSize(width: 520, height: 190))
        w.isReleasedWhenClosed = false
        w.center()
        // Above a PINNED pop-out, which floats (user 2026-09-13: the
        // re-login window "closes immediately" — it opened at .normal
        // under a full-screen pinned pop-out at .floating and was never
        // reachable again). Settings does the same.
        w.level = .floating
        authWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // ALWAYS the sheet: it does passkeys AND passwords. A per-account
        // WKWebView "private window" (no passkeys — WebAuthn is
        // entitlement-locked to real browsers) was the opt-in alternative
        // until 2026-09-14; the desktop's sign-in page and the browser
        // route cover its case now. A sheet SHARING the browser's
        // cookies behind a claude.ai logout hop was tried (2026-09-07):
        // Google remembered, but the double sheet flash bothered more
        // than typing the email — reverted the same day.
        startSystemSheet()
    }

    /// Passkey path (user 2026-08-31: "couldn't use passkey"): WebAuthn
    /// is entitlement-locked to real browsers — a WKWebView only gets
    /// the Bluetooth-hybrid fallback, which fails. The system sheet
    /// (Safari's out-of-process service) has full passkey support.
    /// Its cookie store is app-shared, not per-account — Google's own
    /// account chooser covers multi-account there.
    func startSystemSheet() {
        guard let url = authURL else { return }
        sheetError = nil
        browserRoute = nil
        // A default browser that declares sheet support gets the session
        // from macOS instead of Safari — and Chrome, which declares it,
        // presents nothing (user 2026-09-14: "flash of browser focus,
        // nothing opens"; the request sat queued until cancelled). Open
        // the page there ourselves, in a private window where it has one.
        if case .browser(let name, let flag) = Self.sheetRoute(for: url) {
            openInDefaultBrowser(url, name: name, privateFlag: flag)
            return
        }
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: nil) { [weak self] _, error in
            // No custom-scheme callback exists — the flow ends when the
            // user copies the code and closes the sheet, so a plain
            // cancel is the NORMAL ending and says nothing. Any other
            // error means the sheet never got the user to the page, and
            // silence there left the user with nothing (user 2026-09-14:
            // "the windows didn't open").
            self?.systemSession = nil
            guard let error else { return }
            let failure = error as NSError
            guard !(failure.domain == ASWebAuthenticationSessionErrorDomain
                    && failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue)
            else { return }
            self?.sheetError = failure.localizedDescription
        }
        let provider = AuthAnchorProvider(window: authWindow)
        anchorProvider = provider
        session.presentationContextProvider = provider
        // EPHEMERAL, non-negotiably: the shared sheet store carried
        // account 1's claude session into account 2's relogin ("it
        // opens my account1", user screenshot 2026-08-31). Passkeys
        // don't need cookies — they live in the OS keychain — so a
        // fresh session costs one Touch ID tap and bleeds nothing.
        session.prefersEphemeralWebBrowserSession = true
        systemSession = session
        // `start()` answers false when the sheet cannot present at all —
        // an anchor window that is off-screen or buried does it. Dropping
        // that Bool is what made the sheet look like it simply never
        // opened; say so and offer the way on.
        if !session.start() {
            systemSession = nil
            sheetError = "The sign-in sheet couldn't open. Try \u{201C}Reopen sign-in sheet\u{201D}."
        }
    }

    /// The default https handler's verdict, read off its bundle.
    static func sheetRoute(for url: URL) -> SignInSheetRoute {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundle = Bundle(url: app) else { return .systemSheet }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        return SignInSheetRoute.classify(
            bundleID: bundle.bundleIdentifier, name: name,
            capabilities: info[SignInSheetRoute.capabilitiesKey] as? [String: Any])
    }

    /// `open -na <browser> --args <flag> --user-data-dir=<fresh> <url>`: a
    /// browser instance of its own, on an empty profile. A running browser
    /// gets a URL over Apple Events and ignores launch arguments, and a
    /// second instance handing `--incognito` to the running one was seen
    /// to open the page in the signed-in profile instead (user 2026-09-21,
    /// Chrome 153: "I have to switch accounts") — so the private window
    /// is not asked of the running browser at all. A different
    /// `--user-data-dir` is what makes the Chromium family start a
    /// separate process rather than hand off, and the profile is wiped
    /// before every launch, so the page opens signed in to nothing;
    /// passkeys live in the OS keychain and work there. NSWorkspace's
    /// `open(_:withApplicationAt:configuration:)` sends the URL the
    /// Apple-Events way and drops every flag for the same reason.
    private func openInDefaultBrowser(_ url: URL, name: String, privateFlag: String?) {
        var placement = "in your profile \u{2014} if it is signed in to another Claude account, sign out there first"
        if let privateFlag, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let profile = FileManager.default.temporaryDirectory
                .appendingPathComponent("infinitus-signin-profile")
            try? FileManager.default.removeItem(at: profile)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-na", app.path, "--args", privateFlag,
                              "--user-data-dir=\(profile.path)",
                              "--no-first-run", "--no-default-browser-check",
                              url.absoluteString]
            do {
                try open.run()
                placement = "in a private window of its own, signed in to nothing"
            } catch {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        browserRoute = (name, "\(name) takes over the sign-in sheet, so the page opened there "
            + "(\(placement)). Paste the code back here; with Safari as the default "
            + "browser the sheet opens in this app.")
        // The user is in the browser now: the companion window goes back
        // under it (#1134's .floating stays for the sheet route);
        // reopenAuth floats it again when they come back for the paste bar.
        authWindow?.level = .normal
    }

    /// Brings a running flow's windows back to the front — the only way
    /// in once they are buried, and what a second click on Add / Re-login
    /// does. A headless run has no windows of ours to raise.
    func reopenAuth() {
        guard !headless else { return }
        if let w = authWindow {
            w.level = .floating      // back above a pinned pop-out (#1134)
            w.makeKeyAndOrderFront(nil)
        } else if let url = authURL {
            openAuthWindow(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeAuthWindow() {
        authWindow?.orderOut(nil)
        authWindow = nil
        systemSession?.cancel()
        systemSession = nil
        anchorProvider = nil
    }
}

/// Presentation anchor for the system sign-in sheet.
final class AuthAnchorProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor {
        // Never `NSApp.windows.first`: this app is LSUIElement, so that
        // is the status-bar window, which cannot host the sheet. Fall
        // back to a real visible titled window, else a bare anchor.
        window ?? NSApp.windows.first {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        } ?? ASPresentationAnchor()
    }
}

/// The companion window: sign-in status + the paste-code bar. The
/// actual signing-in happens in the system sheet (passkeys work
/// there), which this window anchors.
private struct AuthWindowRoot: View {
    @ObservedObject var flow: TokenFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = flow.reloginTarget {
                Text("Re-login for \(target) \u{2014} sign in as that account.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if flow.pasteCode {
                Text("1. Sign in and approve in the sign-in sheet "
                     + "(the sheet is a fresh private session \u{2014} "
                     + "passkeys and Touch ID work; it never remembers "
                     + "another account).\n"
                     + "2. Copy the code it shows and paste it here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Paste the code shown after approval",
                              text: $flow.code)
                        .textFieldStyle(.roundedBorder)
                    Button("Submit") { flow.submitCode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(flow.code.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                    Button("Cancel") { flow.cancel() }
                }
            } else {
                Text("Sign in and approve in the sign-in sheet "
                     + "(the sheet is a fresh private session \u{2014} "
                     + "passkeys and Touch ID work). This closes by "
                     + "itself once the engine holds the credential.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if flow.phase == .registering {
                        ProgressView().controlSize(.small)
                        Text("Credential received \u{2014} refreshing…")
                            .font(.caption)
                    }
                    Spacer()
                    Button("Cancel") { flow.cancel() }
                }
            }
            if let why = flow.sheetError {
                Text(why).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let route = flow.browserRoute {
                Text(route.note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(flow.browserRoute.map { "Open in \($0.name) again" }
                   ?? "Reopen sign-in sheet") { flow.startSystemSheet() }
        }
        .padding(14)
        .frame(width: 520, alignment: .leading)
    }
}
