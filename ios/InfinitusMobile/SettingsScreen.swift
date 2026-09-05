import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Settings TAB's content (#9 native shell) — the same Form the Mac
/// popup's gear sheet shows, minus any navigation chrome, so both shells
/// present one settings screen.
///
/// The phone's display prefs (#9 phase C2). "Follow Mac" is the whole
/// point of the mirror, so it's on by default and hides everything else;
/// with it off these are the mac's own Display / Themes / Animations
/// choices, same values and same labels.
struct SettingsForm: View {
    @AppStorage("chat_header") private var chatHeader = "compact"
    @AppStorage(FleetAlarmCenter.enabledKey) private var fleetAlarms = true

    @ObservedObject var model: MirrorModel
    /// The QR scanner (#9 remote access) is a sheet, not a screen: it
    /// exists for the ten seconds it takes to pair.
    @State private var scanning = false
    @State private var paired = false

    var body: some View {
        Form {
            Section {
                Toggle("Follow Mac", isOn: $model.followMac)
                Text("Renders exactly what the Mac popup shows — its "
                     + "theme, compact mode, pace fire and intro. Turn "
                     + "off to pick your own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.followMac {
                Section("Theme") {
                    Picker("Theme", selection: $model.localThemeID) {
                        ForEach(model.availableThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    ThemePreviewRow(theme: model.rowTheme)
                }
                Section("Display") {
                    Toggle("Compact rows (one line per account)",
                           isOn: $model.localCompactRows)
                }
                Section("Pace fire (7d & model bars)") {
                    Picker("Style", selection: $model.localBurnStyle) {
                        Text("Off").tag("off")
                        Text("Ember glow").tag("ember")
                        Text("Flame licks").tag("flame")
                        Text("Limit break").tag("limit")
                    }
                }
                Section("Launch intro") {
                    Picker("Content entrance", selection: $model.localIntroStyle) {
                        Text("Slide from top").tag("top")
                        Text("Slide from bottom").tag("bottom")
                        Text("Fade in").tag("fade")
                        Text("Rows slide from right").tag("rows")
                    }
                    Picker("Title flourish", selection: $model.localIntroTitle) {
                        Text("Zoom bounce").tag("zoom")
                        Text("Stamp slam").tag("slam")
                        Text("Spin up").tag("spin")
                        Text("Off").tag("off")
                    }
                    LabeledContent("Speed") {
                        HStack {
                            Slider(value: $model.localIntroSpeed, in: 0.4...2)
                            Text(String(format: "%.1fx", model.localIntroSpeed))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Button("Replay intro") { model.replayIntro() }
                }
            }
            // Multi-host pairing (04-phone, W14): each machine is its
            // own record with label, emoji, endpoints and token.
            hostsSection
            DictationSettings()
            ScreenshotSettings()
            // The 1:1 Mac rendering isn't lost, just off by default
            // (#9 native shell): this flips the whole app back to it.
            Section("Appearance") {
                ChatHeaderPicker(selection: $chatHeader, theme: model.rowTheme)
                Toggle("Show as Mac popup", isOn: $model.macPopupView)
                Text("Renders the Mac popup itself — the same layout, "
                     + "chrome and scaling, on dark. Off is the native "
                     + "iOS shell. In Mac view, portrait shows the "
                     + "stacked cards and landscape the wide rows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Reset and swap alerts", isOn: $fleetAlarms)
                Text("From the phone itself, planned from the last snapshot: "
                     + "an exhausted account's limit lifting in 10 minutes, "
                     + "and the account the fleet just swapped to. Needs "
                     + "nothing on the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: fleetAlarms) { _, on in
            if !on { FleetAlarmCenter.shared.clearPending() }
        }
        .sheet(isPresented: $scanning) {
            PairScannerSheet { payload in
                if let host = model.applyPairing(payload) {
                    pairedHostName = model.snapshots[host.id]?.machineName ?? (!host.label.isEmpty ? host.label : "the host")
                    paired = true
                }
            }
        }
        .sheet(isPresented: $addingManual) {
            AddHostSheet(model: model)
        }
        .alert("Paired", isPresented: $paired) {
            Button("OK") { model.requestedTab = "fleet" }
        } message: {
            Text("Paired with \(pairedHostName). Its accounts and sessions show up as soon as it answers.")
        }
        .sensoryFeedback(.success, trigger: paired)
    }

    @State private var addingManual = false
    @State private var pairedHostName = "the host"

    private var hostsSection: some View {
        Section {
            if PairScanner.isSupported {
                Button {
                    scanning = true
                } label: {
                    Label("Scan a QR code", systemImage: "qrcode.viewfinder")
                        .font(.body.weight(.semibold))
                }
            }
            Button {
                addingManual = true
            } label: {
                Label("Add by address + token", systemImage: "plus.circle")
            }
            if model.hosts.isEmpty {
                Text("No hosts paired. Scan a QR code or add an address to start mirroring.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.hosts) { host in
                    NavigationLink {
                        HostDetailScreen(model: model, hostID: host.id)
                    } label: {
                        hostRow(host)
                    }
                }
                .onDelete { model.removeHost(at: $0) }
            }
        } header: {
            Text("Hosts")
        } footer: {
            Text("Infinitus can mirror multiple Macs and Windows boxes side by side. "
                 + "Scanning a QR code sets up that machine; tap a host to edit its routes.")
        }
    }

    private func hostRow(_ host: MirrorHost) -> some View {
        let snapshot = model.snapshots[host.id]
        let name = host.label.isEmpty ? (snapshot?.machineName ?? "Host") : host.label
        let emoji = host.emoji.isEmpty ? MirrorHost.defaultEmoji(for: snapshot ?? MirrorSnapshot(capturedAt: Date(), machineName: name, listJSON: Data(), sessions: [])) : host.emoji
        let status = model.transportStatuses[host.id]
            ?? (model.hosts.count <= 1 ? model.transportStatus : nil)
            ?? ""
        return HStack(spacing: 10) {
            Text(emoji).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Host detail editor: label, emoji picker, endpoints list + add/remove, token.
struct HostDetailScreen: View {
    @ObservedObject var model: MirrorModel
    let hostID: String

    @State private var labelText = ""
    @State private var selectedEmoji = ""
    @State private var newEndpoint = ""
    @State private var tokenText = ""
    @State private var revealToken = false

    private static let emojiPalette = ["🍎", "🪟", "🐧", "🖥️", "💻", "🏠", "🏢"]

    private var host: MirrorHost? {
        model.hosts.first(where: { $0.id == hostID })
    }

    var body: some View {
        Form {
            if let host {
                Section("Host") {
                    LabeledContent("Name") {
                        TextField("Machine name", text: $labelText)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { saveLabel() }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            ForEach(Self.emojiPalette, id: \.self) { emoji in
                                Button {
                                    selectedEmoji = emoji
                                    model.updateHost(hostID) { $0.emoji = emoji }
                                } label: {
                                    Text(emoji)
                                        .font(.title2)
                                        .padding(6)
                                        .background(selectedEmoji == emoji ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(Array(host.endpoints.enumerated()), id: \.element) { _, endpoint in
                        Text(endpoint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .onDelete { offsets in
                        model.updateHost(hostID) { $0.endpoints.remove(atOffsets: offsets) }
                    }
                    LabeledContent("Add address") {
                        TextField("host:port, or https://…", text: $newEndpoint)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onSubmit { addEndpoint() }
                    }
                } header: {
                    Text("Routes")
                } footer: {
                    Text("Failover list for this host: local LAN, tailnet, tunnel.")
                }

                Section("Pairing Token") {
                    if revealToken {
                        TextField("Token", text: $tokenText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { saveToken() }
                    } else {
                        Text(MirrorPairing.mask(host.token.isEmpty ? tokenText : host.token))
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(revealToken ? "Hide token" : "Reveal / Edit token") {
                        if !revealToken { tokenText = host.token }
                        else { saveToken() }
                        revealToken.toggle()
                    }
                }

                Section {
                    Button(role: .destructive) {
                        model.removeHost(id: hostID)
                    } label: {
                        Label("Remove host", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView("Host removed", systemImage: "trash")
            }
        }
        .navigationTitle(labelText.isEmpty ? (host?.label ?? "Host") : labelText)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let host {
                labelText = host.label
                selectedEmoji = host.emoji
                tokenText = host.token
            }
        }
    }

    private func saveLabel() {
        let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateHost(hostID) { $0.label = trimmed }
    }

    private func saveToken() {
        let normalized = MirrorPairing.normalize(tokenText)
        model.updateHost(hostID) { $0.token = normalized }
    }

    private func addEndpoint() {
        let endpoint = newEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        model.updateHost(hostID) {
            if !$0.endpoints.contains(endpoint) {
                $0.endpoints.append(endpoint)
            }
        }
        newEndpoint = ""
    }
}

/// Sheet to add a host manually by entering endpoint + token.
struct AddHostSheet: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var token = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("host:port or https://tunnel…", text: $address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Host address")
                }

                Section {
                    TextField("24-character token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Pairing token")
                } footer: {
                    Text("Found in the host daemon's output or Infinitus Settings → Devices.")
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = MirrorPairing.normalize(token)
        guard !addr.isEmpty, !tok.isEmpty else { return }
        let pairURL = MirrorPairing.pairURL(endpoint: addr, token: tok)
        if model.applyPairing(pairURL) != nil {
            dismiss()
        } else {
            errorText = "Invalid address or token format."
        }
    }
}

/// The gear sheet the Mac-popup view puts up — the tab's Form, wrapped
/// in the navigation chrome a sheet needs.
struct SettingsScreen: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm(model: model)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { dismiss() }
                }
        }
    }
}

/// What a themed row will look like: the shared gauge with the theme's
/// own window labels and colors — the same components the fleet rows
/// draw, at a glance, while picking.
struct ThemePreviewRow: View {
    let theme: RowTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                gauge(label: theme.sessionLabel, color: theme.sessionColor,
                      remaining: 62, dividers: (1..<5).map { Double($0) * 20 })
                gauge(label: theme.weeklyLabel, color: theme.weeklyColor,
                      remaining: 38, dividers: (1..<7).map { Double($0) * 100 / 7 })
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func gauge(label: String, color: String, remaining: Double,
                       dividers: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(PopupGlyph.text(label))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(color))
            if theme.plain {
                Text("\(Int(100 - remaining))%")
                    .font(PopupFont.caption).monospacedDigit()
            } else {
                GaugeBar(remaining: remaining, color: ThemeColor.resolve(color),
                         dividers: dividers, animated: false)
            }
        }
    }
}


/// Dictation language and what happens to a non-English take (user
/// 2026-09-04: "can it accept Vietnamese? … build them configurable").
private struct DictationSettings: View {
    @AppStorage(Dictation.localeKey) private var localeID = ""
    @AppStorage(Dictation.policyKey) private var policy = "phone"
    @AppStorage(Dictation.hintsKey) private var hints = true

    private var phoneTranslation: Bool {
        if #available(iOS 18.0, *) { return true } else { return false }
    }

    var body: some View {
        Section {
            Picker("Language", selection: $localeID) {
                Text("Phone language (\(Dictation.displayName(Locale.current)))").tag("")
                ForEach(Dictation.supportedLocales, id: \.identifier) { locale in
                    Text(Dictation.displayName(locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.navigationLink)
            Picker("Non-English dictation", selection: $policy) {
                if phoneTranslation { Text("Translate on the phone").tag("phone") }
                Text("Send as spoken, ask for an English reply").tag("note")
                Text("Send as spoken").tag("none")
            }
            Toggle("Hint the session's terms", isOn: $hints)
        } header: {
            Text("Dictation")
        } footer: {
            Text((phoneTranslation
                  ? "Translation runs on the phone — nothing leaves it; the first use downloads the language. "
                  : "On-phone translation needs iOS 18. ")
                 + "Long-press the mic to switch language. Hints hand the recognizer the "
                 + "session's names, branch and tools so English terms survive a "
                 + (localeID.isEmpty ? "non-English" : Dictation.displayName(Locale(identifier: localeID)))
                 + " take.")
        }
    }
}

/// Screenshots offered for one-tap sending (user 2026-09-04: "react
/// system screenshots too as I may take screenshots from other apps").
private struct ScreenshotSettings: View {
    @AppStorage(ScreenshotWatch.enabledKey) private var offerScreenshots = true

    var body: some View {
        Section {
            Toggle("Offer new screenshots", isOn: $offerScreenshots)
                .onChange(of: offerScreenshots) { _, on in
                    ScreenshotWatch.enabled = on
                    if on { Task { await ScreenshotWatch().requestAccess() } }
                }
        } header: {
            Text("Screenshots")
        } footer: {
            Text("A screenshot you take — in this app or any other — is offered on a session's chat "
                 + "for one-tap sending. Needs full Photos access. Without it: the camera button in a "
                 + "chat's header sends that screen, and a shake on any screen captures it and asks "
                 + "which session to send it to.")
        }
    }
}
