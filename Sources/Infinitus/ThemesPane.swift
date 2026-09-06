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
            Section("Your themes") {
                if model.customThemes.isEmpty {
                    Text("None yet — themes.json skins appear here.")
                        .font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    Button("Open themes file…") { openThemesFile() }
                    Text("Add your own skins — JSON, reloaded when this pane opens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CommunityThemesSection(model: model)
        }
        .formStyle(.grouped)
        .onAppear { model.reloadCustomThemes() }
    }

    private func choose(_ id: String) {
        // withAnimation: an open popover re-measures through the same
        // animated path as the layout toggle — otherwise a theme with
        // wider/narrower cells left the popup overflowing or padded
        // (user-reported).
        withAnimation(.easeInOut(duration: 0.3)) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    preview.fixedSize()
                }
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
    }

    // Same fake numbers for every theme so the cards compare like-for-like:
    // session 21% used, weekly 68% used (ahead of pace), credit 74%, $1,131.
    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if theme.plain {
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).foregroundStyle(.secondary)
                    Text("21%").monospacedDigit()
                    Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).foregroundStyle(.secondary)
                    Text("68%").monospacedDigit()
                    Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
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
                // probed 2026-08-30) and the enclosing ScrollView clipped
                // the last row to ":" slivers (user screenshot).
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.sessionColor))
                    GaugeBar(remaining: 79, color: ThemeColor.resolve(theme.sessionColor), animated: false)
                    Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.weeklyColor))
                    GaugeBar(remaining: 32, color: ThemeColor.resolve(theme.weeklyColor), animated: false)
                    Text(theme.revivePrefix + "5d 9h (Sep 4 03:59)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                HStack(spacing: 3) {
                    Text(theme.creditLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.creditColor))
                    GaugeBar(remaining: 26, color: ThemeColor.resolve(theme.creditColor), animated: false)
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
                .fixedSize()
            }
        }
    }
}
