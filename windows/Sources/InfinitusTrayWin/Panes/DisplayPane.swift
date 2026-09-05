import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Display settings pane for Windows.
///
/// Configures tray tooltip formatting (TitlePrefs + TitleFormatter with live preview),
/// accounts panel sort order, balloon notifications, autostart, refresh interval, and keep-awake.
/// Every control writes immediately to WinSettingsStore.
public final class DisplayPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "display",
        title: "Display",
        glyph: "\u{E7F4}", // Segoe Fluent TaskbarSettings / Settings
        tintRGB: (150, 90, 220), // Mac purple
        keywords: ["layout", "popup", "size", "compact", "menu bar", "icon", "title", "tray", "tooltip", "preview", "refresh", "autostart", "awake", "balloon"],
        section: .general
    )

    private var ctx: PaneContext?

    // Tray section HWNDs
    private var iconOnlyHwnd: HWND?
    private var showAccountNameHwnd: HWND?
    private var titlePctComboHwnd: HWND?
    private var titleResetComboHwnd: HWND?
    private var titleScopedHwnd: HWND?
    private var titleRemainingHwnd: HWND?
    private var previewLabelHwnd: HWND?

    // Accounts section HWNDs
    private var popupLayoutLabelHwnd: HWND?
    private var popupLayoutComboHwnd: HWND?
    private var popupLayoutHelpHwnd: HWND?
    private var sortByHeadroomHwnd: HWND?

    // Notifications section HWNDs
    private var balloonsHwnd: HWND?

    // System section HWNDs
    private var autostartHwnd: HWND?
    private var autostartStatusHwnd: HWND?
    private var refreshIntervalComboHwnd: HWND?
    private var keepAwakeHwnd: HWND?

    // Static labels that need repositioning
    private var trayHeaderHwnd: HWND?
    private var iconOnlyHelpHwnd: HWND?
    private var titlePctLabelHwnd: HWND?
    private var titleResetLabelHwnd: HWND?
    private var titleResetHelpHwnd: HWND?
    private var titleRemainingHelpHwnd: HWND?
    private var previewHeaderHwnd: HWND?
    private var accountsHeaderHwnd: HWND?
    private var accountsHelpHwnd: HWND?
    private var notifHeaderHwnd: HWND?
    private var notifHelpHwnd: HWND?
    private var systemHeaderHwnd: HWND?
    private var autostartHelpHwnd: HWND?
    private var refreshLabelHwnd: HWND?
    private var refreshHelpHwnd: HWND?
    private var keepAwakeHelpHwnd: HWND?

    // Command ID offsets relative to ctx.idBase
    private enum Cmd {
        static let iconOnly: Int32 = 1
        static let showAccountName: Int32 = 2
        static let titlePct: Int32 = 3
        static let titleReset: Int32 = 4
        static let titleScoped: Int32 = 5
        static let titleRemaining: Int32 = 6
        static let sortByHeadroom: Int32 = 7
        static let balloons: Int32 = 8
        static let autostart: Int32 = 9
        static let refreshInterval: Int32 = 10
        static let keepAwake: Int32 = 11
        static let popupLayout: Int32 = 12
    }

    private let pctOptions = ["off", "5h", "7d", "both"]
    private let resetOptions = ["off", "countdown", "clock"]
    private let refreshOptions = [30, 60, 300]
    private let layoutOptions = ["Wide rows", "Stacked cards", "Horizontal cards"]
    private let layoutKeys = ["wide", "stacked", "hstack"]

    private static let sampleAccount = Account(
        number: 1,
        email: "you@example.com",
        active: true,
        usage: Usage(
            fiveHour: UsageWindow(pct: 21, resetsAt: "2999-01-01T00:00:00Z"),
            sevenDay: UsageWindow(pct: 68, resetsAt: "2999-01-01T00:00:00Z"),
            scoped: [UsageWindow(pct: 74, resetsAt: "2999-01-01T00:00:00Z", name: "Fable")]
        ),
        alias: "alpha"
    )

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // Headers and help labels
        trayHeaderHwnd = PaneControls.label("Tray", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        iconOnlyHwnd = PaneControls.checkbox("Tray tooltip shows only the icon", in: ctx, id: base + Cmd.iconOnly, x: 0, y: 0, w: 0, h: 0)
        iconOnlyHelpHwnd = PaneControls.label("Just the session counts — no account name or percentages. The settings below return when this is off.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        showAccountNameHwnd = PaneControls.checkbox("Show account name in the tooltip", in: ctx, id: base + Cmd.showAccountName, x: 0, y: 0, w: 0, h: 0)

        titlePctLabelHwnd = PaneControls.label("Title percentage:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        titlePctComboHwnd = PaneControls.combo(pctOptions, in: ctx, id: base + Cmd.titlePct, x: 0, y: 0, w: 0, h: 0)

        titleResetLabelHwnd = PaneControls.label("Reset time:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        titleResetComboHwnd = PaneControls.combo(resetOptions, in: ctx, id: base + Cmd.titleReset, x: 0, y: 0, w: 0, h: 0)
        titleResetHelpHwnd = PaneControls.label("When the active account's fuller window resets — as a countdown (2h14m) or a clock time (20:29).", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        titleScopedHwnd = PaneControls.checkbox("Show model limits", in: ctx, id: base + Cmd.titleScoped, x: 0, y: 0, w: 0, h: 0)
        titleRemainingHwnd = PaneControls.checkbox("Count remaining, not used", in: ctx, id: base + Cmd.titleRemaining, x: 0, y: 0, w: 0, h: 0)
        titleRemainingHelpHwnd = PaneControls.label("Flips the percentages to what's left. The accounts panel gauges already count remaining.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        previewHeaderHwnd = PaneControls.label("Live Preview:", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        previewLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, color: WinDark.warmTint)

        accountsHeaderHwnd = PaneControls.label("Accounts panel", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        popupLayoutLabelHwnd = PaneControls.label("Panel layout:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        popupLayoutComboHwnd = PaneControls.combo(layoutOptions, in: ctx, id: base + Cmd.popupLayout, x: 0, y: 0, w: 0, h: 0)
        popupLayoutHelpHwnd = PaneControls.label("Wide rows (table grid), Stacked cards, or Horizontal cards side by side.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        sortByHeadroomHwnd = PaneControls.checkbox("Sort rows by headroom (active and next first)", in: ctx, id: base + Cmd.sortByHeadroom, x: 0, y: 0, w: 0, h: 0)
        accountsHelpHwnd = PaneControls.label("Display only — slot numbers don't move.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        notifHeaderHwnd = PaneControls.label("Notifications", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        balloonsHwnd = PaneControls.checkbox("Show balloon notifications", in: ctx, id: base + Cmd.balloons, x: 0, y: 0, w: 0, h: 0)
        notifHelpHwnd = PaneControls.label("Two events only: a session starts waiting on you, and a session stops while it was busy. Routine busy/idle churn is never announced.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        systemHeaderHwnd = PaneControls.label("System", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        autostartHwnd = PaneControls.checkbox("Start Infinitus Tray with Windows", in: ctx, id: base + Cmd.autostart, x: 0, y: 0, w: 0, h: 0)
        autostartStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.destructive)
        autostartHelpHwnd = PaneControls.label("Registers this executable's current path. A debug build registers .build\\debug — use windows\\install.ps1 -Autostart for the release binary.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        refreshLabelHwnd = PaneControls.label("Refresh interval:", in: ctx, x: 0, y: 0, w: 0, h: 0)
        let refreshStrings = refreshOptions.map { "\($0) seconds" }
        refreshIntervalComboHwnd = PaneControls.combo(refreshStrings, in: ctx, id: base + Cmd.refreshInterval, x: 0, y: 0, w: 0, h: 0)
        refreshHelpHwnd = PaneControls.label("How often the accounts panel re-asks the engine.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        keepAwakeHwnd = PaneControls.checkbox("Keep Windows awake while sessions are working", in: ctx, id: base + Cmd.keepAwake, x: 0, y: 0, w: 0, h: 0)
        keepAwakeHelpHwnd = PaneControls.label("Holds a power request while any Claude Code session is mid-turn. The display may still sleep; the machine won't.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let colW = m.labelColumn
        let fieldH = m.fieldHeight
        let gap = m.px(6)
        let fullW = width - pad * 2

        func measureHelp(_ text: String, w: Int32) -> Int32 {
            var rect = RECT(left: 0, top: 0, right: w, bottom: 0)
            let dc = GetDC(ctx.host)
            if let dc {
                let oldFont = ctx.captionFont.map { SelectObject(dc, $0) }
                var textWide = Array(text.utf16) + [0]
                _ = textWide.withUnsafeMutableBufferPointer { buf in
                    DrawTextW(dc, buf.baseAddress, Int32(buf.count - 1), &rect, UINT(DT_CALCRECT | DT_WORDBREAK))
                }
                if let oldFont { SelectObject(dc, oldFont) }
                ReleaseDC(ctx.host, dc)
            }
            return max(m.px(16), rect.bottom - rect.top)
        }

        var y = pad

        // SECTION: Tray
        if let h = trayHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if let h = iconOnlyHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(2)

        let iconHelpText = "Just the session counts — no account name or percentages. The settings below return when this is off."
        let iconHelpH = measureHelp(iconHelpText, w: fullW - m.px(20))
        if let h = iconOnlyHelpHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), iconHelpH, true) }
        y += iconHelpH + gap * 2

        if let h = showAccountNameHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), fieldH, true) }
        y += fieldH + gap

        if let lbl = titlePctLabelHwnd, let cb = titlePctComboHwnd {
            MoveWindow(lbl, pad + m.px(20), y + m.px(3), colW, fieldH, true)
            MoveWindow(cb, pad + m.px(20) + colW, y, m.px(160), m.px(140), true)
        }
        y += fieldH + gap

        if let lbl = titleResetLabelHwnd, let cb = titleResetComboHwnd {
            MoveWindow(lbl, pad + m.px(20), y + m.px(3), colW, fieldH, true)
            MoveWindow(cb, pad + m.px(20) + colW, y, m.px(160), m.px(140), true)
        }
        y += fieldH + m.px(2)

        let resetHelpText = "When the active account's fuller window resets — as a countdown (2h14m) or a clock time (20:29)."
        let resetHelpH = measureHelp(resetHelpText, w: fullW - m.px(20))
        if let h = titleResetHelpHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), resetHelpH, true) }
        y += resetHelpH + gap

        if let h = titleScopedHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), fieldH, true) }
        y += fieldH + gap

        if let h = titleRemainingHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), fieldH, true) }
        y += fieldH + m.px(2)

        let remHelpText = "Flips the percentages to what's left. The accounts panel gauges already count remaining."
        let remHelpH = measureHelp(remHelpText, w: fullW - m.px(20))
        if let h = titleRemainingHelpHwnd { MoveWindow(h, pad + m.px(20), y, fullW - m.px(20), remHelpH, true) }
        y += remHelpH + gap * 2

        // Live Preview Row
        if let h = previewHeaderHwnd { MoveWindow(h, pad, y, m.px(100), fieldH, true) }
        if let h = previewLabelHwnd { MoveWindow(h, pad + m.px(110), y, fullW - m.px(110), fieldH, true) }
        y += fieldH + gap * 3

        // SECTION: Accounts panel
        if let h = accountsHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if let lbl = popupLayoutLabelHwnd, let cb = popupLayoutComboHwnd {
            MoveWindow(lbl, pad, y + m.px(3), colW, fieldH, true)
            MoveWindow(cb, pad + colW, y, m.px(160), m.px(140), true)
        }
        y += fieldH + m.px(2)

        let layoutHelpText = "Wide rows (table grid), Stacked cards, or Horizontal cards side by side."
        let layoutHelpH = measureHelp(layoutHelpText, w: fullW)
        if let h = popupLayoutHelpHwnd { MoveWindow(h, pad, y, fullW, layoutHelpH, true) }
        y += layoutHelpH + gap * 2

        if let h = sortByHeadroomHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(2)

        let accHelpText = "Display only — slot numbers don't move."
        let accHelpH = measureHelp(accHelpText, w: fullW)
        if let h = accountsHelpHwnd { MoveWindow(h, pad, y, fullW, accHelpH, true) }
        y += accHelpH + gap * 3

        // SECTION: Notifications
        if let h = notifHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if let h = balloonsHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(2)

        let notifHelpText = "Two events only: a session starts waiting on you, and a session stops while it was busy. Routine busy/idle churn is never announced."
        let notifHelpH = measureHelp(notifHelpText, w: fullW)
        if let h = notifHelpHwnd { MoveWindow(h, pad, y, fullW, notifHelpH, true) }
        y += notifHelpH + gap * 3

        // SECTION: System
        if let h = systemHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if let h = autostartHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(2)

        let autostartHelpText = "Registers this executable's current path. A debug build registers .build\\debug — use windows\\install.ps1 -Autostart for the release binary."
        let autoHelpH = measureHelp(autostartHelpText, w: fullW)
        if let h = autostartHelpHwnd { MoveWindow(h, pad, y, fullW, autoHelpH, true) }
        y += autoHelpH

        if let h = autostartStatusHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(20) + gap

        if let lbl = refreshLabelHwnd, let cb = refreshIntervalComboHwnd {
            MoveWindow(lbl, pad, y + m.px(3), colW, fieldH, true)
            MoveWindow(cb, pad + colW, y, m.px(160), m.px(140), true)
        }
        y += fieldH + m.px(2)

        let refHelpText = "How often the accounts panel re-asks the engine."
        let refHelpH = measureHelp(refHelpText, w: fullW)
        if let h = refreshHelpHwnd { MoveWindow(h, pad, y, fullW, refHelpH, true) }
        y += refHelpH + gap * 2

        if let h = keepAwakeHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(2)

        let awakeHelpText = "Holds a power request while any Claude Code session is mid-turn. The display may still sleep; the machine won't."
        let awakeHelpH = measureHelp(awakeHelpText, w: fullW)
        if let h = keepAwakeHelpHwnd { MoveWindow(h, pad, y, fullW, awakeHelpH, true) }
        y += awakeHelpH + pad

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 890 }
        return ctx.metrics.px(890)
    }

    public func activate() {
        let s = WinSettingsStore.load()

        PaneControls.setChecked(iconOnlyHwnd, s.titleIconOnly)
        PaneControls.setChecked(showAccountNameHwnd, s.showAccountName)
        PaneControls.setComboSelection(titlePctComboHwnd, s.titlePct)
        PaneControls.setComboSelection(titleResetComboHwnd, s.titleReset)
        PaneControls.setChecked(titleScopedHwnd, s.titleScoped)
        PaneControls.setChecked(titleRemainingHwnd, s.titleRemaining)

        let layoutIdx = layoutKeys.firstIndex(of: s.popupLayout) ?? 0
        PaneControls.setComboSelection(popupLayoutComboHwnd, layoutOptions[layoutIdx])

        PaneControls.setChecked(sortByHeadroomHwnd, s.sortByHeadroom)
        PaneControls.setChecked(balloonsHwnd, s.trayBalloonsEnabled)

        PaneControls.setChecked(autostartHwnd, TrayAutostart.isEnabled())
        PaneControls.setText(autostartStatusHwnd, "")

        let intervalStr = "\(s.refreshIntervalSeconds) seconds"
        PaneControls.setComboSelection(refreshIntervalComboHwnd, intervalStr)

        PaneControls.setChecked(keepAwakeHwnd, s.keepAwake)

        updateTitleControlsEnabled(!s.titleIconOnly)
        updatePreview()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase

        switch rel {
        case Cmd.iconOnly:
            let val = PaneControls.checked(iconOnlyHwnd)
            _ = try? WinSettingsStore.update { $0.titleIconOnly = val }
            updateTitleControlsEnabled(!val)
            updatePreview()
            return true

        case Cmd.showAccountName:
            let val = PaneControls.checked(showAccountNameHwnd)
            _ = try? WinSettingsStore.update { $0.showAccountName = val }
            updatePreview()
            return true

        case Cmd.titlePct:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(titlePctComboHwnd)
                _ = try? WinSettingsStore.update { $0.titlePct = sel }
                updatePreview()
            }
            return true

        case Cmd.titleReset:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(titleResetComboHwnd)
                _ = try? WinSettingsStore.update { $0.titleReset = sel }
                updatePreview()
            }
            return true

        case Cmd.titleScoped:
            let val = PaneControls.checked(titleScopedHwnd)
            _ = try? WinSettingsStore.update { $0.titleScoped = val }
            updatePreview()
            return true

        case Cmd.titleRemaining:
            let val = PaneControls.checked(titleRemainingHwnd)
            _ = try? WinSettingsStore.update { $0.titleRemaining = val }
            updatePreview()
            return true

        case Cmd.popupLayout:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(popupLayoutComboHwnd)
                if let idx = layoutOptions.firstIndex(of: sel) {
                    let key = layoutKeys[idx]
                    _ = try? WinSettingsStore.update { $0.popupLayout = key }
                    FleetWindow.refresh()
                }
            }
            return true

        case Cmd.sortByHeadroom:
            let val = PaneControls.checked(sortByHeadroomHwnd)
            _ = try? WinSettingsStore.update { $0.sortByHeadroom = val }
            return true

        case Cmd.balloons:
            let val = PaneControls.checked(balloonsHwnd)
            _ = try? WinSettingsStore.update { $0.trayBalloonsEnabled = val }
            return true

        case Cmd.autostart:
            let val = PaneControls.checked(autostartHwnd)
            let ok = TrayAutostart.setEnabled(val)
            if !ok {
                PaneControls.setText(autostartStatusHwnd, "Couldn't write the Run key")
                PaneControls.setChecked(autostartHwnd, TrayAutostart.isEnabled())
            } else {
                PaneControls.setText(autostartStatusHwnd, "")
            }
            return true

        case Cmd.refreshInterval:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(refreshIntervalComboHwnd)
                let seconds = Int(sel.prefix(while: { $0.isNumber })) ?? 60
                _ = try? WinSettingsStore.update { $0.refreshIntervalSeconds = seconds }
                TrayFleet.cacheSeconds = TimeInterval(seconds)
            }
            return true

        case Cmd.keepAwake:
            let val = PaneControls.checked(keepAwakeHwnd)
            _ = try? WinSettingsStore.update { $0.keepAwake = val }
            return true

        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { false }

    private func updateTitleControlsEnabled(_ enabled: Bool) {
        if let h = showAccountNameHwnd { EnableWindow(h, enabled) }
        if let h = titlePctComboHwnd { EnableWindow(h, enabled) }
        if let h = titleResetComboHwnd { EnableWindow(h, enabled) }
        if let h = titleScopedHwnd { EnableWindow(h, enabled) }
        if let h = titleRemainingHwnd { EnableWindow(h, enabled) }
    }

    private func updatePreview() {
        let s = WinSettingsStore.load()
        if s.titleIconOnly {
            PaneControls.setText(previewLabelHwnd, "(icon only)")
            return
        }

        let prefs = TitlePrefs(
            showAccountName: s.showAccountName,
            titlePct: s.titlePct,
            titleScoped: s.titleScoped,
            titleRemaining: s.titleRemaining,
            titleReset: s.titleReset
        )

        // Try to get actual active account from TrayFleet cache, or fallback to sample
        let activeAccount: Account? = {
            if let list = TrayFleet.cached() {
                if let activeNum = list.activeAccountNumber,
                   let acc = list.accounts.first(where: { $0.number == activeNum }) {
                    return acc
                }
                if let first = list.accounts.first {
                    return first
                }
            }
            return Self.sampleAccount
        }()

        let formatted = TitleFormatter.format(account: activeAccount, prefs: prefs, now: Date(), icon: "")
        PaneControls.setText(previewLabelHwnd, formatted.isEmpty ? "(empty)" : formatted)
    }
}
