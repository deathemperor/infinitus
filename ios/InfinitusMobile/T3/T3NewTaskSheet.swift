import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's New Task flow (C-4, spec §5 "New Task"): a form sheet at
/// 0.6 / 0.95 that opens on "Choose project" (`NewTaskRouteScreen.tsx`)
/// and pushes the draft (`NewTaskDraftScreen.tsx`) — the prompt hero
/// "What should we build in <project>?", the "on <Mac>" row, a settings
/// row for what the Mac's start route takes (engine, permissions,
/// headless, profile), and the expanded composer whose send starts the
/// session. Projects are the Mac's recent folders; T3's branch row has
/// no counterpart in `SessionStart.Request` and is left out.
struct T3NewTaskSheet: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3
    @State private var path: [String] = []
    @State private var macId: String?
    @State private var adding = false
    @State private var customPath = ""

    var body: some View {
        NavigationStack(path: $path) {
            chooser
                .navigationDestination(for: String.self) { cwd in
                    T3NewTaskDraft(model: model, cwd: cwd, macId: $macId, changeProject: { path = [] })
                }
        }
        .presentationDetents([.fraction(0.6), .fraction(0.95)])
        .presentationDragIndicator(.visible)
        .onAppear { if macId == nil { macId = model.defaultTargetMacId } }
    }

    // MARK: Choose project

    private var projects: [String] { model.recentCwds(macId: macId) }

    private var chooser: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !model.others.isEmpty { macRow }
                if projects.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(projects.enumerated()), id: \.element) { i, cwd in
                            if i > 0 { Divider().overlay(t3.mobile.borderSubtle.color) }
                            Button { path = [cwd] } label: { projectRow(cwd) }
                                .buttonStyle(.plain)
                        }
                    }
                    .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                if adding { addRow }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(t3.mobile.sheet.color.ignoresSafeArea())
        .navigationTitle("Choose project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { adding.toggle() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add project")
            }
        }
    }

    /// T3 lists projects per environment; the phone's is the Mac.
    private var macRow: some View {
        Menu {
            Picker("Mac", selection: $macId) {
                Text(model.machineName(macId: nil)).tag(String?.none)
                ForEach(model.others) { other in Text(other.pairing.name).tag(String?.some(other.id)) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(t3.mobile.iconMuted.color)
                Text("on \(model.machineName(macId: macId))").font(T3Font.mobile(.sm, .medium))
                    .foregroundStyle(t3.mobile.foreground.color)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t3.mobile.iconMuted.color)
            }
            .padding(.horizontal, 8).frame(height: 44)
        }
    }

    private func projectRow(_ cwd: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(t3.mobile.iconMuted.color)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: cwd).lastPathComponent).font(T3Font.mobile(.base, .bold))
                    .foregroundStyle(t3.mobile.foreground.color)
                Text(cwd).font(T3Font.mobile(.xs)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t3.mobile.chevron.color)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No projects yet").font(T3Font.mobile(.lg, .bold)).foregroundStyle(t3.mobile.foreground.color)
            Text("Folders a session has run in on \(model.machineName(macId: macId)) show up here. Add one by its path to start there.")
                .font(T3Font.mobile(.sm)).multilineTextAlignment(.center)
                .foregroundStyle(t3.mobile.foregroundMuted.color)
            Button { adding = true } label: {
                Text("Add new project").font(T3Font.mobile(.sm, .bold)).foregroundStyle(t3.mobile.primaryForeground.color)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(t3.mobile.primary.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 32)
        .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("~/path/on/the/Mac", text: $customPath)
                .font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foreground.color)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(useCustomPath)
            Button(action: useCustomPath) {
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(t3.mobile.primaryForeground.color)
                    .frame(width: 32, height: 32)
                    .background(customPath.trimmingCharacters(in: .whitespaces).isEmpty ? t3.mobile.subtle.color : t3.mobile.primary.color, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(customPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
    }

    private func useCustomPath() {
        let cwd = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return }
        path = [cwd]
    }
}

