import SwiftUI
import InfinitusCore

/// Claude provider pane: auto-switch control + the spec-driven cswap
/// settings. A top-level sidebar row, CodexBar-style (user 2026-08-30 —
/// providers sit IN the settings sidebar, not behind a nested split).
struct ClaudeEnginePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var update: UpdateModel
    @ObservedObject var reliability: ResumeReliabilityModel

    var body: some View {
        Form {
            Section("Claude — cswap engine") {
                Toggle("Engine on (credential swap under Claude Code)", isOn: $model.cswapEnabled)
                EngineToggleNotes(model: model)
                LabeledContent("Auto-switch") {
                    HStack {
                        stateText
                        Button(toggleTitle) { model.toggleEngine() }
                            .disabled(!togglable)
                    }
                }
                Text("Rotates Claude accounts before limits stall a session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mock data") {
                Toggle("Demo fleet (fabricated accounts)", isOn: $model.mockMode)
                Text("Five made-up accounts standing in for the engine — "
                     + "bravo burns ahead of pace, charlie is dead, rotate "
                     + "and reorder play along. Nothing reads or touches "
                     + "your real accounts; flipping this restarts the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResumeNudgesSection(service: model.resume)
            ResumeReliabilitySection(model: reliability)
            // Engine updates live WITH the engine (user 2026-08-30:
            // "move all of updates of engine to its engine setting");
            // About keeps the app's own release channel.
            Section("Engine updates") {
                Toggle("Update automatically", isOn: Binding(
                    get: { update.autoCheck && update.autoInstall },
                    set: { update.autoCheck = $0; update.autoInstall = $0 }))
                    .help("Watch PyPI daily; when a newer claude-swap "
                          + "appears, run `cswap upgrade` unattended and "
                          + "restart the engine.")
                LabeledContent {
                    HStack {
                        if update.updateAvailable {
                            Button("Update Now") { Task { await update.upgrade() } }
                                .disabled(update.busy)
                                .buttonStyle(.borderedProminent)
                        }
                        Button(update.busy ? "Checking…" : "Check for Updates…") {
                            Task { await update.check() }
                        }
                        .disabled(update.busy)
                    }
                } label: {
                    Text("cswap engine \(update.current ?? "—")")
                    if let latest = update.latest {
                        Text("latest on PyPI: \(latest)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = update.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(update.updateAvailable ? Color.orange : .secondary)
                }
                Link(destination: releaseNotesURL) {
                    Label("Release notes", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://github.com/deathemperor/claude-swap")!) {
                    Label("Engine — claude-swap", systemImage: "gearshape.2")
                }
                if let output = update.upgradeOutput, !output.isEmpty {
                    DisclosureGroup("upgrade output") {
                        ScrollView {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
            SettingsFormBody(model: settings)
        }
        .formStyle(.grouped)
        .task { await settings.load() }
        .onAppear { if update.current == nil { Task { await update.check() } } }
    }

    private var releaseNotesURL: URL {
        // Release notes live on the upstream repo (the PyPI package's home).
        if update.updateAvailable, let latest = update.latest {
            return URL(string: "https://github.com/realiti4/claude-swap/releases/tag/v\(latest)")!
        }
        return URL(string: "https://github.com/realiti4/claude-swap/releases")!
    }

    private var stateText: some View {
        Group {
            switch model.cswapState {
            case .running: Text("running").foregroundStyle(.green)
            case .stopped: Text("stopped").foregroundStyle(.secondary)
            case .refused: Text("held elsewhere").foregroundStyle(.orange)
            case .backingOff(let s): Text("retrying in \(Int(s))s")
            case .schemaMismatch: Text("update the app")
            }
        }.font(.caption)
    }

    private var toggleTitle: String {
        if case .running = model.cswapState { return "Stop" }
        if case .backingOff = model.cswapState { return "Stop" }
        return "Start"
    }

    private var togglable: Bool {
        switch model.cswapState {
        case .running, .stopped, .backingOff: return true
        case .refused, .schemaMismatch: return false
        }
    }
}

extension CswapSupervisor.State {
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
            Section("Management API") {
                TextField("Base URL", text: $baseURL, prompt: Text(CLIProxyEngine.defaultBaseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                SecureField("Management key", text: $key,
                            prompt: Text(model.cliproxyKeyPresent ? "•••••••• (stored in keychain)" : "remote-management.secret-key"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(probing ? "Testing…" : "Test connection") { test() }
                        .disabled(probing)
                    Button("Save & restart") {
                        model.saveCLIProxy(baseURL: baseURL.isEmpty ? model.cliproxyBaseURL : baseURL,
                                           key: key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.cliproxyKeyPresent {
                        Button("Forget key") { model.saveCLIProxy(baseURL: model.cliproxyBaseURL, key: "") }
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
                Text("The key is the proxy's remote-management.secret-key; it is kept "
                     + "in the keychain and sent as a bearer header. Infinitus never "
                     + "reads the proxy's config or credential files.")
                    .font(.caption).foregroundStyle(.secondary)
                if let proxy = model.cliProxy {
                    Text(DetectionLines.proxyLine(proxy, live: model.cliProxyLive))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if model.cliproxyEnabled {
                Section("Routing") {
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
                }
                Section("Accounts") {
                    Text("The proxy's credentials are managed in the Accounts tab, "
                         + "next to cswap's.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.cliproxyBaseURL }
    }

    private func test() {
        let urlString = baseURL.isEmpty ? model.cliproxyBaseURL : baseURL
        guard let url = URL(string: urlString) else { probe = "bad URL"; return }
        let k = key.isEmpty ? (Keychain.read(account: model.cliproxyBaseURL) ?? "") : key
        guard !k.isEmpty else { probe = "enter the management key first"; return }
        probing = true
        Task {
            let engine = CLIProxyEngine(baseURL: url, managementKey: k)
            do {
                let p = try await engine.probe()
                probe = "reachable — \(p.credentialFiles) credential file\(p.credentialFiles == 1 ? "" : "s")"
                    + (p.strategy.map { ", routing \($0)" } ?? "")
            } catch {
                probe = (error as? EngineError)?.errorDescription ?? "\(error)"
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

    var body: some View {
        Form {
            Section("Claude — 9Router engine") {
                Toggle("Engine on (rotates behind its own endpoint)", isOn: $model.nineRouterEnabled)
                EngineToggleNotes(model: model)
                Text("9Router rotates its connections per request in priority order and "
                     + "falls back on quota errors. Infinitus reads the roster and quotas, "
                     + "and sets priority / hold; the rotation policy stays 9Router's.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dashboard API") {
                TextField("Base URL", text: $baseURL, prompt: Text(NineRouterEngine.defaultBaseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                SecureField("Dashboard password", text: $password,
                            prompt: Text(model.nineRouterPasswordPresent ? "•••••••• (stored in keychain)" : "the dashboard login password"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(probing ? "Testing…" : "Test connection") { test() }
                        .disabled(probing)
                    Button("Save & restart") {
                        model.saveNineRouter(
                            baseURL: baseURL.isEmpty ? model.nineRouterBaseURL : baseURL,
                            password: password.isEmpty
                                ? (Keychain.read(account: model.nineRouterBaseURL, service: Keychain.nineRouterService) ?? "")
                                : password)
                    }
                    .buttonStyle(.borderedProminent)
                    if model.nineRouterPasswordPresent {
                        Button("Forget password") { model.saveNineRouter(baseURL: model.nineRouterBaseURL, password: "") }
                    }
                }
                if let probe {
                    Text(probe).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let err = model.engineErrors[NineRouterEngine.engineID] {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Text("The password is the one the 9Router dashboard asks for; it is kept in "
                     + "the keychain and exchanged for a session cookie on demand. Leave it "
                     + "empty if 9Router's \"require login\" is off. Infinitus never reads "
                     + "9Router's database or config.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.nineRouterEnabled {
                Section("Accounts") {
                    Text("9Router's connections are managed in the Accounts tab, next to the "
                         + "other engines'. Adding one is done in the 9Router dashboard "
                         + "(Providers → Connect Claude Code).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open 9Router dashboard") {
                        if let url = URL(string: (baseURL.isEmpty ? model.nineRouterBaseURL : baseURL) + "/dashboard") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.nineRouterBaseURL }
    }

    private func test() {
        let urlString = baseURL.isEmpty ? model.nineRouterBaseURL : baseURL
        guard let url = URL(string: urlString) else { probe = "bad URL"; return }
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
                probe = (error as? EngineError)?.errorDescription ?? "\(error)"
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
        Text(ProxyRoutingNotes.explainer(strategy: strategy)).font(.caption).foregroundStyle(.secondary)
        if let warning = ProxyRoutingNotes.affinityWarning(strategy: strategy, affinity: affinity) {
            Text(warning)
                .font(.caption)
                .foregroundStyle(affinity == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
    }
}

/// Under each engine's on/off toggle: the layer-fight warning when both
/// engines are on, and the restart note.
struct EngineToggleNotes: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.cswapEnabled && model.cliproxyEnabled {
            Text("Both engines are on. cswap swaps the credential under "
                 + "Claude Code; the proxy rotates behind its own endpoint \u{2014} "
                 + "for the same accounts they fight. Run one per account set.")
                .font(.caption).foregroundStyle(.orange)
        }
        if model.routedVia9Router {
            Text(model.nineRouterEnabled
                 ? "Claude Code is routed via 9Router \u{2014} env.ANTHROPIC_BASE_URL "
                   + "in ~/.claude/settings.json points at it, and the 9Router fleet "
                   + "is the one the title, resume nudge and pushes follow."
                 : "Claude Code's env.ANTHROPIC_BASE_URL (~/.claude/settings.json) "
                   + "points at 9Router, but the 9Router engine is off \u{2014} Claude "
                   + "Code hits it unmanaged.")
                .font(.caption)
                .foregroundStyle(model.nineRouterEnabled ? Color.secondary : Color.orange)
        }
        Text("Flipping an engine restarts the app.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
