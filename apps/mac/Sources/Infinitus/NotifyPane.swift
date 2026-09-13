import SwiftUI
import InfinitusCore

/// What the app pushes to the phone (#9): account triggers.
struct NotifyPane: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("All accounts are exhausted", isOn: $app.pushAllDead)
                Toggle("The last alive account nears its limit", isOn: $app.pushLastAlive)
                Toggle("An account comes back", isOn: $app.pushRevived)
                Stepper(value: $app.reviveLeadMinutes, in: 1...120) {
                    Text("Revive countdown lead: \(app.reviveLeadMinutes) min")
                }
            } header: {
                Text("Push about accounts")
            } footer: {
                Text("Every switch is pushed already. Last alive: one push when only one "
                     + "account still has quota and it crosses \(Int(PushTriggers.warnPct))%. "
                     + "Comes back: when an exhausted account's windows reset, named, and "
                     + "flagged when Anthropic reset it before the advertised time. The "
                     + "countdown lead is how far ahead of an exhausted account's reset its "
                     + "row starts counting down live and the phone's reset alarm fires.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
