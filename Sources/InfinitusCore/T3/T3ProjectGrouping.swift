import Foundation

/// `sidebarProjectGrouping.ts` + `projectGrouping.ts`: one sidebar group per
/// logical project; checkouts of the same folder name on different Macs merge.
public enum T3ProjectGrouping {
    public struct Project: Sendable, Equatable, Identifiable {
        public let id: String, environmentId: String, name: String, cwd: String
        public init(id: String, environmentId: String, name: String, cwd: String) { self.id = id; self.environmentId = environmentId; self.name = name; self.cwd = cwd }
    }
    public enum Mode: String, Sendable, Equatable { case logical, physical }
    /// `overrides` is keyed by `physicalKey` (`deriveProjectGroupingOverrideKey` upstream), so one
    /// override affects only the physical clone it names, not its siblings in the same logical group.
    public struct Settings: Sendable, Equatable {
        public var mode: Mode, overrides: [String: Mode]
        public init(mode: Mode = .logical, overrides: [String: Mode] = [:]) { self.mode = mode; self.overrides = overrides }
    }
    public enum Presence: String, Sendable, Equatable { case localOnly = "local-only", remoteOnly = "remote-only", mixed }
    public struct Group: Sendable, Equatable, Identifiable {
        public let id: String, displayName: String, representative: Project, members: [Project]
        public let environmentPresence: Presence, remoteEnvironmentLabels: [String]
    }

    public static func physicalKey(_ p: Project) -> String { "\(p.environmentId):\(p.id)" }
    /// This port's approximation of upstream's `deriveLogicalProjectKey`, which prefers
    /// `repositoryIdentity.canonicalKey` (shared-repo grouping) and falls back to the physical
    /// path; the typed `Project` carries neither repository identity nor a full normalised path,
    /// so grouping here is by folder name alone.
    public static func logicalKey(_ p: Project) -> String {
        URL(fileURLWithPath: p.cwd).lastPathComponent.lowercased()
    }
    static func groupKey(_ p: Project, _ s: Settings) -> String {
        let mode = s.overrides[physicalKey(p)] ?? s.mode
        return mode == .logical ? "logical:" + logicalKey(p) : "physical:" + physicalKey(p)
    }

    public static func groups(projects: [Project], settings: Settings, primaryEnvironmentId: String?, environmentLabel: (String) -> String?) -> [Group] {
        var order: [String] = [], byKey: [String: [Project]] = [:]
        for p in projects {
            let k = groupKey(p, settings)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(p)
        }
        return order.map { key in
            let members = byKey[key]!
            let representative = primaryEnvironmentId.flatMap { primary in members.first { $0.environmentId == primary } } ?? members[0]
            let hasLocal = primaryEnvironmentId != nil && members.contains { $0.environmentId == primaryEnvironmentId }
            let remote = primaryEnvironmentId == nil ? [] : members.filter { $0.environmentId != primaryEnvironmentId }
            var labels: [String] = []
            for m in remote { if let l = environmentLabel(m.environmentId), !labels.contains(l) { labels.append(l) } }
            let presence: Presence = hasLocal && !remote.isEmpty ? .mixed : !remote.isEmpty ? .remoteOnly : .localOnly
            return Group(id: key, displayName: representative.name, representative: representative, members: members,
                         environmentPresence: presence, remoteEnvironmentLabels: labels)
        }
    }

    public struct PickerEntry: Sendable, Equatable { public let group: Group, target: Project, isPreferred: Bool }
    public static func pickerEntries(groups: [Group], preferred: (environmentId: String, projectId: String)?) -> [PickerEntry] {
        let entries: [PickerEntry] = groups.map { g in
            let isPreferred = preferred.map { p in g.members.contains { $0.environmentId == p.environmentId && $0.id == p.projectId } } ?? false
            let preferredProject = preferred.flatMap { p in
                g.members.first { $0.environmentId == p.environmentId && $0.id == p.projectId } ?? g.members.first { $0.environmentId == p.environmentId }
            }
            return PickerEntry(group: g, target: preferredProject ?? g.representative, isPreferred: isPreferred)
        }
        guard let i = entries.firstIndex(where: \.isPreferred), i > 0 else { return entries }
        return [entries[i]] + entries[..<i] + entries[(i + 1)...]
    }
}
