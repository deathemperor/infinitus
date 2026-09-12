import SwiftUI
import InfinitusCore

/// One supervised daemon's state, as the swapd pane shows it.
struct EngineStateText: View {
    let state: EngineSupervisor.State
    var body: some View {
        Group {
            switch state {
            case .running: Text("Running").foregroundStyle(.green)
            case .stopped: Text("Stopped").foregroundStyle(.secondary)
            case .refused: Text("Held Elsewhere").foregroundStyle(.orange)
            case .backingOff(let s): Text("Retrying in \(Int(s))s")
            case .schemaMismatch: Text("Update the App")
            }
        }.font(.caption)
    }
}

extension EngineSupervisor.State {
    /// Sidebar live-dot: only a genuinely running engine counts.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// CLIProxyAPI provider pane (#8): the second engine. Talks only to the
/// proxy's Management API with a keychain-held key; never its files.
struct CLIProxyEnginePane: View {
    @ObservedObject var model: AppModel
    @State private var baseURL = ""
    @State private var key = ""
    @State private var probe: String?
    @State private var probing = false
    @State private var confirmForgetKey = false

    var body: some View {
        Form {
            Section("Claude — CLIProxyAPI engine") {
                Toggle("Engine on (rotates behind its own endpoint)", isOn: $model.cliproxyEnabled)
                    .disabled(!model.cliproxyKeyPresent && !model.cliproxyEnabled)
                if !model.cliproxyKeyPresent && !model.cliproxyEnabled {
                    Text("Save the management key below first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                EngineToggleNotes(model: model)
            }
            Section {
                TextField("Base URL", text: $baseURL, prompt: Text(CLIProxyEngine.defaultBaseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                SecureField("Management key", text: $key,
                            prompt: Text(model.cliproxyKeyPresent ? "•••••••• (stored in keychain)" : "remote-management.secret-key"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(probing ? "Testing\u{2026}" : "Test Connection") { test() }
                        .disabled(probing)
                    Button("Save & Restart") {
                        model.saveCLIProxy(baseURL: baseURL.isEmpty ? model.cliproxyBaseURL : baseURL,
                                           key: key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.cliproxyKeyPresent {
                        Button("Forget Key\u{2026}", role: .destructive) { confirmForgetKey = true }
                    }
                }
                if let probe {
                    Text(probe).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let err = model.engineErrors[CLIProxyEngine.engineID] {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if let caveat = model.fleetCaveats[CLIProxyEngine.engineID] {
                    Text(caveat).font(.caption).foregroundStyle(.orange)
                }
                if let proxy = model.cliProxy {
                    Text(DetectionLines.proxyLine(proxy, live: model.cliProxyLive))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } header: {
                Text("Management API")
            } footer: {
                Text("The key is the proxy's own management secret. It is kept in the "
                     + "keychain and sent as a bearer header; Infinitus never reads the "
                     + "proxy's config or credential files.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.cliproxyEnabled {
                Section {
                    Picker("Strategy", selection: Binding(
                        get: { model.proxyRoutingStrategy ?? "fill-first" },
                        set: { model.setProxyRoutingStrategy($0) })) {
                        ForEach(CLIProxyEngine.routingStrategies, id: \.self) { Text($0) }
                    }
                    .disabled(model.proxyRoutingStrategy == nil)
                    if let affinity = model.proxySessionAffinity {
                        Toggle("Session affinity (a conversation stays on one credential)",
                               isOn: Binding(get: { affinity },
                                             set: { model.setProxySessionAffinity($0) }))
                    }
                    RoutingNotes(strategy: model.proxyRoutingStrategy,
                                 affinity: model.proxySessionAffinity)
                } header: {
                    Text("Routing")
                } footer: {
                    Text("The proxy's credentials are managed in the Accounts tab, next to "
                         + "the other engines'.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.cliproxyBaseURL }
        .confirmationDialog("Forget the management key?", isPresented: $confirmForgetKey) {
            Button("Forget", role: .destructive) { model.saveCLIProxy(baseURL: model.cliproxyBaseURL, key: "") }
            Button("Keep Key", role: .cancel) { }
        } message: {
            Text("The key leaves the keychain and Infinitus restarts. This engine can't "
                 + "reach the proxy until you save a key again.")
        }
    }

    private func test() {
        let urlString = baseURL.isEmpty ? model.cliproxyBaseURL : baseURL
        guard let url = URL(string: urlString) else {
            probe = "That isn't a valid address \u{2014} it should look like \(CLIProxyEngine.defaultBaseURL.absoluteString)."
            return
        }
        let k = key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key
        guard !k.isEmpty else { probe = "Enter the management key first, then test."; return }
        probing = true
        Task {
            let engine = CLIProxyEngine(baseURL: url, managementKey: k)
            do {
                let p = try await engine.probe()
                probe = "reachable — \(p.credentialFiles) credential file\(p.credentialFiles == 1 ? "" : "s")"
                    + (p.strategy.map { ", routing \($0)" } ?? "")
            } catch {
                probe = EngineFailure.sentence(error)
            }
            probing = false
        }
    }
}

/// 9Router pane (third engine): the dashboard API on loopback with the
/// dashboard password in the keychain; never `~/.9router`.
struct NineRouterEnginePane: View {
    @ObservedObject var model: AppModel
    @State private var baseURL = ""
    @State private var password = ""
    @State private var probe: String?
    @State private var probing = false
    @State private var confirmForgetPassword = false

    var body: some View {
        Form {
            Section {
                Toggle("Engine on (rotates behind its own endpoint)", isOn: $model.nineRouterEnabled)
                EngineToggleNotes(model: model)
            } header: {
                Text("Claude \u{2014} 9Router engine")
            } footer: {
                Text("9Router rotates its connections per request in priority order and "
                     + "falls back on quota errors. Infinitus reads the roster and quotas, "
                     + "and sets priority / hold; the rotation policy stays 9Router's.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                TextField("Base URL", text: $baseURL, prompt: Text(NineRouterEngine.defaultBaseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                SecureField("Dashboard password", text: $password,
                            prompt: Text(model.nineRouterPasswordPresent ? "•••••••• (stored in keychain)" : "the dashboard login password"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(probing ? "Testing\u{2026}" : "Test Connection") { test() }
                        .disabled(probing)
                    Button("Save & Restart") {
                        model.saveNineRouter(
                            baseURL: baseURL.isEmpty ? model.nineRouterBaseURL : baseURL,
                            password: password.isEmpty
                                ? (Keychain.read(account: model.nineRouterBaseURL, service: Keychain.nineRouterService) ?? "")
                                : password)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.nineRouterPasswordPresent {
                        Button("Forget Password\u{2026}", role: .destructive) { confirmForgetPassword = true }
                    }
                }
                if let probe {
                    Text(probe).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let err = model.engineErrors[NineRouterEngine.engineID] {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Dashboard API")
            } footer: {
                Text("The password is the one the 9Router dashboard asks for. It is kept in "
                     + "the keychain and exchanged for a session cookie on demand; leave it "
                     + "empty if 9Router's require-login is off. Infinitus never reads "
                     + "9Router's database or config.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.nineRouterEnabled {
                Section {
                    Button("Open 9Router Dashboard") {
                        if let url = URL(string: (baseURL.isEmpty ? model.nineRouterBaseURL : baseURL) + "/dashboard") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("9Router's connections are managed in the Accounts tab, next to "
                         + "the other engines'. Adding one is done in the 9Router dashboard "
                         + "under Providers \u{2192} Connect Claude Code.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.nineRouterBaseURL }
        .confirmationDialog("Forget the dashboard password?", isPresented: $confirmForgetPassword) {
            Button("Forget", role: .destructive) { model.saveNineRouter(baseURL: model.nineRouterBaseURL, password: "") }
            Button("Keep Password", role: .cancel) { }
        } message: {
            Text("The password leaves the keychain and Infinitus restarts. If the dashboard "
                 + "requires a login, this engine can't reach it until you save the "
                 + "password again.")
        }
    }

    private func test() {
        let urlString = baseURL.isEmpty ? model.nineRouterBaseURL : baseURL
        guard let url = URL(string: urlString) else {
            probe = "That isn't a valid address \u{2014} it should look like \(NineRouterEngine.defaultBaseURL.absoluteString)."
            return
        }
        let pw = password.isEmpty
            ? (Keychain.read(account: model.nineRouterBaseURL, service: Keychain.nineRouterService) ?? "")
            : password
        probing = true
        Task {
            let engine = NineRouterEngine(baseURL: url, password: pw)
            do {
                let p = try await engine.probe()
                probe = "reachable — \(p.connections) connection\(p.connections == 1 ? "" : "s"), "
                    + "\(p.claudeConnections) Claude"
            } catch {
                probe = EngineFailure.sentence(error)
            }
            probing = false
        }
    }
}

/// Under the routing picker: what each proxy mode does to prompt caching
/// and to the Accounts tab's Switch (config_basic.go / selector.go).
struct RoutingNotes: View {
    let strategy: String?
    /// nil = the proxy predates the session-affinity route (CLIProxyAPI
    /// PR #5447), so the knob is YAML-only and the note says where.
    var affinity: Bool? = nil

    var body: some View {
        Text(explainer).font(.caption).foregroundStyle(.secondary)
        if strategy != nil, strategy != "fill-first" {
            if affinity == nil {
                Text("Turn on session-affinity in the proxy's config (this proxy has no "
                     + "management route for it yet) so a conversation stays on one "
                     + "credential: without it every request lands on a different account "
                     + "and the prompt cache misses. Under affinity, Switch only steers "
                     + "new sessions.")
                    .font(.caption).foregroundStyle(.orange)
            } else if affinity == false {
                Text("Turn on session affinity so a conversation stays on one credential: "
                     + "without it every request lands on a different account and the "
                     + "prompt cache misses.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Under affinity, Switch only steers new sessions; bound ones keep "
                     + "their credential until the TTL lapses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var explainer: String {
        switch strategy {
        case "round-robin":
            return "Each request goes to the next credential in turn."
        case "weighted-round-robin":
            return "Requests rotate in proportion to each credential's priority."
        case nil:
            return "Read from the proxy on the next refresh."
        default:
            return "Highest priority wins until it is rate-limited \u{2014} consume-first. "
                + "Switch in the Accounts tab raises a credential to the top."
        }
    }
}

/// Under each engine's on/off toggle: the layer-fight warning when both
/// engines are on, and the restart note.
struct EngineToggleNotes: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.swapdEnabled && model.cliproxyEnabled {
            Text("Both engines are on. swapd swaps the credential under "
                 + "Claude Code; the proxy rotates behind its own endpoint \u{2014} "
                 + "for the same accounts they fight. Run one per account set.")
                .font(.caption).foregroundStyle(.orange)
        }
        Text("Flipping an engine restarts the app.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// swapd pane (#8): the multi-provider credential-swap engine. A
/// top-level sidebar row, CodexBar-style (user 2026-08-30 — providers
/// sit IN the settings sidebar, not behind a nested split). The app
/// assumes the binary may be missing.
struct SwapdEnginePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reliability: ResumeReliabilityModel

    var body: some View {
        Form {
            Section {
                Toggle("Engine on (swaps the login under each provider's CLI)",
                       isOn: $model.swapdEnabled)
                    .disabled(model.swapd == nil && !model.swapdEnabled)
                if model.swapd == nil {
                    Text("Install a current Infinitus release to restore the bundled engine, then relaunch. For source builds:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(OnboardingBrief.swapdInstallCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                EngineToggleNotes(model: model)
            } header: {
                Text("swapd engine")
            } footer: {
                Text("One binary per machine, several providers: it keeps your logins, "
                     + "shows each one's usage windows and swaps the live login before a "
                     + "limit binds. Igniting an account here refreshes it at once, so "
                     + "the row shows the window that just started.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Demo fleet (fabricated accounts)", isOn: $model.mockMode)
            } header: {
                Text("Mock data")
            } footer: {
                Text("Made-up accounts standing in for the engine \u{2014} one burns "
                     + "ahead of pace, one is dead, rotate and reorder play along. Nothing "
                     + "reads or touches your real accounts; flipping this restarts the app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ResumeNudgesSection(service: model.resume)
            ResumeReliabilitySection(model: reliability)
            Section {
                LabeledContent("Binary") {
                    Text(model.swapd?.binaryPath ?? "not found")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(model.swapd == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                if let err = model.engineErrors[SwapdEngine.engineID] {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if model.swapdEnabled {
                    // #475: the engine's own `auto`, one daemon per enabled engine.
                    LabeledContent("Daemon") { EngineStateText(state: model.swapdState) }
                }
            } header: {
                Text("Binary")
            } footer: {
                Text("Looked for in /opt/homebrew/bin, /usr/local/bin, ~/.cargo/bin and "
                     + "~/.local/bin, then inside the app bundle; INFINITUS_SWAPD_CLI pins another path. "
                     + "Infinitus only ever runs `swapd \u{2026} --json` \u{2014} it never reads "
                     + "the engine's own files.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
