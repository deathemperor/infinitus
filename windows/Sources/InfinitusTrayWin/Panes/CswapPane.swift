import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Pane B — cswap engine: spec-driven config form (every key), resume diagnostics, updates, auto-resume.
public final class CswapPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "cswap",
        title: "cswap",
        glyph: "\u{E713}",
        tintRGB: (149, 165, 166),
        keywords: ["engine", "auto switch", "interval", "config", "threshold", "rotate", "claude", "provider", "update", "upgrade", "pypi", "nudge", "resume", "wake", "session"],
        section: .engines,
        badge: {
            PaneDescriptor.ProviderBadge(live: CswapLocator.locate() != nil)
        }
    )

    private var ctx: PaneContext?
    private var isLoading = false

    // Engine info controls
    private var enginePathLabelHwnd: HWND?

    // Resume reliability controls
    private var autoContinueLabelHwnd: HWND?
    private var crossSessionLabelHwnd: HWND?
    private var setAutoContinueBtnHwnd: HWND?
    private var setCrossSessionBtnHwnd: HWND?

    // Auto resume controls
    private var autoResumeCheckboxHwnd: HWND?
    private var explainResumeBtnHwnd: HWND?
    private var resumeExplainEditHwnd: HWND?

    // Engine updates controls
    private var versionLabelHwnd: HWND?
    private var checkUpdatesBtnHwnd: HWND?
    private var updateNowBtnHwnd: HWND?
    private var updateTranscriptEditHwnd: HWND?

    // Spec-driven form controls
    private var configEntries: [SettingEntry] = []
    private var entryControls: [String: HWND] = [:]       // key -> EDIT / COMBO / CHECKBOX
    private var entryErrorLabels: [String: HWND] = [:]     // key -> error STATIC
    private var draftValues: [String: String] = [:]

    private enum Cmd {
        static let setAutoContinue: Int32 = 1
        static let setCrossSession: Int32 = 2
        static let autoResume: Int32 = 3
        static let explainResume: Int32 = 4
        static let checkUpdates: Int32 = 5
        static let updateNow: Int32 = 6
        static let specBase: Int32 = 20
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        enginePathLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        autoContinueLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        setAutoContinueBtnHwnd = PaneControls.button("Set on", in: ctx, id: base + Cmd.setAutoContinue, x: 0, y: 0, w: 0, h: 0)
        crossSessionLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        setCrossSessionBtnHwnd = PaneControls.button("Set accept", in: ctx, id: base + Cmd.setCrossSession, x: 0, y: 0, w: 0, h: 0)

        autoResumeCheckboxHwnd = PaneControls.checkbox("Nudge limit-stopped sessions automatically", in: ctx, id: base + Cmd.autoResume, x: 0, y: 0, w: 0, h: 0)
        explainResumeBtnHwnd = PaneControls.button("Explain what it would do now", in: ctx, id: base + Cmd.explainResume, x: 0, y: 0, w: 0, h: 0)
        resumeExplainEditHwnd = PaneControls.edit(in: ctx, id: base + 10, x: 0, y: 0, w: 0, h: 0, multiline: true, readOnly: true)

        versionLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        checkUpdatesBtnHwnd = PaneControls.button("Check for updates", in: ctx, id: base + Cmd.checkUpdates, x: 0, y: 0, w: 0, h: 0)
        updateNowBtnHwnd = PaneControls.button("Update now", in: ctx, id: base + Cmd.updateNow, x: 0, y: 0, w: 0, h: 0)
        updateTranscriptEditHwnd = PaneControls.edit(in: ctx, id: base + 11, x: 0, y: 0, w: 0, h: 0, multiline: true, readOnly: true)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight

        var y = pad

        // SECTION: Engine info
        y = PaneControls.sectionHeader("Claude — cswap engine", in: ctx, y: y, width: width)
        if let h = enginePathLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(14)

        // SECTION: Resume reliability
        y = PaneControls.sectionHeader("Resume nudges — Claude Code side", in: ctx, y: y, width: width)
        if let l = autoContinueLabelHwnd, let b = setAutoContinueBtnHwnd {
            MoveWindow(l, pad, y + m.px(2), width - pad * 2 - m.px(100), fieldH, true)
            MoveWindow(b, width - pad - m.px(90), y, m.px(90), btnH, true)
        }
        y += btnH + m.px(8)

        if let l = crossSessionLabelHwnd, let b = setCrossSessionBtnHwnd {
            MoveWindow(l, pad, y + m.px(2), width - pad * 2 - m.px(100), fieldH, true)
            MoveWindow(b, width - pad - m.px(90), y, m.px(90), btnH, true)
        }
        y += btnH + m.px(14)

        // SECTION: Automatic resume
        y = PaneControls.sectionHeader("Automatic resume (this box)", in: ctx, y: y, width: width)
        if let h = autoResumeCheckboxHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(8)

        if let b = explainResumeBtnHwnd, let e = resumeExplainEditHwnd {
            MoveWindow(b, pad, y, m.px(220), btnH, true)
            y += btnH + m.px(6)
            MoveWindow(e, pad, y, width - pad * 2, m.px(60), true)
            y += m.px(64)
        }
        y += m.px(14)

        // SECTION: Engine updates
        y = PaneControls.sectionHeader("Engine updates", in: ctx, y: y, width: width)
        if let l = versionLabelHwnd {
            MoveWindow(l, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + m.px(8)

        if let c = checkUpdatesBtnHwnd, let u = updateNowBtnHwnd {
            MoveWindow(c, pad, y, m.px(140), btnH, true)
            MoveWindow(u, pad + m.px(150), y, m.px(110), btnH, true)
        }
        y += btnH + m.px(6)

        if let e = updateTranscriptEditHwnd {
            MoveWindow(e, pad, y, width - pad * 2, m.px(60), true)
            y += m.px(64)
        }
        y += m.px(18)

        // SECTION: Spec-driven forms
        syncSpecControls(width: width, startY: y, totalHeightOut: &y)
        PaneHost.setContentHeight(ctx.host, y)
    }

    private func syncSpecControls(width: Int32, startY: Int32, totalHeightOut: inout Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        var y = startY

        // Destroy previous spec controls
        for (_, h) in entryControls { DestroyWindow(h) }
        for (_, h) in entryErrorLabels { DestroyWindow(h) }
        entryControls.removeAll()
        entryErrorLabels.removeAll()

        guard !configEntries.isEmpty else {
            totalHeightOut = y
            return
        }

        // Group by prefix
        var grouped: [String: [SettingEntry]] = [:]
        var prefixes: [String] = []
        for e in configEntries {
            let pfx = String(e.key.split(separator: ".").first ?? "misc")
            if grouped[pfx] == nil { prefixes.append(pfx) }
            grouped[pfx, default: []].append(e)
        }

        var entryIdx = 0
        for pfx in prefixes {
            let title = SettingsFormLabels.sectionTitle(pfx)
            y = PaneControls.sectionHeader(title, in: ctx, y: y, width: width)

            for entry in grouped[pfx] ?? [] {
                let id = ctx.idBase + Cmd.specBase + Int32(entryIdx)
                let labelText = SettingsFormLabels.humanLabel(entry.key)

                switch entry.kind {
                case "bool":
                    let cb = PaneControls.checkbox(labelText, in: ctx, id: id, x: pad, y: y, w: width - pad * 2, h: fieldH)
                    if case .bool(let b) = entry.value {
                        PaneControls.setChecked(cb, b)
                    }
                    entryControls[entry.key] = cb
                    y += fieldH

                case "choice":
                    _ = PaneControls.label(labelText, in: ctx, x: pad, y: y + m.px(2), w: m.px(200), h: fieldH, transient: true)
                    var choices = ["(default)"]
                    choices.append(contentsOf: entry.choices ?? [])
                    let combo = PaneControls.combo(choices, in: ctx, id: id, x: pad + m.px(210), y: y, w: m.px(180), h: m.px(120))
                    let currentVal = entry.value.editableText
                    PaneControls.setComboSelection(combo, currentVal.isEmpty ? "(default)" : currentVal)
                    entryControls[entry.key] = combo
                    y += fieldH

                default:
                    _ = PaneControls.label(labelText, in: ctx, x: pad, y: y + m.px(2), w: m.px(200), h: fieldH, transient: true)
                    let edit = PaneControls.edit(in: ctx, id: id, x: pad + m.px(210), y: y, w: m.px(180), h: fieldH)
                    PaneControls.setText(edit, entry.value.editableText)
                    entryControls[entry.key] = edit
                    y += fieldH
                }

                // Help text
                if !entry.help.isEmpty {
                    y += m.px(2)
                    let helpH = PaneControls.helpText(entry.help, in: ctx, x: pad + m.px(8), y: y, width: width - pad * 2 - m.px(8))
                    y += helpH
                }

                // Error label placeholder
                let errH = PaneControls.label("", in: ctx, x: pad + m.px(8), y: y, w: width - pad * 2, h: m.px(16), caption: true, color: WinDark.destructive)
                entryErrorLabels[entry.key] = errH
                y += m.px(20)

                entryIdx += 1
            }
        }

        totalHeightOut = y + pad
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 800 }
        return ctx.metrics.px(max(800, Int32(configEntries.count) * 48 + 400))
    }

    public func activate() {
        loadData()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard !isLoading, let ctx else { return false }
        let rel = id - ctx.idBase

        switch rel {
        case Cmd.setAutoContinue:
            applyReliabilityKey("autoContinueAtUsageLimit", .bool(true))
            return true
        case Cmd.setCrossSession:
            applyReliabilityKey("crossSessionInbound", .string("accept"))
            return true
        case Cmd.autoResume:
            let on = PaneControls.checked(autoResumeCheckboxHwnd)
            _ = try? WinSettingsStore.update { $0.autoResume = on }
            return true
        case Cmd.explainResume:
            runExplainResume()
            return true
        case Cmd.checkUpdates:
            checkForUpdates()
            return true
        case Cmd.updateNow:
            performUpgrade()
            return true
        default:
            break
        }

        // Spec-driven entry command
        if rel >= Cmd.specBase {
            let entryIdx = Int(rel - Cmd.specBase)
            guard entryIdx >= 0 && entryIdx < configEntries.count else { return false }
            let entry = configEntries[entryIdx]

            if entry.kind == "bool" && code == UINT(BN_CLICKED) {
                let val = PaneControls.checked(entryControls[entry.key]) ? "true" : "false"
                commitEntry(entry, text: val)
                return true
            } else if entry.kind == "choice" && code == UINT(CBN_SELCHANGE) {
                var val = PaneControls.comboSelection(entryControls[entry.key])
                if val == "(default)" { val = "" }
                commitEntry(entry, text: val)
                return true
            } else if code == UINT(EN_KILLFOCUS) {
                let val = PaneControls.text(entryControls[entry.key])
                commitEntry(entry, text: val)
                return true
            }
        }

        return false
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    // MARK: - Data Loading

    private func loadData() {
        isLoading = true
        defer { isLoading = false }

        // Engine binary
        if let bin = CswapLocator.locate() {
            PaneControls.setText(enginePathLabelHwnd, "Engine: found at \(bin)")
        } else {
            PaneControls.setText(enginePathLabelHwnd, "Engine: not found (install via uv tool install claude-swap)")
        }

        // Resume reliability
        loadReliability()

        // Auto resume preference
        let settings = WinSettingsStore.load()
        PaneControls.setChecked(autoResumeCheckboxHwnd, settings.autoResume)

        // Version & specs
        ctx?.async({ () -> (String, ConfigList?) in
            var versionStr = "unknown"
            var list: ConfigList? = nil
            if let bin = CswapLocator.locate() {
                let cli = CswapCLI(binaryPath: bin)
                let sem = DispatchSemaphore(value: 0)
                Task {
                    versionStr = (try? await cli.version()) ?? "unknown"
                    list = try? await cli.configList()
                    sem.signal()
                }
                sem.wait()
            }
            return (versionStr, list)
        }, then: { [weak self] (ver: String, list: ConfigList?) in
            self?.applyVersionAndList(ver: ver, list: list)
        })
    }

    private func applyVersionAndList(ver: String, list: ConfigList?) {
        PaneControls.setText(versionLabelHwnd, "cswap \(ver)")
        if let list {
            configEntries = list.settings
            if let ctx {
                layout(width: ctx.metrics.px(600), height: ctx.metrics.px(600))
            }
        }
    }

    private func loadReliability() {
        let config = ClaudeCodeConfig.standard()
        let autoCont = (try? config.effectiveValue("autoContinueAtUsageLimit"))?.value
        let crossSess = (try? config.effectiveValue("crossSessionInbound"))?.value

        if case .bool(true) = autoCont {
            PaneControls.setText(autoContinueLabelHwnd, "✓ Auto-continue at usage limit: on")
            PaneControls.enable(setAutoContinueBtnHwnd, false)
        } else {
            PaneControls.setText(autoContinueLabelHwnd, "⚠ Auto-continue at usage limit: off")
            PaneControls.enable(setAutoContinueBtnHwnd, true)
        }

        if case .string(let s) = crossSess, s == "accept" {
            PaneControls.setText(crossSessionLabelHwnd, "✓ Cross-session messages: accept")
            PaneControls.enable(setCrossSessionBtnHwnd, false)
        } else {
            PaneControls.setText(crossSessionLabelHwnd, "⚠ Cross-session messages: not accept")
            PaneControls.enable(setCrossSessionBtnHwnd, true)
        }
    }

    private func applyReliabilityKey(_ key: String, _ val: JSONValue) {
        let config = ClaudeCodeConfig.standard()
        try? config.writeUserValue(key, val)
        loadReliability()
    }

    private func runExplainResume() {
        PaneControls.setText(resumeExplainEditHwnd, "Running resume explain…")
        ctx?.async({
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
            p.arguments = ["resume", "--explain"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }, then: { [weak self] text in
            PaneControls.setText(self?.resumeExplainEditHwnd, text.isEmpty ? "No active sessions." : text)
        })
    }

    private func checkForUpdates() {
        PaneControls.setText(updateTranscriptEditHwnd, "Checking PyPI for claude-swap…")
        ctx?.async({
            guard let url = URL(string: "https://pypi.org/pypi/claude-swap/json"),
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = obj["info"] as? [String: Any],
                  let latest = info["version"] as? String else {
                return "PyPI check failed"
            }
            return "Latest on PyPI: \(latest)"
        }, then: { [weak self] res in
            PaneControls.setText(self?.updateTranscriptEditHwnd, res)
        })
    }

    private func performUpgrade() {
        PaneControls.setText(updateTranscriptEditHwnd, "Upgrading cswap…")
        ctx?.async({ () -> String in
            guard let bin = CswapLocator.locate() else { return "cswap not found" }
            let cli = CswapCLI(binaryPath: bin)
            let sem = DispatchSemaphore(value: 0)
            var res = "Upgrade failed to start"
            Task {
                if let (status, transcript) = try? await cli.upgrade() {
                    res = "Exit \(status):\n\(transcript)"
                }
                sem.signal()
            }
            sem.wait()
            return res
        }, then: { [weak self] (res: String) in
            PaneControls.setText(self?.updateTranscriptEditHwnd, res)
            self?.loadData()
        })
    }

    private func commitEntry(_ entry: SettingEntry, text: String) {
        let draft = SettingDraft.validate(text, for: entry)
        switch draft {
        case .invalid(let why):
            if let lbl = entryErrorLabels[entry.key] {
                PaneControls.setText(lbl, why)
            }
        case .unset:
            if let lbl = entryErrorLabels[entry.key] { PaneControls.setText(lbl, "") }
            executeConfig(key: entry.key, value: nil)
        case .valid(let val):
            if let lbl = entryErrorLabels[entry.key] { PaneControls.setText(lbl, "") }
            executeConfig(key: entry.key, value: val)
        }
    }

    private func executeConfig(key: String, value: String?) {
        ctx?.async({
            guard let bin = CswapLocator.locate() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = (value == nil) ? ["config", "unset", key] : ["config", "set", key, value!]
            try? p.run()
            p.waitUntilExit()
        }, then: { [weak self] in
            self?.loadData()
        })
    }
}
