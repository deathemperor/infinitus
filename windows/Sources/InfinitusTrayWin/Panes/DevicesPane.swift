import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Devices settings pane.
/// Set-up walkthrough, companion serve toggle, pairing token reveal/copy/regenerate,
/// scannable QR code rendered via GDI, live routes, and SyncSnapshot file export/import.
public final class DevicesPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "devices",
        title: "Devices",
        glyph: "\u{E8EA}",
        tintRGB: (60, 190, 220),
        keywords: ["sync", "settings", "devices", "phone", "iphone", "lan", "companion", "tailscale", "pair", "qr", "export", "import"]
    )

    private var ctx: PaneContext?

    // Walkthrough section
    private var walkthroughHeaderHwnd: HWND?
    private var step1Hwnd: HWND?
    private var step1HelpHwnd: HWND?
    private var step2Hwnd: HWND?
    private var step2HelpHwnd: HWND?
    private var step3Hwnd: HWND?
    private var step3HelpHwnd: HWND?
    private var step4Hwnd: HWND?
    private var step4HelpHwnd: HWND?
    private var copyAgentBtnHwnd: HWND?
    private var copyAgentHelpHwnd: HWND?

    // Phone companion section
    private var companionHeaderHwnd: HWND?
    private var serveToggleHwnd: HWND?
    private var serveStatusLabelHwnd: HWND?
    private var portLabelHwnd: HWND?
    private var portEditHwnd: HWND?
    private var portWarnLabelHwnd: HWND?
    private var tokenLabelHwnd: HWND?
    private var tokenValueHwnd: HWND?
    private var tokenRevealBtnHwnd: HWND?
    private var tokenCopyBtnHwnd: HWND?
    private var tokenRegenBtnHwnd: HWND?
    private var companionNoticeHwnd: HWND?
    private var firewallLabelHwnd: HWND?
    private var firewallCopyBtnHwnd: HWND?

    // Pair a phone section
    private var pairHeaderHwnd: HWND?
    private var qrCanvasHwnd: HWND?
    private var route1TitleHwnd: HWND?
    private var route1EndpointHwnd: HWND?
    private var route1CopyBtnHwnd: HWND?
    private var route2TitleHwnd: HWND?
    private var route2EndpointHwnd: HWND?
    private var route2CopyBtnHwnd: HWND?
    private var copyPairLinkBtnHwnd: HWND?
    private var pairNoteHwnd: HWND?

    // Anywhere section
    private var anywhereHeaderHwnd: HWND?
    private var tailscaleStatusLabelHwnd: HWND?
    private var tailscaleBtnHwnd: HWND?
    private var anywhereNoticeHwnd: HWND?

    // Settings file section
    private var settingsFileHeaderHwnd: HWND?
    private var exportBtnHwnd: HWND?
    private var importBtnHwnd: HWND?
    private var settingsFileStatusHwnd: HWND?
    private var settingsFileNoticeHwnd: HWND?

    // State
    private var revealToken = false
    private var currentToken: String?
    private var cachedRoutes: [PairingChecklist.RouteItem] = []
    private var currentSteps: [PairingChecklist.Step] = []
    private var qrMatrix: QRCode.Matrix?
    private var lastServedTime: Date?
    private var daemonExternal = false
    private var timerID: UINT_PTR = 0
    private var calculatedHeight: Int32 = 1200

    private enum Cmd {
        static let copyAgent: Int32 = 10
        static let serveToggle: Int32 = 20
        static let portEdit: Int32 = 21
        static let tokenReveal: Int32 = 22
        static let tokenCopy: Int32 = 23
        static let tokenRegen: Int32 = 24
        static let copyFirewall: Int32 = 25
        static let copyRoute1: Int32 = 30
        static let copyRoute2: Int32 = 31
        static let copyPairLink: Int32 = 32
        static let getTailscale: Int32 = 35
        static let exportSettings: Int32 = 40
        static let importSettings: Int32 = 41
        static let qrCanvasID: Int32 = 50
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // 1. Walkthrough
        walkthroughHeaderHwnd = PaneControls.label("Set up your phone", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        step1Hwnd = PaneControls.label("[ ] 1. Serve the fleet to my phone", in: ctx, x: 0, y: 0, w: 0, h: 0)
        step1HelpHwnd = PaneControls.label(
            "The toggle below. This box answers with its session snapshot; nothing leaves the machine otherwise.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )
        step2Hwnd = PaneControls.label("[ ] 2. Put Infinitus on the phone", in: ctx, x: 0, y: 0, w: 0, h: 0)
        step2HelpHwnd = PaneControls.label(
            "The iOS companion lives in ios/ of the repo.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )
        step3Hwnd = PaneControls.label("[ ] 3. Pick how the phone reaches this PC", in: ctx, x: 0, y: 0, w: 0, h: 0)
        step3HelpHwnd = PaneControls.label(
            "Same Wi-Fi needs nothing. From anywhere: Tailscale on both devices.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )
        step4Hwnd = PaneControls.label("[ ] 4. Scan the QR from the phone", in: ctx, x: 0, y: 0, w: 0, h: 0)
        step4HelpHwnd = PaneControls.label(
            "On the phone: Settings → Mac connection → Scan QR.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        copyAgentBtnHwnd = PaneControls.button("Copy for an AI agent", in: ctx, id: base + Cmd.copyAgent, x: 0, y: 0, w: 0, h: 0)
        copyAgentHelpHwnd = PaneControls.label(
            "Token left out — Reveal it below to include it.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        // 2. Phone companion
        companionHeaderHwnd = PaneControls.label("Phone companion", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        serveToggleHwnd = PaneControls.checkbox("Serve the fleet to my phone", in: ctx, id: base + Cmd.serveToggle, x: 0, y: 0, w: 0, h: 0)
        serveStatusLabelHwnd = PaneControls.label("not running", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        portLabelHwnd = PaneControls.label("Port:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        let s = WinSettingsStore.load()
        portEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.portEdit, x: 0, y: 0, w: 0, h: 0)
        PaneControls.setText(portEditHwnd, String(s.mirrorPort))
        portWarnLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        tokenLabelHwnd = PaneControls.label("Pairing token:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        tokenValueHwnd = PaneControls.label("••••••••••••••••••••••••", in: ctx, x: 0, y: 0, w: 0, h: 0)
        tokenRevealBtnHwnd = PaneControls.button("Reveal", in: ctx, id: base + Cmd.tokenReveal, x: 0, y: 0, w: 0, h: 0)
        tokenCopyBtnHwnd = PaneControls.button("Copy", in: ctx, id: base + Cmd.tokenCopy, x: 0, y: 0, w: 0, h: 0)
        tokenRegenBtnHwnd = PaneControls.button("Regenerate", in: ctx, id: base + Cmd.tokenRegen, x: 0, y: 0, w: 0, h: 0)

        companionNoticeHwnd = PaneControls.label(
            "Requests without `Authorization: Bearer <token>` (or `?t=<token>`) get a 401. " +
            "The snapshot carries session names, folders and progress; never tokens or push secrets.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        firewallLabelHwnd = PaneControls.label(
            "Inbound TCP 47824 must be allowed on the Private profile:\n" +
            "netsh advfirewall firewall add rule name=\"Infinitus\" dir=in action=allow protocol=TCP localport=47824",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )
        firewallCopyBtnHwnd = PaneControls.button("Copy command", in: ctx, id: base + Cmd.copyFirewall, x: 0, y: 0, w: 0, h: 0)

        // 3. Pair a phone
        pairHeaderHwnd = PaneControls.label("Pair a phone", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)

        // Owner-draw STATIC for QR
        let staticClass = Array("STATIC".utf16) + [0]
        qrCanvasHwnd = staticClass.withUnsafeBufferPointer { sc in
            CreateWindowExW(
                0, sc.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | SS_OWNERDRAW),
                0, 0, 100, 100,
                ctx.host, HMENU(bitPattern: Int(base + Cmd.qrCanvasID)), ctx.instance, nil
            )
        }

        route1TitleHwnd = PaneControls.label("Wi-Fi (LAN)", in: ctx, x: 0, y: 0, w: 0, h: 0)
        route1EndpointHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        route1CopyBtnHwnd = PaneControls.button("Copy", in: ctx, id: base + Cmd.copyRoute1, x: 0, y: 0, w: 0, h: 0)

        route2TitleHwnd = PaneControls.label("Tailscale", in: ctx, x: 0, y: 0, w: 0, h: 0)
        route2EndpointHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        route2CopyBtnHwnd = PaneControls.button("Copy", in: ctx, id: base + Cmd.copyRoute2, x: 0, y: 0, w: 0, h: 0)

        copyPairLinkBtnHwnd = PaneControls.button("Copy pair link", in: ctx, id: base + Cmd.copyPairLink, x: 0, y: 0, w: 0, h: 0)
        pairNoteHwnd = PaneControls.label(
            "One scan pairs every route. The phone tries them in this order and keeps whichever answers.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        // 4. Anywhere
        anywhereHeaderHwnd = PaneControls.label("Anywhere", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        tailscaleStatusLabelHwnd = PaneControls.label("Tailscale: detecting…", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        tailscaleBtnHwnd = PaneControls.button("Get Tailscale…", in: ctx, id: base + Cmd.getTailscale, x: 0, y: 0, w: 0, h: 0)
        anywhereNoticeHwnd = PaneControls.label(
            "Free for personal use. Install it here and on the phone, sign both into the same tailnet, " +
            "and a Tailscale route appears above by itself.\n" +
            "Cloudflare tunnels are macOS-only in this build — use Tailscale, or your own reverse proxy to http://localhost:47824.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        // 5. Settings file
        settingsFileHeaderHwnd = PaneControls.label("Settings file", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        exportBtnHwnd = PaneControls.button("Export…", in: ctx, id: base + Cmd.exportSettings, x: 0, y: 0, w: 0, h: 0)
        importBtnHwnd = PaneControls.button("Import…", in: ctx, id: base + Cmd.importSettings, x: 0, y: 0, w: 0, h: 0)
        settingsFileStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        settingsFileNoticeHwnd = PaneControls.label(
            "Display prefs, custom themes and set cswap engine settings — the same file the Mac exports. " +
            "Never credentials or push secrets.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let innerW = max(100, width - pad * 2)

        var y = pad

        // Walkthrough
        if let h = walkthroughHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }

        func placeStep(titleHwnd: HWND?, helpHwnd: HWND?) {
            if let titleHwnd {
                MoveWindow(titleHwnd, pad, y, innerW, fieldH, true)
                y += fieldH + m.px(2)
            }
            if let helpHwnd {
                MoveWindow(helpHwnd, pad + m.px(20), y, innerW - m.px(20), m.px(18), true)
                y += m.px(24)
            }
        }

        placeStep(titleHwnd: step1Hwnd, helpHwnd: step1HelpHwnd)
        placeStep(titleHwnd: step2Hwnd, helpHwnd: step2HelpHwnd)
        placeStep(titleHwnd: step3Hwnd, helpHwnd: step3HelpHwnd)
        placeStep(titleHwnd: step4Hwnd, helpHwnd: step4HelpHwnd)

        let agentBtnW = m.px(150)
        if let h = copyAgentBtnHwnd {
            MoveWindow(h, pad, y, agentBtnW, btnH, true)
        }
        if let h = copyAgentHelpHwnd {
            MoveWindow(h, pad + agentBtnW + m.px(12), y + m.px(4), innerW - agentBtnW - m.px(12), fieldH, true)
        }
        y += btnH + m.px(20)

        // Companion
        if let h = companionHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }
        if let h = serveToggleHwnd {
            MoveWindow(h, pad, y, innerW, fieldH, true)
            y += fieldH + m.px(2)
        }
        if let h = serveStatusLabelHwnd {
            MoveWindow(h, pad + m.px(20), y, innerW - m.px(20), m.px(18), true)
            y += m.px(22)
        }

        let portLabelW = m.px(40)
        let portEditW = m.px(70)
        if let h = portLabelHwnd {
            MoveWindow(h, pad, y + m.px(2), portLabelW, fieldH, true)
        }
        if let h = portEditHwnd {
            MoveWindow(h, pad + portLabelW, y, portEditW, fieldH, true)
        }
        if let h = portWarnLabelHwnd {
            MoveWindow(h, pad + portLabelW + portEditW + m.px(10), y + m.px(2), innerW - portLabelW - portEditW - m.px(10), fieldH, true)
        }
        y += fieldH + m.px(12)

        let tokenLabelW = m.px(90)
        let tokenValueW = m.px(220)
        if let h = tokenLabelHwnd {
            MoveWindow(h, pad, y + m.px(2), tokenLabelW, fieldH, true)
        }
        if let h = tokenValueHwnd {
            MoveWindow(h, pad + tokenLabelW, y + m.px(2), tokenValueW, fieldH, true)
        }
        y += fieldH + m.px(6)

        let btnW = m.px(80)
        if let h = tokenRevealBtnHwnd { MoveWindow(h, pad, y, btnW, btnH, true) }
        if let h = tokenCopyBtnHwnd { MoveWindow(h, pad + btnW + m.px(8), y, btnW, btnH, true) }
        if let h = tokenRegenBtnHwnd { MoveWindow(h, pad + (btnW + m.px(8)) * 2, y, m.px(95), btnH, true) }
        y += btnH + m.px(10)

        if let h = companionNoticeHwnd {
            MoveWindow(h, pad, y, innerW, m.px(34), true)
            y += m.px(38)
        }
        if let h = firewallLabelHwnd {
            MoveWindow(h, pad, y, innerW, m.px(34), true)
            y += m.px(38)
        }
        if let h = firewallCopyBtnHwnd {
            MoveWindow(h, pad, y, m.px(120), btnH, true)
            y += btnH + m.px(20)
        }

        // Pair a phone
        if let h = pairHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }

        let qrSide = m.px(128)
        if let h = qrCanvasHwnd {
            MoveWindow(h, pad, y, qrSide, qrSide, true)
        }

        let routesX = pad + qrSide + m.px(16)
        let routesW = max(50, innerW - qrSide - m.px(16))
        var ry = y

        if let h = route1TitleHwnd {
            MoveWindow(h, routesX, ry, routesW, fieldH, true)
            ry += fieldH
        }
        let copyBtnW = m.px(65)
        if let h = route1EndpointHwnd {
            MoveWindow(h, routesX, ry + m.px(2), max(50, routesW - copyBtnW - m.px(8)), fieldH, true)
        }
        if let h = route1CopyBtnHwnd {
            MoveWindow(h, routesX + routesW - copyBtnW, ry, copyBtnW, btnH, true)
        }
        ry += btnH + m.px(10)

        if let h = route2TitleHwnd {
            MoveWindow(h, routesX, ry, routesW, fieldH, true)
            ry += fieldH
        }
        if let h = route2EndpointHwnd {
            MoveWindow(h, routesX, ry + m.px(2), max(50, routesW - copyBtnW - m.px(8)), fieldH, true)
        }
        if let h = route2CopyBtnHwnd {
            MoveWindow(h, routesX + routesW - copyBtnW, ry, copyBtnW, btnH, true)
        }
        ry += btnH + m.px(10)

        if let h = copyPairLinkBtnHwnd {
            MoveWindow(h, routesX, ry, m.px(120), btnH, true)
            ry += btnH + m.px(8)
        }

        y = max(y + qrSide, ry) + m.px(10)

        if let h = pairNoteHwnd {
            MoveWindow(h, pad, y, innerW, m.px(30), true)
            y += m.px(34)
        }

        y += m.px(14)

        // Anywhere
        if let h = anywhereHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }
        if let h = tailscaleStatusLabelHwnd {
            MoveWindow(h, pad, y + m.px(4), m.px(240), fieldH, true)
        }
        if let h = tailscaleBtnHwnd {
            MoveWindow(h, pad + m.px(250), y, m.px(120), btnH, true)
        }
        y += btnH + m.px(10)

        if let h = anywhereNoticeHwnd {
            MoveWindow(h, pad, y, innerW, m.px(48), true)
            y += m.px(54)
        }

        y += m.px(14)

        // Settings file
        if let h = settingsFileHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }
        let fileBtnW = m.px(90)
        if let h = exportBtnHwnd { MoveWindow(h, pad, y, fileBtnW, btnH, true) }
        if let h = importBtnHwnd { MoveWindow(h, pad + fileBtnW + m.px(10), y, fileBtnW, btnH, true) }
        if let h = settingsFileStatusHwnd {
            MoveWindow(h, pad + (fileBtnW + m.px(10)) * 2, y + m.px(4), innerW - (fileBtnW + m.px(10)) * 2, fieldH, true)
        }
        y += btnH + m.px(10)

        if let h = settingsFileNoticeHwnd {
            MoveWindow(h, pad, y, innerW, m.px(34), true)
            y += m.px(40)
        }

        calculatedHeight = y + pad
        PaneHost.setContentHeight(ctx.host, calculatedHeight)
    }

    public func activate() {
        refreshState()
        startTimer()
    }

    public func deactivate() {
        stopTimer()
        revealToken = false
        PaneControls.setText(tokenRevealBtnHwnd, "Reveal")
    }

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase

        switch id - base {
        case Cmd.copyAgent:
            let brief = PairingChecklist.agentBrief(
                steps: currentSteps,
                serving: PaneControls.checked(serveToggleHwnd),
                port: UInt16(PaneControls.text(portEditHwnd)),
                routes: cachedRoutes,
                token: currentToken,
                revealToken: revealToken,
                tailscaleAddress: MirrorPairing.tailnetAddress(in: WinAddresses.ipv4()),
                machineName: "this PC"
            )
            WinPairing.setClipboardText(brief)
            return true

        case Cmd.serveToggle:
            handleServeToggle()
            return true

        case Cmd.portEdit:
            if code == UINT(EN_CHANGE) {
                let text = PaneControls.text(portEditHwnd)
                if let p = UInt16(text) {
                    _ = try? WinSettingsStore.update { $0.mirrorPort = p }
                    if let warn = PairingChecklist.portChangeWarning(port: p) {
                        PaneControls.setText(portWarnLabelHwnd, warn)
                    } else {
                        PaneControls.setText(portWarnLabelHwnd, "")
                    }
                    refreshRoutesAndQR()
                }
            }
            return true

        case Cmd.tokenReveal:
            revealToken.toggle()
            PaneControls.setText(tokenRevealBtnHwnd, revealToken ? "Hide" : "Reveal")
            PaneControls.setText(
                copyAgentHelpHwnd,
                revealToken ? "Includes the pairing token." : "Token left out — Reveal it below to include it."
            )
            updateTokenUI()
            return true

        case Cmd.tokenCopy:
            if let t = currentToken {
                WinPairing.setClipboardText(t)
            }
            return true

        case Cmd.tokenRegen:
            let titleWide = Array("Regenerate Pairing Token".utf16) + [0]
            let msgWide = Array("Every paired phone must scan the QR again after rotating. Proceed?".utf16) + [0]
            let confirmed = titleWide.withUnsafeBufferPointer { tb in
                msgWide.withUnsafeBufferPointer { mb in
                    MessageBoxW(ctx.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
                }
            }
            if confirmed {
                shellPairRotate()
            }
            return true

        case Cmd.copyFirewall:
            let p = PaneControls.text(portEditHwnd)
            let cmd = "netsh advfirewall firewall add rule name=\"Infinitus\" dir=in action=allow protocol=TCP localport=\(p)"
            WinPairing.setClipboardText(cmd)
            return true

        case Cmd.copyRoute1:
            if cachedRoutes.count > 0 {
                WinPairing.setClipboardText(cachedRoutes[0].endpoint)
            }
            return true

        case Cmd.copyRoute2:
            if cachedRoutes.count > 1 {
                WinPairing.setClipboardText(cachedRoutes[1].endpoint)
            }
            return true

        case Cmd.copyPairLink:
            let port = UInt16(PaneControls.text(portEditHwnd)) ?? WinPairing.defaultMirrorPort
            if let link = WinPairing.pairingURL(port: port) {
                WinPairing.setClipboardText(link)
            }
            return true

        case Cmd.getTailscale:
            let tsUrl = Array("https://tailscale.com/download/windows".utf16) + [0]
            let openVerb = Array("open".utf16) + [0]
            _ = tsUrl.withUnsafeBufferPointer { ub in
                openVerb.withUnsafeBufferPointer { ob in
                    ShellExecuteW(nil, ob.baseAddress, ub.baseAddress, nil, nil, SW_SHOWNORMAL)
                }
            }
            return true

        case Cmd.exportSettings:
            exportSettingsSnapshot()
            return true

        case Cmd.importSettings:
            importSettingsSnapshot()
            return true

        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        let d = item.pointee
        guard let ctx else { return false }
        if d.CtlID == UINT(ctx.idBase + Cmd.qrCanvasID) {
            drawQRCode(item)
            return true
        }
        return WinDark.drawButton(item)
    }

    public func contentHeight(width: Int32) -> Int32 {
        calculatedHeight
    }

    // MARK: - Timer
    private nonisolated(unsafe) static var activePane: DevicesPane?

    private static let timerCallback: TIMERPROC = { (hwnd, msg, id, time) in
        DevicesPane.activePane?.timerTick()
    }

    private func startTimer() {
        guard let ctx else { return }
        DevicesPane.activePane = self
        timerID = SetTimer(ctx.host, 1001, 3000, DevicesPane.timerCallback)
    }

    private func stopTimer() {
        guard let ctx else { return }
        if timerID != 0 {
            KillTimer(ctx.host, timerID)
            timerID = 0
        }
        if DevicesPane.activePane === self {
            DevicesPane.activePane = nil
        }
    }

    private func timerTick() {
        refreshRoutesAndQR()
    }

    // MARK: - State Refresh
    private func refreshState() {
        currentToken = WinPairing.token()
        updateTokenUI()
        refreshServingState()
        refreshRoutesAndQR()
    }

    private func updateTokenUI() {
        guard let t = currentToken, !t.isEmpty else {
            PaneControls.setText(tokenValueHwnd, "No pairing token yet.")
            return
        }
        if revealToken {
            PaneControls.setText(tokenValueHwnd, t)
        } else {
            PaneControls.setText(tokenValueHwnd, MirrorPairing.mask(t))
        }
    }

    private func refreshServingState() {
        let port = UInt16(PaneControls.text(portEditHwnd)) ?? WinPairing.defaultMirrorPort
        let serving = daemonAlreadyServing(port: port)

        if serving {
            PaneControls.setChecked(serveToggleHwnd, true)
            PaneControls.setText(serveStatusLabelHwnd, "listening on \(port)")
            EnableWindow(portEditHwnd, false)
        } else {
            PaneControls.setChecked(serveToggleHwnd, false)
            PaneControls.setText(serveStatusLabelHwnd, "not running")
            EnableWindow(portEditHwnd, true)
        }
    }

    private func refreshRoutesAndQR() {
        let port = UInt16(PaneControls.text(portEditHwnd)) ?? WinPairing.defaultMirrorPort
        let addresses = WinAddresses.ipv4()
        var routes: [PairingChecklist.RouteItem] = []

        if let lan = MirrorPairing.lanAddress(in: addresses) {
            routes.append(PairingChecklist.RouteItem(id: "lan", title: "Wi-Fi (LAN)", endpoint: "http://\(lan):\(port)"))
        }
        if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
            routes.append(PairingChecklist.RouteItem(id: "tailscale", title: "Tailscale", endpoint: "http://\(tailnet):\(port)"))
        }
        cachedRoutes = routes

        // Route labels
        if routes.count > 0 {
            PaneControls.setText(route1TitleHwnd, routes[0].title)
            PaneControls.setText(route1EndpointHwnd, routes[0].endpoint)
            ShowWindow(route1TitleHwnd, SW_SHOW)
            ShowWindow(route1EndpointHwnd, SW_SHOW)
            ShowWindow(route1CopyBtnHwnd, SW_SHOW)
        } else {
            ShowWindow(route1TitleHwnd, SW_HIDE)
            ShowWindow(route1EndpointHwnd, SW_HIDE)
            ShowWindow(route1CopyBtnHwnd, SW_HIDE)
        }

        if routes.count > 1 {
            PaneControls.setText(route2TitleHwnd, routes[1].title)
            PaneControls.setText(route2EndpointHwnd, routes[1].endpoint)
            ShowWindow(route2TitleHwnd, SW_SHOW)
            ShowWindow(route2EndpointHwnd, SW_SHOW)
            ShowWindow(route2CopyBtnHwnd, SW_SHOW)
        } else {
            ShowWindow(route2TitleHwnd, SW_HIDE)
            ShowWindow(route2EndpointHwnd, SW_HIDE)
            ShowWindow(route2CopyBtnHwnd, SW_HIDE)
        }

        // Tailscale section
        if let ts = MirrorPairing.tailnetAddress(in: addresses) {
            PaneControls.setText(tailscaleStatusLabelHwnd, "Tailscale:  connected · \(ts)")
            ShowWindow(tailscaleBtnHwnd, SW_HIDE)
        } else {
            PaneControls.setText(tailscaleStatusLabelHwnd, "Tailscale:  not connected")
            ShowWindow(tailscaleBtnHwnd, SW_SHOW)
        }

        // Pair URL & QR Code
        if let token = currentToken, !routes.isEmpty {
            let pairURL = MirrorPairing.pairURL(endpoints: routes.map(\.endpoint), token: token)
            qrMatrix = QRCode.encode(pairURL, correction: .m)
        } else {
            qrMatrix = nil
        }
        if let c = qrCanvasHwnd {
            InvalidateRect(c, nil, true)
        }

        // Steps update
        let isServing = PaneControls.checked(serveToggleHwnd)
        currentSteps = PairingChecklist.steps(
            serving: isServing,
            port: port,
            lastServed: lastServedTime,
            routes: routes
        )

        PaneControls.setText(step1Hwnd, (currentSteps[0].done ? "[x] " : "[ ] ") + currentSteps[0].title)
        PaneControls.setText(step2Hwnd, (currentSteps[1].done ? "[x] " : "[ ] ") + currentSteps[1].title)
        PaneControls.setText(step3Hwnd, (currentSteps[2].done ? "[x] " : "[ ] ") + currentSteps[2].title)
        PaneControls.setText(step4Hwnd, (currentSteps[3].done ? "[x] " : "[ ] ") + currentSteps[3].title)

        let doneCount = currentSteps.filter(\.done).count
        let headerText = doneCount == currentSteps.count ? "Set up your phone (all set)" : "Set up your phone (\(doneCount) of \(currentSteps.count))"
        PaneControls.setText(walkthroughHeaderHwnd, headerText)
    }

    // MARK: - Serving Toggle
    private func handleServeToggle() {
        let isChecked = PaneControls.checked(serveToggleHwnd)

        if isChecked {
            startDaemon()
        } else {
            stopDaemon()
        }
        refreshServingState()
        refreshRoutesAndQR()
    }

    private func shellPairRotate() {
        guard let ctx else { return }
        ctx.async({
            let binary = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("infinitus-win.exe")
            let p = Process()
            p.executableURL = binary
            p.arguments = ["pair", "--rotate"]
            try? p.run()
            p.waitUntilExit()
            return WinPairing.token()
        }, then: { [weak self] token in
            self?.currentToken = token
            self?.updateTokenUI()
            self?.refreshRoutesAndQR()
        })
    }

    // MARK: - QR Code Painting via GDI
    private func drawQRCode(_ item: UnsafePointer<DRAWITEMSTRUCT>) {
        let d = item.pointee
        guard let dc = d.hDC else { return }
        var rc = d.rcItem

        // Fill background white
        if let whiteBrush = CreateSolidBrush(RGB(255, 255, 255)) {
            FillRect(dc, &rc, whiteBrush)
            DeleteObject(whiteBrush)
        }

        guard let matrix = qrMatrix else {
            // Draw placeholder text
            SetBkMode(dc, TRANSPARENT)
            SetTextColor(dc, WinDark.rgb(100, 100, 100))
            let msg = "No QR"
            var msgWide = Array(msg.utf16) + [0]
            _ = DrawTextW(dc, &msgWide, Int32(msg.utf16.count), &rc, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            return
        }

        guard let blackBrush = CreateSolidBrush(RGB(0, 0, 0)) else { return }
        defer { DeleteObject(blackBrush) }

        let matrixSize = matrix.size
        let quietZone = 4
        let totalModules = matrixSize + quietZone * 2
        let width = rc.right - rc.left
        let height = rc.bottom - rc.top
        let side = min(width, height)
        let modulePx = max(1, side / Int32(totalModules))
        let originX = rc.left + (width - modulePx * Int32(totalModules)) / 2
        let originY = rc.top + (height - modulePx * Int32(totalModules)) / 2

        for row in 0..<matrixSize {
            for col in 0..<matrixSize {
                if matrix[col, row] {
                    var mRc = RECT(
                        left: originX + Int32(col + quietZone) * modulePx,
                        top: originY + Int32(row + quietZone) * modulePx,
                        right: originX + Int32(col + quietZone + 1) * modulePx,
                        bottom: originY + Int32(row + quietZone + 1) * modulePx
                    )
                    FillRect(dc, &mRc, blackBrush)
                }
            }
        }
    }

    // MARK: - Export / Import
    private func exportSettingsSnapshot() {
        guard let ctx else { return }

        // Ask for destination file
        var fileBuf = [WCHAR](repeating: 0, count: 1024)
        let defName = "infinitus-settings.json"
        for (i, c) in defName.utf16.enumerated() { fileBuf[i] = c }

        let filter = "JSON Files (*.json)\0*.json\0All Files (*.*)\0*.*\0\0"
        let filterWide = Array(filter.utf16)

        // The buffer pointers must stay valid for the DIALOG's whole
        // lifetime, so the call happens INSIDE the withUnsafe… scopes.
        // Assigning `$0.baseAddress` out of the closure and calling
        // afterwards hands comdlg32 a dangling pointer.
        let picked: String? = filterWide.withUnsafeBufferPointer { fBuf in
            fileBuf.withUnsafeMutableBufferPointer { pBuf -> String? in
                var ofn = OPENFILENAMEW()
                ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                ofn.hwndOwner = ctx.shell
                ofn.lpstrFilter = fBuf.baseAddress
                ofn.lpstrFile = pBuf.baseAddress
                ofn.nMaxFile = DWORD(pBuf.count)
                ofn.Flags = DWORD(OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST)
                guard GetSaveFileNameW(&ofn) else { return nil }
                guard let base = pBuf.baseAddress else { return nil }
                return String(decodingCString: base, as: UTF16.self)
            }
        }
        guard let destPath = picked, !destPath.isEmpty else { return }

        PaneControls.setText(settingsFileStatusHwnd, "Exporting…")

        ctx.async({
            let settings = WinSettingsStore.load()
            let appDict: [String: JSONValue]
            if let sData = try? JSONEncoder().encode(settings),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: sData) {
                appDict = decoded
            } else {
                appDict = [:]
            }

            let themes = RowTheme.loadCustom()

            var engineSettings: [String: String] = [:]
            if let binary = CswapLocator.locate() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["config", "list", "--json"]
                let pipe = Pipe()
                p.standardOutput = pipe
                if (try? p.run()) != nil {
                    let out = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if let list = try? JSONDecoder().decode(ConfigList.self, from: out) {
                        for entry in list.settings where entry.isSet {
                            let strVal: String
                            switch entry.value {
                            case .string(let s): strVal = s
                            case .number(let n): strVal = n == n.rounded() ? String(Int(n)) : String(n)
                            case .bool(let b): strVal = b ? "true" : "false"
                            default: strVal = ""
                            }
                            engineSettings[entry.key] = strVal
                        }
                    }
                }
            }

            let snapshot = SyncSnapshot(app: appDict, themes: themes, engine: engineSettings)
            do {
                let data = try snapshot.encoded()
                try data.write(to: URL(fileURLWithPath: destPath))
                return "Exported settings to \(URL(fileURLWithPath: destPath).lastPathComponent)."
            } catch {
                return "Export failed: \(error)"
            }
        }, then: { [weak self] msg in
            PaneControls.setText(self?.settingsFileStatusHwnd, msg)
        })
    }

    private func importSettingsSnapshot() {
        guard let ctx else { return }

        var fileBuf = [WCHAR](repeating: 0, count: 1024)
        let filter = "JSON Files (*.json)\0*.json\0All Files (*.*)\0*.*\0\0"
        let filterWide = Array(filter.utf16)

        let picked: String? = filterWide.withUnsafeBufferPointer { fBuf in
            fileBuf.withUnsafeMutableBufferPointer { pBuf -> String? in
                var ofn = OPENFILENAMEW()
                ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                ofn.hwndOwner = ctx.shell
                ofn.lpstrFilter = fBuf.baseAddress
                ofn.lpstrFile = pBuf.baseAddress
                ofn.nMaxFile = DWORD(pBuf.count)
                ofn.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST)
                guard GetOpenFileNameW(&ofn) else { return nil }
                guard let base = pBuf.baseAddress else { return nil }
                return String(decodingCString: base, as: UTF16.self)
            }
        }
        guard let srcPath = picked, !srcPath.isEmpty else { return }

        PaneControls.setText(settingsFileStatusHwnd, "Importing…")

        ctx.async({
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: srcPath)),
                  let snapshot = SyncSnapshot.decode(data) else {
                return "Import failed: corrupt or unreadable file"
            }

            // 1. App settings
            if let appData = try? JSONEncoder().encode(snapshot.app),
               let newSettings = try? JSONDecoder().decode(WinSettings.self, from: appData) {
                _ = try? WinSettingsStore.save(newSettings)
            }

            // 2. Themes
            if !snapshot.themes.isEmpty {
                _ = try? RowTheme.saveCustom(snapshot.themes)
            }

            // 3. Engine config
            if let binary = CswapLocator.locate() {
                for (key, val) in snapshot.engine {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: binary)
                    p.arguments = ["config", "set", key, val]
                    try? p.run()
                    p.waitUntilExit()
                }
            }

            return "Imported settings from \(URL(fileURLWithPath: srcPath).lastPathComponent)."
        }, then: { [weak self] msg in
            PaneControls.setText(self?.settingsFileStatusHwnd, msg)
            self?.refreshState()
        })
    }
}

private func RGB(_ r: Int, _ g: Int, _ b: Int) -> COLORREF {
    COLORREF(UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16))
}
