import SwiftUI
import WebKit
import SafariServices
import InfinitusCore

/// AWS sign-in from the phone (user 2026-09-03: "sessions often need
/// `aws login` for SSO — let me log in on mobile, the session
/// continues"). The Mac runs the CLI (AwsLoginRunner); this screen
/// drives it over the mirror channel: `POST /aws-login/start` starts
/// the login and, re-posted, reports its state — that is the poll.
///
/// Three flows, chosen Mac-side (`AwsLogin.flow`):
/// - relay: the CLI's own `aws login` with THIS web view as the browser.
///   The IdP finally redirects to `http://127.0.0.1:<port>/oauth/callback`
///   — a URL only the Mac can reach — so the web view cancels that
///   navigation and posts it verbatim; the Mac replays it against the
///   CLI's listener. Nothing to read or type.
/// - deviceCode: `aws sso login --use-device-code`: the page asks for a
///   short code; shown here, sign-in happens in any browser.
/// - remote: `aws login --remote`: the page shows a code after sign-in;
///   pasted back here. The fallback when an IdP refuses the web view.
@MainActor
final class AwsLoginFlow: ObservableObject {
    let item: AwsLogin.Item
    @Published var state: AwsLogin.State?
    @Published var error: String?
    @Published var busy = false
    /// Relay: the callback was posted; the CLI is finishing.
    @Published var relayed = false
    /// Relay: the page asked for a passkey the web view can't serve.
    @Published var passkeyWall = false
    private var poll: Task<Void, Never>?

    /// The Mac that owns the session — its own mirror when the session
    /// lives on another paired Mac (#144 phase 2).
    private let mirror: NetworkFleetMirror

    init(item: AwsLogin.Item, mirror: NetworkFleetMirror = .shared) {
        self.item = item
        self.mirror = mirror
        self.state = item.state
        if let s = item.state, s.phase != .done, s.phase != .failed { startPolling() }
    }

    deinit { poll?.cancel() }

    var profile: String { item.profile }
    var flow: AwsLogin.Flow { state?.flow ?? item.flow }
    var finished: Bool { state?.phase == .done || state?.phase == .failed }

    /// The code flow is the phone's default: the relay's WKWebView has
    /// no WebAuthn (that needs the web-browser entitlement), so a
    /// passkey MFA can never finish in it — the user hit exactly that
    /// (2026-09-03). Safari handles passkeys; the code is one paste.
    func start(remote: Bool = true) {
        busy = true
        error = nil
        relayed = false
        passkeyWall = false
        Task {
            // Explicit true/false: the Mac replaces a run of the other
            // kind on it; the flag-less poll below only reports.
            await post(AwsLogin.StartRequest(profile: profile, pid: item.pid, remote: remote, provider: item.provider))
            busy = false
            startPolling()
        }
    }

    /// Relay: the intercepted loopback callback (`127.0.0.1:<port>/oauth/callback`
    /// for aws, `localhost:8085/` for gcloud).
    func relay(_ url: URL) {
        relayed = true
        Task { await post(AwsLogin.CallbackRequest(profile: profile, url: url.absoluteString, provider: item.provider)) }
    }

    func send(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AwsLogin.isValidCode(code) else {
            error = "That doesn't look like an authorization code."
            return
        }
        busy = true
        Task {
            await post(AwsLogin.CodeRequest(profile: profile, code: code, provider: item.provider))
            busy = false
        }
    }