/// The draft: hero, context rows, composer. Starts the session on send.
struct T3NewTaskDraft: View {
    @ObservedObject var model: MirrorModel
    let cwd: String
    @Binding var macId: String?
    let changeProject: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3
    @State private var prompt = ""
    @State private var focused = false
    @State private var engine = "claude"
    @State private var permissionMode = ""
    @State private var headless = false
    @State private var profile: SessionProfile?
    @State private var showSettings = false
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            t3.mobile.sheet.color.ignoresSafeArea()
            ScrollView {
                hero.padding(.top, 72).padding(.bottom, 236)
            }
            .scrollDismissesKeyboard(.interactively)
            composer.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .sheet(isPresented: $showSettings) {
            T3NewTaskSettings(model: model, macId: macId, engine: $engine, permissionMode: $permissionMode,
                              headless: $headless, profile: $profile)
                .t3(platform: .mobile)
                .presentationDetents([.fraction(0.6)])
        }
        .onAppear { focused = true }
    }

    private var repo: String { URL(fileURLWithPath: cwd).lastPathComponent }

    // MARK: hero (`new-task-hero`)

    private var hero: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("What should we build").font(T3Font.mobile(.xxl, .medium)).tracking(-0.5)
                    .foregroundStyle(t3.mobile.foreground.color)
                HStack(spacing: 0) {
                    Text("in ").font(T3Font.mobile(.xxl, .medium)).tracking(-0.5)
                    Button(action: changeProject) {
                        Text(repo).font(T3Font.mobile(.xxl, .medium)).tracking(-0.5).lineLimit(1)
                            .layoutPriority(-1)
                            .overlay(alignment: .bottom) { Rectangle().fill(t3.mobile.foregroundMuted.color).frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change project from \(repo)")
                    Text("?").font(T3Font.mobile(.xxl, .medium)).tracking(-0.5)
                }
                .frame(maxWidth: 300)
                .foregroundStyle(t3.mobile.foreground.color)
            }
            inlineControl(icon: "laptopcomputer", label: "on \(model.machineName(macId: macId))",
                          chevron: model.others.isEmpty ? nil : "chevron.right") {
                guard !model.others.isEmpty else { return }
                cycleMac()
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// T3's `ComposerInlineControl`: 44 pt row, 16 pt icon, sm label,
    /// a 10 pt chevron when it opens something.
    private func inlineControl(icon: String, label: String, chevron: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(t3.mobile.iconMuted.color)
                    .frame(width: 16, height: 16)
                Text(label).font(T3Font.mobile(.sm, .medium)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foreground.color).frame(maxWidth: 260)
                if let chevron {
                    Image(systemName: chevron).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t3.mobile.iconMuted.color)
                }
            }
            .padding(.horizontal, 8).frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(chevron == nil)
    }

    /// One tap moves to the next paired Mac; the picker sheet is D's.
    private func cycleMac() {
        let ids: [String?] = [nil] + model.others.map { Optional($0.id) }
        let i = ids.firstIndex(where: { $0 == macId }) ?? 0
        macId = ids[(i + 1) % ids.count]
        profile = nil
    }

    // MARK: composer (expanded, as T3's draft composer)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                T3ComposerEditor(text: $prompt, isFocused: $focused, placeholder: "Ask anything…", expanded: true,
                                 textColor: t3.mobile.foreground.color, placeholderColor: t3.mobile.placeholder.color) { _ in }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                HStack(spacing: 4) {
                    inlineControl(icon: "gearshape", label: settingsLabel, chevron: "chevron.down") { showSettings = true }
                    Spacer(minLength: 0)
                    Button(action: start) {
                        Group {
                            if starting { ProgressView().tint(t3.mobile.primaryForeground.color) }
                            else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                        }
                        .foregroundStyle(t3.mobile.primaryForeground.color)
                        .frame(width: 36, height: 36)
                        .background(canStart ? t3.mobile.primary.color : t3.mobile.subtle.color, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .accessibilityLabel("Start task")
                }
                .padding(.horizontal, 6).padding(.top, 4)
            }
            .padding(.vertical, 6)
            .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
            .shadow(color: t3.mobile.drawerShadow.color, radius: 14, y: 6)
            if let error {
                Text(error).font(T3Font.mobile(.xxs)).foregroundStyle(t3.mobile.dangerForeground.color).padding(.leading, 14)
            }
        }
    }

    private var settingsLabel: String {
        var parts = [engine == "codex" ? "Codex" : "Claude"]
        if let profile { parts.append(profile.name) }
        if engine == "claude" {
            parts.append(SessionStart.permissionModes.first { $0.mode == permissionMode }?.label ?? "Supervised")
            if headless { parts.append("headless") }
        }
        return parts.joined(separator: " · ")
    }

    private var canStart: Bool { !starting && !cwd.isEmpty }

    /// `POST /sessions/start` with a client-minted `commandId` (#223
    /// phase 4); the request is the phone's `StartSessionSheet` one.
    private func start() {
        starting = true
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SessionStart.Request(
            cwd: cwd, engine: engine, prompt: text.isEmpty ? nil : text,
            permissionMode: engine == "claude" ? (permissionMode.isEmpty ? (headless ? "manual" : nil) : permissionMode) : nil,
            model: engine == "claude" ? profile?.model : nil,
            systemPrompt: engine == "claude" ? profile?.systemPrompt : nil,
            profile: profile?.name, headless: engine == "claude" && headless,
            commandId: UUID().uuidString)
        let target = macId
        Task {
            do {
                let reply = try await model.mirror(for: target).startSession(request)
                guard reply.outcome == "started" else {
                    error = reply.detail ?? reply.outcome
                    starting = false
                    return
                }
                if let pid = reply.pid {
                    model.requestedMacId = target
                    model.requestedPid = pid
                }
                dismiss()
                await model.refresh(macId: target)
            } catch {
                self.error = "couldn't reach the Mac"
                starting = false
            }
        }
    }
}

