import SwiftUI
import InfinitusCore

/// Backlog item 6 addendum: surface the two Claude Code settings the resume
/// flow depends on — explain, show the EFFECTIVE value, offer the write.
/// Users without cmux have only the peer socket; for them these settings ARE
/// the reliability fix. A managed (org) value wins over the user file, so
/// the write buttons disable themselves rather than claim a success that
/// changes nothing.
@MainActor
final class ResumeReliabilityModel: ObservableObject {
    struct Row {
        let key: String
        let title: String
        let explanation: String
        let recommended: JSONValue
        var effective: ClaudeCodeConfig.Effective?
        var error: String?
    }

    @Published var rows: [Row] = [
        Row(
            key: "autoContinueAtUsageLimit",
            title: "Auto-continue at usage limit",
            explanation: "While off, a limit stop shows a dialog that blocks "
                + "the resume nudge until you answer it at the keyboard.",
            recommended: .bool(true)
        ),
        Row(
            key: "crossSessionInbound",
            title: "Cross-session messages",
            explanation: "While unset, the resume nudges are held for review "
                + "(its socket message carries no permission-mode attestation). "
                + "\"accept\" delivers them immediately — but any local process "
                + "that reaches a session's socket can then inject an "
                + "unreviewed user turn.",
            recommended: .string("accept")
        ),
    ]

    let config: ClaudeCodeConfig
    init(config: ClaudeCodeConfig = .standard()) { self.config = config }

    func load() {
        for i in rows.indices {
            rows[i].effective = try? config.effectiveValue(rows[i].key)
        }
    }

    func applyRecommended(_ index: Int) {
        do {
            try config.writeUserValue(rows[index].key, rows[index].recommended)
            rows[index].error = nil
            load()
        } catch {
            rows[index].error = "\(error)"
        }
    }
}

/// The nudge-reliability rows, embedded in the swapd engine pane (user
/// 2026-08-30: the settings gating the resume nudges belong with the
/// engine that triggers them). Status-first rendering: a green check when a
/// row already matches the recommendation, an amber warning plus the
/// one-click fix when it doesn't.
struct ResumeReliabilitySection: View {
    @ObservedObject var model: ResumeReliabilityModel

    private var readyCount: Int {
        model.rows.filter { matches($0) }.count
    }

    var body: some View {
        Section {
            ForEach(Array(model.rows.enumerated()), id: \.element.key) { index, row in
                rowView(index, row)
            }
            Text("These are Claude Code's settings, not the engine's — they "
                 + "decide whether Infinitus's resume nudges actually reach a "
                 + "stopped session. Changes apply to sessions started "
                 + "afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Resume nudges — Claude Code side")
                Spacer()
                Text(readyCount == model.rows.count
                     ? "nudges ready" : "\(readyCount)/\(model.rows.count) ready")
                    .font(.caption)
                    .foregroundStyle(readyCount == model.rows.count
                                     ? Color.green : .orange)
            }
        }
        .onAppear { model.load() }
    }

    private func matches(_ row: ResumeReliabilityModel.Row) -> Bool {
        row.effective?.value == row.recommended
    }

    @ViewBuilder private func rowView(
        _ index: Int, _ row: ResumeReliabilityModel.Row
    ) -> some View {
        let good = matches(row)
        let managed = row.effective?.source == .managed
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: good ? "checkmark.circle.fill"
                                       : "exclamationmark.triangle.fill")
                    .foregroundStyle(good ? Color.green : .orange)
                Text(row.title)
                Spacer()
                Text(stateText(row) + (managed ? " · managed" : ""))
                    .font(.caption)
                    .foregroundStyle(good ? Color.secondary : .orange)
                if !good && !managed {
                    Button("Set \(row.recommended.editableText)") {
                        model.applyRecommended(index)
                    }
                }
            }
            Text(row.explanation)
                .font(.caption).foregroundStyle(.secondary)
            if managed && !good {
                Text("Managed by your organization — the user file cannot override it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = row.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func stateText(_ row: ResumeReliabilityModel.Row) -> String {
        guard let effective = row.effective else { return "not set" }
        if case .bool(let b) = effective.value { return b ? "on" : "off" }
        return effective.value.editableText
    }
}
