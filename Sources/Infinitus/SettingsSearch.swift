import SwiftUI
import InfinitusCore

/// Everything Settings search can find. Panes this app owns publish
/// their own rows as `searchEntries`; every pane, owned or not, also
/// contributes its title and the keywords already declared on its
/// `SettingsTab`, so nothing becomes unfindable while the other panes
/// catch up (add one `case` below when they do).
enum SettingsSearchCatalog {
    @MainActor
    static func index(tabs: [SettingsTab]) -> SettingsSearchIndex {
        var entries: [SettingsSearchEntry] = []
        for tab in tabs {
            // The pane itself is always findable by name.
            entries.append(SettingsSearchEntry(pane: tab.title, label: tab.title,
                                               keywords: tab.keywords,
                                               anchor: "\(tab.title)/"))
            entries.append(contentsOf: rows(of: tab.title))
        }
        return SettingsSearchIndex(entries)
    }

    @MainActor
    private static func rows(of pane: String) -> [SettingsSearchEntry] {
        switch pane {
        case "Display": return DisplayPane.searchEntries
        case "Themes": return ThemesPane.searchEntries
        case "Utilization": return UtilizationPane.searchEntries
        case "Stats": return StatsPane.searchEntries
        case "Machine": return MachinePane.searchEntries
        case "Activity": return ActivityPane.searchEntries
        case LockModel.paneTitle: return LockPane.searchEntries
        case "About": return AboutPane.searchEntries
        // Accounts, Push, Profiles, Devices, Team and the engine panes
        // carry their title and keywords only, until they publish their
        // own searchEntries.
        default: return []
        }
    }
}

/// The section a search hit asked for. A pane's Section reads it and
/// flashes once when it is the one; nothing else in the app reads it.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

extension View {
    /// Marks a Section as a search destination: `scrollTo` can find it
    /// by this id, and it flashes once when a search hit points at it.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(anchor: id))
    }
}

private struct SettingsAnchor: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tint is a row background only while it shows — nil otherwise,
    /// not a clear fill: in a grouped Form the section's card IS its row
    /// backgrounds, so a permanent listRowBackground strips the card off
    /// every anchored section. A view-or-nil swap alone snaps, so the
    /// tint is mounted transparent a frame before it fades in and
    /// unmounted once it has faded out.
    @State private var mounted = false
    @State private var opacity = 0.0

    private var lit: Bool { highlight == anchor }
    private var fade: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.35) }

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .listRowBackground(mounted
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).opacity(opacity)
                : nil)
            // One shot, cleared by the caller after 1.2s: no
            // repeatForever, no TimelineView, nothing ticking (repo
            // rule — idle CPU stays ~0%).
            .onChange(of: lit) { _, on in
                if on {
                    mounted = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(16))
                        withAnimation(fade) { opacity = 1 }
                    }
                } else {
                    withAnimation(fade) { opacity = 0 }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if !lit { mounted = false }
                    }
                }
            }
    }
}
