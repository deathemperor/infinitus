import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Pane D — 9Router engine: password in 9router.json with user-only DACL, base URL, test probe, dashboard link.
public final class NineRouterPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "9router",
        title: "9Router",
        glyph: "\u{E72D}",
        tintRGB: (149, 165, 166),
        keywords: ["9router", "router", "engine", "provider", "claude", "password"],
        section: .engines,
        badge: {
            let pass = (try? String(contentsOf: NineRouterFleet.configURL)) ?? ""
            return PaneDescriptor.ProviderBadge(live: !pass.isEmpty)
        }
    )

    private var ctx: PaneContext?
    private var engineOnCheckboxHwnd: HWND?
    private var bannerLabelHwnd: HWND?
    private var baseURLHwnd: HWND?
    private var passwordHwnd: HWND?
    private var testBtnHwnd: HWND?
    private var saveBtnHwnd: HWND?
    private var forgetBtnHwnd: HWND?
    private var statusLabelHwnd: HWND?
    private var openDashboardBtnHwnd: HWND?

    private enum Cmd {
        static let engineOn: Int32 = 1
        static let test: Int32 = 2
        static let save: Int32 = 3
        static let forget: Int32 = 4
        static let openDashboard: Int32 = 5
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        engineOnCheckboxHwnd = PaneControls.checkbox("Engine on (rotates behind its own endpoint)", in: ctx, id: base + Cmd.engineOn, x: 0, y: 0, w: 0, h: 0)
        bannerLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        baseURLHwnd = PaneControls.edit(in: ctx, id: base + 10, x: 0, y: 0, w: 0, h: 0)
        passwordHwnd = PaneControls.edit(in: ctx, id: base + 11, x: 0, y: 0, w: 0, h: 0, password: true)

        testBtnHwnd = PaneControls.button("Test connection", in: ctx, id: base + Cmd.test, x: 0, y: 0, w: 0, h: 0)
        saveBtnHwnd = PaneControls.button("Save", in: ctx, id: base + Cmd.save, x: 0, y: 0, w: 0, h: 0, default_: true)
        forgetBtnHwnd = PaneControls.button("Forget password", in: ctx, id: base + Cmd.forget, x: 0, y: 0, w: 0, h: 0, destructive: true)
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        openDashboardBtnHwnd = PaneControls.button("Open 9Router dashboard", in: ctx, id: base + Cmd.openDashboard, x: 0, y: 0, w: 0, h: 0)
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
        y = PaneControls.sectionHeader("Claude — 9Router engine", in: ctx, y: y, width: width)
        if let h = engineOnCheckboxHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(4)

        if let h = bannerLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(36), true)
        }
        y += m.px(40)

        // Dashboard API
        y = PaneControls.sectionHeader("Dashboard API", in: ctx, y: y, width: width)

        _ = PaneControls.label("Base URL:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = baseURLHwnd {
            MoveWindow(h, pad + colW, y, width - pad * 2 - colW, fieldH, true)
        }
        y += fieldH + m.px(8)

        _ = PaneControls.label("Dashboard password:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = passwordHwnd {
            MoveWindow(h, pad + colW, y, width - pad * 2 - colW, fieldH, true)
        }
        y += fieldH + m.px(10)

        // Buttons
        if let t = testBtnHwnd, let s = saveBtnHwnd, let f = forgetBtnHwnd {
            MoveWindow(t, pad, y, m.px(130), btnH, true)
            MoveWindow(s, pad + m.px(140), y, m.px(80), btnH, true)
            MoveWindow(f, pad + m.px(230), y, m.px(130), btnH, true)
        }
        y += btnH + m.px(8)

        if let h = statusLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(20), true)
        }
        y += m.px(22)

        y += PaneControls.helpText(
            "The password is the one the 9Router dashboard asks for. Leave it empty if 9Router's \"require login\" is off. It is stored on disk at %APPDATA%\\Infinitus\\9router.json, readable only by your Windows account. Infinitus never reads 9Router's database or config.",
            in: ctx, x: pad, y: y, width: width - pad * 2
        )
        y += m.px(16)

        // Accounts section
        y = PaneControls.sectionHeader("Accounts", in: ctx, y: y, width: width)
        y += PaneControls.helpText("9Router's connections are managed in the Accounts tab. Adding one is done in the 9Router dashboard (Providers → Connect Claude Code).", in: ctx, x: pad, y: y, width: width - pad * 2)
        y += m.px(8)

        if let h = openDashboardBtnHwnd {
            MoveWindow(h, pad, y, m.px(200), btnH, true)
        }
        y += btnH + pad

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 520 }
        return ctx.metrics.px(520)
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
            _ = try? WinSettingsStore.update { $0.engineNineRouterEnabled = on }
            updateBanner()
            return true
        case Cmd.test:
            testConnection()
            return true
        case Cmd.save:
            saveConfig()
            return true
        case Cmd.forget:
            forgetPassword()
            return true
        case Cmd.openDashboard:
            openDashboard()
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
        let (url, pass) = NineRouterFleet.loadConfig()
        PaneControls.setText(baseURLHwnd, url.absoluteString)
        PaneControls.setText(passwordHwnd, pass)

        let settings = WinSettingsStore.load()
        PaneControls.setChecked(engineOnCheckboxHwnd, settings.engineNineRouterEnabled)
        updateBanner()
    }

    private func updateBanner() {
        let routed = ClaudeCodeRouting.isRouted(ClaudeCodeRouting.anthropicBaseURL(), to: nil)
        let settings = WinSettingsStore.load()
        if routed && !settings.engineNineRouterEnabled {
            PaneControls.setText(
                bannerLabelHwnd,
                "Claude Code's env.ANTHROPIC_BASE_URL points at 9Router, but the 9Router engine is off — Claude Code hits it unmanaged."
            )
        } else if routed {
            PaneControls.setText(
                bannerLabelHwnd,
                "Claude Code is routed via 9Router — env.ANTHROPIC_BASE_URL in ~/.claude/settings.json points at it, and the 9Router fleet is the one the tray tooltip and the resume nudge follow."
            )
        } else {
            PaneControls.setText(
                bannerLabelHwnd,
                "9Router rotates its connections per request in priority order and falls back on quota errors. Infinitus reads the roster and quotas, and sets priority / hold; the rotation policy stays 9Router's."
            )
        }
    }

    private func saveConfig() {
        let urlText = PaneControls.text(baseURLHwnd).trimmingCharacters(in: .whitespaces)
        let passText = PaneControls.text(passwordHwnd).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText.isEmpty ? NineRouterEngine.defaultBaseURL.absoluteString : urlText) else {
            PaneControls.setText(statusLabelHwnd, "Invalid URL")
            return
        }

        let cfg = NineRouterFleet.StoredConfig(baseURL: url.absoluteString, password: passText)
        do {
            let data = try JSONEncoder().encode(cfg)
            let fileURL = NineRouterFleet.configURL
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try WinSecret.restrictToUser(path: fileURL)
            PaneControls.setText(statusLabelHwnd, "Config saved with user-only DACL applied.")
            NineRouterFleet.invalidate()
        } catch {
            PaneControls.setText(statusLabelHwnd, "Save error: \(error.localizedDescription)")
        }
    }

    private func forgetPassword() {
        let fileURL = NineRouterFleet.configURL
        try? FileManager.default.removeItem(at: fileURL)
        PaneControls.setText(passwordHwnd, "")
        PaneControls.setText(statusLabelHwnd, "Password forgotten.")
        NineRouterFleet.invalidate()
    }

    private func testConnection() {
        let urlText = PaneControls.text(baseURLHwnd).trimmingCharacters(in: .whitespaces)
        let passText = PaneControls.text(passwordHwnd).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText.isEmpty ? NineRouterEngine.defaultBaseURL.absoluteString : urlText) else {
            PaneControls.setText(statusLabelHwnd, "Invalid URL")
            return
        }
        PaneControls.setText(statusLabelHwnd, "Testing 9Router connection…")

        ctx?.async({
            let engine = NineRouterEngine(baseURL: url, password: passText)
            let sem = DispatchSemaphore(value: 0)
            var msg = ""
            Task {
                do {
                    let probe = try await engine.probe()
                    msg = "Reachable — \(probe.connections) connections (\(probe.claudeConnections) Claude)"
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

    private func openDashboard() {
        var urlText = PaneControls.text(baseURLHwnd).trimmingCharacters(in: .whitespaces)
        if urlText.isEmpty {
            urlText = NineRouterEngine.defaultBaseURL.absoluteString
        }
        if !urlText.hasSuffix("/dashboard") {
            urlText = urlText.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/dashboard"
        }
        let urlWide = Array(urlText.utf16) + [0]
        let openWide = Array("open".utf16) + [0]
        _ = urlWide.withUnsafeBufferPointer { urlBuf in
            openWide.withUnsafeBufferPointer { opBuf in
                ShellExecuteW(nil, opBuf.baseAddress, urlBuf.baseAddress, nil, nil, SW_SHOWNORMAL)
            }
        }
    }
}
