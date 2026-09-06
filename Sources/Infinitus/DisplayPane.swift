import SwiftUI
import InfinitusCore

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

    var body: some View {
        Form {
            Toggle("Menu bar shows only the icon", isOn: $model.titleIconOnly)
                .help("Just the Infinitus glyph — no account name or "
                      + "percentages. The settings below return when "
                      + "this is off.")
            Toggle("Show account name in menu bar", isOn: $model.showAccountName)
                .disabled(model.titleIconOnly)
            Picker("Title percentage", selection: $model.titlePct) {
                ForEach(TitlePrefs.pctChoices, id: \.self) {
                    Text(pctLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            Picker("Reset time in title", selection: $model.titleReset) {
                ForEach(TitlePrefs.resetChoices, id: \.self) {
                    Text(resetLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            .help("When the active account's fuller window resets — "
                  + "as a countdown (↺2h14m) or a clock time (↺20:29).")
            Toggle("Show model limits in title", isOn: $model.titleScoped)
                .disabled(model.titleIconOnly)
            Toggle("Menu bar counts remaining, not used",
                   isOn: $model.titleRemaining)
                .disabled(model.titleIconOnly)
                .help("Flips the menu bar percentages to what's left. "
                      + "The popup gauges already count remaining.")
            // Visual pickers, System Settings appearance-tile style
            // (user 2026-08-30: "use visual for these 2 settings").
            VStack(alignment: .leading, spacing: 6) {
                Text("Popup layout")
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Popup size")
                HStack(spacing: 12) {
                    sizeTile("Default", "default", 11)
                    sizeTile("Large", "large", 13)
                    sizeTile("Extra large", "xlarge", 15)
                    sizeTile("Huge", "huge", 18)
                }
            }
            WallSection(model: model)
            Section("Popup transparency") {
                glassSlider("Transparency", value: $model.glassFocused)
                Text("Higher is clearer — the backdrop shows through with "
                     + "a soft glass blur. Lower is frostier. Bright apps "
                     + "behind the popup are capped to a legible level at "
                     + "every setting. One value for every state; the "
                     + "popup never shifts with focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Compact popup (one-line accounts, icon controls)",
                   isOn: $model.compactRows)
            Toggle("Hide popup actions (status chips stay)",
                   isOn: $model.footerActionsHidden)
                .help("Removes the buttons from the popup. Everything they "
                      + "did is in the menu bar icon's right-click menu.")
            Toggle("Floating countdown when every account is limited",
                   isOn: $model.revivalPanelShown)
                .help("A small always-on-top panel: who recovers first and "
                      + "when. Click it for the popup; ✕ hides it until the "
                      + "next revival.")
            Toggle("Name unnamed sessions with Claude Haiku", isOn: $model.sessionAutoNames)
                .help("One short Haiku turn per session on the active account, "
                      + "re-asked when the work moves on; the title shows in "
                      + "the sessions list and on the phone.")
            Picker("New sessions from the phone open in", selection: $model.sessionHost) {
                Text("cmux when installed, else Terminal").tag("auto")
                Text("cmux").tag("cmux")
                Text("Terminal").tag("terminal")
            }
            .help("The phone's + button opens a terminal here running the engine "
                  + "in the repository you picked; takes effect at the next launch.")
            Toggle("Checkpoint the repository at every prompt", isOn: $model.checkpointsEnabled)
                .help("With the Claude Code plugin installed, each prompt records the "
                      + "working tree as a hidden git ref (refs/infinitus/checkpoints/…) — "
                      + "`infinitusctl checkpoints <session>` lists them, checkpoint-diff "
                      + "compares, checkpoint-restore puts the files back. Ignored files "
                      + "stay out; git status is untouched.")
            Toggle("Menu bar follows the theme", isOn: $model.menuBarThemed)
                .help("The loop in the theme's color with the theme's icon "
                      + "beside it; off, or the Off theme, keeps the plain loop.")
            Toggle("Menu bar effects", isOn: $model.menuBarEffects)
                .help("A glow on the item when an account switches, dies or "
                      + "revives, and an ember breath while the active account "
                      + "burns ahead of pace. Core Animation only — no idle cost.")
                .disabled(!model.menuBarThemed)
            Toggle("Show menu bar icon", isOn: $model.menuBarIconShown)
                .help("Hide lasts until quit — it always returns on the next "
                      + "launch, so the app can never strand itself with no UI.")
            if !model.menuBarIconShown {
                Text("Icon hidden. The engine keeps running; get back here "
                     + "via this window or the pinned window.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Refresh interval", selection: $model.refreshInterval) {
                ForEach(TitlePrefs.refreshChoices, id: \.self) {
                    Text(intervalLabels[$0] ?? "\($0)s").tag($0)
                }
            }
            Toggle("Start at login",
                   isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                .help("Registers the app at its current path; moving the "
                      + "checkout breaks the login item until re-toggled.")
                .onAppear { login.refresh() }
            if let note = login.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Keep Mac awake while sessions are working",
                   isOn: $model.keepAwake)
                .help("Holds a power assertion (caffeinate -i, in-process) "
                      + "whenever any Claude Code session is mid-turn. The "
                      + "display may still sleep; the machine won't.")
        }
        .formStyle(.grouped)
    }


    private func setLayout(_ value: String) {
        withAnimation(.easeInOut(duration: 0.3)) { model.popupLayout = value }
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
    }
}


