import SwiftUI
import InfinitusCore

/// "Add grant" (#220 §7.1): who, which sessions, what they may do.
struct TeamGrantSheet: View {
    @ObservedObject var team: TeamModel
    let snap: TeamSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var audienceTag = "leaders"
    @State private var pickedKids: Set<String> = []
    @State private var allSessions = true
    @State private var pickedSessions: Set<String> = []
    @State private var capabilities: Set<String> = [TeamGrants.view]
    @State private var live: [(id: String, label: String)] = []

    static let meanings: [(String, String)] = [
        (TeamGrants.view, "read the session's live feed"),
        (TeamGrants.send, "type a prompt into the session"),
        (TeamGrants.approve, "answer a tool prompt with Yes or Esc"),
        (TeamGrants.mode, "switch the session's mode"),
        (TeamGrants.resume, "nudge a stalled session"),
        (TeamGrants.key, "press a single key (y, n, 1–9, enter, esc)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let teammates drive your sessions").font(.headline)
            Picker("Who", selection: $audienceTag) {
                Text("Leaders").tag("leaders")
                Text("Whole team").tag("team")
                Text("Only these members").tag("members")
            }
            if audienceTag == "members" {
                ForEach(snap.members.filter { !$0.isMe }) { m in
                    Toggle(m.name, isOn: Binding(get: { pickedKids.contains(m.kid) },
                                                 set: { on in if on { pickedKids.insert(m.kid) } else { pickedKids.remove(m.kid) } }))
                }
            }
            Picker("Sessions", selection: $allSessions) {
                Text("All sessions, now and later").tag(true)
                Text("Only the ones I pick").tag(false)
            }
            if !allSessions {
                if live.isEmpty { Text("No live sessions right now.").font(.caption).foregroundStyle(.secondary) }
                ForEach(live, id: \.id) { s in
                    Toggle(s.label, isOn: Binding(get: { pickedSessions.contains(s.id) },
                                                  set: { on in if on { pickedSessions.insert(s.id) } else { pickedSessions.remove(s.id) } }))
                }
            }
            Text("What they may do").font(.subheadline)
            ForEach(Self.meanings, id: \.0) { cap, meaning in
                Toggle(isOn: Binding(get: { capabilities.contains(cap) },
                                     set: { on in if on { capabilities.insert(cap) } else { capabilities.remove(cap) } })) {
                    VStack(alignment: .leading) { Text(cap); Text(meaning).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add grant") {
                    Task { await team.addGrant(audience: audience, sessions: sessions, capabilities: capabilities); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            live = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
                .map { ($0.sessionId, $0.name ?? URL(fileURLWithPath: $0.cwd).lastPathComponent) }
        }
    }

    private var audience: TeamRoster.ShareTarget {
        switch audienceTag {
        case "team": .team
        case "members": .members(pickedKids.sorted())
        default: .leaders
        }
    }
    private var sessions: TeamGrants.Sessions { allSessions ? .all : .some(pickedSessions.sorted()) }
    private var valid: Bool {
        !capabilities.isEmpty && (audienceTag != "members" || !pickedKids.isEmpty) && (allSessions || !pickedSessions.isEmpty)
    }
}
