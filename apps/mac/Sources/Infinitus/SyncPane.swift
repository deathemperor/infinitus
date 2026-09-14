import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: this Mac's name, the Cloudflare tunnel the desktop server
/// rides, phone alerts (APNs), crash reports, plus settings sync across
/// Macs (iCloud, file). Was "Sync" — it lived in Display before, which is
/// the wrong home (user report 2026-08-30): it syncs notify flags and
/// engine config too, not just display prefs. The phone mirror it once
/// paired (#9) left with #1041; the phone pairs through the desktop.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The named tunnel publishes its own state (connected, status), so
    /// the pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var named: NamedTunnel
    @ObservedObject private var pusher: LiveActivityPusher
    /// Typed hostname/token live here until Save: the model restarts the
    /// tunnel on a hostname change, and a half-typed one shouldn't.
    @State private var namedHost = ""
    @State private var namedToken = ""
    /// The crash report whose Delete is being confirmed. Lives here, not
    /// on CrashReportsSection, so the dialog can sit on the Form.
    @State private var confirmCrashDelete: CrashReport?
    /// Forgetting a keychain secret is hard to undo (the APNs .p8 downloads
    /// from Apple once), so both Forget buttons ask first.
    @State private var confirmForgetKey = false
    @State private var confirmForgetToken = false

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _named = ObservedObject(wrappedValue: app.namedTunnel)
        _pusher = ObservedObject(wrappedValue: app.liveActivityPusher)
    }

    var body: some View {
        Form {
            Section {
                TextField("This Mac's name", text: $app.machineNameOverride,
                          prompt: Text(MachineName.system()))
            } header: {
                Text("This Mac")
            } footer: {
                Text("How the phone and the desktop name this Mac. Empty follows the computer name.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                if QuickTunnel.binaryPath != nil {
                    namedTunnelRows
                } else {
                    LabeledContent("Cloudflare tunnel") {
                        Button("Copy Install Command") { copy("brew install cloudflared") }
                    }
                    Text("Not installed. Paste the copied command into Terminal and the "
                         + "tunnel settings appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Tunnel")
            } footer: {
                Text("Your own Cloudflare tunnel: a hostname that never changes, fronting "
                     + "the desktop server on this Mac so the phone reaches it from anywhere. "
                     + "Same Wi-Fi needs none of this.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .onAppear { namedHost = app.mirrorNamedTunnelHost }
            CrashReportsSection(app: app, confirmDelete: $confirmCrashDelete)
            Section {
                liveActivityRows
            } header: {
                Text("Phone alerts")
            } footer: {
                Text("The Mac's own notifications reach the phone while the app is "
                     + "open. To keep reaching it with the app closed, this Mac pushes "
                     + "through Apple (APNs) with a key from your developer account: "
                     + "Certificates, Identifiers & Profiles \u{2192} Keys \u{2192} + \u{2192} "
                     + "Apple Push Notifications service, download the .p8.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Sync settings via iCloud Drive", isOn: $sync.enabled)
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Display preferences, custom themes and engine settings travel through "
                     + "one file in your iCloud Drive. Never credentials, never push "
                     + "secrets. The last Mac to write wins.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Manual path for machines outside the iCloud account
            // (user request 2026-08-30). Same snapshot, same scope.
            Section {
                LabeledContent("Settings as a file") {
                    HStack {
                        Button("Export\u{2026}") { runExportPanel() }
                        Button("Import\u{2026}") { runImportPanel() }
                    }
                }
            } header: {
                Text("File")
            } footer: {
                Text("The same settings the iCloud sync carries \u{2014} display "
                     + "preferences, custom themes and engine settings. Never "
                     + "credentials, never push secrets.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete this crash report?",
                            isPresented: Binding(get: { confirmCrashDelete != nil },
                                                 set: { if !$0 { confirmCrashDelete = nil } }),
                            presenting: confirmCrashDelete) { report in
            Button("Delete", role: .destructive) {
                app.removeCrash(report.id)
                confirmCrashDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmCrashDelete = nil }
        } message: { report in
            Text("The report from \(crashWhen(report)) is gone from this Mac for good. The "
                 + "crash it describes has already happened \u{2014} deleting it changes "
                 + "nothing else.")
        }
        .confirmationDialog("Forget the push key?", isPresented: $confirmForgetKey) {
            Button("Forget", role: .destructive) { pusher.storeKey(pem: "") }
            Button("Keep Key", role: .cancel) { }
        } message: {
            Text("The key leaves the keychain and the phone stops getting this Mac's "
                 + "alerts with the app closed. Apple hands out each key file once, so "
                 + "without your own copy you'll need a new key to set push up again. "
                 + "Pairing and everything else here are untouched.")
        }
        .confirmationDialog("Forget the tunnel token?", isPresented: $confirmForgetToken) {
            Button("Forget", role: .destructive) { app.saveNamedTunnelToken("") }
            Button("Keep Token", role: .cancel) { }
        } message: {
            Text("The token leaves the keychain. Unless Cloudflare's config file on this "
                 + "Mac already routes this hostname, the tunnel stops now and the phone "
                 + "reaches this Mac on the same Wi-Fi only. Paste the token from the Cloudflare "
                 + "dashboard again to bring it back \u{2014} the hostname stays saved.")
        }
    }

    /// The restart-proof remote route: a Cloudflare tunnel the user owns.
    /// Cloudflare holds the hostname → localhost:port mapping; this Mac
    /// holds only the tunnel token, in the keychain.
    /// Alert pushes (APNs): the .p8 key that lets this Mac reach the
    /// phone with its own notifications while the app is closed.
    @ViewBuilder private var liveActivityRows: some View {
        TextField("Team ID", text: $pusher.teamID, prompt: Text("ABCDE12345"))
        TextField("Key ID", text: $pusher.keyID, prompt: Text("the key's 10-character id"))
        HStack {
            Button(pusher.keyStored ? "Replace Key from Clipboard" : "Paste Key from Clipboard") {
                pusher.storeKey(pem: NSPasteboard.general.string(forType: .string) ?? "")
            }
            if pusher.keyStored {
                Button("Forget Key\u{2026}", role: .destructive) { confirmForgetKey = true }
            }
            Text(pusher.keyStored ? "In the Keychain" : "Not Set Up")
                .font(.caption).foregroundStyle(.secondary)
        }
        if pusher.registrations.isEmpty {
            Text("No phone has registered a push token yet — open the app once "
                 + "on the phone after it's paired.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(pusher.registrations.values.sorted { $0.registeredAt > $1.registeredAt },
                    id: \.slot) { reg in
                Text("\(reg.deviceName) · \(reg.kind.rawValue) · \(reg.environment) · "
                     + reg.registeredAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let result = pusher.lastResult {
            Text(result).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var namedTunnelRows: some View {
        Toggle("Expose through your own Cloudflare tunnel",
               isOn: $app.mirrorNamedTunnelEnabled)
        TextField("Hostname", text: $namedHost, prompt: Text("infinitus.example.com"))
            .textFieldStyle(.roundedBorder)
            .onSubmit { app.mirrorNamedTunnelHost = namedHost }
        if app.namedTunnelLocalConfig {
            LabeledContent("Tunnel token") {
                Text("Not needed \u{2014} Cloudflare's config file on this Mac already "
                     + "routes this hostname.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            SecureField("Tunnel token", text: $namedToken,
                        prompt: Text(app.namedTunnelTokenPresent
                                     ? "•••••••• (stored in keychain)" : "eyJh… from the Cloudflare dashboard"))
                .textFieldStyle(.roundedBorder)
        }
        HStack {
            Button("Save Tunnel") {
                app.mirrorNamedTunnelHost = namedHost
                if !namedToken.isEmpty { app.saveNamedTunnelToken(namedToken) }
                namedToken = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(NamedTunnel.normalizeHostname(namedHost).isEmpty)
            if app.namedTunnelTokenPresent {
                Button("Forget Token\u{2026}", role: .destructive) { confirmForgetToken = true }
            }
        }
        if let status = named.status {
            Text(status).font(.caption)
                .foregroundStyle(named.connected ? Color.secondary : Color.orange)
        }
        Text("Both ways need a Cloudflare account with your domain on it. In the "
             + "dashboard: Zero Trust \u{2192} Networks \u{2192} Tunnels \u{2192} Create "
             + "\u{2192} Cloudflared, name it, paste its token above, and point its public "
             + "hostname at this Mac's port \(app.forkServerPort), the desktop server's. In Terminal: "
             + "create and route a tunnel with cloudflared, add this hostname to its config "
             + "file, and no token is needed here.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Copy the Config File Path") { copy("~/.cloudflared/config.yml") }
            Spacer()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "infinitus-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.export(to: url) }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.importConfig(from: url) }
    }
}

/// How a crash report is named in a sentence: the moment it happened.
private func crashWhen(_ report: CrashReport) -> String {
    report.at.formatted(date: .abbreviated, time: .shortened)
}

/// Crashes of the phone app (MetricKit, over the control socket's
/// `crash-report`) and of this Mac app (its own diagnostic reports):
/// built-in, nothing leaves the machine.
private struct CrashReportsSection: View {
    @ObservedObject var app: AppModel
    @Binding var confirmDelete: CrashReport?

    var body: some View {
        Section {
            if app.crashReports.isEmpty {
                Text("None. The phone reports its own crashes here on its next launch; "
                     + "this Mac's land here after a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(app.crashReports.prefix(10)) { report in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.summary).lineLimit(1)
                        Text("\(report.at.formatted(date: .abbreviated, time: .shortened)) · app \(report.appVersion) · \(report.osVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.transcript, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy the report from \(crashWhen(report))")
                    .help("Copy the report.")
                    Button(role: .destructive) { confirmDelete = report } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete the report from \(crashWhen(report))")
                    .help("Delete this report from this Mac.")
                }
            }
        } header: {
            Text("Crash reports")
        } footer: {
            Text("Nothing leaves this Mac. Send one into a live session to have it looked "
                 + "at, or copy it to read yourself.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
