import SwiftUI
import InfinitusCore
import InfinitusUI

/// Settings › Machine (#115): what many concurrent Claude sessions do
/// to this Mac, and the confirmed actions to fix it. Reads
/// `model.report`, refreshed on `AppModel`'s own refresh loop
/// (`MachineModel.tick()`) — nothing here polls on its own.
struct MachinePane: View {
    @ObservedObject var model: MachineModel

    @State private var pendingDisable: HookGroup?
    @State private var pendingKill: Runaways.Runaway?
    @State private var pendingHookKill: HookGroup?
    @State private var pendingReclaim = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            header
            if let report = model.report {
                summarySection(report)
                warningsSection(report)
                hooksSection(report)
                runawaysSection(report)
                residueSection(report)
            }
            sessionsSection(model.report)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Move \(pendingDisable?.owner ?? "")'s \(pendingDisable?.registrationCount ?? 0) hook registrations out of ~/.claude/settings.json? A backup is written beside it.",
            isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
            presenting: pendingDisable
        ) { group in
            Button("Disable", role: .destructive) {
                let owner = group.owner
                Task { resultMessage = await model.disableHook(owner: owner) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Send SIGTERM to \(pendingHookKill?.owner ?? "")'s \((pendingHookKill?.instances ?? 0) + (pendingHookKill?.helpers ?? 0)) live hook processes, then SIGKILL after 3 s? The sessions themselves are never signalled.",
            isPresented: Binding(get: { pendingHookKill != nil }, set: { if !$0 { pendingHookKill = nil } }),
            presenting: pendingHookKill
        ) { group in
            Button("Kill instances", role: .destructive) {
                let owner = group.owner
                Task { resultMessage = await model.killHookInstances(owner: owner) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Send SIGTERM to the process group of \(pendingKill?.pid ?? 0), then SIGKILL after 3 s?",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { runaway in
            Button("Kill", role: .destructive) {
                let pid = runaway.pid
                Task { resultMessage = await model.killRunaway(pid: pid) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(reclaimMessage, isPresented: $pendingReclaim) {
            Button("Reclaim", role: .destructive) { Task { resultMessage = await model.reclaim() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: header

    private var header: some View {
        Section {
            Toggle("Watch this Mac", isOn: $model.enabled)
            Toggle("Notify about hooks (new, stuck, fanned out)", isOn: $model.notifyHooks)
            Toggle("Notify about the temp directory", isOn: $model.notifyTemp)
            HStack {
                Button("Sample Now") { Task { resultMessage = nil; await model.sample() } }
                    .disabled(model.sampling)
                if model.sampling { ProgressView().controlSize(.small) }
                Spacer()
                if let at = model.lastSampledAt {
                    Text("Sampled \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let resultMessage {
                Text(resultMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Watching")
        } footer: {
            Text("Watching costs one process listing a minute and one look "
                 + "at the temp directory every five.")
        }
        .settingsAnchor("Machine/Watching")
    }

    // MARK: summary

    private func summarySection(_ report: MachineReport) -> some View {
        let s = report.sample
        return Section("Summary") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Load").foregroundStyle(.secondary)
                    Text("\(s.load1, specifier: "%.2f") / \(s.cores) cores")
                        .foregroundStyle(s.load1 > Double(s.cores) ? .red : .primary)
                }
                GridRow {
                    Text("Swap").foregroundStyle(.secondary)
                    Text("\(s.swapUsedMB) / \(s.swapTotalMB) MB")
                        .foregroundStyle(s.swapPct >= 90 ? .red : .primary)
                }
                GridRow {
                    Text("Processes").foregroundStyle(.secondary)
                    Text("\(s.processes) total, \(s.running) running, \(s.uninterruptible) uninterruptible, \(s.zombies) zombies")
                        .foregroundStyle(s.uninterruptible >= 50 ? .red : .primary)
                }
                GridRow {
                    Text("WindowServer").foregroundStyle(.secondary)
                    Text("\(s.windowServerCPU, specifier: "%.0f")% CPU")
                }
                GridRow {
                    Text("Temp entries").foregroundStyle(.secondary)
                    if let n = s.tempEntries {
                        Text("\(n)")
                    } else {
                        Text("Listing timed out").foregroundStyle(.red)
                    }
                }
                GridRow {
                    Text("Claude sessions").foregroundStyle(.secondary)
                    Text("\(s.claudeRSSMB) MB resident")
                }
            }
            .font(PopupFont.caption).monospacedDigit()
        }
        .settingsAnchor("Machine/Summary")
    }

    // MARK: warnings

    private func warningsSection(_ report: MachineReport) -> some View {
        Section("Warnings") {
            if report.warnings.isEmpty {
                Text("Nothing to flag").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).foregroundStyle(.orange).font(PopupFont.caption)
                }
            }
        }
    }

    // MARK: hooks

    struct HookGroup: Identifiable {
        let owner: String
        let kind: HookRegistration.OwnerKind
        let events: [String]
        let spawnsPerHour: Double
        let heavy: Bool
        let instances: Int
        let helpers: Int
        let oldestSeconds: Int
        let stuckCount: Int
        let registrationCount: Int
        var id: String { owner }
    }

    /// One row per owner. The same script registered on several events
    /// shows the same live instances under each registration, so live
    /// counts take the max, not the sum; spawn rates do add up.
    private func hookGroups(_ report: MachineReport) -> [HookGroup] {
        var byOwner: [String: [MachineReport.Hook]] = [:]
        for hook in report.hooks { byOwner[hook.registration.owner, default: []].append(hook) }
        var groups: [HookGroup] = []
        for (owner, hooks) in byOwner {
            guard let first = hooks.first else { continue }
            var events = Set<String>()
            var spawns = 0.0, heavy = false, instances = 0, helpers = 0, oldest = 0, stuck = 0
            for hook in hooks {
                events.insert(hook.registration.event)
                spawns += hook.spawnsPerHour
                if hook.registration.heavy { heavy = true }
                instances = max(instances, hook.live.instances)
                helpers = max(helpers, hook.live.helpers)
                oldest = max(oldest, hook.live.oldestSeconds)
                if hook.stuck { stuck += 1 }
            }
            groups.append(HookGroup(owner: owner, kind: first.registration.ownerKind, events: events.sorted(),
                                    spawnsPerHour: spawns, heavy: heavy, instances: instances, helpers: helpers,
                                    oldestSeconds: oldest, stuckCount: stuck, registrationCount: hooks.count))
        }
        return groups.sorted { $0.owner < $1.owner }
    }

    private func kindLabel(_ kind: HookRegistration.OwnerKind) -> String {
        switch kind {
        case .brew: return "Brew"
        case .vendored: return "Vendored"
        case .handInstalled: return "Hand-installed"
        case .plugin: return "Plugin"
        case .unknown: return "Unknown"
        }
    }

    private func hooksSection(_ report: MachineReport) -> some View {
        Section("Hooks") {
            let groups = hookGroups(report)
            if groups.isEmpty {
                Text("No hook registrations").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(groups) { group in hookRow(group) }
            }
        }
    }

    @ViewBuilder
    private func hookRow(_ group: HookGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.owner).bold()
                Text("(\(kindLabel(group.kind)))").foregroundStyle(.secondary)
                if group.heavy {
                    Text("Heavy").font(.caption2).padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                if group.instances > 0 {
                    Button("Kill Instances…") { pendingHookKill = group }
                }
                if group.kind == .plugin {
                    Text("Managed by Claude Code").font(.caption2).foregroundStyle(.secondary)
                } else if model.parkedOwners.contains(group.owner) {
                    Button("Restore Hooks") {
                        let owner = group.owner
                        Task { resultMessage = await model.restoreHook(owner: owner) }
                    }
                } else {
                    Button("Disable…") { pendingDisable = group }
                }
            }
            Text(group.events.joined(separator: ", ") + " · \(Int(group.spawnsPerHour))/h expected")
                .font(PopupFont.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(group.instances) live" + (group.helpers > 0 ? " + \(group.helpers) helpers" : ""))
                Text("oldest \(group.oldestSeconds / 60) min")
                if group.stuckCount > 0 { Text("\(group.stuckCount) stuck").foregroundStyle(.red) }
            }
            .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: runaways

    private func runawaysSection(_ report: MachineReport) -> some View {
        Section("Runaways") {
            if report.runaways.isEmpty {
                Text("Nothing flagged").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(report.runaways) { runaway in runawayRow(runaway, sessions: report.sessions) }
            }
        }
    }

    private func runawayRow(_ runaway: Runaways.Runaway, sessions: [SessionHealth]) -> some View {
        let sessionName = runaway.sessionPid.flatMap { pid in sessions.first { $0.pid == pid }?.name }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(runaway.rule).bold()
                Text(runaway.why).foregroundStyle(.secondary)
                Spacer()
                Button("Kill…") { pendingKill = runaway }
            }
            .font(PopupFont.caption)
            HStack(spacing: 8) {
                Text("\(runaway.rssMB) MB")
                Text("\(runaway.elapsedSeconds / 60) min")
                if let sessionName { Text(sessionName) }
            }
            .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(runaway.command)
                .font(PopupFont.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).help(runaway.command)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: residue

    private var reclaimMessage: String {
        let residue = model.report?.residue
        return "\(residue?.staleSockets ?? 0) stale sockets, \(residue?.staleSessionEnvs ?? 0) session-env dirs, and temp files older than an hour that no process holds open"
    }

    private func residueSection(_ report: MachineReport) -> some View {
        let r = report.residue
        return Section("Residue") {
            Text("\(r.staleSockets) stale sockets, \(r.staleSessionEnvs) stale session-env dirs, \(r.tempEntries.map { "\($0)" } ?? "?") temp entries" + MachineReport.tempBreakdown(r.tempByOwner))
                .font(PopupFont.caption).monospacedDigit()
            Text("transcripts \(bytesString(r.transcriptsBytes)) · plugin cache \(bytesString(r.pluginCacheBytes)) · claude-mem \(bytesString(r.memBytes))")
                .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Reclaim…") { pendingReclaim = true }
        }
    }

    private func bytesString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: sessions

    private func sessionsSection(_ report: MachineReport?) -> some View {
        Section("Sessions") {
            Stepper("Notify when a session is idle for \(Int(model.idleHours)) h",
                    value: $model.idleHours, in: 1...72)
            if let sessions = report?.sessions, !sessions.isEmpty {
                ForEach(sessions) { session in sessionRow(session) }
            } else {
                Text("No sessions").foregroundStyle(.secondary).font(PopupFont.caption)
            }
        }
        .settingsAnchor("Machine/Sessions")
    }

    private func sessionRow(_ session: SessionHealth) -> some View {
        HStack {
            Text(session.name).lineLimit(1)
            Spacer()
            Text("\(session.ageSeconds / 60) min")
            Text("\(session.rssMB) MB")
            Text("\(Int(session.idleHours())) h idle")
            Text((session.cwd as NSString).lastPathComponent)
                .foregroundStyle(.secondary).help(session.cwd)
                .accessibilityValue(session.cwd)   // the tooltip is mouse-only
        }
        .font(PopupFont.caption).monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

extension MachinePane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Watch this Mac",
                            keywords: ["watch", "health", "monitor", "guardian"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Notify about hooks (new, stuck, fanned out)",
                            keywords: ["hooks", "notify", "stuck", "runaway"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Notify about the temp directory",
                            keywords: ["temp", "residue", "disk"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Sessions", label: "Notify when a session is idle",
                            keywords: ["idle", "sessions", "hours"], anchor: "Machine/Sessions"),
    ]
}
