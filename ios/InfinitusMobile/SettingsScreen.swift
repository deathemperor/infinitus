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
    /// The Team tab's biometric lock (spec §2.2), so the toggle's label
    /// can name whatever this phone actually has.
    @ObservedObject private var lock = MobileLock.shared
    /// The QR scanner (#9 remote access) is a sheet, not a screen: it
    /// exists for the ten seconds it takes to pair.
    @State private var scanning = false
    /// Staged text for the "add an address" field — submitting it grows
    /// the endpoint list rather than replacing it (#9 pair once, every
    /// route).
    @State private var newEndpoint = ""
    @State private var paired = false
    /// The other Mac a "Make primary" tap is confirming (#144 phase 1).
    @State private var promoting: MirrorModel.OtherMac?

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
            // The transport (#9 remote access): which Mac is being
            // mirrored, the token that lets us read it, and the ways in
            // when Bonjour doesn't survive the network.
            Section {
                if PairScanner.isSupported {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the Mac's QR code", systemImage: "qrcode.viewfinder")
                            .font(.body.weight(.semibold))
                    }
                } else {
                    Text("No camera here — type the address and token from the Mac's Settings → Devices below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.transportStatus.isEmpty
                     ? model.rowTheme.loadingWord("searching")
                     : model.transportStatus)
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.manualEndpoints.enumerated()), id: \.element) { _, endpoint in
                    Text(endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .onDelete { model.removeManualEndpoint(at: $0) }
                LabeledContent("Add address") {
                    TextField("host:port, or a tunnel's https:// URL", text: $newEndpoint)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit {
                            model.addManualEndpoint(newEndpoint)
                            newEndpoint = ""
                        }
                }
                LabeledContent("Pairing token") {
                    TextField("from the Mac's Devices settings",
                              text: $model.pairToken)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Mac connection")
            } footer: {
                Text("Scanning the QR code sets everything up. On the same Wi-Fi the phone "
                     + "finds the Mac by itself; add an address for anywhere else.")
            }
            // Every OTHER paired Mac (#144 phase 1): read-only fleets and
            // sessions elsewhere in the app, forgettable or promotable
            // here. Shown even with none yet — the footer is the "how".
            Section {
                ForEach(model.others) { other in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(other.pairing.name).fontWeight(.semibold)
                        Text(otherCaption(other)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            model.forgetOther(id: other.id)
                        }
                    }
                    .contextMenu {
                        Button("Make primary") { promoting = other }
                    }
                }
            } header: {
                Text("Other Macs")
            } footer: {
                Text("Scan another Mac's QR to add it; widgets and Live Activities follow the primary Mac.")
            }
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
            Section("Team") {
                Toggle("Lock the Team tab with \(lock.methodName)", isOn: $lock.enabled)
                Text("Joining a team from the phone needs the lock on (the Mac has the same rule).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AboutSettings(model: model)
        }
        .onChange(of: fleetAlarms) { _, on in
            if !on { FleetAlarmCenter.shared.clearPending() }
        }
        .sheet(isPresented: $scanning) {
            PairScannerSheet { payload in
                if model.applyPairing(payload) { paired = true }
            }
        }
        .alert("Paired", isPresented: $paired) {
            Button("OK") { model.requestedTab = "fleet" }
        } message: {
            Text("Paired with \(model.snapshot?.machineName ?? "the Mac"). Its accounts are on the Fleet tab.")
        }
        .sensoryFeedback(.success, trigger: paired)
        .confirmationDialog("Make primary",
                            isPresented: Binding(get: { promoting != nil }, set: { if !$0 { promoting = nil } }),
                            presenting: promoting) { other in
            Button("Make primary") { model.makePrimary(id: other.id) }
            Button("Cancel", role: .cancel) {}
        } message: { other in
            Text("Make \(other.pairing.name) the primary Mac? Chats, approvals and widgets follow it.")
        }
    }

    /// Settings › Devices' caption for an other Mac: what it's showing,
    /// or the mirror's own status line while it hasn't answered yet.
    private func otherCaption(_ other: MirrorModel.OtherMac) -> String {
        guard other.snapshot != nil else {
            return other.status.isEmpty ? "looking for this Mac…" : other.status
        }
        if other.parked, let seen = other.snapshot?.capturedAt {
            return "parked — last seen \(seen.formatted(.relative(presentation: .named)))"
        }
        let sessions = other.fleets.reduce(0) { $0 + ($1.liveSessions?.total ?? 0) }
        return "\(other.fleets.count) fleet\(other.fleets.count == 1 ? "" : "s") · "
            + "\(sessions) session\(sessions == 1 ? "" : "s")"
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
            HStack(spacing: 4) {
                if let glyph = theme.rateGlyph {
                    Text(PopupGlyph.text(glyph)).font(PopupFont.caption)
                } else {
                    Image(systemName: "bolt.horizontal.fill").font(PopupFont.caption).foregroundStyle(.yellow)
                }
                Text(TokenRate(perMinute: 1200, peakPerMinute: 1200).label(theme: theme))
                    .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
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

/// Both apps' versions, and the Mac's own update — one tap from the
/// phone, brew doing the actual upgrade (#121).
private struct AboutSettings: View {
    @ObservedObject var model: MirrorModel
    @State private var confirming = false
    @State private var updating = false
    @State private var result: String?

    private var phoneVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var phoneBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        Section("About") {
            LabeledContent("This iPhone", value: "Infinitus \(phoneVersion) (\(phoneBuild))")
            if let snapshot = model.snapshot {
                if let app = snapshot.app {
                    LabeledContent(snapshot.machineName,
                                  value: "Infinitus \(app.version) · \(app.sha.prefix(7))")
                    if app.updateChannel == "source" {
                        Text("source build — update from the repo")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let updateVersion = app.updateVersion {
                        LabeledContent("Mac update available: \(updateVersion)") {
                            Button("Update the Mac") { confirming = true }
                                .disabled(updating)
                        }
                        .confirmationDialog("Update the Mac to \(updateVersion)? brew upgrades "
                                             + "Infinitus and relaunches it.",
                                            isPresented: $confirming, titleVisibility: .visible) {
                            Button("Update") { update() }
                        }
                        if let result {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let phoneLatest = app.phoneLatest,
                       let latest = PackageVersion(phoneLatest), let mine = PackageVersion(phoneVersion),
                       mine < latest {
                        Text("A newer Infinitus (\(phoneLatest)) is out — rebuild the phone app from the release.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(snapshot.machineName, value: "version not reported")
                }
            } else {
                LabeledContent("Mac", value: "not connected")
            }
        }
    }

    private func update() {
        updating = true
        result = nil
        Task {
            do {
                let reply = try await NetworkFleetMirror.shared.updateMac()
                result = reply.detail ?? reply.outcome
            } catch {
                result = error.localizedDescription
            }
            updating = false
        }
    }
}
