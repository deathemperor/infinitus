import SwiftUI
import InfinitusCore
import InfinitusUI

/// Theme picking, promoted out of the Display pane (user 2026-08-30:
/// "revamp theme selection to adapt with the richful themes and future
/// theme gallery"): a card grid that scales past a handful of builtins,
/// your own themes.json skins in their own section, and the community
/// gallery underneath.
struct ThemesPane: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        Form {
            Section("Built-in") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(RowTheme.builtins) { theme in
                        ThemeCard(theme: theme,
                                  selected: model.gamification == theme.id) {
                            choose(theme.id)
                        }
                    }
                }
            }
            .settingsAnchor("Themes/Built-in")
            Section {
                if model.customThemes.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.customThemes) { theme in
                            ThemeCard(theme: theme,
                                      selected: model.gamification == theme.id) {
                                choose(theme.id)
                            }
                        }
                    }
                }
                Button("Open Themes File…") { openThemesFile() }
            } header: {
                Text("Your themes")
            } footer: {
                Text("Your own skins live in a JSON file; Infinitus reloads "
                     + "it every time this pane opens.")
            }
            .settingsAnchor("Themes/Your themes")
            CommunityThemesSection(model: model)
                .settingsAnchor("Themes/Community")
        }
        .formStyle(.grouped)
        .onAppear { model.reloadCustomThemes() }
    }

    private func choose(_ id: String) {
        // withAnimation is load-bearing: an open popover re-measures
        // through the animated path, and a theme with wider or narrower
        // cells otherwise left the popup overflowing or padded
        // (user-reported). Reduce Motion shortens it to one frame
        // rather than removing it.
        withAnimation(reduceMotion ? .linear(duration: 0.01)
                                   : .easeInOut(duration: 0.3)) {
            model.gamification = id
        }
    }

    /// Opens themes.json in the default editor, writing the starter
    /// template first if the file doesn't exist yet.
    private func openThemesFile() {
        let url = RowTheme.customThemesURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? RowTheme.templateJSON.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        model.reloadCustomThemes()
    }
}


/// One selectable row theme, previewed as the real popup row it produces —
/// generic over RowTheme, so custom themes from themes.json preview too.
private struct ThemeCard: View {
    let theme: RowTheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                // Three layouts, widest first: SwiftUI takes the first
                // that fits the card. A horizontal ScrollView used to
                // hide the right-hand half of a wide theme with no hint
                // that there was more (critique, minor observations).
                ViewThatFits(in: .horizontal) {
                    preview(wrapped: false, times: true)
                    preview(wrapped: true, times: true)
                    preview(wrapped: true, times: false)
                }
                namePool
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(theme.name).font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityHint("Shows a live preview of this theme's gauges, "
                           + "labels and account names.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    // Same fake numbers for every theme so the cards compare like-for-like:
    // session 21% used, weekly 68% used (ahead of pace), credit 74%, $1,131.
    // `wrapped` splits the credit row (the widest) over two lines;
    // `times` keeps the reset clocks — dropping them is the last resort
    // for a very wide custom theme.
    @ViewBuilder private func preview(wrapped: Bool, times: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if theme.plain {
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).foregroundStyle(.secondary)
                    Text("21%").monospacedDigit()
                    if times {
                        Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).foregroundStyle(.secondary)
                    Text("68%").monospacedDigit()
                    if times {
                        Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 3) {
                    Text(theme.creditLabel).foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(theme.scopedPrefix + theme.modelName("Fable")).foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                }
            } else {
                // Every row wears its own fixedSize: a bare VStack of
                // text+bar rows under-reports its ideal HEIGHT (macOS 26,
                // probed 2026-08-30) and the last row clipped to ":"
                // slivers (user screenshot).
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.sessionColor))
                    GaugeBar(remaining: 79, color: ThemeColor.resolve(theme.sessionColor), animated: false)
                    if times {
                        Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.weeklyColor))
                    GaugeBar(remaining: 32, color: ThemeColor.resolve(theme.weeklyColor), animated: false)
                    if times {
                        Text(theme.revivePrefix + "5d 9h (Sep 4 03:59)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                creditRow(wrapped: wrapped)
            }
        }
    }

    /// The widest row: credit gauge, the model alias and its gauge, the
    /// cash figure and the themed token rate. `wrapped` puts the model
    /// half on its own line.
    @ViewBuilder private func creditRow(wrapped: Bool) -> some View {
        let credit = HStack(spacing: 3) {
            Text(theme.creditLabel).font(.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.creditColor))
            GaugeBar(remaining: 26, color: ThemeColor.resolve(theme.creditColor), animated: false)
        }
        let model = HStack(spacing: 3) {
            Text(theme.scopedPrefix + theme.modelName("Fable")).font(.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
            GaugeBar(remaining: 26, color: ThemeColor.resolve(theme.scopedColor), animated: false)
            Text(verbatim: "\(theme.cashIcon)1,131")
                .font(.caption).foregroundStyle(.yellow)
            if let glyph = theme.rateGlyph {
                Text(glyph).font(.caption)
            } else {
                Image(systemName: "bolt.horizontal.fill").font(.caption).foregroundStyle(.yellow)
            }
            Text(TokenRate(perMinute: 1200, peakPerMinute: 1200).label(theme: theme))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if wrapped {
            credit.fixedSize()
            model.fixedSize()
        } else {
            HStack(spacing: 3) { credit; model }.fixedSize()
        }
    }

    /// "Names like: Sheriff, Outlaw" — the pool Randomize names draws
    /// from, which the cards never showed even though the tooltip said
    /// so (critique, minor observations). A theme with no pool of its
    /// own (the plain one) simply doesn't show the line.
    @ViewBuilder private var namePool: some View {
        let names = theme.accountNames.prefix(2)
        if !names.isEmpty {
            Text("Names like: " + names.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

extension ThemesPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Themes", section: "Built-in", label: "Theme",
                            keywords: ["theme", "skin", "row theme", "gamification",
                                       "rpg", "wild west", "cyberpunk", "hades"]),
        SettingsSearchEntry(pane: "Themes", section: "Your themes",
                            label: "Open Themes File…",
                            keywords: ["custom", "json", "themes file", "own theme"]),
        SettingsSearchEntry(pane: "Themes", section: "Community",
                            label: "Community themes",
                            keywords: ["gallery", "community", "install", "share"],
                            anchor: "Themes/Community"),
    ]
}
