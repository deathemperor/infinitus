import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: what cannot leave the Mac — the Cloudflare tunnel the desktop
/// server rides (cloudflared on this Mac), crash reports, settings as a
/// file (a file panel) and account backup (#1179, a file panel over the
/// keychain-backed store). This Mac's name and the iCloud sync toggle are
/// the desktop's Settings › Infinitus › Devices since #1218/#1221 (their
/// prefs), and left this pane with #1178; phone alerts go through the
/// Infinitus Connect relay since #1375, with nothing to set up here. Was "Sync" — it lived in Display before,
/// which is the wrong home (user report 2026-08-30). The phone mirror it
/// once paired (#9) left with #1041; the phone pairs through the desktop.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The named tunnel publishes its own state (connected, status), so
    /// the pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var named: NamedTunnel
    /// Typed hostname/token live here until Save: the model restarts the
    /// tunnel on a hostname change, and a half-typed one shouldn't.
    @State private var namedHost = ""
    @State private var namedToken = ""
    /// The crash report whose Delete is being confirmed. Lives here, not
    /// on CrashReportsSection, so the dialog can sit on the Form.
    @State private var confirmCrashDelete: CrashReport?
    /// Forgetting the tunnel token asks first.
    @State private var confirmForgetToken = false

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _named = ObservedObject(wrappedValue: app.namedTunnel)
    }

    var body: some View {
        Form {
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
            // Manual path for machines outside the iCloud account
            // (user request 2026-08-30). Same snapshot, same scope as the
            // iCloud sync, whose toggle is the desktop's `icloud_sync`
            // pref; its outcome line stays here, since export and import
            // report through it too.
            Section {
                LabeledContent("Settings as a file") {
                    HStack {
                        Button("Export\u{2026}") { runExportPanel() }
                        Button("Import\u{2026}") { runImportPanel() }
                    }
                }
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("File")
            } footer: {
                Text("The same settings the iCloud sync carries \u{2014} display "
                     + "preferences, custom themes and engine settings. Never "
                     + "credentials, never push secrets.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Account backup lived in the Accounts pane until #1179
            // retired it; a file panel over the keychain-backed store
            // is the one account action that cannot leave the Mac.
            ForEach(app.fleets.filter { $0.capabilities.contains(.backup) }) { fleet in
                Section("Account backup \u{2014} \(fleet.engine.displayName)") {
                    BackupRow(fleet: fleet)
                }
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
