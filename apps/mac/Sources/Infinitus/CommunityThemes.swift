import SwiftUI
import InfinitusCore

/// The shared theme gallery: a JSON index in the claude-swap repo that
/// anyone can PR a theme into (themes/README.md documents the format and
/// process). The app only READS the repo — installing copies the theme
/// into the local themes.json, so an installed theme keeps working offline
/// and survives the gallery changing.
@MainActor
final class CommunityThemesModel: ObservableObject {
    struct Entry: Decodable, Identifiable {
        let id: String
        let name: String
        let author: String
        let file: String
    }
    private struct Index: Decodable { let themes: [Entry] }

    @Published var entries: [Entry] = []
    @Published var status: String?
    @Published var busy = false

    static let base = URL(string:
        "https://raw.githubusercontent.com/deathemperor/infinitus/main/themes/")!
    static let contributeURL = URL(string:
        "https://github.com/deathemperor/infinitus/tree/main/themes")!

    func refresh() async {
        busy = true
        defer { busy = false }
        status = nil
        do {
            let (data, _) = try await URLSession.shared.data(
                from: Self.base.appendingPathComponent("index.json"))
            entries = try JSONDecoder().decode(Index.self, from: data).themes
            if entries.isEmpty {
                status = "No community themes yet — yours could be the first."
            }
        } catch {
            status = "Couldn't reach the gallery. Check your connection and choose Refresh."
        }
    }

    /// Fetch one theme file and merge it into the local themes.json,
    /// replacing a previous install of the same id.
    func install(_ entry: Entry, into model: AppModel) async {
        busy = true
        defer { busy = false }
        do {
            let (data, _) = try await URLSession.shared.data(
                from: Self.base.appendingPathComponent(entry.file))
            let theme = try JSONDecoder().decode(RowTheme.self, from: data)
            var customs = RowTheme.loadCustom()
            customs.removeAll { $0.id == theme.id }
            customs.append(theme)
            try RowTheme.saveCustom(customs)
            model.reloadCustomThemes()
            status = "Installed \(theme.name)."
        } catch {
            status = "Couldn't install that theme. Choose Refresh and try again."
        }
    }
}

/// Lives inside the Display pane's "Row theme" section.
struct CommunityThemesSection: View {
    @ObservedObject var model: AppModel
    @StateObject private var gallery = CommunityThemesModel()
    @Environment(\.openURL) private var openURL

    private var installedIds: Set<String> {
        Set(model.availableThemes.map(\.id))
    }

    var body: some View {
        DisclosureGroup("Community themes") {
            ForEach(gallery.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                        Text("by \(entry.author)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installedIds.contains(entry.id) {
                        Text("Installed")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Install") {
                            Task { await gallery.install(entry, into: model) }
                        }
                        .disabled(gallery.busy)
                    }
                }
            }
            if let status = gallery.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { Task { await gallery.refresh() } }
                    .disabled(gallery.busy)
                Button("Share Yours…") { openURL(CommunityThemesModel.contributeURL) }
            }
            // Stays a caption Text rather than a Section footer: this is
            // inside a DisclosureGroup, which has no footer slot.
            Text("Themes here are copied into your own file when you install "
                 + "one, so they keep working offline. Share yours by adding "
                 + "it to the gallery on GitHub.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if gallery.entries.isEmpty { await gallery.refresh() } }
    }
}
