import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: what cannot leave the Mac — settings as a file (a file panel)
/// and account backup (#1179, a file panel over the keychain-backed
/// store). This Mac's name and the iCloud sync toggle are the desktop's
/// Settings › Infinitus › Devices since #1218/#1221 (their prefs), and
/// left this pane with #1178; phone alerts go through the Infinitus
/// Connect relay since #1375, with nothing to set up here. Was "Sync" —
/// it lived in Display before, which is the wrong home (user report
/// 2026-08-30). The phone mirror it once paired (#9) left with #1041, and
/// the Cloudflare tunnels left when Infinitus Connect took over remote
/// reach; the phone pairs through the desktop on the LAN and reaches this
/// Mac through Connect off it. Crash reports are the desktop's Devices
/// page now, over the `crashes` verb — this Mac still records and prunes
/// them, it just no longer draws them.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
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
