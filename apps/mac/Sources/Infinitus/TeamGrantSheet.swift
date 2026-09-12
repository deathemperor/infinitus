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
    @State private var preauthorized: Set<String> = []
    @State private var expiryIndex = 0
    @State private var live: [(id: String, label: String)] = []

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
            ForEach(TeamGrants.tiers, id: \.name) { tier in
                Text(tier.name).font(.subheadline)
                if let asks = tier.asks {
                    Text(asks).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(tier.capabilities, id: \.self) { cap in
                    capabilityRow(cap, tier: tier)
                }
            }
            Picker("Expires", selection: $expiryIndex) {
                ForEach(Array(TeamGrants.expiryChoices.enumerated()), id: \.offset) { index, choice in
                    Text(choice.label).tag(index)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add grant") {
                    let expires = TeamGrants.expiryChoices[expiryIndex].seconds.map { Int(Date().timeIntervalSince1970) + $0 }
                    Task {
                        await team.addGrant(audience: audience, sessions: sessions, capabilities: capabilities,
                                            preauthorized: preauthorized, expires: expires)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            live = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
                .map { ($0.sessionId, $0.name ?? URL(fileURLWithPath: $0.cwd).lastPathComponent) }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ cap: String, tier: TeamGrants.Tier) -> some View {
        let meaning = TeamGrants.meanings[cap] ?? ""
        let on = capabilities.contains(cap)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { on }, set: { newValue in
                if newValue { capabilities.insert(cap) } else { capabilities.remove(cap); preauthorized.remove(cap) }
            })) {
                VStack(alignment: .leading) { Text(cap); Text(meaning).font(.caption).foregroundStyle(.secondary) }
            }
            if cap == TeamGrants.delete {
                Text("always asks").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            } else if tier.asks != nil, on, !TeamGrants.neverPreauthorized.contains(cap) {
                Toggle("without asking", isOn: Binding(get: { preauthorized.contains(cap) },
                                                       set: { newValue in if newValue { preauthorized.insert(cap) } else { preauthorized.remove(cap) } }))
                    .controlSize(.small)
                    .padding(.leading, 20)
            }
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
