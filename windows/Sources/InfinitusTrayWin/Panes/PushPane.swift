import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Away-push notification settings pane.
/// Slack & Telegram configuration over `cswap notify`, secrets on stdin only,
/// masked in output. 5 trigger checkboxes backed by WinSettings (PushTriggers.Flags).
public final class PushPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "push",
        title: "Push",
        glyph: "\u{E95A}",
        tintRGB: (220, 60, 60),
        keywords: ["slack", "telegram", "webhook", "notification", "push", "away"]
    )

    private var ctx: PaneContext?

    // Away push info
    private var awayInfoHwnd: HWND?

    // 5 trigger toggles
    private var triggerHeaderHwnd: HWND?
    private var daemonHelp1Hwnd: HWND?
    private var sessionsDoneHwnd: HWND?
    private var sessionsDoneHelpHwnd: HWND?
    private var allDeadHwnd: HWND?
    private var lastAliveHwnd: HWND?
    private var lastAliveHelpHwnd: HWND?
    private var waitingHwnd: HWND?
    private var waitingHelpHwnd: HWND?
    private var awsLoginHwnd: HWND?
    private var awsLoginHelpHwnd: HWND?

    // Slack section
    private var slackHeaderHwnd: HWND?
    private var slackStatusLabelHwnd: HWND?
    private var slackUrlEditHwnd: HWND?
    private var slackSaveBtnHwnd: HWND?
    private var slackRemoveBtnHwnd: HWND?
    private var discordHelpHwnd: HWND?

    // Telegram section
    private var tgHeaderHwnd: HWND?
    private var tgStatusLabelHwnd: HWND?
    private var tgTokenEditHwnd: HWND?
    private var tgChatIdEditHwnd: HWND?
    private var tgSaveBtnHwnd: HWND?
    private var tgRemoveBtnHwnd: HWND?

    // Test section
    private var testPushBtnHwnd: HWND?
    private var testReplyLabelHwnd: HWND?

    // Dynamic UI heights
    private var sessionsDoneHelpH: Int32 = 0
    private var lastAliveHelpH: Int32 = 0
    private var waitingHelpH: Int32 = 0
    private var awsLoginHelpH: Int32 = 0
    private var discordHelpH: Int32 = 0
    private var calculatedHeight: Int32 = 700

    // Local command ID offsets relative to ctx.idBase
    private enum Cmd {
        static let pushSessionsDone: Int32 = 10
        static let pushAllDead: Int32 = 11
        static let pushLastAlive: Int32 = 12
        static let pushWaiting: Int32 = 13
        static let pushAwsLogin: Int32 = 14
        static let slackSave: Int32 = 20
        static let slackRemove: Int32 = 21
        static let tgSave: Int32 = 30
        static let tgRemove: Int32 = 31
        static let testPush: Int32 = 40
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        awayInfoHwnd = PaneControls.label(
            "After every switch, cswap pushes the new account's alias to each channel below. " +
            "Secrets are stored by cswap in notify.json (owner-only) and shown masked. Infinitus never keeps a copy.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        triggerHeaderHwnd = PaneControls.label("Also push when", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        daemonHelp1Hwnd = PaneControls.label(
            "These apply to the mirror daemon (infinitus-win serve); it re-reads them on start.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        sessionsDoneHwnd = PaneControls.checkbox("All sessions finish working", in: ctx, id: base + Cmd.pushSessionsDone, x: 0, y: 0, w: 0, h: 0)
        sessionsDoneHelpHwnd = PaneControls.label(
            "Fires once when every live Claude Code session has been idle for two refresh passes — turn gaps don't count.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        allDeadHwnd = PaneControls.checkbox("All accounts are exhausted", in: ctx, id: base + Cmd.pushAllDead, x: 0, y: 0, w: 0, h: 0)

        let warnPctInt = Int(PushTriggers.warnPct)
        lastAliveHwnd = PaneControls.checkbox("The last alive account nears its limit", in: ctx, id: base + Cmd.pushLastAlive, x: 0, y: 0, w: 0, h: 0)
        lastAliveHelpHwnd = PaneControls.label(
            "Warns once when only one account still has quota and it crosses \(warnPctInt)%.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        waitingHwnd = PaneControls.checkbox("A session waits on you", in: ctx, id: base + Cmd.pushWaiting, x: 0, y: 0, w: 0, h: 0)
        waitingHelpHwnd = PaneControls.label(
            "Fires once per session when it stops at a permission prompt or a question.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        awsLoginHwnd = PaneControls.checkbox("A session needs an AWS login", in: ctx, id: base + Cmd.pushAwsLogin, x: 0, y: 0, w: 0, h: 0)
        awsLoginHelpHwnd = PaneControls.label(
            "Fires once per session and profile when an aws command fails on an expired sign-in.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        // Slack
        slackHeaderHwnd = PaneControls.label("Slack", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        slackStatusLabelHwnd = PaneControls.label("Configured: loading…", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        slackUrlEditHwnd = PaneControls.edit(in: ctx, id: base + 101, x: 0, y: 0, w: 0, h: 0, password: true)
        slackSaveBtnHwnd = PaneControls.button("Save webhook", in: ctx, id: base + Cmd.slackSave, x: 0, y: 0, w: 0, h: 0)
        slackRemoveBtnHwnd = PaneControls.button("Remove", in: ctx, id: base + Cmd.slackRemove, x: 0, y: 0, w: 0, h: 0, destructive: true)
        discordHelpHwnd = PaneControls.label(
            "A Discord webhook works here too — append /slack to the Discord webhook URL.",
            in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true
        )

        // Telegram
        tgHeaderHwnd = PaneControls.label("Telegram", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        tgStatusLabelHwnd = PaneControls.label("Configured: loading…", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        tgTokenEditHwnd = PaneControls.edit(in: ctx, id: base + 102, x: 0, y: 0, w: 0, h: 0, password: true)
        tgChatIdEditHwnd = PaneControls.edit(in: ctx, id: base + 103, x: 0, y: 0, w: 0, h: 0)
        tgSaveBtnHwnd = PaneControls.button("Save bot", in: ctx, id: base + Cmd.tgSave, x: 0, y: 0, w: 0, h: 0)
        tgRemoveBtnHwnd = PaneControls.button("Remove", in: ctx, id: base + Cmd.tgRemove, x: 0, y: 0, w: 0, h: 0, destructive: true)

        // Test
        testPushBtnHwnd = PaneControls.button("Send test push", in: ctx, id: base + Cmd.testPush, x: 0, y: 0, w: 0, h: 0)
        testReplyLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        loadTriggerToggles()
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let innerW = max(100, width - pad * 2)

        var y = pad

        // Away info
        if let h = awayInfoHwnd {
            let measuredH = m.px(34)
            MoveWindow(h, pad, y, innerW, measuredH, true)
            y += measuredH + m.px(14)
        }

        // Trigger section
        if let h = triggerHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(22)
        }
        if let h = daemonHelp1Hwnd {
            MoveWindow(h, pad, y, innerW, m.px(16), true)
            y += m.px(20)
        }

        func placeCheckWithHelp(check: HWND?, help: HWND?, helpText: String) {
            if let check {
                MoveWindow(check, pad, y, innerW, fieldH, true)
                y += fieldH + m.px(2)
            }
            if let help {
                let hH = m.px(18)
                MoveWindow(help, pad + m.px(20), y, innerW - m.px(20), hH, true)
                y += hH + m.px(8)
            }
        }

        placeCheckWithHelp(check: sessionsDoneHwnd, help: sessionsDoneHelpHwnd, helpText: "")
        if let h = allDeadHwnd {
            MoveWindow(h, pad, y, innerW, fieldH, true)
            y += fieldH + m.px(8)
        }
        placeCheckWithHelp(check: lastAliveHwnd, help: lastAliveHelpHwnd, helpText: "")
        placeCheckWithHelp(check: waitingHwnd, help: waitingHelpHwnd, helpText: "")
        placeCheckWithHelp(check: awsLoginHwnd, help: awsLoginHelpHwnd, helpText: "")

        y += m.px(14)

        // Slack section
        if let h = slackHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }
        if let h = slackStatusLabelHwnd {
            MoveWindow(h, pad, y, innerW, fieldH, true)
            y += fieldH + m.px(6)
        }
        if let h = slackUrlEditHwnd {
            MoveWindow(h, pad, y, min(innerW, m.px(420)), fieldH, true)
            y += fieldH + m.px(8)
        }
        let btnW = m.px(110)
        if let sBtn = slackSaveBtnHwnd {
            MoveWindow(sBtn, pad, y, btnW, btnH, true)
        }
        if let rBtn = slackRemoveBtnHwnd {
            MoveWindow(rBtn, pad + btnW + m.px(8), y, m.px(80), btnH, true)
        }
        y += btnH + m.px(6)
        if let h = discordHelpHwnd {
            MoveWindow(h, pad, y, innerW, m.px(18), true)
            y += m.px(24)
        }

        // Telegram section
        if let h = tgHeaderHwnd {
            MoveWindow(h, pad, y, innerW, m.px(20), true)
            y += m.px(24)
        }
        if let h = tgStatusLabelHwnd {
            MoveWindow(h, pad, y, innerW, fieldH, true)
            y += fieldH + m.px(6)
        }
        if let h = tgTokenEditHwnd {
            MoveWindow(h, pad, y, min(innerW, m.px(340)), fieldH, true)
            y += fieldH + m.px(6)
        }
        if let h = tgChatIdEditHwnd {
            MoveWindow(h, pad, y, min(innerW, m.px(200)), fieldH, true)
            y += fieldH + m.px(8)
        }
        if let sBtn = tgSaveBtnHwnd {
            MoveWindow(sBtn, pad, y, btnW, btnH, true)
        }
        if let rBtn = tgRemoveBtnHwnd {
            MoveWindow(rBtn, pad + btnW + m.px(8), y, m.px(80), btnH, true)
        }
        y += btnH + m.px(20)

        // Test section
        if let h = testPushBtnHwnd {
            MoveWindow(h, pad, y, m.px(130), btnH, true)
            y += btnH + m.px(8)
        }
        if let h = testReplyLabelHwnd {
            MoveWindow(h, pad, y, innerW, m.px(30), true)
            y += m.px(36)
        }

        calculatedHeight = y + pad
        PaneHost.setContentHeight(ctx.host, calculatedHeight)
    }

    public func activate() {
        loadTriggerToggles()
        reloadStatus()
    }

    public func deactivate() {
        // Clear secret fields immediately when leaving pane
        PaneControls.setText(slackUrlEditHwnd, "")
        PaneControls.setText(tgTokenEditHwnd, "")
    }

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase

        switch id - base {
        case Cmd.pushSessionsDone:
            let on = PaneControls.checked(sessionsDoneHwnd)
            _ = try? WinSettingsStore.update { $0.pushSessionsDone = on }
            return true
        case Cmd.pushAllDead:
            let on = PaneControls.checked(allDeadHwnd)
            _ = try? WinSettingsStore.update { $0.pushAllDead = on }
            return true
        case Cmd.pushLastAlive:
            let on = PaneControls.checked(lastAliveHwnd)
            _ = try? WinSettingsStore.update { $0.pushLastAlive = on }
            return true
        case Cmd.pushWaiting:
            let on = PaneControls.checked(waitingHwnd)
            _ = try? WinSettingsStore.update { $0.pushWaiting = on }
            return true
        case Cmd.pushAwsLogin:
            let on = PaneControls.checked(awsLoginHwnd)
            _ = try? WinSettingsStore.update { $0.pushAwsLogin = on }
            return true
        case Cmd.slackSave:
            saveSlack()
            return true
        case Cmd.slackRemove:
            removeChannel("slack")
            return true
        case Cmd.tgSave:
            saveTelegram()
            return true
        case Cmd.tgRemove:
            removeChannel("telegram")
            return true
        case Cmd.testPush:
            runTestPush()
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    public func contentHeight(width: Int32) -> Int32 {
        calculatedHeight
    }

    // MARK: - Internal logic
    private func loadTriggerToggles() {
        let s = WinSettingsStore.load()
        PaneControls.setChecked(sessionsDoneHwnd, s.pushSessionsDone)
        PaneControls.setChecked(allDeadHwnd, s.pushAllDead)
        PaneControls.setChecked(lastAliveHwnd, s.pushLastAlive)
        PaneControls.setChecked(waitingHwnd, s.pushWaiting)
        PaneControls.setChecked(awsLoginHwnd, s.pushAwsLogin)
    }

    private func reloadStatus() {
        guard let ctx else { return }
        guard let binary = CswapLocator.locate() else {
            PaneControls.setText(slackStatusLabelHwnd, "Configured: cswap not found")
            PaneControls.setText(tgStatusLabelHwnd, "Configured: cswap not found")
            EnableWindow(slackSaveBtnHwnd, false)
            EnableWindow(slackRemoveBtnHwnd, false)
            EnableWindow(tgSaveBtnHwnd, false)
            EnableWindow(tgRemoveBtnHwnd, false)
            EnableWindow(testPushBtnHwnd, false)
            return
        }

        EnableWindow(slackSaveBtnHwnd, true)
        EnableWindow(slackRemoveBtnHwnd, true)
        EnableWindow(tgSaveBtnHwnd, true)
        EnableWindow(tgRemoveBtnHwnd, true)
        EnableWindow(testPushBtnHwnd, true)

        ctx.async({
            let cli = CswapCLI(binaryPath: binary)
            let sema = DispatchSemaphore(value: 0)
            var status: NotifyStatus? = nil
            Task {
                status = try? await cli.notifyStatus()
                sema.signal()
            }
            sema.wait()
            return status
        }, then: { [weak self] status in
            guard let self else { return }
            if let status {
                let slackText = status.slackWebhookUrl ?? "no"
                PaneControls.setText(self.slackStatusLabelHwnd, "Configured:  \(slackText)")

                let tgText: String
                if let token = status.telegramBotToken {
                    tgText = "\(token)   chat \(status.telegramChatId ?? "?")"
                } else {
                    tgText = "no"
                }
                PaneControls.setText(self.tgStatusLabelHwnd, "Configured:  \(tgText)")
            } else {
                PaneControls.setText(self.slackStatusLabelHwnd, "Configured:  no")
                PaneControls.setText(self.tgStatusLabelHwnd, "Configured:  no")
            }
        })
    }

    private func saveSlack() {
        guard let ctx else { return }
        let raw = PaneControls.text(slackUrlEditHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("https://") else {
            PaneControls.setText(testReplyLabelHwnd, "Webhook URL must start with https://")
            return
        }
        guard let binary = CswapLocator.locate() else { return }

        PaneControls.setText(slackUrlEditHwnd, "")
        PaneControls.setText(testReplyLabelHwnd, "Saving Slack webhook…")

        ctx.async({
            let cli = CswapCLI(binaryPath: binary)
            let sema = DispatchSemaphore(value: 0)
            var reply = ""
            Task {
                do {
                    _ = try await cli.run(["notify", "slack", "-"], stdin: raw)
                    reply = "Slack webhook saved."
                } catch {
                    reply = "Failed to save: \(error)"
                }
                sema.signal()
            }
            sema.wait()
            return reply
        }, then: { [weak self] reply in
            self?.applyResult(reply)
            self?.reloadStatus()
        })
    }

    private func saveTelegram() {
        guard let ctx else { return }
        let token = PaneControls.text(tgTokenEditHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = PaneControls.text(tgChatIdEditHwnd).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty, !chat.isEmpty else {
            PaneControls.setText(testReplyLabelHwnd, "Telegram needs both a bot token and a chat id")
            return
        }
        guard let binary = CswapLocator.locate() else { return }

        PaneControls.setText(tgTokenEditHwnd, "")
        PaneControls.setText(testReplyLabelHwnd, "Saving Telegram bot…")

        ctx.async({
            let cli = CswapCLI(binaryPath: binary)
            let sema = DispatchSemaphore(value: 0)
            var reply = ""
            Task {
                do {
                    _ = try await cli.run(["notify", "telegram", "-", chat], stdin: token)
                    reply = "Telegram bot saved."
                } catch {
                    reply = "Failed to save: \(error)"
                }
                sema.signal()
            }
            sema.wait()
            return reply
        }, then: { [weak self] reply in
            self?.applyResult(reply)
            self?.reloadStatus()
        })
    }

    private func removeChannel(_ channel: String) {
        guard let ctx else { return }
        guard let binary = CswapLocator.locate() else { return }

        PaneControls.setText(testReplyLabelHwnd, "Removing \(channel)…")

        ctx.async({
            let cli = CswapCLI(binaryPath: binary)
            let sema = DispatchSemaphore(value: 0)
            var reply = ""
            Task {
                do {
                    _ = try await cli.run(["notify", "off", channel])
                    reply = "Removed \(channel)."
                } catch {
                    reply = "Remove failed: \(error)"
                }
                sema.signal()
            }
            sema.wait()
            return reply
        }, then: { [weak self] reply in
            self?.applyResult(reply)
            self?.reloadStatus()
        })
    }

    private func runTestPush() {
        guard let ctx else { return }
        guard let binary = CswapLocator.locate() else { return }

        PaneControls.setText(testReplyLabelHwnd, "Sending test push…")

        ctx.async({
            let cli = CswapCLI(binaryPath: binary)
            let sema = DispatchSemaphore(value: 0)
            var reply = ""
            Task {
                do {
                    let out = try await cli.run(["notify", "test"])
                    reply = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if reply.isEmpty { reply = "Test push sent." }
                } catch {
                    reply = "Test push failed — check the channel config"
                }
                sema.signal()
            }
            sema.wait()
            return reply
        }, then: { [weak self] reply in
            self?.applyResult(reply)
        })
    }

    private func applyResult(_ msg: String) {
        PaneControls.setText(testReplyLabelHwnd, msg)
    }
}
