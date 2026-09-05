import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Pane A — Accounts: multi-fleet roster, capability-gated actions (switch, hold, rename, prefer, reorder, remove, backup).
public final class AccountsPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "accounts",
        title: "Accounts",
        glyph: "\u{E716}",
        tintRGB: (52, 152, 219),
        keywords: ["account", "login", "relogin", "token", "add", "remove", "delete", "oauth", "order", "reorder", "alias", "rename"]
    )

    private var ctx: PaneContext?
    private var timerID: UINT_PTR = 0
    private var fleets: [EngineFleet] = []
    private var rowModels: [AccountRowModel] = []
    private var statusText: String = ""

    // Row control HWNDs keyed by row index
    private var renameEdits: [Int: HWND] = [:]
    private var upButtons: [Int: HWND] = [:]
    private var downButtons: [Int: HWND] = [:]
    private var preferButtons: [Int: HWND] = [:]
    private var switchButtons: [Int: HWND] = [:]
    private var holdButtons: [Int: HWND] = [:]
    private var reloginButtons: [Int: HWND] = [:]
    private var removeButtons: [Int: HWND] = [:]

    // Bottom action buttons
    private var addAccountButtonHwnd: HWND?
    private var randomizeNamesButtonHwnd: HWND?
    private var backupButtonHwnd: HWND?
    private var restoreButtonHwnd: HWND?
    private var fullBackupCheckboxHwnd: HWND?
    private var statusLabelHwnd: HWND?

    // Sub-command ID offsets relative to ctx.idBase
    private enum Cmd {
        static let addAccount: Int32 = 1
        static let randomizeNames: Int32 = 2
        static let backup: Int32 = 3
        static let restore: Int32 = 4
        static let fullBackup: Int32 = 5
        static let rowStride: Int32 = 8
        static let rowBase: Int32 = 20

        // Per row offsets (0..7)
        static let up: Int32 = 0
        static let down: Int32 = 1
        static let rename: Int32 = 2
        static let prefer: Int32 = 3
        static let `switch`: Int32 = 4
        static let hold: Int32 = 5
        static let relogin: Int32 = 6
        static let remove: Int32 = 7
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        addAccountButtonHwnd = PaneControls.button("Add account…", in: ctx, id: base + Cmd.addAccount, x: 0, y: 0, w: 0, h: 0)
        randomizeNamesButtonHwnd = PaneControls.button("Randomize names", in: ctx, id: base + Cmd.randomizeNames, x: 0, y: 0, w: 0, h: 0)
        backupButtonHwnd = PaneControls.button("Back up accounts…", in: ctx, id: base + Cmd.backup, x: 0, y: 0, w: 0, h: 0)
        restoreButtonHwnd = PaneControls.button("Restore…", in: ctx, id: base + Cmd.restore, x: 0, y: 0, w: 0, h: 0)
        fullBackupCheckboxHwnd = PaneControls.checkbox("Full (~/.claude.json)", in: ctx, id: base + Cmd.fullBackup, x: 0, y: 0, w: 0, h: 0)
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let btnH = m.buttonHeight

        var y = pad
        buildRowModels()

        // Recreate row child HWNDs if needed
        syncRowControls(width: width, startY: y, totalHeightOut: &y)

        // Bottom section
        y += m.px(16)
        if let h = statusLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(22), true)
        }
        y += m.px(26)

        // Buttons row
        let btnW = m.px(130)
        var btnX = pad
        if let h = addAccountButtonHwnd {
            MoveWindow(h, btnX, y, btnW, btnH, true)
            btnX += btnW + m.px(8)
        }
        if let h = randomizeNamesButtonHwnd {
            MoveWindow(h, btnX, y, btnW, btnH, true)
            btnX += btnW + m.px(8)
        }
        y += btnH + m.px(10)

        btnX = pad
        if let h = backupButtonHwnd {
            MoveWindow(h, btnX, y, btnW, btnH, true)
            btnX += btnW + m.px(8)
        }
        if let h = restoreButtonHwnd {
            MoveWindow(h, btnX, y, m.px(90), btnH, true)
            btnX += m.px(90) + m.px(8)
        }
        if let h = fullBackupCheckboxHwnd {
            MoveWindow(h, btnX, y, m.px(180), btnH, true)
        }
        y += btnH + pad

        PaneHost.setContentHeight(ctx.host, y)
    }

    private func syncRowControls(width: Int32, startY: Int32, totalHeightOut: inout Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        var y = startY

        // Destroy previous row controls
        for (_, h) in renameEdits { DestroyWindow(h) }
        for (_, h) in upButtons { DestroyWindow(h) }
        for (_, h) in downButtons { DestroyWindow(h) }
        for (_, h) in preferButtons { DestroyWindow(h) }
        for (_, h) in switchButtons { DestroyWindow(h) }
        for (_, h) in holdButtons { DestroyWindow(h) }
        for (_, h) in reloginButtons { DestroyWindow(h) }
        for (_, h) in removeButtons { DestroyWindow(h) }
        renameEdits.removeAll()
        upButtons.removeAll()
        downButtons.removeAll()
        preferButtons.removeAll()
        switchButtons.removeAll()
        holdButtons.removeAll()
        reloginButtons.removeAll()
        removeButtons.removeAll()

        guard !fleets.isEmpty else {
            totalHeightOut = y + m.px(40)
            return
        }

        var globalRowIdx = 0
        for fleet in fleets {
            // Fleet section header
            let headerText = "\(fleet.provider.displayName) \u{00B7} \(EngineCatalog.displayName(for: fleet.engineID))"
            y = PaneControls.sectionHeader(headerText, in: ctx, y: y, width: width)

            let caps = EngineCatalog.capabilities(for: fleet.engineID)
            let accounts = fleet.accounts

            for acc in accounts {
                let rowModel = AccountRowModel(
                    account: acc,
                    activeNumber: fleet.activeNumber,
                    engineID: fleet.engineID,
                    provider: fleet.provider,
                    capabilities: caps
                )

                let rowH = m.px(28)
                let rBase = ctx.idBase + Cmd.rowBase + Int32(globalRowIdx) * Cmd.rowStride

                var x = pad
                // Up / Down buttons
                if rowModel.canReorder {
                    let upH = PaneControls.button("▲", in: ctx, id: rBase + Cmd.up, x: x, y: y, w: m.px(22), h: rowH)
                    let dnH = PaneControls.button("▼", in: ctx, id: rBase + Cmd.down, x: x + m.px(24), y: y, w: m.px(22), h: rowH)
                    upButtons[globalRowIdx] = upH
                    downButtons[globalRowIdx] = dnH
                    x += m.px(50)
                }

                // Number
                _ = PaneControls.label("#\(acc.number)", in: ctx, x: x, y: y + m.px(4), w: m.px(28), h: m.px(20), bold: true, transient: true)
                x += m.px(32)

                // Name (EDIT or static)
                if rowModel.canRename {
                    let nameEdit = PaneControls.edit(in: ctx, id: rBase + Cmd.rename, x: x, y: y, w: m.px(120), h: rowH)
                    PaneControls.setText(nameEdit, rowModel.name)
                    renameEdits[globalRowIdx] = nameEdit
                } else {
                    _ = PaneControls.label(rowModel.name, in: ctx, x: x, y: y + m.px(4), w: m.px(120), h: m.px(20), transient: true)
                }
                x += m.px(126)

                // Email
                _ = PaneControls.label(rowModel.email, in: ctx, x: x, y: y + m.px(4), w: m.px(180), h: m.px(20), color: WinDark.dim, transient: true)
                x += m.px(186)

                // Plan chip
                if !rowModel.plan.isEmpty {
                    _ = PaneControls.label(rowModel.plan, in: ctx, x: x, y: y + m.px(4), w: m.px(70), h: m.px(20), caption: true, color: WinDark.text, transient: true)
                }
                x += m.px(74)

                // Status chip
                let chipText = rowModel.active ? "active" : (rowModel.held ? "held" : (rowModel.usageStatus != "ok" ? rowModel.usageStatus : ""))
                if !chipText.isEmpty {
                    _ = PaneControls.label(chipText, in: ctx, x: x, y: y + m.px(4), w: m.px(60), h: m.px(20), caption: true, color: rowModel.active ? WinDark.liveDot : WinDark.dim, transient: true)
                }
                x += m.px(66)

                // Right action buttons
                let actionBtnW = m.px(28)
                if rowModel.canPrefer {
                    let star = (rowModel.preferred == true) ? "★" : "☆"
                    let b = PaneControls.button(star, in: ctx, id: rBase + Cmd.prefer, x: x, y: y, w: actionBtnW, h: rowH)
                    preferButtons[globalRowIdx] = b
                    x += actionBtnW + m.px(4)
                }
                if rowModel.canSwitch {
                    let b = PaneControls.button("→", in: ctx, id: rBase + Cmd.switch, x: x, y: y, w: actionBtnW, h: rowH)
                    switchButtons[globalRowIdx] = b
                    x += actionBtnW + m.px(4)
                }
                if rowModel.canHold {
                    let b = PaneControls.button(rowModel.held ? "▶" : "⏸", in: ctx, id: rBase + Cmd.hold, x: x, y: y, w: actionBtnW, h: rowH)
                    holdButtons[globalRowIdx] = b
                    x += actionBtnW + m.px(4)
                }
                if rowModel.canRelogin {
                    let b = PaneControls.button("⟲", in: ctx, id: rBase + Cmd.relogin, x: x, y: y, w: actionBtnW, h: rowH)
                    reloginButtons[globalRowIdx] = b
                    x += actionBtnW + m.px(4)
                }
                if rowModel.canRemove {
                    let b = PaneControls.button("🗑", in: ctx, id: rBase + Cmd.remove, x: x, y: y, w: actionBtnW, h: rowH, destructive: true)
                    removeButtons[globalRowIdx] = b
                    x += actionBtnW + m.px(4)
                }

                y += rowH + m.px(4)
                globalRowIdx += 1
            }
            y += m.px(10)
        }

        totalHeightOut = y
    }

    private func buildRowModels() {
        rowModels.removeAll()
        for fleet in fleets {
            let caps = EngineCatalog.capabilities(for: fleet.engineID)
            for acc in fleet.accounts {
                rowModels.append(AccountRowModel(
                    account: acc,
                    activeNumber: fleet.activeNumber,
                    engineID: fleet.engineID,
                    provider: fleet.provider,
                    capabilities: caps
                ))
            }
        }
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 500 }
        return ctx.metrics.px(max(500, Int32(fleets.reduce(0) { $0 + $1.accounts.count }) * 36 + 260))
    }

    public func activate() {
        fleets = TrayFleet.cachedFleets()
        if let ctx {
            layout(width: ctx.metrics.px(600), height: ctx.metrics.px(500))
        }
        timerID = SetTimer(ctx?.host, 1, 3000, nil)
    }

    public func deactivate() {
        if let host = ctx?.host, timerID != 0 {
            KillTimer(host, timerID)
            timerID = 0
        }
    }

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase

        switch rel {
        case Cmd.addAccount:
            showAddAccountDialog()
            return true
        case Cmd.randomizeNames:
            randomizeNames()
            return true
        case Cmd.backup:
            performBackup()
            return true
        case Cmd.restore:
            performRestore()
            return true
        default:
            break
        }

        // Check if row command
        if rel >= Cmd.rowBase {
            let rowOffset = rel - Cmd.rowBase
            let rowIdx = Int(rowOffset / Cmd.rowStride)
            let subCmd = rowOffset % Cmd.rowStride
            guard rowIdx >= 0 && rowIdx < rowModels.count else { return false }
            let row = rowModels[rowIdx]

            switch subCmd {
            case Cmd.rename:
                if code == UINT(EN_KILLFOCUS) {
                    commitRename(rowIdx: rowIdx, row: row)
                }
                return true
            case Cmd.prefer:
                togglePrefer(row: row)
                return true
            case Cmd.switch:
                doSwitch(row: row)
                return true
            case Cmd.hold:
                toggleHold(row: row)
                return true
            case Cmd.relogin:
                showReloginDialog(row: row)
                return true
            case Cmd.remove:
                confirmAndRemove(row: row)
                return true
            case Cmd.up:
                reorderRow(rowIdx: rowIdx, delta: -1)
                return true
            case Cmd.down:
                reorderRow(rowIdx: rowIdx, delta: 1)
                return true
            default:
                return false
            }
        }

        return false
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    // MARK: - Actions

    private func commitRename(rowIdx: Int, row: AccountRowModel) {
        guard let editH = renameEdits[rowIdx] else { return }
        let newName = PaneControls.text(editH).trimmingCharacters(in: .whitespaces)
        guard newName != row.name else { return }

        ctx?.async({
            if row.engineID == "cswap" {
                guard let bin = CswapLocator.locate() else { return "cswap not found" }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = newName.isEmpty ? ["alias", String(row.number), "--unset"] : ["alias", String(row.number), newName]
                try? p.run()
                p.waitUntilExit()
                return "Alias updated"
            } else if row.engineID == "cliproxy" {
                _ = CLIProxyFleet.rename(row.number, provider: row.provider, name: newName)
                return "Renamed account"
            }
            return ""
        }, then: { [weak self] msg in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func togglePrefer(row: AccountRowModel) {
        let newPref = !(row.preferred ?? false)
        ctx?.async({
            if row.engineID == "cswap" {
                guard let bin = CswapLocator.locate() else { return "cswap not found" }
                let engine = CswapEngine(cli: CswapCLI(binaryPath: bin))
                let sem = DispatchSemaphore(value: 0)
                var resultMsg = ""
                Task {
                    do {
                        try await engine.setPreferred(fleet: row.provider, number: row.number, newPref)
                        resultMsg = newPref ? "Starred #\(row.number)" : "Unstarred #\(row.number)"
                    } catch {
                        resultMsg = error.localizedDescription
                    }
                    sem.signal()
                }
                sem.wait()
                return resultMsg
            } else if row.engineID == "cliproxy" {
                _ = CLIProxyFleet.setPreferred(row.number, provider: row.provider, on: newPref)
                return newPref ? "Starred #\(row.number)" : "Unstarred #\(row.number)"
            }
            return ""
        }, then: { [weak self] msg in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func doSwitch(row: AccountRowModel) {
        PaneControls.setText(statusLabelHwnd, "Switching to #\(row.number)…")
        TrayFleet.requestSwitch(to: row.number, provider: row.provider, engineID: row.engineID) { [weak self] report in
            self?.ctx?.async({ report }, then: { [weak self] msg in
                self?.statusText = msg
                PaneControls.setText(self?.statusLabelHwnd, msg)
                self?.refreshFleets()
            })
        }
    }

    private func toggleHold(row: AccountRowModel) {
        let targetHeld = !row.held
        ctx?.async({
            if row.engineID == "cswap" {
                guard let bin = CswapLocator.locate() else { return "cswap not found" }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = targetHeld ? ["disable", String(row.number)] : ["enable", String(row.number)]
                try? p.run()
                p.waitUntilExit()
                return targetHeld ? "Held account #\(row.number)" : "Released hold #\(row.number)"
            } else if row.engineID == "cliproxy" {
                _ = CLIProxyFleet.setHold(row.number, provider: row.provider, held: targetHeld)
                return targetHeld ? "Held account #\(row.number)" : "Released hold #\(row.number)"
            } else if row.engineID == "9router" {
                guard let engine = NineRouterFleet.loadConfig().0 as URL? else { return "9Router not configured" }
                let nrEngine = NineRouterEngine(baseURL: engine, password: NineRouterFleet.loadConfig().1)
                let sem = DispatchSemaphore(value: 0)
                var msg = ""
                Task {
                    do {
                        try await nrEngine.setHold(fleet: row.provider, number: row.number, held: targetHeld)
                        msg = targetHeld ? "Held account #\(row.number)" : "Released hold #\(row.number)"
                    } catch {
                        msg = error.localizedDescription
                    }
                    sem.signal()
                }
                sem.wait()
                return msg
            }
            return ""
        }, then: { [weak self] msg in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func confirmAndRemove(row: AccountRowModel) {
        let titleWide = Array("Confirm Account Removal".utf16) + [0]
        let prompt = "Remove \(row.name)? cswap forgets its stored credential. The Claude account itself is untouched — you can add it back any time."
        let promptWide = Array(prompt.utf16) + [0]

        let ret = titleWide.withUnsafeBufferPointer { tBuf in
            promptWide.withUnsafeBufferPointer { pBuf in
                MessageBoxW(ctx?.host, pBuf.baseAddress, tBuf.baseAddress, UINT(MB_YESNO | MB_ICONWARNING))
            }
        }
        guard ret == IDYES else { return }

        ctx?.async({
            if row.engineID == "cswap" {
                guard let bin = CswapLocator.locate() else { return "cswap not found" }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["remove", String(row.number), "--yes"]
                try? p.run()
                p.waitUntilExit()
                return "Removed account #\(row.number)"
            } else if row.engineID == "cliproxy" {
                _ = CLIProxyFleet.remove(row.number, provider: row.provider)
                return "Removed credential"
            } else if row.engineID == "9router" {
                let nrCfg = NineRouterFleet.loadConfig()
                let nrEngine = NineRouterEngine(baseURL: nrCfg.0, password: nrCfg.1)
                let sem = DispatchSemaphore(value: 0)
                var msg = ""
                Task {
                    do {
                        try await nrEngine.remove(fleet: row.provider, number: row.number)
                        msg = "Removed connection #\(row.number)"
                    } catch {
                        msg = error.localizedDescription
                    }
                    sem.signal()
                }
                sem.wait()
                return msg
            }
            return ""
        }, then: { [weak self] msg in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func reorderRow(rowIdx: Int, delta: Int) {
        guard let fleet = fleets.first(where: { $0.engineID == "cswap" }) else { return }
        var numbers = fleet.accounts.map(\.number)
        let targetIdx = rowIdx + delta
        guard targetIdx >= 0 && targetIdx < numbers.count else { return }
        numbers.swapAt(rowIdx, targetIdx)
        let newNumbers = numbers

        ctx?.async({ () -> String in
            guard let bin = CswapLocator.locate() else { return "cswap not found" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["reorder"] + newNumbers.map(String.init) + ["--json"]
            try? p.run()
            p.waitUntilExit()
            return "Reordered accounts"
        }, then: { [weak self] (msg: String) in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func randomizeNames() {
        guard let fleet = fleets.first(where: { $0.engineID == "cswap" }) else { return }
        let settings = WinSettingsStore.load()
        let theme = RowTheme.builtins.first(where: { $0.id == settings.gamificationStyle }) ?? RowTheme.off
        let randomNames = theme.randomAccountNames(count: fleet.accounts.count)

        ctx?.async({ () -> String in
            guard let bin = CswapLocator.locate() else { return "cswap not found" }
            for (idx, acc) in fleet.accounts.enumerated() {
                let alias = idx < randomNames.count ? randomNames[idx] : "agent-\(acc.number)"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["alias", String(acc.number), alias]
                try? p.run()
                p.waitUntilExit()
            }
            return "Randomized account names"
        }, then: { [weak self] (msg: String) in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func showAddAccountDialog() {
        let msg = """
        Add an account
        Sign in with Claude Code, then hand the credential to cswap:
            claude auth login --claudeai
            cswap add
        Or register an existing token:
            cswap add-token -
        9Router connections are added in its dashboard: Providers → Connect Claude Code.
        """
        copyToClipboard("claude auth login --claudeai\ncswap add")
        let titleWide = Array("Add Account".utf16) + [0]
        let msgWide = Array((msg + "\n\n(Commands copied to clipboard)").utf16) + [0]
        _ = titleWide.withUnsafeBufferPointer { tBuf in
            msgWide.withUnsafeBufferPointer { mBuf in
                MessageBoxW(ctx?.host, mBuf.baseAddress, tBuf.baseAddress, UINT(MB_OK | MB_ICONINFORMATION))
            }
        }
    }

    private func showReloginDialog(row: AccountRowModel) {
        let msg = """
        Re-login this account
        Infinitus can't host Claude's browser sign-in on Windows (no WebKit).
        In a terminal:
            claude auth login --claudeai --email \(row.email)
            cswap add
        The second command captures the fresh credential back into slot \(row.number).
        """
        copyToClipboard("claude auth login --claudeai --email \(row.email)\ncswap add")
        let titleWide = Array("Re-login Account".utf16) + [0]
        let msgWide = Array((msg + "\n\n(Commands copied to clipboard)").utf16) + [0]
        _ = titleWide.withUnsafeBufferPointer { tBuf in
            msgWide.withUnsafeBufferPointer { mBuf in
                MessageBoxW(ctx?.host, mBuf.baseAddress, tBuf.baseAddress, UINT(MB_OK | MB_ICONINFORMATION))
            }
        }
    }

    private func performBackup() {
        let isFull = PaneControls.checked(fullBackupCheckboxHwnd)
        var szFile = [WCHAR](repeating: 0, count: 512)
        var ofn = OPENFILENAMEW()
        ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        ofn.hwndOwner = ctx?.host
        ofn.nMaxFile = DWORD(szFile.count)
        let filterWide = Array("JSON Files (*.json)\0*.json\0All Files (*.*)\0*.*\0\0".utf16)
        ofn.nFilterIndex = 1
        ofn.Flags = DWORD(OFN_PATHMUSTEXIST | OFN_OVERWRITEPROMPT)

        let success = szFile.withUnsafeMutableBufferPointer { fileBuf in
            filterWide.withUnsafeBufferPointer { filterBuf in
                ofn.lpstrFile = fileBuf.baseAddress
                ofn.lpstrFilter = filterBuf.baseAddress
                return GetSaveFileNameW(&ofn)
            }
        }
        guard success else { return }
        let chosenPath = String(decodingCString: &szFile, as: UTF16.self)

        ctx?.async({ () -> String in
            guard let bin = CswapLocator.locate() else { return "cswap not found" }
            var args = ["export", chosenPath]
            if isFull { args.append("--full") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
            return "Export complete to \(chosenPath)"
        }, then: { [weak self] (msg: String) in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
        })
    }

    private func performRestore() {
        var szFile = [WCHAR](repeating: 0, count: 512)
        var ofn = OPENFILENAMEW()
        ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        ofn.hwndOwner = ctx?.host
        ofn.nMaxFile = DWORD(szFile.count)
        let filterWide = Array("JSON Files (*.json)\0*.json\0All Files (*.*)\0*.*\0\0".utf16)
        ofn.nFilterIndex = 1
        ofn.Flags = DWORD(OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST)

        let success = szFile.withUnsafeMutableBufferPointer { fileBuf in
            filterWide.withUnsafeBufferPointer { filterBuf in
                ofn.lpstrFile = fileBuf.baseAddress
                ofn.lpstrFilter = filterBuf.baseAddress
                return GetOpenFileNameW(&ofn)
            }
        }
        guard success else { return }
        let chosenPath = String(decodingCString: &szFile, as: UTF16.self)

        ctx?.async({ () -> String in
            guard let bin = CswapLocator.locate() else { return "cswap not found" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["import", chosenPath]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                return "Accounts imported successfully"
            }
            return "Import requires confirmation (--force)"
        }, then: { [weak self] (msg: String) in
            self?.statusText = msg
            PaneControls.setText(self?.statusLabelHwnd, msg)
            TrayFleet.invalidate()
            self?.refreshFleets()
        })
    }

    private func copyToClipboard(_ text: String) {
        let utf16 = Array(text.utf16) + [0]
        let bytes = utf16.count * MemoryLayout<WCHAR>.stride
        guard let hMem = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) else { return }
        guard let pMem = GlobalLock(hMem) else { GlobalFree(hMem); return }
        utf16.withUnsafeBufferPointer { buf in
            memcpy(pMem, buf.baseAddress, bytes)
        }
        GlobalUnlock(hMem)
        if OpenClipboard(ctx?.host) {
            EmptyClipboard()
            SetClipboardData(UINT(CF_UNICODETEXT), hMem)
            CloseClipboard()
        }
    }

    private func refreshFleets() {
        fleets = TrayFleet.cachedFleets()
        if let ctx {
            layout(width: ctx.metrics.px(600), height: ctx.metrics.px(500))
        }
    }
}
