import SwiftUI
import InfinitusCore
import InfinitusUI

/// App-local display preferences — the rumps Settings menu's four display
/// items (menubar.py `MenuBarSettings`), same choices and defaults.
struct DisplayPane: View {
    @ObservedObject var model: AppModel
    @StateObject private var login = LoginItemModel()

    private let resetLabels = ["off": "None", "countdown": "Countdown",
                               "clock": "Clock time"]
    private let pctLabels = ["off": "None", "5h": "Session (5h)",
                             "7d": "Weekly (7d)", "both": "Both (5h · 7d)"]
    private let intervalLabels = [30: "30 seconds", 60: "60 seconds", 300: "5 minutes"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            menuBarSection
            popupSection
            // The wall's Section is built inside WallSection, so its
            // anchor rides the wrapper view rather than the Section.
            WallSection(model: model)
                .settingsAnchor("Display/Fleet wall")
            sessionsSection
            startupSection
        }
        .formStyle(.grouped)
    }

    // MARK: menu bar

    @ViewBuilder private var menuBarSection: some View {
        Section {
            Toggle("Show only the icon", isOn: $model.titleIconOnly)
            Toggle("Show the account name", isOn: $model.showAccountName)
                .disabled(model.titleIconOnly)
            Picker("Percentages", selection: $model.titlePct) {
                ForEach(TitlePrefs.pctChoices, id: \.self) {
                    Text(pctLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            Picker("Reset time", selection: $model.titleReset) {
                ForEach(TitlePrefs.resetChoices, id: \.self) {
                    Text(resetLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            Toggle("Show model limits", isOn: $model.titleScoped)
                .disabled(model.titleIconOnly)
            Toggle("Count what's left, not what's used", isOn: $model.titleRemaining)
                .disabled(model.titleIconOnly)
            Toggle("Follow the theme", isOn: $model.menuBarThemed)
            Toggle("Animate switches and burn", isOn: $model.menuBarEffects)
                .disabled(!model.menuBarThemed)
            Toggle("Show the icon in the menu bar", isOn: $model.menuBarIconShown)
            if !model.menuBarIconShown {
                Text("The icon is hidden until the next launch. The engine "
                     + "keeps running, and this window and the pinned window "
                     + "still reach it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Menu bar")
        } footer: {
            Text("Showing only the icon puts the rest of this group away "
                 + "until you turn it off. The reset time is the refill of "
                 + "whichever limit is further from empty, session or "
                 + "weekly, as a countdown (↺2h14m) or a clock time "
                 + "(↺20:29). Following the theme draws the loop in the "
                 + "theme's color with the theme's icon beside it; off "
                 + "keeps the plain loop. Animate switches and burn glows "
                 + "the icon when an account switches and breathes an "
                 + "ember while the active one burns ahead of pace; it "
                 + "needs the theme on. Hiding the icon lasts until quit: "
                 + "it always comes back on the next launch, so the app "
                 + "can never strand itself with no way in.")
        }
        .settingsAnchor("Display/Menu bar")
    }

    // MARK: popup

    @ViewBuilder private var popupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Layout").accessibilityHidden(true)
                HStack(spacing: 12) {
                    PickTile(title: "Wide rows",
                             selected: model.popupLayout == "wide",
                             choose: { setLayout("wide") }) {
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(Color.secondary.opacity(0.65))
                                    .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 9)
                    }
                    PickTile(title: "Stacked cards",
                             selected: model.popupLayout == "stacked",
                             choose: { setLayout("stacked") }) {
                        VStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 22, height: 10)
                            }
                        }
                    }
                    PickTile(title: "Horizontal cards",
                             selected: model.popupLayout == "hstack",
                             choose: { setLayout("hstack") }) {
                        HStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 10, height: 22)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Layout")
            VStack(alignment: .leading, spacing: 6) {
                Text("Size").accessibilityHidden(true)
                HStack(spacing: 12) {
                    sizeTile("Default", "default", 11)
                    sizeTile("Large", "large", 13)
                    sizeTile("Extra large", "xlarge", 15)
                    sizeTile("Huge", "huge", 18)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Size")
            glassSlider("Transparency", value: $model.glassFocused)
            Toggle("Compact rows", isOn: $model.compactRows)
            Toggle("Hide the action buttons", isOn: $model.footerActionsHidden)
            Toggle("Sort rows by headroom", isOn: $model.sortByHeadroom)
            Toggle("Floating countdown when every account is out",
                   isOn: $model.revivalPanelShown)
        } header: {
            Text("Popup")
        } footer: {
            Text("Higher transparency is clearer, lower is frostier, and "
                 + "it is one value for every state — the popup never "
                 + "shifts with focus, and a bright app behind it is "
                 + "capped to a legible level at every setting. Compact "
                 + "rows put each account on one line with icon-only "
                 + "controls. Hiding the action buttons leaves everything "
                 + "they did in the menu bar icon's right-click menu. "
                 + "Sorting by headroom puts the active account first, "
                 + "then the next candidate, then the fullest — slot "
                 + "numbers don't move, and Settings › Accounts keeps the "
                 + "engine's own order. The floating countdown is a small "
                 + "always-on-top panel saying who recovers first and "
                 + "when.")
        }
        .settingsAnchor("Display/Popup")
    }

    // MARK: sessions

    @ViewBuilder private var sessionsSection: some View {
        Section {
            Toggle("Checkpoint the repository at every prompt",
                   isOn: $model.checkpointsEnabled)
            Toggle("Name unnamed sessions with Claude Haiku",
                   isOn: $model.sessionAutoNames)
            Picker("New sessions from the phone open in", selection: $model.sessionHost) {
                Text("cmux when installed, else Terminal").tag("auto")
                Text("cmux").tag("cmux")
                Text("Terminal").tag("terminal")
                Text("No terminal — Infinitus runs it, chat from the app or phone").tag("owned")
            }
            // The phone's picker with its live previews (#151): one row
            // per style, drawn in the current theme.
            ChatHeaderPicker(selection: $model.chatHeader, theme: model.rowTheme)
        } header: {
            Text("Sessions")
        } footer: {
            Text("Checkpointing records the working tree as a hidden git "
                 + "ref at every prompt, so a session can be compared or "
                 + "put back later; ignored files stay out and git status "
                 + "is untouched. Naming asks Claude Haiku once per "
                 + "session on the active account — roughly a fraction of "
                 + "a cent each, and it re-asks when the work moves on. "
                 + "The terminal choice takes effect at the next launch.")
        }
        .settingsAnchor("Display/Sessions")
    }

    // MARK: startup

    @ViewBuilder private var startupSection: some View {
        Section {
            Picker("Refresh interval", selection: $model.refreshInterval) {
                ForEach(TitlePrefs.refreshChoices, id: \.self) {
                    Text(intervalLabels[$0] ?? "\($0)s").tag($0)
                }
            }
            Toggle("Start at login",
                   isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                .onAppear { login.refresh() }
            if let note = login.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Keep the Mac awake while sessions are working",
                   isOn: $model.keepAwake)
            Toggle("Keep the screen on too",
                   isOn: $model.keepAwakeDisplay)
                .disabled(!model.keepAwake)
        } header: {
            Text("Refresh and startup")
        } footer: {
            Text("The refresh interval is how often Infinitus asks for new "
                 + "usage numbers; a longer one is lighter on the machine "
                 + "and slower to notice a switch. "
                 + "The login item points at where the app is right now — "
                 + "move it and turn this off and on again. Keeping the Mac "
                 + "awake holds a power assertion while any session is "
                 + "mid-turn, like a caffeine app; with the screen on too "
                 + "the display stays lit as well, otherwise it may sleep "
                 + "while the machine won't.")
        }
        .settingsAnchor("Display/Startup")
    }


    /// withAnimation is not decoration here: an open NSPopover measures
    /// its content once, and only an animated change makes it re-measure
    /// live (CLAUDE.md). Under Reduce Motion the animation shrinks to a
    /// single frame instead of disappearing — dropping it outright leaves
    /// the popup overflowing or padded.
    private func setLayout(_ value: String) {
        withAnimation(reduceMotion ? .linear(duration: 0.01)
                                   : .easeInOut(duration: 0.3)) {
            model.popupLayout = value
        }
    }

    private func sizeTile(_ title: String, _ tag: String,
                          _ pt: CGFloat) -> some View {
        PickTile(title: title, selected: model.popupTextSize == tag,
                 choose: { model.popupTextSize = tag }) {
            Text("Aa").font(.system(size: pt, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func glassSlider(_ label: String,
                             value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0...1)
                    .frame(width: 180)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

}


/// One visual settings choice: a little art tile + caption, ringed when
/// selected — the System Settings appearance-picker look.
private struct PickTile<Art: View>: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    @ViewBuilder let art: Art

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                art
                    .frame(width: 58, height: 36)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.accentColor
                                               : Color.secondary.opacity(0.3),
                                      lineWidth: selected ? 2 : 1))
                Text(title).font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}



/// What Settings search can find on this pane. One entry per visible
/// row; `anchor` is the Section id the row lives under, so a hit scrolls
/// to and flashes its group.
extension DisplayPane {
    static let searchEntries: [SettingsSearchEntry] = {
        let menuBar = "Menu bar", popup = "Popup", wall = "Fleet wall"
        let sessions = "Sessions"
        // The last group is headed "Refresh and startup", but its anchor
        // stays "Display/Startup": renaming a header must never move the
        // Section id the search scrolls to.
        let startup = "Refresh and startup", startupAnchor = "Display/Startup"
        func entry(_ section: String, _ label: String, _ keywords: [String],
                   anchor: String? = nil) -> SettingsSearchEntry {
            SettingsSearchEntry(pane: "Display", section: section,
                                label: label, keywords: keywords,
                                anchor: anchor)
        }
        return [
            entry(menuBar, "Show only the icon", ["glyph", "icon only", "menu bar"]),
            entry(menuBar, "Show the account name", ["name", "alias"]),
            entry(menuBar, "Percentages", ["percent", "5h", "7d", "session", "weekly"]),
            entry(menuBar, "Reset time", ["countdown", "clock", "refill", "reset"]),
            entry(menuBar, "Show model limits", ["model", "scoped", "opus", "fable"]),
            entry(menuBar, "Count what's left, not what's used", ["remaining", "used", "headroom"]),
            entry(menuBar, "Follow the theme", ["theme", "colour", "color"]),
            entry(menuBar, "Animate switches and burn",
                  ["effects", "glow", "ember", "animation", "flash"]),
            entry(menuBar, "Show the icon in the menu bar", ["hide", "hidden", "status item"]),
            entry(popup, "Layout", ["wide", "stacked", "horizontal", "cards", "rows"]),
            entry(popup, "Size", ["text size", "large", "huge", "scale"]),
            entry(popup, "Transparency", ["glass", "blur", "opacity", "translucent"]),
            entry(popup, "Compact rows", ["compact", "one line", "dense"]),
            entry(popup, "Hide the action buttons", ["actions", "buttons", "footer", "chips"]),
            entry(popup, "Sort rows by headroom", ["order", "sort", "headroom", "next"]),
            entry(popup, "Floating countdown when every account is out", ["revival", "panel", "floating", "all out"]),
            entry(wall, "Screen", ["wall", "monitor", "external", "full screen"]),
            entry(wall, "Enter Full-Screen Fleet Wall", ["wall", "full screen", "kiosk"]),
            entry(sessions, "Checkpoint the repository at every prompt", ["checkpoint", "git", "restore", "diff", "undo"]),
            entry(sessions, "Name unnamed sessions with Claude Haiku", ["haiku", "name", "title", "auto name"]),
            entry(sessions, "New sessions from the phone open in", ["terminal", "cmux", "phone", "host", "headless", "owned"]),
            entry(sessions, "Chat header", ["hud", "compact", "strip", "chat", "header", "unit frame"]),
            entry(startup, "Refresh interval", ["poll", "interval", "refresh", "seconds"],
                  anchor: startupAnchor),
            entry(startup, "Start at login", ["login item", "startup", "launch", "boot"],
                  anchor: startupAnchor),
            entry(startup, "Keep the Mac awake while sessions are working",
                  ["keep awake", "awake", "caffeinate", "sleep", "power"],
                  anchor: startupAnchor),
            entry(startup, "Keep the screen on too",
                  ["screen", "display", "awake", "caffeine", "sleep"],
                  anchor: startupAnchor),
        ]
    }()
}
