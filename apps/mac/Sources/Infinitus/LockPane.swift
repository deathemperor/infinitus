import SwiftUI
import InfinitusCore

/// Settings › Lock (spec §2.2): the biometric unlock switch and its
/// re-lock choice. Off by default. Style follows DisplayPane: a grouped
/// Form whose section header names the group and whose footer explains
/// what turning it on costs.
struct LockPane: View {
    @ObservedObject var lock: LockModel
    /// Team names, set when turning off needs a warning first.
    @State private var offWarning: [String]?
    @State private var busy = false

    private static let relockLabels: [LockPolicy.Relock: String] = [
        .immediately: "Immediately",
        .fiveMinutes: "After 5 minutes",
        .oneHour: "After 1 hour",
        .onSleep: "When the Mac sleeps",
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Unlock with \(BiometricLock.methodName)",
                       isOn: Binding(get: { lock.enabled }, set: toggle))
                    .disabled(busy)
                Picker("Re-lock", selection: Binding(get: { lock.relock }, set: { lock.relock = $0 })) {
                    ForEach(LockPolicy.Relock.allCases, id: \.self) {
                        Text(Self.relockLabels[$0] ?? $0.label).tag($0)
                    }
                }
                .disabled(!lock.enabled)
                if lock.enabled {
                    Button("Lock Now") { lock.lockNow() }
                }
                if let err = lock.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                        .accessibilityLabel("Error. \(err)")
                }
            } header: {
                Text("Unlocking")
            } footer: {
                Text("The pop-out and this window show a locked state until "
                     + "you unlock; biometrics fall back to your password, as "
                     + "the system does. A timed re-lock settles on your next "
                     + "interaction or when the Mac wakes — nothing ticks "
                     + "while the Mac is idle. Teams need this on: creating a "
                     + "team, accepting an invite and requesting to join stay "
                     + "unavailable until it is.")
            }
            .settingsAnchor("Lock/Unlocking")
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off biometric unlock?",
                            isPresented: Binding(get: { offWarning != nil },
                                                 set: { if !$0 { offWarning = nil } })) {
            Button("Turn Off", role: .destructive) { lock.turnOff(); offWarning = nil }
            Button("Keep On", role: .cancel) { offWarning = nil }
        } message: {
            Text("You're in \(ListFormatter.localizedString(byJoining: offWarning ?? [])). "
                 + "Team data stays on this Mac and re-locks only behind the "
                 + "identity prompt on each launch; you stay in the team.")
        }
    }

    private func toggle(_ on: Bool) {
        if on {
            busy = true
            Task {
                _ = await lock.turnOn()   // false = prompt failed or cancelled; the binding re-reads `enabled`
                busy = false
            }
        } else {
            let teams = lock.teamNames()
            if teams.isEmpty { lock.turnOff() } else { offWarning = teams }
        }
    }
}

extension LockPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: LockModel.paneTitle, section: "Unlocking",
                            label: "Unlock with \(BiometricLock.methodName)",
                            keywords: ["biometric", "touch id", "face id", "password", "unlock", "privacy"],
                            anchor: "Lock/Unlocking"),
        SettingsSearchEntry(pane: LockModel.paneTitle, section: "Unlocking", label: "Re-lock",
                            keywords: ["re-lock", "relock", "timeout", "sleep"], anchor: "Lock/Unlocking"),
    ]
}