/// The draft's settings row (T3 `draft/settings`): what the Mac's start
/// route takes — engine, permissions, headless, a saved profile.
struct T3NewTaskSettings: View {
    @ObservedObject var model: MirrorModel
    let macId: String?
    @Binding var engine: String
    @Binding var permissionMode: String
    @Binding var headless: Bool
    @Binding var profile: SessionProfile?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    card {
                        row("Engine") {
                            Picker("Engine", selection: $engine) {
                                Text("Claude Code").tag("claude")
                                Text("Codex CLI").tag("codex")
                            }
                            .pickerStyle(.segmented).frame(maxWidth: 220)
                        }
                        if engine == "claude" {
                            Divider().overlay(t3.mobile.borderSubtle.color)
                            row("Permissions") {
                                Picker("Permissions", selection: $permissionMode) {
                                    Text("Supervised").tag("")
                                    ForEach(SessionStart.permissionModes, id: \.mode) { Text($0.label).tag($0.mode) }
                                }
                                .labelsHidden().tint(t3.mobile.foreground.color)
                            }
                            Divider().overlay(t3.mobile.borderSubtle.color)
                            row("Headless") {
                                Toggle("Headless", isOn: $headless).labelsHidden().tint(t3.mobile.switchActiveTrack.color)
                            }
                        }
                    }
                    if engine == "claude", !model.profiles(macId: macId).isEmpty {
                        card {
                            row("Profile") {
                                Picker("Profile", selection: profileName) {
                                    Text("None").tag(String?.none)
                                    ForEach(model.profiles(macId: macId)) { p in Text(p.name).tag(String?.some(p.name)) }
                                }
                                .labelsHidden().tint(t3.mobile.foreground.color)
                            }
                            if let profile {
                                Divider().overlay(t3.mobile.borderSubtle.color)
                                Text(profile.summary).font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundMuted.color)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                        }
                    }
                    Text(footnote).font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundMuted.color)
                        .padding(.horizontal, 16)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .background(t3.mobile.sheet.color.ignoresSafeArea())
            .navigationTitle("Task settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: profile) { _, p in
                guard let p else { return }
                if let e = p.engine, !e.isEmpty { engine = e }
                if let m = p.permissionMode { permissionMode = m }
            }
        }
    }

    /// Profiles are not Hashable; the picker selects by name.
    private var profileName: Binding<String?> {
        Binding(get: { profile?.name }, set: { name in profile = model.profiles(macId: macId).first { $0.name == name } })
    }

    private var footnote: String {
        switch permissionMode {
        case "manual": return "Every tool asks here, including the ones Claude Code would normally allow."
        case "acceptEdits": return "File edits go through without asking; other tools still ask here."
        case "auto": return "Claude decides what needs asking."
        case "bypassPermissions": return "Nothing asks. Only for folders you trust completely."
        default: return headless ? "Headless runs without a terminal on the Mac; every tool asks here." : "Every tool asks, and the prompts show up on this phone."
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title).font(T3Font.mobile(.base, .medium)).foregroundStyle(t3.mobile.foreground.color)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }
}
