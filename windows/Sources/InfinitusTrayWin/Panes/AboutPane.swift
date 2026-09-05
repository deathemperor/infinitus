import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// About pane and updates for Windows Settings.
/// Spec: docs/wave-01-settings/06-about-and-updates.md
public final class AboutPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "about",
        title: "About",
        glyph: "\u{E946}", // Info
        tintRGB: (100, 95, 220), // .indigo
        keywords: ["update", "version", "license", "links", "components", "runtime", "daemon", "cswap", "claude"],
        section: .general
    )

    private var ctx: PaneContext?

    // Subcommand IDs inside this pane's 512 block
    private enum Cmd {
        static let checkNow: Int32 = 1
        static let openRelease: Int32 = 2
        static let copyCommands: Int32 = 3
        static let autoCheckCheckbox: Int32 = 4
        static let openNotifSettings: Int32 = 5
        static let linkGitHub: Int32 = 10
        static let linkWebsite: Int32 = 11
        static let linkProject: Int32 = 12
        static let linkGuide: Int32 = 13
    }

    // Hero controls
    private var heroTitleHwnd: HWND?
    private var heroVersionHwnd: HWND?
    private var heroBuildDateHwnd: HWND?
    private var heroTaglineHwnd: HWND?

    // Updates section controls
    private var updateLocationHwnd: HWND?
    private var updateStatusHwnd: HWND?
    private var updateAutoCheckHwnd: HWND?
    private var checkNowButtonHwnd: HWND?
    private var openReleaseButtonHwnd: HWND?
    private var updateExplHwnd: HWND?
    private var copyCommandsButtonHwnd: HWND?

    // Components section controls
    private var compTrayHwnd: HWND?
    private var compDaemonHwnd: HWND?
    private var compCswapHwnd: HWND?
    private var compClaudeHwnd: HWND?
    private var compRuntimeHwnd: HWND?

    // Notifications section controls
    private var notifDeliveryHwnd: HWND?
    private var notifFocusAssistHwnd: HWND?
    private var notifSettingsButtonHwnd: HWND?

    // Links section controls
    private var linkGitHubHwnd: HWND?
    private var linkWebsiteHwnd: HWND?
    private var linkProjectHwnd: HWND?
    private var linkGuideHwnd: HWND?

    // Footer
    private var footerHwnd: HWND?

    // State
    private var latestReleaseTag: String?
    private var releasePageURL: String = "https://github.com/deathemperor/infinitus/releases"
    private var cachedComponentsLoaded = false

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // 1. Hero
        heroTitleHwnd = PaneControls.label("Infinitus", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        let currentVer = InfinitusVersion.current
        heroVersionHwnd = PaneControls.label("Version \(currentVer) (tray)", in: ctx, x: 0, y: 0, w: 0, h: 0)
        let bDate = getBuildDateString()
        heroBuildDateHwnd = PaneControls.label("Built \(bDate)", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        heroTaglineHwnd = PaneControls.label("Every Claude account in one tray — swap before you stall.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        // 2. Updates
        let installPath = getExecutableDirectory()
        let classification = UpdateLogicWin.classifyInstallLocation(path: installPath)
        let locText: String
        switch classification {
        case .debugBuild:
            locText = "debug build — runs only with the Swift runtime DLLs staged or env.ps1 sourced"
        case .installed:
            locText = "Infinitus \(currentVer) · installed from %LOCALAPPDATA%\\Infinitus\\bin"
        case .other(let path):
            locText = "Infinitus \(currentVer) · running from \(path)"
        }
        updateLocationHwnd = PaneControls.label(locText, in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: classification == .debugBuild ? WinDark.scopedColor : WinDark.dim)
        updateStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        updateAutoCheckHwnd = PaneControls.checkbox("Check for updates daily", in: ctx, id: base + Cmd.autoCheckCheckbox, x: 0, y: 0, w: 0, h: 0)
        checkNowButtonHwnd = PaneControls.button("Check now", in: ctx, id: base + Cmd.checkNow, x: 0, y: 0, w: 0, h: 0)
        openReleaseButtonHwnd = PaneControls.button("Open the release page", in: ctx, id: base + Cmd.openRelease, x: 0, y: 0, w: 0, h: 0)
        let expl = "Windows installs update by re-running windows\\install.ps1 from a fresh checkout — the tray never replaces itself. (Nightly builds are macOS-only for now.)"
        updateExplHwnd = PaneControls.label(expl, in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        copyCommandsButtonHwnd = PaneControls.button("Copy the update commands", in: ctx, id: base + Cmd.copyCommands, x: 0, y: 0, w: 0, h: 0)

        // 3. Components
        compTrayHwnd = PaneControls.label("infinitus-tray-win    \(currentVer)    this window", in: ctx, x: 0, y: 0, w: 0, h: 0)
        compDaemonHwnd = PaneControls.label("infinitus-win         checking…", in: ctx, x: 0, y: 0, w: 0, h: 0)
        compCswapHwnd = PaneControls.label("cswap                 checking…", in: ctx, x: 0, y: 0, w: 0, h: 0)
        compClaudeHwnd = PaneControls.label("claude                checking…", in: ctx, x: 0, y: 0, w: 0, h: 0)
        compRuntimeHwnd = PaneControls.label("Swift runtime         checking…", in: ctx, x: 0, y: 0, w: 0, h: 0)

        // 4. Notifications
        notifDeliveryHwnd = PaneControls.label("Delivery: tray balloons (Shell_NotifyIconW)", in: ctx, x: 0, y: 0, w: 0, h: 0)
        let focusAssistText = "Windows Focus Assist suppresses balloons while it is on; check Settings → System → Notifications if nothing appears."
        notifFocusAssistHwnd = PaneControls.label(focusAssistText, in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        notifSettingsButtonHwnd = PaneControls.button("Open Windows notification settings", in: ctx, id: base + Cmd.openNotifSettings, x: 0, y: 0, w: 0, h: 0)

        // 5. Links
        linkGitHubHwnd = PaneControls.button("</>   GitHub                                                                        ↗", in: ctx, id: base + Cmd.linkGitHub, x: 0, y: 0, w: 0, h: 0)
        linkWebsiteHwnd = PaneControls.button("🌐   Website                                                                       ↗", in: ctx, id: base + Cmd.linkWebsite, x: 0, y: 0, w: 0, h: 0)
        linkProjectHwnd = PaneControls.button("📦   Project — Infinitus                                                           ↗", in: ctx, id: base + Cmd.linkProject, x: 0, y: 0, w: 0, h: 0)
        linkGuideHwnd = PaneControls.button("📄   Windows guide (windows/README.md)                                             ↗", in: ctx, id: base + Cmd.linkGuide, x: 0, y: 0, w: 0, h: 0)

        // 6. Footer
        footerHwnd = PaneControls.label("Infinitus by deathemperor · MIT License", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let gap = m.px(6)
        let contentW = width - pad * 2

        var y = pad

        // Hero: Reserve 64x64 icon area (drawn in drawItem / paint)
        let iconSize = m.px(64)
        y += iconSize + gap

        if let h = heroTitleHwnd {
            MoveWindow(h, pad, y, contentW, m.px(22), true)
        }
        y += m.px(22) + gap / 2

        if let h = heroVersionHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + gap / 2

        if let h = heroBuildDateHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + gap / 2

        if let h = heroTaglineHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + m.sectionGap * 2

        // Section: Updates
        y = PaneControls.sectionHeader("Updates", in: ctx, y: y, width: width)
        if let h = updateLocationHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + gap

        if let h = updateStatusHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + gap

        if let h = updateAutoCheckHwnd {
            MoveWindow(h, pad, y, contentW, fieldH, true)
        }
        y += fieldH + gap

        if let b1 = checkNowButtonHwnd, let b2 = openReleaseButtonHwnd {
            let b1W = m.px(110)
            let b2W = m.px(180)
            MoveWindow(b1, pad, y, b1W, btnH, true)
            MoveWindow(b2, pad + b1W + gap, y, b2W, btnH, true)
        }
        y += btnH + gap

        if let h = updateExplHwnd {
            MoveWindow(h, pad, y, contentW, m.px(32), true)
        }
        y += m.px(32) + gap

        if let h = copyCommandsButtonHwnd {
            MoveWindow(h, pad, y, m.px(200), btnH, true)
        }
        y += btnH + m.sectionGap * 2

        // Section: Components
        y = PaneControls.sectionHeader("Components", in: ctx, y: y, width: width)
        if let h = compTrayHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + gap
        if let h = compDaemonHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + gap
        if let h = compCswapHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + gap
        if let h = compClaudeHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + gap
        if let h = compRuntimeHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + m.sectionGap * 2

        // Section: Notifications
        y = PaneControls.sectionHeader("Notifications", in: ctx, y: y, width: width)
        if let h = notifDeliveryHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + gap
        if let h = notifFocusAssistHwnd { MoveWindow(h, pad, y, contentW, m.px(32), true) }
        y += m.px(32) + gap
        if let h = notifSettingsButtonHwnd { MoveWindow(h, pad, y, m.px(260), btnH, true) }
        y += btnH + m.sectionGap * 2

        // Section: Links
        y = PaneControls.sectionHeader("Links", in: ctx, y: y, width: width)
        let linkW = min(m.px(420), contentW)
        if let h = linkGitHubHwnd { MoveWindow(h, pad, y, linkW, btnH, true) }
        y += btnH + gap
        if let h = linkWebsiteHwnd { MoveWindow(h, pad, y, linkW, btnH, true) }
        y += btnH + gap
        if let h = linkProjectHwnd { MoveWindow(h, pad, y, linkW, btnH, true) }
        y += btnH + gap
        if let h = linkGuideHwnd { MoveWindow(h, pad, y, linkW, btnH, true) }
        y += btnH + m.sectionGap * 2

        // Footer
        if let h = footerHwnd { MoveWindow(h, pad, y, contentW, fieldH, true) }
        y += fieldH + pad * 2

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 820 }
        return ctx.metrics.px(820)
    }

    public func activate() {
        guard let ctx else { return }
        let settings = WinSettingsStore.load()
        PaneControls.setChecked(updateAutoCheckHwnd, settings.updateAutoCheck)

        if !cachedComponentsLoaded {
            cachedComponentsLoaded = true
            loadComponentsAsync()
        }

        // Draw 64x64 hero icon
        drawHeroIcon()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.autoCheckCheckbox:
            let on = PaneControls.checked(updateAutoCheckHwnd)
            _ = try? WinSettingsStore.update { $0.updateAutoCheck = on }
            return true

        case Cmd.checkNow:
            performUpdateCheck()
            return true

        case Cmd.openRelease:
            openURL(releasePageURL)
            return true

        case Cmd.copyCommands:
            let autostart = TrayAutostart.isEnabled()
            let cmds = UpdateLogicWin.updateCommands(autostart: autostart)
            setClipboardText(cmds)
            PaneControls.setText(updateStatusHwnd, "Copied update commands to clipboard.")
            return true

        case Cmd.openNotifSettings:
            let msSettings = Array("ms-settings:notifications".utf16) + [0]
            let openWide = Array("open".utf16) + [0]
            msSettings.withUnsafeBufferPointer { sBuf in
                openWide.withUnsafeBufferPointer { oBuf in
                    ShellExecuteW(nil, oBuf.baseAddress, sBuf.baseAddress, nil, nil, SW_SHOWNORMAL)
                }
            }
            return true

        case Cmd.linkGitHub:
            openURL("https://github.com/deathemperor")
            return true

        case Cmd.linkWebsite:
            openURL("https://huuloc.com")
            return true

        case Cmd.linkProject:
            openURL("https://github.com/deathemperor/infinitus")
            return true

        case Cmd.linkGuide:
            openURL("https://github.com/deathemperor/infinitus/blob/main/windows/README.md")
            return true

        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    // MARK: - Hero Icon
    private func drawHeroIcon() {
        guard let ctx else { return }
        let m = ctx.metrics
        let iconSide = m.px(64)
        let pad = m.pad

        // Tray icon at 64x64
        guard let hIcon = TrayIcon.make(busy: false, side: iconSide) else { return }
        defer { DestroyIcon(hIcon) }

        if let hdc = GetDC(ctx.host) {
            DrawIconEx(hdc, pad, pad, hIcon, iconSide, iconSide, 0, nil, UINT(DI_NORMAL))
            ReleaseDC(ctx.host, hdc)
        }
    }

    // MARK: - Update Check
    private struct ReleasePayload: Decodable {
        let tag_name: String
        let html_url: String?
        let name: String?
    }

    private func performUpdateCheck() {
        guard let ctx else { return }
        PaneControls.setText(updateStatusHwnd, "Checking GitHub for updates…")

        ctx.async({ () -> (status: String, tag: String?, url: String?) in
            guard let url = URL(string: "https://api.github.com/repos/deathemperor/infinitus/releases/latest") else {
                return ("Invalid URL", nil, nil)
            }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Infinitus-Win/\(InfinitusVersion.current)", forHTTPHeaderField: "User-Agent")

            var resultStatus = ""
            var releaseTag: String? = nil
            var releaseURL: String? = nil

            let sema = DispatchSemaphore(value: 0)
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: req) { data, response, error in
                defer { sema.signal() }
                if let error {
                    resultStatus = "release check failed: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    resultStatus = "release check failed: unknown response"
                    return
                }
                if http.statusCode == 404 {
                    resultStatus = "no releases published yet — this build came from source"
                    return
                }
                guard http.statusCode == 200, let data else {
                    resultStatus = "release check failed (HTTP \(http.statusCode))"
                    return
                }
                do {
                    let rel = try JSONDecoder().decode(ReleasePayload.self, from: data)
                    let tag = UpdateLogicWin.normalizeTag(rel.tag_name)
                    releaseTag = tag
                    releaseURL = rel.html_url ?? "https://github.com/deathemperor/infinitus/releases"
                    let curr = InfinitusVersion.current
                    if UpdateLogicWin.isUpdateAvailable(current: curr, latest: tag) {
                        resultStatus = "\(tag) is available on GitHub"
                    } else {
                        resultStatus = "up to date (latest: \(tag))"
                    }
                } catch {
                    resultStatus = "release check failed: could not parse response"
                }
            }
            task.resume()
            sema.wait()
            return (resultStatus, releaseTag, releaseURL)
        }, then: { [weak self] res in
            guard let self else { return }
            self.latestReleaseTag = res.tag
            if let url = res.url { self.releasePageURL = url }
            PaneControls.setText(self.updateStatusHwnd, res.status)

            let now = Date().timeIntervalSince1970
            _ = try? WinSettingsStore.update {
                $0.appUpdateLastCheck = now
            }
        })
    }

    // MARK: - Components Async Inspection
    private struct ComponentsResult: Sendable {
        let daemon: String
        let cswap: String
        let claude: String
        let runtime: String
    }

    private func loadComponentsAsync() {
        guard let ctx else { return }
        let currentVer = InfinitusVersion.current

        ctx.async({ () -> ComponentsResult in
            // 1. Daemon check
            let isServing = daemonAlreadyServing(port: defaultMirrorPort)
            let daemonText = isServing
                ? "infinitus-win        \(currentVer)      running on \(defaultMirrorPort)"
                : "infinitus-win        \(currentVer)      not running"

            // 2. cswap check
            let cswapText: String
            if let binary = CswapLocator.locate() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["--version"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                if (try? p.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let ver = out.split(separator: " ").last.map(String.init) ?? out
                    cswapText = "cswap                \(ver)     \(binary)"
                } else {
                    cswapText = "cswap                found      \(binary)"
                }
            } else {
                cswapText = "cswap                not found"
            }

            // 3. claude on PATH
            let claudeText: String
            if let claudePath = findOnPath("claude.exe") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claudePath)
                p.arguments = ["--version"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                if (try? p.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let ver = out.split(separator: " ").last.map(String.init) ?? out
                    claudeText = "claude               \(ver)     \(claudePath)"
                } else {
                    claudeText = "claude               installed  \(claudePath)"
                }
            } else {
                claudeText = "claude               not found on PATH"
            }

            // 4. Swift runtime staged vs PATH
            let runtimeText: String
            let exeDir = getExecutableDirectory()
            let stagedPath = (exeDir as NSString).appendingPathComponent("swiftCore.dll")
            if FileManager.default.fileExists(atPath: stagedPath) {
                runtimeText = "Swift runtime        staged     \(exeDir)"
            } else if findOnPath("swiftCore.dll") != nil {
                runtimeText = "Swift runtime        from PATH"
            } else {
                runtimeText = "Swift runtime        warning: DLLs not found (debug build requires env.ps1)"
            }

            return ComponentsResult(
                daemon: daemonText,
                cswap: cswapText,
                claude: claudeText,
                runtime: runtimeText
            )
        }, then: { [weak self] res in
            guard let self else { return }
            PaneControls.setText(self.compDaemonHwnd, res.daemon)
            PaneControls.setText(self.compCswapHwnd, res.cswap)
            PaneControls.setText(self.compClaudeHwnd, res.claude)
            PaneControls.setText(self.compRuntimeHwnd, res.runtime)
        })
    }

    // MARK: - Helpers
    private func openURL(_ urlString: String) {
        let wideURL = Array(urlString.utf16) + [0]
        let wideOpen = Array("open".utf16) + [0]
        wideURL.withUnsafeBufferPointer { uBuf in
            wideOpen.withUnsafeBufferPointer { oBuf in
                ShellExecuteW(nil, oBuf.baseAddress, uBuf.baseAddress, nil, nil, SW_SHOWNORMAL)
            }
        }
    }

    private func setClipboardText(_ text: String) {
        let wide = Array(text.utf16) + [0]
        let byteCount = wide.count * MemoryLayout<WCHAR>.stride
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let hMem = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(byteCount)) else { return }
        guard let ptr = GlobalLock(hMem) else { return }
        ptr.copyMemory(from: wide, byteCount: byteCount)
        GlobalUnlock(hMem)
        SetClipboardData(UINT(CF_UNICODETEXT), hMem)
    }
}

// MARK: - Standalone Helpers
private func getExecutableDirectory() -> String {
    var buffer = [WCHAR](repeating: 0, count: 1024)
    let len = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    guard len > 0 else { return "." }
    let exePath = String(decodingCString: buffer, as: UTF16.self)
    return (exePath as NSString).deletingLastPathComponent
}

private func getBuildDateString() -> String {
    var buffer = [WCHAR](repeating: 0, count: 1024)
    let len = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    guard len > 0 else { return "recent" }
    let exePath = String(decodingCString: buffer, as: UTF16.self)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
          let mtime = attrs[.modificationDate] as? Date else {
        return "recent"
    }
    // DateFormatter without named IANA timeZone per CLAUDE.md
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "MMM d, yyyy 'at' HH:mm"
    return df.string(from: mtime)
}

private func findOnPath(_ filename: String) -> String? {
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let dirs = pathEnv.split(separator: ";").map(String.init)
    for dir in dirs {
        let full = (dir as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: full) {
            return full
        }
    }
    return nil
}