    private func post(_ request: AwsLogin.StartRequest) async {
        do { apply(try await mirror.awsLoginStart(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }
    private func post(_ request: AwsLogin.CallbackRequest) async {
        do { apply(try await mirror.awsLoginCallback(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }
    private func post(_ request: AwsLogin.CodeRequest) async {
        do { apply(try await mirror.awsLoginCode(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }

    private func apply(_ reply: AwsLogin.Reply) {
        if let s = reply.state { state = s }
        if !reply.ok { error = reply.error ?? "The Mac refused." }
        if finished { poll?.cancel(); poll = nil }
    }

    /// Every 2 s while a login is in flight: `start` is idempotent per
    /// profile and answers with the current state.
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.finished else { return }
                if let reply = try? await mirror.awsLoginStart(
                    AwsLogin.StartRequest(profile: self.profile, pid: self.item.pid, provider: self.item.provider)) {
                    self.apply(reply)
                }
            }
        }
    }
}

struct AwsLoginScreen: View {
    @StateObject private var flow: AwsLoginFlow
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var showSafari = false
    /// The last value copied — its row shows a check until another is.
    @State private var copied: String?

    init(item: AwsLogin.Item, mirror: NetworkFleetMirror = .shared) {
        _flow = StateObject(wrappedValue: AwsLoginFlow(item: item, mirror: mirror))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("\(provider.loginLabel) · \(flow.profile)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(flow.finished ? "Done" : "Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        let state = flow.state
        if let state, state.phase == .done {
            outcome(icon: "checkmark.circle.fill", tint: .green,
                    title: "Signed in",
                    text: state.message ?? "The session was told to retry and continue.")
        } else if let state, state.phase == .failed {
            outcome(icon: "xmark.octagon.fill", tint: .red,
                    title: "Login failed", text: state.message ?? "The CLI stopped.") {
                Button("Try again") { flow.start() }.buttonStyle(.borderedProminent)
                if flow.flow == .relay {
                    Button("Use the code flow instead") { flow.start(remote: true) }
                }
            }
        } else if state == nil || state?.url == nil {
            // Not started, or the CLI hasn't printed its URL yet.
            VStack(spacing: 16) {
                if let label = flow.item.sessionLabel {
                    Text("Session **\(label)** is stuck on expired \(provider == .aws ? "AWS" : "gcloud") credentials for **\(flow.item.subjectLabel)**.")
                        .multilineTextAlignment(.center)
                } else {
                    Text("**\(flow.item.subjectLabel.prefix(1).uppercased() + flow.item.subjectLabel.dropFirst())** needs a fresh \(provider.loginLabel).")
                }
                if provider == .aws { accountRows }
                if state != nil || flow.busy {
                    ProgressView("Starting `\(provider == .aws ? "aws login" : "gcloud auth login")` on the Mac…")
                } else {
                    Button("Sign in from this phone") { flow.start() }
                        .buttonStyle(.borderedProminent)
                    Text(flowBlurb)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if flow.item.flow == .relay {
                        Button("Sign in here instead (no code, but no passkeys)") {
                            flow.start(remote: false)
                        }
                        .font(.footnote)
                    }
                }
                errorLine
            }
            .padding()
        } else if let state, let url = URL(string: state.url ?? "") {
            switch state.flow {
            case .relay, .local:
                relayView(state: state, url: url)
            case .deviceCode:
                deviceCodeView(state: state, url: url)
            case .remote:
                remoteView(state: state, url: url)
            }
        }
    }

    private var provider: AwsLogin.Provider { flow.item.providerOrAws }

    private var flowBlurb: String {
        switch flow.item.flow {
        case .deviceCode: return "You'll get a short code to enter on the AWS page."
        case .relay, .local, .remote:
            return provider == .aws
                ? "The AWS page opens in Safari (passkeys work there); it ends with a code to paste back here."
                : "Google's sign-in page opens in Safari; it ends with a code to paste back here."
        }
    }

    /// What the AWS page asks for and nobody remembers across accounts
    /// (user 2026-09-05): the account id and IAM user name from the
    /// profile's config, one tap to copy each. The relay web view also
    /// fills them in; Safari flows have only these.
    @ViewBuilder private var accountRows: some View {
        if let account = flow.item.account {
            VStack(spacing: 6) {
                copyRow(label: "Account", value: account.accountId)
                if let user = account.userName { copyRow(label: "User", value: user) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func copyRow(label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = value
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Text(value).font(.system(.footnote, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied == value ? .green : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(label.lowercased()) \(value)")
    }

    @ViewBuilder private var errorLine: some View {
        if let error = flow.error {
            Text(error).font(.footnote).foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func outcome(icon: String, tint: Color, title: String, text: String,
                         @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.largeTitle.weight(.regular)).imageScale(.large).foregroundStyle(tint)
            Text(title).font(.title2.bold())
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
            errorLine
        }
        .padding()
    }

    // MARK: relay — the web view is the browser

    private func relayView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 0) {
            if flow.relayed {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Signing in… the Mac is finishing the login.")
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.thinMaterial)
            } else if flow.passkeyWall {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
                    Text("This sign-in needs a passkey, which only Safari can do here.")
                        .font(.footnote)
                    Spacer(minLength: 8)
                    Button("Use a code") { flow.start(remote: true) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.15))
            } else {
                HStack(spacing: 8) {
                    Text("Sign in below; the final redirect goes to the Mac by itself. "
                         + "Passkey or trouble? Switch to Safari and a code.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Use a code") { flow.start(remote: true) }
                        .font(.footnote)
                }
                .padding(10)
                .background(.thinMaterial)
            }
            accountRows.padding(.horizontal, 10).padding(.vertical, 6)
            errorLine.padding(.horizontal)
            RelayWebView(url: url, callbackPort: state.callbackPort,
                         fillScript: AwsLogin.fillScript(account: flow.item.account),
                         onCallback: { flow.relay($0) },
                         onPasskeyWall: { flow.passkeyWall = true })
            .opacity(flow.relayed ? 0.35 : 1)
        }
    }

    // MARK: device code

    private func deviceCodeView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 18) {
            accountRows
            Text("Enter this code on the sign-in page:")
            Text(state.userCode ?? "…")
                .font(.system(.largeTitle, design: .monospaced).bold())
                .textSelection(.enabled)
            HStack {
                Button {
                    UIPasteboard.general.string = state.userCode
                } label: { Label("Copy code", systemImage: "doc.on.doc") }
                .disabled(state.userCode == nil)
                Button { showSafari = true } label: {
                    Label("Open sign-in page", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
            ProgressView("Waiting for approval…")
                .font(.footnote).foregroundStyle(.secondary)
            errorLine
        }
        .padding()
        .sheet(isPresented: $showSafari) { SafariSheet(url: url) }
    }

    // MARK: remote — paste the code back

    private func remoteView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 18) {
            Text("Sign in on the AWS page (it opens in Safari, so passkeys work); it ends with an authorization code. Paste it here.")
                .multilineTextAlignment(.center)
            accountRows
            Button { showSafari = true } label: {
                Label("Open sign-in page", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            // The real code is ~1.8k chars of base64: a growing multi-line
            // field so the paste is visible, plus a one-tap paste.
            TextField("Authorization code", text: $code, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button {
                    if let pasted = UIPasteboard.general.string { code = pasted }
                } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.bordered)
                Button("Send code") { flow.send(code: code) }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.busy)
            }
            if state.phase == .waitingForBrowser {
                ProgressView("Finishing…").font(.footnote)
            }
            errorLine
        }
        .padding()
        .sheet(isPresented: $showSafari) { SafariSheet(url: url) }
    }
}

/// The relay flow's browser. `decidePolicyFor` sees every navigation:
/// the one to the CLI's loopback listener (`http://127.0.0.1:<port>/oauth/callback`
/// for aws, `http://localhost:8085/` for gcloud) is
/// cancelled (the phone can't reach it anyway) and handed back; all
/// else loads. A Safari user agent because some IdPs refuse embedded
/// views by their default UA ("disallowed_useragent").
private struct RelayWebView: UIViewRepresentable {
    let url: URL
    let callbackPort: Int?
    /// `AwsLogin.fillScript`: account id + user name into the page's
    /// inputs, at document end and again as the single-page flow moves.
    let fillScript: String?
    let onCallback: (URL) -> Void
    /// The page reports a passkey step the web view cannot serve.
    let onPasskeyWall: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // a fresh jar per login
        if let fillScript {
            config.userContentController.addUserScript(
                WKUserScript(source: fillScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RelayWebView
        private var handed = false
        init(_ parent: RelayWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, isCallback(url) {
                decisionHandler(.cancel)
                guard !handed else { return }
                handed = true
                parent.onCallback(url)
                return
            }
            decisionHandler(.allow)
        }

        /// Passkey walls read like "canceled the passkey authentication
        /// process" / "Additional verification required" — the WebAuthn
        /// call fails at once without the browser entitlement.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let text = (result as? String)?.lowercased() else { return }
                if text.contains("canceled the passkey") || text.contains("cancelled the passkey")
                    || text.contains("passkey authentication process")
                    || text.contains("additional verification required") {
                    self?.parent.onPasskeyWall()
                }
            }
        }

        private func isCallback(_ url: URL) -> Bool {
            guard url.host == "127.0.0.1" || url.host == "localhost" else { return false }
            if let port = parent.callbackPort { return url.port == port }
            return url.path == "/oauth/callback"
        }
    }
}

private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
