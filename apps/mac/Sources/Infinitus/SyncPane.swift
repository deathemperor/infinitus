import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: what cannot leave the Mac — crash reports, settings as a
/// file (a file panel) and account backup (#1179, a file panel over the
/// keychain-backed store). This Mac's name and the iCloud sync toggle are
/// the desktop's Settings › Infinitus › Devices since #1218/#1221 (their
/// prefs), and left this pane with #1178; phone alerts go through the
/// Infinitus Connect relay since #1375, with nothing to set up here. Was "Sync" — it lived in Display before,
/// which is the wrong home (user report 2026-08-30). The phone mirror it
/// once paired (#9) left with #1041, and the Cloudflare tunnels left when
/// Infinitus Connect took over remote reach; the phone pairs through the
/// desktop on the LAN and reaches this Mac through Connect off it.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The crash report whose Delete is being confirmed. Lives here, not
    /// on CrashReportsSection, so the dialog can sit on the Form.
    @State private var confirmCrashDelete: CrashReport?

    var body: some View {
        Form {
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
