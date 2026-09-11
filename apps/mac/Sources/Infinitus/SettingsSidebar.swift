import SwiftUI
import InfinitusCore

/// How the sidebar's destinations are grouped. System Settings puts a
/// header over every run of related panes; ours were eighteen flat rows
/// ordered by how often each was reached (critique P1: "a frequency
/// list, not an information architecture").
///
/// The group is derived from the pane's title rather than stored on
/// `SettingsTab` — that type lives in StatusItemController.swift and is
/// shared with the settings scene; nothing about grouping belongs there.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case general = "General"
    case accounts = "Accounts"
    case dashboards = "Dashboards"
    case engines = "Engines"
    /// About and the debug Animations pane: last, and under no header —
    /// a header of one word over the app's own two rows adds nothing.
    case app = ""

    var id: String { rawValue }
    var title: String? { rawValue.isEmpty ? nil : rawValue }

    /// How wide the pane's content is allowed to get. A grouped Form
    /// self-limits around 700pt and looked marooned in a 1800pt window;
    /// the dashboards are tables and charts and earn more (critique P1).
    var contentWidth: CGFloat { self == .dashboards ? 1100 : 760 }

    static func of(_ tab: SettingsTab) -> SettingsGroup {
        if tab.provider != nil { return .engines }
        switch tab.title {
        case "Accounts", TeamModel.paneTitle: return .accounts
        case "Usage", "Utilization", "Stats", "Machine", "Activity": return .dashboards
        case "About", "Animations": return .app
        default: return .general
        }
    }
}

/// The Settings sidebar: a real `List(selection:)`, which is where the
/// arrow keys, type-select, the focus ring and the accessibility rows
/// come from (critique P0 — every row used to announce as "button").
/// A plain List inside our own HStack is NOT the NavigationSplitView
/// whose selection→detail hop froze under synthetic clicks in 2026-08-30.
struct SettingsSidebar: View {
    let tabs: [SettingsTab]
    /// Search hits, grouped by pane; empty while not searching.
    let results: [(pane: String, entries: [SettingsSearchEntry])]
    let searching: Bool
    let query: String
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if searching {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(results, id: \.pane) { group in
                        Section(group.pane) {
                            ForEach(group.entries) { entry in
                                resultRow(entry)
                            }
                        }
                    }
                }
            } else {
                ForEach(SettingsGroup.allCases) { group in
                    let rows = tabs.filter { SettingsGroup.of($0) == group }
                    if !rows.isEmpty {
                        if let title = group.title {
                            Section {
                                ForEach(rows, id: \.title) { row($0) }
                            } header: {
                                header(title, rows: rows)
                            }
                        } else {
                            Section {
                                ForEach(rows, id: \.title) { row($0) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// "Engines · 2 on" — the live count the old hand-rolled header
    /// carried, kept where it was.
    @ViewBuilder private func header(_ title: String, rows: [SettingsTab]) -> some View {
        let live = rows.filter { $0.provider?.live == true }.count
        HStack {
            Text(title)
            if rows.contains(where: { $0.provider != nil }) {
                Spacer()
                Text("\(live) on")
            }
        }
    }

    @ViewBuilder private func row(_ tab: SettingsTab) -> some View {
        if tab.provider == nil {
            Label {
                Text(tab.title)
            } icon: {
                tile(tab)
            }
            .accessibilityLabel(tab.title)
            .tag(tab.title)
        } else {
            let badge = tab.provider ?? ProviderBadge()
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .frame(width: 18)
                Text(tab.title)
                Spacer()
                if badge.live {
                    Circle().fill(.green).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(badge.placeholder ? AnyShapeStyle(.tertiary)
                                               : AnyShapeStyle(.primary))
            .accessibilityLabel(badge.placeholder
                                ? "\(tab.title), not available yet"
                                : "\(tab.title), \(badge.live ? "running" : "not running")")
            // selectionDisabled, not .disabled: a disabled row still
            // takes keyboard focus and then does nothing.
            .selectionDisabled(badge.placeholder)
            .tag(tab.title)
        }
    }

    @ViewBuilder private func tile(_ tab: SettingsTab) -> some View {
        if let image = tab.image {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: tab.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(tab.tint.gradient))
        }
    }

    @ViewBuilder private func resultRow(_ entry: SettingsSearchEntry) -> some View {
        // A section named after its one setting (Stats/Period) would
        // read "Period, in Period" — show and announce the label alone.
        let section = entry.section.flatMap { $0 == entry.label ? nil : $0 }
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.label)
            if let section {
                Text(section).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.map { "\(entry.label), in \($0)" } ?? entry.label)
        .tag(entry.id)
    }
}

/// Sets the enclosing window's title and subtitle from SwiftUI. The
/// window is created by StatusItemController, which cannot see which
/// pane is showing; System Settings titles by pane and so do we
/// (critique P1: "the window is titled Infinitus, never Settings").
struct WindowTitler: NSViewRepresentable {
    let title: String
    let subtitle: String

    final class Titled: NSView {
        var apply: (NSWindow) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { apply(window) }
        }
    }

    func makeNSView(context: Context) -> Titled { Titled(frame: .zero) }

    func updateNSView(_ view: Titled, context: Context) {
        let title = title, subtitle = subtitle
        // viewDidMoveToWindow covers the first pass, where the view has
        // no window yet; updateNSView covers every pane change after.
        view.apply = { window in
            window.title = title
            window.subtitle = subtitle
        }
        if let window = view.window { view.apply(window) }
    }
}
