import SwiftUI
import InfinitusCore

/// Settings › Profiles (#165): the saved ways to start a session. Each
/// row opens to its fields; the phone's Start a session shows them as
/// chips. Style follows LockPane: a grouped Form.
struct ProfilesPane: View {
    @ObservedObject var profiles: SessionProfilesModel
    @State private var newName = ""
    @State private var expanded: Set<String> = []
    /// The profile whose Remove is being confirmed.
    @State private var confirmRemove: SessionProfile?

    var body: some View {
        Form {
            if !profiles.profiles.isEmpty {
                Section {
                    ForEach(profiles.profiles) { profile in
                        ProfileRow(profile: profile, profiles: profiles,
                                   confirmRemove: $confirmRemove,
                                   expanded: Binding(get: { expanded.contains(profile.name) },
                                                     set: { open in if open { expanded.insert(profile.name) } else { expanded.remove(profile.name) } }))
                    }
                } header: {
                    Text("Profiles")
                }
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newName, prompt: Text("Review PRs"))
                        .onSubmit(add)
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = profiles.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("New profile")
            } footer: {
                Text("A profile is a named way to start a session \u{2014} folder, engine, "
                     + "permissions, model, an appended system prompt and a first prompt. "
                     + "The phone offers each one as a chip in Start a session.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(confirmRemove?.name ?? "this profile")?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { profile in
            Button("Remove", role: .destructive) {
                profiles.remove(profile.name)
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { profile in
            Text("Start a session stops offering \(profile.name) on the phone and on this "
                 + "Mac. Sessions already started keep running \u{2014} you can make the "
                 + "profile again any time.")
        }
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
    @Binding var confirmRemove: SessionProfile?
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
            TextField("Model", text: field(\.model), prompt: Text("the engine's default"))
            TextField("Appended system prompt", text: field(\.systemPrompt), axis: .vertical)
                .lineLimit(2...6)
            TextField("First prompt", text: field(\.prompt), axis: .vertical)
                .lineLimit(1...4)
            TextField("Allowed without asking (Edit, Write, Bash git)", text: allowField)
                .font(.body.monospaced())
            HStack {
                Spacer()
                Button("Remove\u{2026}", role: .destructive) { confirmRemove = profile }
            }
        } label: {
            HStack {
                Text(profile.name)
                Spacer()
                Text(profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The allow-list as one comma-separated line; parsed on the way in.
    private var allowField: Binding<String> {
        Binding(get: { (profile.allowTools ?? []).joined(separator: ", ") },
                set: { value in
                    var next = profile
                    next.allowTools = SessionProfiles.parseAllowList(value)
                    profiles.set(next)
                })
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
