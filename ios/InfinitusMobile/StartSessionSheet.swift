import InfinitusCore
import SwiftUI

/// Start a session on the Mac from the phone (#91): a repository from
/// the folders sessions have run in (or any path), the engine, an
/// optional first prompt. Start opens a terminal on the Mac and, once
/// the session registers, its chat here.
struct StartSessionSheet: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var custom = ""
    @State private var engine = "claude"
    @State private var prompt = ""
    /// "" = supervised (Claude Code's default: every tool asks).
    @State private var permissionMode = ""
    /// The chip applied last (#165): its model and system prompt ride
    /// along unseen; the visible fields it set can still be changed.
    @State private var profile: SessionProfile?
    @State private var starting = false
    @State private var error: String?

    private static let other = "__other__"

    var body: some View {
        NavigationStack {
            Form {
                if let profiles = model.snapshot?.profiles, !profiles.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(profiles) { p in
                                    Button { apply(p) } label: {
                                        Text(p.name)
                                            .font(.subheadline.weight(profile?.name == p.name ? .semibold : .regular))
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(Capsule().fill(profile?.name == p.name ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if let profile {
                            Text(profile.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Profile")
                    }
                }
                Section("Repository") {
                    Picker("Repository", selection: $cwd) {
                        ForEach(model.recentCwds, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                        Text("Another folder…").tag(Self.other)
                    }
                    .pickerStyle(.menu)
                    if cwd == Self.other {
                        TextField("~/path/on/the/Mac", text: $custom)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                    } else if !cwd.isEmpty {
                        Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Section("Engine") {
                    Picker("Engine", selection: $engine) {
                        Text("Claude Code").tag("claude")
                        Text("Codex CLI").tag("codex")
                    }
                    .pickerStyle(.segmented)
                }
                if engine == "claude" {
                    Section {
                        Picker("Permissions", selection: $permissionMode) {
                            Text("Supervised").tag("")
                            ForEach(SessionStart.permissionModes, id: \.mode) { Text($0.label).tag($0.mode) }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("Permissions")
                    } footer: {
                        Text(permissionFootnote)
                    }
                }
                Section("First prompt") {
                    TextField("Optional — what to start on", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Start a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { start() }.disabled(chosen.isEmpty)
                    }
                }
            }
            .onAppear { if cwd.isEmpty { cwd = model.recentCwds.first ?? Self.other } }
        }
    }

    /// Fills the form from a profile; a field the profile leaves out
    /// keeps what is there.
    private func apply(_ p: SessionProfile) {
        profile = p
        if let folder = p.cwd, !folder.isEmpty {
            if model.recentCwds.contains(folder) { cwd = folder } else { cwd = Self.other; custom = folder }
        }
        if let e = p.engine, !e.isEmpty { engine = e }
        if let m = p.permissionMode { permissionMode = m }
        if let first = p.prompt, !first.isEmpty, prompt.isEmpty { prompt = first }
    }

    private var permissionFootnote: String {
        switch permissionMode {
        case "acceptEdits": return "File edits go through without asking; other tools still ask here."
        case "auto": return "Claude decides what needs asking."
        case "bypassPermissions": return "Nothing asks. Only for folders you trust completely."
        default: return "Every tool asks, and the prompts show up on this phone."
        }
    }

    private var chosen: String {
        (cwd == Self.other ? custom : cwd).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        starting = true
        error = nil
        let request = SessionStart.Request(cwd: chosen, engine: engine,
                                           prompt: prompt.isEmpty ? nil : prompt,
                                           permissionMode: engine == "claude" && !permissionMode.isEmpty ? permissionMode : nil,
                                           model: engine == "claude" ? profile?.model : nil,
                                           systemPrompt: engine == "claude" ? profile?.systemPrompt : nil,
                                           profile: profile?.name)
        Task {
            do {
                let reply = try await NetworkFleetMirror.shared.startSession(request)
                guard reply.outcome == "started" else {
                    error = reply.detail ?? reply.outcome
                    starting = false
                    return
                }
                if let pid = reply.pid { model.requestedPid = pid }
                dismiss()
                await model.refresh()
            } catch {
                self.error = error.localizedDescription
                starting = false
            }
        }
    }
}
