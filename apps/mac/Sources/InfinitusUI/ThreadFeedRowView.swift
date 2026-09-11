import SwiftUI
import InfinitusCore

/// One presented row of a session's timeline (#223 phase 2's reducer,
/// drawn): messages and prompt cards reuse `SessionFeedRow`; tool groups,
/// turn folds, the live slot and the sub-agent card are native here.
/// Both clients render through this, the way they share `SessionFeedRow`.
public struct ThreadFeedRowView<Thumb: View>: View {
    let row: ThreadFeedRow
    @Binding var expandedTurns: Set<String>
    @Binding var expandedGroups: Set<String>
    @Binding var expandedPeers: Set<String>
    let thumbnail: (String) -> Thumb

    public init(row: ThreadFeedRow, expandedTurns: Binding<Set<String>>, expandedGroups: Binding<Set<String>>,
                expandedPeers: Binding<Set<String>>, @ViewBuilder thumbnail: @escaping (String) -> Thumb) {
        self.row = row
        self._expandedTurns = expandedTurns
        self._expandedGroups = expandedGroups
        self._expandedPeers = expandedPeers
        self.thumbnail = thumbnail
    }

    /// Chrome rows (toggles, folds, chips) sit tight; bubbles breathe.
    public static func isChrome(_ row: ThreadFeedRow) -> Bool {
        if case .message = row.kind { return false }
        if case .agentSpawn = row.kind { return false }
        return true
    }

    public var body: some View {
        switch row.kind {
        case .message(let m):
            SessionFeedRow(item: Self.item(m), expandedPeers: $expandedPeers, thumbnail: thumbnail)
        case .activityGroup(let entries):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries, id: \.id) { entry($0) }
            }
        case .workToggle(let toggle):
            workToggle(toggle)
        case .turnFold(let fold):
            turnFold(fold)
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .agentSpawn(let spawn):
            agentCard(spawn)
        }
    }

    static func item(_ m: SessionTimeline.Message) -> SessionFeedItem {
        SessionFeedItem(kind: m.role == .user ? .user : .assistant, text: m.text, at: m.createdAt,
                        images: m.images, sender: m.sender)
    }

    // MARK: Chrome

    private func workToggle(_ t: WorkToggle) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if t.expanded { expandedGroups.remove(t.groupId) } else { expandedGroups.insert(t.groupId) }
            }
        } label: {
            HStack(spacing: 6) {
                if t.live {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: t.hasFailure ? "exclamationmark.circle" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(!t.hasFailure && t.expanded ? 90 : 0))
                }
                Text(t.summary).font(.caption.weight(.medium)).lineLimit(1)
                if !t.live, t.hiddenCount > 1 {
                    Text("· \(t.hiddenCount)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.hasFailure ? Color.red : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel(t.summary)
        .accessibilityHint(t.expanded ? "Hides the calls" : "Shows the calls")
    }

    private func turnFold(_ f: TurnFold) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if f.expanded { expandedTurns.remove(row.turnId) } else { expandedTurns.insert(row.turnId) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(f.expanded ? 90 : 0))
                Text(f.label).font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityHint(f.expanded ? "Hides what happened" : "Shows what happened")
    }

    // MARK: Entries

    @ViewBuilder private func entry(_ e: WorkEntry) -> some View {
        switch e.kind {
        case "approval.requested":
            SessionFeedRow(item: SessionFeedItem(kind: .permission, text: e.summary, at: e.createdAt,
                                                 toolName: e.payload["toolName"]?.stringValue),
                           expandedPeers: $expandedPeers, thumbnail: thumbnail)
        case "user-input.requested":
            SessionFeedRow(item: SessionFeedItem(kind: .question, text: e.summary, at: e.createdAt,
                                                 options: Self.options(e)),
                           expandedPeers: $expandedPeers, thumbnail: thumbnail)
        case "user-input.resolved":
            Label(e.payload["answers"]?.stringValue.map { "Answered: \($0)" } ?? "Answered", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case "runtime.warning" where e.payload["code"]?.stringValue == "held":
            Label(e.summary, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
        case "runtime.warning":
            Label(e.summary, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.red)
        case "runtime.error":
            Label(e.summary, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        case "context-compaction":
            Label(e.summary, systemImage: "arrow.down.right.and.arrow.up.left").font(.caption).foregroundStyle(.secondary)
        case "turn.plan.updated":
            Label(e.summary, systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
        case let kind where kind.hasPrefix("tool."):
            toolChip(e)
        default:
            Text(e.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toolChip(_ e: WorkEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if e.status == .inProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: Self.icon(e.action)).font(.caption2)
                        .foregroundStyle(e.status == .failure ? Color.red : Color.primary)
                }
                Text(e.summary)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                if !e.changedFiles.isEmpty, e.changedFiles.count > 1 {
                    Text("· \(e.changedFiles.count) files").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let detail = e.detail {
                Text(detail).font(.caption2).foregroundStyle(e.status == .failure ? .red : .secondary)
                    .lineLimit(2).padding(.leading, 18)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    static func icon(_ action: WorkEntry.Action) -> String {
        switch action {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .command: return "terminal"
        case .browser: return "globe"
        case .codeSearch, .search: return "magnifyingglass"
        case .other: return "wrench"
        case .update: return "info.circle"
        }
    }

    /// The first question's option labels — what the `.question` row lists.
    static func options(_ e: WorkEntry) -> [String]? {
        guard let q = e.payload["questions"]?.arrayValue?.first?.objectValue,
              let opts = q["options"]?.arrayValue else { return nil }
        let labels = opts.compactMap { $0.objectValue?["label"]?.stringValue }
        return labels.isEmpty ? nil : labels
    }

    // MARK: Sub-agents

    private func agentCard(_ spawn: AgentSpawn) -> some View {
        let anyRunning = spawn.members.contains(where: \.running)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(anyRunning ? Color.accentColor : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(spawn.title).font(.subheadline.weight(.semibold))
                ForEach(spawn.members, id: \.id) { m in
                    HStack(spacing: 6) {
                        Text("\(m.agentType) — \(m.title)").lineLimit(1)
                        Text(m.failed ? "failed" : m.running ? (m.lastTool.map { "running · \($0)" } ?? "running") : "done")
                            .foregroundStyle(m.failed ? Color.red : Color.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
