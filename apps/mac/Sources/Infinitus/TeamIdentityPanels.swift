import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Spec §2.1 in the pane: the recovery key (after Touch ID, shown once,
/// copied by the user), a passphrase-sealed export to a file the user
/// picks, and import from a file or a recovery key.
struct TeamRecoveryKeySheet: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovery key").font(.headline)
            if let key {
                Text(key).font(.body.monospaced()).textSelection(.enabled)
                Text("Anyone with this key IS this identity. Keep it offline; it is not shown again without Touch ID.").font(.caption).foregroundStyle(.secondary)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string) }
            } else {
                ProgressView()
            }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding().frame(width: 460)
        .task { key = await team.recoveryKey(); if key == nil { dismiss() } }
    }
}

struct TeamExportSheet: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var again = ""
    @State private var error: String?
    var body: some View {
        Form {
            SecureField("Passphrase (8+ characters)", text: $passphrase)
            SecureField("Again", text: $again)
            Text("The file holds your identity secret sealed with this passphrase (PBKDF2 600k + ChaChaPoly). Without the passphrase it is noise.").font(.caption).foregroundStyle(.secondary)
            if let err = error ?? team.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "infinitus-identity.json"
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        error = "that file exists; pick another name — the export never overwrites"
                        return
                    }
                    error = nil
                    team.clearError()
                    Task { if await team.exportIdentity(passphrase: passphrase, to: url) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.count < 8 || passphrase != again)
            }
        }
        .padding().frame(width: 420)
    }
}

struct TeamImportSheet: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var recovery = ""
    @State private var passphrase = ""
    var body: some View {
        Form {
            Section("From a recovery key") {
                TextField("xxxxxxx-xxxxxxx-…", text: $recovery).font(.body.monospaced())
                Button("Import key") { team.clearError(); Task { if await team.importIdentity(recoveryKey: recovery) { dismiss() } } }.disabled(recovery.isEmpty)
            }
            Section("From an export file") {
                SecureField("Passphrase", text: $passphrase)
                Button("Choose file…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    team.clearError()
                    Task { if await team.importIdentity(file: url, passphrase: passphrase) { dismiss() } }
                }.disabled(passphrase.isEmpty)
            }
            Text("Replaces this Mac's identity. Teams that approved the old kid must re-approve; leave any team first.").font(.caption).foregroundStyle(.orange)
            if let err = team.lastError {
                Text(err).font(.caption.bold()).foregroundStyle(.orange)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding().frame(width: 460)
    }
}
