import Foundation

/// One searchable row of Settings: the pane it lives on, the section
/// that holds it, its own visible label, and any words a user might
/// type instead. `anchor` is the id the pane tags its Section with, so
/// a hit can scroll to and flash the group the row belongs to.
///
/// Panes declare these as `static let searchEntries` next to the
/// sections they describe, so a renamed label and its index entry move
/// together (critique P1: the old field matched a hand-written keyword
/// list that had drifted away from the settings themselves).
public struct SettingsSearchEntry: Sendable, Equatable, Identifiable {
    public let pane: String
    public let section: String?
    public let label: String
    public let keywords: [String]
    public let anchor: String

    public var id: String { "\(anchor)#\(label)" }

    public init(pane: String, section: String? = nil, label: String,
                keywords: [String] = [], anchor: String? = nil) {
        self.pane = pane
        self.section = section
        self.label = label
        self.keywords = keywords
        self.anchor = anchor ?? "\(pane)/\(section ?? "")"
    }
}

/// Ranked search over every setting the window can show. Pure
/// Foundation: it builds and ranks the same way on Linux, and its
/// ranking is the part worth testing.
public struct SettingsSearchIndex: Sendable {
    public let entries: [SettingsSearchEntry]
    /// Lower-cased once at build time — the query is matched against
    /// this, never against the display strings.
    private let folded: [Folded]

    private struct Folded: Sendable {
        let label: String
        let section: String
        let keywords: [String]
        let pane: String
        /// Everything above in one string, for the loose word match.
        let all: String
    }

    public init(_ entries: [SettingsSearchEntry]) {
        self.entries = entries
        self.folded = entries.map { entry in
            let label = entry.label.lowercased()
            let section = (entry.section ?? "").lowercased()
            let keywords = entry.keywords.map { $0.lowercased() }
            let pane = entry.pane.lowercased()
            return Folded(label: label, section: section, keywords: keywords,
                          pane: pane,
                          all: ([label, section, pane] + keywords).joined(separator: " "))
        }
    }

    public func entry(id: String) -> SettingsSearchEntry? {
        entries.first { $0.id == id }
    }

    /// Best matches first: an exact label, then a label that starts
    /// with the query, then a label that contains it, then the section,
    /// then a keyword, then the pane's own name — and last, a row where
    /// every word of the query appears somewhere, so "keep awake" finds
    /// "Keep the Mac awake while sessions are working". Ties keep
    /// declaration order, so a pane's rows stay in the order it shows them.
    public func matches(_ query: String, limit: Int = 60) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map(String.init)
        var scored: [(rank: Int, order: Int, entry: SettingsSearchEntry)] = []
        for (i, f) in folded.enumerated() {
            let rank: Int
            if f.label == q { rank = 0 }
            else if f.label.hasPrefix(q) { rank = 1 }
            else if f.label.contains(q) { rank = 2 }
            else if f.section.contains(q) { rank = 3 }
            else if f.keywords.contains(where: { $0.contains(q) }) { rank = 4 }
            else if f.pane.contains(q) { rank = 5 }
            else if words.count > 1, words.allSatisfy({ f.all.contains($0) }) { rank = 6 }
            else { continue }
            scored.append((rank, i, entries[i]))
        }
        return scored.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(limit).map(\.entry)
    }

    /// The same matches, gathered under their pane in the order the
    /// panes first appear — the shape the sidebar draws.
    public func grouped(_ query: String, limit: Int = 60) -> [(pane: String, entries: [SettingsSearchEntry])] {
        var order: [String] = []
        var byPane: [String: [SettingsSearchEntry]] = [:]
        for hit in matches(query, limit: limit) {
            if byPane[hit.pane] == nil { order.append(hit.pane) }
            byPane[hit.pane, default: []].append(hit)
        }
        return order.map { ($0, byPane[$0] ?? []) }
    }
}
