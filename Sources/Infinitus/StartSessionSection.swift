import SwiftUI
import InfinitusCore
import InfinitusUI

/// The sessions popover's Start a session (#163 / #165, the Mac half of
/// the phone sheet): a profile chip fills the form, then folder, engine,
/// permissions and a first prompt — `SessionLauncher.start` opens cmux
/// or Terminal, and the birth is recorded so the row wears its chip.
struct StartSessionSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    @State private var profile: SessionProfile?
    @State private var cwd = ""
    @State private var custom = ""
    @State private var engine = "claude"
    @State private var permissionMode = ""
    @State private var prompt = ""
    @State private var starting = false
    @State private var note: String?

    private static let other = "__other__"
    private var recent: [String] { UserDefaults.standard.stringArray(forKey: "recent_cwds") ?? [] }
    private var chosenFolder: String { cwd == Self.other ? custom.trimmingCharacters(in: .whitespaces) : cwd }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.sessionProfiles.profiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.sessionProfiles.profiles) { p in
                                Button { apply(p) } label: {
                                    Text(p.name)
                                        .font(PopupFont.caption2.weight(profile?.name == p.name ? .semibold : .regular))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(profile?.name == p.name
                                                                   ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .help(p.summary)
                            }
                        }
                    }
                }
                Picker("Folder", selection: $cwd) {
                    ForEach(recent, id: \.self) { path in
                        Text((path as NSString).lastPathComponent).tag(path)
                    }
                    Text("Another folder…").tag(Self.other)
                }
                .font(PopupFont.caption)
                if cwd == Self.other {
                    TextField("~/path/on/this/Mac", text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .font(PopupFont.caption.monospaced())
                }
                Picker("Engine", selection: $engine) {
                    Text("Claude Code").tag("claude")
                    Text("Codex CLI").tag("codex")
                }
                .pickerStyle(.segmented)
                .font(PopupFont.caption)
                if engine == "claude" {
                    Picker("Permissions", selection: $permissionMode) {
                        Text("Supervised").tag("")
                        ForEach(SessionStart.permissionModes, id: \.mode) { Text($0.label).tag($0.mode) }
                    }
                    .font(PopupFont.caption)
                }
                TextField("First prompt (optional)", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(PopupFont.caption)
                    .lineLimit(1...3)
                HStack {
                    if let note {
                        Text(note).font(PopupFont.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                    Spacer()
                    Button(starting ? "Starting…" : "Start") { start() }
                        .font(PopupFont.caption)
                        .disabled(starting || chosenFolder.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
            .onAppear { if cwd.isEmpty { cwd = recent.first ?? Self.other } }
        } label: {
            Text("Start a session").font(PopupFont.caption).foregroundStyle(.secondary)
        }
    }

    /// Fills the form from a profile; a field the profile leaves out
    /// keeps what is there.
    private func apply(_ p: SessionProfile) {
        profile = p
        if let folder = p.cwd, !folder.isEmpty {
            if recent.contains(folder) { cwd = folder } else { cwd = Self.other; custom = folder }
        }
        if let e = p.engine, !e.isEmpty { engine = e }
        if let m = p.permissionMode { permissionMode = m }
        if let first = p.prompt, !first.isEmpty, prompt.isEmpty { prompt = first }
    }

    private func start() {
        starting = true
        note = nil
        let claude = engine == "claude"
        let request = SessionStart.Request(cwd: chosenFolder, engine: engine,
                                           prompt: prompt.isEmpty ? nil : prompt,
                                           permissionMode: claude && !permissionMode.isEmpty ? permissionMode : nil,
                                           model: claude ? profile?.model : nil,
                                           systemPrompt: claude ? profile?.systemPrompt : nil,
                                           profile: profile?.name)
        let host = model.sessionHost
        Task.detached(priority: .userInitiated) {
            let reply = SessionLauncher.start(request, preferredHost: host)
            await MainActor.run {
                starting = false
                if reply.outcome == "started" {
                    if let pid = reply.pid, let birth = SessionBirth(request: request) {
                        model.recordBirth(pid: pid, birth)
                    }
                    model.logEvent("other", icon: "terminal", "started a session in \((chosenFolder as NSString).lastPathComponent)\(profile.map { " (profile \($0.name))" } ?? "")\(reply.host.map { " via \($0)" } ?? "")")
                    prompt = ""
                    model.sessionsShown = false
                } else {
                    note = reply.detail ?? reply.outcome
                }
            }
        }
    }
}
