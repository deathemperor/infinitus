import SwiftUI
import AppKit
import InfinitusCore

/// Devices: what cannot leave the Mac — the Cloudflare tunnel the desktop
/// server rides (cloudflared on this Mac) and account backup (#1179, a
/// file panel over the keychain-backed store). This Mac's name, phone
/// alerts (APNs) and the iCloud sync toggle are the desktop's Settings ›
/// Infinitus › Devices since #1218/#1221 (their prefs and the `apns` /
/// `apns-key` verbs), and left this pane with #1178; settings as a file
/// and crash reports left it altogether (user 2026-09-15). Was "Sync" —
/// it lived in Display before, which is the wrong home (user report
/// 2026-08-30). The phone mirror it once paired (#9) left with #1041; the
/// phone pairs through the desktop.
struct SyncPane: View {
    @ObservedObject var app: AppModel
    /// The named tunnel publishes its own state (connected, status), so
    /// the pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var named: NamedTunnel
    /// Typed hostname/token live here until Save: the model restarts the
    /// tunnel on a hostname change, and a half-typed one shouldn't.
    @State private var namedHost = ""
    @State private var namedToken = ""
    /// Forgetting the tunnel token asks first.
    @State private var confirmForgetToken = false

    init(app: AppModel) {
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
}
