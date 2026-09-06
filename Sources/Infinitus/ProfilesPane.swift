import SwiftUI
import InfinitusCore

/// Settings › Profiles (#165): the saved ways to start a session. Each
/// row opens to its fields; the phone's Start a session shows them as
/// chips. Style follows LockPane: a grouped Form.
struct ProfilesPane: View {
    @ObservedObject var profiles: SessionProfilesModel
    @State private var newName = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            Section {
                if profiles.profiles.isEmpty {
                    Text("No profiles yet. A profile is a named way to start a session — folder, engine, "
                         + "permissions, model, an appended system prompt, a first prompt — offered on the phone "
                         + "as a chip in Start a session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(profiles.profiles) { profile in
                    ProfileRow(profile: profile, profiles: profiles,
                               expanded: Binding(get: { expanded.contains(profile.name) },
                                                 set: { open in if open { expanded.insert(profile.name) } else { expanded.remove(profile.name) } }))
                }
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newName)
                        .onSubmit(add)
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("`infinitusctl profiles`, `profile-set <name> --cwd … --mode … --model …` and "
                     + "`profile-remove <name>` manage the same list.")
                    .font(.caption).foregroundStyle(.secondary)
                if let err = profiles.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        profiles.set(SessionProfile(name: name))
        expanded.insert(name)
        newName = ""
    }
}

private struct ProfileRow: View {
    let profile: SessionProfile
    @ObservedObject var profiles: SessionProfilesModel
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TextField("Folder on this Mac", text: field(\.cwd))
                .font(.body.monospaced())
            Picker("Engine", selection: field(\.engine, default: "claude")) {
                Text("Claude Code").tag("claude")
                Text("Codex CLI").tag("codex")
            }
            Picker("Permissions", selection: field(\.permissionMode)) {
                Text("Supervised").tag("")
                ForEach(SessionStart.permissionModes, id: \.mode) { Text($0.label).tag($0.mode) }
            }
            TextField("Model (e.g. opus, sonnet — blank = default)", text: field(\.model))
            TextField("Appended system prompt", text: field(\.systemPrompt), axis: .vertical)
                .lineLimit(2...6)
            TextField("First prompt", text: field(\.prompt), axis: .vertical)
                .lineLimit(1...4)
            HStack {
                Spacer()
                Button("Remove", role: .destructive) { profiles.remove(profile.name) }
            }
        } label: {
            HStack {
                Text(profile.name)
                Spacer()
                Text(profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Every edit writes the whole row through the model, so the file
    /// and the phone stay in step with what the field shows.
    private func field(_ key: WritableKeyPath<SessionProfile, String?>, default fallback: String = "") -> Binding<String> {
        Binding(get: { profile[keyPath: key] ?? fallback },
                set: { value in
                    var next = profile
                    next[keyPath: key] = value
                    profiles.set(next)
                })
    }
}
