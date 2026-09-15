import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Backup and restore for an engine that can hand its accounts over
/// (`.backup`; swapd `export` / `import`). Absent that capability the
/// row never appears — the proxy holds keys it will not reveal.
///
/// Two things make this unlike the other rows around it:
///
///  - **An export is a credential file.** It carries each account's
///    `claudeAiOauth` block in PLAINTEXT (`encrypted: false` in cswap's
///    own header, verified 2026-09-04), so the warning is permanent UI,
///    not a one-time alert someone can dismiss and forget.
///  - **A forced import is destructive and has no dry-run.** Plain
///    import is additive and repairs slots whose refresh token has died,
///    which is the common case and safe; replacing live accounts is the
///    rare one and gets a confirmation naming what it will overwrite.
struct BackupRow: View {
    /// Whether the engine refused a plain import because a slot already
    /// holds that account — the one case the pane offers `--force`. Text
    /// match on the engine's message: a reworded error degrades to
    /// "here's what it said", never to an unasked-for destructive retry.
    static func importNeedsForce(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("--force") || text.contains("already exists")
    }

    @ObservedObject var fleet: FleetState
    @State private var full = false
    @State private var confirmRestore: URL?
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Back up accounts\u{2026}") { runExportPanel() }
                    .disabled(fleet.accounts.isEmpty)
                Button("Restore\u{2026}") { runImportPanel() }
            }
            Toggle("Include the full ~/.claude.json", isOn: $full)
                .help("Off: each account's OAuth credential only. On: the "
                      + "whole ~/.claude.json, which carries editor and "
                      + "project state as well.")
            Text("The backup file contains ACCOUNT CREDENTIALS in plain text \u{2014} "
                 + "treat it like a private key. Keep it out of git and off shared "
                 + "drives, and delete it once you have restored what you needed.")
                .font(.caption).foregroundStyle(.secondary)
            if fleet.accounts.isEmpty {
                Text("Nothing to back up yet.").font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                Text(result).font(.caption)
                    .foregroundStyle(failed ? .red : .secondary)
            }
        }
        .alert("Replace existing accounts?", isPresented: Binding(
            get: { confirmRestore != nil },
            set: { if !$0 { confirmRestore = nil } })) {
            Button("Replace", role: .destructive) {
                if let url = confirmRestore { restore(url, force: true) }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("This backup holds accounts that already exist here. Replacing "
                 + "them overwrites \(fleet.accounts.count) stored credential(s) "
                 + "with the file's, and cannot be undone \u{2014} anything added "
                 + "since the backup is lost.\n\nBack up first if you want a way "
                 + "back.")
        }
    }

    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "infinitus-accounts.json"
        panel.message = "This file will contain account credentials in plain text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fleet.exportAccounts(to: url, full: full) { error in
            failed = error != nil
            result = error.map { "Backup failed: \($0)" }
                ?? "Backed up to \(url.lastPathComponent) \u{2014} treat it like a private key."
        }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Try the SAFE import first. It adds accounts and repairs
        // dead-token slots without touching live ones, so most restores
        // never need the destructive path or its confirmation. Only if
        // the engine refuses for wanting --force do we ask.
        fleet.importAccounts(from: url, force: false) { error in
            guard let error else {
                failed = false
                result = "Restored from \(url.lastPathComponent)."
                return
            }
            if Self.importNeedsForce(error) {
                confirmRestore = url
                return
            }
            failed = true
            result = "Restore failed: \(error)"
        }
    }

    private func restore(_ url: URL, force: Bool) {
        fleet.importAccounts(from: url, force: force) { error in
            failed = error != nil
            result = error.map { "Restore failed: \($0)" }
                ?? "Restored from \(url.lastPathComponent), replacing existing accounts."
        }
    }
}
