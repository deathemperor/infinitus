import SwiftUI
import WebKit
import AuthenticationServices
import InfinitusCore

/// Native account management (user 2026-08-31: "add new account,
/// relogin, delete. do not reuse cswap['s login flow]"). The app hosts
/// `claude auth login` on a PTY — NOT `setup-token`, whose inference-
/// only token can't join an account slot (it minted a junk
/// "setup-token-7@" account, user screenshot 2026-08-31) — shows the
/// OAuth URL in a private sheet/window, takes the pasted code, then
/// runs the engine's blessed pair: `cswap add` captures the new live
/// credential into its slot, `cswap switch <previous>` restores the
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
        case registering        // token captured; cswap add-token runs
        case done(String)       // masked token tail
        case failed(String)
    }
    @Published var phase: Phase = .idle
    @Published var authURL: URL?
    @Published var code = ""
    /// Which account this flow is for (relogin) — display only; cswap
    /// matches the credential identity itself.
    @Published var reloginTarget: String?
    /// Persistent per-account web session (user 2026-08-31: "if
    /// relogin an account can open that browser session of that
    /// account"): each account gets its own WKWebsiteDataStore
    /// identifier, so a relogin window opens already signed in — the
    /// approve click is usually all that's left. Adds start fresh
    /// under a new identifier, bound to the account once it appears.
    private var storeID = UUID()
    private var reloginEmail: String?
    private var preEmails: Set<String> = []
    private static let mapKey = "auth_web_store_map"

    private static func storeMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }
    private static func bind(email: String, id: UUID) {
        var m = storeMap()
        m[email] = id.uuidString
        UserDefaults.standard.set(m, forKey: mapKey)
    }

    private var process: Process?
    private weak var model: AppModel?
    private var master: FileHandle?
    private var buffer = ""
    private var previousActive: Int?
    private var shimDir: URL?
    private var authWindow: NSWindow?
    private var webWindow: NSWindow?
    private var webDelegate: AuthWebDelegate?
    private var systemSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthAnchorProvider?
    /// Engine-driven variant (`.addOAuth`, the proxy): the poll task,
    /// and whether the companion window needs the paste-code bar.
    private var engineTask: Task<Void, Never>?
    @Published var pasteCode = true

    var running: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    func start(model: AppModel, relogin: Account? = nil) {
        guard !running else { return }
        reloginTarget = relogin.map { ($0.alias?.isEmpty == false ? $0.alias! : $0.email) }
        reloginEmail = relogin?.email
        previousActive = model.activeNumber
        preEmails = Set(model.accounts.map(\.email))
        if let email = relogin?.email,
           let saved = Self.storeMap()[email], let id = UUID(uuidString: saved) {
            storeID = id            // reopen THIS account's session
        } else {
            storeID = UUID()        // fresh jar for a fresh login
        }
        code = ""
        buffer = ""
        authURL = nil
        pasteCode = true
        phase = .launching
        self.model = model
        do { try launch(model: model) } catch {
            phase = .failed("couldn't start claude setup-token: \(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
        engineTask?.cancel()
        cleanup()
        phase = .idle
    }

    /// The same chooser for an engine that signs accounts in through a
    /// browser (the proxy): its Management API hands us the login URL,
    /// the OAuth redirect lands on the engine's own callback, and we
    /// poll until it reports the credential — nothing to paste. Same
    /// per-account cookie jar as the cswap flow (user 2026-09-02:
    /// "share cookiejar with cswap"): a re-login for an address that
    /// already has a jar opens signed in, whichever engine made it.
    /// `onFinish` gets nil on success or cancel, else the error text.
    func start(model: AppModel, engine: any AccountEngine, provider: Provider,
               relogin: Account? = nil, onFinish: @escaping (String?) -> Void) {
        guard !running else { return }
        reloginTarget = relogin.map { ($0.alias?.isEmpty == false ? $0.alias! : $0.email) }
        reloginEmail = relogin?.email
        let fleetEmails = { (model: AppModel) -> Set<String> in
            Set(model.registry.fleets
                .first { $0.engineID == engine.id && $0.provider == provider }?
                .accounts.map(\.email) ?? [])
        }
        preEmails = fleetEmails(model)
        if let email = relogin?.email,
           let saved = Self.storeMap()[email], let id = UUID(uuidString: saved) {
            storeID = id
        } else {
            storeID = UUID()
        }
        code = ""
        authURL = nil
        pasteCode = false
        phase = .launching
        self.model = model
        engineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.beginOAuthAdd(fleet: provider)
                self.authURL = url
                self.phase = .awaitingLogin
                self.openAuthWindow(url)
                try await engine.awaitOAuthAdd()
                self.phase = .registering
                await model.refreshSnapshot()
                if let email = self.reloginEmail {
                    Self.bind(email: email, id: self.storeID)
                } else {
                    let new = fleetEmails(model).subtracting(self.preEmails)
                    if let email = new.first, new.count == 1 {
                        Self.bind(email: email, id: self.storeID)
                    }
                }
                self.phase = .done("captured")
                onFinish(nil)
            } catch {
                if Task.isCancelled {
                    self.phase = .idle
                    onFinish(nil)
                } else {
                    let msg = (error as? EngineError)?.errorDescription ?? "\(error)"
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
        master?.write(Data((trimmed + "\r").utf8))
        phase = .waitingForToken
        closeAuthWindow()
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

    private func launch(model: AppModel) throws {
        guard let claude = Self.claudePath() else {
            throw CLIError(message: "claude CLI not found")
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
            throw CLIError(message: "openpty failed")
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
                guard let cli = model.cswap else {
                    throw CLIError(message: "no engine")
                }
                // The blessed pair: capture the fresh credential into
                // its slot, then restore whoever was active before.
                try await cli.addCurrent()
                if let n = restoreTo {
                    try? await cli.switchTo(n)
                }
                await model.refreshSnapshot()
                // Bind the web session to its account for future
                // relogins: the relogin target, or the one new email.
                if let email = self.reloginEmail {
                    Self.bind(email: email, id: self.storeID)
                } else {
                    let new = Set(model.accounts.map(\.email))
                        .subtracting(self.preEmails)
                    if let email = new.first, new.count == 1 {
                        Self.bind(email: email, id: self.storeID)
                    }
                }
                self.phase = .done("captured")
            } catch {
                self.phase = .failed("engine refused the account: \(error)")
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
    /// paste-code bar. The per-account private WKWebView window stays
    /// available as the opt-in alternative for isolated sessions.
    private func openAuthWindow(_ url: URL) {
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
        authWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // ALWAYS the sheet: it does passkeys AND passwords. The
        // saved-session auto-routing sent a passkey account into the
        // private window — where WebAuthn can never run — and hit the
        // Bluetooth-fallback wall again (user screenshot 2026-08-31).
        // The private window stays strictly opt-in.
        startSystemSheet()
    }

    /// The opt-in private window: this account's own isolated session
    /// (signed in already on later re-logins), Safari UA, popup
    /// hosting. No passkeys — WebAuthn is entitlement-locked to real
    /// browsers; password sign-in works.
    func openPrivateWindow() {
        guard let url = authURL else { return }
        if let w = webWindow { w.makeKeyAndOrderFront(nil); return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/26.0 Safari/605.1.15"
        let delegate = AuthWebDelegate()
        webDelegate = delegate
        web.uiDelegate = delegate
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude login (private)"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        webWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Passkey path (user 2026-08-31: "couldn't use passkey"): WebAuthn
    /// is entitlement-locked to real browsers — a WKWebView only gets
    /// the Bluetooth-hybrid fallback, which fails. The system sheet
    /// (Safari's out-of-process service) has full passkey support.
    /// Its cookie store is app-shared, not per-account — Google's own
    /// account chooser covers multi-account there.
    func startSystemSheet() {
        guard let url = authURL else { return }
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: nil) { [weak self] _, _ in
            // No custom-scheme callback exists — the flow ends when the
            // user copies the code and closes the sheet; nothing to do.
            self?.systemSession = nil
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
        session.start()
    }

    func reopenAuth() {
        if let w = authWindow {
            w.makeKeyAndOrderFront(nil)
        } else if let url = authURL {
            openAuthWindow(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeAuthWindow() {
        authWindow?.orderOut(nil)
        authWindow = nil
        webWindow?.orderOut(nil)
        webWindow = nil
        webDelegate?.closePopups()
        webDelegate = nil
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
        window ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// OAuth popup host: window.open from the login page (Google's flow)
/// gets a real child window sharing the SAME configuration — required
/// by WebKit, and what keeps the popup inside the private session.
@MainActor final class AuthWebDelegate: NSObject, WKUIDelegate {
    private var popups: [NSWindow] = []

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = webView.customUserAgent
        web.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return web
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let i = popups.firstIndex(where: { $0.contentView === webView }) {
            popups[i].orderOut(nil)
            popups.remove(at: i)
        }
    }

    func closePopups() {
        popups.forEach { $0.orderOut(nil) }
        popups = []
    }
}

private struct AuthWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
                Text("1. Sign in and approve in the sign-in sheet or window "
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
                Text("Sign in and approve in the sign-in sheet or window "
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
            HStack(spacing: 6) {
                Button("Reopen sign-in sheet") { flow.startSystemSheet() }
                Button("Use private window (no passkeys)") {
                    flow.openPrivateWindow()
                }
                .help("An isolated per-account browser session \u{2014} "
                      + "remembers this account's login for the next "
                      + "re-login. Passkeys CANNOT work there (a macOS "
                      + "restriction); password sign-in only.")
            }
        }
        .padding(14)
        .frame(width: 520, alignment: .leading)
    }
}

struct AccountsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var flow = TokenFlow.shared
    @State private var confirmDelete: (fleet: FleetState, account: Account)?

    /// An engine that is on but holds no credential yet (a fresh proxy)
    /// has no FleetState to list — it still gets a section with the
    /// add button, so the first credential can be added from here.
    private struct EngineRef: Identifiable { let id: String; let name: String }
    private var fleetlessOAuthEngines: [EngineRef] {
        model.registry.engines
            .filter { e in e.capabilities.contains(.addOAuth)
                && !model.fleets.contains { $0.engineID == e.id } }
            .map { EngineRef(id: $0.id, name: $0.displayName) }
    }

    var body: some View {
        Form {
            // One section per fleet (user 2026-09-02: "cswap account
            // management is under Accounts but CLIProxyAPI's is under
            // CLIProxyAPI, revamp that") — same rows, same icons; each
            // control shows only where the fleet's engine supports it.
            ForEach(model.fleets) { fleet in
                FleetAccountsSection(fleet: fleet, model: model, flow: flow,
                                     confirmDelete: $confirmDelete)
            }
            ForEach(fleetlessOAuthEngines) { engine in
                Section("Claude · \(engine.name)") {
                    Text("No credentials yet.").foregroundStyle(.secondary)
                    OAuthAddRow(model: model, engineID: engine.id, provider: .claude)
                }
            }
            if model.fleets.isEmpty && fleetlessOAuthEngines.isEmpty {
                Section("Accounts") {
                    Text("No engine is on \u{2014} turn one on in the CLIProxyAPI tab.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Remove \(confirmDelete?.account.alias ?? confirmDelete?.account.email ?? "account")?",
               isPresented: Binding(get: { confirmDelete != nil },
                                    set: { if !$0 { confirmDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let d = confirmDelete { d.fleet.remove(d.account.number) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("\(confirmDelete?.fleet.engine.displayName ?? "The engine") forgets its "
                 + "stored credential. The Claude account itself is untouched "
                 + "\u{2014} you can add it back any time.")
        }
    }
}

/// One fleet's rows in the Accounts tab. The row layout is shared by
/// every engine; capabilities decide which controls appear (drag +
/// sort toggles need `.reorder`, the name field `.rename`, and so on).
private struct FleetAccountsSection: View {
    @ObservedObject var fleet: FleetState
    @ObservedObject var model: AppModel
    @ObservedObject var flow: TokenFlow
    @Binding var confirmDelete: (fleet: FleetState, account: Account)?

    private var isCswap: Bool { fleet.engineID == CswapEngine.engineID }
    private var caps: EngineCapabilities { fleet.capabilities }
    private var canRelogin: Bool { isCswap || caps.contains(.addOAuth) }

    var body: some View {
        Section("\(fleet.provider.displayName) \u{00B7} \(fleet.engine.displayName)") {
            if caps.contains(.reorder) {
                // Display-only (todo 2026-09-01): the popup shows headroom
                // order with active + next on top; engine slot numbers
                // stay put.
                Toggle("Popup sorts rows by headroom (active and next first)",
                       isOn: $model.sortByHeadroom)
                    .help("Display only \u{2014} the popup lists the active "
                          + "account, then the next candidate, then most "
                          + "headroom first. Slot numbers don't move; "
                          + "this list keeps the engine's order.")
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
            if fleet.accounts.isEmpty {
                Text("No accounts yet \u{2014} add the first one below.")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(fleet.accounts, id: \.number) { a in
                    row(a).moveDisabled(!caps.contains(.reorder))
                        .contextMenu {
                            if caps.contains(.rename) {
                                Button("Re-roll name") { fleet.randomizeName(a.number) }
                            }
                        }
                }
                .onMove { from, to in
                    guard caps.contains(.reorder) else { return }
                    var order = fleet.accounts.map(\.number)
                    order.move(fromOffsets: from, toOffset: to)
                    fleet.reorder(order)
                }
            }
            .frame(minHeight: CGFloat(fleet.accounts.count) * 30 + 16)
            if let err = model.reorderError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if caps.contains(.rename), !fleet.accounts.isEmpty {
                Button("Randomize names") { fleet.randomizeNames() }
                    .help("Every account gets a fresh name drawn from the "
                          + "\(model.rowTheme.name) theme's pool; the Off theme "
                          + "and themes without a pool draw from every built-in.")
            }
            if isCswap {
                CswapAddFlow(model: model, flow: flow)
            } else if caps.contains(.addOAuth) {
                OAuthAddRow(model: model, engineID: fleet.engineID, provider: fleet.provider)
            }
        }
    }

    @ViewBuilder private func row(_ a: Account) -> some View {
        HStack(spacing: 8) {
            if caps.contains(.reorder) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
            }
            Text("\(a.number)").monospacedDigit()
                .foregroundStyle(.secondary)
            if caps.contains(.rename) {
                RenameField(fleet: fleet, account: a)
            }
            Text(a.email).lineLimit(1)
                .font(.caption).foregroundStyle(.secondary)
            if let plan = a.plan {
                Text(plan)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule()
                        .fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            statusChip(a)
            Spacer()
            if caps.contains(.prefer), let confirmed = a.preferred {
                // Pick-first (#15) is the engine's knob: nil `preferred`
                // means this engine build has none, so no star at all.
                // A pending flip shows at once, dimmed until the engine
                // confirms it.
                let pending = fleet.pendingPreferred[a.number]
                let starred = pending ?? confirmed
                Button { fleet.setPreferred(a.number, !starred) } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .foregroundStyle(starred ? Color.yellow : Color.secondary)
                        .opacity(pending == nil ? 1 : 0.5)
                }
                .buttonStyle(.borderless)
                .disabled(flow.running || pending != nil)
                .help(starred
                      ? "Preferred: the engine lands on this account first when it switches"
                      : (isCswap
                         ? "Prefer this account: switches to it now, and auto-switch lands on it first when it qualifies (autoswitch.preferred)"
                         : "Prefer this account: switches to it now, and the proxy drains it before unstarred ones (priority tier)"))
            }
            if caps.contains(.switch), !a.active {
                Button { fleet.switchTo(a.number) } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .help(isCswap ? "Switch to this account now"
                              : "Make this the active credential (top priority tier)")
            }
            if caps.contains(.hold) {
                // Rotation hold (todo 2026-09-01): the row stays listed,
                // auto-rotation (or the proxy's routing) skips it.
                Button {
                    fleet.setRotation(a.number, enabled: a.disabled ?? false)
                } label: {
                    Image(systemName: (a.disabled ?? false)
                          ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .help((a.disabled ?? false)
                      ? "Return this account to rotation"
                      : "Hold this account out of rotation "
                        + "(it stays listed, rotation skips it)")
            }
            if canRelogin {
                Button("Relogin") { fleet.startRelogin(a) }
                    .disabled(flow.running)
            }
            if caps.contains(.remove) {
                Button(role: .destructive) {
                    confirmDelete = (fleet, a)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .help("Remove this account from \(fleet.engine.displayName)")
            }
        }
    }

    /// Same sentences in every section, each present only when the
    /// fleet has the control it describes (user 2026-09-02: "make sure
    /// 2 sections saying same things").
    private var caption: String {
        var parts: [String] = []
        if caps.contains(.reorder) {
            parts.append("Drag rows to set the rotation order \u{2014} Rotate cycles through them.")
        }
        if caps.contains(.prefer) {
            parts.append(fleet.accounts.contains { $0.preferred != nil }
                ? "Star an account to have the engine land on it first when it switches."
                : "Stars need a cswap with the autoswitch.preferred setting (claude-swap PR #312).")
        }
        if caps.contains(.switch) || caps.contains(.hold) {
            parts.append("The arrow switches to that account; pause holds it "
                         + "out of rotation (it stays listed).")
        }
        if caps.contains(.rename) {
            parts.append("Type in the Name field to rename an account (shown "
                         + "everywhere); clear it to go back to the email.")
        }
        return parts.joined(separator: " ")
    }

    /// Active and health are separate facts, so both chips can show:
    /// the proxy's active credential with a stalled usage read is still
    /// the active one.
    @ViewBuilder private func statusChip(_ a: Account) -> some View {
        if a.active {
            Text("active").font(.caption2).foregroundStyle(.green)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.green.opacity(0.18)))
        }
        if a.disabled ?? false {
            Text("held").font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.gray.opacity(0.3)))
        } else if a.usageStatus != "ok" {
            Text(a.usageStatus == "relogin_required"
                 ? "re-login needed" : a.usageStatus.replacingOccurrences(of: "_", with: " "))
                .font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.orange.opacity(0.18)))
        }
    }
}

/// Add / re-login for an engine that signs in through a browser (the
/// proxy): one button, the shared in-app sign-in chooser does the rest.
private struct OAuthAddRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var flow = TokenFlow.shared
    let engineID: String
    let provider: Provider

    var body: some View {
        HStack(spacing: 8) {
            Button("Add account\u{2026}") {
                model.addOAuthAccount(engineID: engineID, provider: provider)
            }
            .disabled(model.addingFirstAccount || flow.running)
            if model.addingFirstAccount {
                ProgressView().controlSize(.small)
                Text("Sign in in the window that opened\u{2026}")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let msg = model.firstAccountMessage {
                Text(msg).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Opens Claude's login in a private in-app window \u{2014} "
                     + "your browser session is never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// cswap's add-account flow, phase by phase (the PTY-hosted
/// `claude auth login` + paste-back described on TokenFlow).
private struct CswapAddFlow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: TokenFlow

    var body: some View {
        if !flow.pasteCode && flow.running {
            Text("A sign-in for another engine is in progress.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            phases
        }
    }

    @ViewBuilder private var phases: some View {
        switch flow.phase {
        case .idle:
            HStack {
                Button("Add account\u{2026}") { flow.start(model: model) }
                Text("Opens Claude's login in a private in-app window \u{2014} "
                     + "your browser session is never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .launching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting claude setup-token\u{2026}")
                Button("Cancel") { flow.cancel() }
            }
        case .awaitingLogin:
            VStack(alignment: .leading, spacing: 8) {
                if let target = flow.reloginTarget {
                    Text("Re-login for \(target): sign in as that account.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("1. Sign in and approve in the login window "
                     + "(reopen: button below).\n2. Copy the code it "
                     + "shows, paste it here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Reopen login window") { flow.reopenAuth() }
                    TextField("Paste code", text: $flow.code)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Button("Submit") { flow.submitCode() }
                        .disabled(flow.code.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                    Button("Cancel") { flow.cancel() }
                }
            }
        case .waitingForToken, .registering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.phase == .registering
                     ? "Handing the token to the engine\u{2026}"
                     : "Waiting for the token\u{2026}")
                Button("Cancel") { flow.cancel() }
            }
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Account captured \u{2014} the engine holds its credential "
                     + "and your previous active account is restored.")
                Button("Add another") { flow.start(model: model) }
                Button("Done") { flow.phase = .idle }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                HStack {
                    Button("Try again") { flow.start(model: model) }
                    Button("Dismiss") { flow.phase = .idle }
                }
            }
        }
    }
}

/// One account's editable display name. Local draft, committed on Enter or
/// focus loss — never on every keystroke (each commit is a `cswap alias`
/// subprocess + snapshot refresh).
private struct RenameField: View {
    @ObservedObject var fleet: FleetState
    let account: Account
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .focused($focused)
            .onAppear { draft = account.alias ?? "" }
            .onChange(of: account.alias) { draft = account.alias ?? "" }
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (account.alias ?? "") else { return }
        fleet.rename(account.number, to: trimmed)
    }
}
