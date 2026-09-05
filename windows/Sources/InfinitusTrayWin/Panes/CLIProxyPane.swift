import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Pane C — CLIProxyAPI engine: DPAPI-encrypted management key, base URL, probe status, routing settings.
public final class CLIProxyPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "cliproxy",
        title: "CLIProxyAPI",
        glyph: "\u{E839}",
        tintRGB: (149, 165, 166),
        keywords: ["proxy", "cliproxy", "router", "management", "key", "engine", "provider", "claude"],
        section: .engines,
        badge: {
            PaneDescriptor.ProviderBadge(live: CLIProxyFleet.isAvailable())
        }
    )

    private var ctx: PaneContext?
    private var engineOnCheckboxHwnd: HWND?
    private var baseURLHwnd: HWND?
    private var keyHwnd: HWND?
    private var testBtnHwnd: HWND?
    private var saveBtnHwnd: HWND?
    private var forgetKeyBtnHwnd: HWND?
    private var statusLabelHwnd: HWND?

    // Routing
    private var strategyComboHwnd: HWND?
    private var affinityCheckboxHwnd: HWND?
    private var routingNotesLabelHwnd: HWND?

    private enum Cmd {
        static let engineOn: Int32 = 1
        static let test: Int32 = 2
        static let save: Int32 = 3
        static let forgetKey: Int32 = 4
        static let strategy: Int32 = 5
        static let affinity: Int32 = 6
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        engineOnCheckboxHwnd = PaneControls.checkbox("Engine on (rotates behind its own endpoint)", in: ctx, id: base + Cmd.engineOn, x: 0, y: 0, w: 0, h: 0)
        baseURLHwnd = PaneControls.edit(in: ctx, id: base + 10, x: 0, y: 0, w: 0, h: 0)
        keyHwnd = PaneControls.edit(in: ctx, id: base + 11, x: 0, y: 0, w: 0, h: 0, password: true)

        testBtnHwnd = PaneControls.button("Test connection", in: ctx, id: base + Cmd.test, x: 0, y: 0, w: 0, h: 0)
        saveBtnHwnd = PaneControls.button("Save", in: ctx, id: base + Cmd.save, x: 0, y: 0, w: 0, h: 0, default_: true)
        forgetKeyBtnHwnd = PaneControls.button("Forget key", in: ctx, id: base + Cmd.forgetKey, x: 0, y: 0, w: 0, h: 0, destructive: true)
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        strategyComboHwnd = PaneControls.combo(CLIProxyEngine.routingStrategies, in: ctx, id: base + Cmd.strategy, x: 0, y: 0, w: 0, h: 0)
        affinityCheckboxHwnd = PaneControls.checkbox("Session affinity (a conversation stays on one credential)", in: ctx, id: base + Cmd.affinity, x: 0, y: 0, w: 0, h: 0)
        routingNotesLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let colW = m.labelColumn

        var y = pad

        // Engine on/off
        y = PaneControls.sectionHeader("Claude — CLIProxyAPI engine", in: ctx, y: y, width: width)
        if let h = engineOnCheckboxHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(4)
        y += PaneControls.helpText("Save the management key below first. Takes effect on next tray launch.", in: ctx, x: pad, y: y, width: width - pad * 2)
        y += m.px(14)

        // Management API
        y = PaneControls.sectionHeader("Management API", in: ctx, y: y, width: width)

        _ = PaneControls.label("Base URL:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = baseURLHwnd {
            MoveWindow(h, pad + colW, y, width - pad * 2 - colW, fieldH, true)
        }
        y += fieldH + m.px(8)

        _ = PaneControls.label("Management key:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = keyHwnd {
            MoveWindow(h, pad + colW, y, width - pad * 2 - colW, fieldH, true)
        }
        y += fieldH + m.px(10)

        // Buttons
        if let t = testBtnHwnd, let s = saveBtnHwnd, let f = forgetKeyBtnHwnd {
            MoveWindow(t, pad, y, m.px(130), btnH, true)
            MoveWindow(s, pad + m.px(140), y, m.px(80), btnH, true)
            MoveWindow(f, pad + m.px(230), y, m.px(100), btnH, true)
        }
        y += btnH + m.px(8)

        if let h = statusLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(20), true)
        }
        y += m.px(22)

        y += PaneControls.helpText(
            "The key is the proxy's remote-management.secret-key. It is stored encrypted for your Windows account (DPAPI) at %APPDATA%\\Infinitus\\cliproxy.json and sent as a bearer header. Infinitus never reads the proxy's config or credential files.",
            in: ctx, x: pad, y: y, width: width - pad * 2
        )
        y += m.px(16)

        // Routing section
        y = PaneControls.sectionHeader("Routing", in: ctx, y: y, width: width)

        _ = PaneControls.label("Strategy:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = strategyComboHwnd {
            MoveWindow(h, pad + colW, y, m.px(200), m.px(120), true)
        }
        y += fieldH + m.px(8)

        if let h = affinityCheckboxHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(6)

        if let h = routingNotesLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(36), true)
        }
        y += m.px(42)

        // Accounts note
        y = PaneControls.sectionHeader("Accounts", in: ctx, y: y, width: width)
        y += PaneControls.helpText("The proxy's credentials are managed in the Accounts tab, next to the other engines'.", in: ctx, x: pad, y: y, width: width - pad * 2)
        y += m.px(16)

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 580 }
        return ctx.metrics.px(580)
    }

    public func activate() {
        loadConfig()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.engineOn:
            let on = PaneControls.checked(engineOnCheckboxHwnd)
            _ = try? WinSettingsStore.update { $0.engineCLIProxyEnabled = on }
            return true
        case Cmd.test:
            testConnection()
            return true
        case Cmd.save:
            saveConfig()
            return true
        case Cmd.forgetKey:
            forgetKey()
            return true
        case Cmd.strategy:
            if code == UINT(CBN_SELCHANGE) {
                commitStrategy()
            }
            return true
        case Cmd.affinity:
            if code == UINT(BN_CLICKED) {
                commitAffinity()
            }
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    private func loadConfig() {
        let settings = WinSettingsStore.load()
        let isConfigured = CLIProxyFleet.isAvailable()
        PaneControls.setChecked(engineOnCheckboxHwnd, settings.engineCLIProxyEnabled && isConfigured)
        PaneControls.enable(engineOnCheckboxHwnd, isConfigured)

        if let cfg = CLIProxyFleet.loadConfig() {
            PaneControls.setText(baseURLHwnd, cfg.baseURL.absoluteString)
            PaneControls.setText(keyHwnd, cfg.key)
        } else {
            PaneControls.setText(baseURLHwnd, CLIProxyEngine.defaultBaseURL.absoluteString)
            PaneControls.setText(keyHwnd, "")
        }
        updateRoutingNotes()
    }

    private func saveConfig() {
        let urlText = PaneControls.text(baseURLHwnd).trimmingCharacters(in: .whitespaces)
        let keyText = PaneControls.text(keyHwnd).trimmingCharacters(in: .whitespaces)

        guard let _ = URL(string: urlText.isEmpty ? CLIProxyEngine.defaultBaseURL.absoluteString : urlText) else {
            PaneControls.setText(statusLabelHwnd, "Invalid URL")
            return
        }
        guard let encrypted = WinSecret.protect(keyText) else {
            PaneControls.setText(statusLabelHwnd, "Failed to encrypt key with DPAPI")
            return
        }

        let cfg = CLIProxyFleet.StoredConfig(baseURL: urlText, encryptedKey: encrypted)
        do {
            let data = try JSONEncoder().encode(cfg)
            let fileURL = CLIProxyFleet.configURL
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try WinSecret.restrictToUser(path: fileURL)
            PaneControls.setText(statusLabelHwnd, "Key saved encrypted (DPAPI) with user-only DACL.")
            PaneControls.enable(engineOnCheckboxHwnd, true)
            CLIProxyFleet.invalidate()
        } catch {
            PaneControls.setText(statusLabelHwnd, "Save error: \(error.localizedDescription)")
        }
    }

    private func forgetKey() {
        let fileURL = CLIProxyFleet.configURL
        try? FileManager.default.removeItem(at: fileURL)
        PaneControls.setText(keyHwnd, "")
        PaneControls.setText(statusLabelHwnd, "Management key forgotten.")
        PaneControls.setChecked(engineOnCheckboxHwnd, false)
        PaneControls.enable(engineOnCheckboxHwnd, false)
        _ = try? WinSettingsStore.update { $0.engineCLIProxyEnabled = false }
        CLIProxyFleet.invalidate()
    }

    private func testConnection() {
        let urlText = PaneControls.text(baseURLHwnd).trimmingCharacters(in: .whitespaces)
        let keyText = PaneControls.text(keyHwnd).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText.isEmpty ? CLIProxyEngine.defaultBaseURL.absoluteString : urlText) else {
            PaneControls.setText(statusLabelHwnd, "Invalid URL")
            return
        }
        PaneControls.setText(statusLabelHwnd, "Testing proxy connection…")

        ctx?.async({
            let engine = CLIProxyEngine(baseURL: url, managementKey: keyText)
            let sem = DispatchSemaphore(value: 0)
            var msg = ""
            Task {
                do {
                    let probe = try await engine.probe()
                    msg = "Reachable — \(probe.credentialFiles) credential files, routing \(probe.strategy ?? "unknown")"
                } catch {
                    msg = (error as? EngineError)?.errorDescription ?? error.localizedDescription
                }
                sem.signal()
            }
            sem.wait()
            return msg
        }, then: { [weak self] report in
            PaneControls.setText(self?.statusLabelHwnd, report)
        })
    }

    private func commitStrategy() {
        let strat = PaneControls.comboSelection(strategyComboHwnd)
        guard let cfg = CLIProxyFleet.loadConfig() else { return }
        ctx?.async({
            let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
            let sem = DispatchSemaphore(value: 0)
            Task {
                try? await engine.setRoutingStrategy(strat)
                sem.signal()
            }
            sem.wait()
            return strat
        }, then: { [weak self] _ in
            self?.updateRoutingNotes()
        })
    }

    private func commitAffinity() {
        let on = PaneControls.checked(affinityCheckboxHwnd)
        guard let cfg = CLIProxyFleet.loadConfig() else { return }
        ctx?.async({
            let engine = CLIProxyEngine(baseURL: cfg.baseURL, managementKey: cfg.key)
            let sem = DispatchSemaphore(value: 0)
            Task {
                try? await engine.setSessionAffinity(on)
                sem.signal()
            }
            sem.wait()
            return on
        }, then: { [weak self] _ in
            self?.updateRoutingNotes()
        })
    }

    private func updateRoutingNotes() {
        let strat = PaneControls.comboSelection(strategyComboHwnd)
        let affinity = PaneControls.checked(affinityCheckboxHwnd)
        let note = ProxyRoutingNotes.explainer(strategy: strat.isEmpty ? nil : strat)
        let warn = ProxyRoutingNotes.affinityWarning(strategy: strat.isEmpty ? nil : strat, affinity: affinity)
        let full = warn != nil ? "\(note) \(warn!)" : note
        PaneControls.setText(routingNotesLabelHwnd, full)
    }
}
